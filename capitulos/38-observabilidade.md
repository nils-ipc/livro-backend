# Observabilidade

## Sábado, 7h12, e o log diz "chegou aqui 2"

Sábado, 7h12. Seu Anselmo está na porta da lavanderia Bolha Azul com onze camisas sociais num saco e um aplicativo que, há quarenta segundos, mostra uma rodinha girando em cima do botão "Pagar". No plantão, Renata abre o painel: latência média do checkout, 257 ms, verde. Taxa de erro, 0,2%, verde. O painel está tranquilo. Seu Anselmo, menos.

Renata abre os logs do serviço `checkout` e encontra 1,8 milhão de linhas como estas:

```text
2026-03-14 07:12:09 INFO chegou aqui
2026-03-14 07:12:09 INFO chegou aqui 2
2026-03-14 07:12:19 INFO chegou aqui 3 (agora vai)
2026-03-14 07:12:19 ERROR Erro: sucesso
```

Dez segundos entre `chegou aqui 2` e `chegou aqui 3`. Nesse intervalo, o checkout chama nove serviços, entre eles cupons, fidelidade e estoque de sabão (sim, existe um microsserviço de sabão). Nenhuma linha diz de qual requisição veio, e as linhas de trinta clientes simultâneos estão intercaladas. O procedimento tradicional seria acrescentar um `chegou aqui 2.5`, fazer deploy e esperar o problema voltar.

Uma em cada cinquenta requisições do checkout leva 10 segundos. Como descobrir quais, por quê e em qual dos nove serviços, sem acrescentar um `print` e fazer deploy num sábado de manhã?

## Três sinais e uma pergunta que ninguém previu

Monitoramento responde perguntas feitas com antecedência: a CPU passou de 80%? Observabilidade é a propriedade de um sistema que permite responder, com os dados que ele já emite, perguntas que ninguém previu, como "por que só alguns clientes esperam 10 segundos?". O termo vem da teoria de controle (Kálmán, 1960): um sistema é observável quando o estado interno pode ser deduzido das saídas. No backend, as saídas são três sinais: logs, métricas e traces, cada um com um custo diferente.

### Logs estruturados

Um log é o registro de um evento discreto, com horário. O defeito do `chegou aqui 2` está na forma: texto livre, feito para um humano ler uma linha por vez. Com 1,8 milhão de linhas, a ferramenta que sobra é o `grep`, e o `grep` não sabe que `pedido=48213`, `pedido 48213` e `pedido: #48213` são a mesma coisa (três desenvolvedores, três formatos, uma quarta-feira).

Log estruturado é um registro com campos nomeados e tipados, em geral uma linha de JSON por evento. A mensagem vira um nome de evento fixo, `pagamento_recusado`, e o resto vira campo: `pedido_id`, `motivo`. O armazenamento indexa os campos, e a busca vira consulta. Uma mensagem com o valor interpolado (`f"pagamento de {valor} recusado"`) gera um texto diferente para cada valor, e nenhuma ferramenta agrupa isso sem expressão regular e fé.

O campo que mais rende é o `trace_id` da requisição em toda linha que ela produz, em todos os serviços. Com ele, 1,8 milhão de linhas viram 50 mil grupos, um por requisição.

Os níveis (`DEBUG`, `INFO`, `ERROR`) filtram volume, e volume é dinheiro. Uma API com 2.000 requisições por segundo, dez linhas por requisição e 500 bytes por linha produz 10 MB/s, ou 864 GB por dia. Armazenamentos de log cobram por GB ingerido e por dia de retenção, e o `DEBUG` esquecido ligado em produção aparece na fatura do mês com nome e sobrenome.

### Métricas e seus quatro tipos

Uma métrica é um número agregado ao longo do tempo, e por isso custa o mesmo com 10 ou com 10 milhões de requisições por segundo. No modelo do Prometheus, uma série temporal é identificada por um nome e um conjunto de rótulos (pares chave-valor), e cada combinação distinta de valores de rótulos é uma série separada, com seus próprios pontos `(timestamp, valor)`.

Os tipos:

- **Contador** (*counter*): só cresce, ou volta a zero quando o processo reinicia. O valor absoluto não informa nada (12.884.301 requisições desde o último deploy, parabéns a todos os envolvidos); interessa a taxa. A função `rate()` calcula a variação por segundo e, se o valor cai, entende que o contador zerou.
- ***Gauge***: valor que sobe e desce, lido na coleta: conexões em uso, tamanho da fila. Uma fila que encheu e esvaziou entre duas coletas de 15 segundos nunca existiu para o painel.
- **Histograma**: conta quantas observações caíram em cada balde de limites fixos.
- ***Summary***: calcula quantis no próprio processo. Quantis de réplicas diferentes não se combinam (a média de dois p99 corresponde a percentil nenhum; ver capítulo 6).

A coleta pode ser *pull* (o Prometheus busca o endpoint `/metrics` de cada alvo em intervalo fixo) ou *push* (o processo envia, como o SDK do OpenTelemetry pelo protocolo OTLP).

### Histogramas, ou de onde vem o p99 do painel

Os baldes do Prometheus são cumulativos: `le="0.5"` (*less or equal*) conta todas as observações até 0,5 s. Junto vêm `_count` e `_sum`. Como tudo é contador, histogramas de réplicas se somam balde a balde:

```text
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
```

O histograma não guarda durações. O `histogram_quantile` acha o balde onde cai a posição do percentil e interpola linearmente dentro dele. Com 10.000 requisições, 9.850 até 0,5 s e 9.930 até 1 s, a posição do p99 é a 9.900ª, que fica 50 posições dentro de um balde de 80. A estimativa é `0,5 + (50 / 80) × 0,5 = 0,8125 s`. Se as 80 requisições daquele balde levaram todas 0,51 s, o p99 real é 0,51 s e o painel mostra 0,81. Com um alerta em "p99 acima de 800 ms", essa interpolação acaba de acordar alguém às 3h por causa de uma suposição sobre distribuição uniforme.

O erro é limitado pela largura do balde, então os limites precisam ser densos perto do limiar de um SLO (capítulo 39). Os baldes padrão do cliente Python vão de 5 ms a 10 s; uma chamada de 40 s cai em `+Inf`, e o histograma só diz "mais de 10 s, e não me pergunte mais nada". Os histogramas nativos do Prometheus (desde a 2.40) e o exponencial do OpenTelemetry geram baldes exponenciais automaticamente, com erro relativo constante.

### Cardinalidade, a conta que chega no fim do mês

O banco de séries temporais mantém índice e memória para cada série ativa. A cardinalidade de uma métrica é o produto das cardinalidades dos rótulos. Um histograma com 14 baldes mais `+Inf`, `_sum` e `_count` tem 17 séries por combinação. Com `rota` (40 valores), `metodo` (4), `status` (8) e `pod` (30), são 38.400 combinações e 652.800 séries. É bastante, e funciona.

Agora alguém acrescenta `cliente_id`, "só para poder filtrar por cliente". Com 200 mil clientes ativos, a conta passa de 130 bilhões de séries. Um Prometheus nunca chega a esse número, porque fica sem memória muito antes. Um serviço de métricas gerenciado chega, e manda a conta.

Rótulo adequado tem conjunto de valores pequeno e fechado: método, status, rota (`/pedidos/{id}`, nunca `/pedidos/48213`). IDs, e-mails e URLs completas vão para logs e traces, feitos para alta cardinalidade.

### Tracing distribuído

Um trace é o registro de uma requisição atravessando o sistema, organizado em árvore. Cada nó é um *span*: uma operação com nome, início, duração, atributos e status. O modelo vem do Dapper (Google, 2010).

O `trace_id` tem 16 bytes aleatórios e é igual em todos os spans da requisição. O `span_id` tem 8 bytes. O `parent_span_id` aponta para o span que fez a chamada; sem ele, o span é a raiz. O backend de tracing remonta a árvore com spans que chegam separados e fora de ordem. Os horários vêm do relógio de cada máquina, então um span filho pode aparecer começando antes do pai, o que é fisicamente impossível e acontece toda semana (capítulo 18).

O tipo (*kind*) do span é `SERVER`, `CLIENT`, `PRODUCER`, `CONSUMER` ou `INTERNAL`. A diferença entre o `CLIENT` do chamador e o `SERVER` do chamado é o tempo no caminho: rede, pool, balanceador. Se o cliente mediu 900 ms e o servidor mediu 40, os 860 ms restantes estão entre os dois, e nenhum dos serviços tem culpa (os dois vão negar mesmo assim, agora com dados).

### Propagação de contexto

O trace só existe se o `trace_id` atravessa as fronteiras. Entre processos, ele viaja no cabeçalho `traceparent` do padrão W3C Trace Context:

```text
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             │  │                                │                │
             │  trace-id (32 hex = 16 bytes)     parent-id        trace-flags
             versão                              (16 hex = 8 bytes)
```

O `parent-id` é o `span_id` do span `CLIENT` que chamou. O bit `01` (*sampled*) avisa que o chamador decidiu gravar este trace, para que os serviços seguintes gravem também. O padrão W3C Baggage define o cabeçalho `baggage` para pares chave-valor da aplicação, que seguem para todo serviço chamado, inclusive de terceiros. Colocar o CPF do cliente ali é uma forma eficiente de distribuí-lo para fornecedores.

Em mensageria, os mesmos campos vão nos cabeçalhos da mensagem; um consumidor que processa um lote de mensagens de traces diferentes usa *links* em vez de um pai único.

Dentro do processo, o contexto vai do middleware até o cliente HTTP sem passar `trace_id` por quarenta funções: o OpenTelemetry guarda o span atual numa `ContextVar`, que tem valor próprio por thread e por tarefa do `asyncio`. A cópia é automática em `asyncio.create_task` e em `asyncio.to_thread`. Em `loop.run_in_executor` e em `ThreadPoolExecutor.submit`, não: o span criado na thread do pool vira raiz de um trace novo, órfão, que ninguém vai procurar.

### OpenTelemetry

O OpenTelemetry (OTel), da CNCF, nasceu em 2019 da fusão do OpenTracing com o OpenCensus. Ele define uma API (sem SDK configurado, as chamadas viram operações vazias), um SDK por linguagem, o protocolo OTLP (gRPC na porta 4317, HTTP na 4318), as convenções semânticas, que fixam nomes de atributos (`http.request.method`, `http.route`), e o Collector, um processo com pipeline de *receivers*, *processors* (amostragem, lotes, remoção de atributos) e *exporters*. Trocar de backend muda só configuração.

Todo dado carrega atributos de recurso, como `service.name`. Sem ele, o SDK usa `unknown_service`, e um painel com doze serviços chamados `unknown_service` é uma experiência que todo mundo tem uma vez na vida.

### Amostragem

Guardar todos os spans custa caro: a 3.000 requisições por segundo e 25 spans por requisição, são 75 mil spans por segundo. A amostragem decide quais traces guardar.

Na amostragem na cabeça (*head sampling*), a decisão sai no primeiro serviço e se propaga pelo bit *sampled*; o `TraceIdRatioBased` do OTel compara bits do `trace_id` com um limiar, e o `ParentBased` faz o filho seguir o pai. É barato e decide antes de saber como a requisição vai terminar: com 1%, de cada 100 requisições lentas iguais à do Seu Anselmo, você guarda uma, e descarta as outras 99 com toda a confiança estatística.

Na amostragem na cauda (*tail sampling*), o Collector espera o trace terminar e decide depois: todos com erro, todos acima de 2 s, 1% do resto. O processador `tail_sampling` espera 30 segundos por padrão, com os spans em memória, e todos os spans de um trace precisam chegar à mesma instância (o exporter `loadbalancing` roteia por `trace_id`).

### RED e USE

O método RED (Tom Wilkie, 2015) vale para cada serviço: *Rate* (requisições por segundo), *Errors* (erros por segundo) e *Duration* (histograma da duração). O método USE (Brendan Gregg, 2012) vale para cada recurso (CPU, memória, disco, pool, fila): *Utilization* (fração do tempo ocupado), *Saturation* (trabalho esperando, como `nr_throttled` do cgroup) e *Errors*. A saturação separa casos que a utilização confunde: um pool com 10 de 10 conexões em uso marca 100% de utilização tanto com zero quanto com 400 requisições na fila, e só uma dessas situações tem 400 pessoas olhando uma rodinha.

Os quatro sinais dourados do livro de SRE do Google (latência, tráfego, erros e saturação) cobrem o mesmo terreno.

## Na prática

### Um log que dá para consultar

Com `structlog`, o middleware associa o contexto da requisição uma vez, numa `ContextVar`, e toda linha emitida depois o carrega:

```python
import structlog

structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        structlog.processors.JSONRenderer(sort_keys=True),
    ]
)
log = structlog.get_logger()

# o middleware faz isto uma vez, no começo da requisição
structlog.contextvars.bind_contextvars(
    trace_id="4bf92f3577b34da6a3ce929d0e0e4736", pedido_id=48213
)

# qualquer função, em qualquer profundidade, sem receber nada por parâmetro
log.info("pagamento_recusado", motivo="saldo_insuficiente", valor_centavos=8990)
```

```json
{"event": "pagamento_recusado", "level": "info", "motivo": "saldo_insuficiente", "pedido_id": 48213, "timestamp": "2026-03-14T07:12:09.481233Z", "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736", "valor_centavos": 8990}
```

O `pedido_id` sai como número, o horário em UTC, e o `trace_id` liga a linha ao trace. Em texto livre, seria `chegou aqui 4`.

### O histograma do checkout

O serviço registra um contador e um histograma, com o nome da rota como rótulo:

```python
import time

from prometheus_client import Counter, Histogram

REQUISICOES = Counter("http_requests", "Requisições HTTP", ["rota", "status"])
DURACAO = Histogram(
    "http_request_duration_seconds",
    "Duração das requisições",
    ["rota"],
    buckets=(0.05, 0.1, 0.25, 0.5, 0.8, 1, 2.5, 10),
)


def registrar(rota: str, status: int, inicio: float) -> None:
    # rota é o template ("/checkout", "/pedidos/{id}"), nunca o caminho cru
    DURACAO.labels(rota=rota).observe(time.perf_counter() - inicio)
    REQUISICOES.labels(rota=rota, status=str(status)).inc()
```

Depois de 10.000 requisições, um trecho do `/metrics`:

```text
http_requests_total{rota="/checkout",status="200"} 9981.0
http_requests_total{rota="/checkout",status="500"} 19.0
http_request_duration_seconds_bucket{rota="/checkout",le="0.05"} 6210.0
http_request_duration_seconds_bucket{rota="/checkout",le="0.1"} 8730.0
http_request_duration_seconds_bucket{rota="/checkout",le="0.25"} 9604.0
http_request_duration_seconds_bucket{rota="/checkout",le="0.5"} 9790.0
http_request_duration_seconds_bucket{rota="/checkout",le="0.8"} 9796.0
http_request_duration_seconds_bucket{rota="/checkout",le="1.0"} 9800.0
http_request_duration_seconds_bucket{rota="/checkout",le="2.5"} 9801.0
http_request_duration_seconds_bucket{rota="/checkout",le="10.0"} 9802.0
http_request_duration_seconds_bucket{rota="/checkout",le="+Inf"} 10000.0
http_request_duration_seconds_count{rota="/checkout"} 10000.0
http_request_duration_seconds_sum{rota="/checkout"} 2570.4
```

A média, `2570,4 / 10000`, dá os 257 ms do painel verde. O histograma conta outra história: 198 requisições (1,98%) passaram de 10 s. O p95 fica no balde de 0,1 a 0,25 s: `0,1 + (9500 − 8730) / (9604 − 8730) × 0,15 ≈ 0,232 s`. O p99 cai no balde `+Inf`, e o `histogram_quantile` devolve o limite superior do último balde finito: 10 s. Esse "10" quer dizer "pelo menos 10". O painel exibe "p99: 10 s", que é verdade de um jeito bem específico.

### O `traceparent` saindo do processo

```python
from opentelemetry import propagate, trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider

trace.set_tracer_provider(
    TracerProvider(resource=Resource.create({"service.name": "checkout"}))
)
tracer = trace.get_tracer("bolha_azul.checkout")

with tracer.start_as_current_span("POST /checkout", kind=trace.SpanKind.SERVER):
    with tracer.start_as_current_span(
        "POST /fidelidade/pontuar", kind=trace.SpanKind.CLIENT
    ) as chamada:
        cabecalhos: dict[str, str] = {}
        propagate.inject(cabecalhos)  # lê o span atual da ContextVar
        print(cabecalhos)
        print(format(chamada.get_span_context().span_id, "016x"))
```

```text
{'traceparent': '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'}
00f067aa0ba902b7
```

Os IDs são aleatórios (estes são os do exemplo da especificação W3C). O `parent-id` é o `span_id` do span `CLIENT`, e o `01` vem do amostrador padrão, `ParentBased(ALWAYS_ON)`. As instrumentações prontas de httpx, FastAPI e psycopg fazem esse `inject` sozinhas.

### O trace do Seu Anselmo

Com amostragem na cauda guardando tudo acima de 2 s, Renata filtra os traces do checkout com duração acima de 5 s. São 198, e o do Seu Anselmo tem esta forma:

```text
trace 4bf92f3577b34da6a3ce929d0e0e4736                                    10,214 s
checkout       SERVER  POST /checkout              ████████████████████  10,214 s
cupons         SERVER  POST /cupons/validar        ▏                      0,018 s
estoque-sabao  SERVER  GET /estoque/sabao          ▏                      0,009 s
fidelidade     SERVER  POST /fidelidade/pontuar     ███████████████████  10,031 s
  fidelidade   CLIENT  POST sms.exemplo.com/enviar  ███████████████████  10,002 s  ReadTimeout
  atributos: fidelidade.pontos=112  fidelidade.gatilho="brinde_100_pontos"
pagamentos     SERVER  POST /pagamentos                               ▏   0,142 s
```

Agrupando os 198 traces pelo atributo `fidelidade.gatilho`, todos têm `brinde_100_pontos`. Quem passa de 100 pontos ganha uma lavagem grátis, e o serviço de fidelidade avisa por SMS, de forma síncrona, por um fornecedor que está fora do ar. O cliente HTTP espera os 10 s do timeout, a exceção é capturada e registrada como `Erro: sucesso`, e o checkout responde 200. O sistema pune com precisão os clientes mais fiéis. Seu Anselmo tem 112 pontos.

O atributo no span encontrou o padrão, a árvore apontou o serviço, e a amostragem na cauda garantiu que os 198 traces existiam. Nenhum `print` foi acrescentado.

## Propriedades e custos

| | Logs | Métricas | Traces |
|---|---|---|---|
| Unidade | evento | número agregado por série | requisição (árvore de spans) |
| Custo cresce com | eventos (req/s × linhas × bytes) | número de séries (cardinalidade) | req/s × spans, reduzido pela amostragem |
| Alta cardinalidade | suporta | quebra | suporta |
| Pergunta típica | "o que aconteceu com o pedido 48213?" | "a taxa de erro subiu nos últimos 5 min?" | "onde foram os 10 s?" |
| Exatidão | exata por evento registrado | exata em contagens, aproximada em percentis | exata, só no que foi amostrado |
| Base para alertas | ruim (contagem cara e atrasada) | boa (barata, completa, contínua) | ruim com amostragem na cabeça |

Métricas são o sinal para alertas porque contam todas as requisições a custo fixo. Traces amostrados não servem para contar: com 1% de amostragem, a taxa de erro calculada a partir deles tem a precisão de uma pesquisa com 1% dos entrevistados escolhidos antes de saber a resposta. Logs contam tudo, mas cobram por linha.

No *pull*, um processo morto aparece como falha de coleta (`up == 0`). No *push*, ele só para de enviar, e o silêncio é ambíguo entre "morreu" e "não tinha nada a dizer". Em compensação, *push* atende jobs mais curtos que o intervalo de coleta e processos atrás de NAT.

## Armadilhas e casos reais

> **Armadilha:** o contador de erros que nunca existiu. Uma série com rótulos só aparece depois do primeiro `inc()`. Se `status="500"` nunca ocorreu desde o último deploy, a consulta da taxa de erro não devolve zero: devolve vazio, e um alerta `taxa_de_erro > 0.05` sobre um resultado vazio nunca dispara. Chamar `.labels(rota=..., status="500")` na inicialização cria a série com valor 0.

Rótulos com o caminho cru da URL deixam os robôs da internet escolherem a sua cardinalidade: um scanner pedindo `/wp-admin.php`, `/.env` e outros 4.000 endereços inexistentes cria 4.000 séries de 404, cada uma vezes os baldes do histograma.

Contexto perdido em threads: a cópia do contexto é automática em `asyncio.create_task` e `asyncio.to_thread`, mas não em `loop.run_in_executor` nem em `ThreadPoolExecutor.submit`. O span criado na thread do pool vira raiz de um trace órfão, que ninguém vai procurar.

O exporter é uma dependência. O `BatchSpanProcessor` do OTel enfileira até 2.048 spans e descarta o excedente, então um Collector fora do ar custa traces, sem derrubar a aplicação. O `SimpleSpanProcessor` exporta de forma síncrona a cada span e transforma a lentidão do Collector em lentidão de toda requisição.

> **Na vida real:** em maio de 2018, o Twitter pediu a todos os usuários que trocassem a senha depois de achar um bug que gravava senhas sem hash num log interno. Em março de 2019, o Facebook confirmou ter guardado senhas de centenas de milhões de usuários em texto puro em logs internos (segundo Brian Krebs, desde 2012). O banco de senhas estava protegido; o log, não. A defesa mecânica é uma lista de campos permitidos no logger, em vez de despejar corpos de requisição inteiros.

> **Na vida real:** em dezembro de 2021, a Log4Shell (CVE-2021-44228, CVSS 10,0) mostrou o extremo oposto: o Log4j 2 interpretava `${jndi:ldap://...}` dentro das mensagens registradas, e um `User-Agent` malicioso fazia o servidor carregar código remoto. Uma aplicação Python não usa Log4j, mas o pipeline que recebe os logs dela pode usar.

## Resumo

- Log estruturado: evento fixo, campos tipados, `trace_id` em toda linha.
- Contador (use a taxa), *gauge*, histograma (agregável) e *summary* (não agregável).
- `histogram_quantile` interpola dentro do balde; `+Inf` esconde a cauda.
- Cardinalidade é o produto dos valores dos rótulos; IDs vão para logs e traces.
- Trace é uma árvore de spans; `traceparent` propaga entre processos, `contextvars` dentro.
- Amostragem na cabeça decide às cegas; na cauda, vendo o resultado.
- RED para serviços, USE para recursos.

## Referências

- W3C. *Trace Context*. <https://www.w3.org/TR/trace-context/>
- W3C. *Baggage*. <https://www.w3.org/TR/baggage/>
- OpenTelemetry. *Specification*. <https://opentelemetry.io/docs/specs/otel/>
- OpenTelemetry. *Semantic Conventions*. <https://opentelemetry.io/docs/specs/semconv/>
- OpenTelemetry. *OTLP Specification*. <https://opentelemetry.io/docs/specs/otlp/>
- Prometheus. *Metric types*. <https://prometheus.io/docs/concepts/metric_types/>
- Prometheus. *Histograms and summaries*. <https://prometheus.io/docs/practices/histograms/>
- Prometheus. *Metric and label naming*. <https://prometheus.io/docs/practices/naming/>
- Sigelman, B. et al. *Dapper, a Large-Scale Distributed Systems Tracing Infrastructure*. Google, 2010. <https://research.google/pubs/dapper-a-large-scale-distributed-systems-tracing-infrastructure/>
- Gregg, B. *The USE Method*. <https://www.brendangregg.com/usemethod.html>
- Wilkie, T. *The RED Method: How to Instrument Your Services*. Grafana Labs, 2018. <https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/>
- Beyer, B. et al. *Site Reliability Engineering*, cap. 6, "Monitoring Distributed Systems". <https://sre.google/sre-book/monitoring-distributed-systems/>
- Python. *contextvars*. <https://docs.python.org/3/library/contextvars.html>
- structlog. *Documentação*. <https://www.structlog.org/>
- NIST NVD. *CVE-2021-44228*. <https://nvd.nist.gov/vuln/detail/CVE-2021-44228>
- Krebs, B. *Facebook Stored Hundreds of Millions of User Passwords in Plain Text for Years*, 2019. <https://krebsonsecurity.com/2019/03/facebook-stored-hundreds-of-millions-of-user-passwords-in-plain-text-for-years/>
- Twitter. *Keeping your account secure*, 2018. <https://blog.twitter.com/official/en_us/topics/company/2018/keeping-your-account-secure.html>
