# Resumo 15 — Modelos não relacionais

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- sem planner → caminho de acesso gravado no layout físico; padrões de acesso antes do modelo
- chave-valor: get/put, valor opaco; Redis tipos + comandos atômicos (INCR, sorted set O(log N + M)); replicação assíncrona, WAIT não dá consistência forte; AOF everysec ~1 s perdido
- documento: atomicidade por documento; embutir limitado/lido junto, referenciar o que cresce; MongoDB 16 MB, $lookup, transações 4.0/4.2 (60 s); write concern majority padrão 5.0; w:1 → rollback no failover; read concern local/majority/linearizable/snapshot; $jsonSchema
- wide-column: chave de partição + clustering, partição = lista ordenada; ALLOW FILTERING; uma tabela por consulta; LSM-tree; tombstone, gc_grace_seconds 10 dias, 1.000 aviso / 100.000 aborta; LWT Paxos
- colunar analítico: layout por coluna, OLAP vs OLTP, mutação ClickHouse assíncrona
- grafo: propriedades, index-free adjacency, Cypher, GQL ISO/IEC 39075:2024, particionamento NP-difícil
- séries temporais: Gorilla delta-of-delta + XOR, 1,37 byte/ponto; time_bucket TimescaleDB; Prometheus sem replicação; cardinalidade de rótulos
- tabela de padrões de acesso com frequência; single-table design

## Termos e traduções adotados
- wide-column, single-table design, tombstone, write/read concern, index-free adjacency, scan em inglês
- padrão de acesso; colunar analítico

## Casos reais e exemplos usados (não repetir)
- hipotético: reservas de padel, Otávio "só uma perguntinha", scan 38 GB 41 min 14 reservas, u-4417 Ana; quadra-12; u-9001 ranking
- MongoDB resgate jan/2017, bindIp localhost 3.6
- Jepsen MongoDB 4.2.6 (2020)
