# Resumo 29 — Escalabilidade e capacidade

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- vertical (scale up): código igual, teto de catálogo (centenas de vCPUs, dezenas de TB), reinício/failover, 1 domínio de falha
- horizontal (scale out): réplicas atrás de balanceador, exige stateless; teto = recurso compartilhado (Amdahl/USL → cap. 6)
- stateless: qualquer réplica atende qualquer requisição, morte perde só requisições em andamento; tabela estado local → destino; Twelve-Factor VI, afinidade = violação
- sessão: Redis com TTL ou cookie assinado (revogação = estado)
- HPA: ceil(réplicas × atual/desejado), ciclo 15 s, tolerância 10%, CPU relativa ao request, não prontos = 0% ao crescer, estabilização scale-down 300 s / scale-up 0; behavior policies
- limit = request satura métrica em 100% → crescimento máx. 1,43×/rodada a meta 70%
- tempo de reação = métrica + ciclo + nó novo + imagem + inicialização + readiness
- meta ≤ utilização_máx / (1+g)^T (10%/min, T=5 → 50%)
- histerese: faixa morta ou tempo; cooldown EC2 Auto Scaling 300 s
- métricas: CPU, em andamento (Little), RPS, backlog (KEDA), latência = realimentação positiva
- estimativa: 1 dia ≈ 10^5 s, fator de pico como premissa, Little para núcleos e concorrência
- terminationGracePeriodSeconds 30 s

## Termos e traduções adotados
- scale up/out → escala vertical/horizontal; stateless, autoscaling, cooldown, sticky session em inglês
- stabilization window → janela de estabilização; histerese; fator de pico

## Casos reais e exemplos usados (não repetir)
- hipotético: programa de TV domingo 20h47, QR code bolo de fubá, 60 → 9.000 req/s, 1,2 GB de vetores, 3 min de partida, liveness reinicia, sessões perdidas, Zilda; simulação HPA 3→5→8→12→18→26→38 em 18 min
- estimativa: 2 mi usuários, 579/3.472 req/s, 69 núcleos, 41,8 TiB/ano fotos, 1.138 Mbit/s, 18 TB/dia imagens
- cron 12× receita do dia; maxReplicas 80 → 3.200 conexões
- Pokémon GO jul/2016: 50× meta, 10× pior caso (Google Cloud blog)
