# Resumo 06 — Planos de execução

## A Lastro ao fim do capítulo
- incidente painel vendas do dia (gerente): 100 cobranças, lazy loading → 1 + 100 compradores + 100 split + 100 estornos + 99 vendedores (identity map) = 400 consultas/tela, ~1 ms ida e volta, 420 ms; 40 abas, refresh 15 s → >1.000 consultas/s
- correção: vendedor/comprador por junção, split/estornos `selectinload` → 3 consultas, ~6 ms; todas relações `lazy="raise"`; `json_agg` só se aninhamento profundo
- cabeçalho total por vendedor: 7,4 s às 18h (0,5 s às 9h); estimativa `rows=1` vs 11.802 → nested loop com seq scan em `contas` 11.802×; após ANALYZE → hash join 31 ms
- causa: `cobrancas` 9 mi linhas, autovacuum 50+10% = 900 mil alterações, ~12 mil cobranças/dia → ANALYZE a cada 75 dias; histograma `criado_em` parado 19 dias; índice `(marketplace_id, criado_em)` não começa por `criado_em`
- decisão: `cobrancas` e `lancamentos` com `autovacuum_analyze_scale_factor = 0`, `autovacuum_analyze_threshold = 5000`
- `contas.vendedor_id` indexado (CONCURRENTLY); contas tipo `disponivel` ~1.200
- extrato completo: cursor opaco `(criado_em, id)`, 50/página, `proximo_cursor`, sem `COUNT(*)`, sem número de página, 0,4 ms; antes OFFSET 199.950 = 3,4 s (+ COUNT 1,1 mi)
- índice ledger muda: `(conta_id, criado_em, id) INCLUDE (valor, transacao_id)` (~2,3 GB), CONCURRENTLY + DROP INDEX CONCURRENTLY
- próximo: gerente, marketplace argentino, "outra moeda é só uma coluna" em `lancamentos`; Carlos quer `ALTER TABLE` "rapidinho" (cap. 07)

## Conceitos aprofundados aqui
- EXPLAIN/ANALYZE/BUFFERS, cost constants, por loop
- nested loop, hash join (`work_mem × hash_mem_multiplier`, batches), merge join
- pg_stats: MCV, histograma, n_distinct, amostra 300×target; independência, CREATE STATISTICS
- N+1, joinedload/selectinload/raise; keyset vs OFFSET

## Casos reais usados
- Bullet (Rails); Winand "No Offset"; Campinas/SP (hipotético)

## Piadas recorrentes
- Carlos: `EXPLAIN ANALYZE DELETE` barrado pelo trigger "tabelião"; "só quer assistir" índice
- estagiária Capinhas: clica "carregar mais" há 20 min
- "custo é a fé do planner"; "produto cartesiano do amor"; banco "pune sucesso comercial"
