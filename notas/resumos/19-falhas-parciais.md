# Resumo 19 — Falhas parciais

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- falha parcial: parte quebra, resto continua com visão incompleta
- modelos de falha: crash-stop, crash-recovery, omissão, temporização, bizantina
- gray failure (Huang, HotOS 2017); fail-slow (Gunawi, FAST 2018)
- chamada remota: sucesso, falha, "não sei"; timeout decide
- timeouts httpx (connect, read, write, pool); `read` = intervalo entre pedaços; teto total via `asyncio.timeout`
- escolha do timeout: percentil (p99,9 ≈ 0,1% falsos) + prazo do chamador; presas = taxa × timeout
- retry: erro transitório, idempotente, `Retry-After`; backoff exponencial com teto; jitter full/equal/decorrelated (Brooker 2015)
- retry storm (4⁵ = 1.024); retry budget 10% → 1,1×; falha metaestável (Bronson, HotOS 2021)
- circuit breaker fechado/aberto/meio-aberto; não contar 4xx; estado por processo
- bulkhead: semáforo por dependência, vagas pela Lei de Little; células
- deadline propagado relativo (`grpc-timeout`, cabeçalho próprio em HTTP, `SET LOCAL statement_timeout`)
- degradação controlada; fallback mais simples, exercitado, com métrica

## Termos e traduções adotados
- circuit breaker → circuit breaker (disjuntor)
- bulkhead → bulkhead (antepara)
- deadline → deadline; trabalho órfão
- graceful degradation → degradação controlada
- retry budget → orçamento de retries

## Casos reais e exemplos usados (não repetir)
- loja de cimento, `calcula-frete`, `TIMEOUT = 30` de 2019, 40 workers, painel verde
- `tcp_retries2 = 15` ≈ 924,6 s
- diálogo cobrança dupla `POST /pagamentos`
- classe `Disjuntor` com relógio falso; Resilience4j 50%/100 chamadas/60 s
- AWS EBS us-east-1, 21/04/2011, re-mirroring storm
- DynamoDB us-east-1, 20/09/2015, metadados, falha metaestável
