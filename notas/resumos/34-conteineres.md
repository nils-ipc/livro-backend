# Resumo 34 — Contêineres

## A Lastro ao fim do capítulo
- incidente: 1º contêiner (Carlos, `conector-adquirente`), `CMD ./iniciar.sh` forma shell, `carregar_segredos && python` → shell PID 1 sem tratador descarta SIGTERM; `docker stop` 10 s → SIGKILL, 31 autorizações `processando` (resolução cap. 15, 0 centavos perdidos, "aguarde" 4 min); URGENTE "CONTÊINER????"
- painel: 3 workers × (160 + 4 × 64 MiB Argon2id) ≈ 1,2 GiB em contêiner 512 MiB → OOM killer, sem log, gateway `502`
- contêineres justificados: reação autoscaling (4 min 20 s, 2 min montando máquina), limite memória por serviço, mínimo software no segmento; imagem de máquina bastaria com 1 serviço/máquina
- decisões: 1 processo Uvicorn por contêiner (contagens cap. 29 seguem); `tini` PID 1 + forma exec; base `python:3.12-slim` multiestágio, cofre e conector distroless; UID 10001, raiz somente leitura, sem capabilities; deploy por digest, tag `serviço:data-commit` só humanos; segredos lidos pelo Python na partida
- pagamentos 1,2 GB → 160 MB, pull 38 s → 6 s
- encerramento: `/pronto` falha no SIGTERM, 2 × 2 s, deadline 8 s, SSE `retry` → ≤ 15 s; prazo parada 20 s; alerta SIGKILL > 0; consumidores terminam lote, confirmam offsets
- limites (pico medido → memory.max, cpu.max): pagamentos 180/320 MiB, conector 140/256 MiB, painel 416/640 MiB, relatórios 1,4/2 GiB; todos 2 núcleos; alerta `nr_throttled`; workers fixos = 1, nunca `os.cpu_count()`
- agente lê `memory.events` + código 137 → alerta com serviço e pico
- temp-01 sem contêiner (kernel sem cgroups v2, ninguém reinicia)
- 14 imagens, ~90 contêineres, deploy por scripts bash
- próximo: "orquestrador" do Carlos reinicia contêiner se `/saude` > 1 s; sexta de campanha, lag > 1 s → reinício em cascata derruba pagamentos saudáveis (cap. 35)

## Conceitos aprofundados aqui
- contêiner = processo + namespaces (8, tabela) + cgroups; kernel compartilhado; capabilities, seccomp
- cgroups v2: `memory.max`, OOM no grupo, 137, `memory.events`; `cpu.max` cota/período, throttling, `cpu.stat`, `cpu.weight`; `os.cpu_count()` = host
- OCI Image/Distribution/Runtime; manifest, camadas SHA-256, overlayfs, copy-up, whiteout; cache de build
- multiestágio; bases (completo, slim, Alpine/musl, distroless)
- PID 1: sinal sem tratador ignorado, colhe órfãos; forma shell × exec, `exec`, tini/`--init`; encerramento gracioso 4 passos
- tag mutável × digest; `latest`

## Casos reais usados
- JVM pré-JDK 10/8u191 ignorava cgroup (JDK-8146115); runc CVE-2019-5736

## Piadas recorrentes
- 1º contêiner "serial killer com metas trimestrais"; shell "morreu como viveu"
- OOM: "testemunha é o próprio assassino"
- `.env` apagado na camada = "segredo publicado com controle de versão"
- `latest` nome otimista = `repasse_final_v2_agora_vai.py`
- relatório de risco morre sozinho: "mesmo crime, cena isolada"
- fundador: 1 GB sumido = `.git`, testes, `backup_antigo/` 400 MB CSV do financeiro
- Carlos: 129 workers por aritmética; "orquestrador" bash
