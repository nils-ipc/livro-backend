# Particionamento e sharding

## O DELETE que comemorou aniversário

Ninguém cantou parabéns quando o `DELETE` que apaga leituras de temperatura com mais de 90 dias completou 30 horas de execução, numa segunda-feira de manhã. A empresa (hipotética) monitora 50 mil freezers de sorveterias e supermercados, cada um mandando uma leitura por minuto, e a tabela `leituras` guarda 6,5 bilhões de linhas. O expurgo semanal começou no domingo às 2h e precisa apagar 500 milhões delas.

Cada linha apagada vira uma versão morta para o *autovacuum* limpar depois, as réplicas acumulam 40 minutos de atraso e o disco chegou a 91%. Na reunião de crise, alguém sugere: "Vamos fazer *sharding*". Outra pessoa pergunta: "Por qual coluna?". Uma terceira responde: "Pela geladeira, claro". Uma quarta, que atende a maior cliente da empresa, a Sorveteria Pinguim Feliz e seus 9 mil freezers, fica pálida e não diz nada.

Como cortar dados em pedaços de modo que cada consulta encontre o que precisa num pedaço só, e o que acontece no dia em que o corte precisar mudar?

## Partição e shard, duas palavras para cortar uma tabela

**Particionar** é dividir os dados de uma tabela lógica em pedaços menores, chamados partições, segundo uma regra aplicada a uma ou mais colunas: a **chave de partição**. Cada linha pertence a exatamente uma partição.

O mercado usa duas palavras com uma diferença que importa:

- **Particionamento**: as partições ficam no mesmo servidor, e o banco roteia as linhas e otimiza as consultas sozinho. Você ganha manutenção barata e consultas que ignoram partições irrelevantes. Não ganha CPU, memória nem disco.
- **Sharding**: as partições (os *shards*) ficam em servidores diferentes. A capacidade soma, e os problemas também: consultas e transações que atravessam máquinas, dados mudando de servidor em pleno uso.

Os dois usam as mesmas regras de divisão e sofrem dos mesmos males. No particionamento, um erro custa uma consulta lenta; no sharding, custa uma consulta lenta que conversa com 32 servidores para descobrir isso.

## Particionamento dentro do PostgreSQL

No particionamento declarativo (PostgreSQL 10), a tabela pai não guarda linha nenhuma; ela é a regra e o ponto de entrada. As partições são tabelas comuns, cada uma com heap, índices e VACUUM próprios. Há três métodos:

- `RANGE`: cada partição cobre um intervalo semiaberto `[início, fim)`. Datas são o uso clássico.
- `LIST`: cada partição recebe uma lista explícita de valores (país, região, tipo de cliente).
- `HASH` (PostgreSQL 11): a partição é escolhida por `hash(chave) % MODULUS == REMAINDER`.

Uma partição `DEFAULT` pode recolher as linhas que não se encaixam em nenhuma outra. Sem ela, inserir uma leitura de 2027 numa tabela que só tem partições até 2026 resulta em `ERROR: no partition of relation "leituras" found for row`, que é a forma do banco dizer que ninguém criou o mês de janeiro.

O ganho principal é o **partition pruning**: o planner compara o `WHERE` com os limites de cada partição e descarta as que não podem conter linhas. Desde o PostgreSQL 11, isso também acontece na execução, quando o valor só aparece ali (parâmetro de prepared statement, `now()`); o `EXPLAIN ANALYZE` mostra `Subplans Removed: N`, as partições que nem foram abertas.

O segundo ganho resolveria a segunda-feira: apagar um mês vira remover uma tabela, sem versões mortas, sem VACUUM e quase sem WAL.

### Na prática: leituras por mês

```sql
CREATE TABLE leituras (
    geladeira_id bigint      NOT NULL,
    medido_em    timestamptz NOT NULL,
    temperatura  numeric(4,1) NOT NULL,
    PRIMARY KEY (geladeira_id, medido_em)
) PARTITION BY RANGE (medido_em);

CREATE TABLE leituras_2026_09 PARTITION OF leituras
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE leituras_2026_10 PARTITION OF leituras
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');

CREATE INDEX ON leituras (geladeira_id, medido_em);
```

O índice criado na tabela pai é replicado em cada partição, inclusive nas futuras. A chave primária inclui `medido_em` por obrigação: o PostgreSQL não tem índice global, e cada índice só garante unicidade dentro da própria partição. A versão com `PRIMARY KEY (id)` produz isto:

```text
ERROR:  unique constraint on partitioned table must include all partitioning columns
DETAIL:  PRIMARY KEY constraint on table "leituras" lacks column "medido_em" which is part of the partition key.
```

Com a tabela certa, uma consulta de setembro toca só setembro:

```sql
EXPLAIN (COSTS OFF)
SELECT avg(temperatura) FROM leituras
WHERE geladeira_id = 4242
  AND medido_em >= '2026-09-01' AND medido_em < '2026-10-01';
```

```text
                                       QUERY PLAN
------------------------------------------------------------------------------------------
 Aggregate
   ->  Index Scan using leituras_2026_09_geladeira_id_medido_em_idx on leituras_2026_09 leituras
         Index Cond: ((geladeira_id = 4242) AND (medido_em >= '2026-09-01 00:00:00-03'::timestamp with time zone) AND (medido_em < '2026-10-01 00:00:00-03'::timestamp with time zone))
```

Outubro nem foi consultado. Sem o filtro de data, o plano ganha um `Append` com um scan por partição: com 36 meses guardados, a consulta continua correta e 36 vezes mais trabalhosa.

O expurgo vira duas linhas:

```sql
ALTER TABLE leituras DETACH PARTITION leituras_2026_06 CONCURRENTLY;
DROP TABLE leituras_2026_06;
```

`DETACH ... CONCURRENTLY` (PostgreSQL 14) solta a partição sem bloquear a tabela pai; não roda dentro de transação e é recusado se houver partição `DEFAULT`. As 30 horas do domingo viram segundos, quase todos esperando transações antigas terminarem.

> **Armadilha:** partição demais também cobra. A documentação do PostgreSQL diz que o planner lida bem com até alguns milhares de partições, desde que as consultas típicas descartem quase todas. Particionar por hora e guardar cinco anos dá 43.800 partições, e cada consulta sem filtro de tempo planeja um `Append` com todas elas.

## Dividindo entre máquinas: por faixa ou por hash

Quando os dados ou as escritas passam do que um servidor aguenta, as partições vão para máquinas diferentes, e alguém acima do banco precisa responder, a cada requisição, "em que máquina está a chave `k`?".

### Por faixa

Cada shard guarda um intervalo contíguo de chaves, com limites que se ajustam aos dados. Quando uma faixa cresce demais, ela é dividida em duas (*split*), e metade pode mudar de máquina. HBase, Bigtable, CockroachDB e o sharding por faixa do MongoDB seguem esse desenho. A vantagem é a ordem: uma consulta por intervalo visita só os shards cujas faixas cruzam o intervalo.

O custo aparece com chaves monotônicas. Com timestamp, sequência ou UUIDv7, toda escrita nova cai no último shard. Você comprou 16 servidores e 15 deles assistem enquanto o décimo sexto recebe 100% dos `INSERT`s. Quando ele faz split, a metade nova continua sendo a última, e o problema só muda de endereço.

### Por hash, e o problema do módulo

Aplicar um hash à chave antes de distribuir acaba com a monotonicidade: `geladeira-1` e `geladeira-2` caem em lugares sem relação. A função precisa ser estável entre processos (o `hash()` embutido do Python muda a cada processo por causa do `PYTHONHASHSEED`). O preço é perder a ordem: consulta por intervalo pergunta a todos os shards.

A forma ingênua é `hash(chave) % N`, que funciona perfeitamente até o dia em que `N` muda. Com 100 mil IDs e um quinto shard entrando num cluster de quatro:

```python
ids = range(100_000)

movidos = sum(i % 4 != i % 5 for i in ids)
print(f"mod N: {movidos / len(ids):.1%} das chaves mudaram de shard")
```

```text
mod N: 80.0% das chaves mudaram de shard
```

Uma chave só fica parada se `i % 4 == i % 5`, o que acontece com 4 a cada 20 números. Passar de `N` para `N + 1` move `N / (N + 1)` das chaves. Você queria 25% a mais de capacidade e ganhou, de brinde, uma migração de 80% dos dados, ao vivo, com o cluster cheio.

## Consistent hashing, ou como mudar de ideia movendo pouco

O **consistent hashing** (Karger e colegas, 1997) trata o espaço de saída do hash (0 a 2^64 − 1) como um anel. Cada nó ocupa uma posição, dada pelo hash do seu nome, e cada chave pertence ao primeiro nó no sentido horário a partir da posição dela. Um nó que entra assume só as chaves entre o nó anterior e ele, todas tiradas de um vizinho; um nó que sai entrega as suas ao próximo. Em média, o nó novo leva `1/(N+1)` das chaves, o mínimo para ele ter a sua parte.

Um anel de brinquedo, com 100 posições escolhidas à mão para a conta caber na página:

```python
import bisect

TAMANHO_DO_ANEL = 100  # anel de brinquedo; um anel real tem 2**64 posições


def dono(posicao: int, nos: dict[str, int]) -> str:
    """Primeiro nó no sentido horário a partir da posição da chave."""
    ordenados = sorted(nos.items(), key=lambda item: item[1])
    posicoes = [p for _, p in ordenados]
    i = bisect.bisect_left(posicoes, posicao) % len(ordenados)
    return ordenados[i][0]


nos = {"shard-a": 10, "shard-b": 35, "shard-c": 60, "shard-d": 85}
com_novo = nos | {"shard-e": 48}

ids = range(100_000)
origens = [
    dono(i % TAMANHO_DO_ANEL, nos)
    for i in ids
    if dono(i % TAMANHO_DO_ANEL, nos) != dono(i % TAMANHO_DO_ANEL, com_novo)
]
print(f"anel: {len(origens) / len(ids):.1%} das chaves mudaram de shard")
print(f"vindas de: {sorted(set(origens))}")
```

```text
anel: 13.0% das chaves mudaram de shard
vindas de: ['shard-c']
```

O `shard-e` ficou com as posições de 36 a 48, todas antes do `shard-c`; os outros três nem perceberam. A saída também mostra o defeito do anel simples: o novo nó aliviou um vizinho só e terminou com metade da carga dos outros. Com posições aleatórias de verdade, os arcos saem desiguais, e com quatro nós um deles pode facilmente ter o dobro do arco de outro.

A correção são os **nós virtuais** (*vnodes*): cada nó físico ocupa muitas posições no anel, a variância cai e um nó novo pega um pouco de cada vizinho. O Dynamo, da Amazon (2007), usou esse esquema; o Cassandra usa `num_tokens`, com padrão 16 desde a versão 4.0. Existem variantes com outros custos, como o rendezvous hashing e o jump consistent hash (Lamping e Veach, 2014), que não usa memória mas só adiciona ou remove nós no fim da lista.

### Muitos shards lógicos, poucas máquinas

Outra saída é nunca mudar o `N`: criar, no início, muito mais partições lógicas do que máquinas e manter um mapa de partição para máquina. Para crescer, movem-se partições inteiras.

O Redis Cluster usa 16.384 *hash slots* (`CRC16(chave) mod 16384`); um cliente que pergunta ao nó errado recebe `MOVED` com o endereço certo. O Instagram, em 2012, descreveu milhares de shards lógicos (schemas do PostgreSQL) em poucos servidores, com o ID do shard embutido em 13 bits de cada ID. A Notion, em 2021, dividiu seu PostgreSQL em 480 shards lógicos sobre 32 bancos, 15 por banco, pelo workspace; 480 tem muitos divisores, e em 2023 a conta virou 96 bancos com 5 shards cada.

O roteador fica pequeno:

```python
SHARDS_LOGICOS = 480


def shard_logico(workspace_id: int) -> int:
    return workspace_id % SHARDS_LOGICOS  # nunca muda depois do primeiro deploy


def banco_fisico(workspace_id: int, shards_por_banco: int) -> str:
    return f"pg-{shard_logico(workspace_id) // shards_por_banco:02d}"


for ws in (1_234_567, 98_765):
    print(ws, shard_logico(ws), banco_fisico(ws, 15), "->", banco_fisico(ws, 5))
```

```text
1234567 7 pg-00 -> pg-01
98765 365 pg-24 -> pg-73
```

O módulo direto só distribui bem porque os IDs são sequenciais; com outros padrões, aplica-se antes um hash estável. O shard lógico 365 é o 365 para sempre; muda só o mapa para o banco, que pode morar em configuração, numa tabela ou num serviço de diretório. O diretório por chave é o mais flexível (um cliente gigante pode ganhar uma máquina só dele) e acrescenta um componente que precisa estar disponível e coerente em todos os roteadores.

## Hot spots, ou a Sorveteria Pinguim Feliz

Hash distribui chaves de forma uniforme. Carga é outra história. Com `cliente_id` como chave, os 9 mil freezers da Pinguim Feliz caem no mesmo shard, que recebe 18% das escritas enquanto os outros 31 dividem o resto. O hash cumpriu o prometido; a premissa de que as chaves pesavam parecido é que falhou.

Isso é um **hot spot**: um shard com uma fatia desproporcional do tráfego. As causas comuns são uma chave popular demais (o cliente gigante, a celebridade com 80 milhões de seguidores), uma chave monotônica num esquema por faixa ou poucos valores distintos. As saídas conhecidas:

1. **Chave mais granular.** Particionar por `geladeira_id` espalha a Pinguim Feliz por todos os shards, e "todas as leituras do cliente X" passa a consultar todos eles.
2. **Sal na chave quente.** Um sufixo aleatório de `0` a `7` (`pinguim#0` ... `pinguim#7`) divide as escritas por 8, e toda leitura consulta as 8 subchaves. A aplicação precisa saber quais chaves são quentes.
3. **Isolamento.** Com diretório ou shards lógicos, a Pinguim Feliz ganha um shard só dela. Ela provavelmente vai chamar isso de benefício contratual.

## Consultas que atravessam shards

Consulta com a chave de partição no filtro vai a um shard. Sem ela, vai a todos: o roteador dispara a pergunta para cada shard e junta as respostas (*scatter-gather*). A latência vira a do shard mais lento: se cada um passa do próprio p99 em 1% das vezes, a consulta com 32 shards sofre isso em `1 − 0,99^32 ≈ 27,5%` das vezes (o capítulo 6 trata de fan-out e cauda).

Índices secundários vêm em duas formas. O **índice local** indexa só as linhas do shard: escrever é barato, buscar por outro campo vira scatter-gather. O **índice global** é particionado pelo valor indexado: a busca vai a um lugar só, e a escrita atualiza shards diferentes, em geral de forma assíncrona. Os índices secundários globais do DynamoDB são eventualmente consistentes: você grava, consulta pelo índice e a linha ainda não chegou.

O resto do que o banco fazia de graça também ganha preço:

- `JOIN` entre chaves diferentes vira tráfego de rede. A técnica usual é a **co-localização**: todas as tabelas particionadas por `tenant_id`, com joins dentro do tenant num shard só. O Citus, extensão do PostgreSQL, faz isso e replica tabelas pequenas em todos os nós (*reference tables*).
- Transação entre shards exige two-phase commit, com seus bloqueios (capítulo 22), ou não existe.
- `UNIQUE` fora da chave de partição exige uma tabela de unicidade particionada pela própria coluna.
- Sequências deixam de ser globais; IDs passam a ser gerados sem coordenação (capítulo 7).

O Redis Cluster deixa a regra explícita: comando com chaves em slots diferentes falha com `CROSSSLOT Keys in request don't hash to the same slot`. As *hash tags* resolvem, porque só o trecho entre chaves conta para o hash: `{pedido:42}:itens` e `{pedido:42}:total` caem no mesmo slot. O nome da chave vira decisão de topologia, coisa que pouca gente espera de uma string.

## Rebalanceamento sem desligar nada

Mover uma partição com tráfego entrando segue quase sempre a mesma sequência:

1. Copiar um snapshot da partição para o destino.
2. Aplicar no destino as mudanças feitas na origem desde o snapshot (replicação lógica ou CDC).
3. Com atraso perto de zero, bloquear as escritas da partição por um instante, aplicar o resto e trocar o roteamento.
4. Liberar as escritas no destino e apagar a cópia antiga depois de um período de segurança.

Vitess, Citus, MongoDB e CockroachDB automatizam variações disso. O cliente precisa lidar com a troca de endereço: refazer a consulta após um `MOVED` ou recarregar o mapa de roteamento.

Mover dados gasta disco, rede e CPU justamente nos nós que você queria aliviar. Daí a armadilha do rebalanceamento automático: um nó lento por excesso de carga parece morto, o sistema move as partições dele, a movimentação sobrecarrega os vizinhos, que também parecem mortos, e o cluster passa a tarde se mudando. Por isso muitos sistemas limitam a vazão da cópia e deixam a decisão de mover para um humano.

## Escolhendo a chave de partição

Trocar a chave depois é reescrever todos os dados. Os critérios são mensuráveis:

- **Presença nas consultas.** Uma chave que aparece em 3% das consultas transforma os outros 97% em scatter-gather.
- **Cardinalidade.** `status` com quatro valores nunca vai ocupar 32 máquinas.
- **Distribuição de frequência.** Muitos valores distintos não bastam se um deles concentra 18% das linhas (olá, Pinguim Feliz).
- **Monotonicidade.** Chaves crescentes concentram escritas num esquema por faixa.
- **Imutabilidade.** Mudar a chave de uma linha é movê-la de shard, ou seja, uma transação distribuída.
- **Tamanho máximo por valor.** O Discord, em 2017, particionava mensagens no Cassandra por `(channel_id, bucket)`, com buckets de 10 dias, para manter cada partição abaixo de 100 MB.

Na tabela de leituras, as duas escolhas convivem: `medido_em` para particionar dentro de cada banco (o expurgo vira `DROP TABLE`) e `geladeira_id` para shardear entre bancos, porque aparece em quase toda consulta e espalha a Pinguim Feliz.

## Propriedades e custos

| Estratégia | Consulta por intervalo | Distribuição de escritas | Chaves movidas ao adicionar um nó | Estado extra |
|---|---|---|---|---|
| Faixa | Visita só os shards da faixa | Concentra em chave monotônica | Só a faixa dividida | Mapa de faixas |
| `hash % N` | Todos os shards | Uniforme | `N/(N+1)` (80% de 4 para 5) | Nenhum |
| Consistent hashing com vnodes | Todos os shards | Uniforme | ~`1/(N+1)` | Posições no anel |
| Partições lógicas fixas | Todos os shards | Uniforme | Partições inteiras escolhidas | Mapa partição → nó |
| Diretório por chave | Depende do mapa | Controlável por chave | Qualquer subconjunto | Serviço de diretório |

Particionamento no mesmo servidor mantém transações ACID, joins locais e um banco só para operar, com a capacidade de uma máquina. Sharding soma a capacidade das máquinas e cobra em cada consulta, transação e restrição que antes vinham inclusas, e cada upgrade de versão vira N upgrades.

## Armadilhas e casos reais

> **Na vida real:** em 4 de outubro de 2010, o Foursquare ficou horas fora do ar. Os check-ins estavam num MongoDB com dois shards, particionados por usuário, e um shard chegou a cerca de 66 GB contra cerca de 50 GB do outro. O maior passou da memória da máquina e passou a ler do disco. Um terceiro shard foi adicionado, mas os documentos movidos eram pequenos e espalhados pelas páginas da origem, que continuaram ocupadas; a memória não caiu, e compactar o shard original levou cerca de quatro horas.

**Sharding cedo demais.** O sistema da introdução escrevia 833 linhas por segundo, que um PostgreSQL num servidor grande aguenta com folga. O que doía era o `DELETE`. Shardear para resolver um expurgo troca um problema de 30 horas por um problema permanente.

**Sharding tarde demais.** Copiar terabytes compete com a carga que já não cabia. A Notion relatou que shardeou porque o autovacuum não acompanhava e o wraparound de IDs de transação se aproximava.

**Esquecer de criar as partições.** Sem partição `DEFAULT`, o primeiro `INSERT` do dia 1 às 00h00 falha. Com `DEFAULT`, ele funciona, até alguém criar a partição do mês e o PostgreSQL recusar porque a `DEFAULT` já tem linhas desse intervalo. A extensão `pg_partman` cria as partições com antecedência.

**Unicidade que não existe.** Um `UNIQUE (email)` local garante que não há e-mail repetido dentro de cada shard, uma promessa bem menor do que parece.

## Resumo

- Particionamento divide uma tabela pela chave de partição no mesmo servidor; sharding, entre servidores.
- PostgreSQL: `RANGE`, `LIST`, `HASH`, pruning no planejamento e na execução; restrição única inclui a chave, porque não há índice global.
- Expurgo por partição: `DETACH ... CONCURRENTLY` e `DROP TABLE`.
- Faixa preserva a ordem e concentra escritas monotônicas; hash espalha escritas e espalha consultas por intervalo.
- `hash % N` move `N/(N+1)` das chaves; consistent hashing com vnodes, cerca de `1/(N+1)`; partições lógicas fixas movem partições inteiras.
- Hot spot: chave mais granular, sal ou isolamento.
- Joins, transações, unicidade e sequências ficam caros entre shards; co-localização reduz o custo.
- A chave se escolhe por presença nas consultas, cardinalidade, distribuição, monotonicidade, imutabilidade e tamanho por valor.

## Referências

- PostgreSQL, *Table Partitioning*: https://www.postgresql.org/docs/current/ddl-partitioning.html
- Karger, D. et al., *Consistent Hashing and Random Trees* (STOC 1997): https://dl.acm.org/doi/10.1145/258533.258660
- DeCandia, G. et al., *Dynamo: Amazon's Highly Available Key-value Store* (SOSP 2007): https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf
- Lamping, J.; Veach, E., *A Fast, Minimal Memory, Consistent Hash Algorithm* (2014): https://arxiv.org/abs/1406.2294
- Redis, *Cluster specification*: https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/
- Instagram Engineering, *Sharding & IDs at Instagram* (2012): https://instagram-engineering.com/sharding-ids-at-instagram-1cf5a71e5a5c
- Notion, *Herding elephants: lessons learned from sharding Postgres at Notion* (2021): https://www.notion.com/blog/sharding-postgres-at-notion
- Notion, *Building and scaling Notion's data lake* (resharding para 96 bancos): https://www.notion.com/blog/building-and-scaling-notions-data-lake
- Discord, *How Discord Stores Billions of Messages* (2017): https://discord.com/blog/how-discord-stores-billions-of-messages
- Horowitz, E., *Foursquare outage post mortem* (lista mongodb-user, 2010): https://groups.google.com/group/mongodb-user/browse_thread/thread/528a94f287e9d77e
- InfoQ, *Foursquare's MongoDB Outage* (2010): https://www.infoq.com/news/2010/10/4square_mongodb_outage/
