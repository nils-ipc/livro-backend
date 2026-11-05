# Resumo 18 — Transações distribuídas

## A Lastro ao fim do capítulo
- incidente terça 16h00min03s: reload entre COMMIT e publish → Pix R$ 870,00 sem evento; checkout mostrou confete (NOTIFY no COMMIT); Bazar cancelou pedido em 30 min; Carlos inverteu em homologação → ROLLBACK após publish, 14 fones grátis (R$ 4.898,60 imaginários); vendedor 42: R$ 300,00 debitados sem Pix
- volume: ~25 mil cobranças/dia
- outbox `eventos_saida` (id `evt_`, chave, tipo, payload) no mesmo COMMIT → CDC (decodificação lógica, publication só outbox) → `cobrancas.eventos` + novo `repasses.eventos`; API não fala com broker
- CDC > polling → primário do ledger sem escrita extra (500/s BF), ordem do COMMIT; `wal_level=logical` = restart 14 s madrugada quarta; alerta slot > 5 GB; `max_slot_wal_keep_size` 50 GB; outbox 7 dias, apagada em lotes; slot perdido → republica outbox, dedupe `id`
- saga repasse orquestrada: T1 disponível → `repasses_em_transito` (lock semântico) `enviando`; T2 Pix c/ ID; aceito = pivô → T3 → liquidante `enviado`; recusado → C1 volta disponível `falhou`; sem resposta → consulta backoff
- saga cartão: autorização compensável (desfazimento); pivô captura; depois repetível; estorno = saga própria
- orquestrador = processo de resolução cap. 15, `SKIP LOCKED` + `proxima_acao_em`; coreografia p/ webhooks, Vigia, conciliação
- conciliação 06h: arquivo adquirente + extrato liquidante; classes casou/só parceiro (estorno automático)/só Lastro/valor/repasse `enviando` > 24 h/evento sem entrega 3 dias; fila manual web; financeiro exporta p/ planilha
- `repasse_final_v2_agora_vai.py` fora da saga, temp-01 (cap. 20)
- próximo: vendedor 42 vê R$ 870,00 disponível no painel, saque `saldo-insuficiente` (cap. 19)

## Conceitos aprofundados aqui
- escrita dupla, tabela das 4 ordens
- 2PC, em dúvida, bloqueante, 3PC; `PREPARE TRANSACTION`, `max_prepared_transactions` 0, XA
- saga (1987): compensável, pivô, repetível; lock semântico, comutativas; orquestração × coreografia
- outbox, relay, polling (furo de IDs), CDC, slot, PG17 failover slots; CDC de tabelas internas = Hyrum
- conciliação como verificação independente

## Casos reais usados
- Spanner 2PC sobre Paxos; Helland 2007

## Piadas recorrentes
- vendedor 42 vítima, "tem razão", decepcionado com o reembolso
- Carlos: fones de homologação; slot esquecido, disco 200 GB em 11 dias
- PostgreSQL "em dúvida" com act-out; preparada esquecida = morto-vivo
- financeiro e planilha "estavam certos desde o cap. 1"
