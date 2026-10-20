# Resumo 12 — Migrações de schema sem downtime

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- todo SELECT pega ACCESS SHARE; lock de tabela dura até fim da transação
- fila de locks FIFO: pedido novo checa concedidos + pedidos à frente → ACCESS EXCLUSIVE esperando bloqueia leituras; evita starvation
- lock_timeout (por espera, erro 55P03 `canceling statement due to lock timeout`) + retry/backoff no pipeline; statement_timeout limita trabalho
- custo DDL = modo de lock + trabalho: catálogo / varredura / reescrita
- ADD COLUMN default constante/estável sem reescrita desde PG 11 (attmissingval); volátil reescreve; now() → mesmo valor em todas as linhas
- ALTER TYPE reescreve, exceto binário-compatível (varchar→text)
- NOT VALID + VALIDATE (SHARE UPDATE EXCLUSIVE); SET NOT NULL usa CHECK validado (PG 12+)
- CREATE INDEX = SHARE (bloqueia escritas); CONCURRENTLY: 2 varreduras, 3 esperas, fora de transação, falha → INVALID (pg_index.indisvalid); ADD CONSTRAINT USING INDEX
- regra: schema compatível com código atual e próximo (rolling + rollback)
- expand/contract = parallel change; analogia real: deprecar parâmetro
- backfill em lotes: PK em faixas, autocommit, pausa, idempotente, índice depois (HOT)
- Alembic: transação única por padrão → transaction_per_migration=True; autocommit_block; server_default

## Termos e traduções adotados
- expand/contract, parallel change, backfill, starvation, rolling em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: `0137_so_uma_coluna.py`, faturas 38 mi, relatório BI 9h36, ALTER 4 ms esperou 6 min, terça 10h14
- pedidos 60 mi valor → valor_centavos, 7 passos, trigger que recusa vendas; backfill 42 min
- ux_clientes_email duplicado ana@exemplo.com
- GoCardless post lock_timeout; Stripe 2017 online migrations; gh-ost, pt-osc, pgroll, squawk, strong_migrations
