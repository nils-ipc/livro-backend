# Observabilidade

## O dashboard verde e o Bazar vermelho

Às 19h25 de uma sexta, o Bazar abriu chamado com o assunto "URGENTE!!!! APROVAÇÃO CAIU, O QUE VOCÊS FIZERAM???", e a resposta honesta era "nada", que é a pior resposta possível. Não houve deploy. O canary do capítulo anterior vigiava a taxa de aprovação com rigor estatístico, durante deploys. Fora deles, a aprovação podia despencar à vontade, sem plateia.

O Carlos abriu o dashboard. Taxa de `5xx`: zero. p99 da autorização: 1,1 s, melhor que o normal. CPU: 31%. Lag do event loop: 2 ms. Tudo verde, num tom de verde que só se vê em painel de empresa que está perdendo dinheiro. O Bazar, olhando a própria conversão, via a aprovação de cartão sair de 85% para 72% desde as 18h52.

Às 20h10, a equipe estava fazendo `grep` em logs de 60 pods, um por um, em texto livre, sem saber o que procurar. Às 21h05 alguém achou, entre dois milhões de linhas iguais, esta:

```text
WARNING antifraude: falha ao ler sinais, seguindo sem
```

O `redis-sinais` do capítulo 25 tinha batido o `maxmemory` às 18h52. Configurado com `noeviction`, ele continuava aceitando leituras e recusava escritas com `OOM command not allowed when used memory > 'maxmemory'`. O pipeline de leitura e incremento falhava inteiro, o antifraude tratava a falha como "Redis fora" e seguia sem sinais, exatamente como o capítulo 25 projetou. O Vigia, sem os contadores, recusava mais. A degradação controlada funcionou com perfeição, e ninguém sabia que ela estava ligada. Em 2h20, umas 16 mil autorizações a mais foram recusadas. Nenhum centavo errado no ledger; só vendas que não aconteceram, que é o tipo de prejuízo que não aparece em conciliação nenhuma.

O sistema sabia de tudo: cada processo tinha escrito a falha no log, dois milhões de vezes, num lugar que ninguém abria desde a visita do auditor. Como se constrói um sistema em que a pergunta "por que a aprovação caiu?" se responde em minutos, e não em duas horas de `grep`?

## Monitorar o que você sabe, observar o que você não sabe

**Monitoramento** responde perguntas feitas com antecedência: a CPU passou de 80%? O `5xx` subiu? Cada dashboard e cada alerta é uma pergunta que alguém pensou em fazer. **Observabilidade** é a propriedade de um sistema cujos sinais permitem responder perguntas que ninguém fez antes, sem mudar código e sem deploy novo. O termo vem da teoria de controle (Kálmán, 1960), onde mede se o estado interno pode ser inferido das saídas.

A sexta-feira foi uma pergunta nova: "o que mudou nas autorizações recusadas desde as 18h52?". O monitoramento da Lastro respondia com perfeição a todas as perguntas antigas. Todo dashboard é o postmortem do incidente anterior, emoldurado, e o incidente seguinte, por educação, nunca repete o figurino.

Os sinais clássicos são três: **logs** (eventos discretos com contexto), **métricas** (números agregados no tempo) e **traces** (o caminho de uma requisição pelos serviços). Cada um responde um tipo de pergunta a um custo diferente, e nenhum substitui os outros, apesar de o Carlos querer os três num `print`.

## Logs estruturados: o evento com campos

Log em texto livre é escrito para um humano lendo um processo. Com 60 pods, ninguém lê; consulta-se. **Log estruturado** é um registro com campos nomeados, em geral JSON por linha, que um sistema de busca indexa e filtra:

```json
{"ts": "2027-03-12T21:52:07.114Z", "nivel": "WARNING", "servico": "antifraude",
 "versao_servico": "sha256:7c1e...", "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
 "evento": "sinais.indisponiveis", "causa": "redis_oom", "marketplace_id": 7,
 "cobranca_id": "0195f2a4-..."}
```

A diferença é a consulta: `evento = "sinais.indisponiveis" agrupado por causa` devolve uma tabela em segundos, onde o `grep` devolvia um fim de semana. O campo `evento` é um nome estável, que código e consulta compartilham; a mensagem livre muda a cada refatoração do Carlos.

Os custos de log são volume e vazamento. Volume, porque cada linha é paga na ingestão, no índice e na retenção, e um `WARNING` por requisição a 400 requisições por segundo dá 35 milhões de linhas por dia, quase todas idênticas. Vazamento, porque o log é a cópia de dados mais esquecida da empresa: o capítulo 33 achou 204 mil cartões num log de depuração, e a solução de lá (mascaramento na origem e detector de PAN no coletor) continua valendo aqui. Corpo de requisição, token e CPF ficam fora do log, e quem discorda pode reler o capítulo 33, de joelhos, no milho.

## Métricas: contadores, gauges, histogramas e a conta da cardinalidade

Uma **métrica** é uma série temporal: um nome, um conjunto de rótulos e valores amostrados no tempo. O custo não depende do tráfego; um contador que soma um milhão de eventos por segundo ocupa o mesmo espaço que um que soma um. É o sinal mais barato, e por isso alerta se faz com ele.

Os tipos, no modelo do Prometheus (que virou referência e é o formato que o OpenTelemetry também exporta):

- **Contador**: só cresce, zera quando o processo reinicia. O valor bruto não significa nada; o que se consulta é a taxa, `rate(x[5m])`, que já trata a volta a zero.
- **Gauge**: sobe e desce. Memória usada, conexões abertas, tamanho de fila.
- **Histograma**: contadores por faixa de valor (*buckets*), cumulativos, mais soma e contagem. É o tipo que dá percentis.

```text
autorizacao_duracao_segundos_bucket{le="0.5"} 1210
autorizacao_duracao_segundos_bucket{le="1.0"} 8433
autorizacao_duracao_segundos_bucket{le="2.5"} 9902
autorizacao_duracao_segundos_bucket{le="+Inf"} 10000
autorizacao_duracao_segundos_count 10000
```

O p99 é a posição 9.900, que cai no bucket entre 1,0 e 2,5 s. `histogram_quantile` interpola linearmente dentro do bucket e estima ~2,5 s, mesmo que o p99 real seja 1,3 s. O percentil de um histograma só é tão bom quanto os buckets perto do valor que importa, então os buckets se escolhem em volta da meta (para a Lastro, 1,5 s do contrato do capítulo 14), e não pelo padrão da biblioteca. A vantagem que compensa: buckets se somam entre processos, e percentis não (a média de percentis do capítulo 14, a de "alma de horóscopo", continua inválida).

Cada combinação de rótulos é uma série separada, e o número de séries é o produto das cardinalidades. `metodo` (2) × `marketplace` (42) × `bandeira` (5) × `motivo_recusa` (12) dá 5.040 séries, tranquilo. Acrescente `cobranca_id` como rótulo e você terá uma série por cobrança, com um ponto só, guardada como série temporal: o banco de métricas explode de memória e o boleto da observabilidade passa o da nuvem. Identificador de alta cardinalidade vai para log e trace, onde cada evento já é uma linha. Esse é o ponto do capítulo 25: série temporal comprime bem justamente porque as séries são poucas e longas.

## Tracing distribuído: a cobrança com rastro

Um **trace** é a árvore de operações de uma requisição. Cada operação é um **span**, com nome, início, duração, atributos e o ID do span pai. O trace inteiro compartilha um `trace_id`. O que transforma isso em sistema distribuído é a **propagação de contexto**: cada chamada de saída leva o `trace_id` e o ID do span atual, e o serviço do outro lado cria spans filhos dele.

O formato padrão é o **W3C Trace Context**, num cabeçalho HTTP:

```http
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
```

Versão, `trace-id` de 16 bytes, `parent-id` de 8 bytes e flags (o bit final diz se o trace foi amostrado). O gRPC leva o mesmo valor nos metadados. Mensagens assíncronas levam o contexto no cabeçalho do registro do broker; o trace atravessa a fila e o consumidor continua a árvore, ou, quando processa um lote de mensagens de traces diferentes, cria **links** para cada uma, porque um span só tem um pai. O tracing é monogâmico; o lote é uma relação aberta, e o link é o registro de cada caso.

Guardar todos os spans custa caro, então se amostra. **Amostragem na cabeça** decide no primeiro serviço, por sorteio, e propaga a decisão no bit de flags: barata, e cega, porque decide antes de saber se a requisição vai dar erro. É escolher quem sai nas fotos do casamento antes de saber quem vai cair bêbado na piscina. O Dapper do Google, artigo de 2010 que popularizou a técnica, amostrava 1 em 1.024. **Amostragem na cauda** guarda tudo temporariamente num coletor e decide quando o trace termina: fica com 100% dos erros e lentos e uma fração do resto. Custa memória no coletor e exige que todos os spans de um trace cheguem ao mesmo coletor.

## OpenTelemetry: um padrão para os três

O **OpenTelemetry** (projeto da CNCF, fusão do OpenTracing com o OpenCensus em 2019, o raro caso da computação em que dois padrões concorrentes viraram um, e não três) padroniza a produção de telemetria, sem ser backend de armazenamento. Tem uma API que o código e as bibliotecas chamam, um SDK que implementa amostragem e exportação, instrumentação automática para frameworks comuns (FastAPI, httpx, psycopg, gRPC, Kafka), as **convenções semânticas** (nomes padronizados como `http.response.status_code`) e o protocolo **OTLP**.

O **Collector** é um processo separado com pipelines de *receivers*, *processors* e *exporters*: recebe OTLP dos serviços, amostra na cauda, filtra atributos, mascara, e exporta para o backend que a empresa usar (Prometheus, Jaeger, Grafana Tempo e Loki são exemplos de código aberto; há dezenas de serviços comerciais). Trocar de backend vira configuração do Collector, sem reinstrumentar os serviços. O vendor lock-in muda de endereço, mas pelo menos muda para um YAML, que é onde todo mundo já espera sofrer.

**Exemplars** fecham o ciclo: um ponto de histograma carrega o `trace_id` de uma requisição que caiu naquele bucket. Do pico no gráfico de p99 vai-se direto a um trace lento.

## RED, USE e a métrica que o negócio sente

Dois métodos dizem o que medir em cada coisa. O **RED** (Tom Wilkie) vale para serviços que atendem requisições: *Rate* (requisições por segundo), *Errors* (falhas por segundo) e *Duration* (distribuição de latência). O **USE** (Brendan Gregg) vale para recursos: *Utilization* (fração do tempo ocupado), *Saturation* (trabalho esperando) e *Errors*. Para um pool de conexões, utilização é conexões em uso sobre o tamanho, saturação é quem espera na fila do pool, erro é timeout de aquisição. Os "quatro sinais dourados" do livro de SRE do Google (latência, tráfego, erros, saturação) cobrem os dois.

A sexta-feira passou por RED e USE com nota dez. RED dos serviços: taxa normal, zero erros, latência ótima. USE do Redis: ninguém tinha aplicado; memória a 100% do `maxmemory` e escritas recusadas são, respectivamente, U e E de manual. E faltou a terceira camada: **métricas de negócio**, contadas como qualquer contador, que dizem se o sistema faz o que a empresa vende. Uma API que responde `201` rapidamente para uma autorização recusada pelo motivo errado é, para o RED, um serviço exemplar.

## Na Lastro

### Os três sinais, de ponta a ponta

Todos os serviços usam o SDK do OpenTelemetry com instrumentação automática de FastAPI, httpx, gRPC, psycopg e do cliente Kafka, e exportam OTLP para um Collector por nó (DaemonSet), que encaminha a um Collector central com amostragem na cauda. O segmento de cartão tem Collector próprio no cluster dele, e só spans com atributos de uma lista permitida saem de lá: nada de PAN, BIN ou token do cofre, com o detector de Luhn do capítulo 33 descartando e contando qualquer atributo suspeito. O backend fica em armazenamento gerenciado, separado por sinal; a escolha do produto é configuração do Collector.

Um trace de cobrança de cartão, como o Collector monta:

```text
POST /v1/cobrancas  trace 4bf92f35...                     0 ms ──────────── 912 ms
├─ gateway: limite + token                                 2 ms
├─ pagamentos: tx1 (cobrança + chave idempotência)         4 ms
├─ antifraude.avaliar                                      9 ms
│  ├─ redis-sinais: MGET + INCR (pipeline)                 1 ms
│  └─ Vigia.Avaliar (gRPC)                                 6 ms
├─ conector-adquirente.autorizar (segmento cartão)       871 ms
│  └─ cofre.detokenizar                                    2 ms
└─ pagamentos: tx2 (estado + evento na outbox)             5 ms
   ┄┄ link ┄┄ ledger-consumidor: lançamentos            +340 ms
   ┄┄ link ┄┄ webhooks-entregador: POST ao marketplace  +1,2 s
```

O contexto atravessa a parte assíncrona assim: a linha de `eventos_saida` (a outbox do capítulo 18) ganhou a coluna `traceparent`, o CDC a copia para um cabeçalho do registro no `cobrancas.eventos`, e o consumidor do ledger e o agendador de webhooks continuam o trace. O entregador envia ao marketplace o cabeçalho `traceparent` com um `trace_id` que o suporte pode consultar. Como o webhook é a única parte que o marketplace vê, o painel mostra o `trace_id` de cada entrega; o Bazar agora pode colar no "URGENTE!!!!" um identificador útil, o que só dá para torcer.

A amostragem na cauda guarda 100% dos traces com erro, com estado `processando` ou `recusada`, e com duração acima de 2 s; do resto, 5%. São ~39 cobranças por segundo de manhã e cerca de 25 spans por cobrança, uns mil spans por segundo antes da amostragem.

### Logs com contrato

Logs em JSON, uma linha por evento, com campos obrigatórios: `ts`, `nivel`, `servico`, `versao_servico` (o digest do capítulo 37), `trace_id`, `span_id`, `evento` e, quando houver, `marketplace_id` e `cobranca_id`. O formatador recusa campo fora de uma lista por serviço, para que o próximo `logger.debug(corpo)` falhe na CI, e não no relatório do auditor. Repetição vira métrica: um evento que acontece em toda requisição é contador, com no máximo um log de amostra por minuto. Retenção de 30 dias pesquisável e um ano em armazenamento frio; os logs do segmento de cartão têm retenção e acesso próprios.

### Métricas: RED, USE e o negócio

| Camada | Métrica (exemplos) | Rótulos permitidos |
|--------|--------------------|--------------------|
| RED | requisições, erros, histograma de duração por rota | `servico`, `rota`, `status`, `versao_servico` |
| USE | pool e PgBouncer (uso, espera), memória do Redis / `maxmemory`, comandos recusados, lag de consumidor, `nr_throttled` | `instancia` |
| Negócio | autorizações por resultado e motivo; aprovação; Pix confirmados por minuto; webhooks entregues; resíduo de arredondamento | `marketplace`, `metodo`, `bandeira`, `motivo` |
| Degradação | `antifraude_sinais_ausentes_total`, breaker aberto, descarte de carga, retry consumido | `servico`, `causa` |

Os buckets do histograma de autorização são 0,25, 0,5, 0,75, 1, 1,25, 1,5, 2, 3, 5 e 8 s: densos perto de 1,5 s e com o último no deadline de 8 s do capítulo 15. O Collector descarta qualquer rótulo fora da lista e conta o descarte, porque a primeira pessoa a pôr `vendedor_id` num rótulo vai ser, estatisticamente, o Carlos. São cerca de 400 mil séries ativas no total.

A regra nova é a da última linha da tabela: **todo caminho de degradação incrementa um contador**, e todo contador de degradação tem alerta. O código do capítulo 25 seguia sem sinais em silêncio; agora conta, por causa (`redis_oom`, `timeout`, `conexao`). Na sexta, esse contador teria saído de zero para 15 por segundo às 18h52.

A aprovação por marketplace e método é comparada com a mesma janela da semana anterior; queda de mais de 5 pontos por 10 minutos alerta, com o detalhamento por motivo de recusa no próprio alerta. A memória do `redis-sinais` alerta a 80% do `maxmemory`, e o `maxmemory` foi recalculado pelo volume do Tuiuiú, com a mesma conta de ordem de grandeza do capítulo 29. Como esses alertas se transformam em metas com orçamento de erro é o assunto do capítulo 39.

O diagnóstico da sexta, refeito com os sinais novos: alerta de aprovação do Bazar às 19h02; motivo dominante `antifraude_recusa`; o contador de sinais ausentes com causa `redis_oom`; o gauge de memória do `redis-sinais` em 100%. Quatro cliques, dez minutos depois do início, 23 minutos antes do Bazar.

## Armadilhas e casos reais

> **Na vida real:** o artigo do Dapper (Sigelman et al., Google, 2010) descreve o tracing em produção que inspirou o Zipkin, o Jaeger e o próprio OpenTelemetry, com propagação de contexto e amostragem uniforme de 1 em 1.024 requisições. A observação que sobreviveu: o rastreamento só funciona se for automático e onipresente, porque o serviço que não propaga o contexto corta o trace no meio, e o pedaço que falta é sempre o que você precisava ver. Trace com um serviço sem instrumentação é autópsia com um órgão faltando: dá para assinar o laudo, só não dá para dizer do que o paciente morreu.

> **Armadilha:** degradação silenciosa. Fallback, retry, breaker e cache stale existem para esconder falhas do usuário, e escondem também do operador. Cada um precisa de contador próprio, senão a falha só aparece quando a última camada de proteção cede, e a primeira testemunha é o cliente.

> **Armadilha:** dashboard de vaidade. Trinta gráficos de CPU e memória por pod, nenhum de negócio. A tela mais bonita da Lastro estava 100% verde enquanto a aprovação caía 13 pontos.

> **Armadilha:** contexto perdido na fronteira assíncrona. Instrumentação automática cobre HTTP e gRPC; outbox, CDC e jobs próprios não sabem de trace nenhum até alguém pôr o `traceparent` no dado. Sem isso, todo trace termina no `COMMIT` e o webhook vira outra história.

> **Armadilha:** log em nível `DEBUG` ligado em produção "só por hoje". O volume decuplica, a fatura chega um mês depois e o conteúdo, como o capítulo 33 provou, pode incluir o que nunca deveria estar escrito.

## Resumo

- Monitoramento responde perguntas conhecidas; observabilidade permite responder as novas sem deploy.
- Logs estruturados: campos nomeados, `evento` estável, `trace_id`; custo de volume e risco de vazamento.
- Métricas: contador (consulta por taxa), gauge, histograma (buckets agregáveis, percentil interpolado); séries = produto das cardinalidades.
- Trace: spans com pai, propagação W3C `traceparent`, links em lotes, amostragem na cabeça ou na cauda.
- OpenTelemetry: API, SDK, convenções semânticas, OTLP e Collector; backend intercambiável.
- RED para serviços, USE para recursos, métricas de negócio e contadores de degradação para o que os dois não veem.

## A Lastro agora

Toda cobrança tem um trace da API ao webhook, com o `traceparent` atravessando a outbox, o CDC e o broker, e amostragem na cauda que guarda todos os erros, recusas e lentos. Logs são JSON com campos fixos e lista permitida; métricas seguem RED, USE e negócio, com rótulos controlados pelo Collector e um contador para cada caminho de degradação. O segmento de cartão tem Collector próprio e só deixa sair atributos permitidos. O `redis-sinais` ganhou `maxmemory` recalculado e alerta de memória.

O Vigia, que no capítulo 25 ficou cego de um olho, passou a sexta cego dos dois sem que ninguém notasse, e agora tem até contador para isso. Os alertas novos disparam quando algo muda; ninguém ainda definiu quanto a Lastro pode falhar antes de doer. O novo contrato vai definir isso pela Lastro, com cláusula de SLA e multa, e o advogado do cliente não aceita "o dashboard estava verde" como evidência.

## Referências

- Sigelman, B. et al. *Dapper, a Large-Scale Distributed Systems Tracing Infrastructure*. Google, 2010. https://research.google/pubs/dapper-a-large-scale-distributed-systems-tracing-infrastructure/
- W3C. *Trace Context*. https://www.w3.org/TR/trace-context/
- OpenTelemetry. *Documentation*. https://opentelemetry.io/docs/
- OpenTelemetry. *Semantic Conventions*. https://opentelemetry.io/docs/specs/semconv/
- Prometheus. *Metric types* e *Histograms and summaries*. https://prometheus.io/docs/concepts/metric_types/ e https://prometheus.io/docs/practices/histograms/
- Gregg, B. *The USE Method*. https://www.brendangregg.com/usemethod.html
- Wilkie, T. *The RED Method: key metrics for microservices architecture*. Grafana Labs. https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/
- Beyer, B. et al. *Site Reliability Engineering*, cap. 6, "Monitoring Distributed Systems". O'Reilly, 2016. https://sre.google/sre-book/monitoring-distributed-systems/
- Redis. *Key eviction*. https://redis.io/docs/latest/develop/reference/eviction/
