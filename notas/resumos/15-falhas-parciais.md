# Resumo 15 — Falhas parciais

## A Lastro ao fim do capítulo
- incidente BF sexta 21h40: adquirente p99 1,18 → 4 s; Carlos timeout leitura 1,3 s "proteger contrato" → 3.000 `recusada` em 10 min, 412 aprovadas; financeiro desfez à mão, planilha `bf_desfazer_FINAL.xlsx`
- cartão: estado novo `processando` (enum aberto, 30 dias changelog) → timeout leitura = `201` + `processando`, final por webhook
- adquirente (contrato de integração): referência única = ID cobrança; consulta e desfazimento por referência, idempotentes; desfazimento aceito p/ referência desconhecida e bloqueia autorização posterior
- resolução: consulta backoff + full jitter 1, 2, 4… até 60 s; aprovada → `autorizada`; negada → `recusada`; inexistente após 5 min → desfazimento (repete até confirmar) → `recusada`
- deadline autorização 8 s desde proxy (Bazar desiste 10 s); Vigia `min(120 ms, restante)`; adquirente restante − 300 ms (~7,5 s); adquirente p99,9 saudável ~2,7 s
- prefere violar p99 (multa 7.2) a mentir sobre dinheiro (runbook)
- conexão adquirente 500 ms + 1 retry; leitura nunca repetida
- bulkheads por processo: adquirente 100, Vigia 50, banco Pix 30; cheio → `503` + `Retry-After: 2` + `adquirente-indisponivel`; 900 slots / 7,5 s = 120/s
- circuit breaker por parceiro e por processo: >50% falhas, janela 10 s, mín 20 chamadas, aberto 5 s, 3 sondas; recusa do emissor ≠ falha
- Vigia degradado: ≤ R$ 300,00 segue c/ regras locais (limite cartão 24 h); acima recusa `antifraude_indisponivel`
- retries só resolução + conexão, orçamento 10%/parceiro
- próximo: consultoria Java Bazar: timeout 10 s + 3 retries + full jitter no `POST /v1/cobrancas`; Lastro 7,8 s + 2,6 s fila pool do próprio Bazar = 10,4 s → cobrança duplicada, comprador paga 2× (cap. 16)

## Conceitos aprofundados aqui
- falha parcial, resultado desconhecido, 4 explicações do silêncio
- crash/fail-stop, omissão, tempo, bizantina; falha cinzenta
- timeout conexão (certeza de não envio) × leitura; escolha: acima cauda saudável, abaixo paciência chamador; Little
- retry seguro; backoff exponencial, full jitter; amplificação `(1+r)^camadas`; retry budget; gRPC retry throttling
- circuit breaker 3 estados; bulkhead; deadline como tempo restante; cancelamento; fail-open/fail-closed

## Casos reais usados
- DynamoDB us-east-1 20/9/2015 (metadados, GSI, retries); gray failure (Huang, HotOS 2017); Brooker 2015

## Piadas recorrentes
- Carlos: timeout 1,3 s; `@retry(5)` sobre 3 = 15, banco perguntou se Lastro estava bem; `except` das 2h
- planilha conciliação ganhou "irmã mais nova"
- Bazar: "confiança" 11 vezes; "pagou duas vezes, com jitter"
- psicografia = resposta p/ socket fechado
