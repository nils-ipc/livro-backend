# Resumo 29 — Escalabilidade e capacidade

## A Lastro ao fim do capítulo
- incidente terça 15h12–15h34: Carlos autoscaling homologação máx 64 "por segurança"; 64 conexões HTTP/2 homolog adquirente pelo mesmo proxy saída `203.0.113.10` (allowlist 2 IPs, 2º ainda temp-01) → 73 > 20 → adquirente bloqueia IP 15 min, produção junto; 2.730 autorizações `503` `adquirente-indisponivel`, ninguém cobrado; URGENTE 15h22 "escalando ou caindo?"
- novo cliente: Tuiuiú (grupo de varejo), 10× Bazar, migração 4 meses; contrato: aviso campanha 48 h
- Bazar = 50% pico → Lastro com Tuiuiú = 6× pico ref. cap. 14: 17,2 s CPU/s → 50 workers pagamentos (ρ ≤ 0,7 no 2×)
- `conector-adquirente`: 10 processos fixos (5 api-01, 5 api-02), 1 conexão × 100 streams; 648 em andamento no 2×; +2 conexões homologação; breaker/bulkhead/deadline movidos; +~1 ms
- sharding ledger IMPLANTADO: gatilho cap. 24 (4.800/7.000 medidos = 69%); Tuiuiú shard próprio, máquina 2× núcleos, ~11.000/s medidos (1,6×), 36%; shard 0 ~800/s
- contas quentes shard Tuiuiú: 32 baldes (~9.000/s)
- `cobrancas.eventos` 12 → 48 partições (pausa relay CDC, lag zero, acrescenta)
- webhooks: concorrência por inscrição via Little; Tuiuiú 800 (endpoint ~150 ms, 2.500/s); ~72 Mbit/s
- ledger 9 mi lanç/dia × ~170 B ≈ 1,5 GB/dia, 560 GB/ano; 10 anos ≈ 5,6 TB/cópia, 33 bi; online 24 meses, resto DETACH arquivo; `eventos_cobranca` ~270 GB/ano particionada mês
- autoscaling (grupos de máquinas do provedor, imagem imutável, 3 workers/4 vCPU; registro de serviços, releitura 5 s): pagamentos 12–60 (teto 60 LISTEN + 18 PgBouncer < 100), antifraude 6–30, entregador 2–20 (idade entrega, alvo 5 s), ledger consumidor 6–48; alvo CPU 35%; sobe +50% (2 min ou lag > 50 ms 1 min); desce 1 máquina/5 min após 15 min < 20%, drena 15 s, SSE `retry`; agenda: mín 50 uma hora antes de campanha/BF; tempo de reação 4 min 20 s
- fixos: temp-01, api-01, api-02, repasses, relatórios; homologação máx 6 processos
- próximo: consultoria Java Bazar publica repositório exemplo com chave API produção do Bazar no `application.properties` (cap. 30)

## Conceitos aprofundados aqui
- estimativa ordem de grandeza, conversões (86.400 s), fator de pico, cadeia
- vertical × horizontal; USL Gunther `N/(1+α(N−1)+βN(N−1))`, `N*`, retrógrada
- stateless como auditoria; limite por processo × N
- autoscaling: regra proporcional HPA, tolerância 10%, estabilização 300 s; métricas; histerese/flapping; tempo de reação → alvo; agendado/preditivo; máximo do recurso escasso

## Casos reais usados
- Pokémon GO 2016 (50× meta, 10× pior caso)

## Piadas recorrentes
- Carlos: "por segurança" (64 processos, 1.024 baldes); post-it no monitor
- fundador ganhou máquina maior "para um shard só"
- temp-01 "é a imagem"; Lastro escala para zero
- tabelião pediu estagiário (33 bi)
- autoscaler manda mais clientes ao banco lento; 13º consumidor = VP de inovação
