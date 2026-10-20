# Resumo 27 — Balanceamento e proxies

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- L4 decide por conexão (proxy completo, NAT de destino, DSR); L7 por requisição, vê status
- PROXY protocol v1 texto / v2 binário; `Forwarded` RFC 7239; XFF lido da direita até 1º não confiável; Uvicorn `--forwarded-allow-ips`
- balanceador redundante: VRRP/keepalived, ECMP, Maglev NSDI 2016, anycast
- round robin 1/N; smooth WRR nginx 5/1/1 → a a b a c a a; least connections atrai backend que erra rápido (Little); duas escolhas ln ln n/ln 2, teto ~2/N, Envoy LEAST_REQUEST, nginx `random two least_conn`; EWMA (Linkerd); hash consistente com cargas limitadas, `hash-balance-factor`; slow start
- health check ativo: detecção = intervalo × limiar; passivo Envoy 5×5xx, 30 s, máx. 10%; nginx open source só passivo
- liveness vs readiness; readiness só local; pânico Envoy <50%; fail open ALB
- sticky por cookie (AWSALB) ou IP (CGNAT)
- reverse proxy: buffer cliente lento, Slowloris, keepalive nginx exige `proxy_http_version 1.1` + `Connection ""`
- gateway; mesh sidecar, xDS, 2 proxies/chamada, ambient Istio 1.24; retries 3×3×3 = 27
- CDN: PoP, anycast; draining 300 s ALB

## Termos e traduções adotados
- sticky session → afinidade de sessão; outlier detection → health check passivo
- power of two choices → duas escolhas; slow start, draining, sidecar, origin shield em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: app passeio de cachorro, Seu Horácio, dachshund Biscoito, `passeio-04` 503 em 2 ms, 58%, latência 80→3 ms
- FastAPI `/vivo` `/pronto`; HAProxy `random(2)`
- Cloudflare WAF regex 02/07/2019, 27 min; Fastly 08/06/2021, 85%, 49 min
