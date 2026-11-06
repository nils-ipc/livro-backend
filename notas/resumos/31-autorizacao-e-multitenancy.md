# Resumo 31 — Autorização e multitenancy

## A Lastro ao fim do capítulo
- incidente segunda 10h40: analista Hornero troca `/painel/cobrancas/18734512` → ...513 (ID interno `BIGINT` sequencial, rota "suporte interno" do Carlos) → cobranças Bazar com nome/CPF/e-mail + botão Estornar ativo (não clicou); chamado 10h52; Bazar URGENTE 11h30 "CONCORRENTE ESTÁ VENDO"; GraphQL `vendedor { cobrancas }` sem checagem → Capinhas (mesmo CNPJ Bazar + Hornero) vazou vendas Bazar
- tenant = marketplace (42: 41 + Tuiuiú); `marketplace_id` em toda tabela de cliente + RLS em `pg-pagamentos` e todos shards `pg-ledger` → requisito nenhum vazamento com consulta esquecida; banco/schema por tenant descartados (42× migração; Tuiuiú já shard próprio)
- lançamentos herdam `marketplace_id` da transação, inclusive liquidante/receita
- política RLS `nullif(current_setting('app.marketplace_id', true), '')::bigint`, `FORCE`; `SET LOCAL` em toda transação (PgBouncer transaction)
- papéis banco: `dono_schema` (migrações), `app_pagamentos`/`app_ledger` sem BYPASSRLS, `conciliacao` `USING (true)` só SELECT, `quebra_vidro` BYPASSRLS 1 h, 2 aprovações, auditado
- fundador perdeu superusuário (pendência cap. 01)
- gateway emite token de contexto JWT ES256 60 s (marketplace, sujeito, papéis, último fator), propagado entre serviços (anti confused deputy); painel: tenant pelo emissor OIDC, nunca claim
- papéis marketplace (grupos do IdP): leitura, suporte (estorno ≤ R$ 500,00), financeiro (sem limite, fator ≤ 5 min), admin (usuários, chaves, inscrições webhook); vendedores via `afiliacoes (vendedor_id, marketplace_id)`, só recebíveis; Zanzibar descartado
- biblioteca de política; rota sem ação declarada `403` + CI; repositórios só `buscar(marketplace_id, id)`; DataLoader chave `(marketplace_id, vendedor_id)`; alheio = `404` `nao-encontrado`; painel usa UUIDv7 pública
- alerta > 20 negações/sujeito/5 min; índice extrato + `marketplace_id` INCLUDE (0,6 ms)
- suporte Lastro: personificação leitura, chamado, 2 h, CPF mascarado, visível ao marketplace
- próximo: admin marketplace novo cadastra webhook `http://169.254.169.254/latest/meta-data/` (SSRF, cap. 32)

## Conceitos aprofundados aqui
- autorização (sujeito, ação, recurso, contexto), deny by default, PDP/PEP (XACML)
- RBAC (Ferraiolo/Kuhn 1992, ANSI 359-2004), explosão de papéis; ABAC (NIST 800-162, Rego, Cedar); ReBAC (Zanzibar, tuplas, novo inimigo, zookie)
- camadas borda/serviço/banco; filtrar na consulta; 404 × 403; tenant da credencial; confused deputy (Hardy 1988)
- IDOR/BOLA (OWASP API1:2023); UUID = ofuscação; ID sequencial vaza volume
- 4 modelos de isolamento (tabela)
- RLS: USING/WITH CHECK, sem política = nada, superuser/BYPASSRLS/dono sem FORCE, SET LOCAL + pool, `''` após SET LOCAL, views `security_invoker` (PG15), UNIQUE/FK vazam existência, tenant no índice, partições políticas próprias, SECURITY DEFINER

## Casos reais usados
- problema dos tanques alemães (246 × 1.400; real 245); First American 2019 (~885 mi documentos)

## Piadas recorrentes
- analista Hornero: pen test mais barato, crochê no colo, agradecimento formal
- tabelião sem chefe com interruptor; fundador "banco confiava nas pessoas", planilha tem aba p/ isso
- PgBouncer motel → quarto com bagagem do hóspede anterior
- Carlos: `super_suporte` e personificação com escrita "por segurança", backlog ao lado dos 1.024 baldes
- "integração entre concorrentes melhor que a de qualquer cliente"; ID sequencial = relatório de faturamento público
