# Resumo 21 — Event sourcing e CQRS

## A Lastro ao fim do capítulo
- incidente: chargeback cartão, notebook R$ 2.390,00, vendedor Sabiá Eletrônicos; comprador alega estorno prometido 14/09 15h; `cobrancas` só estado atual (`capturada`, `valor_estornado` 40000, `versao` 7); tópico/outbox 7 dias; backup diário 3h, restauração ~6 h; prazo contrato adquirente 7 dias corridos; respondido no 6º dia com planilha do financeiro (linha 4.812)
- história real: v4 estorno.solicitado 14/09 14h52 → v5 estorno.falhou 14h53 saldo-insuficiente → v7 concluído 16/09 10h04
- decisão: event sourcing só ciclo de vida da cobrança → requisito estado em T + causa + autor como evidência
- `eventos_cobranca` no primário do ledger: PK `(cobranca_id, versao)` = versão esperada; `tipo`, `versao_schema`, `dados` jsonb, `autor`, `registrado_em`, `ocorrido_em`; mesmo COMMIT de lançamentos + outbox (evita escrita dupla)
- `cobrancas` = projeção inline; `versao` = versão do stream (ETag, webhooks); leitura linearizável
- eventos de domínio internos; webhook público segue contrato cap. 11
- extrato vendedor → projeção assíncrona `extrato_linhas` no `pg-notificacoes` ("banco de leitura"), via `conta.movimentada` com descrição; RYW cap. 19; reconstrução ~60 mi lançamentos, 5 mil/s, ~3h20, tabela paralela
- conciliação/fechamento seguem ledger primário
- continuam tabela + histórico por trigger: vendedores, inscrições webhook, tarifas, split
- volume: ~5 eventos/cobrança, ~125 mil/dia, ~45 GB/ano (→ cap. 24); maior stream 31; sem snapshots (< 1 ms); consulta stream 4 ms
- migração: evento sintético `cobranca.importada`, `autor = migracao`
- descartados: backup, histórico por trigger (sem intenção), SQL:2011 (PG não tem), Kafka/banco dedicado
- próximo: criação cobrança lê tarifas + split 11×/requisição; Carlos quer Redis p/ tudo, inclusive saldo do saque (cap. 22)

## Conceitos aprofundados aqui
- event sourcing, fold, reducer React; agregado, stream, comando × evento
- bitemporal (registro × ocorrência)
- event store: 4 operações; posição global BIGSERIAL × COMMIT
- projeção descartável/idempotente/inline/assíncrona; snapshot = cache
- versionamento: tolerante, upcasting, tipo novo, copiar/transformar; crypto-shredding (LGPD)
- CQS (Meyer 1988), CQRS (Young); ledger = ES sem saber

## Casos reais usados
- LMAX (Fowler 2011, ~6 mi pedidos/s); Helland "contadores não usam borracha"

## Piadas recorrentes
- Carlos: pizza + backup, comeu sozinho às 2h; contou 40, CI 43
- financeiro girou monitor; apagou 1 aba
- `cobranca.atualizada` = UPDATE fantasiado; snapshot = segurança p/ pote de sal; cartório que incinera escrituras
