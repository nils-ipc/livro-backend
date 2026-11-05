# Resumo 28 — Controle de carga

## A Lastro ao fim do capítulo
- incidente segunda 11h02: Hornero laço reconciliação sem parada, `GET /v1/cobrancas/{id}` 4.000/s, sem `If-None-Match`, 40 conexões; ~1,5 ms CPU/GET → 2/3 de cada loop; autorização p99 1,3 → 4,8 s; Pix Bazar estoura 10 s; URGENTE 11h09 "Pix mais lento que o meu"; Carlos bloqueou IP Hornero no firewall 11h20 → Hornero 25 min sem vender
- limitação no gateway por `(marketplace, classe)`, GCRA → requisito isolamento entre marketplaces, nunca por IP
- classes: escrita 50/s b100 (Bazar 300/600); leitura 200/s b400 (Bazar 1.000/2.000); painel (GraphQL, relatórios) 20/s b40 (Bazar 60/120); `webhooks-pix` sem limite (banco desiste após 3)
- valores ~10× pico medido de cada marketplace
- estado no Redis de cache (cap. 22), ~120 chaves, ~0,4 ms; Redis fora → `limite / 3` local por gateway (fail open aproximado)
- resposta `429` + `Retry-After` + `type` `limite-de-taxa`; changelog 30 dias; limite de emergência por marketplace sem deploy ("firewall com pontaria"); e-mail automático se `429` > 50% por 5 min
- pagamentos: classes crítica (autorização, criação Pix, notificação banco) / normal (captura, estorno, GET) / descartável (GraphQL, listagens); lag loop > 50 ms → `503` descartáveis `Retry-After: 5`; > 150 ms também normais; críticas só bulkheads cap. 15; middleware antes de banco
- relatórios: 2 em execução + 5 em fila por processo; 6º `503` `Retry-After: 60`
- gateway: concorrência máx por rota; espera > 1 s → `503`
- health check fora do descarte
- Hornero em loop agora = 3% CPU
- próximo: contrato marketplace grupo de varejo 10× Bazar, migração em 4 meses; gerente "multiplicar tudo por dez" (cap. 29)

## Conceitos aprofundados aqui
- `S/(1−ρ)`; goodput → 0
- janela fixa (2× fronteira), sliding log, sliding counter, token bucket, leaky bucket (fila × medidor), GCRA
- distribuído: central, local/N (falha com L4 por conexão), híbrido; fail open/closed
- 429 × 503, Retry-After, rascunho RateLimit headers; throttling adaptativo cliente Google SRE (K = 2)
- filas limitadas, contrapressão, CoDel (RFC 8289), LIFO adaptativo
- descarte cedo, adaptativo, por prioridade; classe sacrificada precisa disputar o mesmo recurso

## Casos reais usados
- Cloudflare 2017 sliding counter (400 mi, 0,003%); Stripe 2017 4 limitadores; Facebook Fail at Scale 2015

## Piadas recorrentes
- analista Hornero sem crochê (abrindo chamado), volta ao crochê
- goodput = sistema mais produtivo e inútil, concorre com comitê de arquitetura
- PostgreSQL do ledger "começou a suar"
