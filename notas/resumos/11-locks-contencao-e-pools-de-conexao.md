# Resumo 11 — Locks, contenção e pools de conexão

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- lock de linha PG: ID da transação no `xmax`, dura até COMMIT/ROLLBACK; espera = `ShareLock` no ID da dona; lock `tuple` ordena fila; sem limite de linhas; FOR UPDATE gera WAL
- 4 modos de linha: FOR UPDATE, FOR NO KEY UPDATE, FOR SHARE, FOR KEY SHARE (FK, 9.3)
- 8 modos de tabela; fila FIFO: ACCESS EXCLUSIVE à espera bloqueia SELECTs seguintes → cap. 12
- NOWAIT (55P03), SKIP LOCKED (9.5, filas/itens intercambiáveis); RC reavalia WHERE
- controle otimista: coluna versao, UPDATE 0; SQLAlchemy version_id_col → StaleDataError
- deadlock PG: deadlock_timeout 1 s, 40P01, ordem fixa via SELECT ... ORDER BY FOR UPDATE
- vazão de linha disputada = 1/tempo travado
- conexão = processo (fork), TCP+TLS+SCRAM; max_connections 100, 3 reservadas
- SQLAlchemy QueuePool 5 + 10 overflow, pool_timeout 30 s; conexões possíveis = réplicas × processos × (pool+overflow)
- PgBouncer: session/transaction/statement; transaction quebra SET, advisory de sessão, LISTEN, WITH HOLD; prepared statements 1.21 max_prepared_statements; default_pool_size 20
- dimensionamento: Little + teto núcleos; wiki PG (núcleos×2)+discos
- idle_in_transaction_session_timeout 9.6, transaction_timeout 17, FOR UPDATE OF

## Termos e traduções adotados
- lock, pool, checkout/checkin, pooler em inglês; lock pessimista/otimista

## Casos reais e exemplos usados (não repetir)
- hipotético: venda de ingressos banda de 1998, 37 ingressos em 31 s, gateway 800 ms dentro de FOR UPDATE, CPU 4%
- 12 réplicas × 4 × 15 = 720 conexões; autoscaling 30 → 1.800
- pg_stat_activity + pg_blocking_pids; ingressos SKIP LOCKED [1..8]; deadlock assentos 10/20
- HikariCP/Oracle: pool 2.048 → 96, ~100 ms → ~2 ms
