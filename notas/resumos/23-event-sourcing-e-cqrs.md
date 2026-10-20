# Resumo 23 — Event sourcing e CQRS

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- event sourcing: fonte da verdade = eventos imutáveis, nome no passado; correção por estorno (livro razão)
- estado = redução (functools.reduce, reducer React/Redux); `aplicar` determinística, nunca recusa evento
- comando (imperativo, pode recusar) → carregar, validar, emitir, anexar
- stream, agregado (DDD) = fronteira de consistência; versão esperada = controle otimista; PG `UNIQUE (stream_id, versao)`
- event store: anexo condicional, leitura por stream, leitura global, assinatura; Kafka sem anexo condicional por chave
- posição global por sequência confirmada fora de ordem → `xid8` + `pg_snapshot_xmin(pg_current_snapshot())` ou lock
- projeção + checkpoint mesma transação; descartável, reconstruível; reactors para efeitos externos
- snapshot = cache versionado; fechamento de período (`PeriodoEncerrado`)
- versionamento: weak schema, upcasting, tipo novo, copiar e transformar
- CQRS Greg Young ~2010, CQS Meyer 1988; independe de ES
- atraso de projeção: estado na resposta, posição + espera, ler stream
- crypto-shredding (LGPD/GDPR); reconstrução lado a lado `saldos_v2`

## Termos e traduções adotados
- event sourcing, event store, stream, snapshot, read model → modelo de leitura, checkpoint, upcasting, weak schema → leitor tolerante, reactors, crypto-shredding
- aggregate → agregado; expected version → versão esperada

## Casos reais e exemplos usados (não repetir)
- hipotético: Seu Arlindo, Café Coado, 4.380 → 12 pontos, `job_expiracao_v2_NAO_RODAR.py`, 7 UPDATEs, conta-4417, 2 caixas −8
- evento 2019 `{"qtd": "10"}`; 1.312 recibos no replay
- 2 mi contas, 24 GB/mês; 300 mi eventos 20 mil/s ≈ 4 h
- Kafka retention.ms 7 dias, compact
- LMAX (Fowler 2011, 6 mi pedidos/s); Overeem/Spoor/Jansen SANER 2017
