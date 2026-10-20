# Resumo 21 — Mensageria

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- broker; fila (estado por mensagem, apaga após ack) vs log (partição só acréscimo, offset, retenção; Kafka retention.ms 7 dias); log = WAL exposto (Kreps 2013)
- RabbitMQ AMQP 0-9-1: exchange, binding, delivery tag, basic.ack/nack/reject, redelivered, consumer_timeout 30 min, prefetch basic.qos (0 = ilimitado), auto-ack = at-most-once; streams 3.9; single active consumer 3.8
- SQS: visibility timeout 30 s padrão / 12 h máx., receipt handle, ChangeMessageVisibility heartbeat/nack, long polling 20 s, retenção 4/14 dias
- Kafka: commit por partição em __consumer_offsets, offset = próxima; enable.auto.commit 5 s; max.poll.interval.ms 5 min; murmur2 % partições; idempotente padrão 3.0
- consumidores concorrentes vs consumer group (paralelismo = partições); rebalance eager / KIP-429 / KIP-848 (4.0); share groups KIP-932
- SQS FIFO MessageGroupId, 300 TPS / 3.000 com lote; head-of-line blocking
- DLQ: redrive policy maxReceiveCount; dead letter exchange, x-delivery-limit 20 (4.0); Kafka tópico .dlq, Connect errors.deadletterqueue.topic.name
- backlog: consumer lag, ApproximateAgeOfOldestMessage; T = backlog/(consumo − produção); auto.offset.reset latest pula
- claim check; message.max.bytes ~1 MB

## Termos e traduções adotados
- poison message → mensagem venenosa; competing consumers → consumidores concorrentes
- ack, offset, commit, rebalance, prefetch, heartbeat, backlog, consumer lag, fan-out em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: Seu Valdemar, papagaio Comandante, 3 canecas, foto 48 MP, render 41 s vs 30 s; TIFF 48 MB OOM; DLQ 41 mil de 2022
- boto3 heartbeat 3f9a1c2e; confluent-kafka ped-1001 p4 812–814, ped-2002 p1
- Black Friday 1,8 mi, 300/s, 25/worker: 12 nunca, 20 → 150 min, 40 → 43 min
- SQS DLQ expira pelo enqueue original
- Kinesis us-east-1 25/11/2020, limite de threads
