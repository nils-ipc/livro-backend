# Resumo 22 — Transações distribuídas

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- escrita dupla: 2 sistemas, atomicidades independentes; toda ordem tem falha; concorrência diverge sem falha (preço 10/12 no índice de busca)
- 2PC Gray 1978, X/Open XA 1991: coordenador, participantes, PREPARE → voto sim irrevogável → decisão no log do coordenador; 4 mensagens/participante, 2 RTTs + fsyncs
- estado incerto (in doubt): coordenador caído → locks presos; 3PC Skeen 1981 supõe rede síncrona; Paxos Commit Gray/Lamport 2006; Spanner 2PC sobre grupos Paxos
- PG: PREPARE TRANSACTION, max_prepared_transactions padrão 0, pg_prepared_xacts, COMMIT/ROLLBACK PREPARED; esquecida segura locks + VACUUM
- Kafka/SQS/Redis/APIs sem XA
- saga Garcia-Molina/Salem 1987: T1..Tn, Ci ordem inversa; compensação semântica (estorno, e-mail de desculpas); passos compensáveis/pivô/repetíveis
- saga sem isolamento; Frank/Zahle 1998: lock semântico, atualizações comutativas, reler antes de gravar
- orquestração vs coreografia; estado persistido por passo (Temporal, Step Functions); compensação idempotente, nunca falha de vez
- outbox: tabela na mesma transação, relay FOR UPDATE SKIP LOCKED + publicado_em, at-least-once, consumidor deduplica por evento_id
- CDC: decodificação lógica, test_decoding, Debezium pgoutput, outbox event router; schema interno vira contrato

## Termos e traduções adotados
- dual write → escrita dupla; in doubt → incerto; compensating action → ação compensatória
- two-phase commit, saga, outbox, relay, change data capture (CDC), pivô em inglês/português conforme acima

## Casos reais e exemplos usados (não repetir)
- hipotético: loja de piscina, 37 boias de flamingo despachadas para pedidos inexistentes; Dona Neide sem boia após OOMKilled
- pedido 4471; orquestrador Python cartão recusado (boias)
- armadilhas: id > ultimo_id pula transação lenta; SKIP LOCKED perde ordem; outbox 17,28 mi linhas/dia; slot parado enche disco
- Helland CIDR 2007
