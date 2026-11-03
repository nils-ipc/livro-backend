# Locks, contenção e pools de conexão

## A conta que todo mundo quer tocar

Às 21h04 de uma terça, no quarto dia da campanha "Black Friday o mês inteiro", a API da Lastro parou de responder, e quem avisou foi o Bazar, num chamado com o assunto "URGENTE!!!!" e o corpo "?????". O monitoramento só soube às 21h11. O monitoramento soube pelo chamado.

O log tinha uma linha só, repetida 3.800 vezes:

```text
sqlalchemy.exc.TimeoutError: QueuePool limit of size 5 overflow 10
reached, connection timed out, timeout 30.00
```

Saque, extrato, consulta de cobrança: tudo esperava 30 segundos e morria. Um vendedor que só queria o extrato de março olhou meio minuto para um spinner e ganhou um `500`. O ledger estava íntegro, a soma dava zero, e ninguém conseguia entrar no prédio.

A causa tinha três semanas. O gerente de produto pediu "a comissão do Bazar em tempo real no painel, é só um número". O `SUM` sobre os 2,1 milhões de lançamentos da conta de comissão levava 1,4 segundo, e o Carlos criou a coluna `contas.saldo_cache` e um trigger que, a cada lançamento, faz `UPDATE contas SET saldo_cache = saldo_cache + valor`. O commit dizia `saldo instantâneo, zero risco`. Dois erros em quatro palavras, uma taxa que nem o vendedor 42 alcança.

Toda venda do Bazar grava quatro lançamentos (capítulo 3): liquidante, vendedor, comissão e receita da Lastro. Só o vendedor muda. Com o trigger, toda venda passou a dar `UPDATE` na mesma linha da comissão, e o handler que confirma o Pix só faz `COMMIT` depois de mandar o webhook para o Bazar, que em campanha respondia em 250 ms.

Por que uma linha derrubou a API inteira, inclusive o que nem passa perto dela?

## Onde o PostgreSQL guarda um lock

Os locks de tabela do PostgreSQL ficam em memória compartilhada. São oito modos, de `ACCESS SHARE` (todo `SELECT`; só conflita com `ACCESS EXCLUSIVE`) até `ACCESS EXCLUSIVE` (quase todo `ALTER TABLE`, `DROP`, `TRUNCATE`; conflita com tudo, até com o `SELECT` mais humilde). `INSERT`, `UPDATE` e `DELETE` pegam `ROW EXCLUSIVE`, que, apesar do nome, não conflita com outro `ROW EXCLUSIVE`. Quem batizou odiava a gente. Locks de DDL ficam para o capítulo 7.

Os locks de linha ficam na própria linha: quem trava grava o seu ID de transação no `xmax` da tupla (o do MVCC, capítulo 3) e marca nos bits de informação que aquilo é lock, e não exclusão. Por isso o PostgreSQL trava 10 milhões de linhas sem gastar memória de lock. O custo é uma escrita em cada linha travada, inclusive no `SELECT ... FOR UPDATE`, que tem cara de leitura e alma de `UPDATE`.

São quatro modos de lock de linha:

| Modo | Quem pega | Conflita com |
|------|-----------|--------------|
| `FOR KEY SHARE` | checagem de chave estrangeira | `FOR UPDATE` |
| `FOR SHARE` | pedido explícito | `FOR NO KEY UPDATE`, `FOR UPDATE` |
| `FOR NO KEY UPDATE` | `UPDATE` que não muda chave | `FOR SHARE`, `FOR NO KEY UPDATE`, `FOR UPDATE` |
| `FOR UPDATE` | `DELETE`, `UPDATE` de chave, pedido explícito | todos |

Repare na primeira linha. Todo `INSERT` em `lancamentos` confere a chave estrangeira para `contas` e, para isso, pega `FOR KEY SHARE` na linha da conta. O `FOR UPDATE` do trigger de débito (capítulo 2) bloqueia, portanto, todo crédito na conta enquanto o saque não termina. Um `FOR NO KEY UPDATE` daria a mesma exclusão entre débitos e deixaria os créditos passarem. Duas palavras a mais no SQL, uma fila a menos na conta.

E quem espera, espera o quê? A transação B encontra o ID da transação A no `xmax`, enfileira-se pelo lock da tupla e depois pede um `ShareLock` sobre o próprio ID de transação de A. Esse lock A segura desde que nasceu e só solta no `COMMIT` ou no `ROLLBACK`. Ou seja: B espera A **morrer**. O lock de linha do PostgreSQL é uma herança, e só se recebe no velório.

## A matemática da fila indiana

Contenção é tempo esperando lock em vez de trabalhando. Para uma linha: se cada transação segura o lock por `t` segundos, aquela linha atende no máximo `1 / t` transações por segundo, com qualquer número de núcleos, de workers ou de orações do fundador. O tempo de posse vai do comando que trava até o fim da transação, com tudo que o código faz no meio. Na Lastro de 21h04:

```text
BEGIN
  INSERT lançamentos ... trigger: UPDATE contas (comissão)  -- trava aqui
  UPDATE cobrancas SET estado = 'paga'
  POST https://bazar.../webhooks         -- 250 ms, Bazar em campanha
COMMIT                                   -- solta aqui
```

Posse de ~260 ms dá teto de 3,8 vendas por segundo na comissão. O pico da campanha: 12 por segundo. Chegam 12, saem 3,8: a fila cresce 8 transações por segundo, para sempre, ou até algo quebrar. Algo quebrou.

Cada transação na fila segura uma conexão, e conexão esperando lock está tão ocupada quanto uma trabalhando. As 45 do pool (15 por worker) encheram em menos de seis segundos, e daí em diante toda requisição, inclusive o extrato de março, esperava 30 segundos e morria. O lock transforma espera em conexões presas, e o pool transforma conexões presas em fila para todo mundo. A contenção foi numa linha; a indisponibilidade, no sistema inteiro.

O próprio banco mostra a cena:

```text
  pid  |        state        | wait_event_type |  wait_event   | query
-------+---------------------+-----------------+---------------+---------------
 51120 | idle in transaction | Client          | ClientRead    | UPDATE cobranc
 51133 | active              | Lock            | transactionid | INSERT INTO la
 51134 | active              | Lock            | tuple         | INSERT INTO la
 51137 | active              | Lock            | tuple         | INSERT INTO la
 (44 rows)
```

O processo 51120 segura o lock e está `idle in transaction`: parado, de transação aberta, esperando o Python, que espera o Bazar. O 51133 é o primeiro da fila e espera o `transactionid` dele; os outros 42 esperam o lock da tupla, atrás do 51133. Quarenta e quatro conexões, uma trabalhando, e ela nem está trabalhando. É a reunião de planejamento do banco de dados.

## `FOR UPDATE`, `NOWAIT` e `SKIP LOCKED`

O `SELECT ... FOR UPDATE` trava as linhas que retorna até o fim da transação e, por padrão, espera quem chegou antes. Dois modificadores mudam isso.

`NOWAIT` falha na hora com erro `55P03` (`lock_not_available`) se a linha estiver travada: serve quando esperar é pior que desistir. `SET lock_timeout = '2s'` dá o mesmo erro depois de dois segundos. Fila, sim, mas com prazo de validade, igual a iogurte.

`SKIP LOCKED` pula as linhas travadas e devolve as livres. O resultado omite linhas que existem, então ele serve para uma coisa só: vários consumidores pegando tarefas da mesma tabela sem pisar uns nos outros.

```sql
BEGIN;
SELECT id, payload FROM tarefas
 WHERE estado = 'pendente'
 ORDER BY id
 LIMIT 10
 FOR UPDATE SKIP LOCKED;
-- worker A recebe 1..10; worker B, no mesmo instante, recebe 11..20
```

Se o worker morre no meio, o `ROLLBACK` solta as linhas e outro worker herda as tarefas do falecido. Fila sem broker, transacional com o resto do banco. O limite é o volume: cada tarefa é escrita, lock e, depois, uma tupla morta para o VACUUM enterrar (o capítulo 17 conta quando a fila sai do banco).

## Otimista, ou "trava nada e reza"

Tudo até aqui é controle **pessimista**: trava antes, porque alguém vai mexer. O controle **otimista** não trava: lê a linha com um número de versão, faz o que tem de fazer e grava só se a versão ainda for a mesma.

```sql
UPDATE cobrancas
   SET estado = 'estornada', versao = versao + 1
 WHERE id = '01936f3e-...' AND versao = 7;
-- UPDATE 0   (alguém mudou a cobrança depois que você leu)
```

`UPDATE 0` é conflito: relê e decide de novo, ou devolve erro. É o `UPDATE` condicional do capítulo 2 com versão no lugar do saldo, e o que o HTTP faz com `ETag` e `If-Match` (capítulo 9).

A régua é a taxa de conflito. Com conflito raro, o otimista não segura lock nenhum, e o pessimista paga escrita de lock à toa. Com conflito frequente, como na conta de comissão a 12 vendas por segundo, o otimista também faz fila, só que em loop no Python, perdendo, repetindo e queimando CPU. E o otimista alcança o que o pessimista não alcança: leitura e escrita em requisições diferentes. O operador abre a cobrança às 14h e clica em "estornar" às 14h07. Nenhum lock de banco atravessa sete minutos e duas requisições HTTP. Uma coluna de versão atravessa até o almoço.

## Deadlock no banco

O PostgreSQL não previne deadlock (capítulo 2): detecta. Quem espera um lock por mais de `deadlock_timeout` (1 segundo por padrão) dispara a busca de ciclo no grafo de espera; achando um, aborta uma das transações com `40P01`, e a outra segue.

Com o `saldo_cache` do Carlos, o ciclo veio de brinde. O pagamento atualizava o cache na ordem de inserção (liquidante, vendedor, comissão, receita). O estorno, na ordem crescente de `conta_id` do capítulo 2, atualizava a comissão, criada antes de quase todo vendedor, primeiro.

```text
ERROR:  deadlock detected
DETAIL:  Process 51190 waits for ShareLock on transaction 9182733;
         blocked by process 51188.
         Process 51188 waits for ShareLock on transaction 9182730;
         blocked by process 51190.
CONTEXT: while updating tuple (8812,4) in relation "contas"
```

O estorno retenta `40P01` (capítulo 3). O pagamento não retentava: o comprador pagou, o banco parceiro confirmou, e a Lastro respondeu erro. E como a busca do ciclo só começa depois de 1 segundo, todo deadlock custa pelo menos 1 segundo de lock segurado, com a fila inteira da conta quente atrás, batendo o pé.

## Uma conexão é um processo

O PostgreSQL atende cada conexão com um processo do sistema operacional, criado por `fork`. Abrir uma custa handshake TCP, TLS, autenticação SCRAM-SHA-256 e o `fork`: alguns milissegundos na mesma rede, mais entre máquinas distantes (capítulo 8). Cada processo ocupa alguns megabytes, mais `work_mem` por ordenação ou hash, e cada conexão existente pesa em contas internas como a montagem de snapshots (o PostgreSQL 14 baratiou esse custo, sem zerá-lo).

Por isso `max_connections` vem com 100 por padrão. Passar disso compra memória gasta, troca de contexto e um banco mais lento com 500 conexões ativas do que com 20. Conexão é cara de abrir e cara de manter, como todo relacionamento que você já teve.

## Pools: guardar conexões abertas

Um **pool de conexões** mantém conexões abertas e as empresta: pega, usa, devolve, e ninguém paga handshake nem `fork` de novo.

O pool **na aplicação** vive dentro de cada processo. O `QueuePool` do SQLAlchemy usa `pool_size=5` (conexões mantidas), `max_overflow=10` (extras sob demanda) e `pool_timeout=30` (segundos de espera antes do erro que abriu o capítulo); o `psycopg_pool` tem equivalentes. O problema é a multiplicação: o banco recebe processos × (pool + overflow). Três workers dão 45. Trinta réplicas com três workers dão 1.350, e o `max_connections` ri por último.

O pool **externo**, como o PgBouncer, fica entre as aplicações e o banco: aceita milhares de conexões de clientes e as multiplexa sobre poucas conexões reais. O modo define quando a conexão real volta para o pool:

| Modo | Conexão real devolvida | Quebra |
|------|------------------------|--------|
| `session` | quando o cliente desconecta | nada; e multiplexa pouco |
| `transaction` | no fim de cada transação | `SET` de sessão, advisory lock de sessão, `LISTEN`, tabelas temporárias que sobrevivem à transação |
| `statement` | a cada comando | transações com mais de um comando |

O modo `transaction` multiplexa de verdade e cobra o preço: estado de sessão some ou, pior, aparece para outro cliente. Prepared statements quebravam nesse modo até o PgBouncer 1.21, que passou a rastreá-los com `max_prepared_statements`. No modo `transaction`, a conexão real vira motel: entra, resolve, sai, e o próximo hóspede não pode achar nada seu na gaveta.

## Quantas conexões, afinal

Pool pequeno demais enfileira requisições na aplicação; grande demais enfileira processos no banco, disputando CPU. O número sai de duas contas.

A demanda vem da Lei de Little (capítulo 14): conexões em uso = taxa de requisições × tempo médio de posse. Com 40 requisições por segundo segurando conexão por 25 ms, a média é 1 conexão ocupada. O pool cobre picos acima disso, não 45 vezes isso.

O teto vem do banco. Um ponto de partida empírico, publicado pelo projeto HikariCP, é `conexões = núcleos × 2 + discos efetivos`: acima disso, cada conexão a mais só disputa CPU e disco. Para o PostgreSQL da Lastro, com 8 núcleos e SSD, dá perto de 17 a 20 conexões ativas úteis. Ponto de partida para medir, não lei.

E o `pool_timeout` de 30 segundos? Aquele timeout de 30 segundos que ninguém sabe quem configurou? Ninguém configurou. É o padrão. O culpado era o silêncio.

## Na Lastro: a conta quente

Uma **conta quente** recebe lançamento numa fração grande de todas as transações. A Lastro tem três: liquidante, receita e comissão de cada marketplace; com dezenas de marketplaces (Parte IV), liquidante e receita entram em todas as vendas de todos. São as contas mais populares da empresa, e popularidade, no PostgreSQL, se mede em gente esperando na porta.

O ledger do capítulo 1 já aguentava: créditos são `INSERT`, e `INSERT` na mesma conta não conflita. Quem criou a fila foi o cache. E o requisito do painel (saldo da comissão em tempo real, sem o `SUM` de 1,4 s) continua de pé, porque o gerente de produto já mostrou o número para o Bazar. As opções:

| Estratégia | Espera por lock | Saldo no painel | Custo |
|------------|-----------------|-----------------|-------|
| `saldo_cache` numa linha | 1 fila por conta; teto `1/t` | exato | o incidente |
| Só `SUM`, sem cache | nenhuma | exato, 1,4 s e crescendo | leitura O(n); índices no capítulo 5 |
| Agregação assíncrona (fila com `SKIP LOCKED`) | nenhuma no pagamento | atrasado segundos | job novo; saldo defasado |
| Saldo em N baldes (subcontas de cache) | 1 fila por balde; teto `N/t` | exato, soma de N linhas | N linhas por conta; ordem de travamento |

A Lastro escolhe os baldes, só para contas marcadas como quentes. A tabela `saldos_parciais (conta_id, balde, saldo)` tem 16 linhas por conta quente; cada pagamento soma o valor no balde `hash(cobranca_id) % 16`, e o saldo é a soma das 16, exata no snapshot de quem lê. Contas de vendedor seguem sem cache: lá ninguém disputa. A agregação assíncrona perdeu porque o financeiro concilia o saldo exibido com o ledger, e saldo atrasado vira divergência às 23h de sábado. Ela seria a escolha se o painel aceitasse defasagem de segundos (consistência eventual, capítulo 19).

```text
pagamento (read committed)
  INSERT 4 lançamentos            (FK: FOR KEY SHARE nas contas)
  UPDATE cobrancas estado = paga
  UPDATE saldos_parciais           ordem (conta_id, balde)   -- último comando
COMMIT                             posse do balde: ~2 ms
  └─> webhook ao Bazar             depois do COMMIT, fora da transação
```

Junto vieram três regras. O webhook sai depois do `COMMIT` (o capítulo 17 o tira da requisição também). O trigger de débito troca `FOR UPDATE` por `FOR NO KEY UPDATE`, e créditos param de esperar saques. A ordem de `(conta_id, balde)` vale para toda escrita em conta, e o pagamento ganha a retentativa de `40P01` que o estorno já tinha.

Com posse de ~2 ms, um balde aguenta perto de 500 pagamentos por segundo; 16, perto de 8.000. O pico da campanha caberia em 2,4% de um balde só. Os 16 são para a Black Friday de verdade (capítulo 14) e para o liquidante, que recebe as vendas de todos os marketplaces. O Carlos sugeriu 1.024 baldes, "por segurança". O `# por segurança` tem currículo neste livro, e foi recusado.

O pool ficou em `pool_size=5`, `max_overflow=0` e `pool_timeout=3`: 15 conexões previsíveis e falha em 3 segundos em vez de 30. Cada transação ganha `lock_timeout = '2s'`, e o `idle_in_transaction_session_timeout` do capítulo 3 fica em 5 segundos. PgBouncer fica fora: com 15 conexões, multiplexaria quase nada e acrescentaria um salto de rede e um componente para operar. Ele vira a escolha quando processos × pool passar do teto útil do banco, com o monólito dividido em serviços (capítulo 26) e réplicas em Kubernetes (capítulo 35).

## Armadilhas e casos reais

> **Armadilha:** chamada de rede dentro de transação com lock. O lock dura o p99 do serviço externo, não o seu. A sua conta quente passa a ter o SLA do Bazar, e o Bazar não tem SLA.

> **Armadilha:** aumentar o pool para "resolver" a falta de conexões. Com fila de lock, mais conexões só põem mais transações na fila. O Carlos subiu `pool_size` para 50 às 21h20. Às 21h24 eram 150 conexões esperando a mesma linha, e o `max_connections` recusou o resto. Ele chamou de teste de carga.

> **Armadilha:** `SKIP LOCKED` em consulta que precisa de resposta completa. Um relatório que "pula o que está travado" é um relatório que mente em silêncio, e o financeiro descobre a mentira na planilha.

`SET statement_timeout` de sessão atrás de PgBouncer em modo `transaction` fica na conexão real e vaza para o próximo cliente; `SET LOCAL` dura só a transação.

> **Na vida real:** antes do PgBouncer 1.21, o erro `prepared statement "S_1" does not exist` era a forma mais comum de descobrir que o driver usava prepared statements e o pooler estava em modo `transaction`. Drivers como o JDBC do PostgreSQL passam a preparar comandos automaticamente depois de algumas execuções (`prepareThreshold`, 5 por padrão), então o erro aparecia na quinta chamada, nunca no teste com quatro.

## Resumo

- Locks de tabela em memória (8 modos); locks de linha no `xmax` (4 modos); esperar uma linha é esperar a transação dona terminar.
- FK pega `FOR KEY SHARE`, que só conflita com `FOR UPDATE`.
- Linha travada por `t` segundos: teto de `1/t` transações por segundo, e `t` inclui tudo até o `COMMIT`.
- `NOWAIT` e `lock_timeout` limitam a espera; `SKIP LOCKED` serve a filas de tarefas.
- Otimista com versão: conflito raro ou requisições diferentes; colapsa com conflito alto.
- Deadlock detectado após `deadlock_timeout` (1 s), vítima com `40P01`; ordem fixa previne.
- Conexão = processo; pool na aplicação multiplica por processo; PgBouncer multiplexa (session, transaction, statement).
- Pool: Lei de Little para a demanda, núcleos × 2 + discos para o teto.
- Conta quente: I/O fora da transação, travar por último, baldes.

## A Lastro agora

O `saldo_cache` saiu de `contas`. Contas quentes (liquidante, receita, comissão de cada marketplace) têm saldo em 16 baldes em `saldos_parciais`, atualizados no último comando, em ordem de `(conta_id, balde)`. O webhook sai depois do `COMMIT`, o trigger de débito usa `FOR NO KEY UPDATE`, o pagamento retenta `40P01`, `lock_timeout` é 2 s, e o pool tem 5 conexões por worker, sem overflow, 3 segundos de espera.

O commit do Carlos dizia `saldo instantâneo, zero risco`. O saldo voltou a ser instantâneo, em 16 pedaços, e o risco virou uma linha do postmortem com o nome dele. O painel ganhou fôlego e uma ambição nova: o extrato do vendedor por período, que filtra 40 milhões de lançamentos e já leva 6 segundos. O gerente de produto acha que é só um índice. Dessa vez ele quase acertou.

## Referências

- PostgreSQL 16 Documentation, *Explicit Locking*. <https://www.postgresql.org/docs/16/explicit-locking.html>
- PostgreSQL 16 Documentation, *SELECT: The Locking Clause*. <https://www.postgresql.org/docs/16/sql-select.html#SQL-FOR-UPDATE-SHARE>
- PostgreSQL 16 Documentation, *Client Connection Defaults*. <https://www.postgresql.org/docs/16/runtime-config-client.html>
- PostgreSQL 16 Documentation, *The Cumulative Statistics System*. <https://www.postgresql.org/docs/16/monitoring-stats.html>
- SQLAlchemy 2.0 Documentation, *Connection Pooling*. <https://docs.sqlalchemy.org/en/20/core/pooling.html>
- PgBouncer, *Configuration*. <https://www.pgbouncer.org/config.html>
- HikariCP Wiki, *About Pool Sizing*. <https://github.com/brettwooldridge/HikariCP/wiki/About-Pool-Sizing>
- Freund, A. *Improving Postgres Connection Scalability: Snapshots*. Microsoft Tech Community, 2020.
