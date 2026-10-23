# Migrações de schema sem downtime

## A migração de uma linha que derrubou o site por seis minutos

O arquivo se chama `0137_so_uma_coluna.py`, tem uma operação e foi aprovado no code review por duas pessoas, uma delas com o comentário "trivial".

```python
def upgrade() -> None:
    op.add_column("faturas", sa.Column("desconto_pct", sa.Numeric(5, 2)))
```

Em staging, levou 4 ms. Em produção, a tabela `faturas` tem 38 milhões de linhas, mas isso não preocupa ninguém: no PostgreSQL, adicionar uma coluna anulável sem default só altera o catálogo, e o tamanho da tabela nem entra na conta. A equipe sabia disso. E estava certa.

Numa terça-feira, às 10h14min03s, o pipeline aplica a migração. Às 10h14min05s, o p99 da API vai de 80 ms para 30 s, o timeout do balanceador. Às 10h15, os pools de conexão estão esgotados e o `/health` falha, o que faz o orquestrador reiniciar os pods, o que abre mais conexões, o que não ajuda. Às 10h20, alguém encontra no `pg_stat_activity` uma consulta iniciada às 9h36: o relatório de inadimplência do mês, disparado por uma ferramenta de BI, lendo `faturas` inteira com a serenidade de quem não tem SLO. A consulta é cancelada, o `ALTER TABLE` termina em 4 ms, exatamente como prometido, e o site volta.

O comando levou 4 ms para executar e seis minutos esperando, e durante a espera ninguém leu uma única fatura. Como um comando que não faz nada pesado consegue parar todas as leituras de uma tabela? E, já que o schema precisa mudar com a aplicação no ar, em que ordem fazer cada mudança para que nenhum usuário perceba?

## Locks de DDL e a fila que ninguém vê

Toda instrução no PostgreSQL adquire um *lock* na tabela que toca, inclusive o `SELECT` mais inocente. Dos oito modos (o capítulo 11 trata deles), seis importam aqui:

| Modo | Quem pede | Conflita com |
|------|-----------|--------------|
| `ACCESS SHARE` | `SELECT` | só `ACCESS EXCLUSIVE` |
| `ROW EXCLUSIVE` | `INSERT`, `UPDATE`, `DELETE` | `SHARE` e os mais fortes |
| `SHARE UPDATE EXCLUSIVE` | `VACUUM`, `CREATE INDEX CONCURRENTLY`, `VALIDATE CONSTRAINT` | ele mesmo e os mais fortes; leituras e escritas passam |
| `SHARE` | `CREATE INDEX` | escritas e DDL; leituras passam |
| `SHARE ROW EXCLUSIVE` | `ADD FOREIGN KEY`, `CREATE TRIGGER` | escritas e DDL; leituras passam |
| `ACCESS EXCLUSIVE` | a maioria dos `ALTER TABLE`, `DROP`, `TRUNCATE` | tudo, inclusive `SELECT` |

Dois fatos explicam o incidente das 10h14. O primeiro: um lock de tabela dura até o fim da transação. O relatório de BI pegou `ACCESS SHARE` às 9h36 e só ia devolver quando terminasse, o que, pelo plano de execução, ia acontecer lá pelas 10h20. O `ALTER TABLE` precisa de `ACCESS EXCLUSIVE`, que conflita com `ACCESS SHARE`, então espera.

O segundo fato é o que pega todo mundo: os pedidos de lock formam uma fila por ordem de chegada, e um pedido novo precisa ser compatível com os locks concedidos e também com os pedidos que estão na frente dele na fila. O `SELECT` das 10h14min04s quer `ACCESS SHARE`. Ele é compatível com o relatório, mas não com o `ALTER` que está esperando na frente. Então entra na fila também.

```text
09:36:00  relatório BI   ACCESS SHARE em faturas      concedido (vai até 10:20)
10:14:03  ALTER TABLE    ACCESS EXCLUSIVE             espera o relatório
10:14:04  SELECT #1      ACCESS SHARE                 espera o ALTER
10:14:04  SELECT #2      ACCESS SHARE                 espera o ALTER
   ...    (todas as leituras e escritas em faturas, até esgotar os pools)
10:20:11  relatório cancelado → ALTER executa em 4 ms → a fila anda
```

Sem essa regra, um fluxo contínuo de `SELECT`s deixaria o `ALTER` esperando para sempre (*starvation*). A fila é justa: todo mundo espera o relatório junto com o `ALTER`.

Logo, qualquer comando que pede `ACCESS EXCLUSIVE` é perigoso, por mais instantâneo que seja, se houver uma transação longa na tabela: um relatório, um `pg_dump`, a sessão `idle in transaction` de quem abriu o `psql` em produção, digitou `BEGIN` e foi almoçar.

A defesa é o `lock_timeout`. Com `SET lock_timeout = '2s'`, o `ALTER` que não consegue o lock em 2 segundos desiste com `canceling statement due to lock timeout`, sai da fila, e as consultas atrás dele seguem. O pior caso vira um pico de 2 segundos em vez de seis minutos de site fora, e a migração é repetida mais tarde, com *backoff*. Uma migração que falha e é repetida é um evento sem graça nenhuma, que é exatamente o objetivo. Para limitar o trabalho feito depois de obter o lock (uma reescrita que ninguém previu), existe o `statement_timeout`.

## O que o PostgreSQL faz em cada ALTER TABLE

Uma operação de schema custa o modo de lock que pede e o trabalho feito sob ele. Mudar só o catálogo leva milissegundos. Varrer a tabela leva o tempo de ler todas as páginas. Reescrever cria um arquivo novo com todas as linhas e reconstrói os índices, e em 38 milhões de linhas isso se mede em minutos ou horas, sob `ACCESS EXCLUSIVE`.

| Operação (PostgreSQL 16) | Lock | Trabalho | Forma segura |
|--------------------------|------|----------|--------------|
| `ADD COLUMN` anulável, ou com default constante/estável | `ACCESS EXCLUSIVE` | catálogo | já é segura |
| `ADD COLUMN` com default volátil (`gen_random_uuid()`) | `ACCESS EXCLUSIVE` | reescrita | sem default + backfill |
| `ALTER COLUMN TYPE` (`integer` → `bigint`) | `ACCESS EXCLUSIVE` | reescrita + índices | expand/contract |
| `ALTER COLUMN TYPE` binário-compatível (`varchar` → `text`) | `ACCESS EXCLUSIVE` | catálogo | já é segura |
| `SET NOT NULL` | `ACCESS EXCLUSIVE` | varredura | `CHECK` validado antes (PG 12+) |
| `ADD CHECK`, `ADD FOREIGN KEY` | `ACCESS EXCLUSIVE`, `SHARE ROW EXCLUSIVE` | varredura | `NOT VALID` + `VALIDATE` |
| `CREATE INDEX`, `ADD UNIQUE` | `SHARE`, `ACCESS EXCLUSIVE` | constrói índice | `CONCURRENTLY` |
| `RENAME`, `DROP COLUMN` | `ACCESS EXCLUSIVE` | catálogo | seguro para o banco, não para o código |

Até o PostgreSQL 10, `ADD COLUMN ... DEFAULT 0 NOT NULL` reescrevia a tabela inteira. A partir do 11, o banco guarda o valor no catálogo (`pg_attribute.attmissingval`) e o devolve ao ler uma linha antiga que não tem a coluna fisicamente. O truque exige o mesmo valor para todas as linhas, e por isso um default volátil continua reescrevendo tudo. `now()` é `STABLE`: é avaliado uma vez, no momento do `ALTER`, e as 38 milhões de faturas antigas passam a ter exatamente o mesmo `criado_em`, com precisão de microssegundo. É barato. E é uma ótima forma de confundir o time de dados no ano seguinte.

Uma restrição criada com `NOT VALID` vale para toda linha escrita a partir dali, mas o banco não confere as existentes, e o `ADD` vira mudança de catálogo. Depois, `VALIDATE CONSTRAINT` varre a tabela segurando só `SHARE UPDATE EXCLUSIVE`. A varredura continua longa; a diferença é que ninguém espera por ela. Desde o PostgreSQL 12, o `SET NOT NULL` aceita um `CHECK (coluna IS NOT NULL)` validado como prova e pula a varredura.

Renomear é o caso curioso: para o banco, é a operação mais barata possível. O código em produção, porém, continua fazendo `SELECT fone FROM clientes`, e a coluna `fone` deixou de existir 4 ms atrás.

## Índices sem parar as escritas

O `CREATE INDEX` comum pega `SHARE`, que deixa as leituras passarem e bloqueia todo `INSERT`, `UPDATE` e `DELETE` até o índice ficar pronto. Numa tabela grande, isso é uma janela de manutenção que ninguém agendou.

O `CREATE INDEX CONCURRENTLY` pega `SHARE UPDATE EXCLUSIVE`, que convive com escritas, e paga com mais trabalho. O índice entra no catálogo como inválido; o banco espera terminarem as transações que poderiam escrever sem saber dele, constrói o índice numa primeira varredura, espera de novo, faz uma segunda passada para incluir o que mudou no meio do caminho, espera as transações com snapshots antigos e só então marca o índice como válido. Duas varreduras, três esperas, bem mais tempo e I/O que a versão comum.

As esperas têm uma consequência: uma única transação aberta há três horas segura o `CONCURRENTLY` por três horas. Ele não bloqueia ninguém enquanto espera. Só não termina.

O comando também não pode rodar dentro de um bloco de transação, porque comita etapas intermediárias. E, se falhar no meio, o índice fica marcado como `INVALID`: o planner o ignora, mas cada escrita continua a atualizá-lo. Todos os custos de um índice, nenhum benefício. A saída é `DROP INDEX CONCURRENTLY` e tentar de novo, ou `REINDEX INDEX CONCURRENTLY` (PG 12+). Para `UNIQUE` e chave primária, cria-se o índice único com `CONCURRENTLY` e depois `ADD CONSTRAINT ... USING INDEX`, que só mexe no catálogo.

## Expand/contract, ou como renomear uma coluna em quatro deploys

Até aqui, o problema era o banco. Agora o problema é o código. Num deploy *rolling* (o capítulo 37 trata das estratégias de deploy), as réplicas são substituídas aos poucos, e durante alguns minutos a versão antiga e a nova atendem tráfego ao mesmo tempo, no mesmo banco. Se houver rollback, a versão antiga volta a rodar sobre o schema que a nova deixou. Disso sai a regra que governa tudo:

> Cada mudança de schema precisa ser compatível com o código que está em produção e com o código que vai entrar em produção.

Mudança incompatível nenhuma passa nessa regra em um passo só. O padrão *expand/contract* (ou *parallel change*) divide a mudança em fases: o schema ganha a estrutura nova sem perder a antiga, o código migra para a nova enquanto os dados são copiados, e a antiga sai quando nenhuma versão em produção a usa. A sequência é a mesma de deprecar um parâmetro de uma função pública numa biblioteca Python: a versão 2.3 aceita os dois nomes e emite `DeprecationWarning`, e só a 3.0 remove o antigo. A diferença é que, aqui, quem chama a função com o parâmetro antigo é a sua própria aplicação, em produção, e ela não lê warnings.

Exemplo: a tabela `pedidos`, com 60 milhões de linhas, guarda `valor numeric(10,2)` em reais e vai passar a guardar `valor_centavos bigint`. Um `ALTER COLUMN TYPE` reescreveria a tabela sob `ACCESS EXCLUSIVE` e quebraria o código antigo. Em fases:

| Passo | Banco | Código em produção |
|-------|-------|--------------------|
| 1 | `ADD COLUMN valor_centavos bigint` (anulável) + trigger que preenche `valor_centavos` a partir de `valor` | v1 (só conhece `valor`) |
| 2 | backfill em lotes das linhas antigas | v1 |
| 3 | `CHECK (valor_centavos IS NOT NULL) NOT VALID`, `VALIDATE`, `SET NOT NULL`, remove o `CHECK` | v1 |
| 4 | nada | deploy da v2: escreve as duas colunas, lê `valor_centavos`; v1 e v2 convivem |
| 5 | remove o trigger; `ALTER COLUMN valor DROP NOT NULL` | v2 |
| 6 | nada | deploy da v3: o modelo não tem mais `valor` |
| 7 | `DROP COLUMN valor` | v3 |

O trigger cobre a janela em que a v1 escreve só em `valor`, e a ordem dos passos 5 e 6 tem um motivo pouco intuitivo: com o trigger ativo, cada `INSERT` da v3 chegaria com `valor` nulo, o trigger gravaria `round(NULL * 100)` em `valor_centavos` e o `NOT NULL` recusaria o pedido. O trigger que protegia os dados passaria a recusar todas as vendas, com total dedicação.

Só o passo 7 é irreversível, e por isso fica por último, depois que a v3 está em todas as réplicas. Um rename de coluna segue o mesmo roteiro, sem a conversão.

## Backfill em lotes

O passo 2 parece trivial: `UPDATE pedidos SET valor_centavos = round(valor * 100)`. Em 60 milhões de linhas, numa transação só, esse comando cria vários problemas de uma vez.

No MVCC do PostgreSQL (capítulo 10), um `UPDATE` grava uma versão nova de cada linha: a tabela quase dobra, e o `VACUUM` não limpa nada enquanto a transação estiver aberta. Cada linha fica com lock até o `COMMIT`, então qualquer pedido que a aplicação tente atualizar espera, talvez por uma hora. O WAL sai todo de uma vez e as réplicas ficam para trás (capítulo 13). E, se o comando falhar aos 95%, o `ROLLBACK` desfaz tudo, e o banco terá passado uma hora convertendo I/O em calor.

O backfill em lotes divide o trabalho em transações de alguns milhares de linhas, percorridas pela chave primária. Cada lote comita, libera seus locks em milissegundos e deixa o autovacuum trabalhar; uma pausa entre lotes limita a taxa de WAL. A condição `WHERE valor_centavos IS NULL` torna o processo idempotente: se parar no meio, recomeça e pula o que já foi feito. O índice na coluna nova, se houver, vem depois: sem índice na coluna atualizada, o `UPDATE` pode ser HOT (*heap-only tuple*, capítulo 8) e nenhum índice precisa saber da versão nova.

## Na prática: a fila, o timeout e o lote

Durante o incidente das 10h14, esta consulta mostra a fila inteira:

```sql
SELECT pid, wait_event_type AS espera, pg_blocking_pids(pid) AS bloqueado_por,
       now() - query_start AS ha, left(query, 45) AS consulta
FROM pg_stat_activity
WHERE datname = current_database() AND pid <> pg_backend_pid()
ORDER BY query_start;
```

```text
  pid  | espera | bloqueado_por |       ha        |                   consulta
-------+--------+---------------+-----------------+-----------------------------------------------
 41207 |        | {}            | 00:40:11.83     | SELECT cliente_id, sum(valor) FROM faturas WH
 41388 | Lock   | {41207}       | 00:02:08.61     | ALTER TABLE faturas ADD COLUMN desconto_pct n
 41390 | Lock   | {41388}       | 00:02:08.58     | SELECT id, status, valor FROM faturas WHERE i
 41391 | Lock   | {41388}       | 00:02:08.57     | SELECT id, status, valor FROM faturas WHERE i
 41395 | Lock   | {41388}       | 00:02:08.51     | UPDATE faturas SET status = $1 WHERE id = $2
(... 312 linhas)
```

O `pg_blocking_pids` lista quem segura um lock conflitante e também quem está na frente na fila com um pedido conflitante. Por isso os `SELECT`s aparecem bloqueados pelo `ALTER` (41388), e não pelo relatório. O culpado está no topo, com 40 minutos de idade e a consciência tranquila.

A versão segura da `0137_so_uma_coluna.py` tem uma linha a mais:

```python
def upgrade() -> None:
    op.execute("SET LOCAL lock_timeout = '2s'")
    op.add_column("faturas", sa.Column("desconto_pct", sa.Numeric(5, 2)))
```

`SET LOCAL` limita a configuração à transação da migração. Com o relatório ainda rodando, a saída do pipeline fica assim:

```text
INFO  [alembic.runtime.migration] Running upgrade 0136 -> 0137, so uma coluna
sqlalchemy.exc.OperationalError: (psycopg.errors.LockNotAvailable) canceling statement due to lock timeout
tentativa 1: lock ocupado, nova tentativa em 10 s
INFO  [alembic.runtime.migration] Running upgrade 0136 -> 0137, so uma coluna
sqlalchemy.exc.OperationalError: (psycopg.errors.LockNotAvailable) canceling statement due to lock timeout
tentativa 2: lock ocupado, nova tentativa em 20 s
```

O laço do pipeline que produz essa saída:

```bash
for tentativa in 1 2 3 4 5; do
  if alembic upgrade head; then exit 0; fi
  echo "tentativa $tentativa: lock ocupado, nova tentativa em $((tentativa * 10)) s"
  sleep $((tentativa * 10))
done
echo "desisti: alguém está segurando a tabela faturas" >&2
exit 1
```

No pior caso, cinco picos de 2 segundos na API e uma mensagem de erro honesta.

O índice concorrente, no Alembic, precisa sair da transação da migração, e o `autocommit_block` existe para isso:

```python
def upgrade() -> None:
    with op.get_context().autocommit_block():
        op.create_index(
            "ux_clientes_email", "clientes", ["email"],
            unique=True, postgresql_concurrently=True,
        )
```

Quando a tabela tem duplicatas que ninguém sabia que existiam, o resultado é este:

```text
ERROR:  could not create unique index "ux_clientes_email"
DETAIL:  Key (email)=(ana@exemplo.com) is duplicated.
```

```sql
SELECT indexrelid::regclass AS indice FROM pg_index WHERE NOT indisvalid;
```

```text
      indice
-------------------
 ux_clientes_email
(1 row)
```

O índice que falhou continua lá, sendo atualizado a cada `INSERT`, até alguém procurar por `indisvalid`, de preferência antes do primeiro aniversário dele.

O backfill do passo 2, com psycopg 3:

```python
import os
import time

import psycopg

LOTE = 5_000
PAUSA_S = 0.2  # o banco também tem outros clientes, e eles pagam

with psycopg.connect(os.environ["DATABASE_URL"], autocommit=True) as conn:
    conn.execute("SET statement_timeout = '30s'")
    (maior_id,) = conn.execute("SELECT max(id) FROM pedidos").fetchone()
    inicio_backfill = time.monotonic()
    total = 0

    for inicio in range(0, maior_id, LOTE):
        cur = conn.execute(
            """
            UPDATE pedidos
               SET valor_centavos = round(valor * 100)
             WHERE id > %s AND id <= %s
               AND valor_centavos IS NULL
            """,
            (inicio, inicio + LOTE),
        )
        total += cur.rowcount
        if (inicio + LOTE) % 10_000_000 == 0:
            print(f"até id {inicio + LOTE:,}: {total:,} linhas")
        time.sleep(PAUSA_S)

    minutos = (time.monotonic() - inicio_backfill) / 60
    print(f"fim: {total:,} linhas em {minutos:.0f} min")
```

```text
até id 10,000,000: 9,982,114 linhas
até id 20,000,000: 19,961,530 linhas
até id 30,000,000: 29,940,877 linhas
até id 40,000,000: 39,918,302 linhas
até id 50,000,000: 49,899,640 linhas
até id 60,000,000: 59,873,204 linhas
fim: 59,873,204 linhas em 42 min
```

Com `autocommit=True`, cada `UPDATE` é uma transação própria; os buracos da sequência explicam o total abaixo do maior id, e os 12 mil lotes de 0,2 s de pausa explicam os 42 minutos. Um backfill de produção também consulta o lag das réplicas entre lotes e desacelera quando ele cresce. É mais lento que um `UPDATE` único, e ninguém na empresa percebeu que ele existiu.

## Propriedades e custos

Para uma mudança que o PostgreSQL não faz só no catálogo, existem três caminhos.

| | DDL direto em janela de manutenção | Expand/contract manual | Ferramenta de migração online |
|---|---|---|---|
| Indisponibilidade | durante toda a reescrita | picos de até `lock_timeout` | picos curtos na troca final |
| Número de deploys | 1 | 3 a 4 | 1 a 2 |
| Duração total | minutos a horas, concentrados | dias, espalhados | horas |
| Reversão | nova reescrita | trivial até o `DROP` | depende da ferramenta |
| Complexidade | baixa | código e trigger temporários | uma dependência a mais no caminho crítico |

O DDL direto custa a indisponibilidade inteira e não deixa código temporário. Cabe quando a tabela é pequena (uma reescrita de 50 mil linhas dura menos que o `lock_timeout`) ou quando há janela de manutenção. O expand/contract funciona em qualquer banco, sem ferramenta, mas espalha a mudança por vários deploys, e alguém precisa lembrar do passo 7. O `TODO: remover valor depois do deploy` tem o mesmo destino de todos os outros TODOs.

Para MySQL, gh-ost e pt-online-schema-change criam uma tabela fantasma com o schema novo, copiam os dados em lotes, aplicam as escritas concorrentes (pelo binlog no gh-ost, por triggers no pt-osc) e trocam os nomes no fim. No PostgreSQL, o pgroll automatiza o expand/contract com colunas sombra e uma view por versão do schema. Linters como squawk (SQL de PostgreSQL) e strong_migrations (Rails) recusam no CI as operações perigosas. Cada ferramenta é uma peça a mais para depurar no dia em que ela parar no meio de uma troca.

## Armadilhas e casos reais

> **Armadilha:** o Alembic, por padrão, aplica todas as migrações pendentes numa única transação no PostgreSQL. Os locks se acumulam: o `ACCESS EXCLUSIVE` pego pela primeira migração fica preso enquanto a quinta reescreve outra tabela. `transaction_per_migration=True` no `context.configure` do `env.py` comita cada migração separadamente.

> **Armadilha:** o SQLAlchemy e o Django geram `SELECT` com a lista explícita de colunas do modelo. Um `DROP COLUMN` enquanto a versão anterior ainda roda quebra toda consulta à tabela, mesmo as que nem usavam a coluna. Primeiro sai do modelo, depois do banco.

> **Armadilha:** `default=` no SQLAlchemy é preenchido pela aplicação. Uma coluna nova `NOT NULL` com default só no código quebra os `INSERT`s da versão antiga; durante o deploy, o default precisa estar no banco (`server_default`).

> **Armadilha:** `SELECT *` em prepared statements. Depois de um `ADD COLUMN`, o formato do resultado muda e a execução falha com `cached plan must not change result type`. Listar as colunas evita o problema.

> **Na vida real:** a GoCardless publicou o post "Zero-downtime Postgres migrations - the hard parts", que descreve a fila de locks atrás de um `ALTER TABLE` aprendida em produção e a defesa com `lock_timeout`. A biblioteca que eles publicaram depois para Rails (`activerecord-safer_migrations`) aplica esse timeout por padrão.

> **Na vida real:** a Stripe descreveu em 2017, em "Online migrations at scale", uma migração de assinaturas em quatro fases (escrita dupla, troca das leituras, troca das escritas, remoção do antigo): expand/contract sobre centenas de milhões de registros.

## Resumo

- Locks de tabela duram até o fim da transação; um `ACCESS EXCLUSIVE` na fila bloqueia até as leituras que chegam depois.
- `lock_timeout` curto em toda migração, com retry no pipeline.
- Catálogo é barato; varredura e reescrita sob `ACCESS EXCLUSIVE` são o perigo.
- `NOT VALID` + `VALIDATE`, `CHECK` antes de `SET NOT NULL`, `CREATE INDEX CONCURRENTLY` (e conferir `INVALID`).
- Cada mudança de schema funciona com o código atual e com o próximo; expand/contract deixa o `DROP` por último.
- Backfill em lotes por chave primária, com commit, pausa e idempotência.

## Referências

- PostgreSQL 16, Explicit Locking: <https://www.postgresql.org/docs/16/explicit-locking.html>
- PostgreSQL 16, `ALTER TABLE` (modos de lock por subcomando, `NOT VALID`, reescritas): <https://www.postgresql.org/docs/16/sql-altertable.html>
- PostgreSQL 16, `CREATE INDEX`, Building Indexes Concurrently: <https://www.postgresql.org/docs/16/sql-createindex.html#SQL-CREATEINDEX-CONCURRENTLY>
- PostgreSQL 16, `lock_timeout` e `statement_timeout`: <https://www.postgresql.org/docs/16/runtime-config-client.html>
- PostgreSQL 11 Release Notes (`ADD COLUMN` com default sem reescrita): <https://www.postgresql.org/docs/release/11.0/>
- Alembic, Runtime Objects (`autocommit_block`, `transaction_per_migration`): <https://alembic.sqlalchemy.org/en/latest/api/runtime.html>
- Danilo Sato, "ParallelChange" (2014): <https://martinfowler.com/bliki/ParallelChange.html>
- Stripe, "Online migrations at scale" (2017): <https://stripe.com/blog/online-migrations>
- GoCardless, "Zero-downtime Postgres migrations - the hard parts": <https://gocardless.com/blog/zero-downtime-postgres-migrations-the-hard-parts/>
- gh-ost: <https://github.com/github/gh-ost>
- pgroll: <https://github.com/xataio/pgroll>
- squawk: <https://github.com/sbdchd/squawk>
- strong_migrations: <https://github.com/ankane/strong_migrations>
