# Resumo 35 — Kubernetes

## A Lastro ao fim do capítulo
- incidente sexta 20h14, "Semana da Capinha" Bazar: laço bash do Carlos (41 linhas, `/saude` > 1 s → `docker restart` 10 s < drenagem 15 s) → 22 de 24 contêineres pagamentos reiniciados em 4 min; 640 autorizações `processando`, 6 min `503` Pix; URGENTE 20h19 "DESLIGARAM DE PROPÓSITO???"
- cluster gerenciado (EKS/GKE/AKS ex.), zonas A/B/C, nós 8 vCPU 16 GiB, 9–36 nós, espalhamento por zona, PDB pagamentos `maxUnavailable` 10%
- segmento cartão (entrada cofre, cofre, conector) = cluster separado → namespace não isola control plane/kernel; escopo PCI
- fora do cluster: bancos (ledger Patroni/síncrona/fencing; failover 30–40 s por drenagem de nó), Redis, broker; proxy saída `203.0.113.10` api-01/02; temp-01
- pagamentos por pod: CPU req 1/limit 2; memória req = limit 320 MiB (Burstable); HPA 12–60, alvo 35% do request ou lag > 50 ms; +50%/min, −3 pods/5 min após 15 min; `maxSurge` 20%, `maxUnavailable` 0; `preStop` `sleep` nativo 5 s (distroless sem shell), prazo 25 s
- probes: startup `/vivo` 2 s × 30; readiness `/pronto` (cap. 27) 2 s × 2; liveness `/vivo` (sem dependência) 10 s, timeout 5, × 6 = 60 s
- mesh sidecar nativo (Istio/Linkerd ex.) substitui proxy local → P2C/ejeção/pânico + HTTP/2 por requisição + mTLS por ServiceAccount (segmento aceita só pagamentos); ~50 MiB/pod, +0,4 ms/salto da folga 120 ms
- segredos: gerenciador cap. 33 via identidade de carga de trabalho (token ServiceAccount); papel por ServiceAccount; NetworkPolicy bloqueia `169.254.169.254`; sem Secret do K8s p/ app
- pods de lastro (enchimento, prioridade negativa) p/ capacidade adiantada
- `repasse_final_v2_agora_vai.py` = Deployment 2 réplicas; lease segue no PostgreSQL (Lease K8s sem fencing no débito)
- próximo: auditor PCI vê temp-01 (6 anos, "provisório") na mesma rede privada do cofre (cap. 36)

## Conceitos aprofundados aqui
- apiserver, etcd Raft, scheduler, controller-manager, kubelet/CRI, watch/`resourceVersion`, reconciliação
- pod, IP sem NAT, CNI, sidecar nativo 1.33
- Deployment/ReplicaSet, labels, maxSurge/maxUnavailable 25%, corrida encerramento × EndpointSlices, preStop no prazo
- Service ClusterIP, EndpointSlices só prontos, kube-proxy L4 por conexão, sem pânico; Ingress/Gateway API (v1.0 out/2023)
- Secret base64 em claro no etcd; criar pod = ler Secret
- requests/limits → cgroup, QoS, despejo
- probes, padrões (timeout 1 s), CrashLoopBackOff; readiness × liveness
- HPA % do request, `behavior`, autoscaler de nós, preempção

## Casos reais usados
- Reddit Pi Day 2023 (314 min, 1.23→1.24, label `master`, Calico)
- `ndots:5`

## Piadas recorrentes
- orquestrador Carlos: segurança de boate; apagado com honras
- pods de lastro: "35 capítulos para ter lastro, feito de pod vazio"
- liveness padrão = orquestrador do Carlos com documentação em 15 idiomas
- "master" se vingou; NetworkPolicy = lápide do botão "Testar"
