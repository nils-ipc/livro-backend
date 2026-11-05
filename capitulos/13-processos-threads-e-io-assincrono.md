# Processos, threads e I/O assíncrono

## A CPU a 4% e ninguém atendendo

Às 20h03 de uma quinta-feira, a Lastro teve o incidente mais relaxado da sua história: as duas máquinas com a CPU a 4%, memória sobrando, rede bocejando, e nenhuma requisição sendo atendida. Um servidor parado por excesso de trabalho você entende. Um servidor parado por excesso de descanso precisa de terapia.

O Bazar tinha lançado às 20h a campanha "12x sem juros em tudo, até em capinha", e as autorizações de cartão saíram de 1 para 7 por segundo. Cada uma chama a Vigia (uns 60 ms) e o adquirente (uns 800 ms) com clientes síncronos, dentro de um `async def`, porque o Carlos achou que "é só uma chamada". Era. Uma chamada que segura o processo inteiro por 0,9 segundo.

Seis processos (3 em `temp-01`, 3 em `api-01`), cada um fazendo uma coisa por vez durante 0,9 segundo, dão um teto de 6 / 0,9 ≈ 6,7 autorizações por segundo. Chegavam 7. O `POST /v1/cobrancas` foi de 0,9 para 14 segundos, o Bazar desistia aos 10 (o destino da cobrança abandonada é assunto do capítulo 15), e os checkouts com SSE pararam de receber o `: ping`, até o proxy cortar todos aos 60 segundos. O Pix, que nem passa pelo adquirente, morreu junto, por solidariedade.

O URGENTE!!!! chegou às 20h11. O Carlos propôs `--workers 64`. O fundador lembrou que no tempo dele era um processo e funcionava.

Por que seis processos com a CPU a 4% não dão conta de sete pedidos por segundo, e como dimensionar um servidor cujo trabalho é 99% esperar?

## Processo e thread, ou a árvore genealógica mais mórbida da computação

Um **processo** é um espaço de endereçamento virtual próprio, uma tabela de descritores de arquivo (sockets inclusos) e pelo menos uma thread. Uma **thread** é um fluxo de execução (registradores, pilha) que compartilha memória e descritores com as outras do processo.

No Linux, os dois são *tasks* criadas por `clone()`: com `CLONE_VM` e companhia, a task nova divide memória com a mãe e vira thread; sem, vira processo. O `fork()` cria o filho com *copy-on-write*: as páginas ficam compartilhadas até alguém escrever nelas. Fork de um processo de 2 GB custa milissegundos. Até a primeira escrita.

E aí começa a novela. O filho que termina vira **zumbi**: fica na tabela de processos até o pai chamar `wait()` e ler o código de saída. Pai que não lê atestado de óbito acumula zumbis. O filho cujo pai morre primeiro vira **órfão** e é adotado pelo PID 1, que passa o dia recolhendo cadáver alheio. Sistemas operacionais foram batizados por alguém que precisava conversar com um profissional.

A pilha de uma thread reserva 8 MB de endereço virtual (o padrão de `ulimit -s` na maioria das distribuições), mas só ocupa RAM a página tocada: uma thread ociosa custa dezenas de KB. Um processo Python com FastAPI, SQLAlchemy e gRPC carregados ocupa de 100 a 200 MB de RSS; na Lastro, 160 MB por worker. Thread é barata. Processo Python tem pensão alimentícia.

## A troca de contexto, ou o kernel que vive de interromper

O *scheduler* do kernel (o EEVDF, desde o Linux 6.6) decide qual task roda em cada núcleo. Uma task está **executável** ou **dormindo**, à espera de um evento: dado no socket, timer, lock.

Uma **troca de contexto** salva os registradores de uma task e carrega os da outra: voluntária quando a task bloqueia numa chamada de sistema, involuntária quando a fatia de tempo acaba. Entre processos, troca também a tabela de páginas. O custo direto é de microssegundos; o indireto, cache e TLB frios, não aparece em gráfico nenhum, como todo custo indireto da sua vida.

O kernel conta as duas por task:

```text
$ grep ctxt /proc/$(pgrep -of "uvicorn.*worker")/status
voluntary_ctxt_switches:     1843021
nonvoluntary_ctxt_switches:  312
```

Essa saída, de um worker de `temp-01` às 20h05, é a assinatura do incidente: quase dois milhões de saídas voluntárias (dorme esperando rede) e 312 expulsões (ninguém disputa CPU com ele). Passa o dia dormindo e nunca é interrompido. Chegou ao estilo de vida do fundador.

## I/O bloqueante e não bloqueante, ou a arte de não esperar sentado

Um `recv()` num socket sem dado, no modo padrão, **bloqueia**: o kernel põe a thread para dormir na fila de espera do socket e a acorda quando os bytes chegarem. Simples de programar, caro de escalar: cada conexão em espera prende uma thread. O worker do Carlos tinha uma thread só, e ela estava esperando o adquirente.

Com `O_NONBLOCK`, o mesmo `recv()` retorna na hora com `EAGAIN`. A thread não dorme, e também não sabe quando tentar de novo. Tentar em laço é *busy waiting*: a CPU a 100% perguntando "chegou?" milhões de vezes por segundo, o equivalente computacional da criança no banco de trás. Falta o kernel avisar quando um descritor fica pronto, a **notificação de prontidão**:

| Mecanismo | Como registra os descritores | Custo por chamada | Limite |
|-----------|------------------------------|-------------------|--------|
| `select` | bitmask copiado a cada chamada | O(n) descritores vigiados | `FD_SETSIZE`, 1.024 |
| `poll` | vetor copiado a cada chamada | O(n) descritores vigiados | nenhum fixo |
| `epoll` | lista de interesse no kernel, registrada uma vez | O(k) descritores prontos | memória |

No `epoll`, `epoll_ctl()` registra o descritor uma vez e `epoll_wait()` dorme até algum ficar pronto, devolvendo só os prontos. Com 10.000 conexões e 12 com dado, o `select` varre 10.000 bits e o `epoll` devolve 12 entradas. No modo padrão, **level-triggered**, cada `epoll_wait` avisa de novo enquanto houver dado no buffer; no **edge-triggered** (`EPOLLET`), o aviso vem só na transição, e quem leu metade e foi embora nunca mais é avisado. É o modo para quem gosta de emoção.

O `kqueue` (BSD, macOS) também é de prontidão. O IOCP do Windows e o `io_uring` do Linux (desde o 5.1) são de **conclusão**: o kernel faz a leitura e avisa que terminou. Arquivo comum fica fora da festa: o `epoll_ctl` recusa arquivo regular com `EPERM`, porque disco, para o kernel, está sempre pronto. Por isso o `asyncio` lê arquivo e resolve DNS (`getaddrinfo`, bloqueante) num pool de threads, escondido nos fundos.

Em 1999, o texto "The C10K problem", de Dan Kegel, perguntou como atender 10 mil conexões numa máquina. A resposta foi essa tabela, e o nginx, o Node.js e o `asyncio` descendem dela.

## O event loop, ou uma thread que não pode piscar

Um **event loop** é um laço em volta do `epoll_wait`: calcula quanto falta para o próximo timer, dorme no `epoll_wait` até esse prazo, executa os callbacks dos descritores prontos e dos agendados, e recomeça. Uma thread, milhares de conexões.

No `asyncio`, cada requisição é uma **corrotina** dentro de uma **Task**; no `await` num socket sem dado, a Task devolve o controle ao loop, que registra o descritor no `epoll` e atende outra. A multitarefa é **cooperativa**: a troca só acontece num `await` de algo pendente. Código que não faz `await` nunca solta o loop, e o resto do processo espera, como numa reunião em que alguém compartilhou a tela e saiu para almoçar.

```python
import asyncio, time

async def bloqueia():
    time.sleep(0.8)           # a thread dorme; o loop dorme junto

async def coopera():
    await asyncio.sleep(0.8)  # a corrotina dorme; o loop segue atendendo

# asyncio.gather com 100 de cada:
# bloqueia: 80,1 s     coopera: 0,8 s
```

Cem chamadas que bloqueiam viram 80 segundos em série; cem que cooperam terminam juntas em 0,8. O `requests.post` e o stub síncrono do gRPC são `time.sleep` com currículo. Às 20h03, eram sete por segundo, cada uma dormindo 0,9 segundo com o loop no colo.

O modo debug do `asyncio` denuncia o crime: callback acima de `loop.slow_callback_duration` (100 ms por padrão) gera aviso.

```text
WARNING:asyncio:Executing <Task pending name='Task-48213'
  coro=<RequestResponseCycle.run_asgi() running at ...>
  wait_for=<Future pending ...>> took 0.913 seconds
```

Novecentos e treze milissegundos sem atender ninguém: nove vezes o limite de vergonha que o próprio Python configurou.

Código bloqueante inevitável vai por `asyncio.to_thread()` (3.9+) ou `loop.run_in_executor()`: a chamada roda numa thread do pool e a corrotina faz `await` no resultado. A thread fica presa, o loop fica livre.

## O GIL, ou o cadeado que o Python pôs no próprio pé

Se thread resolve espera, por que não usar threads em tudo e esquecer o `asyncio`? Por causa do **GIL**, o Global Interpreter Lock do CPython: um mutex que só deixa uma thread por interpretador executar bytecode Python por vez.

O GIL é liberado em toda chamada de sistema bloqueante (`recv`, `sleep`) e por extensões em C que trabalham sem tocar em objetos Python (o `hashlib` com entradas grandes, o NumPy). Uma thread que só executa Python é convidada a soltá-lo a cada 5 ms (`sys.getswitchinterval()`). Threads Python dão concorrência para I/O, porque quem espera rede solta o GIL, e nenhum paralelismo para CPU: quatro threads calculando em 4 núcleos levam o mesmo tempo que uma thread fazendo as quatro contas, mais a briga pelo lock. Paralelismo de CPU, com GIL, vem de processos. E o `+=` do capítulo 2 continua sem atomicidade: o GIL protege o interpretador. Você ele deixa morrer.

O build sem GIL (*free-threaded*, PEP 703) é suportado desde o 3.14 (PEP 779), ainda opcional. A Lastro roda o padrão, com GIL.

## Modelos de servidor, ou quantas requisições cabem num processo

| Modelo | Exemplos | Requisições simultâneas por processo | Limite que aparece primeiro |
|--------|----------|--------------------------------------|-----------------------------|
| *Prefork* síncrono | Gunicorn `sync`, Apache `prefork` | 1 | número de processos × memória |
| Workers com threads | Gunicorn `gthread`, Apache `worker` | número de threads | threads × memória; GIL para CPU |
| Event loop | nginx, Node.js, Uvicorn | milhares | CPU de um núcleo; código que bloqueia |
| Híbrido | Uvicorn `--workers N`, Gunicorn com workers Uvicorn | milhares × N | CPU total; limites dos parceiros |

No híbrido, um mestre abre o socket de escuta e faz fork dos workers, que herdam o descritor e disputam o `accept()` (com `SO_REUSEPORT`, cada um abre o próprio socket e o kernel distribui por hash). O mestre repõe quem morre: funeral com contratação imediata. O Gunicorn mata o worker síncrono que passa 30 segundos sem sinal de vida (`--timeout`, padrão 30): o timeout de 30 segundos que ninguém configurou, agora com licença para matar.

O **WSGI** (PEP 3333) define a aplicação como callable síncrono que devolve a resposta inteira: um processo ou thread por requisição em andamento. O **ASGI** a define como corrotina que recebe e envia eventos, o que permite conexões longas e milhares delas num loop. O SSE do capítulo 12 só existe porque a Lastro é ASGI.

No FastAPI, rota `async def` roda no event loop; rota `def` roda num pool de threads do AnyIO, de 40 por processo. O Carlos achou a combinação perfeita: código bloqueante em `async def`, com a concorrência do modelo síncrono e a fragilidade do assíncrono. Com `def`, cada processo atenderia 40 autorizações ao mesmo tempo. Errar pela metade teria funcionado melhor.

## Quantos workers, ou a conta que o fundador fez de cabeça

Chame de `C` o tempo de CPU de uma requisição e de `W` o tempo esperando I/O. Trabalho de CPU puro: um processo por núcleo; mais que isso só compra troca de contexto (o `(2 × núcleos) + 1` da documentação do Gunicorn conta com alguma espera de rede).

Espera num modelo bloqueante: cada trabalhador atende uma requisição por vez, e a vazão máxima é `trabalhadores / (C + W)`. A concorrência necessária sai da Lei de Little (capítulo 14), `L = λ × W`. Brian Goetz, em *Java Concurrency in Practice*, dá o número de threads que mantém a CPU ocupada:

```text
threads = núcleos × utilização_alvo × (1 + W / C)
```

Num event loop, volta a ser um processo por núcleo, e o teto vira `núcleos / C` ou o recurso de fora que acabar primeiro: conexões do banco, limite do parceiro, memória.

A autorização da Lastro tem `C ≈ 6 ms` e `W ≈ 900 ms`: `W / C = 150`. Por Goetz, com 4 núcleos, 604 threads por máquina. Com event loop, 4 processos. O fundador configurou `--workers 3` "para aproveitar os núcleos" e acertou o número com o modelo errado. Relógio parado também acerta duas vezes por dia, e nenhum dos dois devia ter acesso de administrador.

## Na Lastro

`temp-01` e `api-01` têm 4 vCPUs cada. As opções para o caminho da autorização, nas duas máquinas juntas:

| Opção | Teto de autorizações/s | Custo |
|-------|------------------------|-------|
| Como estava (síncrono em `async def`, 6 processos) | ~6,7, e o resto da API para junto | nada a mudar; tudo a perder |
| `--workers 64` por máquina (proposta do Carlos) | ~140 | 128 × 160 MB = 20 GB de RAM; 128 conexões HTTP/2 ao adquirente, que aceita 20; 640 conexões possíveis ao banco |
| Rotas `def` no pool de threads (40 por processo) | ~266 | 240 threads disputando o GIL nos 6 ms de CPU; SSE e GraphQL continuam no loop |
| Clientes assíncronos, 3 processos por máquina | ~750 (streams do adquirente) | trocar dois clientes; disciplina contra chamada bloqueante |

O `--workers 64` morre antes de começar: o adquirente aceita 20 conexões (capítulo 9), e cada processo abre a sua. Seriam 108 processos recusados, e o Carlos chamaria de teste de carga.

A Lastro escolhe os clientes assíncronos: `grpc.aio` para a Vigia e um cliente HTTP/2 assíncrono para o adquirente (o `httpx.AsyncClient` é um exemplo), com a mesma conexão por processo do capítulo 9. O requisito é capacidade para um trabalho 99% espera, e o event loop atende espera sem thread nem processo extra. O teto passa a ser o adquirente: 100 streams por conexão (`SETTINGS_MAX_CONCURRENT_STREAMS`), 600 nos 6 processos, 600 / 0,8 = 750 autorizações por segundo; a CPU aguentaria uns 1.000. Um semáforo de 100 por processo segura o excedente na aplicação, com prazo, em vez de estourar no parceiro.

O resto do dimensionamento:

- **Processos:** 3 por máquina. O quarto núcleo fica com o proxy TLS (capítulo 10), o sistema e, em `temp-01`, o `repasse_final_v2_agora_vai.py`, que ninguém quer ver disputando CPU com autorização.
- **Pool do banco:** 6 processos × 5 = 30 conexões possíveis, acima do teto útil de 17 a 20 do capítulo 4. O `pool_size` cai para 3: 18.
- **Nenhuma conexão do banco atravessa um `await` externo.** A cobrança é gravada numa transação curta, Vigia e adquirente são chamados sem conexão, e o resultado vai numa segunda transação curta. Segurar conexão por 0,9 segundo daria 3,3 autorizações por segundo por processo, e o `QueuePool limit` voltaria das férias.
- **CPU pesada fora do loop:** rota com mais de 20 ms de CPU vai para um processo separado. Thread não serve: com o GIL, ela paralelizaria só a culpa.

```text
             temp-01 / api-01 (4 vCPU cada, mesma forma)
   ┌───────────────────────────────────────────────────────────┐
   │ proxy TLS :443                                            │
   │    │                                                      │
   │ Uvicorn mestre (fork, repõe worker morto)                 │
   │    ├─ worker 1 ─ event loop ─┬─ pool PostgreSQL: 3        │
   │    ├─ worker 2 ─ event loop  ├─ 1 conexão LISTEN          │
   │    └─ worker 3 ─ event loop  ├─ 1 conexão HTTP/2 ─► adquirente (≤100 streams)
   │                              └─ 1 canal gRPC aio ─► Vigia │
   └───────────────────────────────────────────────────────────┘
```

Cada worker tem uma Task que dorme 100 ms e mede quanto acordou atrasado: o **lag do event loop**, métrica com alerta acima de 50 ms. Na CI, as regras `ASYNC` do Ruff barram chamada HTTP síncrona e `time.sleep` em `async def`. Na quinta seguinte, campanha repetida: CPU a 9%, lag de 2 ms, autorização ainda em 0,9 segundo (o adquirente segue em 0,8), e o processo atendendo centenas de outras coisas em vez de olhar para o teto.

Com biblioteca de parceiro só síncrona e dezenas de requisições por processo, rotas `def` seriam a escolha; com trabalho dominado por CPU, mais processos; com tráfego pequeno, prefork síncrono, que só não aguenta 12x sem juros em capinha.

## Armadilhas e casos reais

> **Armadilha:** fork depois de criar threads. O `fork()` copia só a thread que o chamou; um lock que outra thread segurava fica travado no filho para sempre, sem dono para soltar. Herança com dívida e sem inventariante. O Python 3.12 avisa com `DeprecationWarning`, e o 3.14 trocou o padrão do `multiprocessing` no Linux para `forkserver`.

> **Armadilha:** o driver síncrono escondido. Um `async def` com psycopg2, ou com um SDK de parceiro que usa `requests` por baixo, bloqueia o loop como o cliente do adquirente e passa no code review, porque a palavra `async` está lá, linda, mentindo para todo mundo. O lag do loop pega; os olhos, não.

> **Na vida real:** em 2 de julho de 2019, uma regra nova no WAF da Cloudflare trouxe uma expressão regular de *backtracking* catastrófico; a CPU dos núcleos que atendiam HTTP e HTTPS na rede inteira foi a 100%, e o tráfego falhou por 27 minutos. Nenhum modelo de concorrência salva CPU presa no caminho da requisição. O seu `re.match` também está ouvindo.

## Resumo

- Processo tem memória e descritores próprios; threads compartilham os do processo. `fork` usa copy-on-write.
- Troca de contexto voluntária (bloqueio) ou involuntária (preempção).
- I/O não bloqueante depende de notificação de prontidão; o `epoll` custa O(prontos).
- `asyncio` é cooperativo: código bloqueante em `async def` para o processo inteiro.
- GIL: threads servem para I/O, processos para CPU.
- Prefork, threads, event loop e híbrido; WSGI síncrono, ASGI assíncrono.
- CPU: um processo por núcleo; espera bloqueante: `núcleos × (1 + W/C)` threads; event loop: teto em `núcleos / C` ou no recurso de fora.

## A Lastro agora

Vigia e adquirente são chamados por clientes assíncronos, com semáforo de 100 por processo. Seguem 3 workers por máquina de 4 vCPUs, o pool caiu para 3 conexões por processo (18 no total), nenhuma conexão atravessa chamada externa, e o lag do loop tem alerta em 50 ms. O teto da autorização foi de 6,7 para 750 por segundo, com a mesma CPU que antes ficava a 4% assistindo.

O Carlos aceitou a derrota do `--workers 64` e apresentou o relatório de capacidade para a Black Friday: autorização com média de 0,9 segundo, "tranquilo". O Bazar respondeu com um contrato que fala em p99 abaixo de 1,5 segundo, e ninguém na Lastro sabe dizer qual é o p99. A média do Carlos está correta. Do mesmo jeito que a média de temperatura de um paciente com um pé no forno e outro no freezer.

## Referências

- Dan Kegel, "The C10K problem". <http://www.kegel.com/c10k.html>
- Linux man-pages, `epoll(7)`. <https://man7.org/linux/man-pages/man7/epoll.7.html>
- Python, "Developing with asyncio". <https://docs.python.org/3/library/asyncio-dev.html>
- PEP 703, "Making the Global Interpreter Lock Optional in CPython". <https://peps.python.org/pep-0703/>
- PEP 779, "Criteria for supported status for free-threaded Python". <https://peps.python.org/pep-0779/>
- PEP 3333, "Python Web Server Gateway Interface v1.0.1". <https://peps.python.org/pep-3333/>
- ASGI Specification. <https://asgi.readthedocs.io/en/latest/specs/main.html>
- Gunicorn, "Design". <https://docs.gunicorn.org/en/stable/design.html>
- FastAPI, "Concurrency and async / await". <https://fastapi.tiangolo.com/async/>
- Ruff, regras flake8-async. <https://docs.astral.sh/ruff/rules/#flake8-async-async>
- Brian Goetz et al., *Java Concurrency in Practice*, Addison-Wesley, 2006, seção 8.2.
- Cloudflare, "Details of the Cloudflare outage on July 2, 2019". <https://blog.cloudflare.com/details-of-the-cloudflare-outage-on-july-2-2019/>
