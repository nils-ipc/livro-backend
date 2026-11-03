# Resumo 04 — Locks, contenção e pools de conexão

## A Lastro ao fim do capítulo
- incidente 21h04, terça, 4º dia "Black Friday o mês inteiro": 3.800 `QueuePool limit of size 5 overflow 10 reached ... timeout 30.00`; API toda parada; Bazar avisou antes do monitoramento
- causa: `contas.saldo_cache` (Carlos, pedido do gerente; `SUM` comissão 2,1 mi lançamentos = 1,4 s) via trigger UPDATE + webhook ao Bazar (250 ms) dentro da transação → posse ~260 ms, teto 3,8/s vs pico 12/s; deadlock pagamento × estorno (ordem do cache)
- `saldo_cache` removido; contas quentes (liquidante, receita, comissão de cada marketplace) → `saldos_parciais (conta_id, balde, saldo)`, 16 baldes, balde = `hash(cobranca_id) % 16`, último comando antes do COMMIT, posse ~2 ms → requisito painel tempo real + conciliação exata
- contas de vendedor sem cache (SUM)
- webhook após COMMIT (ainda na requisição → cap. 17)
- ordem `(conta_id, balde)` p/ toda escrita em conta; pagamento retenta `40P01`
- trigger débito: `FOR UPDATE` → `FOR NO KEY UPDATE` (não bloqueia FK `FOR KEY SHARE` dos créditos)
- pool: `pool_size=5`, `max_overflow=0`, `pool_timeout=3` × 3 workers = 15; `lock_timeout` 2 s; `idle_in_transaction_session_timeout` 5 s
- PostgreSQL: 8 núcleos, SSD; teto útil ~17–20 conexões ativas
- sem PgBouncer até caps. 26/35
- descartados: agregação assíncrona (`SKIP LOCKED`), otimista na conta quente
- próximo: extrato vendedor por período, 40 mi lançamentos, 6 s (cap. 05)

## Conceitos aprofundados aqui
- locks de tabela (8 modos), de linha (4 modos, `xmax`, espera = `transactionid`/`tuple`)
- teto `1/t` por linha; pool esgotado propaga contenção
- `NOWAIT` (55P03), `lock_timeout`, `SKIP LOCKED`
- otimista com versão
- `deadlock_timeout` 1 s
- conexão = processo; pools app × PgBouncer (session/transaction/statement; 1.21 prepared)
- Little + HikariCP `núcleos × 2 + discos`

## Termos
- conta quente; baldes; tempo de posse

## Casos reais usados
- `prepared statement "S_1" does not exist` (pgJDBC `prepareThreshold` 5)

## Piadas recorrentes
- Carlos: commit "saldo instantâneo, zero risco"; pool 50 às 21h20 ("teste de carga"); pediu 1.024 baldes "por segurança"
- timeout 30 s: ninguém configurou, padrão SQLAlchemy
- lock de linha = herança, só no velório; PgBouncer transaction = motel
