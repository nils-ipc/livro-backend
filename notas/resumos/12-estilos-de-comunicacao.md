# Resumo 12 — Estilos de comunicação

## A Lastro ao fim do capítulo
- pedidos: Hornero painel = 201 chamadas/tela (1 lista + 100 vendedor + 100 estornos) × 100 ms → >20 s; checkout polling 2 s, pico 600 checkouts = 300 req/s, 99,6% `pendente`; Carlos quis 100 ms (6.000/s); antifraude Vigia só gRPC
- comandos seguem REST; webhooks iguais
- painel: `POST /v1/graphql` só `query` (escritas REST) → combinações variáveis por marketplace; ~140 ms Hornero; profundidade 5, `primeiros` obrigatório máx 100, custo estático ≤ 5.000 pontos, `statement_timeout` 3 s, DataLoader por requisição, CI conta SQL, cursor assinado cap. 11, `extensions.type` = URIs RFC 9457, `@deprecated`, checagem de marketplace por resolver (cap. 31); descartado `expandir=` (serve poucos clientes/telas fixas)
- checkout: SSE `GET /v1/checkout/cobrancas/{id}/eventos`, lido via `fetch` (EventSource sem cabeçalho; token segue no `Authorization`), reconexão própria `retry` + `Last-Event-ID`; `id` evento = `cobrancas.versao`; `: ping` 15 s; proxy sem buffer, 60 s; fecha na mudança de estado/expiração QR; WebSocket descartado (unidirecional)
- fan-out: `NOTIFY cobrancas '<id>:<versao>'` na transação do pagamento Pix → sai só no COMMIT; 1 conexão `LISTEN` fora do pool por processo (6); stream não segura conexão do pool; LISTEN antes de ler estado
- Vigia: gRPC unário `Avaliar` antes do adquirente, `grpc-timeout` 120 ms (p99 prometido 60 ms), 1 canal HTTP/2 TLS por processo, `.proto` versionado, campos com `optional`; estouro → cap. 15
- próximo: Carlos usou stub gRPC síncrono em `async def`; cliente adquirente sempre síncrono → processo trava ~1 s por autorização, SSE congela (cap. 13)

## Conceitos aprofundados aqui
- REST (Fielding 2000), over/under-fetching
- protobuf: tag `(n << 3) | tipo`, varint, desconhecidos preservados (3.5), `reserved`, proto3 ausente = zero, `optional` (3.15)
- gRPC: HTTP/2, prefixo 5 bytes, trailers `grpc-status` (17), `grpc-timeout`, 4 tipos, gRPC-Web
- GraphQL: resolvers, N+1, DataLoader, custo/profundidade, aliases, persisted queries, `200` + `errors`
- WebSocket RFC 6455 (`101`, Accept, máscara); SSE (`retry`, `Last-Event-ID`, heartbeat, buffer proxy)

## Casos reais usados
- Kubernetes blog 2018 gRPC LB; GitHub GraphQL limites (1–100, 500.000 nós); GraphQL Facebook 2012/2015

## Piadas recorrentes
- analista Hornero: crochê enquanto painel carrega; casaco pela metade
- Carlos: polling 100 ms "tempo real"; token na URL "só desta vez"
- Lastro "ex mais requisitada do país"; "200, morreu"; `reserved` = lápide
