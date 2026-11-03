# Resumo 05 — Índices

## A Lastro ao fim do capítulo
- incidente: extrato outubro vendedor 7310 (Capinhas Hiper Ltda., maior do Bazar, 1,1 mi lançamentos) = 6 s; `lancamentos` 40 mi linhas, ~330 mil blocos; coluna `criado_em timestamptz default now()`
- Carlos, quinta 15h40: `CREATE INDEX (criado_em)` sem CONCURRENTLY → lock SHARE 48 s → pagamentos `55P03` (lock_timeout 2 s) → Pix recusado; extrato 5,8 s; índice 500 MB, `idx_scan = 0`, apagado
- decisão: `(conta_id, criado_em) INCLUDE (valor, transacao_id)` (~2 GB) → extrato <100 ms + saldo anterior; index-only, `Heap Fetches: 0`, 0,23 ms; serve `SUM` do trigger débito; substitui índice `conta_id`
- índices `lancamentos`: PK, `transacao_id`, composto (3 B-trees) + BRIN `criado_em` p/ conciliação (até partições cap. 24)
- INSERT lançamento 0,11 → 0,13 ms, +15% WAL
- pico: ~50 inserções/s, ~20 extratos/s, ~5 buscas/s por transacao_id
- `cobrancas`: parcial `(expira_em) WHERE estado = 'pendente'` (0,3% pendentes); expressão `(marketplace_id, (metadata->>'pedido_id'))`; `metadata jsonb` existe; GIN `jsonb_path_ops` só se busca arbitrária
- CNPJ, chave Pix, EndToEndId → `COLLATE "C"`
- ~9 mil contas
- próximo: painel vendas do dia 400 consultas/tela (N+1); estagiária da Capinhas na página 4.000 (OFFSET 199.950) → cap. 06

## Conceitos aprofundados aqui
- B-tree nbtree/Lehman-Yao, fan-out ~400, 3 níveis p/ 40 mi, page split, deduplicação (13)
- TID, visibilidade no heap, index-only, visibility map, INCLUDE sem dedup
- composto: igualdade antes de faixa; prefixo; skip scan (18)
- seletividade, cardinalidade, `random_page_cost` 4, bitmap scan, correlação
- parcial, expressão `IMMUTABLE`; hash, GIN, GiST, BRIN
- custo escrita, HOT, full-page write

## Casos reais usados
- glibc 2.28 collation; Uber 2016 Postgres→MySQL (amplificação de escrita)

## Piadas recorrentes
- Carlos: "rapidinho"; índice enterrado "deixa viúva (fatura do disco)"; cap. 07 "outra chance de virar exemplo"
- gerente: "é só um índice" → era, só não o do Carlos
- Bazar "URGENTE!!!!" tem template no helpdesk
- ledger "ficha limpa" (VACUUM)
- Capinhas + estagiária
