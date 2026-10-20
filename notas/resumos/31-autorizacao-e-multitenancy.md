# Resumo 31 — Autorização e multitenancy

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- decidir(sujeito, ação, recurso, contexto) → permitir/negar; negar por padrão; recurso concreto
- PEP/PDP (termos XACML)
- RBAC: Ferraiolo/Kuhn 1992, RBAC96, ANSI INCITS 359-2004; explosão de papéis
- ABAC: NIST SP 800-162 (2014); Rego/OPA, Cedar; auditoria cara
- ReBAC: Zanzibar USENIX ATC 2019, tuplas `objeto#relação@sujeito`, userset, reescrita; p95 <10 ms, >99,999%; problema do novo inimigo, zookie; OpenFGA, SpiceDB
- gateway = token/escopo/rota; objeto = serviço dono, filtro na consulta
- IDOR = BOLA (OWASP API1 2019/2023); 404 para alheio; IDs no corpo; mass assignment; UUID não corrige; filtro pós-consulta quebra paginação
- isolamento: banco/schema/coluna/coluna+RLS; silo/pool/bridge (AWS SaaS); vizinho barulhento; híbrido + diretório tenant→banco
- RLS PG 9.5: ENABLE + FORCE (dono ignora), superuser/BYPASSRLS ignoram; `NULLIF(current_setting('app.x', true), '')`; set_config(..., true) = SET LOCAL, PgBouncer transaction; erro "new row violates row-level security policy"; FK composta (tenant_id, id); índice começando pelo tenant

## Termos e traduções adotados
- tenant, multitenant, userset, zookie, mass assignment em inglês
- noisy neighbor → vizinho barulhento; new enemy → novo inimigo

## Casos reais e exemplos usados (não repetir)
- hipotético: AgendaDente, Dr. Plínio (Sorriso Pleno, clínica 7), Dona Rosângela (Dente de Ouro, 8), paciente 1042→1043, R$ 189
- worker de SMS com BYPASSRLS
- First American Financial mai/2019, 885 mi documentos (Krebs)
- ChaosDB Azure Cosmos DB ago/2021 (Wiz)
