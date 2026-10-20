# Resumo 28 — Controle de carga

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- rate limiting = limite por identidade (chave do limite); protege clientes entre si, não capacidade total
- janela fixa: INCR + EXPIRE, emenda deixa 2× limite, reset sincronizado
- janela deslizante: log (sorted set, memória ∝ limite) vs contador `anterior × (1 − decorrido/janela) + atual` (Cloudflare)
- token bucket: `b` rajada, `r` média, reposição calculada na hora, máximo `b + r × t`
- leaky bucket: medidor (= token bucket) vs fila/modelador; nginx limit_req rate/burst/nodelay
- GCRA: TAT, T = 1/r, τ = (b − 1)T, espera pronta; redis-cell
- distribuído: Redis central + Lua + TIME do Redis; fail open vs fail closed; local `limite / N`; lotes de fichas; Envoy local/global
- goodput; fila sem limite (asyncio.Queue maxsize=0); backpressure (janela TCP, `await put`) vs recusa (`QueueFull`)
- load shedding: concorrência (Little, Uvicorn `--limit-concurrency`), tempo na fila, adaptativo (Netflix concurrency-limits, Vegas), criticidade Google 4 níveis, CoDel 5/100 ms + LIFO adaptativo (Fail at Scale 2015)
- 429 RFC 6585 vs 503; Retry-After segundos ou data; rascunho RateLimit-Policy/RateLimit; throttling adaptativo cliente K=2, 2 min

## Termos e traduções adotados
- token → ficha; burst → rajada
- rate limiting, load shedding, backpressure, goodput, fail open/closed em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: API previsão do tempo, 6h03, 4.000 vs 140 req/s, Cooperativa Vale do Milho, `sync_chuva.py`, 5.570 municípios; v2 em 900 cooperativas, `Retry-After: 37`
- TokenBucket b=5 r=1; Lua Redis 100/10, 103 → 3 recusas; middleware ASGI 503 maximo=30, `/pronto` fora
- Stripe rate limiters 2017
