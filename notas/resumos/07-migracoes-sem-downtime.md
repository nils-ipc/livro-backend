# Resumo 07 — Migrações de schema sem downtime

## A Lastro ao fim do capítulo
- incidente domingo dia 1º, 03h11–03h29: Carlos, Alembic 0042 (`ADD COLUMN moeda ... DEFAULT 'BRL'` + `valor` → `numeric(20,4)`), sessão sem `lock_timeout`; ALTER na fila atrás do fechamento mensal (RR READ ONLY, 03h00, 38 min) → INSERTs `55P03` 18 min; Bazar URGENTE 03h19; financeiro conciliou 47 Pix à mão
- `lancamentos`: ~45 mi linhas, heap ~3 GB, índices ~4,5 GB
- novo cliente: Mercadito Hornero (marketplace argentino, ARS)
- `moedas (codigo, casas_decimais)` ISO 4217: BRL 2, ARS 2; valores seguem `bigint` unidade mínima
- `contas.moeda` NOT NULL DEFAULT 'BRL' FK → moedas; UNIQUE `(id, moeda)` (CONCURRENTLY + USING INDEX)
- `lancamentos.moeda` NOT NULL DEFAULT 'BRL' (só catálogo, `attmissingval`; tabelião intacto) → FK composta `(conta_id, moeda)` → contas, NOT VALID + VALIDATE (~4 min)
- soma zero por `(transacao_id, moeda)`; câmbio futuro = 2 pernas, conta de câmbio por moeda
- deploy temp-01: reload troca 3 workers um a um, ~40 s v1+v2 juntas; rollback 7 dias
- contract 0044: DROP DEFAULT `lancamentos.moeda` + DROP FK simples conta_id
- regras migração: `lock_timeout 1s`, até 5 tentativas, `statement_timeout`, sem transação longa, fora do fechamento mensal, expand/contract em deploys separados
- descartados: janela (Pix 24x7), cópia + troca (estilo gh-ost)
- próximo: Hornero vê +300 ms por chamada; fundador troca temp-01, "só mudar IP no DNS" (cap. 08)

## Conceitos aprofundados aqui
- ACCESS EXCLUSIVE, fila de locks (pedido esperando bloqueia posteriores)
- custo DDL: catálogo/varredura/reescrita; tabela de operações PG16
- fast default (PG11), default volátil reescreve; SET NOT NULL via CHECK (PG12)
- NOT VALID + VALIDATE (SHARE UPDATE EXCLUSIVE); índice INVALID
- expand/contract (parallel change), matriz compatibilidade v1/v2
- backfill em lotes por PK, idempotente, escrita dupla antes
- autovacuum wraparound não cede

## Casos reais usados
- gh-ost × pt-online-schema-change; strong_migrations

## Piadas recorrentes
- gerente: "é só uma coluna" → era (mais 2 migrações...)
- Carlos: domingo 3h "ninguém usando"; próxima: "hora do almoço" (pico)
- `repasse_final_v2_agora_vai.py`: cópia própria do código; vai "falhar do jeito certo"
- Bazar: "URGENTE!!!!" com um ponto só por 1 s
- tabelião nem acorda; empresa sem registrar pagamento = ONG
