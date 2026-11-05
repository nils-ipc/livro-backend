# Particionamento e sharding

A Capinhas Hiper pediu um estorno de R$ 19,90 numa terça às 15h, e o PostgreSQL levou 1,9 segundo para descobrir se ela tinha R$ 19,90. O trigger de débito (capítulos 2 e 3) soma os lançamentos da conta para conferir o saldo, e a Capinhas, a maior vendedora do Bazar, acumula 9 milhões de lançamentos. O `SUM` é index-only, bem planejado, impecável, e lê 9 milhões de entradas de índice com o lock da conta na mão. Cada estorno dela faz fila atrás do anterior. Ser o melhor cliente da Lastro virou uma punição com complexidade O(n).

O resto do ledger vai pelo mesmo caminho. `lancamentos` tem 420 milhões de linhas e recebe 1,5 milhão por dia. O índice do extrato não cabe mais na memória de nenhuma das três cópias (capítulo 23). O VACUUM da tabela leva horas, e cada página que ele congela vira WAL para três réplicas. Um índice novo, mesmo com `CONCURRENTLY` (capítulo 7), seria uma maratona de 420 milhões de linhas.

As propostas chegaram rápido. O fundador quer "uma máquina maior". O Carlos quer apagar os lançamentos com mais de um ano "e guardar num arquivo", o tabelião do capítulo 1 recusou o `DELETE` antes de ele terminar a frase, e o financeiro teve que se sentar.

Como se divide uma tabela que não pode perder uma linha, e o que acontece com uma transferência quando as duas contas moram em máquinas diferentes?

## Particionar sem sair da máquina

**Particionamento** é dividir uma tabela em pedaços menores, as **partições**, dentro do mesmo banco. Para a aplicação, continua uma tabela só: o `INSERT` vai para `lancamentos` e o banco põe a linha na partição certa. O PostgreSQL faz isso de forma declarativa (versão 10+), por três critérios:

- **Faixa** (`RANGE`): um intervalo de valores por partição. O caso clássico é tempo: uma partição por mês.
- **Lista** (`LIST`): valores enumerados, como uma partição por moeda ou por região.
- **Hash** (`HASH`): o resto da divisão do hash da chave, para espalhar linhas sem ordem natural.

```sql
CREATE TABLE lancamentos (...) PARTITION BY RANGE (criado_em);
CREATE TABLE lancamentos_2027_01 PARTITION OF lancamentos
    FOR VALUES FROM ('2027-01-01') TO ('2027-02-01');
-- o limite superior é exclusivo: meia-noite do dia 1º já é do mês seguinte
```

O ganho vem de três mecanismos. O **partition pruning**: uma consulta com `criado_em` no `WHERE` só toca as partições que podem conter a resposta, decidido no planejamento ou, com parâmetros, na execução. A **manutenção local**: VACUUM, `REINDEX` e estatísticas rodam por partição, e uma partição de três anos atrás, congelada uma vez, nunca mais dá trabalho. E a **retenção barata**: `DETACH PARTITION` tira um mês inteiro da tabela mexendo só no catálogo, sem gerar uma linha morta. É o `DELETE` de 45 milhões de linhas que custa o mesmo que renomear uma variável.

As regras que mordem. Cada partição tem os próprios índices, e não existe índice global, então `PRIMARY KEY` e `UNIQUE` precisam incluir a chave de partição: o `id` sozinho deixa de ser garantidamente único, e a chave vira `(id, criado_em)`. Consulta sem a chave de partição no filtro visita todas as partições, uma por uma, e milhares de partições custam tempo de planejamento e memória por sessão (a documentação dedica uma seção de boas práticas a isso). E `CREATE INDEX CONCURRENTLY` não funciona na tabela particionada: cria-se o índice com `ON ONLY` na tabela-mãe, inválido, depois um índice concorrente em cada partição, e cada um é anexado com `ALTER INDEX ... ATTACH PARTITION`. Quando a última partição se anexa, o índice da mãe fica válido sozinho. Um ritual com mais etapas que despacho de importação, mas sem lock de escrita.

Tudo isso continua numa máquina só. Particionar organiza o problema; não aumenta o disco, a memória nem a vazão de escrita do servidor.

## Sharding, ou como transformar um banco em vários problemas independentes

**Sharding** é particionar entre máquinas: cada **shard** é um banco independente, com seu primário e suas réplicas, guardando uma fração das linhas. A escrita escala com o número de shards, e cada um tem memória, disco e WAL próprios. O preço é tudo o que o banco fazia por você entre linhas que agora moram em lugares diferentes: `JOIN`, transação, unicidade, sequência, consistência de leitura. O PostgreSQL de cada shard não sabe que os outros existem. Você ganhou dez bancos e perdeu o único que sabia de tudo.

Alguém precisa saber em qual shard está cada chave. As estratégias:

**Por faixa**: cada shard guarda um intervalo da chave (marketplaces de 1 a 1000 no shard 1, de 1001 a 2000 no shard 2). Consultas por intervalo continuam baratas. O defeito é a chave crescente: com faixas de tempo ou IDs sequenciais, toda escrita nova cai no último shard, e os outros viram museu. Você comprou dez máquinas e uma trabalha.

**Por hash**: `shard = hash(chave) mod N`. Distribuição uniforme, consultas por intervalo viram consulta a todos. E o `mod N` esconde uma bomba: ao passar de N para N + 1 shards, quase toda chave muda de lugar. Uma chave fica onde está só se `h mod N = h mod (N + 1)`; de 10 para 11 shards, cerca de 91% dos dados atravessam a rede. Crescer 10% de capacidade custa uma mudança de casa quase inteira.

**Hashing consistente** (Karger et al., 1997) resolve isso. Chaves e nós são mapeados no mesmo anel de hashes, e cada chave pertence ao primeiro nó encontrado no sentido horário. Um nó novo assume só o arco entre ele e o antecessor: em média, só 1/N das chaves se move. Com poucos nós, os arcos saem desiguais, e um nó pega metade do anel pela mesma sorte que escolhe o plantonista do Natal. Por isso cada nó físico ocupa centenas de posições no anel, os **nós virtuais**, e a carga se espalha. Cassandra usa essa ideia.

**Shards lógicos fixos**: a chave vai para um de muitos baldes fixos (milhares), e uma tabela pequena diz em que máquina mora cada balde. O Redis Cluster usa 16.384 *hash slots*. Rebalancear vira mover baldes inteiros e atualizar a tabela, e nenhuma chave muda de balde. Escolha um número de baldes muito maior do que o número de máquinas que você algum dia terá, porque esse número não muda.

**Diretório**: uma tabela de roteamento mapeia cada chave (ou grupo de chaves) para um shard, com a liberdade de pôr qualquer chave em qualquer lugar. O custo é uma consulta a mais por requisição, que vira cache, e um componente que, se cair, deixa o sistema inteiro sem saber onde está nada.

## Hot spots, ou o hash que espalha as chaves e não a carga

O hash distribui chaves de forma uniforme. A carga por chave, não. Se uma chave recebe 30% do tráfego, o shard dela recebe pelo menos 30%, e não existe função de hash que divida uma chave só. Isso é um **hot spot**: a conta de comissão do capítulo 4, agora com endereço de entrega.

As saídas são as mesmas do capítulo 4, em escala de máquina. Dividir a chave quente em subchaves com sufixo (`comissao#0` a `comissao#15`), que caem em shards diferentes e se somam na leitura: os baldes do capítulo 4, finalmente promovidos a infraestrutura. Ou isolar o cliente gigante num shard dedicado, o que o diretório permite e o hash puro não.

## Entre shards: consultas, transações e mudanças de casa

Consulta que não traz a chave de sharding vira **scatter-gather**: a pergunta vai a todos os shards, cada um responde com o seu pedaço, e a aplicação junta. A latência é a do shard mais lento, e a cauda se multiplica: com 20 shards, cada um com p99 de 50 ms, a chance de uma consulta pegar ao menos um p99 é `1 − 0,99^20`, cerca de 18% (capítulo 14). O "quanto vendemos hoje?" passa a esperar o shard que, naquele segundo, está no meio de um VACUUM. Ordenação e paginação globais pedem que cada shard mande o seu topo e alguém faça o merge, que é o `ORDER BY` do banco reescrito à mão, com bugs novos.

Transação entre shards é transação distribuída (capítulo 18). O 2PC funciona e segura locks durante a rede inteira, travando se o coordenador morrer no meio. A saga troca atomicidade por estados intermediários visíveis e compensações. Unicidade global também sai do banco: um `UNIQUE` vale só dentro do shard, então IDs precisam ser globalmente únicos por construção, como os UUIDv7 que a Lastro usa desde o capítulo 1.

**Rebalancear** é mover dados entre shards com o sistema no ar: copiar o snapshot do balde, acompanhar as mudanças que chegam durante a cópia (replicação lógica, capítulo 23), bloquear escritas daquele balde por segundos, aplicar o resto, atualizar o roteamento e liberar. Cliente com roteamento em cache antigo escreve no lugar errado, então o shard de origem precisa recusar escrita de balde que já não é dele. O fencing token do capítulo 20, de novo, porque todo problema distribuído acaba sendo o mesmo problema com outra roupa.

E a **chave de sharding**: a que mantém cada transação inteira dentro de um shard, aparece em quase toda consulta e espalha a carga. As três quase nunca vêm juntas, e a ordem de prioridade decide a arquitetura.

## Na Lastro: o tempo particiona, o marketplace fragmenta

### Particionamento por mês, já

`lancamentos` passa a ser particionada por faixa mensal de `criado_em`. O extrato e a conciliação filtram por período e são podados; VACUUM e índices passam a trabalhar no mês corrente, cerca de 45 milhões de linhas e 2,3 GB de índice do extrato, que cabem no cache. A chave primária vira `(id, criado_em)`; nada referencia `lancamentos` por FK, então ninguém sente falta do `id` sozinho, já que o `BIGINT` identity continua único por construção.

A migração dos 420 milhões de linhas não move nenhuma linha. A tabela atual vira `lancamentos_legado`, com um `CHECK (criado_em < '2026-12-01')` criado `NOT VALID` e validado sem lock de escrita (capítulo 7) e o índice único `(id, criado_em)` criado concorrentemente. Num deploy, sob `lock_timeout`, a tabela é renomeada, a tabela particionada nasce com o nome antigo e a legada é anexada como a partição `[MINVALUE, '2026-12-01')`. O `CHECK` válido prova a restrição da partição, e o `ATTACH` pula a varredura. Segundos de lock, contra uma cópia de 420 milhões de linhas. Os triggers do tabelião e do débito são recriados na tabela particionada e valem para todas as partições. Um job cria as partições com três meses de antecedência e alerta se faltar a do mês seguinte: lançamento sem partição é `INSERT` recusado, e Pix recusado à meia-noite de virada de mês é o tipo de incidente que vira lenda.

O saldo deixa de somar a história inteira. A cada mês encerrado, um job grava `saldos_fechados (conta_id, mes, saldo)`. O mês está encerrado quando nenhuma transação aberta começou nele: como `criado_em` é o `now()` do início da transação (capítulo 20), o job espera o menor `xact_start` das sessões de cliente em `pg_stat_activity` passar da virada antes de somar. Lançamentos são imutáveis, então o saldo fechado nunca invalida. O trigger de débito passa a somar o último saldo fechado com os lançamentos do mês corrente, e o estorno da Capinhas cai de 1,9 s para 4 ms. É o snapshot do capítulo 21: no event sourcing, snapshot era cache; aqui é cache que nunca envelhece, porque o passado do ledger não muda.

Retenção: dez anos (política da Lastro). Partição com mais que isso sai com `DETACH`, é exportada para armazenamento de arquivo e conferida pela soma antes de apagada. O Carlos ganhou o "guardar num arquivo" dele, com dez anos de atraso.

### Sharding: a chave escolhida, a máquina ainda não

Hoje o primário aguenta: o pico da Black Friday foi de ~800 lançamentos por segundo (200 pagamentos de quatro lançamentos, capítulo 14), bem abaixo do que o teste de carga mediu. O sharding entra quando a vazão de escrita do primário passar de 50% da capacidade medida em teste de carga ou o mês corrente deixar de caber no cache, e o capítulo 29 vai fazer essa conta com o marketplace dez vezes maior. A chave, porém, é escolhida agora, porque toda tabela nova do ledger precisa nascer com ela.

| Chave | Transação de pagamento | Saldo de uma conta | Carga | Problema |
|---|---|---|---|---|
| `conta_id` (hash) | 4 contas em até 4 shards | 1 shard | uniforme | toda venda vira transação distribuída |
| `transacao_id` (hash) | 1 shard | todos os shards | uniforme | todo saldo vira scatter-gather |
| `criado_em` (faixa) | 1 shard | todos os shards | tudo no último | hot spot permanente |
| `marketplace_id` (diretório) | 1 shard | 1 shard | desigual | contas globais e marketplace gigante |

A Lastro escolhe `marketplace_id`, com diretório. Um pagamento com split toca o vendedor, a comissão do marketplace, o liquidante e a receita da Lastro (capítulo 3), e os dois primeiros já pertencem ao marketplace. Os dois últimos são globais, e são resolvidos como o capítulo 4 resolveu as contas quentes: cada shard tem a sua subconta de liquidante e de receita, e o saldo global é a soma das subcontas, conferida pela conciliação contra o extrato do banco liquidante. Assim, todo pagamento, estorno e saque é uma transação local de um shard, com o lock da conta, o serializable e a soma zero do ledger funcionando como hoje.

O diretório, em vez de hash, porque são 41 marketplaces com tamanhos que variam mais de mil vezes: o Bazar e o gigante do capítulo 29 ganham shard próprio, e os pequenos dividem. Hashing consistente seria a escolha com milhões de chaves de tamanho parecido; aqui ele espalharia 41 chaves de forma uniforme e a carga de forma nenhuma. O diretório fica no primário de configuração, em cache em cada processo como as tarifas (capítulo 22), e mudar um marketplace de shard segue o rebalanceamento acima, com época no diretório como fencing.

### A transferência entre shards

O gerente de produto trouxe o primeiro caso: um grupo que é dono de dois marketplaces quer mover saldo de um para o outro. "É só um botão." O botão atravessa shards.

```text
 shard A (marketplace origem)          shard B (marketplace destino)
 T1: débito conta origem      ---->    T2: crédito conta destino
     crédito transito_saida_A              débito transito_entrada_B
     transferência = 'enviada'             (referência = id transferência, UNIQUE)
 falha definitiva em T2 -> C1 no shard A: estorno de T1, 'falhou'
```

É a saga do capítulo 18, orquestrada pelo mesmo agendador com lease (capítulo 20). Cada shard continua com soma zero em cada transação, porque o dinheiro passa pelas contas de trânsito, e T2 é idempotente pela referência única (capítulo 16). Entre T1 e T2, o dinheiro está visivelmente em trânsito, e a conciliação confere que a soma das contas de trânsito de todos os shards é zero ao fim do dia. O 2PC ficou de fora: travaria a conta de origem durante uma ida e volta entre shards e, com o coordenador morto, deixaria o lock pendurado até alguém resolver à mão (capítulo 18).

## Armadilhas e casos reais

> **Na vida real:** a Notion fragmentou o PostgreSQL em 2021 pelo ID do workspace, com 480 shards lógicos distribuídos em 32 bancos físicos. O número 480 foi escolhido por ter muitos divisores, o que permite redistribuir os shards lógicos entre várias quantidades de máquinas sem sobra. Toda tabela com dados de workspace ganhou a chave de partição, e a migração teve escrita dupla, backfill e verificação antes da troca. A matemática do número de baldes é a parte que ninguém pode mudar depois.

> **Armadilha:** chave de partição ausente da consulta. Um relatório sem `criado_em` no `WHERE` visita 120 partições; uma consulta sem `marketplace_id` vira scatter-gather em todos os shards. O plano parece correto e a conta chega na latência.

> **Armadilha:** esquecer de criar a partição do mês seguinte. O PostgreSQL recusa a linha sem destino com `no partition of relation "lancamentos" found for row`, e a virada do ano é a data favorita desse erro, porque o job de partições do Carlos só olhava o mês.

> **Armadilha:** fragmentar cedo. Cada shard é mais um primário com réplicas, failover e backup, e cada consulta global vira código. Particionamento resolve tamanho; sharding resolve vazão de escrita. Sharding para resolver tamanho é comprar dez apartamentos porque o armário encheu.

## Resumo

- Particionamento divide a tabela dentro do banco (faixa, lista, hash): pruning, manutenção por partição e retenção com `DETACH`; PK e UNIQUE incluem a chave de partição.
- Sharding divide entre máquinas e escala a escrita, perdendo `JOIN`, transação e unicidade entre shards.
- Faixa preserva intervalos e concentra chaves crescentes; hash `mod N` move quase tudo ao crescer; hashing consistente move ~1/N; shards lógicos e diretório movem unidades inteiras.
- Hash espalha chaves, não carga: hot spot pede subchaves ou shard dedicado.
- Entre shards: scatter-gather com cauda multiplicada, saga ou 2PC, IDs únicos por construção, rebalanceamento com cópia, replicação e fencing.
- A chave de sharding mantém a transação num shard, aparece nas consultas e espalha a carga.

## A Lastro agora

`lancamentos` é particionada por mês, com a legada anexada sem cópia, partições criadas com três meses de antecedência e retenção de dez anos por `DETACH`. O saldo soma `saldos_fechados` com o mês corrente, e o estorno da Capinhas voltou a 4 ms. O sharding ainda não existe, mas a chave sim: `marketplace_id` por diretório, subcontas de liquidante e receita por shard, transferência entre shards como saga com contas de trânsito. O tabelião aprovou tudo, porque nenhuma linha foi apagada, e cobrou um carimbo por partição.

Com os relatórios na réplica e o ledger organizado, sobrou tempo para o antifraude. O Vigia avisou que precisa de contadores por cartão e por dispositivo em milissegundos, de um grafo de contas ligadas para achar fraude em anel e de agregações que nenhum índice B-tree entrega. O Carlos já criou a tabela `grafo_de_fraude (de, para)` no ledger e escreveu um `WITH RECURSIVE` que, segundo ele, "termina".

## Referências

- PostgreSQL 16, Table Partitioning: https://www.postgresql.org/docs/16/ddl-partitioning.html
- PostgreSQL 16, `ALTER TABLE` (ATTACH e DETACH PARTITION): https://www.postgresql.org/docs/16/sql-altertable.html
- PostgreSQL 16, `CREATE INDEX` (índices em tabelas particionadas): https://www.postgresql.org/docs/16/sql-createindex.html
- Karger et al., "Consistent Hashing and Random Trees", STOC 1997: https://dl.acm.org/doi/10.1145/258533.258660
- Redis, Cluster specification (hash slots): https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/
- Notion, "Herding elephants: lessons learned from sharding Postgres at Notion", 2021: https://www.notion.so/blog/sharding-postgres-at-notion
