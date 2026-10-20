# Resumo 35 — Kubernetes

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- control plane: kube-apiserver (único que fala com etcd), etcd (Raft), scheduler, controller-manager
- nó: kubelet (CRI, probes), runtime containerd/CRI-O, kube-proxy (iptables/nftables, eBPF substitui)
- spec vs status; reconciliação level-triggered; list + watch, resourceVersion
- data plane sobrevive sem control plane; mudança para
- pod: rede compartilhada, contêiner pause, IP por pod sem NAT (CNI), descartável
- Deployment → ReplicaSet por template (pod-template-hash); maxSurge 25% ↑ / maxUnavailable 25% ↓; rollout undo; progressDeadlineSeconds 600 s não desfaz
- Service ClusterIP = IP virtual, DNAT por conexão (L4); NodePort 30000–32767; LoadBalancer; EndpointSlice ready; DNS nome.namespace.svc.cluster.local
- Ingress precisa de controller; Gateway API v1.0 out/2023
- ConfigMap 1 MiB; Secret base64, em claro no etcd sem encryption at rest; criar pod = ler Secret; env nunca atualiza, volume com atraso, subPath nunca; nome com hash
- scheduler olha requests, kernel limits; QoS Guaranteed/Burstable/BestEffort, ordem de despejo
- probes startup/liveness/readiness; padrões 10 s/1 s/3; CrashLoopBackOff 10 s → 5 min, zera após 10 min
- encerramento: deletionTimestamp → preStop/SIGTERM/30 s/SIGKILL em paralelo com remoção do EndpointSlice; preStop sleep nativo 1.30

## Termos e traduções adotados
- eviction → despejo; control plane, data plane, watch, rolling update, preStop, overcommit em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: karaokê Microfone de Ouro, Dona Glória, "Evidências", 23 unidades, liveness `/health` SELECT 1, banco 4 ms → 1,3 s, 22h09–22h31
- cliente Python watch rolling update 7d9f8b6c5d → 5c8b7f9d4b
- Reddit Pi Day 14/03/2023, 314 min, rótulo master → control-plane, Calico
- OpenAI 11/12/2024, telemetria sobrecarrega API server, DNS
