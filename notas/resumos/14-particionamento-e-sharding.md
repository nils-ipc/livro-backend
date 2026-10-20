# Resumo 14 — Particionamento e sharding

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- particionamento = mesmo servidor; sharding = servidores diferentes; chave de partição
- PG declarativo 10: RANGE `[início, fim)`, LIST, HASH (11, MODULUS/REMAINDER), DEFAULT; erro "no partition of relation ... found for row"
- partition pruning planejamento + execução (11), `Subplans Removed`; planner OK até alguns milhares de partições
- sem índice global: PK/UNIQUE inclui chave de partição (erro "must include all partitioning columns")
- expurgo: DETACH CONCURRENTLY (14, fora de transação, sem DEFAULT) + DROP TABLE
- faixa: split, ordem, chave monotônica → último shard quente
- hash % N move N/(N+1) (4→5 = 80%); hash() Python instável (PYTHONHASHSEED)
- consistent hashing Karger 1997, anel, ~1/(N+1); vnodes; Cassandra num_tokens 16 (4.0); rendezvous, jump hash
- shards lógicos fixos + mapa; Redis 16.384 slots CRC16, MOVED, CROSSSLOT, hash tags; diretório
- hot spot: chave granular, sal, isolamento
- scatter-gather, 1−0,99^32 ≈ 27,5%; índice local vs global (DynamoDB GSI eventual); co-localização, reference tables Citus
- rebalanceamento: snapshot → CDC → bloqueio breve → troca roteamento; rebalanceamento automático em cascata
- critérios chave: presença em consultas, cardinalidade, distribuição, monotonicidade, imutabilidade, tamanho por valor

## Termos e traduções adotados
- partition pruning, scatter-gather, hot spot, split, vnodes, hash slots, hash tags em inglês
- chave de partição; shard lógico; rebalanceamento

## Casos reais e exemplos usados (não repetir)
- hipotético: freezers, `leituras` 6,5 bi, DELETE 30 h, Sorveteria Pinguim Feliz 9 mil freezers (18%)
- anel brinquedo 100 posições, shard-e 48 → 13%
- roteador 480 shards, ws 98765 → 365
- Instagram 2012; Notion 480/32 → 96; Discord bucket 10 dias 100 MB; Foursquare 4/10/2010 66 vs 50 GB
