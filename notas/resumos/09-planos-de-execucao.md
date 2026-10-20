# Resumo 09 — Planos de execução

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- parser → rewriter → planner → executor; planner por custo (System R, Selinger 1979); programação dinâmica; GEQO a partir de 12 tabelas
- custos: seq_page 1,0, random_page 4,0, cpu_tuple 0,01, cpu_index_tuple 0,005, cpu_operator 0,0025; seq scan = páginas + linhas×0,01 + linhas×0,0025
- erro de cardinalidade > modelo de custo (Leis VLDB 2015)
- ANALYZE amostra 300 × default_statistics_target (30.000); pg_stats MCV, histograma, n_distinct, correlation; independência entre colunas → CREATE STATISTICS (PG 10)
- autoanalyze: 50 + 10% linhas modificadas
- Seq/Index/Index Only/Bitmap (lossy, Recheck Cond, BitmapAnd/Or)
- Nested Loop N×log M ou N×M; Hash Join work_mem × hash_mem_multiplier 2,0, Batches; Merge Join
- EXPLAIN vs ANALYZE (executa); BUFFERS padrão PG 18; tempos/linhas por loop
- N+1: lazy loading, selectinload, joinedload, lazy="raise", pg_stat_statements
- offset vs cursor (keyset), comparação de linhas, token base64 + HMAC
- plano genérico após 5 execuções, psycopg prepare_threshold 5, plan_cache_mode; JIT PG 12 jit_above_cost 100.000; auto_explain

## Termos e traduções adotados
- planner/otimizador, keyset pagination → paginação por cursor, lazy loading em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: Colégio Grande escola 9001, 48.000 alunos importados, rows=4, Nested Loop + Materialize, 2.879.948.130 comparações, 47,2 s → Hash Join 171 ms após ANALYZE
- boletos 11.586 páginas/900.000 linhas custo 22.836
- 50 cursos lazy load; OFFSET 200000 212 ms vs cursor 0,077 ms
- Campinas/SP independência
