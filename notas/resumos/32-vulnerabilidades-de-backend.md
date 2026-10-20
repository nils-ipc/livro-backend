# Resumo 32 — Vulnerabilidades de backend

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- padrão comum: dado externo → interpretador (SQL, shell, cliente HTTP, pickle) trata como instrução
- OWASP Top 10:2025: A01 Broken Access Control absorve SSRF; Supply Chain Failures; nova Mishandling of Exceptional Conditions; ASVS = padrão de verificação
- OWASP API Top 10 2023: API1 BOLA, API3 BOPLA, API5 BFLA, API7 SSRF, API9 inventário
- injeção: extended query protocol Parse/Bind, psycopg 3 binding no servidor; identificadores → lista fechada + `psycopg.sql.Identifier`; `text(f"...")`; `subprocess` sem `shell=True`; SSTI Jinja
- SSRF: metadados 169.254.169.254, IMDSv2 (PUT token), `Metadata-Flavor: Google`; validar esquema + todos IPs com `is_global` + IPv4 mapeado; conectar ao IP validado (DNS rebinding); redirects; proxy/firewall de saída (Smokescreen)
- pickle: STACK_GLOBAL + REDUCE; yaml.load, shelve, torch.load (weights_only padrão 2.6); JSON + Pydantic; HMAC só entre lados próprios
- BOPLA: exposição excessiva + mass assignment; `extra="forbid"`, `response_model`
- dependências: pip-audit/OSV, lockfile, índice único, `--require-hashes`; dependency confusion
- falhar fechado em autorização

## Termos e traduções adotados
- SSRF, DNS rebinding, mass assignment, dependency confusion, WAF em inglês
- excessive data exposure → exposição excessiva de dados

## Casos reais e exemplos usados (não repetir)
- hipotético: pentest sexta 17h40 "Conseguimos tudo", lista de casamento Noemi e Haroldo, fondue R$ 0,01 ×11, `/admin-temporario` 2021
- validador `resolver_destino_publico`; pickletools date(2026, 5, 16); 422 extra_forbidden is_admin
- Jinja2 GHSA-h5c8-rqwp-cp95; Birsan 2021 (35+ empresas); xz CVE-2024-3094 (Freund, ~0,5 s); Capital One 2019; Equifax 2017 Struts CVE-2017-5638 (147 mi)
