# Locks, contenção e pools de conexão

## O show que esgotou sem vender

Às 10h00 de uma segunda-feira, abriu a venda de ingressos para a turnê de reencontro de uma banda que tinha se separado em 1998 (a situação é hipotética; a dor é real). Trinta mil pessoas apertaram "Comprar" no mesmo segundo. Às 10h00min31s, o painel mostrava três números: CPU do banco em 4%, memória sobrando e 37 ingressos vendidos.

O log da API, por outro lado, estava bem ocupado:

```text
sqlalchemy.exc.TimeoutError: QueuePool limit of size 5 overflow 10 reached,
connection timed out, timeout 30.00
```

Alguém reiniciou os pods "para limpar", e a mensagem mudou de assunto:

```text
psycopg.OperationalError: connection failed: connection to server at "10.0.3.17",
port 5432 failed: FATAL:  sorry, too many clients already
```

A função de compra tinha onze linhas e passou no code review sem nenhum comentário:

```python
def comprar(sessao: Session, lote_id: int, cliente: Cliente) -> None:
    lote = sessao.execute(
        select(Lote).where(Lote.id == lote_id).with_for_update()
    ).scalar_one()
    if lote.disponiveis == 0:
        raise Esgotado()
    gateway.cobrar(cliente, lote.preco)  # ~800 ms, nos dias bons
    lote.disponiveis -= 1
    sessao.commit()
```

Trinta e sete ingressos em 31 segundos dá 1,2 por segundo, quase exatamente um a cada 800 ms. A pergunta que este capítulo responde: como um banco de dados praticamente ocioso consegue recusar conexões e, ao mesmo tempo, vender um ingresso por vez, com a calma de um cartório?

## O mecanismo

### Locks de linha, ou o banco escreve "ocupado" no próprio registro

No PostgreSQL, leitores comuns não esperam por escritores: o MVCC entrega a cada transação a versão da linha que o snapshot dela enxerga (o capítulo 10 trata disso em detalhe). O *lock* entra em cena quando dois escritores querem a mesma linha. Duas transações não podem criar, ao mesmo tempo, duas versões novas da mesma linha, porque uma delas teria de escolher qual versão é a "anterior".

A implementação é curiosamente doméstica. Quando a transação 912044 atualiza ou trava uma linha, o PostgreSQL grava o ID dela no campo `xmax` do cabeçalho da tupla, na página de dados. A transação 912045 chega, lê esse cabeçalho, vê que a 912044 ainda está em andamento e espera pelo fim dela: cada transação mantém um lock exclusivo sobre o próprio ID enquanto vive, e a interessada pede um `ShareLock` sobre esse ID, que só sai no `COMMIT` ou no `ROLLBACK`.

Daí saem duas consequências. O lock de linha dura até o fim da transação, incluindo tudo o que acontecer depois do `UPDATE`, como, digamos, uma chamada HTTP de 800 ms para um gateway de pagamento. E, como a marca fica na própria tupla, não há limite para quantas linhas você pode travar; o preço é que `SELECT ... FOR UPDATE` escreve na página e gera WAL. Um `SELECT` que escreve no disco: o nome do comando mente um pouco.

Quando várias transações esperam pela mesma linha, a ordem é mantida por um lock auxiliar do tipo `tuple`: a primeira da fila segura esse lock e espera o ID da dona; as outras esperam a primeira, em conga.

Há quatro modos de lock de linha, do mais forte para o mais fraco:

| Modo | Quem pede | Conflita com |
|------|-----------|--------------|
| `FOR UPDATE` | `DELETE`, `UPDATE` que altera coluna de chave, `SELECT ... FOR UPDATE` | todos os modos |
| `FOR NO KEY UPDATE` | `UPDATE` comum | `FOR SHARE`, `FOR NO KEY UPDATE`, `FOR UPDATE` |
| `FOR SHARE` | `SELECT ... FOR SHARE` | `FOR NO KEY UPDATE`, `FOR UPDATE` |
| `FOR KEY SHARE` | inserir linha que referencia esta via chave estrangeira | só `FOR UPDATE` |

O modo mais fraco existe por causa das chaves estrangeiras. Inserir um item de pedido trava o pedido pai em `FOR KEY SHARE`, para ele não ser apagado no meio do caminho; um `UPDATE` comum no pai pede só `FOR NO KEY UPDATE`, e os dois convivem em paz. Antes do PostgreSQL 9.3, o lock era `FOR SHARE`, e qualquer atualização no pedido esperava a inserção de itens terminar.

### Locks de tabela, oito modos e uma fila sem misericórdia

Todo comando também pede um lock na tabela inteira, guardado em memória compartilhada. Quase sempre passa despercebido, porque os modos dos comandos do dia a dia são compatíveis entre si.

| Modo | Pedido por | Conflita com SELECT? |
|------|------------|----------------------|
| `ACCESS SHARE` | `SELECT` | não |
| `ROW SHARE` | `SELECT ... FOR UPDATE/SHARE` | não |
| `ROW EXCLUSIVE` | `INSERT`, `UPDATE`, `DELETE` | não |
| `SHARE UPDATE EXCLUSIVE` | `VACUUM`, `ANALYZE`, `CREATE INDEX CONCURRENTLY` | não |
| `SHARE` | `CREATE INDEX` | não (mas bloqueia escritas) |
| `SHARE ROW EXCLUSIVE` | `CREATE TRIGGER` | não |
| `EXCLUSIVE` | `REFRESH MATERIALIZED VIEW CONCURRENTLY` | não |
| `ACCESS EXCLUSIVE` | `DROP`, `TRUNCATE`, `VACUUM FULL`, a maioria dos `ALTER TABLE` | sim, com tudo |

Os nomes são um desafio à parte: `ROW EXCLUSIVE` é um lock de tabela, e é pedido por todo `UPDATE`. Os modos foram batizados nos anos 1990 e ninguém teve coragem de mexer.

O detalhe que derruba sistemas é a fila. Pedidos de lock de tabela são atendidos em ordem de chegada, e um pedido novo que conflita com alguém *esperando* também espera, mesmo que seja compatível com quem *segura* o lock. Um `ALTER TABLE` que chega enquanto um relatório de 40 segundos lê a tabela fica na fila pedindo `ACCESS EXCLUSIVE`; todo `SELECT` que chega depois entra atrás dele. A tabela fica inacessível por causa de um comando que nem começou a executar. O capítulo 12 trata dos locks de DDL e de como escapar dessa fila com `lock_timeout`.

### FOR UPDATE, NOWAIT e SKIP LOCKED

`SELECT ... FOR UPDATE` trava as linhas lidas no modo mais forte e implementa o lock pessimista: "eu vou mexer nisso, ninguém mais mexe até eu terminar". Em `READ COMMITTED`, se a linha travada por outra transação mudar e essa transação fizer commit, o PostgreSQL reavalia o `WHERE` contra a versão nova antes de entregar a linha. Se ela não satisfaz mais o filtro, simplesmente some do resultado.

O comportamento na espera tem três variantes:

- Sem nada: espera o tempo que for preciso (ou até `lock_timeout`, se configurado).
- `NOWAIT`: se qualquer linha estiver travada, falha na hora com `ERROR: could not obtain lock on row in relation "lotes"` (SQLSTATE `55P03`).
- `SKIP LOCKED` (PostgreSQL 9.5+): pula as linhas que não consegue travar imediatamente e devolve as outras.

`SKIP LOCKED` produz de propósito uma visão inconsistente da tabela: serve quando qualquer linha livre atende, como numa fila de tarefas. Num relatório de saldo, ele mente com toda a convicção.

### Controle otimista, ou "confio, mas verifico na hora de gravar"

O lock pessimista trava antes de ler. O controle otimista não trava nada: lê a linha junto com um número de versão e, na hora de gravar, exige que a versão continue a mesma.

```sql
UPDATE eventos
SET descricao = 'Turnê de reencontro (agora com o baterista)', versao = versao + 1
WHERE id = 42 AND versao = 7;
```

Se outra transação gravou antes, a versão já é 8 e o banco responde `UPDATE 0`. A aplicação recarrega e tenta de novo, ou devolve um conflito ao usuário (em HTTP, `If-Match` com `412 Precondition Failed`). Sob disputa alta, N clientes leem, N tentam gravar, um consegue e N-1 jogam o trabalho fora: ninguém fica travado, e a CPU de todo mundo é desperdiçada democraticamente.

### Deadlocks no banco

Duas transações, cada uma esperando um lock que a outra segura, formam um ciclo. O PostgreSQL não verifica ciclos a cada espera, porque montar o grafo de espera custa caro. Quando um processo passa `deadlock_timeout` (padrão 1 s) esperando, ele roda o detector; se encontrar um ciclo, uma das transações é abortada com SQLSTATE `40P01`, e a outra segue. A documentação avisa que qual delas morre é difícil de prever e que a aplicação não deve contar com isso.

Num mapa de assentos, o cliente A clica nos assentos 10 e 20; o cliente B, ao mesmo tempo, clica no 20 e depois no 10. A aplicação reserva na ordem dos cliques:

```text
T1: UPDATE assentos SET reservado_por = 'A' WHERE id = 10;  -- trava 10
T2: UPDATE assentos SET reservado_por = 'B' WHERE id = 20;  -- trava 20
T1: UPDATE assentos SET reservado_por = 'A' WHERE id = 20;  -- espera T2
T2: UPDATE assentos SET reservado_por = 'B' WHERE id = 10;  -- espera T1
```

Um segundo depois, uma das duas recebe:

```text
ERROR:  deadlock detected
DETAIL:  Process 51877 waits for ShareLock on transaction 912044; blocked by process 51876.
Process 51876 waits for ShareLock on transaction 912045; blocked by process 51877.
HINT:  See server log for query details.
CONTEXT:  while updating tuple (0,10) in relation "assentos"
```

O `ShareLock on transaction` é a espera pelo ID da dona descrita lá atrás. A correção quebra a espera circular travando sempre na mesma ordem; como o `UPDATE` do PostgreSQL não aceita `ORDER BY`, trava-se antes com `SELECT id FROM assentos WHERE id = ANY(%s) ORDER BY id FOR UPDATE`. A transação abortada ainda merece retry (o capítulo 5 trata das condições de Coffman).

### Quanto custa uma conexão

O PostgreSQL usa um processo do sistema operacional por conexão: o processo principal (`postmaster`) faz `fork()` e entrega o socket ao novo backend. Abrir uma conexão do zero custa o handshake TCP (1 RTT), o TLS 1.3 (mais 1 RTT), a inicialização com autenticação SCRAM-SHA-256 (mais dois ou três RTTs), o `fork()` e a carga dos caches de catálogo. Alguns milissegundos, para executar uma consulta por chave primária de 0,2 ms. Uma conexão por requisição faz o banco gastar mais tempo cumprimentando do que trabalhando.

Depois de aberta, a conexão ocupa alguns megabytes de memória (sem contar `work_mem`, que é por operação de ordenação ou hash) e um slot de `max_connections`, cujo padrão é 100, com 3 reservados para superusuários. Passado o limite, o servidor recusa com o `sorry, too many clients already` que abriu o capítulo, educado e irredutível.

### Pools na aplicação

Um *pool* de conexões mantém conexões abertas e as empresta: a requisição pega uma (checkout), usa e devolve (checkin). No SQLAlchemy, o `QueuePool` padrão tem `pool_size=5` conexões mantidas, `max_overflow=10` extras temporárias e `pool_timeout=30` segundos de espera por uma conexão antes do `TimeoutError`. Sim: o timeout de 30 segundos que ninguém sabe quem configurou foi configurado pelo valor padrão, e ninguém configurou nada.

O pool vive dentro do processo. Cada worker do Gunicorn, cada processo do Celery e cada réplica tem o seu. A conta que importa:

```text
conexões possíveis = réplicas × processos por réplica × (pool_size + max_overflow)
                   = 12 × 4 × (5 + 10) = 720
```

Setecentas e vinte conexões possíveis apontadas para um `max_connections = 100`. Em dia normal, cada pool usa duas ou três e a conta nunca aparece. No dia do show, ela aparece inteira.

### Pools externos: PgBouncer

Um pooler externo, como o PgBouncer, fica entre as aplicações e o banco, falando o protocolo do PostgreSQL dos dois lados. Ele aceita milhares de conexões de clientes (`max_client_conn`), baratas porque são só sockets num event loop de thread única, e as multiplexa sobre poucas conexões reais (`default_pool_size`, padrão 20 por par usuário e banco).

O modo de pool define quando a conexão real volta para o PgBouncer:

- `session`: no fim da sessão do cliente. Tudo funciona, e o ganho é só o reuso das conexões entre sessões.
- `transaction`: no fim de cada transação. É o modo que multiplica, e é também o que quebra coisas.
- `statement`: a cada comando, o que proíbe transações com mais de um comando.

No modo `transaction`, duas transações seguidas do mesmo cliente podem cair em backends diferentes. Tudo que pertence à sessão deixa de ser confiável: `SET` sem `LOCAL`, advisory locks de sessão, `LISTEN`, tabelas temporárias que sobrevivem à transação, cursores `WITH HOLD`. Prepared statements no protocolo estendido passaram a ser suportados no PgBouncer 1.21 (outubro de 2023), com o parâmetro `max_prepared_statements`; em versões anteriores, o psycopg 3 precisa de `prepare_threshold=None` para não preparar consultas num backend e tentar usá-las em outro.

### Dimensionamento do pool

A Lei de Little dá o número de conexões ocupadas em média: taxa de transações vezes o tempo que cada uma segura a conexão. A 2.000 transações por segundo, segurando a conexão por 5 ms, a média é 10 conexões ocupadas. A folga cobre picos e variância, e não precisa ser de uma ordem de grandeza.

O teto vem do outro lado. Um servidor com 8 núcleos executa no máximo 8 backends ao mesmo tempo; o resto espera na fila do escalonador, trocando de contexto, disputando locks internos e caches. A wiki do PostgreSQL cita como ponto de partida empírico `conexões = (núcleos × 2) + discos efetivos`, avisando que serve para começar a medir. Mais conexões ativas do que o banco consegue executar só move a fila de um lugar visível (o pool) para um invisível (dentro do banco).

E agora a resposta para a pergunta do começo. Todas as compras disputavam a mesma linha de `lotes`, travada durante a chamada ao gateway. Uma linha travada por 800 ms tem vazão máxima de 1/0,8 s = 1,25 transações por segundo, com qualquer pool, núcleo ou réplica. As outras esperavam com a conexão na mão, os pools esgotaram, requisições novas morreram após 30 s, e os pods reiniciados abriram conexões antes de as antigas fecharem, estourando `max_connections`. A CPU ficou em 4% porque esperar lock não gasta CPU. O banco estava ocupadíssimo não fazendo nada.

## Na prática

### Encontrando quem segura quem

`pg_stat_activity` mostra o estado de cada backend, e `pg_blocking_pids()` (PostgreSQL 9.6+) diz quem bloqueia quem:

```sql
SELECT pid, state, wait_event_type AS tipo, wait_event AS evento,
       now() - xact_start AS idade_tx,
       pg_blocking_pids(pid) AS bloqueado_por
FROM pg_stat_activity
WHERE datname = 'ingressos' AND xact_start IS NOT NULL
ORDER BY xact_start
LIMIT 4;
```

```text
  pid  |        state        |  tipo  |    evento     |    idade_tx     | bloqueado_por
-------+---------------------+--------+---------------+-----------------+---------------
 48211 | idle in transaction | Client | ClientRead    | 00:00:00.791204 | {}
 48212 | active              | Lock   | transactionid | 00:00:00.787931 | {48211}
 48219 | active              | Lock   | tuple         | 00:00:00.785512 | {48212}
 48224 | active              | Lock   | tuple         | 00:00:00.781066 | {48212}
(4 rows)
```

O dono do lock, 48211, está `idle in transaction`: travou a linha e foi conversar com o gateway. O 48212 espera o ID da transação dele; os demais esperam o lock `tuple` segurado pelo 48212, que é a fila descrita no mecanismo. A primeira linha é a culpada, e ela está, tecnicamente, descansando.

### Reservando sem fila com SKIP LOCKED

A versão corrigida troca o contador por uma linha por ingresso e reserva qualquer ingresso livre, sem ninguém esperar ninguém:

```python
import os

from psycopg_pool import ConnectionPool

RESERVAR = """
WITH livre AS (
    SELECT id FROM ingressos
    WHERE lote_id = %s AND status = 'livre'
    ORDER BY id
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
UPDATE ingressos AS i
SET status = 'reservado', reservado_ate = now() + interval '10 minutes'
FROM livre
WHERE i.id = livre.id
RETURNING i.id
"""

pool = ConnectionPool(os.environ["DATABASE_URL"], min_size=4, max_size=8)


def reservar(lote_id: int) -> int | None:
    with pool.connection() as conn:  # commit ao sair do bloco
        linha = conn.execute(RESERVAR, (lote_id,)).fetchone()
    return linha[0] if linha else None  # None: esgotou de verdade
```

A transação dura cerca de 1 ms; a cobrança acontece depois, fora dela, e um job devolve para `livre` as reservas vencidas. Com 8 threads chamando `reservar(1)` ao mesmo tempo:

```text
[1, 2, 3, 4, 5, 6, 7, 8]
```

Oito ingressos distintos, nenhuma espera; sem o `SKIP LOCKED`, as oito fariam fila na linha 1. Um índice parcial em `(lote_id, id) WHERE status = 'livre'` evita que a busca percorra os ingressos já vendidos, que no fim da venda são quase todos.

### Versão otimista no ORM

O SQLAlchemy implementa o controle otimista com `version_id_col`:

```python
class Evento(Base):
    __tablename__ = "eventos"

    id: Mapped[int] = mapped_column(primary_key=True)
    descricao: Mapped[str]
    versao: Mapped[int] = mapped_column(nullable=False)

    __mapper_args__ = {"version_id_col": versao}
```

O ORM acrescenta `AND versao = :versao_lida` a todo `UPDATE` e incrementa o valor. Quando dois administradores editam a descrição do evento ao mesmo tempo, o segundo a salvar recebe:

```text
sqlalchemy.orm.exc.StaleDataError: UPDATE statement on table 'eventos'
expected to update 1 row(s); 0 were matched.
```

O segundo descobre que alguém chegou antes, em vez de apagar o trabalho alheio em silêncio.

### Um PgBouncer em modo transação

```ini
[databases]
ingressos = host=10.0.3.17 port=5432 dbname=ingressos

[pgbouncer]
listen_addr = 10.0.3.20
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 2000
default_pool_size = 20
max_prepared_statements = 200
```

As 720 conexões possíveis da aplicação viram, no máximo, 20 conexões reais. O PgBouncer escuta só na rede privada, e as senhas ficam no `auth_file`, fora do arquivo versionado.

## Propriedades e custos

| Técnica | Garante | Custa | Pesa quando |
|---------|---------|-------|-------------|
| `FOR UPDATE` | exclusão até o fim da transação | espera; vazão da linha = 1/tempo travado | conflito frequente e transação curta |
| `FOR UPDATE NOWAIT` | falha imediata em vez de espera | tratar `55P03` | a interface prefere "tente de novo" a esperar |
| `FOR UPDATE SKIP LOCKED` | nenhuma espera, linhas distintas por consumidor | visão inconsistente | itens intercambiáveis: filas, unidades de estoque |
| Versão otimista | nenhum lock entre leitura e escrita | retry; trabalho perdido sob disputa | conflito raro, edição longa (formulário aberto por minutos) |
| `UPDATE` atômico condicional | uma ida ao banco, lock por milissegundos | regra precisa caber num `WHERE` | contadores e saldos |

Para pools:

| Opção | Conexões no banco | O que deixa de funcionar | Custo operacional |
|-------|-------------------|--------------------------|-------------------|
| Pool na aplicação | soma de todos os pools | nada | nenhum componente novo; a conta cresce com réplicas |
| PgBouncer `session` | uma por sessão ativa | nada | um salto de rede a mais; ganho limitado |
| PgBouncer `transaction` | uma por transação ativa | estado de sessão, prepared statements em versões < 1.21 | um salto a mais, um servidor novo chamado `pgbouncer-temp` |
## Armadilhas e casos reais

> **Armadilha:** chamada externa dentro da transação. HTTP, fila, e-mail ou `time.sleep` com lock aberto transformam a latência de outro sistema no tempo de lock da sua linha. Se o gateway tiver um dia ruim de 30 segundos, sua linha também tem.

**`idle in transaction` eterno.** Alguém faz um `SELECT ... FOR UPDATE` no `psql` para "dar uma olhada" e vai almoçar, segurando locks e o horizonte do VACUUM. `idle_in_transaction_session_timeout` (9.6+) encerra sessões paradas dentro de transação; `transaction_timeout` (PostgreSQL 17) limita a duração total; `lock_timeout` limita a espera por lock.

**`FOR UPDATE` com `JOIN`.** Sem qualificação, o lock vale para as linhas de todas as tabelas do `FROM`. Um `SELECT ... FROM pedidos JOIN clientes ... FOR UPDATE` trava o cliente junto, e todo pedido daquele cliente passa a fazer fila. `FOR UPDATE OF pedidos` restringe o lock à tabela certa.

**Pool multiplicado em silêncio.** O autoscaling sobe de 12 para 30 réplicas no pico, e as conexões possíveis vão de 720 para 1.800. O dia em que o autoscaling funciona bem é o dia em que o banco recusa conexões.

> **Na vida real:** a página "About Pool Sizing", do HikariCP, relata a demonstração do Oracle Real-World Performance group: 9.600 threads acessando o banco, e a redução do pool de 2.048 para 96 conexões levou o tempo de resposta de cerca de 100 ms para cerca de 2 ms, sem mudar mais nada. O banco não ficou mais rápido; parou de gastar tempo alternando entre trabalhos que não podia fazer ao mesmo tempo.

## Resumo

- Lock de linha fica no `xmax` da tupla e dura até o fim da transação; esperar uma linha é esperar o ID da transação dona.
- A fila de locks de tabela faz um `ACCESS EXCLUSIVE` à espera bloquear os `SELECT`s que chegam depois.
- `NOWAIT` falha na hora; `SKIP LOCKED` pula linhas travadas e serve para itens intercambiáveis; a versão otimista troca espera por retry.
- Deadlock: detector após `deadlock_timeout` (1 s), erro `40P01`; travar em ordem fixa e fazer retry.
- Uma linha disputada tem vazão máxima de 1/tempo travado, com qualquer pool.
- O limite real são as conexões possíveis somadas de todos os pools; PgBouncer em modo `transaction` as multiplexa, ao preço do estado de sessão.
- Pool dimensionado pela Lei de Little e limitado pelos núcleos do banco.

## Referências

- PostgreSQL, "Explicit Locking": https://www.postgresql.org/docs/current/explicit-locking.html
- PostgreSQL, "SELECT", seção "The Locking Clause": https://www.postgresql.org/docs/current/sql-select.html
- PostgreSQL, "Client Connection Defaults" (`lock_timeout`, `idle_in_transaction_session_timeout`, `transaction_timeout`): https://www.postgresql.org/docs/current/runtime-config-client.html
- PostgreSQL, "Lock Management" (`deadlock_timeout`): https://www.postgresql.org/docs/current/runtime-config-locks.html
- PostgreSQL, "The Cumulative Statistics System" (`pg_stat_activity`): https://www.postgresql.org/docs/current/monitoring-stats.html
- PostgreSQL Wiki, "Number Of Database Connections": https://wiki.postgresql.org/wiki/Number_Of_Database_Connections
- PgBouncer, "Features": https://www.pgbouncer.org/features.html
- PgBouncer, "Configuration": https://www.pgbouncer.org/config.html
- SQLAlchemy 2.0, "Connection Pooling": https://docs.sqlalchemy.org/en/20/core/pooling.html
- SQLAlchemy 2.0, "Configuring a Version Counter": https://docs.sqlalchemy.org/en/20/orm/versioning.html
- psycopg 3, "Connection pools": https://www.psycopg.org/psycopg3/docs/advanced/pool.html
- HikariCP Wiki, "About Pool Sizing": https://github.com/brettwooldridge/HikariCP/wiki/About-Pool-Sizing
