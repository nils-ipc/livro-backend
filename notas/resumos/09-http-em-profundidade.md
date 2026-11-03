# Resumo 09 — HTTP em profundidade

## A Lastro ao fim do capítulo
- incidente quarta 10h12: link `GET .../estornar?valor=129900` colado pelo Carlos no chat → robô de preview estornou R$ 1.299,00, antivírus do e-mail outros R$ 1.299,00 (kit 200 capinhas, R$ 2.598,00, Capinhas Hiper); devolvido em 2 lançamentos novos
- painel: estorno só `POST` com confirmação; endpoint antigo `405` + `Allow: POST`
- API pública: `POST /v1/cobrancas` → `201` + `Location` (Pix `pendente`; cartão `autorizada`/`recusada`, adquirente síncrono ~800 ms; recusa = estado, não 4xx); `GET /v1/cobrancas/{id}` `ETag` (coluna nova `cobrancas.versao`) + `private, no-cache`; `POST .../captura` `200`; `POST .../estornos` → `202` + `Location: /v1/estornos/{id}` (`processando`/`concluido`/`falhou`) + webhook; `GET /v1/moedas` `public, max-age=86400`; saldo `no-store`
- erros: `422` conteúdo impossível, `409` conflito de estado; formato → cap. 11
- Hornero polling Pix 2 s, 95% `304`
- cartão começa: adquirente limita 20 conexões simultâneas; pico 12/s × 0,8 s ≈ 10 simultâneas; 6 processos (3 temp-01 + 3 api-01) → HTTP/2 via ALPN, 1 conexão/processo, 600 streams, teto 750/s (HTTP/1.1 = 25/s); GOAWAY: reenvia só streams acima do último ID
- marketplaces seguem HTTP/1.1 (Uvicorn); HTTP/2 borda → proxy caps. 10/27
- checkout no navegador: CORS só `/v1/checkout/`, token curto por cobrança no `Authorization` (cap. 30), origens cadastradas ecoadas + `Vary: Origin`, sem cookies, `Max-Age` 7200
- próximo: certificado TLS de `api.lastro.com.br` emitido à mão pelo fundador, vence madrugada de domingo (cap. 10)

## Conceitos aprofundados aqui
- HTTP/1.1 framing, smuggling, pipelining/HOL; HTTP/2 frames, streams, HPACK, GOAWAY, HOL do TCP; HTTP/3/QUIC, connection ID, Alt-Svc
- seguro × idempotente (RFC 9110); status; Cache-Control, ETag, If-Match/412, Vary; CORS, preflight

## Casos reais usados
- Google Web Accelerator 2005; CVE-2023-44487 Rapid Reset (398 mi rps); CRIME 2012; nginx 1.9.13 `non_idempotent`

## Piadas recorrentes
- Carlos: "a validação funcionando"; Chromium barrou PR dele (`*` + credentials)
- `402` "uso futuro" desde 1997, mais velho que temp-01
- "no-cache = cache com fiscalização"; HTTP/2 "coletivismo de rede"
