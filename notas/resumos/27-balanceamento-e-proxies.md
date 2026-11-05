# Resumo 27 — Balanceamento e proxies

## A Lastro ao fim do capítulo
- incidente quarta 14h10: processo antifraude `api-02` segfault, supervisor desistiu (5×/10 s); `ANTIFRAUDE_HOSTS` à mão (Carlos), lida na partida, round robin → 1/3 chamadas RST → degradação cap. 15; breaker fechado (33% < 50%); 1.128 cartões > R$ 300,00 recusados em 47 min; URGENTE 14h31 "algo contra notebook?"; Carlos reiniciou 9 processos 14h57
- IPs privados: temp-01 `10.0.1.10`, api-01 `10.0.1.11`, api-02 `10.0.1.12`
- antes: DNS 2 registros A (api-01, api-02); temp-01 só integração antiga Bazar
- borda: balanceador L4 gerenciado `203.0.113.50` → 3 gateways (1/máquina, inclusive temp-01), PROXY protocol v2 só da faixa do balanceador → requisito política por marketplace (caps. 28/30) + mTLS banco; MUDA cap. 10: ACME por máquina continua nos gateways
- gateway: rotas Host/prefixo, timeout criação cobrança 9 s (> deadline 8 s), relatórios 120 s, sem afinidade, 404 RFC 9457
- interno: proxy local por máquina (Envoy ex.), porta `127.0.0.1:71xx` por serviço (antifraude 7100), lista do deploy; P2C least request; ativa `/pronto` 2 s, fora 2 falhas; passiva 5 falhas → 30 s dobrando, máx 1/3; pânico 50%; repete só falha de conexão
- `/pronto` só local (tarifas, drenagem, lag loop < 50 ms); PR Carlos `/saude` profundo fechado
- réplicas: pagamentos ×9, antifraude ×6, ledger ×6
- saída: forward proxy `CONNECT` ativo api-01/passivo api-02, IP `203.0.113.10`, failover ~30 s (hipótese), lista de destinos (cap. 32); adquirente exige allowlist ≤ 2 IPs; formulário tirar IP temp-01 do banco (10 dias úteis); NAT cap. 36
- descartados: mesh (até cap. 35), CDN na API (PCI), L7 gerenciado
- próximo: Hornero `while True` 4.000 `GET /v1/cobrancas/{id}`/s (cap. 28)

## Conceitos aprofundados aqui
- L4 (NAT, DSR, proxy TCP) × L7; PROXY protocol v1/v2
- RR, aleatório, least conn/outstanding (ama quem falha rápido), P2C (`ln ln n / ln 2`), hash/Maglev
- ativa/passiva, liveness/readiness, health check profundo = falha correlacionada, limite ejeção, pânico, drenagem, keep-alive backend > balanceador (502)
- sticky; reverse proxy, gateway, mesh, CDN; XFF da direita

## Casos reais usados
- Fastly 8/6/2021 (85%, 49 min)

## Piadas recorrentes
- temp-01 promovido a borda, exame médico a cada 2 s, passa
- health check que mata paciente, família e médico; gateway = monólito em YAML
- variável do Carlos aposentada com honras
