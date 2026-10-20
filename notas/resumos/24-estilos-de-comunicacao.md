# Resumo 24 — Estilos de comunicação

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- REST Fielding 2000: restrições, HATEOAS raro; mercado = JSON/HTTP + RFC 9110; Fielding 2008 "hypertext-driven"
- Protobuf: tag = (campo << 3) | tipo; tipos 0/1/2/5, 3/4 groups; VARINT 150 → 96 01; nome não viaja; `reserved`; campo desconhecido pulado; proto3 padrão não transmitido, `optional`
- gRPC: HTTP/2 obrigatório, `:path /pacote.Servico/Metodo`, prefixo 5 bytes (flag + tamanho), `grpc-status` nos trailers com HTTP 200, 17 códigos; `grpc-timeout`; 4 formatos; gRPC-Web só unário + streaming servidor; sem cache HTTP; limite 4 MB `RESOURCE_EXHAUSTED`
- GraphQL: query paralela, mutation em série, subscription; 200 + `errors` vs `application/graphql-response+json`; resolvers → N+1; DataLoader por requisição, ordem das chaves; profundidade, custo, GitHub (1–100, 500 mil nós, 5.000 pontos/h); persisted queries por GET; aliases contornam rate limit
- polling, long polling; SSE `text/event-stream`, `Last-Event-ID`, `retry:`, comentário ping, `X-Accel-Buffering: no`, 6 conexões HTTP/1.1
- WebSocket RFC 6455: handshake 101, Accept = SHA-1 + GUID, frames 2–14 bytes, opcodes, máscara cliente (Huang 2011), sem retomada, sem cabeçalhos no navegador, CSWSH/Origin
- conexões longas: descritores, pub/sub entre réplicas, drenagem + jitter no deploy; gRPC em L4 cola réplica

## Termos e traduções adotados
- overfetching, underfetching, trailers, resolver, DataLoader, persisted queries, long polling em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: Dona Zuleica, pizza meia calabresa/portuguesa, pedido 7781, 1.140 polls, 18 mil celulares, 9.000 req/s, `polling-01`
- Pedido(id=150, "calabresa") 14 vs 30 bytes
- Strawberry 51 consultas; 100⁴ avaliações
- Kubernetes blog 2018 gRPC L4
