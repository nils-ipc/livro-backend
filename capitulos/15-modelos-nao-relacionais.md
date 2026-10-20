# Modelos não relacionais

## Só uma perguntinha

Segunda-feira, 9h07, chega a mensagem do Otávio, do produto: "só uma perguntinha: dá para listar as reservas de um usuário, da mais recente para a mais antiga?". A plataforma de reservas de quadras de padel guarda tudo num banco chave-valor gerenciado desde o primeiro dia, porque "ele escala sozinho". A chave de cada item é o `reserva_id`, um UUID. São 120 milhões de reservas.

O banco escala sozinho mesmo. O que ele não faz é responder perguntas que ninguém combinou com ele antes. Para achar as reservas da usuária `u-4417`, a única operação disponível é ler a tabela inteira e filtrar no caminho. O *scan* leu 38 GB, levou 41 minutos, consumiu a capacidade de leitura provisionada da semana e devolveu 14 reservas. Duas delas eram da própria Ana, a dona do `u-4417`, reclamando que o aplicativo estava lento.

Na terça veio outra perguntinha. O Otávio é muito curioso.

Um banco relacional deixa você modelar os dados primeiro e descobrir as perguntas depois, porque tem um otimizador que monta um plano para qualquer `SELECT`. A maioria dos não relacionais inverte essa ordem. A pergunta, então: o que cada modelo não relacional sabe fazer de verdade, e como se modela um banco quando as perguntas precisam vir antes dos dados?

## O que se perde junto com o planner

Num banco relacional, o *planner* escolhe índice, tipo de join e ordem (capítulo 9), e uma consulta nova exige, no pior caso, um índice. Os modelos não relacionais trocam esse conforto por distribuição horizontal com custo previsível, um formato mais próximo do objeto da aplicação ou uma travessia que o SQL faz mal. O preço é o caminho de acesso gravado no layout físico. A chave que você escolhe determina em que servidor o dado fica (o capítulo 14 explica chaves de partição e *sharding*) e em que ordem ele é guardado dentro desse servidor. Consultas que seguem esse caminho custam milissegundos. Consultas que não seguem viram scan, e scan num banco distribuído é ler todos os servidores, educadamente, um de cada vez. O rótulo "NoSQL" ajuda pouco: agrupa bancos com quase nada em comum além de não serem PostgreSQL, e vários têm linguagens parecidíssimas com SQL.

## Chave-valor, o banco que só sabe uma coisa

O modelo chave-valor tem duas operações: `get(chave)` e `put(chave, valor)`. O valor é opaco para o banco: uma sequência de bytes que ele guarda e devolve sem nunca olhar dentro. Por isso não há consulta por atributo do valor, não há índice secundário no modelo puro e não há join. Em troca, cada operação é uma busca numa tabela hash (ou numa estrutura ordenada) e o custo independe do tamanho do banco.

O Redis (e o Valkey, seu fork) estica esse modelo com valores tipados: listas, conjuntos, hashes, *sorted sets*, *streams*. Cada tipo traz operações atômicas próprias, executadas no servidor. Um `INCR` incrementa um contador sem o ciclo ler, somar e gravar do lado do cliente, que é exatamente onde nascem as condições de corrida do capítulo 5.

```bash
redis-cli INCR quadra:12:reservas:2026-10-19
redis-cli ZADD ranking:jogadores 1840 u-4417 1795 u-0032 2210 u-9001
redis-cli ZREVRANGE ranking:jogadores 0 1 WITHSCORES
```

```text
(integer) 1
(integer) 3
1) "u-9001"
2) "2210"
3) "u-4417"
4) "1840"
```

O sorted set é uma consulta por faixa disfarçada de tipo de dado: os membros ficam ordenados pela pontuação, e buscar os N primeiros custa O(log N + M). O `u-9001` está ganhando de todo mundo, como sempre acontece com quem tem esse número.

A garantia de consistência depende da implementação. No Redis, cada comando é atômico porque um único thread executa os comandos. A replicação é assíncrona: o primário responde ao cliente antes de mandar a escrita para a réplica, e um failover nessa janela perde a escrita. O `WAIT` faz o cliente esperar N réplicas, e a própria documentação avisa que isso não torna o Redis fortemente consistente. Com AOF e `appendfsync everysec` (o padrão do AOF), uma queda leva até cerca de um segundo de escritas.

A chave é o índice. `reserva:{id}` responde "me dê a reserva X"; para "reservas do usuário Y", alguém mantém uma segunda estrutura, `usuario:{id}:reservas`, em sincronia. Esse alguém é o seu código, em toda escrita, para sempre.

## Documento, o JSON com endereço fixo

Um banco de documentos guarda registros semiestruturados (JSON ou um formato binário derivado, como o BSON do MongoDB) e, ao contrário do chave-valor, enxerga dentro deles. Dá para consultar por qualquer campo, criar índices secundários em campos aninhados e atualizar só um pedaço do documento.

A unidade que importa é o documento. É nele que a maioria dos bancos desse tipo garante atomicidade de forma barata: uma escrita num documento é atômica, inclusive quando altera vários campos. Isso favorece agregar no mesmo documento o que é lido e alterado junto.

```python
import os
from pymongo import MongoClient

cliente = MongoClient(os.environ["MONGO_URL"])
quadras = cliente.padel.quadras

resultado = quadras.update_one(
    {"_id": "quadra-12", "vagas_terca_19h": {"$gt": 0}},
    {
        "$inc": {"vagas_terca_19h": -1},
        "$push": {"ultimas_reservas": {"$each": ["u-4417"], "$slice": -50}},
    },
)
print(resultado.matched_count, resultado.modified_count)
```

```text
1 1
```

Filtro e decremento são uma operação atômica no servidor; sem vaga, a saída seria `0 0`, sem overbooking. O `$slice: -50` mantém só as 50 reservas mais recentes no array, porque arrays que crescem sem limite são a forma mais popular de descobrir o limite de 16 MB por documento do MongoDB, quase sempre numa sexta à noite.

Daí a regra: embutir o que tem cardinalidade limitada e é lido junto com o pai (endereços de um cliente, itens de um pedido); referenciar o que cresce sem teto ou é compartilhado (todos os comentários de um post viral, o perfil de um autor usado em mil documentos). Embutir é desnormalizar, com os custos de manter cópias que o capítulo 7 descreve.

O MongoDB tem joins (`$lookup`) e transações multidocumento desde a versão 4.0 (4.2 com sharding), mais caros que o caminho de um documento só e limitados a 60 segundos por padrão. Um modelo que precisa de transação multidocumento em toda requisição costuma ser um modelo relacional que entrou pela porta errada.

As garantias são ajustáveis por operação. O *write concern* diz quantos membros do replica set confirmam a escrita: `w: 1` só o primário, `w: "majority"` a maioria. O padrão passou a ser `majority` no MongoDB 5.0. Com `w: 1`, uma escrita confirmada pode sumir num failover, porque o novo primário eleito nunca a recebeu e a antiga é desfeita (*rollback*) quando o primário original volta. O *read concern* (`local`, `majority`, `linearizable`, `snapshot`) controla o que a leitura enxerga.

## Colunas largas e colunar, dois bichos com o mesmo sobrenome

"Banco colunar" designa duas coisas bem diferentes, e a confusão já rendeu muita arquitetura curiosa.

### Wide-column

O modelo *wide-column* (Bigtable, HBase, Cassandra, ScyllaDB) organiza os dados em partições. Cada linha tem uma chave de partição, que decide o nó por hash, e colunas de clustering, que decidem a ordem das linhas dentro da partição. Uma partição é, fisicamente, uma lista ordenada guardada junta no disco. Por isso as consultas baratas são exatamente duas: ler uma partição inteira, ou uma faixa contígua dela.

Esse é o modelo que teria salvado a segunda-feira do Otávio:

```sql
CREATE TABLE reservas_por_usuario (
    usuario_id text,
    inicio     timestamp,
    reserva_id uuid,
    quadra_id  text,
    status     text,
    PRIMARY KEY ((usuario_id), inicio, reserva_id)
) WITH CLUSTERING ORDER BY (inicio DESC, reserva_id ASC);

SELECT inicio, quadra_id, status
  FROM reservas_por_usuario
 WHERE usuario_id = 'u-4417'
 LIMIT 3;
```

```text
 inicio                          | quadra_id | status
---------------------------------+-----------+------------
 2026-10-21 19:00:00.000000+0000 | quadra-12 | confirmada
 2026-10-14 19:00:00.000000+0000 | quadra-12 |  cancelada
 2026-10-07 20:00:00.000000+0000 | quadra-03 | confirmada

(3 rows)
```

Uma partição, lida em ordem, sem ordenação em memória. Agora a perguntinha de terça: "quais reservas foram canceladas?".

```sql
SELECT * FROM reservas_por_usuario WHERE status = 'cancelada';
```

```text
InvalidRequest: Error from server: code=2200 [Invalid query] message="Cannot execute this query as it might involve data filtering and thus may have unpredictable performance. If you want to execute this query despite the performance unpredictability, use ALLOW FILTERING"
```

O Cassandra recusa, com franqueza rara em software. O `ALLOW FILTERING` existe e faz o scan de todos os nós. Colocá-lo numa consulta de produção é assinar um termo de responsabilidade escrito pelo próprio banco. A resposta do modelo é outra tabela, `reservas_canceladas_por_dia`, com a chave certa para essa pergunta, e o código passa a gravar nas duas. Uma tabela por consulta é o padrão normal desse modelo.

As escritas vão para uma LSM-tree (memtable, commit log, SSTables imutáveis compactadas depois). Apagar é escrever um *tombstone*, um marcador de "isto morreu" que só é descartado após `gc_grace_seconds` (dez dias por padrão), para o dado não ressuscitar numa réplica desinformada. Uma leitura que atravessa 1.000 tombstones gera aviso; com 100.000, é abortada. Usar o Cassandra como fila, inserindo e apagando, é o jeito mais rápido de conhecer esses dois números.

A consistência é ajustável por operação com níveis como `ONE` e `QUORUM`, e o capítulo 13 trata da conta `W + R > N`. Para operações condicionais (`INSERT ... IF NOT EXISTS`) existem as *lightweight transactions*, implementadas com Paxos e com algumas idas e voltas de rede a mais por operação.

### Colunar analítico

O outro bicho é o armazenamento colunar analítico (ClickHouse, DuckDB, Parquet, data warehouses gerenciados). O modelo é relacional comum, com tabelas e SQL. O que muda é o layout: cada coluna é gravada separadamente, comprimida e lida só se a consulta pedir. Uma soma de `valor` agrupada por `bairro` numa tabela de 40 colunas lê 2 delas. Valores parecidos lado a lado comprimem muito bem (codificação por dicionário, *run-length*, delta), e a execução vetorizada processa blocos de milhares de valores por instrução.

O custo aparece no outro extremo: buscar uma linha inteira lê um pedaço de cada coluna, e atualizar é caro (no ClickHouse, `ALTER TABLE ... UPDATE` é uma mutação assíncrona que reescreve as partes afetadas). Ótimo para OLAP, "receita por bairro por mês"; péssimo para OLTP, "marcar a reserva 812 como paga". Um banco colunar analítico atendendo checkout é uma escolha que costuma durar até o primeiro pico de vendas.

## Grafo, quando o relacionamento é o dado

Um banco de grafo de propriedades (Neo4j, Memgraph, Amazon Neptune como exemplo gerenciado) guarda nós e arestas, ambos com rótulos e propriedades. A diferença mecânica está em como uma aresta é seguida. No Neo4j, cada nó guarda ponteiros diretos para seus relacionamentos (*index-free adjacency*): ir de um nó aos vizinhos custa proporcional ao número de vizinhos, sem consultar um índice global. Num banco relacional, cada salto é um join que passa por um índice B-tree, com custo logarítmico no tamanho da tabela, multiplicado pelo número de saltos.

```text
MATCH (eu:Jogador {id: 'u-4417'})-[:JOGOU_COM]->(:Jogador)-[:JOGOU_COM]->(sugestao:Jogador)
WHERE sugestao <> eu AND NOT (eu)-[:JOGOU_COM]->(sugestao)
RETURN sugestao.nome, count(*) AS em_comum
ORDER BY em_comum DESC
LIMIT 3;
```

```text
╒═══════════════╤══════════╕
│sugestao.nome  │em_comum  │
╞═══════════════╪══════════╡
│"Bruna"        │7         │
│"Caio"         │5         │
│"Dalva"        │5         │
╘═══════════════╧══════════╛
```

Isso é Cypher, base do padrão ISO GQL (ISO/IEC 39075:2024). A consulta pede "parceiros de parceiros com quem ainda não joguei". Em SQL seriam dois self-joins e um `NOT EXISTS`; com caminhos de tamanho variável (`-[:JOGOU_COM*1..5]->`) vira uma CTE recursiva que o planner trata com respeito e algum medo.

O grafo faz mal agregações globais ("reservas por mês") e particionamento: cortar um grafo sem que as travessias cruzem a rede o tempo todo é NP-difícil no caso geral, então muitos bancos de grafo mantêm o grafo inteiro em cada réplica. A consistência costuma ser a do líder único com réplicas, com mecanismos como os *bookmarks* do Neo4j para ler as próprias escritas numa réplica.

## Séries temporais, o banco que só olha para trás

Uma série temporal é uma sequência de pontos `(timestamp, valor)` identificada por uma métrica e um conjunto de rótulos: `temperatura{quadra="12", sensor="teto"}`. A carga escreve em ordem de tempo, quase nunca altera, lê por faixa e agrega em janelas.

Os bancos especializados (Prometheus, InfluxDB, TimescaleDB como extensão do PostgreSQL) aproveitam esse perfil. Particionam por tempo, o que torna o expurgo um `DROP` de pedaço inteiro, e comprimem de forma agressiva. O Gorilla, do Facebook, guarda timestamps como *delta-of-delta*, já que pontos coletados a cada 60 segundos têm delta-of-delta zero, que cabe em 1 bit, e valores como XOR com o anterior, que para métricas estáveis é quase todo zero. O artigo relata média de 1,37 byte por ponto, contra 16 bytes do par cru.

```sql
SELECT time_bucket('1 hour', momento) AS hora,
       avg(ocupacao) AS ocupacao_media
  FROM ocupacao_quadras
 WHERE quadra_id = 'quadra-12'
   AND momento >= '2026-10-18 18:00' AND momento < '2026-10-18 22:00'
 GROUP BY hora
 ORDER BY hora;
```

```text
          hora          | ocupacao_media
------------------------+----------------
 2026-10-18 18:00:00+00 |           0.50
 2026-10-18 19:00:00+00 |           1.00
 2026-10-18 20:00:00+00 |           1.00
 2026-10-18 21:00:00+00 |           0.75
```

O `time_bucket` é do TimescaleDB, e o resto é PostgreSQL comum, com transações ACID e tudo o que vem junto. Os bancos de séries temporais "nativos" costumam relaxar essas garantias: o Prometheus, por exemplo, é um processo único com armazenamento local e não replica nada; alta disponibilidade é rodar dois iguais coletando os mesmos alvos.

O inimigo número um desse modelo é a cardinalidade, o número de combinações distintas de rótulos. Cada combinação é uma série nova, com índice e memória próprios. Colocar `usuario_id` como rótulo num sistema com dois milhões de usuários cria dois milhões de séries por métrica, e o banco morre de um jeito muito bem instrumentado. O capítulo 38 trata disso do ponto de vista das métricas.

## Modelar começando pelas perguntas

O método que funciona para chave-valor, documento e wide-column é o mesmo, e é o inverso do que o capítulo 7 ensina para o relacional. Primeiro se listam os padrões de acesso, com a frequência e a latência esperada de cada um. Depois se desenha a chave que torna cada padrão uma leitura de partição ou uma faixa contígua.

| # | Padrão de acesso | Frequência | Chave que atende |
|---|------------------|------------|------------------|
| 1 | Reserva por id | 900/s | PK `RESERVA#{id}` |
| 2 | Reservas de um usuário, recentes primeiro | 300/s | PK `USUARIO#{id}`, SK `RESERVA#{inicio}` |
| 3 | Agenda de uma quadra num dia | 1.200/s | PK `QUADRA#{id}#{data}`, SK `{hora}` |
| 4 | Cancelamentos por dia (relatório) | 1/h | exportação para o colunar |

A coluna de frequência faz parte do modelo. O padrão 3 é o mais quente, então a chave inclui a data para que a partição da quadra 12 não acumule cinco anos de agenda nem vire *hot spot*. O padrão 4 roda uma vez por hora e não merece chave nenhuma no banco transacional: vai para um armazenamento analítico alimentado por CDC (o capítulo 22 explica *change data capture*).

Os prefixos `RESERVA#` e `USUARIO#` vêm do *single-table design*, comum no DynamoDB: entidades diferentes dividem a tabela, e uma consulta por PK traz o usuário e as reservas dele numa leitura só. Um índice secundário global resolveria o padrão 2 sem duplicar dados no código, ao preço de ser atualizado de forma assíncrona (capítulo 14).

> **Dica:** antes de escolher o banco, escreva a tabela de padrões de acesso. Se a lista tem dois itens e o Otávio ainda não foi contratado, qualquer modelo serve. Se ela muda toda semana, o argumento técnico mais forte a favor de um relacional com otimizador está nessa própria lista.

## Propriedades e custos

| Modelo | Acesso barato | Acesso caro ou ausente | Atomicidade típica | Escala horizontal |
|--------|---------------|------------------------|--------------------|-------------------|
| Chave-valor | get/put por chave, faixa em tipos ordenados | qualquer coisa por atributo do valor | por chave ou comando | partição por hash da chave |
| Documento | documento por id, consulta por campo indexado | joins, transações entre muitos documentos | por documento | sharding por chave escolhida |
| Wide-column | partição, faixa de clustering | filtro fora da chave, apagar muito | por partição (LWT com Paxos) | nativa, sem líder |
| Colunar analítico | agregação sobre poucas colunas e muitas linhas | linha individual, update frequente | por bloco inserido | por cluster, com shards |
| Grafo | travessia de vizinhança, caminhos | agregação global, particionamento | transação ACID no líder | réplicas de leitura |
| Séries temporais | faixa de tempo, janelas, expurgo | update, alta cardinalidade de rótulos | varia (ACID no TimescaleDB, nenhuma no Prometheus) | particionamento por tempo |

Latência previsível por chave em qualquer volume importa quando o padrão de acesso é estável e o volume passa do que um servidor aguenta. Flexibilidade de consulta importa quando as perguntas ainda estão sendo descobertas, o que, em produtos novos, é sempre. E cada modelo novo é mais um sistema com backup, monitoramento e alguém que sabe o que significa aquele alerta às 3h. O PostgreSQL cobre parte dessas cargas com `jsonb` e índices GIN (capítulo 8), extensões de séries temporais e CTEs recursivas, sem um segundo banco na escala de plantão.

## Armadilhas e casos reais

> **Armadilha:** "schemaless" significa que o banco não valida o schema; a aplicação continua tendo um, só que espalhado pelo código. Depois de três anos, o campo `telefone` aparece como string, como número, como array e, num documento de 2023, como `"ver com o Otávio"`. Os bancos de documentos oferecem validação (o MongoDB aceita `$jsonSchema` na coleção) justamente porque todo mundo acaba precisando dela.

> **Armadilha:** contar com consistência forte num índice secundário que é eventual. A escrita é confirmada, a tela seguinte consulta pelo índice e o item não aparece. O usuário clica em "reservar" de novo, e agora a quadra tem duas reservas iguais. Chave de idempotência (capítulo 20) e leitura pela chave primária logo após a escrita resolvem os dois sintomas.

> **Na vida real:** em janeiro de 2017, dezenas de milhares de instâncias de MongoDB expostas na internet sem autenticação foram apagadas por atacantes que deixavam um pedido de resgate no lugar dos dados. Versões antigas do MongoDB escutavam em todas as interfaces por padrão; desde a 3.6, o padrão de `bindIp` é `localhost`. O banco fez exatamente o que foi configurado para fazer, incluindo obedecer a quem não devia.

> **Na vida real:** a análise do Jepsen sobre o MongoDB 4.2.6, publicada em 2020, encontrou violações de snapshot isolation em transações mesmo com os níveis mais fortes de read concern e write concern, além de escritas confirmadas perdidas com os padrões da época. Garantias de consistência são afirmações testáveis, e o padrão de fábrica raramente é o mais forte.

Outro clássico: modelar um documento a partir da tela. A tela de detalhe da quadra mostra as últimas avaliações, então as avaliações vão embutidas no documento da quadra. A quadra 12 fica famosa, acumula 300 mil avaliações e esbarra no limite de 16 MB. Antes disso, cada mudança de vagas já replicava megabytes para alterar um inteiro.
## Resumo

- Sem planner, o caminho de acesso fica gravado no layout físico: as consultas vêm antes do modelo.
- Chave-valor: get e put por chave; Redis tem tipos com operações atômicas e replicação assíncrona.
- Documento: atomicidade barata por documento; embutir o limitado, referenciar o que cresce; limite de 16 MB no MongoDB.
- Wide-column: partição por hash, ordem por clustering, uma tabela por consulta, tombstones ao apagar.
- Colunar analítico: layout por coluna, bom para agregação, ruim para linha individual.
- Grafo: travessia proporcional aos vizinhos, difícil de particionar.
- Séries temporais: compressão por delta e XOR, expurgo por partição, cardinalidade como limite.
- Modelar listando padrões de acesso com frequência, depois desenhar as chaves.

## Referências

- DeCandia et al., "Dynamo: Amazon's Highly Available Key-value Store", SOSP 2007: https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf
- Chang et al., "Bigtable: A Distributed Storage System for Structured Data", OSDI 2006: https://research.google/pubs/bigtable-a-distributed-storage-system-for-structured-data/
- Pelkonen et al., "Gorilla: A Fast, Scalable, In-Memory Time Series Database", VLDB 2015: https://www.vldb.org/pvldb/vol8/p1816-teller.pdf
- Redis, persistência (RDB e AOF): https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/
- MongoDB, write concern: https://www.mongodb.com/docs/manual/reference/write-concern/
- Apache Cassandra, documentação: https://cassandra.apache.org/doc/latest/
- Neo4j, Cypher Manual: https://neo4j.com/docs/cypher-manual/current/
- ISO/IEC 39075:2024, Information technology: Database languages, GQL.
- TimescaleDB: https://github.com/timescale/timescaledb
- ClickHouse, documentação: https://clickhouse.com/docs
- Jepsen, "MongoDB 4.2.6": https://jepsen.io/analyses/mongodb-4.2.6
