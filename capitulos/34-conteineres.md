# Contêineres

O primeiro contêiner da Lastro durou onze minutos em produção e matou 31 autorizações, o que dá uma autorização a cada 21 segundos, ritmo de serial killer com metas trimestrais.

O Carlos empacotou o `conector-adquirente` para as máquinas do segmento de cartão (capítulo 33) com `CMD ./iniciar.sh`, um script que fazia `carregar_segredos && python -m conector`. No primeiro deploy, o `docker stop` mandou `SIGTERM`, esperou os dez segundos padrão sem reação e mandou `SIGKILL`. As 31 autorizações em voo ficaram em `processando` e a resolução do capítulo 15 fechou uma a uma com o adquirente. Nenhum centavo se perdeu; 31 compradores encararam um "aguarde" de quatro minutos, e o Bazar abriu chamado com o assunto "URGENTE!!!! CONTÊINER????".

Na mesma tarde, o contêiner do painel começou a perder processos sem traceback, sem `ERROR`, sem nada. O gateway devolvia `502` e o log do Python terminava no meio de uma frase sobre login, como diário de vítima em filme de terror.

O que é um contêiner, para um sinal sumir no caminho e um processo morrer calado?

## Um contêiner é um processo com antolhos

Contêiner não existe no kernel do Linux; não há chamada de sistema `create_container`. Existe um processo comum, criado por `clone` (capítulo 13), com duas coisas configuradas: **namespaces**, que limitam o que ele enxerga, e **cgroups**, que limitam o que ele consome. O resto (imagem, registry, `docker run`) é tooling em volta desse processo.

Cada namespace isola um recurso global do kernel:

| Namespace | O processo dentro dele vê |
|---|---|
| `pid` | a própria árvore de processos, começando no PID 1 |
| `mnt` | a própria árvore de montagens, com a imagem como raiz |
| `net` | as próprias interfaces, rotas, portas e regras de firewall |
| `uts` | o próprio hostname |
| `ipc` | a própria memória compartilhada System V e filas POSIX |
| `user` | um mapeamento de UIDs: root dentro, usuário comum fora |
| `cgroup` | a própria raiz da hierarquia de cgroups |
| `time` | deslocamentos próprios dos relógios monotônico e de boot |

O mesmo processo tem dois PIDs. Dentro do contêiner do Carlos:

```text
$ docker exec conector ps -o pid,cmd
  PID CMD
    1 /bin/sh ./iniciar.sh
    9 python -m conector
```

No host, o mesmo Python é o PID 48213. Ele acha que é o segundo processo do universo. É o 48.213º, e o host sabe.

A consequência que mais importa: **os contêineres de uma máquina compartilham o mesmo kernel**, sem sistema operacional convidado como numa máquina virtual. Por isso o contêiner sobe em milissegundos e custa quase só o processo; e por isso um bug no kernel ou no runtime é fuga para o host. A defesa é reduzir o que o processo pode pedir ao kernel: usuário não root, *capabilities* removidas, seccomp e raiz somente leitura.

## cgroups, ou o kernel cobrando a conta no ato

Os **cgroups** (na versão 2, a hierarquia única em `/sys/fs/cgroup`) aplicam limites e contabilidade a grupos de processos. O contêiner é um cgroup, e os arquivos que importam são poucos e brutais.

**Memória.** `memory.max` é o teto rígido. Quando o grupo passa dele e o kernel não consegue recuperar páginas (o cache de arquivos conta, mas é recuperável; o heap do Python, sem swap, fica), o OOM killer age dentro do grupo: escolhe o processo de maior pontuação, em geral o de maior RSS, e manda `SIGKILL`. `SIGKILL` não pode ser capturado, então não existe `except`, `finally` ou `atexit` que rode. O processo não tem últimas palavras. O kernel registra o óbito por ele:

```text
Memory cgroup out of memory: Killed process 51877 (python) total-vm:1489240kB,
anon-rss:498112kB, file-rss:10240kB, shmem-rss:0kB, UID:10001 oom_score_adj:0
```

E o contador `oom_kill` em `memory.events` do cgroup sobe um. Se o processo morto era o PID 1, o contêiner inteiro termina com código 137, que é 128 + 9, o número do `SIGKILL`. Esse é o "sem log" do painel: a única testemunha do assassinato é o próprio assassino, e ele escreve no log do kernel, que ninguém da aplicação lê.

**CPU.** `cpu.max` define cota e período: `200000 100000` dá 200 ms de CPU a cada 100 ms, o equivalente a 2 núcleos. A cota é por período e somada entre todas as threads. Um processo com 8 threads ativas gasta os 200 ms em 25 ms de relógio e fica **congelado** os 75 ms restantes do período (*throttling*), com fila de requisições crescendo e o p99 subindo. O `cpu.stat` mostra `nr_throttled` e `throttled_usec`, e quase ninguém olha. Já `cpu.weight` só define proporção quando há disputa: com a máquina ociosa, o grupo usa o que quiser.

A pegadinha mais cara: o processo dentro do contêiner não sabe dos próprios limites a menos que leia o cgroup. `os.cpu_count()` devolve os núcleos do host. Uma configuração que calcula workers como `2 × núcleos + 1` num host de 64 núcleos, com limite de 2 CPUs, sobe 129 workers que dividem 2 núcleos. O Carlos tinha chegado a 64 workers por puro instinto no capítulo 13; o contêiner chegaria a 129 por aritmética.

## Imagens e camadas, ou o sistema de arquivos que nunca esquece

Uma imagem segue a **OCI Image Specification**: um *manifest* em JSON que aponta para uma configuração (comando, variáveis, usuário) e para uma lista ordenada de **camadas**, cada uma um tar com as diferenças do sistema de arquivos. Cada peça é identificada pelo SHA-256 dos próprios bytes, e camada base repetida entre imagens é guardada e baixada uma vez.

Na execução, um sistema de arquivos de união (overlayfs) empilha as camadas como diretórios somente leitura e põe por cima uma camada gravável do contêiner. Alterar um arquivo de baixo copia o arquivo inteiro para cima (*copy-up*). Apagar um arquivo cria um *whiteout*, um marcador que o esconde. O arquivo continua inteiro na camada de baixo.

Cada instrução `RUN`, `COPY` e `ADD` do Dockerfile gera uma camada. Daí a armadilha que fecha com o capítulo 33:

```dockerfile
COPY .env requirements.txt /app/
RUN . /app/.env && pip install --index-url "$INDICE_PRIVADO" -r /app/requirements.txt \
    && rm /app/.env                               # "apaguei, tá seguro"
```

O `rm` criou um whiteout numa camada nova. O `.env`, com a credencial do índice privado do capítulo 32, segue inteiro na camada do `COPY`, que viaja para todo registry e toda máquina que baixar a imagem. Segredo em imagem é segredo publicado com controle de versão.

O cache de build segue a mesma lógica: mudou a instrução ou os arquivos que ela copia, a camada e todas as seguintes são refeitas. Instalar dependências antes de copiar o código faz a mudança de uma linha refazer só a última camada.

## Build em múltiplos estágios, ou a obra sem o entulho

A imagem que constrói precisa de compilador, cabeçalhos e ferramentas; a que roda precisa de Python, das dependências instaladas e do código. O **build em múltiplos estágios** usa vários `FROM` num Dockerfile e copia para a imagem final só o resultado:

```dockerfile
FROM python:3.12-slim AS build
RUN python -m venv /venv
COPY requirements.txt .
RUN /venv/bin/pip install --require-hashes -r requirements.txt

FROM python:3.12-slim
COPY --from=build /venv /venv
COPY app/ /app/
USER 10001
ENTRYPOINT ["/venv/bin/python", "-m", "app"]
```

O estágio `build` é descartado. O compilador e o cache do pip não vão para produção, e o `--require-hashes` é o lock com hashes do capítulo 32.

A escolha da base define tamanho e superfície:

| Base | Tamanho aproximado | Shell e gerenciador de pacotes | Custo |
|---|---|---|---|
| `python:3.12` (Debian completo) | perto de 1 GB | sim | centenas de pacotes que o scanner de CVE vai listar |
| `python:3.12-slim` | pouco mais de 100 MB | sim | pacotes compilados precisam do estágio de build |
| Alpine | dezenas de MB | sim | musl em vez de glibc: wheels diferentes e diferenças de comportamento |
| distroless | dezenas de MB | não | sem shell para depurar dentro do contêiner |

Menos pacotes é menos CVE para triar e menos ferramenta para quem invadir: sem shell, o atacante com execução de código não tem `sh`, `curl` nem `apt` e precisa trazer tudo de casa. Você também, às 3h da manhã: depurar distroless exige anexar um contêiner de depuração ao lado.

## PID 1, ou o processo que o kernel não deixa morrer de susto

O PID 1 de um namespace tem duas regras próprias no kernel.

A primeira: **sinal sem tratador instalado é ignorado**. Num processo comum, `SIGTERM` sem tratador mata pela ação padrão. No PID 1, o kernel descarta o sinal, para proteger o init do sistema de morrer por acidente. Só `SIGKILL` e `SIGSTOP` vindos de fora do namespace passam.

A segunda: o PID 1 adota todo órfão do namespace e precisa colher os filhos que morrem com `wait`. Quem não colhe acumula zumbis na tabela de processos (capítulo 13), mortos que ninguém enterrou porque o pai não leu o atestado de óbito.

Agora o Dockerfile do Carlos. `CMD ./iniciar.sh` está na *forma shell*, que o Docker executa por `/bin/sh -c`, e o PID 1 acabou sendo um shell. O script tinha `&&`, então o shell precisava continuar vivo para rodar o segundo comando, e o Python virou filho. O `docker stop` mandou `SIGTERM` ao PID 1. O `sh` não tinha tratador, o kernel jogou o sinal fora, o Python nunca soube de nada, e dez segundos depois veio o `SIGKILL` para todos. O Python morreu no meio de 31 autorizações sem ter sido avisado. O shell morreu como viveu: sem fazer nada.

```text
docker stop        SIGTERM ──► PID 1 (sh, sem tratador) ──► descartado
  10 s depois      SIGKILL ──► todo o namespace       ──► 31 autorizações em voo
```

As correções são três, combináveis. A **forma exec** (`ENTRYPOINT ["/venv/bin/python", "-m", "app"]`) não passa por shell, e o Python é o PID 1. Script de entrada que termina com `exec python ...` substitui o shell pelo Python no mesmo PID. E um init mínimo como PID 1 (o `tini`, ou `docker run --init`, que usa o mesmo princípio) repassa os sinais ao filho e colhe zumbis.

Receber o sinal é metade do trabalho. O processo precisa saber morrer. O **encerramento gracioso** é uma sequência:

1. Ao receber `SIGTERM`, sair do balanceamento: o endpoint de prontidão passa a falhar e o proxy para de mandar requisições novas.
2. Parar de aceitar conexões e terminar as requisições em voo, dentro de um prazo.
3. Fechar o que é externo: pools de banco, conexões HTTP/2 (com `GOAWAY`, capítulo 9), consumidores do broker (devolvendo partições, capítulo 17).
4. Sair antes do `SIGKILL`.

O prazo de parada precisa ser maior que a soma. Fora do PID 1, um Python sem tratador de `SIGTERM` morre na hora, sem `finally`; o Uvicorn instala tratadores e faz o passo 2, com `--timeout-graceful-shutdown` como limite.

## Registries e a tríade OCI

A OCI padroniza três peças: a **Image Spec** (o formato acima), a **Distribution Spec** (a API HTTP de um registry, que guarda blobs e manifests por digest) e a **Runtime Spec** (como um runtime, o `runc` por exemplo, cria o processo com namespaces e cgroups a partir de um `config.json`). Ferramentas que falam OCI trocam imagens entre si.

No registry, a **tag** (`pagamentos:v42`) é um ponteiro mutável, que alguém pode reapontar amanhã. O **digest** (`pagamentos@sha256:9f1c...`) é o hash do manifest e só significa uma imagem. Deploy por tag roda o que a etiqueta apontar na hora do pull; por digest, roda exatamente o que foi testado. E `latest` é só uma tag com nome otimista, igual ao `repasse_final_v2_agora_vai.py`.

## Na Lastro: imagens, sinais e limites

A Lastro já tinha artefato imutável: a imagem de máquina do autoscaling (capítulo 29). O contêiner custa mais uma camada de software por máquina e se paga por três requisitos: o tempo de reação do autoscaling (4 min 20 s, 2 min deles montando a máquina), limite de memória por serviço e o mínimo de software no segmento de cartão. Com um serviço por máquina e sem segmento, a imagem de máquina bastaria.

As decisões:

| Item | Decisão | Por quê |
|---|---|---|
| Processos por contêiner | 1 processo Uvicorn | escala por contêiner; os números do capítulo 29 já contavam processos |
| PID 1 | `tini` + Python em forma exec | sinal chega, zumbi é colhido |
| Base | `python:3.12-slim`, multiestágio; cofre e conector em distroless | cofre e conector ficam sem shell no segmento |
| Usuário | UID 10001, raiz somente leitura, sem capabilities | execução de código não vira root |
| Identificação | deploy por digest; tag `serviço:data-commit` só para humanos | o que foi testado é o que roda |
| Segredos | lidos do gerenciador pelo próprio Python na partida (capítulo 33) | nada em camada, nada em variável de ambiente |
| Tamanho | pagamentos de 1,2 GB para 160 MB | pull na máquina nova de 38 s para 6 s |

No encerramento de pagamentos e do conector, o `/pronto` do capítulo 27 falha no `SIGTERM` e o proxy local tira o processo após 2 checagens de 2 s; as requisições em voo têm o deadline de 8 s (capítulo 15); o SSE fecha com `retry` (capítulo 29). Total: até 15 s, a drenagem que o autoscaling já reservava. O prazo de parada é **20 s**, e um contador de "processos encerrados por `SIGKILL`" alarma acima de zero. Os consumidores do broker (ledger, entregador) param de buscar, terminam o lote, confirmam offsets e saem.

Os limites saíram de medição, e não de chute:

| Serviço | Pico de RSS medido | `memory.max` | `cpu.max` |
|---|---|---|---|
| pagamentos | 180 MiB | 320 MiB | 2 núcleos |
| conector-adquirente | 140 MiB | 256 MiB | 2 núcleos |
| painel (login com Argon2id) | 160 MiB + 4 × 64 MiB | 640 MiB | 2 núcleos |
| relatórios | 1,4 GiB | 2 GiB | 2 núcleos |

O painel morria porque o Carlos tinha empacotado os três workers num contêiner de 512 MiB: 3 × (160 + 4 × 64) MiB, perto de 1,2 GiB no pior caso, e o OOM killer resolvia pela maior conta. Com um processo por contêiner e o semáforo de 4 do capítulo 33, o pior caso é 416 MiB, e o limite tem folga de 50%. O relatório de risco do capítulo 26, que derrubou a autorização com 7 GB de DataFrame, agora morre sozinho dentro dos 2 GiB dele, em vez de levar a máquina junto. É o mesmo crime com a cena isolada.

A cota de 2 núcleos para um processo com GIL parece generosa. Ela existe para as threads em C (o gRPC do antifraude, o `to_thread` do capítulo 13) não serem congeladas por *throttling* no meio de uma autorização; `nr_throttled` acima de zero vira alerta. Nenhum serviço calcula workers por `os.cpu_count()`: o número é fixo e igual a um.

E a morte silenciosa ganhou testemunha: o agente de cada máquina lê `memory.events` dos cgroups e o código de saída dos contêineres, e 137 com `oom_kill` incrementado vira evento com nome do serviço e pico de memória. O `temp-01` não roda contêiner: o kernel dele é anterior à hierarquia única de cgroups v2 e ninguém aceita reiniciá-lo para descobrir se volta.

## Armadilhas e casos reais

> **Na vida real:** a JVM, antes do JDK 10 (e do 8u191, que recebeu o recurso por *backport*), não lia os limites do cgroup e dimensionava o heap pela memória do host. Um contêiner com limite de 1 GB numa máquina de 64 GB ganhava heap padrão de 16 GB e era morto pelo OOM killer muito antes de o garbage collector achar que estava na hora de limpar alguma coisa. A consultoria Java do Bazar descobriu isso em produção e cobrou o aprendizado em horas.

> **Na vida real:** a CVE-2019-5736, de fevereiro de 2019, permitia a um contêiner malicioso sobrescrever o binário `runc` do host e ganhar root na máquina na próxima execução. O ataque exigia root dentro do contêiner: quem rodava com usuário comum assistiu de camarote.

> **Armadilha:** cache em memória sem `maxsize` cresce até o `memory.max`, e o OOM killer escolhe o maior culpado, que é ele. O `lru_cache` do capítulo 22 tinha 128 entradas, e foi a única coisa naquele PR que estava certa.

> **Armadilha:** `print` em contêiner. Sem terminal, o `stdout` do Python é bufferizado em blocos, e o processo morto por `SIGKILL` leva o buffer junto. O módulo `logging` faz *flush* a cada registro; `PYTHONUNBUFFERED=1` cobre o resto.

## Resumo

- Contêiner é um processo com namespaces (o que vê) e cgroups (o que consome), sobre o kernel do host.
- `memory.max` estourado: OOM killer, `SIGKILL`, código 137, registro só no kernel e em `memory.events`.
- `cpu.max` é cota por período somada entre threads; excesso vira *throttling*, e o processo não conhece os limites sem ler o cgroup.
- Imagem OCI: camadas endereçadas por SHA-256; apagar depois não remove o arquivo.
- Múltiplos estágios e bases mínimas reduzem tamanho e superfície.
- PID 1 ignora sinais sem tratador e colhe órfãos: forma exec ou init mínimo.
- Encerramento gracioso: sair do balanceamento, drenar, fechar conexões, sair antes do `SIGKILL`.
- Tag é ponteiro mutável; digest identifica a imagem.

## A Lastro agora

Cada serviço virou uma imagem multiestágio, com um processo Uvicorn atrás do `tini`, usuário sem privilégio, segredos lidos na partida e deploy por digest. O prazo de parada é 20 s contra 15 s de drenagem, os limites de memória vêm de pico medido mais folga, e um `SIGKILL` ou um OOM agora deixam nome, sobrenome e pico de memória no alerta. Pagamentos caiu de 1,2 GB para 160 MB, e o fundador perguntou para onde foi o resto. Foi o `.git`, os testes, o compilador e uma pasta `backup_antigo/` com 400 MB de CSV do financeiro.

Agora são 14 imagens e uns 90 contêineres espalhados pelas máquinas, iniciados por scripts de deploy em bash. Para não depender de ninguém acordado, o Carlos escreveu um laço que reinicia todo contêiner cujo `/saude` não responde em 1 s e chamou de orquestrador. Na primeira sexta de campanha, sob carga, o lag do event loop passou de 1 s, o laço reiniciou um contêiner saudável, a carga dele foi para os vizinhos, que também passaram de 1 s, e o orquestrador do Carlos derrubou, com eficiência exemplar, todos os processos de pagamentos que estavam funcionando.

## Referências

- Linux man-pages, `namespaces(7)`: https://man7.org/linux/man-pages/man7/namespaces.7.html
- Linux man-pages, `pid_namespaces(7)` (PID 1 e sinais): https://man7.org/linux/man-pages/man7/pid_namespaces.7.html
- Documentação do kernel Linux, *Control Group v2*: https://docs.kernel.org/admin-guide/cgroup-v2.html
- Open Container Initiative, especificações de imagem, distribuição e runtime: https://opencontainers.org/
- Docker, *Multi-stage builds*: https://docs.docker.com/build/building/multi-stage/
- Docker, referência do Dockerfile (formas shell e exec): https://docs.docker.com/reference/dockerfile/
- Docker, `docker container stop`: https://docs.docker.com/reference/cli/docker/container/stop/
- tini: https://github.com/krallin/tini
- Uvicorn, configurações (`--timeout-graceful-shutdown`): https://www.uvicorn.org/settings/
- CVE-2019-5736 (runc): https://nvd.nist.gov/vuln/detail/CVE-2019-5736
- JDK-8146115, suporte a contêineres na JVM: https://bugs.openjdk.org/browse/JDK-8146115
