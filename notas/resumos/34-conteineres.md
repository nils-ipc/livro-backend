# Resumo 34 — Contêineres

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- contêiner = task comum + namespaces + cgroups + raiz própria + capabilities + seccomp (Docker bloqueia ~44 syscalls); kernel compartilhado
- 8 namespaces (pid, mnt, net, uts, ipc, user, cgroup, time 5.6); clone/unshare/setns (`docker exec`)
- rede: veth + bridge, `-p` = DNAT iptables; localhost = próprio contêiner; portas publicadas ignoram ufw
- user namespace ausente → root dentro = root fora; rootless, userns-remap
- cgroup v2: memory.max → OOM killer no grupo, SIGKILL, 137, OOMKilled; memory.events oom_kill; tmpfs/`/dev/shm` contam
- cpu.max cota/período 100 ms soma threads → throttling (cpu.stat nr_throttled); cpu.weight; mapeamento requests/limits K8s; PYTHON_CPU_COUNT 3.13
- imagem = tar + JSON; OverlayFS lowerdir/upperdir, copy-up, whiteout; rm posterior não reduz; cache por instrução; .dockerignore
- multi-stage, venv copiado, `--mount=type=cache/secret`, USER não root
- bases: full ~1 GB, slim ~130 MB, Alpine musl (PEP 656, DNS TCP até 1.2.4), distroless sem shell (kubectl debug)
- PID 1: só sinais com handler; Python sem handler SIGTERM; docker stop 10 s, K8s 30 s; 137/143; forma shell vs exec; `exec` no entrypoint; zumbis, tini, `--init`
- OCI Distribution API manifests/blobs, digest SHA-256, image index multiarquitetura, tag mutável, latest sem significado
- OCI 2015: runtime/image/distribution spec; dockerd → containerd → shim → runc; dockershim removido 1.24

## Termos e traduções adotados
- throttling → estrangulado (*throttled*); copy-up, whiteout, shim, bundle, rootless, distroless em inglês
- zombie → zumbi

## Casos reais e exemplos usados (não repetir)
- hipotético: Padaria Trigo Dourado, `fila-do-pao`, senha 47, Jéssica, 14 lojas, loja 9 50 Mbit/s, loja 3 `latest-final` em cache, 2,04 GB → 187 MB, stop 10,2 s → 1,4 s
- cpu.stat 31.102/86.400 throttled; exec format error ARM
- CVE-2019-5736 runc; CVE-2024-21626 Leaky Vessels
