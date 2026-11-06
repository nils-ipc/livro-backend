# Resumo 32 — Vulnerabilidades de backend

## A Lastro ao fim do capítulo
- incidente quarta 14h05: marketplace novo Pechincha Relâmpago (passou análise comercial: CNPJ existia), admin cadastra webhook `http://169.254.169.254/latest/meta-data/iam/security-credentials/`; botão "Testar endpoint" do Carlos (`GET` do servidor, mostra status + 2 KB) → papel `lastro-maquina` → 14h07 credenciais temporárias; papel único p/ todas as máquinas do autoscaling (mesma imagem) lia bucket relatórios exportados → 14h19 de fora da nuvem baixou 3 relatórios mensais de 2 marketplaces (CPF compradores); 14h31 detector anomalias do provedor; 14h40 Carlos invalidou sessões + desligou botão
- webhooks: cadastro só https/443, nome (nunca IP literal); validação que protege = na entrega: resolve DNS, rejeita não globais (RFC 1918, loopback, 169.254/16, fe80::/10, 100.64/10, fc00::/7, IPv4 mapeado), conecta no IP validado (Host + SNI = nome), 3xx = falha, guarda só status/latência/classe de erro; "Testar" = evento `webhook.teste` por POST
- entregadores em nós de saída dedicados, sub-rede sem rota interna/metadado, IP de saída próprio ≠ `203.0.113.10` (rede cap. 36)
- metadado com token de sessão + 1 salto em todas as máquinas; papel por grupo de máquinas, mínimo
- revisão por listas: modelos entrada `extra="forbid"`/`response_model` (achado: `PATCH` vendedor aceitava `tarifa_pix`); `/interno` só proxy local, fora do OpenAPI; ordenação por lista, CI recusa f-string em `execute`/`text()`; `pickle` proibido por lint (achado: cache painel no Redis usava pickle), JSON + Pydantic; resposta adquirente com schema e tamanho máx.; CSV com apóstrofo antes de `= + - @` tab CR (achado: vendedor 42 `=HYPERLINK`); corpo ≤ 1 MB no gateway; `defusedxml`; lock com hashes, índice privado, `pip-audit`, SBOM; RFC 9457 sem stack trace; fail closed (achado: `except: pass` do Carlos na assinatura notificações banco, 2024, `# temporario`)
- próximo: busca do token nos logs acha log de depuração do `conector-adquirente` desde a BF com PAN, validade e nome em texto puro, centenas de milhares, em bucket que o papel antigo lia (cap. 33)

## Conceitos aprofundados aqui
- OWASP Top 10:2025 (SSRF dentro de A01), API Security Top 10 2023 (tabela com remissões)
- SSRF: alvos, codificações alternativas (decimal 2852039166, IPv6 mapeado), redirecionamento (requests segue, httpx não), DNS rebinding, defesa por endereço, rede de saída, IMDSv2/`Metadata-Flavor`, blind
- injeção: parametrização psycopg 3 (protocolo estendido), `sql.Identifier`, shell, SSTI, CSV/fórmula
- deserialização: `pickle` `__reduce__`, `yaml.safe_load`, HMAC não resolve
- BOPLA (mass assignment, exposição excessiva), BFLA
- dependências: CVE conhecido, typosquatting, confusão de dependência, lock com hashes, SBOM

## Casos reais usados
- Capital One 2019 (~100 mi EUA + 6 mi Canadá, SSRF metadado); Equifax 2017 (Struts CVE-2017-5638, ~147 mi); Birsan 2021 dependency confusion; xz-utils CVE-2024-3094

## Piadas recorrentes
- Carlos: botão "feature mais usada do painel", "por uma margem de 2 KB"
- planilha do financeiro também é interpretador; financeiro desconfiado mesmo com fórmula virando texto
- fundador: chave "num arquivo" no temp-01 (cap. 33 visita)
- `curl` não tem gerente de produto
