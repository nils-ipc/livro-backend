# Falhas parciais

## O serviço que não caiu e derrubou a loja

No primeiro dia da promoção de cimento, a página "Quem somos" da loja online saiu do ar. Ela só tem uma foto da fachada. (A situação é hipotética; o cimento, não.)

Às 10h02 daquela segunda-feira, a loja recebe 200 requisições por segundo nas páginas de produto, e cada página mostra o frete, que vem do serviço interno `calcula-frete`, que consulta a API de uma transportadora.

Às 10h03 a transportadora não caiu. Continuou aceitando conexões, com toda a educação, e passou a responder em 40 segundos. O `calcula-frete` esperou com a paciência configurada em 2019:

```python
TIMEOUT = 30  # segundos. Não mexer. Ninguém sabe por quê, mas não mexer.
```

A loja tinha 40 workers síncronos. Com o frete em 80 ms, ficavam 200 × 0,08 = 16 requisições em andamento. Com cada chamada presa por 30 segundos, a conta virou 200 × 30 = 6.000 requisições para 40 lugares, e os workers acabaram em 0,2 segundo. Dali em diante, o login, o carrinho e até a página "Quem somos" davam timeout, esperando na fila atrás das páginas de produto.

Para completar, o cliente HTTP repetia a chamada três vezes ao receber erro, e o painel do `calcula-frete` ficou verde a manhã inteira: o `/health` dele respondia `200 OK` em 2 ms, porque não consultava a transportadora. Guarde esse painel verde; ele volta.

Nenhum processo caiu, e a CPU ficou em 3%, descansando como nunca. Como uma dependência que só ficou lenta derrubou o sistema inteiro, e o que cada camada deveria ter feito para a falha ficar do tamanho do frete?

## Os jeitos de quebrar, do mais educado ao mais traiçoeiro

Numa máquina só, a falha costuma ser tudo ou nada. Num sistema distribuído, uma parte quebra e o resto continua, com uma visão incompleta e possivelmente errada do que aconteceu. Isso é uma **falha parcial**, e com máquinas suficientes ela vira o estado normal: sempre tem algo quebrado em algum lugar, e a estatística garante que é numa sexta-feira. Os modelos clássicos:

| Modelo | O que o componente faz | Exemplo |
|---|---|---|
| Crash-stop | Para e nunca mais volta | Instância encerrada pelo autoscaling |
| Crash-recovery | Para e volta, talvez sem o estado em memória | Pod reiniciado pelo OOM killer |
| Omissão | Perde mensagens, no envio ou no recebimento | Pacote descartado por um firewall de tabela cheia |
| Temporização | Responde, mas fora do prazo | A transportadora das 10h03 |
| Bizantina | Faz qualquer coisa, inclusive mentir | Disco que devolve dado corrompido sem erro |

Para um backend, a mais cara é a de temporização. Um serviço morto devolve `ConnectionRefusedError` em um RTT. Um serviço lento prende workers e memória do chamador enquanto ele aceitar esperar: o morto falha sozinho, o lento terceiriza a falha para quem o chama.

Duas variantes têm nome. A *gray failure* (falha cinzenta, Huang et al., HotOS 2017) é quando o *health check* vê o serviço saudável e os clientes veem erro; o painel verde da abertura é um exemplar de museu. A *fail-slow* (Gunawi et al., FAST 2018) é o componente que funciona com uma fração do desempenho, como a placa de rede que negociou 1 Gb/s em vez de 10 Gb/s e não contou para ninguém.

Do lado de quem chama, "o servidor morreu", "a rede perdeu a resposta" e "o servidor está lento" são idênticos: silêncio. Uma chamada remota tem três resultados, sucesso, falha e "não sei". O *timeout* transforma o "não sei" numa decisão.

## Timeout, ou a arte de desistir na hora certa

Sem timeout na aplicação, quem decide quanto esperar são as camadas de baixo, e elas são muito pacientes. A `requests` não tem timeout padrão. O `statement_timeout` do PostgreSQL vem em 0, que significa infinito. O TCP do Linux, com dados enviados e não confirmados, retransmite até `tcp_retries2 = 15` vezes, cerca de 924,6 segundos segundo a documentação do kernel: quinze minutos e meio de esperança. E se o processo só aguarda a resposta, não há nada para retransmitir, e a espera vai até o keepalive (7.200 s por padrão) ou até o fim dos tempos.

### Os quatro timeouts do httpx

"Timeout" esconde várias esperas diferentes. O httpx separa quatro, todas com padrão de 5 segundos:

```python
import httpx

limites = httpx.Timeout(
    connect=1.5,  # abrir a conexão (handshake TCP e TLS)
    read=2.0,     # espera máxima ENTRE dois pedaços da resposta
    write=2.0,    # espera máxima para enviar cada pedaço do corpo
    pool=0.2,     # espera por uma conexão livre no pool do próprio cliente
)
cliente = httpx.AsyncClient(base_url="https://calcula-frete.interno", timeout=limites)
```

Um SYN perdido só é retransmitido depois do RTO inicial de 1 segundo (RFC 6298), então um `connect` de 0,5 s nunca dá chance à retransmissão; 1,5 s permite uma. O `pool` cobre a requisição na fila do próprio processo, esperando a vez de esperar.

O `read` limita o intervalo entre dois pedaços, e a duração total fica sem limite. Um servidor que manda um byte a cada 1,9 segundo nunca dispara um read timeout de 2 s e segura sua requisição por uma tarde inteira, cumprindo o regulamento à risca. O teto total vem do `asyncio.timeout` (Python 3.11+):

```python
import asyncio

async def cotar_frete(cep: str) -> dict:
    async with asyncio.timeout(1.0):  # teto da operação inteira, do connect ao último byte
        resposta = await cliente.get("/cotacao", params={"cep": cep})
        resposta.raise_for_status()
        return resposta.json()
```

### Escolhendo o número

Curto demais, o timeout cancela requisições que iam dar certo; longo demais, prende recursos durante uma falha real. O valor sai de duas medidas.

A primeira é a latência normal da dependência. Com o timeout no p99,9, cerca de 0,1% das requisições saudáveis estouram o prazo; o método da Amazon Builders' Library é escolher a taxa aceitável de timeouts falsos e ler o percentil. Com p99 de 100 ms e p99,9 de 600 ms, algo entre 700 ms e 1 s serve. O número de 2019 era 50 vezes o p99,9, dimensionado para uma transportadora que respondesse por carta registrada.

A segunda é o prazo do chamador. Se o balanceador desiste da página em 2 segundos, um timeout interno de 30 s é trabalhar 28 segundos para alguém que já foi embora. O timeout de quem chama tem de ser maior que o de quem é chamado vezes o número de tentativas, mais as esperas.

A Lei de Little (capítulo 6) dá o custo durante uma falha: requisições presas = taxa × timeout.

```text
taxa = 200 req/s, 40 workers

timeout 30 s    →  200 × 30   = 6.000 presas   (esgota em 0,2 s)
timeout 1 s     →  200 × 1    =   200 presas   (ainda esgota)
timeout 0,15 s  →  200 × 0,15 =    30 presas   (cabe, e corta as saudáveis mais lentas)
```

O timeout limita quanto tempo cada requisição sofre; com 40 workers, nenhum valor razoável impede o esgotamento. Quantas sofrem ao mesmo tempo é assunto do *circuit breaker* e do *bulkhead*.

## Retry, backoff e jitter

Depois de desistir, a tentação é tentar de novo. Às vezes o *retry* resolve (um pacote se perdeu, o líder do banco trocou); às vezes transforma um tropeço em incêndio. A diferença está em três perguntas.

### Quando tentar de novo

O erro é transitório? Erro de conexão, `503`, `504` e `429` são candidatos. Um `400` ou `404` dá o mesmo resultado na décima tentativa, só que com mais convicção.

A operação é idempotente? A RFC 9110 define `GET`, `PUT` e `DELETE` como idempotentes; o `POST` fica de fora. Um timeout num `POST /pagamentos` é o "não sei" em estado puro:

```text
Checkout:  POST /pagamentos  R$ 89,90
Gateway:   (cobra, e a resposta se perde no caminho)
Checkout:  Timeout. Vou mandar de novo, por garantia.
Gateway:   (cobra de novo, com o mesmo entusiasmo)
Cliente:   (liga para o banco)
```

A saída é uma chave de idempotência, tema do capítulo 20.

O servidor pediu um tempo? O `Retry-After` de um 429 ou 503 (RFC 9110, seção 10.2.3) diz quanto esperar. Ignorá-lo é voltar no momento em que o servidor avisou, por escrito, que não ia dar.

### Backoff exponencial

Repetir na hora concentra carga no pior momento. O *backoff* exponencial espera cada vez mais, até um teto:

```text
espera(n) = min(teto, base × 2ⁿ)        n = 0, 1, 2, ...

base = 100 ms, teto = 10 s:
100 ms, 200 ms, 400 ms, 800 ms, 1,6 s, 3,2 s, 6,4 s, 10 s, 10 s, ...
```

Sem teto, a décima segunda tentativa esperaria 0,1 × 2¹² = 409,6 s, e o usuário já teria comprado o cimento no concorrente.

### Jitter

A dependência falha para todo mundo ao mesmo tempo. Mil clientes que receberam erro em t = 0 voltam juntos em t = 100 ms, de novo em 300 ms, em 700 ms: o backoff espaçou as rajadas e manteve cada uma intacta, com a pontualidade de um coral.

O *jitter* soma aleatoriedade à espera para desfazer o bloco. Marc Brooker comparou variantes por simulação (AWS Architecture Blog, 2015):

```python
import random

BASE, TETO = 0.1, 10.0

def full_jitter(tentativa: int) -> float:
    # sorteia entre zero e o backoff exponencial
    return random.uniform(0, min(TETO, BASE * 2**tentativa))

def equal_jitter(tentativa: int) -> float:
    # metade garantida, metade sorteada
    metade = min(TETO, BASE * 2**tentativa) / 2
    return metade + random.uniform(0, metade)

def decorrelated_jitter(espera_anterior: float) -> float:
    # cresce a partir da espera anterior, sorteada, em vez do número da tentativa
    return min(TETO, random.uniform(BASE, espera_anterior * 3))
```

Com full jitter, os mil clientes se espalham entre 0 e 100 ms: cerca de 10 por milissegundo em vez de mil num só. Na simulação, as variantes com jitter fizeram o mesmo trabalho com bem menos chamadas, e full e decorrelated ficaram entre as mais econômicas. O custo é um tempo de conclusão individual menos previsível.

## Retry storm, ou como multiplicar uma falha

Cada camada ganha retries por motivos razoáveis, um de cada vez. Suponha cinco serviços em cadeia, cada um com "3 retries" (4 tentativas) na chamada para o seguinte. Quando o último falha:

```text
camadas com retry   tentativas no serviço do fundo, por clique do usuário
        1           4
        2           4 × 4 = 16
        3           4³ = 64
        5           4⁵ = 1.024
```

Mil e vinte e quatro chamadas por clique, contra o componente que já estava com problema. É um *retry storm*: ninguém escreveu um ataque de negação de serviço; ele surgiu da soma de cinco decisões prudentes.

A tempestade pode se sustentar sozinha. Bronson et al. (HotOS 2021) chamam de **falha metaestável** o estado em que o gatilho sumiu e a sobrecarga gera o trabalho que a mantém: requisições estouram o timeout, são repetidas, a carga sobe. A transportadora volta às 10h20, e a loja segue fora do ar às 10h40, com a fila cheia de repetições. Sair desse estado costuma exigir cortar carga (desligar retries, descartar tráfego) até a fila esvaziar.

As defesas:

1. **Retry numa camada só**, a que conhece a semântica da operação; as outras repassam o erro.
2. **Limite de tentativas por requisição.** O livro de SRE do Google cita no máximo três.
3. **Orçamento de retries** (*retry budget*): repetições limitadas a uma fração do tráfego normal. Com 10%, valor citado no mesmo livro, a amplificação de uma camada cai de 4× para 1,1×. O gRPC tem uma variante com token bucket (*retry throttling*).

## Circuit breaker, ou parar de bater na mesma porta

O retry decide o destino de uma requisição; o *circuit breaker* (disjuntor) decide o das próximas, pelo que aconteceu com as anteriores. Popularizado por Michael Nygard em *Release It!* (2007), tem três estados:

```text
                 falhas passam do limite
   FECHADO  ------------------------------->  ABERTO
      ^                                       |    ^
      |                     passou o tempo    |    | sonda falhou
      |                     de espera         v    |
      +-------- sonda deu certo ---------  MEIO-ABERTO
```

Fechado, as chamadas passam e o disjuntor conta os resultados. Aberto, falham na hora, sem tocar a rede. Depois da espera, meio-aberto: uma sonda passa; se der certo, fecha; se falhar, reabre. A dependência para de receber carga justamente enquanto tenta se levantar. A versão mínima, com relógio falso:

```python
import time

class CircuitoAberto(Exception):
    pass

class Disjuntor:
    def __init__(self, limite_falhas=5, tempo_aberto=30.0, relogio=time.monotonic):
        self.limite_falhas = limite_falhas
        self.tempo_aberto = tempo_aberto
        self.relogio = relogio
        self.estado = "fechado"
        self.falhas_seguidas = 0
        self.aberto_em = 0.0

    def chamar(self, funcao, *args):
        if self.estado == "aberto":
            if self.relogio() - self.aberto_em < self.tempo_aberto:
                raise CircuitoAberto("nem tentei")
            self.estado = "meio-aberto"  # deixa passar uma sonda
        try:
            resultado = funcao(*args)
        except Exception:
            self._registrar_falha()
            raise
        self.estado, self.falhas_seguidas = "fechado", 0
        return resultado

    def _registrar_falha(self):
        self.falhas_seguidas += 1
        if self.estado == "meio-aberto" or self.falhas_seguidas >= self.limite_falhas:
            self.estado, self.aberto_em = "aberto", self.relogio()

def calcula_frete(cep):
    if not frete_vivo:
        raise TimeoutError("calcula-frete: 2 s sem resposta")
    return "R$ 19,90"

d = Disjuntor(limite_falhas=3, tempo_aberto=30.0, relogio=lambda: agora)  # relógio falso
for agora, frete_vivo in [(0, False), (1, False), (2, False), (3, False),
                          (31, False), (32, False), (65, True), (66, True)]:
    try:
        msg = f"ok: {d.chamar(calcula_frete, '01310-100')}"
    except Exception as e:
        msg = f"{type(e).__name__}: {e}"
    print(f"t={agora:>3}s  {msg:<46} estado={d.estado}")
```

```text
t=  0s  TimeoutError: calcula-frete: 2 s sem resposta  estado=fechado
t=  1s  TimeoutError: calcula-frete: 2 s sem resposta  estado=fechado
t=  2s  TimeoutError: calcula-frete: 2 s sem resposta  estado=aberto
t=  3s  CircuitoAberto: nem tentei                     estado=aberto
t= 31s  CircuitoAberto: nem tentei                     estado=aberto
t= 32s  TimeoutError: calcula-frete: 2 s sem resposta  estado=aberto
t= 65s  ok: R$ 19,90                                   estado=fechado
t= 66s  ok: R$ 19,90                                   estado=fechado
```

Em t = 3 s e t = 31 s o chamador desistiu em microssegundos, sem pagar os 2 segundos. Em t = 32 s a sonda falhou e o disjuntor reabriu; em t = 65 s passou, e tudo voltou ao normal sem reunião. Implementações de produção usam taxa de falhas numa janela deslizante: o Resilience4j, de Java, abre por padrão com 50% de falhas em 100 chamadas e fica 60 s aberto.

Timeouts, erros de conexão e 5xx contam como falha. Um 404 é a dependência informando, perfeitamente saudável, que o CEP não existe; um disjuntor que conta 4xx abre porque meia dúzia de usuários digitou errado. E o estado vive em cada processo: com 40 processos, cada um aprende sozinho que a transportadora caiu. Compartilhar o estado num Redis cria uma dependência nova, com timeout próprio, só para lidar com dependências quebradas, o que tem sua ironia.

## Bulkhead, ou o frete não leva o login junto

Na abertura, o login caiu porque dividia os 40 workers com as páginas que esperavam o frete. O *bulkhead* (antepara, a divisória estanque do casco de um navio) dá a cada dependência um conjunto separado e limitado de recursos. Num processo assíncrono, basta um semáforo que recusa na hora em vez de enfileirar:

```python
import asyncio
import httpx

class CompartimentoCheio(Exception):
    pass

class Bulkhead:
    def __init__(self, nome: str, vagas: int):
        self.nome = nome
        self._semaforo = asyncio.Semaphore(vagas)

    async def executar(self, corrotina):
        if self._semaforo.locked():  # sem vaga: falha agora, sem entrar em fila
            corrotina.close()
            raise CompartimentoCheio(self.nome)
        async with self._semaforo:
            return await corrotina

frete = Bulkhead("calcula-frete", vagas=20)

async def pagina_produto(produto_id: int, cep: str) -> dict:
    try:
        valor_frete = await frete.executar(cotar_frete(cep))
    except (CompartimentoCheio, TimeoutError, httpx.HTTPError):
        valor_frete = None  # a página sai sem frete (ver "degradação controlada")
    return {"produto": produto_id, "frete": valor_frete}
```

As vagas saem da Lei de Little: 200 req/s × 100 ms = 20 chamadas em andamento. Quando o frete trava, as 20 vagas enchem em 0,1 s, as seguintes recebem `CompartimentoCheio` em microssegundos, e o login segue com o resto da capacidade. A página "Quem somos" volta a exibir a fachada, para alívio de ninguém em particular.

Com workers síncronos, o equivalente é um pool de threads por dependência, o modelo do Hystrix, da Netflix. Em escala maior, o bulkhead vira infraestrutura: pools de conexão separados para tráfego interativo e relatórios, ou células, cópias independentes da pilha que atendem cada uma uma fração dos clientes.

## Deadlines propagados

O checkout tem 1 segundo. Chama o estoque com timeout de 1 s, que chama o banco com 1 s, e depois chama o frete com mais 1 s: cada camada respeita o próprio número, e o total passa de 2 segundos. Quando o checkout desiste, o estoque e o banco continuam trabalhando, porque ninguém avisou. Esse trabalho órfão consome capacidade justamente na sobrecarga, com a dedicação de quem prepara uma festa para convidados que já foram embora.

Com um *deadline*, a requisição carrega um prazo, e cada camada usa só o que sobrou. O gRPC transmite no cabeçalho `grpc-timeout`, e o servidor lê `context.time_remaining()`. O valor é relativo ("restam 640 ms"), porque relógios de máquinas diferentes divergem (capítulo 18). Em HTTP não há cabeçalho padrão; usa-se um próprio:

```python
import asyncio
import time
from contextvars import ContextVar

prazo: ContextVar[float] = ContextVar("prazo")  # instante limite, relógio monotônico

def restante() -> float:
    return prazo.get() - time.monotonic()

def cabecalho_prazo() -> dict[str, str]:  # iria em cada chamada HTTP de saída
    return {"X-Prazo-Restante-Ms": str(int(restante() * 1000))}

async def chamar(servico: str, duracao: float) -> None:
    sobra = restante()
    if sobra < duracao:  # não começa o que não vai dar tempo de terminar
        print(f"{servico:<10} restam {sobra:.2f} s, precisa de {duracao:.2f} s: desisto antes")
        raise TimeoutError(servico)
    print(f"{servico:<10} restam {sobra:.2f} s: chamando")
    async with asyncio.timeout(sobra):
        await asyncio.sleep(duracao)  # a chamada de rede de verdade iria aqui

async def checkout() -> None:
    prazo.set(time.monotonic() + 1.0)
    try:
        await chamar("estoque", 0.30)
        await chamar("frete", 0.50)
        await chamar("pagamento", 0.40)
    except TimeoutError as erro:
        print(f"checkout: 504 após {1.0 - restante():.2f} s, parou em {erro}, nada foi cobrado")

asyncio.run(checkout())
```

```text
estoque    restam 1.00 s: chamando
frete      restam 0.70 s: chamando
pagamento  restam 0.20 s, precisa de 0.40 s: desisto antes
checkout: 504 após 0.80 s, parou em pagamento, nada foi cobrado
```

O pagamento nem começou, o que é melhor negócio do que cobrar o cliente e devolver timeout em seguida. No banco, o prazo vira um `SET LOCAL statement_timeout` com os milissegundos restantes, e o PostgreSQL cancela a consulta em vez de terminá-la com capricho para ninguém.

## Degradação controlada

Quando as defesas funcionam, sobra uma exceção na mão. A **degradação controlada** é decidir antes o que o sistema entrega sem aquela dependência: omitir a parte ("calcule o frete no carrinho"), usar um valor padrão (frete de tabela por região), servir dado velho (o `stale-if-error` da RFC 5861, visto no capítulo 16) ou aceitar o trabalho para depois, numa fila.

O *fallback* precisa ser mais simples que o caminho principal: um fallback que consulta outro serviço é uma dependência nova, acionada pela primeira vez no dia da falha, com carga de pico. A Amazon Builders' Library ("Avoiding fallback in distributed systems") descreve a preferência por fallbacks exercitados continuamente. E toda degradação precisa de métrica: uma página que esconde o frete em silêncio pode ficar degradada uma semana, com o painel verde, sorridente.

## Propriedades e custos

| Mecanismo | Protege contra | Custa | Mal configurado |
|---|---|---|---|
| Timeout | Espera indefinida por requisição | Corta as saudáveis acima do percentil escolhido | Curto: falhas falsas no pico. Longo: os 30 s da abertura |
| Retry com backoff e jitter | Falhas transitórias e independentes | Carga extra; latência maior para quem repete | Amplificação; cobrança duplicada em operação não idempotente |
| Orçamento de retries | Retry storm, falha metaestável | Repetições negadas durante falhas amplas | Orçamento alto demais vira amplificação sem limite visível |
| Circuit breaker | Tempo e carga gastos numa dependência quebrada | Estado por processo; erros durante o tempo aberto mesmo se a dependência voltou | Abre por 4xx; demora a fechar; granularidade grossa |
| Bulkhead | Esgotamento de um recurso compartilhado | Capacidade ociosa em cada compartimento | Poucas vagas recusam tráfego normal |
| Deadline propagado | Soma de timeouts, trabalho órfão | Cabeçalho e disciplina em todos os serviços | Um salto que ignora o prazo quebra a cadeia dali para baixo |
| Degradação controlada | Erro exposto ao usuário | Código que só roda durante falhas | Fallback mais frágil que o caminho principal |

O retry ajuda quando as falhas são curtas e independentes e atrapalha quando a falha é sobrecarga. O circuit breaker compensa quando a falha dura bem mais que o timeout; para soluços de 2 segundos, 30 s aberto produzem 28 segundos de erros que a dependência nem teria causado.

## Armadilhas e casos reais

> **Armadilha:** uma liveness probe do Kubernetes que consulta o banco faz o orquestrador reiniciar todos os pods quando o banco fica lento, somando uma tempestade de reinícios à lentidão (o capítulo 35 trata das probes).

> **Armadilha:** retries empilhados sem ninguém perceber: a biblioteca no código, o cliente HTTP com `retries`, o service mesh e o SDK da fila, quatro camadas de "só três tentativas" no mesmo salto.

> **Na vida real:** em 21 de abril de 2011, uma mudança de rede na us-east-1 da AWS isolou muitos nós do Amazon EBS de suas réplicas, e todos passaram ao mesmo tempo a procurar espaço para cópias novas, esgotando a capacidade. O relatório chama isso de "re-mirroring storm": um retry storm com volumes de disco.

> **Na vida real:** em 20 de setembro de 2015, depois de uma interrupção de rede breve, servidores de armazenamento do DynamoDB pediram metadados ao mesmo tempo, as respostas estouraram o tempo limite, os pedidos foram repetidos, e a carga manteve o serviço de metadados sobrecarregado por horas. A recuperação exigiu pausar os pedidos para adicionar capacidade: uma falha metaestável documentada.

## Resumo

- Lento é pior que morto, porque prende os recursos de quem chama.
- O timeout transforma o "não sei" em decisão; sai do percentil da dependência e do prazo de quem chama. Presas numa falha = taxa × timeout.
- Retry só para erro transitório e operação idempotente, com backoff exponencial, teto e jitter.
- Retries em camadas multiplicam (4⁵ = 1.024); defesa: uma camada só e orçamento de retries.
- Circuit breaker para de chamar o que está quebrado; bulkhead isola recursos por dependência.
- Deadline propagado evita soma de timeouts e trabalho órfão.
- Fallback mais simples que o caminho principal, exercitado e medido.

## Referências

- RFC 9110, *HTTP Semantics* (idempotência e `Retry-After`): <https://www.rfc-editor.org/rfc/rfc9110>
- RFC 6298, *Computing TCP's Retransmission Timer*: <https://www.rfc-editor.org/rfc/rfc6298>
- RFC 5861, *HTTP Cache-Control Extensions for Stale Content*: <https://www.rfc-editor.org/rfc/rfc5861>
- Documentação do kernel Linux, `ip-sysctl` (`tcp_retries2`, keepalive): <https://docs.kernel.org/networking/ip-sysctl.html>
- Documentação do httpx, *Timeouts*: <https://www.python-httpx.org/advanced/timeouts/>
- Marc Brooker, *Exponential Backoff And Jitter*, AWS Architecture Blog, 2015: <https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/>
- Amazon Builders' Library, *Timeouts, retries, and backoff with jitter*: <https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/>
- Amazon Builders' Library, *Avoiding fallback in distributed systems*: <https://aws.amazon.com/builders-library/avoiding-fallback-in-distributed-systems/>
- Google, *Site Reliability Engineering*, capítulos "Handling Overload" e "Addressing Cascading Failures": <https://sre.google/sre-book/addressing-cascading-failures/>
- gRPC, *Deadlines*: <https://grpc.io/docs/guides/deadlines/>; *Retry*: <https://grpc.io/docs/guides/retry/>
- Michael T. Nygard, *Release It!*, 2ª ed., Pragmatic Bookshelf, 2018.
- Resilience4j, *CircuitBreaker*: <https://resilience4j.readme.io/docs/circuitbreaker>
- Peng Huang et al., *Gray Failure: The Achilles' Heel of Cloud-Scale Systems*, HotOS 2017.
- Haryadi S. Gunawi et al., *Fail-Slow at Scale: Evidence of Hardware Performance Faults in Large Production Systems*, USENIX FAST 2018.
- Nathan Bronson et al., *Metastable Failures in Distributed Systems*, HotOS 2021.
- AWS, *Summary of the Amazon EC2 and Amazon RDS Service Disruption in the US East Region* (abril de 2011): <https://aws.amazon.com/message/65648/>
- AWS, *Summary of the Amazon DynamoDB Service Disruption and Related Impacts in the US-East Region* (setembro de 2015): <https://aws.amazon.com/message/5467D2/>
