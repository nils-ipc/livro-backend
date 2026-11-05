# Resumo 17 — Mensageria

## A Lastro ao fim do capítulo
- incidente quinta 14h02: webhook Hornero 25 s, enviado dentro da requisição; `httpx` 5 conexões/processo (Carlos), timeout 30 s; 2/s × 25 s = 50 > 45; POST cartão p99 31 s; banco desistiu 212 notificações Pix; `create_task` do Carlos → tasks morrem no pool, 140 no reload (ref. fraca)
- broker: log gerenciado compatível Kafka → replay + consumidores independentes (conciliação, Vigia)
- `cobrancas.eventos`: 12 partições, RF 3, `min.insync.replicas=2`, 7 dias, chave `cobranca_id`, `acks=all`, idempotente; registro = envelope cap. 11
- `webhooks-agendador`: grava `entregas_webhook` em `pg-notificacoes` (PostgreSQL separado: conexões + VACUUM); UNIQUE `(evento_id, inscricao_id)`; nunca HTTP
- `webhooks-entregador` (api-01/02): SKIP LOCKED, lease 30 s; timeout 10 s; ordem `versao` por (inscrição, cobrança); bulkhead 10/endpoint/processo; breaker cap. 15; 9 tentativas ~69 h → `morta` (DLQ painel, reenvio, alarme)
- `cobrancas.eventos.dlq`: evento não desserializável
- volume BF: 500 eventos/s, 1.000 no 2×
- publicação após COMMIT → próximo: reload entre COMMIT e publish, Pix R$ 870,00 sem evento, pedido Bazar cancelado (cap. 18)

## Conceitos aprofundados aqui
- broker: tempo, taxa, falha
- fila: ack, competing consumers, prefetch, visibility timeout = lease, FIFO por grupo
- log: offset, retenção, commit, partição `murmur2 mod N`, consumer group, replay, rebalance
- acks/min.insync; poison message; DLQ; lag por partição, idade, `backlog/(vazão − chegada)`

## Casos reais usados
- Kinesis us-east-1 25/11/2020; Stripe webhooks 3 dias; asyncio weak ref

## Piadas recorrentes
- Carlos: webhook coletável pelo GC; Kafka operado por ele = "incidente com cronograma"
- Hornero vira lápide no domingo; analista sem tempo p/ crochê
- DLQ = cemitério com mensalidade; broker compra tempo a juros
