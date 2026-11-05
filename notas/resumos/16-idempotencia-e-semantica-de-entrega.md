# Resumo 16 — Idempotência e semântica de entrega

## A Lastro ao fim do capítulo
- incidente terça 10h14: Bazar pedido 88213, fone R$ 349,90; POST 10,4 s do lado Bazar (2,6 s pool próprio + 7,8 s Lastro `processando`); retry → 2ª cobrança `autorizada`; resolução aprovou 1ª → 37 compradores cobrados 2×; URGENTE com 16 exclamações; financeiro estornou 37; consultoria +40 h
- `Idempotency-Key`: opcional `/v1` (obrigatório quebraria clientes, cap. 11), obrigatório `/v2`; escopo `(marketplace_id, chave)`; retenção 24 h; job apaga expiradas em lotes
- tabela chaves (conceitual): marketplace_id, chave, hash_requisicao, fase, cobranca_id, status_http, corpo_resposta, expira_em
- fluxo: tx1 chave `criada` + cobrança COMMIT → retry `409` `requisicao-em-andamento` + `Retry-After: 2`; Vigia/adquirente; tx2 chave `concluida` + resposta → replay mesma resposta/ID (inclusive `processando`); morte entre tx1/tx2 → resolução cap. 15 conclui
- corpo diferente → `422` `chave-idempotencia-reutilizada`
- captura: transição condicional `autorizada → capturada`
- adquirente: referência duplicada recusada sem nova reserva (contrato) → retries conexão/GOAWAY seguros; leitura segue sem retry
- `transacoes` + `origem`, `referencia` UNIQUE (CONCURRENTLY): pix_recebido/E2E, captura, estorno, repasse
- Pix recebido: E2E UNIQUE (cap. 01); duplicata → `200`
- repasse Pix: ID repasse enviado ao banco, banco recusa repetido → retry seguro; escrita em 2 sistemas → cap. 18
- descartado: dedupe por conteúdo (só alerta)
- próximo: webhooks ainda dentro da requisição, 1×, sem retry (at-most-once); Hornero webhook responde em 25 s → API cai (cap. 17)

## Conceitos aprofundados aqui
- at-most-once, at-least-once, exactly-once (entrega impossível; efeito = at-least-once + dedupe)
- dois generais (Akkoyunlu 1975, Gray 1978)
- idempotência `f(f(x)) = f(x)`, efeito ≠ resposta, intercalação (If-Match)
- RFC 9110 9.2.2; naturalmente idempotentes; `ON CONFLICT DO NOTHING` → `INSERT 0 0`
- chave idempotência: 4 casos, 409/422, escopo, retenção, atomicidade, fases atômicas (Brandur)
- dedupe consumidor: natural, chave UNIQUE, inbox; janela; duplicata = sucesso

## Casos reais usados
- Kafka EOS KIP-98 (0.11, 2017); Stripe 24 h; SQS FIFO 5 min; draft IETF Idempotency-Key

## Piadas recorrentes
- consultoria Java: UUID dentro do laço ("cada duplicada única"), +40 h por vez
- Carlos: chaves no Redis "mais rápido"
- exactly-once = unicórnio que não sai do curral
- tabelião registra "RG" de cada partida dobrada
- "cai igual, quantas vezes for" (idempotência da queda)
