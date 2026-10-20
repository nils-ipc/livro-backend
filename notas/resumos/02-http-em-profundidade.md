# Resumo 02 — HTTP em profundidade

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- RFCs: 9110 semântica, 9111 cache, 9112/9113/9114 formato no fio por versão
- HTTP/1.1: texto, CRLF, Host obrigatório, chunked, request smuggling (1 frase)
- keep-alive: HTTPS novo = 2 RTT; pipelining desligado; ~6 conexões por origem
- HTTP/2: frames 9 bytes, streams, MAX_CONCURRENT_STREAMS ≥100, ALPN h2, push removido Chrome 2022; HOL no TCP
- HPACK: tabela estática 61, dinâmica 4.096 bytes, Huffman
- HTTP/3: QUIC/UDP, 1 RTT, 0-RTT + replay + 425, Connection ID, QPACK, Alt-Svc, registro HTTPS
- seguro vs idempotente (definições RFC 9110); retry automático só idempotente
- status: 301/302 vs 307/308, 401 vs 403, 429/503 Retry-After, 502/504 vindos do proxy
- cache: fresca/velha, max-age, s-maxage, heurística 10% Last-Modified, no-cache vs no-store, private, ETag/W/, 304, If-Match→412, Vary
- CORS: origem = esquema+host+porta, simples vs preflight, Max-Age teto 2 h Chromium/24 h Firefox, `*` proibido com credenciais, não protege contra CSRF
- corrida keep-alive: timeout app (Uvicorn 5 s) < balanceador (60 s) → 502

## Termos e traduções adotados
- fresh/stale → fresca/velha
- head-of-line blocking, preflight, keep-alive mantidos em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: `GET /pedidos/{id}/cancelar` em e-mail, scanner de links cancela 214 pedidos
- preço antigo 1 h (max-age=3600); `Access-Control-Allow-Origin: *` "fix definitivo"
- httpx sem/com Client: 9,61 s vs 3,62 s; ETag FastAPI `"15d172abbe2c1c11"`
- HTTP/2 Rapid Reset CVE-2023-44487, Google 398 mi rps
- Steam Natal 2015, cache, ~34 mil usuários
