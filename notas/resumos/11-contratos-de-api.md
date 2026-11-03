# Resumo 11 — Contratos de API

## A Lastro ao fim do capítulo
- incidente terça 11h02–13h40: gerente adiciona `parcelas_detalhe` na cobrança; Bazar (consultoria Java, Jackson `FAIL_ON_UNKNOWN_PROPERTIES = true`) quebra em GET + webhooks (`500`); webhook sem retry → job Bazar cancela pedido sem pagamento em 30 min → 312 compradores com Pix pago e "pedido cancelado"; URGENTE 11h41; financeiro devolveu Pix; rollback
- compatibilidade (guia + contrato comercial): cliente ignora campo desconhecido; enums resposta abertos (`estado`, `metodo`, `tipo`); ausente = `null` = sem valor; aditivo sem versão (campo resposta, campo opcional req., enum, endpoint, validação frouxa) com 30 dias changelog
- versão no caminho `/v1`, sem menores → proxy por prefixo, sem `Vary`, logs; `/v2` convive ≥12 meses, `Deprecation` + `Sunset`; versões por data (Stripe) só com centenas de clientes
- erros RFC 9457 todo 4xx/5xx, `type` por regra (`saldo-insuficiente`, `split-invalido`, `estado-invalido`, `limite-diario-excedido`, `parametro-desconhecido`), extensão `erros` com JSON Pointer; recusa emissor segue `201` `recusada`
- listagens: cursor assinado, `limite` 50/máx 200, ordem `(criado_em, id)`, filtros `[de, ate)` RFC 3339 com fuso, parâmetro desconhecido `400`
- OpenAPI gerado FastAPI commitado, diff na CI bloqueia quebra; schemas resposta `additionalProperties: true`
- sandbox: campo-isca `_sandbox_campo_novo` em toda resposta/webhook
- webhooks: envelope `id` (`evt_` UUIDv7), `tipo`, `versao_api`, `criado_em`, `dados` (cobrança inteira, campo `versao`); dedupe por `id`, sem ordem, descarta `versao` menor, inscrição por tipo, `2xx` em 10 s, cabeçalho assinatura reservado (cap. 33); entrega ainda 1×, após COMMIT (cap. 17)
- `ETag` = `versao` + identificador do schema
- `parcelas_detalhe` volta em 30 dias; consultoria cobrou 40 h
- próximo: GraphQL painel, Pix tempo real no checkout, antifraude só gRPC (cap. 12)

## Conceitos aprofundados aqui
- contrato, Lei de Hyrum, variância req./resp., tabela de quebras, leitor tolerante, Postel/RFC 9413, enum aberto, null × ausente
- versionamento (caminho, cabeçalho, media type, query, data por conta), RFC 9745/8594
- RFC 9457; OpenAPI 3.1; consumer-driven (Pact)

## Casos reais usados
- Stripe versões por data (2017); Twitter `id_str` Snowflake 2010

## Piadas recorrentes
- gerente: "é só um campo" → "é sempre só um campo"
- Carlos: corrigiu typo "insuficinte" no `detail`, quebrou regex do Hornero 4 h ("derrubou produção acertando")
- Hornero poupado "graças a um bug" (ETag)
- consultoria Java do Bazar; "leve lanche e um padre"
