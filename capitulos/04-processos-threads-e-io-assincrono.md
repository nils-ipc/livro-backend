# Processos, threads e I/O assíncrono

## Uma API inteira esperando um único boleto

Segunda-feira, 9h03. O painel mostra uma API de pagamentos com uso de CPU em 2%, memória folgada, banco tranquilo e todas as requisições levando exatamente 2 segundos. Todas. Inclusive o `GET /health`, que só devolve `{"status": "ok"}` e, até sexta-feira, levava 1 milissegundo.

O orquestrador vê o health check estourar o limite e reinicia o contêiner, que volta, fica lento e é reiniciado de novo. Às 9h20 a API já reiniciou onze vezes e continua com 2% de CPU, o que é, tecnicamente, um ótimo aproveitamento de energia.

O culpado é um *pull request* de sexta-feira, "só uma linha":

```python
@app.post("/pagamentos")
async def criar_pagamento(pedido: Pedido):
    resposta = requests.post(GATEWAY_URL, json=pedido.model_dump(), timeout=10)
    return resposta.json()
```

O gateway de boletos responde em 2 segundos, a função é `async def` e a biblioteca `requests` é síncrona. Nenhum desses fatos parece perigoso sozinho.

Por que uma única chamada lenta trava requisições que nem passam por ela? E por que a mesma linha, numa função `def` sem o `async`, funcionaria sem problema nenhum?

## O que o kernel enxerga

Para o kernel Linux, um **processo** é um espaço de endereçamento de memória isolado, com uma tabela de descritores de arquivo (sockets, arquivos, pipes), credenciais e pelo menos uma **thread**. A thread é a unidade que o escalonador põe para executar num núcleo: tem registradores, um ponteiro de instrução e uma pilha própria. Threads do mesmo processo compartilham a memória e os descritores.

No Linux os dois nascem da mesma chamada de sistema, `clone()`, com flags diferentes. Um `fork()` cria um processo com uma cópia da memória do pai; uma thread nova é um `clone()` que pede para compartilhar a memória. O kernel chama os dois de *task* e trata ambos com a mesma burocracia, sem favoritismo.

A cópia do `fork()` usa *copy-on-write*: pai e filho apontam para as mesmas páginas físicas, marcadas como somente leitura, e uma página só é duplicada quando alguém escreve nela. Um `fork()` de um processo de 500 MB é rápido e quase não consome memória no início. "No início" é a parte que costuma ser esquecida (ver as armadilhas).

| | Processo | Thread |
|---|---|---|
| Memória isolada | Sim; um crash ou corrupção fica no processo | Não; uma thread pode estragar a memória de todas |
| Criação | Centenas de microssegundos a milissegundos | Dezenas de microssegundos |
| Memória extra | Páginas que divergirem do pai | Pilha (8 MB de espaço virtual por padrão no Linux, só as páginas tocadas viram memória real) |
| Comunicação | Pipes, sockets, memória compartilhada explícita | Variáveis comuns, com todos os riscos de concorrência |

O capítulo 5 trata dos riscos desse último item.

### Troca de contexto, o imposto que ninguém declara

Um núcleo executa uma thread por vez. Quando há mais threads prontas do que núcleos, o escalonador (o CFS e, desde o Linux 6.6, o EEVDF) reparte o tempo: deixa uma thread rodar por uma fatia de alguns milissegundos e então a troca por outra. Essa troca é a **troca de contexto**: salvar os registradores da thread que sai, carregar os da que entra e, se for outro processo, trocar a tabela de páginas.

A troca também acontece quando a thread pede algo que não está pronto, como ler um socket sem dados: essa é a troca **voluntária**. A que ocorre porque a fatia acabou é **involuntária**. O kernel conta as duas:

```bash
grep ctxt /proc/48213/status
```

```text
voluntary_ctxt_switches:        1843270
nonvoluntary_ctxt_switches:     912
```

Muitas trocas voluntárias indicam um processo que passa a vida esperando I/O. Muitas involuntárias indicam threads disputando CPU, despejadas do núcleo no meio do trabalho.

O custo direto de uma troca fica na ordem de microssegundos. O indireto costuma ser maior: a thread que entra encontra caches e TLB cheios de dados alheios. Com 50 threads, isso é irrelevante. Com 10 mil, cada uma acordando por 30 µs para processar um pacote, o servidor passa boa parte do tempo fazendo a mudança e pouco tempo morando no lugar novo.

## Esperar sem bloquear

Num socket comum, `sock.recv(4096)` é **bloqueante**: sem dados no buffer do kernel, a thread dorme até eles chegarem. Para o código, a linha só demora. Para o sistema, uma thread inteira fica reservada para esperar um pacote vindo do outro lado do mundo.

"Uma thread por conexão" funciona até alguns milhares de conexões. Em 1999, Dan Kegel deu nome ao problema de atender 10 mil clientes simultâneos, o C10K, e a saída descrita ali vale até hoje: parar de dedicar uma thread a cada espera.

O primeiro passo é o socket **não bloqueante**: com `O_NONBLOCK`, um `recv` sem dados volta na hora com `EAGAIN` ("tente de novo depois"). Falta saber *quando* tentar de novo sem perguntar a cada socket, em loop, se já chegou algo (o que gastaria 100% de um núcleo para ouvir "não" quase sempre).

Para isso existe a **multiplexação de I/O**: uma chamada que recebe vários descritores e bloqueia até algum ficar pronto. O `select()` recebe a lista inteira a cada chamada, percorre todos (O(n)) e aceita no máximo `FD_SETSIZE`, 1.024 descritores na glibc. O `poll()` tirou o limite e manteve o custo.

O **epoll**, do Linux, separa as duas coisas:

- `epoll_create1()` cria uma instância de epoll no kernel.
- `epoll_ctl()` registra uma vez cada descritor e os eventos de interesse (leitura, escrita).
- `epoll_wait()` bloqueia até haver eventos e devolve **só os descritores prontos**.

O kernel preenche a lista de prontos quando os pacotes chegam, e o custo de `epoll_wait` acompanha os prontos, e não os registrados: com 50 mil conexões abertas e 30 com dados, o processo olha para 30. Os equivalentes são o kqueue (BSD e macOS) e o IOCP (Windows). O módulo `selectors` escolhe o disponível:

```python
import selectors

print(selectors.DefaultSelector)
```

```text
<class 'selectors.EpollSelector'>
```

No macOS, a mesma linha mostra `KqueueSelector`. Seu código continua igual; quem muda de ideia é a biblioteca.

> **Armadilha:** para arquivos comuns em disco o epoll não ajuda: o kernel considera um arquivo regular sempre "pronto", e a leitura bloqueia enquanto o disco trabalha. Por isso o `aiofiles` lê numa thread separada. O assíncrono de arquivo, ali, é uma thread de terno.

## O event loop e o asyncio

Um **event loop** é um laço que repete três passos: perguntar ao epoll quais descritores estão prontos, executar o código que estava esperando por eles e voltar a perguntar. Uma única thread atende milhares de conexões porque ela nunca espera por nenhuma em particular; espera por todas de uma vez, dentro do `epoll_wait`.

O `asyncio` organiza esse código em **corrotinas**. Cada `await` sobre uma operação que não está pronta suspende a corrotina e devolve o controle ao loop, que registra o socket no epoll e vai cuidar de outra coisa. Quando o dado chega, o loop retoma a corrotina da linha onde ela parou. Corrotinas do Python são geradores por dentro: o `await` descende do `yield from`, e o loop chama `send()` quando o resultado fica disponível.

O modelo é **cooperativo**: o loop não interrompe ninguém, e uma corrotina só cede o controle num `await` que suspende. Entre dois `await`s, ela tem o processo inteiro só para si.

Eis a cena de segunda-feira. O `requests.post` chama `recv` bloqueante por baixo, sem `await`. A thread do loop fica 2 segundos parada dentro do kernel, e ninguém mais é atendido, nem o `/health`. O loop continua ali, com a fila cheia, esperando educadamente uma corrotina terminar de esperar. Com dez tarefas:

```python
import asyncio
import time

async def espera_educada(n: int) -> None:
    await asyncio.sleep(1)       # devolve o controle ao loop

async def espera_egoista(n: int) -> None:
    time.sleep(1)                # segura a thread do loop inteira

async def medir(nome, corrotina) -> None:
    inicio = time.perf_counter()
    await asyncio.gather(*(corrotina(i) for i in range(10)))
    print(f"{nome}: {time.perf_counter() - inicio:.2f} s")

async def main() -> None:
    await medir("educada", espera_educada)
    await medir("egoista", espera_egoista)

asyncio.run(main())
```

```text
educada: 1.00 s
egoista: 10.02 s
```

As educadas esperam juntas; as egoístas fazem fila indiana. O modo de depuração do `asyncio` (`PYTHONASYNCIODEBUG=1`) avisa quando um passo segura o loop por mais de 100 ms, e a API de pagamentos teria confessado no log:

```text
WARNING:asyncio:Executing <Task pending name='Task-7' coro=<criar_pagamento() running at /app/pagamentos.py:9> ...> took 2.004 seconds
```

Há três correções. Um cliente assíncrono (`httpx.AsyncClient`) mantém tudo no loop. `await asyncio.to_thread(requests.post, ...)` empurra o bloqueio para o pool padrão, de `min(32, os.cpu_count() + 4)` threads. E declarar a função com `def` faz o FastAPI executá-la num pool de threads (40 por padrão, via AnyIO), que é por que a mesma linha sem `async` funcionaria.

> **Na vida real:** o bloqueio aparece disfarçado de driver de banco síncrono, de hash bcrypt, de `json.loads` de 40 MB. Nenhum faz rede, e todos seguram o loop. Até o DNS seria um problema, se o `asyncio` não o delegasse a uma thread por conta própria.

## O GIL, ou por que oito threads fazem o trabalho de uma

O CPython tem o **GIL** (*Global Interpreter Lock*): um lock que a thread precisa possuir para executar bytecode Python, porque a contagem de referências e várias estruturas internas do interpretador não suportam acesso simultâneo. Só uma thread por processo executa Python de cada vez, com 2 ou 128 núcleos.

A thread solta o GIL ao entrar numa operação bloqueante (socket, `sleep`, lock) ou numa função em C que o libera, como boa parte do NumPy e do `hashlib`. Também é obrigada a soltá-lo quando outra thread espera mais que o intervalo de troca, 5 ms por padrão (`sys.getswitchinterval()`). Para **carga de I/O**, threads funcionam bem: cada uma solta o GIL enquanto espera. Para **carga de CPU** em Python puro, elas só se revezam. Numa máquina com 8 núcleos:

```python
import time
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor

def gerar_relatorio_do_trimestre(n: int) -> int:
    # Python puro, sem I/O: o tipo de função que só sabe ocupar CPU
    return sum(i * i for i in range(n))

N, PARTES = 20_000_000, 4

def medir(nome, executor_cls) -> None:
    inicio = time.perf_counter()
    with executor_cls(max_workers=PARTES) as ex:
        list(ex.map(gerar_relatorio_do_trimestre, [N // PARTES] * PARTES))
    print(f"{nome:>9}: {time.perf_counter() - inicio:.2f} s")

if __name__ == "__main__":
    inicio = time.perf_counter()
    gerar_relatorio_do_trimestre(N)
    print(f"{'sequencial':>9}: {time.perf_counter() - inicio:.2f} s")
    medir("threads", ThreadPoolExecutor)
    medir("processos", ProcessPoolExecutor)
```

```text
sequencial: 1.21 s
  threads: 1.24 s
processos: 0.36 s
```

Quatro threads levaram o mesmo tempo que nenhuma, com o entusiasmo de quatro pessoas dividindo um único teclado. Quatro processos, cada um com seu GIL, dividiram o trabalho; a distância para o ideal de 0,30 s é o custo de criar processos e serializar dados com `pickle`.

A PEP 703 trouxe um build sem GIL (*free-threaded*), experimental no 3.13 e suportado no 3.14 (`python3.14t`). Ele continua opcional, exige extensões em C compatíveis e, segundo a documentação do 3.14, custa de 5% a 10% em código de uma thread só. Enquanto ele não for o padrão do seu ambiente e das suas dependências, CPU paralelo em Python pede processos.

## Modelos de servidor

**Prefork com workers síncronos.** O Gunicorn, com o worker padrão (`sync`), sobe um mestre que abre o socket de escuta e faz `fork()` de N workers, que herdam o socket. Cada worker atende **uma requisição por vez**; com os 4 esperando o banco, a quinta espera no *backlog* do `listen()` (2.048 por padrão). Um worker sem sinal de vida por 30 segundos (`--timeout`) é morto e substituído, com `[CRITICAL] WORKER TIMEOUT (pid:2817)` no log, o obituário mais curto da computação.

**Workers com threads.** A classe `gthread` dá a cada worker um pool de threads: 4 workers com 8 threads atendem 32 requisições ao mesmo tempo, revezando o GIL nos intervalos entre esperas.

**ASGI com event loop.** Uvicorn, Hypercorn e Granian executam aplicações ASGI num event loop por processo, com milhares de conexões abertas (o que importa para WebSocket e SSE). Para usar mais núcleos, sobem-se vários processos, com `uvicorn --workers 4` ou com o Gunicorn de mestre e o pacote `uvicorn-worker`.

Prefork entrega paralelismo de CPU e isolamento de falhas; threads e loop entregam concorrência de espera. Servidores reais combinam os dois eixos.

## Quantos workers?

A resposta é calculável, desde que você saiba quanto tempo cada requisição passa usando CPU e quanto passa esperando, em vez do método tradicional de dobrar o número até o alerta parar. Uma API hipotética recebe 300 requisições por segundo, cada uma com 20 ms de CPU e 100 ms esperando o banco.

A **Lei de Little** (detalhada no capítulo 6) dá a concorrência: requisições em andamento = taxa de chegada × tempo de permanência.

```text
L = λ × W = 300 req/s × 0,120 s = 36 requisições simultâneas
```

Com workers síncronos, são pelo menos 36 workers (ou 36 threads); com menos, a fila cresce sem parar. A CPU dá o segundo número: 300 × 0,020 s = 6 segundos de CPU por segundo, logo pelo menos 6 núcleos, e alguns a mais para fugir dos 100% de utilização, onde a latência explode. A fórmula popularizada por Brian Goetz em *Java Concurrency in Practice* junta as duas contas:

```text
threads = núcleos × (1 + tempo_de_espera / tempo_de_cpu)
        = 6 × (1 + 100 / 20) = 36
```

Para CPU pura, a espera é zero e a fórmula dá um worker por núcleo; mais que isso só compra trocas involuntárias. Com muita espera, o número cresce rápido, e um event loop, que não paga uma thread por espera, passa a pesar. O `(2 × núcleos) + 1` da documentação do Gunicorn é um ponto de partida para carga típica; o cálculo diz quando ele não serve.

> **Armadilha:** cada worker tem o próprio pool de conexões com o banco. Com 36 workers, cada um com um pool de 10 conexões, a aplicação pode abrir 360 conexões, e o `max_connections` padrão do PostgreSQL é 100. A conta dos workers e a do pool são uma conta só; o capítulo 11 trata do dimensionamento do pool.

## Propriedades e custos

| Modelo | Concorrência por processo | Paralelismo de CPU | Custo por requisição em espera | Efeito de um bloqueio inesperado |
|---|---|---|---|---|
| Prefork síncrono | 1 | Sim, entre processos | Um processo inteiro (dezenas de MB) | Trava só aquele worker |
| Workers com threads | Número de threads | Sim, entre processos; limitado pelo GIL dentro de cada um | Uma thread (pilha, troca de contexto) | Trava só aquela thread |
| ASGI com event loop | Milhares de conexões | Sim, entre processos | Um objeto corrotina (alguns KB) | Trava o processo inteiro |

O event loop é o mais barato por espera e o menos tolerante a bloqueio: exige que o caminho inteiro (driver, cliente HTTP, SDK de terceiros) seja assíncrono ou empurrado para threads explicitamente. Basta um SDK de três linhas escrito em 2014 para devolver a API inteira à segunda-feira das 9h03. O prefork síncrono é o mais caro e o mais tolerante: um worker bloqueado é um worker a menos. Na memória, 36 workers de 200 MB somam gigabytes (parte compartilhada por copy-on-write); 36 corrotinas em espera, quase nada.

## Armadilhas e casos reais

**O copy-on-write que copia tudo.** No CPython, ler um objeto escreve nele (incrementa a contagem de referências), e o coletor de lixo marca objetos. As páginas herdadas do mestre vão sendo duplicadas, e a memória "compartilhada" vira privada aos poucos. O Instagram relatou em 2017 que desligar o coletor nos workers do seu Django em prefork melhorou a eficiência de CPU em torno de 10%. O caso levou ao `gc.freeze()` do Python 3.7, chamado no mestre antes do `fork()`, e a PEP 683 (objetos imortais, 3.12) cita o mesmo problema.

**`fork()` com threads vivas.** O `fork()` copia só a thread que o chamou. Se outra segurava um lock (do logging, do alocador) naquele instante, o filho herda o lock fechado e ninguém para abri-lo; o primeiro `logger.info()` espera para sempre. O 3.12 passou a emitir `DeprecationWarning` nesse caso, e o 3.14 trocou o padrão do `multiprocessing` no Linux para `forkserver`.

**`os.cpu_count()` dentro de contêiner.** Devolve os núcleos do host e ignora o cgroup. `workers = multiprocessing.cpu_count() * 2 + 1` num contêiner de 2 CPUs num nó de 64 núcleos sobe 129 workers para disputar 2 CPUs. O limite efetivo (cgroup v2):

```bash
cat /sys/fs/cgroup/cpu.max
```

```text
200000 100000
```

São 200.000 µs de CPU a cada 100.000 µs: 2 CPUs. Uma configuração que respeita isso:

```python
# gunicorn.conf.py
import math
import os

def cpus_do_cgroup() -> int:
    try:
        cota, periodo = open("/sys/fs/cgroup/cpu.max").read().split()
        if cota != "max":
            return max(1, math.ceil(int(cota) / int(periodo)))
    except FileNotFoundError:
        pass  # fora de contêiner (ou cgroup v1): confia no que o SO disser
    return os.cpu_count() or 1

workers = cpus_do_cgroup() * 2 + 1   # 5 workers, e não 129
bind = "0.0.0.0:8000"                # dentro do contêiner, para o proxy alcançar
```

O `0.0.0.0` aqui é a interface do contêiner, exposta só para a rede interna do orquestrador.

**`select()` acima de 1.024.** Código legado com `select.select()` passa em todos os testes e falha quando o processo abre o descritor 1.024, com `ValueError: filedescriptor out of range in select()`, pontualmente no dia de maior movimento.

**Thread pool como fila escondida.** A requisição 41 num endpoint `def` do FastAPI espera uma das 40 threads, e essa espera não aparece em nenhuma métrica do banco ou do gateway: latência alta com tudo "saudável" ao redor.

**Timeout de worker no lugar do timeout de requisição.** O `--timeout 30` do Gunicorn mata o worker com tudo que ele fazia. Para limitar uma chamada lenta, o timeout é o do cliente HTTP ou do driver (o capítulo 19 trata da escolha do valor).

## Resumo

- Processo isola memória; thread compartilha. No Linux, ambos são *tasks* criadas por `clone()`, e `fork()` usa copy-on-write.
- Troca de contexto custa microssegundos diretos e mais em caches frios; voluntária indica espera de I/O, involuntária indica disputa por CPU.
- I/O não bloqueante devolve `EAGAIN`; epoll registra descritores uma vez e devolve só os prontos, com custo proporcional aos eventos e sem o limite de 1.024 do `select()`.
- O event loop do `asyncio` é cooperativo: só troca de corrotina num `await` que suspende. Uma chamada bloqueante dentro de `async def` trava o processo inteiro.
- O GIL deixa uma thread por vez executar Python; threads servem para I/O, processos para CPU. O build sem GIL existe desde o 3.13 e é suportado no 3.14, ainda opcional.
- Prefork síncrono, workers com threads e ASGI trocam custo por conexão em espera por tolerância a bloqueio.
- Workers: Lei de Little para concorrência, tempo de CPU por requisição para núcleos, `núcleos × (1 + espera/cpu)` para carga mista. Respeitar o limite do cgroup e o `max_connections` do banco.

## Referências

- Dan Kegel, *The C10K problem*: http://www.kegel.com/c10k.html
- Página de manual do epoll(7): https://man7.org/linux/man-pages/man7/epoll.7.html
- Documentação do `asyncio`, desenvolvimento e modo de depuração: https://docs.python.org/3/library/asyncio-dev.html
- Documentação do `selectors`: https://docs.python.org/3/library/selectors.html
- PEP 703, *Making the Global Interpreter Lock Optional in CPython*: https://peps.python.org/pep-0703/
- PEP 683, *Immortal Objects, Using a Fixed Refcount*: https://peps.python.org/pep-0683/
- *What's New In Python 3.14*: https://docs.python.org/3/whatsnew/3.14.html
- Documentação do Gunicorn, design e número de workers: https://docs.gunicorn.org/en/stable/design.html
- Documentação do FastAPI, concorrência e `async`/`await`: https://fastapi.tiangolo.com/async/
- Instagram Engineering, *Dismissing Python Garbage Collection at Instagram* (2017): https://instagram-engineering.com/dismissing-python-garbage-collection-at-instagram-4dca40b29172
- Brian Goetz et al., *Java Concurrency in Practice*, Addison-Wesley, 2006, seção 8.2.
- Documentação do kernel Linux, cgroup v2 (`cpu.max`): https://docs.kernel.org/admin-guide/cgroup-v2.html
