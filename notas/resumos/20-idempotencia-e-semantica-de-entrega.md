# Resumo 20 — Idempotência e semântica de entrega

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- 3º resultado "não sei"; dois generais (Akkoyunlu/Ekanadham/Huber 1975, nome Gray 1978)
- at-most-once (ack antes) vs at-least-once (ack depois); SQS padrão pode duplicar
- exactly-once = efeito único: at-least-once + idempotente/deduplicado
- Kafka 0.11 KIP-98: producer ID + sequência por partição; transações + offset; read_committed; 3.0 KIP-679 enable.idempotence padrão + acks=all; só Kafka → Kafka
- SQS FIFO MessageDeduplicationId janela 5 min
- idempotência f(f(x))=f(x); RFC 9110 9.2.2 efeito no estado, resposta pode mudar (DELETE 204→404); promessa não verificada
- estado absoluto vs delta; ON CONFLICT DO NOTHING; transição condicionada → UPDATE 0
- reordenação ≠ repetição → versão / If-Match
- Idempotency-Key (Stripe, rascunho IETF httpapi): 422 corpo diferente, 409 em andamento, 400 ausente; Stripe guarda 500, ≥24 h
- PG: INSERT ON CONFLICT espera no índice único → serializa concorrentes sem lock
- efeito externo: em_andamento/concluida + chave derivada propagada (Brandur 2017)
- consumidor: marcação + efeito mesma transação (inbox); Redis + PG quebra
- custo: 200 POST/s → 17,28 mi chaves/dia, ~17 GB/24 h

## Termos e traduções adotados
- at-most-once, at-least-once, exactly-once, inbox, outbox, ack em inglês
- idempotency key → chave de idempotência; fingerprint → impressão digital

## Casos reais e exemplos usados (não repetir)
- hipotético: Dona Lurdes, gato Almirante, 4 sacos 15 kg, elevador, OOMKilled, proxy
- FastAPI + psycopg chaves_idempotencia (cliente_id, chave), pedido 48213, Idempotent-Replayed
- worker ev-90311 worker-2/worker-5
- NGINX proxy_next_upstream non_idempotent 1.9.13
