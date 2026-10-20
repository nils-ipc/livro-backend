# Desempenho mensurável

## O painel estava verde

Segunda-feira, 9h40. O suporte abre o quinto chamado da manhã com o mesmo texto: "o checkout fica girando e depois dá erro". Você abre o painel de monitoramento. No centro, em letras grandes e num verde muito saudável, está escrito: **latência média: 95 ms**. A meta é 200 ms. O painel está tranquilo. O painel sempre está tranquilo.

Você responde ao suporte que o sistema está rápido. O suporte responde com um print de um cliente esperando 8 segundos. Os dois estão certos: o sistema está rápido e lento ao mesmo tempo, dependendo de quem pergunta.

Como medir o desempenho de um backend de um jeito que concorde com o que os usuários sentem, e como prever quando ele vai piorar antes de piorar?

## Latência e throughput

**Latência** é o tempo entre o início e o fim de uma operação, medido num ponto específico, e o ponto importa. A latência que o seu código registra começa quando o framework entrega a requisição à sua função; a que o cliente sente inclui DNS, handshakes TCP e TLS, a fila no balanceador, o *backlog* do socket, a fila do worker e só então a sua função. O seu log mede o trecho mais curto e mais bonito dessa história.

Dentro da latência há dois pedaços: o **tempo de serviço**, em que o recurso trabalha na requisição, e o **tempo de espera**, em que ela aguarda numa fila o recurso ficar livre.

**Throughput** (vazão) é quantas operações terminam por unidade de tempo. Com um único atendente, o máximo é `1 / tempo_de_serviço`: um worker que gasta 20 ms por requisição atende no máximo 50 requisições por segundo, por mais motivado que esteja.

As duas grandezas se relacionam, mas uma não determina a outra. Um caminhão de HDs atravessando o país tem vazão enorme e latência de dois dias. Um `GET` num Redis local tem latência de dezenas de microssegundos e, se você fizer um por vez numa thread, vazão bem modesta. Quando alguém diz "o sistema ficou mais rápido", a primeira pergunta técnica é: mais rápido em qual das duas?

## Por que a média engana

A média é puxada pelos extremos e, ao mesmo tempo, os esconde. E costuma descrever uma requisição que ninguém fez. O checkout da segunda-feira (hipotético) tinha 98% das requisições em 42 ms, 1,5% em 950 ms esperando um lock no banco e 0,5% em 8 segundos, presas no timeout de um gateway de pagamento.

```python
import math
import statistics

# 10 mil requisições do checkout, em milissegundos
latencias = [42] * 9_800 + [950] * 150 + [8_000] * 50

def percentil(ordenadas: list[float], p: float) -> float:
    """Método nearest-rank: o menor valor que cobre p% das amostras."""
    k = math.ceil(p / 100 * len(ordenadas)) - 1
    return ordenadas[max(k, 0)]

ordenadas = sorted(latencias)
print(f"média  {statistics.fmean(ordenadas):7.2f} ms")
for p in (50, 90, 99, 99.9):
    print(f"p{p:<5} {percentil(ordenadas, p):7.0f} ms")
print(f"máximo {max(ordenadas):7.0f} ms")
```

```text
média    95.41 ms
p50         42 ms
p90         42 ms
p99        950 ms
p99.9     8000 ms
máximo    8000 ms
```

Nenhuma das 10 mil requisições levou 95,41 ms. A média é a latência de um cliente que não existe, o único satisfeito com o painel.

### Percentis

O **percentil p** é o valor que cobre p% das amostras. O p50 é a mediana. O p99 do exemplo diz que 99% das requisições levaram até 950 ms; o p99,9 olha para a pior em cada mil.

"1% é pouco" parece razoável até você fazer a conta. A 500 requisições por segundo, 1% são 18 mil clientes por hora. E quem tem o carrinho maior faz as requisições mais pesadas, então mora na cauda com mais frequência. Uma página que dispara 40 requisições ao carregar tem `1 - 0,99^40 ≈ 33%` de chance de esbarrar em pelo menos uma acima do p99. O "1% de azarados" é, na verdade, um terço das visitas.

O nearest-rank do exemplo devolve sempre um valor que ocorreu; `statistics.quantiles` e o `histogram_quantile` do Prometheus interpolam. Com muitas amostras, os métodos convergem. Com 30 amostras, o "p99" é basicamente o máximo com um nome mais elegante.

> **Armadilha:** percentis não se agregam com média. Se a instância A tem p99 de 100 ms e a instância B tem p99 de 900 ms, o p99 do serviço pode ser qualquer valor entre 100 e 900 ms, conforme o volume de cada uma, e só dá 500 por coincidência. Combinar fontes exige combinar as distribuições (histogramas com os mesmos buckets se somam bucket a bucket) e calcular o percentil no final. O capítulo 38 trata de histogramas em métricas.

### A cauda que cresce com o fan-out

Quando uma requisição depende de várias chamadas em paralelo e só termina quando a mais lenta responde, a latência dela é o máximo das latências das partes. Se cada parte tem probabilidade 1% de ser lenta, a chance de pelo menos uma das N partes ser lenta é:

```text
P(alguma lenta) = 1 - 0,99^N

N = 1     →  1,0%
N = 10    →  9,6%
N = 100   → 63,4%
```

Com fan-out de 100, o p99 de cada servidor vira, na prática, a mediana da requisição. Jeffrey Dean e Luiz André Barroso mediram isso num serviço do Google, no artigo "The Tail at Scale" (2013): uma requisição isolada a um nó folha tinha p99 de 10 ms; a que esperava todos os nós folha, 140 ms. O artigo descreve também as *hedged requests*: mandar uma cópia a outra réplica se a primeira não responder até o p95. Num benchmark com Bigtable, a cópia após 10 ms reduziu o p99,9 de 1.800 ms para 74 ms, com 2% de requisições a mais. A técnica só vale para operações que podem ser repetidas sem efeito colateral, o que deixa o `POST /pagamentos` educadamente de fora.

## Lei de Little

A **Lei de Little** relaciona três médias de qualquer sistema estável (em que, no longo prazo, entra o mesmo tanto que sai):

```text
L = λ × W

L = número médio de itens dentro do sistema
λ = taxa média de chegada (itens por unidade de tempo)
W = tempo médio que cada item passa no sistema
```

John Little provou o resultado em 1961, e o impressionante é o que ele dispensa: nenhuma hipótese sobre distribuições ou ordem de atendimento. Vale para um worker, um cluster, um pool de conexões e até para a fila de deploys de sexta-feira.

Uma API recebe 1.200 req/s e cada requisição fica 80 ms no serviço: `L = 1.200 × 0,08 = 96` requisições em andamento, em média. Se o servidor aceita no máximo 64 ao mesmo tempo, as outras 32 estão numa fila em algum lugar, e o seu painel provavelmente não sabe qual. A lei também confere métricas: se o painel diz 2.000 req/s, 50 ms de média e 400 requisições em andamento, alguma delas mente, porque `2.000 × 0,05 = 100`. É um detector de mentiras que cabe numa linha.

## Lei de Amdahl

A **Lei de Amdahl** (Gene Amdahl, 1967) diz quanto se ganha ao paralelizar parte de um trabalho:

```text
                1
S(n) = ─────────────────
        (1 - p) + p / n

p = fração do tempo que pode ser paralelizada
n = número de unidades trabalhando em paralelo
S = aceleração em relação à versão serial
```

O limite com infinitas unidades é `1 / (1 - p)`. A parte serial vira o teto.

Um endpoint de relatório leva 400 ms: 100 ms de autenticação e banco, em sequência obrigatória, e 300 ms em seis chamadas HTTP independentes de 50 ms, uma depois da outra (porque alguém escreveu um `for` em 2021 e ele funcionou). Trocando o `for` por `asyncio.gather`, `p = 0,75` e `n = 6`:

```text
S(6) = 1 / (0,25 + 0,75/6) = 1 / 0,375 ≈ 2,67   →  400 ms / 2,67 = 150 ms
S(∞) = 1 / 0,25 = 4                            →  100 ms, e daí não passa
```

Nem com mil chamadas paralelas o endpoint fica abaixo de 100 ms. Para descer mais, só atacando a parte serial.

Amdahl supõe que as unidades paralelas não se atrapalham; na prática, elas disputam locks e conexões. A **Universal Scalability Law** de Neil Gunther acrescenta esse custo:

```text
           N
C(N) = ─────────────────────────────
        1 + α(N - 1) + β·N·(N - 1)
```

`α` é a contenção (o pedaço serial de Amdahl) e `β` é o custo de coerência entre as unidades, que cresce com N². Com `β > 0`, a curva tem um máximo e depois desce: acrescentar workers passa a reduzir a vazão. É o fenômeno em que o décimo sexto worker entra para ajudar e passa o turno inteiro esperando o lock que os outros quinze estão segurando.

## Utilização e filas, ou por que a latência explode perto de 100%

**Utilização** (`ρ`, rô) é a fração do tempo em que o recurso está ocupado: `ρ = λ × S`, a taxa de chegada vezes o tempo de serviço. Um worker que recebe 40 req/s e gasta 20 ms em cada uma tem `ρ = 0,8`.

Com chegadas perfeitamente regulares e serviço constante, não haveria fila até 100%. Mas às vezes três requisições chegam no mesmo milissegundo, e duas esperam. O modelo mais simples disso é a fila **M/M/1**: chegadas de Poisson, serviço exponencial, um atendente:

```text
W = S / (1 - ρ)          tempo médio no sistema (espera + serviço)
L = ρ / (1 - ρ)          requisições no sistema, em média
p99 de W = ln(100) × W   o tempo de resposta na M/M/1 é exponencial
```

O denominador `1 - ρ` é o vilão. Com um worker de 20 ms de tempo médio de serviço:

```python
import math

SERVICO_MS = 20  # tempo médio de serviço do worker

print("rho  no sistema  média (ms)  p99 (ms)")
for rho in (0.50, 0.70, 0.80, 0.90, 0.95, 0.99):
    media = SERVICO_MS / (1 - rho)
    p99 = math.log(100) * media
    no_sistema = rho / (1 - rho)
    print(f"{rho:.2f}  {no_sistema:10.1f}  {media:10.1f}  {p99:8.1f}")
```

```text
rho  no sistema  média (ms)  p99 (ms)
0.50         1.0        40.0     184.2
0.70         2.3        66.7     307.0
0.80         4.0       100.0     460.5
0.90         9.0       200.0     921.0
0.95        19.0       400.0    1842.1
0.99        99.0      2000.0    9210.3
```

De 50% para 90% de utilização, a carga cresceu 80% e a latência média quintuplicou. De 90% para 99%, a carga cresceu 10% e a latência ficou dez vezes maior. A curva tem um joelho, e o joelho fica bem antes do que a intuição de "ainda sobra 10% de CPU" sugere. A CPU a 95% está, tecnicamente, com folga. Os clientes na fila discordam.

O modelo M/M/1 é uma simplificação, e dois refinamentos mudam os números sem mudar o formato da curva:

- **Variabilidade.** A aproximação de Kingman multiplica a espera por `(ca² + cs²) / 2`, com `ca` e `cs` sendo os coeficientes de variação das chegadas e dos tempos de serviço. Rajadas, ou um endpoint que às vezes leva 5 ms e às vezes 3 segundos (o relatório anual, sempre ele), aumentam a fila para a mesma utilização.
- **Vários atendentes.** Com c workers numa fila só (M/M/c), o joelho se desloca para a direita: 32 workers a 80% esperam muito menos que um worker a 80%. O joelho continua lá; só se esconde melhor.

Operar a 70% ou 80% no pico é, portanto, margem para a cauda, com o número tirado da curva. Acima de 100%, a fila cresce sem limite e a latência vira uma função do tempo desde que o problema começou. Daí em diante, limitar a fila e recusar o excesso (capítulo 28) é o que impede o servidor de atender com perfeição clientes que desistiram há um minuto.

## Números de latência de referência

Para estimar antes de medir, a tabela segue os números divulgados por Jeff Dean (LADIS 2009) e atualizados por Colin Scott. São aproximações que variam com o hardware; as distâncias entre as linhas mudam pouco.

| Operação | Ordem de grandeza |
|----------|-------------------|
| Referência ao cache L1 da CPU | ~1 ns |
| Lock/unlock de mutex sem disputa | ~20 ns |
| Leitura da memória principal | ~100 ns |
| Leitura aleatória de 4 KB em SSD | dezenas de µs |
| Ida e volta na rede dentro do mesmo datacenter | ~500 µs |
| Seek em disco giratório | ~10 ms |
| Ida e volta Califórnia–Holanda–Califórnia | ~150 ms |

A coluna da direita cobre oito ordens de grandeza. Se 1 ns fosse esticado para 1 segundo, a ida e volta transatlântica levaria quase cinco anos (`0,15 s × 10^9 = 1,5 × 10^8 s`). Por isso um ORM que faz 200 consultas de 0,5 ms gasta 100 ms só em idas e voltas, com o banco ocioso quase o tempo todo (o capítulo 9 trata do N+1).

## Testes de carga: modelo aberto e modelo fechado

No **modelo fechado**, há um número fixo de usuários virtuais. Cada um envia uma requisição, espera a resposta, opcionalmente espera um tempo de reflexão Z e envia a próxima. A carga depende do próprio sistema: pela Lei de Little, `X = N / (W + Z)`. Com 50 usuários virtuais sem tempo de reflexão e latência de 250 ms, a vazão é 200 req/s. Se o servidor degradar para 2 segundos, a vazão cai para 25 req/s. O gerador de carga, gentilmente, alivia a pressão exatamente quando o servidor está sofrendo.

No **modelo aberto**, as requisições chegam numa taxa definida (500 req/s, por exemplo), terminem as anteriores ou não. Se o servidor desacelera, a concorrência sobe e a fila aparece, como no tráfego de um site público: os usuários na internet não combinam entre si de esperar o servidor se recuperar antes de clicar.

Um sistema com população limitada (500 operadores de call center, um job em lote com 8 workers) é fechado de verdade; uma API pública fica bem mais perto do aberto. Schroeder, Wierman e Harchol-Balter ("Open Versus Closed: A Cautionary Tale", NSDI 2006) mostram que, com a mesma carga média, os dois modelos produzem tempos de resposta muito diferentes. No k6, `constant-vus` é fechado e `constant-arrival-rate` é aberto.

### Coordinated omission

Gil Tene deu nome a um defeito de muitos geradores do modelo fechado: a **coordinated omission**. Quando o servidor trava, o gerador para de enviar, porque está esperando a resposta. As requisições que deveriam ter saído durante o travamento nunca existem, e suas latências nunca entram nas estatísticas. O gerador e o servidor se coordenam para omitir exatamente as piores amostras.

Uma situação hipotética, calculável à mão: o servidor responde em 1 ms, mas trava por 10 segundos em t = 50 s de um teste de 100 s a 500 req/s (pausa de *garbage collector*, `VACUUM FULL` esquecido, escolha o seu vilão).

O gerador fechado usa uma conexão, espera cada resposta e dorme 1 ms. Faz 25 mil requisições antes do travamento, uma de 10.001 ms durante e 19.999 depois: 44.999 das 45 mil amostras têm 1 ms.

O gerador aberto envia uma requisição a cada 2 ms, aconteça o que acontecer. As 5 mil enviadas durante o travamento ficam na fila; o servidor volta e atende uma por milissegundo enquanto chegam novas a cada 2 ms, e a fila leva mais 10 segundos para zerar. As 10 mil requisições entre t = 50 s e t = 70 s têm latências de 2 ms até 10.001 ms, uma de cada valor; as outras 40 mil levam 1 ms.

```text
                 fechado (45.000 amostras)   aberto (50.000 amostras)
média                       1,2 ms                  1.001,1 ms
p50                           1 ms                        1 ms
p90                           1 ms                    5.001 ms
p99                           1 ms                    9.501 ms
p99,9                         1 ms                    9.951 ms
máximo                   10.001 ms                   10.001 ms
```

Mesmo servidor, mesmo travamento. O gerador fechado relata um p99,9 de 1 ms e um máximo esquisito que alguém vai chamar de *outlier* na reunião. O gerador aberto mostra que um em cada dez usuários teria esperado mais de 5 segundos.

A correção, quando o gerador precisa manter uma taxa, é medir a latência a partir do instante em que a requisição *deveria* ter sido enviada, e não do instante em que foi:

```python
import asyncio
import time

import httpx

async def gerar_carga(cliente: httpx.AsyncClient, taxa_rps: int, duracao_s: int,
                      latencias: list[float]) -> None:
    intervalo = 1 / taxa_rps
    inicio = time.perf_counter()
    tarefas = []
    for i in range(taxa_rps * duracao_s):
        planejado = inicio + i * intervalo
        await asyncio.sleep(max(0.0, planejado - time.perf_counter()))
        tarefas.append(asyncio.create_task(requisitar(cliente, planejado, latencias)))
    await asyncio.gather(*tarefas)

async def requisitar(cliente: httpx.AsyncClient, planejado: float,
                     latencias: list[float]) -> None:
    await cliente.get("/checkout/resumo")
    # Desde o instante planejado: inclui o atraso que o próprio gerador sofreu.
    latencias.append(time.perf_counter() - planejado)
```

Cada requisição é uma tarefa independente, então uma resposta lenta não atrasa as próximas; se o próprio gerador se atrasar, o atraso entra na medição em vez de sumir.

## Propriedades e custos

| Escolha | O que mostra | O que custa ou esconde |
|---------|--------------|------------------------|
| Média | Custo total (média × volume = tempo de máquina gasto) | Esconde a cauda; descreve uma requisição que pode nunca ter ocorrido |
| Percentis (p50, p99, p99,9) | A experiência de cada fatia de usuários | Não se agregam com média; p99,9 exige muitas amostras para ser estável |
| Histograma | A distribuição inteira; permite combinar fontes | Precisão limitada pelos buckets; mais séries armazenadas |
| Teste de modelo fechado | Sistemas com população limitada; estabilidade com N clientes | Reduz a carga quando o sistema degrada; sujeito a coordinated omission |
| Teste de modelo aberto | Comportamento sob uma taxa de chegada, como tráfego público | Pode empilhar requisições sem limite; o gerador precisa sustentar a taxa |

Multiplicada pelo volume, a média dá o tempo total de recurso consumido, útil para custo e capacidade. Para a experiência do usuário, ela continua sendo o cliente fictício da segunda-feira.

## Armadilhas e casos reais

> **Armadilha:** medir só dentro da aplicação. O middleware que cronometra a função começa a contar depois do backlog do socket e da espera por um worker livre. Sob carga, a fila cresce e a métrica interna continua linda. O balanceador vê a requisição desde a chegada.

> **Armadilha:** `time.time()` para medir duração. Ele segue o relógio de parede, que o NTP pode ajustar no meio da medição, produzindo durações negativas ou de horas. `time.perf_counter()` e `time.monotonic()` são monotônicos e existem para isso.

> **Armadilha:** teste de carga que mede o cache. Repetir a mesma URL com o mesmo ID mede o cache do banco, do Redis e da CDN, todos encantados com a requisição que já conhecem. Os dados do teste precisam ter a variedade e a distribuição do tráfego real.

> **Armadilha:** gerador de carga como gargalo. Um gerador em Python numa máquina pequena satura a própria CPU antes do servidor, que assiste ao teste ocioso. A vazão relatada passa a ser a do gerador.

> **Na vida real:** Gil Tene descreveu a coordinated omission na palestra "How NOT to Measure Latency" e no README do wrk2, um fork do wrk que gera carga com taxa constante e registra latências corrigidas no HdrHistogram. A motivação foram ferramentas de benchmark populares que relatavam percentis altos ordens de grandeza menores que os reais.

## Resumo

- Latência = espera + serviço, medida num ponto específico; throughput = operações por tempo.
- A média esconde a cauda. Percentis não se agregam com média; histogramas se combinam.
- Com fan-out N, a chance de alguma parte cair no p99 é `1 - 0,99^N` (63% com N = 100).
- Little: `L = λ × W`, sem hipótese sobre distribuições.
- Amdahl: a parte serial limita a aceleração a `1 / (1 - p)`; a USL mostra a vazão caindo com unidades demais.
- M/M/1: `W = S / (1 - ρ)`; a latência dobra a 50%, quintuplica a 80% e multiplica por cem a 99%.
- Os números de latência de referência cobrem oito ordens de grandeza; uma ida e volta na rede custa mais que quase todo o código ao redor.
- Teste fechado reduz a carga quando o sistema degrada; teste aberto mantém a taxa. Coordinated omission some com as piores amostras; a correção mede a partir do instante planejado.

## Referências

- Little, J. D. C. "A Proof for the Queuing Formula: L = λW". *Operations Research*, 9(3), 1961. <https://doi.org/10.1287/opre.9.3.383>
- Amdahl, G. M. "Validity of the single processor approach to achieving large scale computing capabilities". AFIPS Spring Joint Computer Conference, 1967. <https://doi.org/10.1145/1465482.1465560>
- Dean, J.; Barroso, L. A. "The Tail at Scale". *Communications of the ACM*, 56(2), 2013. <https://doi.org/10.1145/2408776.2408794>
- Dean, J. "Designs, Lessons and Advice from Building Large Distributed Systems". Palestra no LADIS 2009. <https://www.cs.cornell.edu/projects/ladis2009/talks/dean-keynote-ladis2009.pdf>
- Scott, C. "Latency Numbers Every Programmer Should Know" (versão interativa). <https://colin-scott.github.io/personal_website/research/interactive_latency.html>
- Schroeder, B.; Wierman, A.; Harchol-Balter, M. "Open Versus Closed: A Cautionary Tale". USENIX NSDI, 2006.
- Gunther, N. J. *Guerrilla Capacity Planning*. Springer, 2007 (Universal Scalability Law).
- Tene, G. wrk2 (README, seção sobre coordinated omission). <https://github.com/giltene/wrk2>
- HdrHistogram. <https://github.com/HdrHistogram/HdrHistogram>
- Grafana k6, "Open and closed models". <https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/open-vs-closed/>
- Prometheus, "Histograms and summaries". <https://prometheus.io/docs/practices/histograms/>
- Python, `time.perf_counter`. <https://docs.python.org/3/library/time.html#time.perf_counter>
