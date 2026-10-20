# Resumo 08 — Índices

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- heap sem ordem, páginas 8 KB, TID/ctid (página, posição)
- B-tree: (chave, TID), busca binária generalizada, fan-out ~350–400 (bigint), 300⁴ = 8,1 bi → altura 4; folhas duplamente ligadas; Lehman-Yao 1981; deduplicação PG 13
- função/conversão na coluna anula índice; índice de expressão exige IMMUTABLE, ANALYZE coleta estatística
- hash: só `=`, 4 bytes, sem UNIQUE, 1 coluna, WAL desde PG 10
- GIN: invertido, jsonb_path_ops (`@>`, jsonpath) vs jsonb_ops (`?`), pg_trgm, pending list 4 MB
- GiST: predicados englobantes, recheck, KNN `<->`; BRIN pages_per_range 128
- composto: prefixo à esquerda, igualdade antes de faixa; skip scan PG 18
- INCLUDE PG 11, index-only scan, visibility map, Heap Fetches
- parcial: predicado provado; UNIQUE parcial soft delete
- seletividade vs cardinalidade; random_page_cost 4,0 / seq 1,0; palpite igualdade sem estatística 0,5%
- custo escrita: INSERT todos índices, HOT só sem coluna indexada alterada + espaço na página; DELETE via VACUUM; pg_stat_user_indexes idx_scan

## Termos e traduções adotados
- heap, fan-out, skip scan, index-only scan, visibility map, pending list, recheck em inglês
- HOT update (heap-only tuple)

## Casos reais e exemplos usados (não repetir)
- hipotético: `entregas` 80 mi linhas, `upper(codigo_rastreio)` 3 ms → 11,2 s, estimativa 400 mil linhas; 14 índices; `idx_entregas_tmp_nao_apagar` 2,3 GB idx_scan 0
- parcial pendentes 7 MB vs 1,7 GB
- SQLAlchemy Index postgresql_include/postgresql_where
- LIKE prefixo + collation → text_pattern_ops
- Uber 2016 Postgres→MySQL, amplificação de escrita
