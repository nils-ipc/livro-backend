# Contêineres

## A senha 47 e os dez segundos de silêncio

Segunda-feira, 6h58. A TV da Padaria Trigo Dourado mostra `SENHA 47` há onze minutos, e onze clientes seguram papeizinhos com números maiores que 47 (a padaria é hipotética; os papeizinhos, infelizmente, são universais).

Quem chama as senhas é o `fila-do-pao`, um worker Python que lê a fila de atendimento num Redis e manda o próximo número para as TVs das catorze lojas. Às 6h47 alguém fez o deploy de uma correção "de uma linha só" no texto da TV. A Jéssica, que cuida do serviço, juntou as pistas no canal de incidentes:

- `docker stop fila` leva 10,2 segundos. Sempre. Mesmo com o worker parado, sem nada para fazer.
- O log termina no meio da frase `chamando senha 4`, e o contêiner sai com código `137`.
- A imagem `padaria/fila-do-pao:latest-final` tem 2,04 GB. Na loja 9, com um link de 50 Mbit/s, o download levou quase dois minutos, e nesse tempo a senha 47 ficou na tela, firme, com a serenidade de quem não sabe que tem gente com fome.
- A loja 3 subiu uma versão diferente das outras treze, apesar de todas usarem a mesma tag.

Nenhuma dessas quatro coisas é bug do Python. Todas saem de como o Linux implementa um contêiner. A pergunta que o capítulo responde: o que, exatamente, o kernel enxerga quando você diz "contêiner", e o que ele faz com os sinais, a memória, a CPU e os bytes da imagem?

## Um contêiner é um processo comum com a visão restrita

O kernel Linux não tem nenhum objeto chamado "contêiner". Existe a *task* de sempre, criada com `clone()`, à qual o runtime aplica namespaces (o que o processo enxerga), cgroups (quanto ele gasta) e uma raiz própria montada a partir da imagem. Por cima entram *capabilities* reduzidas e um filtro seccomp (o perfil padrão do Docker desliga cerca de 44 das mais de 300 chamadas de sistema).

Não há máquina virtual. Os contêineres de um host compartilham o kernel, e o worker aparece no `ps` do host com um PID qualquer, sem cerimônia. Por isso um contêiner sobe em milissegundos, e uma falha no kernel ou no runtime atinge todos de uma vez.

### Namespaces, ou o que o processo consegue ver

Um *namespace* dá ao processo uma cópia isolada de um recurso global do kernel. São oito tipos:

| Namespace | Efeito no contêiner |
|-----------|---------------------|
| `pid` | O primeiro processo vira PID 1 |
| `mnt` | Raiz e `/proc` próprios |
| `net` | Interfaces, rotas, portas e `localhost` próprios |
| `uts` | Hostname próprio |
| `ipc` | Memória compartilhada e `/dev/shm` separados |
| `user` | Root dentro pode ser usuário comum fora |
| `cgroup` | `/sys/fs/cgroup` mostra só o próprio grupo |
| `time` | Relógios monotônicos próprios (kernel 5.6) |

`clone()` cria o processo já em namespaces novos, `unshare()` move o atual e `setns()` entra num existente (é o que `docker exec` faz). Um contêiner tosco, sem Docker nenhum:

```bash
$ sudo unshare --pid --fork --mount-proc sh -c 'echo "meu PID: $$"; ps -e'
meu PID: 1
    PID TTY          TIME CMD
      1 pts/0    00:00:00 sh
      2 pts/0    00:00:00 ps
```

O `sh` acredita ser o primeiro processo do universo. No host, ele tem um PID de cinco dígitos e nenhuma autoestima especial.

No namespace de rede, o Docker cria um par `veth` (duas interfaces virtuais ligadas ponta a ponta), põe uma ponta dentro como `eth0` e liga a outra a uma bridge no host. O `-p 8000:8000` vira uma regra de NAT de destino no iptables do host. E `localhost` dentro do contêiner é o próprio contêiner: o Redis "em localhost" do notebook passa a ser procurado num namespace onde só existe o worker.

Sem namespace `user`, o UID 0 dentro do contêiner é o UID 0 do host, com menos capabilities. Quem escapa do isolamento escapa como root. Os modos *rootless* e `userns-remap` mapeiam o root interno para um UID alto e sem poder no host.

### cgroups, ou quanto o processo consegue gastar

Um *cgroup* (control group) agrupa processos e aplica limites e contabilidade por grupo. Na versão 2, tudo é arquivo em `/sys/fs/cgroup`, um diretório por grupo. O runtime cria o do contêiner e escreve os limites:

```bash
$ docker run -d --name fila --memory=256m --cpus=1 padaria/fila-do-pao:1.5.0
$ docker exec fila cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/cpu.max
268435456
100000 100000
```

`memory.max` é o teto em bytes (256 × 1024²). No teto, o kernel tenta recuperar páginas; se não consegue, o OOM killer escolhe um processo **dentro do grupo**, normalmente o maior, e manda `SIGKILL`. Sem `MemoryError`, sem última palavra no log: o processo deixa de existir no meio de uma linha de código.

O contador inclui memória anônima (o heap do Python), cache de páginas de arquivos e arquivos em `tmpfs`, inclusive `/dev/shm`: gravar 300 MB temporários ali num contêiner de 256 MB é morrer por causa de um arquivo. O `memory.events` registra o histórico de vexames:

```bash
$ docker exec fila cat /sys/fs/cgroup/memory.events
low 0
high 0
max 1843
oom 3
oom_kill 3
oom_group_kill 0
```

`oom_kill 3` diz quantos processos morreram. Se a vítima é um filho (um worker do Gunicorn), o contêiner continua vivo e o mestre loga `Worker (pid:212) was sent SIGKILL! Perhaps out of memory?`. Se a vítima é o PID 1, o contêiner termina com código 137 e `OOMKilled: true` no `docker inspect`.

A CPU tem outra mecânica. `cpu.max` contém `cota período`, em microssegundos: `100000 100000` são 100 ms de CPU a cada janela de 100 ms, uma CPU. A cota soma todas as threads do grupo. Quatro threads ocupadas gastam os 100 ms em 25 ms de relógio e passam os 75 ms seguintes estranguladas (*throttled*), com 63 núcleos ociosos no host olhando para o teto.

```bash
$ docker exec fila cat /sys/fs/cgroup/cpu.stat
usage_usec 912334871
user_usec 801223004
system_usec 111111867
nr_periods 86400
nr_throttled 31102
throttled_usec 2210338412
nr_bursts 0
burst_usec 0
```

Em 36% das janelas o grupo esgotou a cota e ficou parado, em média 71 ms por vez. Qualquer requisição que chegue no fim da janela ganha até 75 ms de brinde, invisíveis no gráfico de CPU, que mostra serenos 40% de média. O limite de CPU produz latência; o de memória produz cadáveres.

`cpu.weight` (padrão 100) define a fatia relativa só quando há disputa. No Kubernetes, `limits.cpu` vira `cpu.max`, `requests.cpu` vira `cpu.weight` e `limits.memory` vira `memory.max` (capítulo 35). E `os.cpu_count()` ignora o `cpu.max`, assunto do capítulo 4; desde o Python 3.13 a variável `PYTHON_CPU_COUNT` força o valor.

## Imagens e camadas, ou por que o arquivo apagado continua lá

Uma imagem é um conjunto de arquivos `tar` (as camadas) mais um JSON de configuração (ambiente, usuário, comando). Cada `RUN`, `COPY` ou `ADD` gera uma camada com a **diferença** em relação à anterior; `ENV`, `CMD` e `USER` só alteram o JSON.

O runtime monta a raiz com OverlayFS: as camadas da imagem entram empilhadas como `lowerdir`, somente leitura, e um diretório vazio por contêiner entra como `upperdir`, gravável. Alterar um arquivo de baixo dispara *copy-up*, a cópia do arquivo inteiro para cima antes da primeira escrita (um SQLite de 2 GB que recebe um `UPDATE` vira 4 GB no disco). Apagar cria um *whiteout*, uma marca dizendo "finja que isto não existe", e o original continua intacto na camada de baixo.

O Dockerfile do `fila-do-pao` mostra o resultado:

```dockerfile
FROM python:3.12
WORKDIR /app
COPY . .
RUN apt-get update && apt-get install -y build-essential libpq-dev
RUN pip install -r requirements.txt
RUN rm -rf /app/dados_de_teste    # "limpeza"
CMD python worker.py
```

```bash
$ docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' padaria/fila-do-pao:latest-final
0B      CMD ["/bin/sh" "-c" "python worker.py"]
0B      RUN /bin/sh -c rm -rf /app/dados_de_teste # buildkit
412MB   RUN /bin/sh -c pip install -r requirements.txt # buildkit
287MB   RUN /bin/sh -c apt-get update && apt-get install -y build-essential libpq-dev # buildkit
318MB   COPY . . # buildkit
0B      WORKDIR /app
...
```

O `rm` custou 0 B e economizou 0 B. Os 290 MB de `dados_de_teste` continuam na camada do `COPY`, junto com o `.git` e, num dia ruim, o `.env` com a senha do Redis (capítulo 33). Quem tem permissão de *pull* extrai a camada com `tar` e lê tudo. O `.dockerignore` decide o que entra; o `rm` posterior só esconde.

O cache de build segue a mesma estrutura: cada instrução tem uma chave calculada a partir dela e, no `COPY`, do conteúdo dos arquivos. Mudou uma chave, tudo depois é refeito. Com `COPY . .` antes do `pip install`, mudar o texto da TV reinstala 412 MB de dependências. Copiar `requirements.txt` primeiro, instalar e só depois copiar o código mantém o `pip install` no cache.

## Build em múltiplos estágios e imagens mínimas

Compilar dependências exige compilador, cabeçalhos e ferramentas que a aplicação nunca usa em produção. O build em múltiplos estágios separa as duas coisas: vários `FROM` no mesmo Dockerfile, e só o último vira a imagem final, que copia do anterior apenas o que interessa.

```dockerfile
# syntax=docker/dockerfile:1
FROM python:3.12-slim AS construcao
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

FROM python:3.12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 \
 && rm -rf /var/lib/apt/lists/*
RUN useradd --uid 10001 --no-create-home padeiro
COPY --from=construcao /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" PYTHONUNBUFFERED=1
WORKDIR /app
COPY src/ ./src/
USER padeiro
CMD ["python", "-m", "src.worker"]
```

O estágio `construcao` fica com o `build-essential` e morre esquecido no cache do builder. O final recebe o virtualenv pronto e só a `libpq5`. O `rm -rf /var/lib/apt/lists/*` está no **mesmo** `RUN` do `apt-get`, então os índices nunca chegam a existir numa camada. O `--mount=type=cache` guarda o cache do pip entre builds fora da imagem (o `--mount=type=secret` faz o mesmo com tokens). O código pertence ao root e o processo roda como `padeiro`, sem poder alterar o próprio código.

```bash
$ docker image ls padaria/fila-do-pao
REPOSITORY            TAG            IMAGE ID       CREATED          SIZE
padaria/fila-do-pao   1.5.0          9b2d41c07e1f   2 minutes ago    187MB
padaria/fila-do-pao   latest-final   3f1c88a2d6b0   3 weeks ago      2.04GB
```

Onze vezes menor. Na loja 9, o download comprimido cai de quase dois minutos para uns dez segundos, e a senha 47 perde a desculpa.

A imagem base é a escolha com mais consequências. As principais para Python, em ordem decrescente de conforto:

| Base | Tamanho aproximado (descompactada) | libc | Shell e gerenciador de pacotes | Consequência |
|------|------------------------------------|------|-------------------------------|--------------|
| `python:3.12` | ~1 GB | glibc | Sim, com compiladores | Tudo instala; tudo pesa |
| `python:3.12-slim` | ~130 MB | glibc | Sim (`apt`) | Wheels `manylinux` funcionam |
| `python:3.12-alpine` | ~50 MB | musl | Sim (`apk`) | Sem wheel `musllinux`, compila do fonte |
| Distroless Python | ~50 MB | glibc | Não | Sem shell para depurar nem para o invasor |
| `scratch` | 0 B | Nenhuma | Não | Só binários estáticos; Python não cabe |

Os tamanhos são ordem de grandeza, com base em imagens oficiais de 2026, e variam por versão e arquitetura.

Os wheels `manylinux` do PyPI são compilados contra a glibc e não servem na Alpine. Pacotes sem wheel `musllinux` (PEP 656) compilam do fonte, e um `pip install` de 20 segundos vira quinze minutos de compilação de `numpy`. Até a versão 1.2.4 (2023), o resolvedor do musl nem repetia por TCP uma resposta DNS truncada.

A *distroless* corta shell, `apt` e `ps`: menos CVEs no scanner, menos ferramentas para um invasor. O custo chega no primeiro incidente, quando `docker exec fila sh` responde `executable file not found` e a depuração passa a exigir um contêiner auxiliar nos namespaces do alvo (`kubectl debug` com contêiner efêmero).

## PID 1, sinais e a morte em dez segundos

Agora os dez segundos. `docker stop` manda `SIGTERM` (ou o sinal definido em `STOPSIGNAL`) para o PID 1 do contêiner, espera o prazo (10 segundos por padrão, ajustável com `-t`) e, se o processo ainda existe, manda `SIGKILL`. O Kubernetes faz o mesmo com `terminationGracePeriodSeconds`, que vale 30 segundos.

O PID 1 tem um regime especial no kernel. Para qualquer outro processo, um sinal sem handler instalado aplica a ação padrão (`SIGTERM` termina o processo). Para o init de um namespace de PID, a regra muda: o kernel só entrega os sinais para os quais o processo instalou um handler; os demais são descartados. A exceção é o `SIGKILL` vindo de um namespace ancestral, que sempre funciona, e é por isso que o contêiner acaba morrendo. O kernel foi projetado assim para que ninguém derrube o init de um sistema por acidente, e aplica a mesma regra ao seu worker, com o mesmo zelo burocrático.

O Python instala handler para `SIGINT` (é ele que gera o `KeyboardInterrupt`), mas deixa o `SIGTERM` na ação padrão. Um `python worker.py` comum, como PID 1, recebe o `SIGTERM` e o kernel joga o sinal fora. O worker continua chamando senhas, em paz, até o `SIGKILL` dez segundos depois. `137 = 128 + 9`, o código de saída de quem morreu por `SIGKILL`; `143 = 128 + 15` seria o de quem morreu por `SIGTERM`. Como `OOMKilled` estava `false`, a Jéssica pôde descartar a memória: o processo morreu de prazo, sem chance de terminar a frase `chamando senha 4`.

A correção é instalar o handler e terminar o trabalho em andamento:

```python
import signal

parar = False

def ao_receber_sigterm(signum, frame):
    global parar
    parar = True
    print("SIGTERM recebido; terminando a senha atual", flush=True)

signal.signal(signal.SIGTERM, ao_receber_sigterm)

while not parar:
    chamar_proxima_senha()   # bloqueia no Redis por até 1 s
print("fila fechada, bom café a todos", flush=True)
```

```bash
$ time docker stop fila
fila

real    0m1.388s
$ docker inspect fila --format '{{.State.ExitCode}} {{.State.OOMKilled}}'
0 false
```

De 10,2 s para 1,4 s, com saída limpa. Uvicorn e Gunicorn já instalam handler para `SIGTERM` e fazem *graceful shutdown*: param de aceitar conexões, terminam as requisições em andamento e saem.

O handler só adianta se o sinal chegar. A forma shell, `CMD python worker.py`, vira `/bin/sh -c "python worker.py"`, e a documentação do Docker avisa que aí o executável deixa de ser o PID 1 e não recebe sinais; o shell absorve o `SIGTERM` sem repassar. A forma exec, `CMD ["python", "worker.py"]`, inicia o Python como PID 1. Um `entrypoint.sh` que aplica migrações antes de chamar a aplicação precisa terminar com `exec python -m src.worker`, que substitui o shell pelo Python no mesmo PID.

O PID 1 também adota órfãos: os filhos de um processo que morre passam para o init, que precisa chamar `wait()` para recolhê-los. Sem isso, cada filho encerrado vira *zumbi*, sem CPU nem memória, mas ocupando um PID. Uma aplicação que dispara um navegador headless por etiqueta acumula zumbis até o `pids.max`, e então o `fork()` falha com `EAGAIN`, numa terça-feira, no meio do expediente. O tini (que o `docker run --init` injeta) repassa sinais e recolhe zumbis; no Kubernetes ele entra na imagem com `ENTRYPOINT ["tini", "--"]`.

## Registries, tags e digests

Um *registry* guarda e serve imagens por HTTP, seguindo a OCI Distribution Spec. A API é pequena: `GET /v2/<nome>/manifests/<referência>` devolve um manifesto, `GET /v2/<nome>/blobs/<digest>` devolve uma camada ou a configuração, e o push faz upload dos blobs antes do manifesto que os referencia.

Tudo é endereçado por conteúdo. O **digest** é o SHA-256 dos bytes do objeto. O manifesto da imagem lista o digest da configuração e o de cada camada; o *image index* lista um manifesto por plataforma, para imagens multiarquitetura:

```bash
$ curl -s -H "Authorization: Bearer $REGISTRY_TOKEN" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    https://registry.exemplo.com/v2/padaria/fila-do-pao/manifests/1.5.0
```

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:4f1e9c27b0a8d3e6f5c2b19a7d8e0f3c6b5a4d2e1f0c9b8a7d6e5f4c3b2a1d0e",
      "size": 1612,
      "platform": { "architecture": "amd64", "os": "linux" }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:a7c3e5f1d9b2c4e6f8a0b1c3d5e7f9a2b4c6d8e0f1a3b5c7d9e2f4a6b8c0d1e3",
      "size": 1612,
      "platform": { "architecture": "arm64", "os": "linux" }
    }
  ]
}
```

O cliente escolhe o manifesto da própria arquitetura e baixa só os blobs cujo digest ainda não tem no disco. Imagens com a mesma base compartilham essas camadas.

A **tag** é um ponteiro mutável para um manifesto. `latest` é só o nome usado quando ninguém informa outro, sem significado de "mais recente" ou "estável". Um push novo move o ponteiro, e quem já baixou fica com a versão velha. Foi a loja 3: o servidor tinha `latest-final` em cache e a política de pull era "só se não existir localmente". Catorze lojas, a mesma tag, duas versões, e um diagnóstico que virou exercício de fé.

Referenciar pelo digest (`padaria/fila-do-pao@sha256:4f1e…`) garante os mesmos bytes em todo lugar. Tags de versão (`1.5.0`) ajudam a ler, mas continuam mutáveis; o capítulo 37 trata de artefatos imutáveis.

## OCI, ou quem faz o quê

A Open Container Initiative, criada em 2015 sob a Linux Foundation, padronizou o que antes era formato interno do Docker em três especificações: a **runtime spec** (um *bundle* com diretório raiz e um `config.json` com namespaces, cgroups, montagens e comando), a **image spec** (manifesto, índice, configuração, camadas) e a **distribution spec** (a API do registry). Uma imagem construída com Docker, Buildah ou Kaniko sobe em containerd, CRI-O ou Podman.

```text
docker CLI ──► dockerd ──► containerd ──► containerd-shim ──► runc ──► seu processo
kubelet ──(CRI)──► containerd ou CRI-O ──────────────────────► runc ──► seu processo
```

O `runc` cria os namespaces, escreve os cgroups, monta a raiz, faz `execve` na aplicação e sai, sem esperar agradecimento. Quem fica de babá é o *shim*, que segura o stdio e recolhe o código de saída. O Kubernetes removeu o dockershim na versão 1.24 (2022), e as imagens continuaram funcionando porque eram OCI desde o início.

## Armadilhas e casos reais

> **Armadilha:** a porta publicada que passa por cima do firewall. O Docker insere as próprias regras de NAT no iptables, antes das cadeias que o ufw gerencia, e a documentação oficial avisa que portas publicadas ignoram as regras do ufw. Um `-p 6379:6379` num servidor com "firewall ativo" expõe o Redis para a internet, e o `ufw status` continua jurando que está tudo fechado. `-p 127.0.0.1:6379:6379` restringe à interface local.

> **Armadilha:** `exec format error`. A imagem construída num notebook ARM sem `--platform` sobe só como `arm64`; o servidor `amd64` tenta executar o binário e o kernel recusa o formato, com a mensagem mais curta e menos útil do capítulo. O image index com as duas plataformas, gerado por `docker buildx build --platform linux/amd64,linux/arm64`, resolve.

> **Na vida real:** CVE-2019-5736, de fevereiro de 2019. Um contêiner malicioso sobrescrevia o binário `runc` do host via `/proc/self/exe` quando alguém fazia `docker exec` nele, e a execução seguinte do `runc` entregava root no host ao atacante. O isolamento vale o que vale o código que o monta.

> **Na vida real:** CVE-2024-21626 ("Leaky Vessels"), corrigida no runc 1.1.12 em janeiro de 2024. Um descritor de arquivo do host vazava para o contêiner, e um `WORKDIR /proc/self/fd/<n>` numa imagem maliciosa punha o diretório atual no sistema de arquivos do host. Para imagem não confiável, o isolamento pede camadas extras (user namespace, gVisor, Kata Containers, microVMs).
## Resumo

- Contêiner = processo comum + namespaces + cgroups + raiz própria + capabilities e seccomp, com kernel compartilhado.
- `memory.max` estourado → OOM killer no grupo → `SIGKILL`, código 137, sem log.
- `cpu.max` soma todas as threads por janela de 100 ms; o throttling aparece em `cpu.stat` e na latência.
- Imagem = camadas `tar` + JSON; apagar numa camada posterior não remove nada.
- Ordem do Dockerfile decide o cache; múltiplos estágios deixam o compilador fora da imagem final.
- `slim`, Alpine e distroless trocam tamanho e superfície de ataque por compatibilidade e depuração.
- PID 1 só recebe sinais com handler: forma exec, `exec` no script, handler de `SIGTERM`, tini para zumbis.
- Tag é ponteiro mutável; digest garante os mesmos bytes.
- OCI padroniza runtime, imagem e distribuição; `runc` monta e sai, o shim acompanha.

## Referências

- Open Container Initiative, Runtime Specification: https://github.com/opencontainers/runtime-spec
- Open Container Initiative, Image Format Specification: https://github.com/opencontainers/image-spec
- Open Container Initiative, Distribution Specification: https://github.com/opencontainers/distribution-spec
- Linux man-pages, `namespaces(7)`: https://man7.org/linux/man-pages/man7/namespaces.7.html
- Linux man-pages, `pid_namespaces(7)` (sinais e o processo init): https://man7.org/linux/man-pages/man7/pid_namespaces.7.html
- Linux man-pages, `cgroups(7)`: https://man7.org/linux/man-pages/man7/cgroups.7.html
- Documentação do kernel Linux, Control Group v2: https://docs.kernel.org/admin-guide/cgroup-v2.html
- Documentação do kernel Linux, Overlay Filesystem: https://docs.kernel.org/filesystems/overlayfs.html
- Docker, Multi-stage builds: https://docs.docker.com/build/building/multi-stage/
- Docker, `docker container stop`: https://docs.docker.com/reference/cli/docker/container/stop/
- Docker, Dockerfile reference (formas shell e exec): https://docs.docker.com/reference/dockerfile/
- Docker, Seccomp security profiles: https://docs.docker.com/engine/security/seccomp/
- Docker, Packet filtering and firewalls (ufw): https://docs.docker.com/engine/network/packet-filtering-firewalls/
- tini: https://github.com/krallin/tini
- PEP 656, Platform Tag for Linux Distributions Using Musl: https://peps.python.org/pep-0656/
- Kubernetes, Dockershim removal FAQ: https://kubernetes.io/blog/2022/02/17/dockershim-faq/
- NVD, CVE-2019-5736: https://nvd.nist.gov/vuln/detail/CVE-2019-5736
- NVD, CVE-2024-21626: https://nvd.nist.gov/vuln/detail/CVE-2024-21626
