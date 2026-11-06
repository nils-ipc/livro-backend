# Resumo 36 — Redes em nuvem e infraestrutura como código

## A Lastro ao fim do capítulo
- incidente: auditor PCI, SSH no temp-01 (22 aberta p/ internet, chave do fundador) → `nc` em `pg-cofre` `10.0.7.41:5432` conectou; relatório "sem segmentação; escopo = rede inteira"; rede antiga `10.0.0.0/16` por cliques: 11 sub-redes todas com internet, 31 grupos, 214 regras, `default` libera tudo, regra 147 6379 p/ `0.0.0.0/0` "teste"
- VPC principal `10.20.0.0/16`, zonas A/B/C: pública /24 (balanceador `203.0.113.50`, NAT app 1/zona, IPs novos); app /19 (nós cluster); saída /24 (entregadores webhook, NAT `203.0.113.30`, ACL sem estado nega RFC 1918 + 169.254/16, só 443 + efêmeras); dados /24 (bancos, Redis, PgBouncer)
- VPC CDE `10.30.0.0/20`, zonas A/B só, sem peering; único caminho = endpoint privado 443 pagamentos → entrada cofre; NAT a `203.0.113.10` (transferido do proxy api-01), NAT b `203.0.113.11` (vaga do temp-01) → adquirente aceita ≤ 2 IPs; só conector fala c/ adquirente; cofre 3 réplicas em 2 zonas
- banco Pix: IPs NAT app cadastrados (formulário) antes da troca; forward proxy api-01/02 desligado
- endpoints privados p/ KMS, objetos, segredos
- firewalls com estado por papel, origem por grupo; 47 regras (de 214) com motivo no PR; sem porta 22 (sessão gerenciada provedor, identidade cap. 30); `default` vazio + CI recusa
- Terraform: estados por camada (`rede`, `cde`, `dados`, `clusters`, `dns`), backend remoto c/ trava; plan em PR, apply só `main` c/ aprovação; console humano somente leitura + quebra de vidro; drift noturno `-detailed-exitcode`; IPs allowlist `prevent_destroy`; rede antiga importada antes de desmontar; peering temporário (CIDRs sem sobreposição)
- temp-01 DESLIGADO: última cliente integração antiga Bazar (IP `198.51.100.7`), consultoria reiniciou (4 h), 14 dias zero, snapshot, parado (IP perdido), destruído 30 dias depois; uptime 6 anos, 2 meses, 11 dias
- próximo: mudança cálculo tarifa passa CI + 2 aprovadores, vai p/ todas réplicas, 1 h cobrando 1 centavo a mais (cap. 37)

## Conceitos aprofundados aqui
- região, zona (1–2 ms), VPC/VNet, anti-spoofing, sub-rede por zona (GCP regional), 5 endereços reservados AWS
- tabela de rotas, prefixo mais longo, rota local irremovível, gateway internet, pública × privada
- NAT: SNAT, IP fixo, zonal, ~55 mil conexões/destino/IP (AWS)
- endpoints privados (PrivateLink, PSC)
- firewall com estado × sem estado (tabela), efêmeras
- Terraform: declarativo, providers, grafo, estado (só gerencia o que tem, segredos em claro, trava), plan/apply, `forces replacement`, `prevent_destroy`, drift, `import` (1.5), módulos, `for_each` × `count`, `moved`; BSL ago/2023, OpenTofu

## Casos reais usados
- Code Spaces jun/2014 (console invadido, backups apagados, encerrou)

## Piadas recorrentes
- temp-01 morto; financeiro minuto de silêncio; planilha aba "in memoriam"
- Carlos: regra 5432 p/ casa às 23h40 "temporária, debug", drift alarmou 3h, apply 9h removeu
- fundador: IP público sem rota = "reserva estratégica"
- servidor sem efêmeras = "perfeito para reunião de diretoria"
