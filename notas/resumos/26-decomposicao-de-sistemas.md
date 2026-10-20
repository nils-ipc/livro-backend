# Resumo 26 — Decomposição de sistemas

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- 3 unidades independentes: código (disciplina), deploy (rede), dados (transações)
- monólito, monólito modular (interface pública, tabelas próprias, fronteira no CI), microsserviços (Lewis/Fowler 2014)
- acoplamento/coesão Stevens/Myers/Constantine 1974; níveis conteúdo, comum, controle, carimbo, dados; Parnas 1972 information hiding
- acoplamentos distribuídos: temporal, deploy, schema, semântico → monólito distribuído
- coesão operacional = co-mudança no git
- chamada função 88 ns vs HTTP local ~412 µs (~4.700×); DC ~500 µs (Dean 2009); N+1 remoto 50 × 2 ms
- série A = ΠAi: 99,9% × 9 = 99,1% (6,5 h/mês), ×14 = 98,61% (10 h); paralelo 1−(1−A)^N; correlação
- tirar do caminho crítico: degradação, evento, cópia local
- banco por serviço = posse lógica; schema + role, `permission denied for schema`; perde JOIN, FK, transação
- strangler fig (Fowler 2004); bounded context (Evans 2003)
- Conway 1968 Datamation; MacCormack 2012; Nagappan 2008 Vista

## Termos e traduções adotados
- monólito modular, monólito distribuído, acoplamento temporal/de deploy/de schema/semântico
- strangler fig, bounded context em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: loja de vinil, 14 serviços/4 pessoas, `servico-de-avatares` 48×48, checkout 9 chamadas, `ORDEM_DO_DEPLOY.txt`, LP-1977-RUMOURS
- script git co-change pagamentos+pedidos 61
- import-linter forbidden; Packwerk Shopify
- Prime Video 2023 (−90%); Segment 2018 (140+ serviços)
