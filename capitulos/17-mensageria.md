# Mensageria

## Quinta, 14h02: o Hornero ficou lento e a Lastro foi junto, por solidariedade

Na quinta às 14h02, o servidor de webhooks do Mercadito Hornero começou a responder em 25 segundos, e a Lastro, educadíssima, esperou cada um deles até o fim, de pé, segurando a porta.

O webhook sai depois do COMMIT (capítulo 4), mas **de dentro da requisição** que mudou o estado: o worker grava, commita, chama o marketplace e só então responde a quem pediu. O cliente HTTP dos webhooks é um por processo, limitado a 5 conexões "para não sobrecarregar os marketplaces", com um timeout de 30 segundos "para dar tempo ao cliente". As duas gentilezas têm o mesmo autor, nome, sobrenome e um comentário `não mexa` na linha de cima.

Às 14h, o Hornero gera uns 2 webhooks por segundo. A Lei de Little (capítulo 14) faz a conta sem pedir licença: 2 por segundo × 25 segundos = 50 conexões ocupadas ao mesmo tempo. Os 9 processos da API somam 45.

```text
14h02  Hornero: deploy deles; webhooks passam a responder em 25 s
14h04  pool httpx dos 9 processos: 5/5 conexões ocupadas
14h05  webhooks do Bazar entram na fila do mesmo pool, atrás do Hornero
14h06  POST /v1/cobrancas (cartão), p99: 31 s
14h07  banco parceiro desiste de 212 notificações Pix após 3 tentativas
14h11  Bazar: "URGENTE!!!! A LASTRO CAIU?????"
14h12  analista do Hornero termina a manga do casaco de crochê
```

Você aí, que já chamou um serviço externo no meio de um handler "porque é rapidinho": a Lastro passou a ter o SLA do pior estagiário de cada marketplace.

O Carlos resolveu em nove minutos: trocou o `await enviar_webhook(...)` por `asyncio.create_task(enviar_webhook(...))`, a resposta parou de esperar e a API voltou às 14h31. Aplausos no canal. Só que as tasks continuaram na fila do mesmo pool, agora em silêncio, morrendo de timeout sem log e sem retry. Às 16h, o *reload* do deploy (capítulo 7) levou junto 140 tasks pendentes. E a documentação do `asyncio` avisa que o event loop guarda só uma referência fraca para cada task: sem referência forte no seu código, o garbage collector pode recolher a task no meio da execução. O Carlos inventou o webhook que pode ser apagado pela coleta de lixo. A semântica era at-most-once (capítulo 16); virou at-most-once com boato.

A pergunta do capítulo: como a Lastro entrega uma mensagem a quem pode demorar, sumir ou morrer, sem esperar por ele e sem perder a mensagem?

## O broker, ou o primeiro componente da Lastro cuja função é segurar coisa dos outros

Um **broker** de mensagens recebe mensagens de **produtores**, guarda de forma durável (disco e réplicas) e entrega a **consumidores**. O produtor depende só do broker; o consumidor pode estar lento, fora do ar ou nem ter sido escrito. A mensagem espera.

Isso desacopla o **tempo** (produzir agora, consumir depois), a **taxa** (produzir 500 por segundo, consumir 80, e o broker absorve a diferença) e a **falha** (o consumidor cai e o produtor nem fica sabendo). O preço vem parcelado, igual fatura da consultoria Java do Bazar: um sistema a mais para operar, entrega "depois" (milissegundos num dia bom, horas num dia ruim) e at-least-once como padrão.

Existem dois modelos de broker, com garantias bem diferentes, e o mercado chama os dois de "fila", o que ajuda tanto quanto chamar PostgreSQL e planilha de "banco".

### A fila: entregar, esperar o ack, apagar

Numa **fila**, o broker entrega cada mensagem a **um** consumidor e espera a confirmação, o **ack** (*acknowledgment*). Com ack, apaga. Sem ack, entrega de novo, talvez a outro. Vários consumidores na mesma fila são **consumidores concorrentes** (*competing consumers*): o broker divide as mensagens e a vazão cresce com eles.

O "sem ack" vem de dois jeitos. No RabbitMQ (AMQP 0-9-1), a mensagem sem ack fica presa ao canal do consumidor; se a conexão cai, volta à fila marcada `redelivered`, e o *prefetch* (`basic.qos`) limita quantas cada consumidor segura. Numa fila gerenciada como o Amazon SQS, receber esconde a mensagem por um **visibility timeout** (padrão 30 s, máximo 12 h); apagar é o ack, e se o prazo vence ela reaparece para qualquer um.

O visibility timeout é um lease (capítulo 2) com as mesmas doenças: processamento mais longo que o prazo e são dois consumidores fazendo a mesma coisa. Estende-se o prazo durante o trabalho (`ChangeMessageVisibility`) ou ele fica acima da cauda, com o critério do capítulo 15.

Nos dois mecanismos, o consumidor pode morrer entre terminar o trabalho e mandar o ack, e a mensagem é processada outra vez. Fila com ack é at-least-once por construção; o efeito exatamente uma vez sai da deduplicação no consumidor (capítulo 16). Quem manda o ack antes de processar ganha at-most-once e passa a perder mensagem com a consciência tranquila.

E a ordem? Com consumidores concorrentes, a mensagem 1 vai para o consumidor A, a 2 para o B, o B é mais rápido e a 2 termina primeiro. Uma redelivery manda a 1 para o fim da festa. As saídas têm o mesmo preço: o SQS FIFO não libera a próxima mensagem de um `MessageGroupId` enquanto a anterior não for apagada; o RabbitMQ tem *single active consumer*. Ordem custa paralelismo, sempre.

### O log: gravar no fim, cada um lê de onde parou

Um **log** (o Apache Kafka é o exemplo de referência) é um arquivo append-only replicado. O produtor anexa registros no fim, cada um com um **offset**, sua posição. Ler **não apaga nada**: o registro fica pela **retenção** (no Kafka, 168 horas por padrão), lido por ninguém ou por quarenta consumidores.

O consumidor guarda o próprio progresso, **commitando** o offset até onde processou (no Kafka, no tópico interno `__consumer_offsets`), e volta dali se morrer. Commitar depois de processar dá at-least-once; antes, at-most-once. O log trocou o nome do ack e manteve o dilema, como todo rebranding.

Um tópico se divide em **partições**, logs independentes com ordem total dentro e nenhuma entre elas. A **chave** escolhe a partição: no cliente Java do Kafka, `murmur2(chave) mod número_de_partições`. Mesma chave, mesma partição, mesma ordem.

No **consumer group**, os consumidores repartem as partições entre si, e cada partição é lida por exatamente um membro do grupo. Grupos diferentes são independentes: cada um tem os próprios offsets e lê o tópico inteiro no próprio ritmo, e um grupo novo pode começar do offset zero e reprocessar a semana inteira. Isso é o **replay**, impossível numa fila, que já apagou tudo quando você teve a ideia.

```text
tópico cobrancas.eventos, partição 3 (chave = cobranca_id)

offset:   ... 1201   1202   1203   1204   1205   1206  <- produtor anexa aqui
                                    ^                ^
            grupo webhooks-agendador        grupo conciliacao
            (commitado: 1204)               (commitado: 1206)
```

As consequências da partição são todas mecânicas:

- O paralelismo de um grupo tem teto no número de partições. Doze partições e vinte consumidores: oito recebendo salário para não fazer nada.
- Uma mensagem lenta trava a partição inteira para aquele grupo, porque o offset só avança em ordem. Head-of-line blocking (capítulo 9), agora com retenção de sete dias.
- Aumentar o número de partições muda o resultado do `mod`, e a ordem por chave quebra na transição. O número se escolhe com folga no primeiro dia, igual nome de filho.
- Consumidor que entra ou sai dispara um *rebalance*: as partições afetadas ficam sem leitor por um tempo, e o que foi processado sem commit é processado de novo pelo novo dono.

Do lado do produtor, durabilidade é configuração. No Kafka, `acks=all` com `min.insync.replicas=2` e fator de replicação 3 só confirma depois que duas réplicas gravaram; com `acks=1`, o líder confirma sozinho e, se morrer antes de replicar, a mensagem confirmada some. O produtor idempotente (KIP-98, capítulo 16, padrão desde o Kafka 3.0) evita que os retries do produtor dupliquem registros numa partição.

| Propriedade | Fila (RabbitMQ, SQS) | Log (Kafka) |
|-------------|----------------------|-------------|
| Depois de consumida | Apagada no ack | Fica até a retenção |
| Consumidores independentes | Uma fila por consumidor | Um consumer group por consumidor |
| Replay | Não | Sim, dentro da retenção |
| Ordem | Perdida com concorrência; FIFO por grupo | Por partição |
| Paralelismo | Cresce com consumidores | Teto nas partições |
| Retry e atraso por mensagem | Nativos | Inexistentes: trava a partição ou vai para outro tópico |

### A mensagem que não quer ser processada

Uma **mensagem venenosa** (*poison message*) falha sempre: JSON truncado, schema desconhecido, a cobrança de um marketplace apagado pelo Carlos num dia que ninguém comenta. Numa fila, ela volta e falha para sempre. Num log é pior: o offset não avança e a partição inteira para atrás dela.

A saída é a **DLQ** (*dead-letter queue*): depois de N tentativas, a mensagem vai para uma fila separada e o fluxo segue. No SQS, a *redrive policy* move a mensagem quando o `ApproximateReceiveCount` passa do `maxReceiveCount`; no RabbitMQ, o `x-dead-letter-exchange` recebe o que foi rejeitado sem requeue ou expirou. No Kafka não há DLQ nativa: o consumidor publica num tópico de DLQ e commita o offset.

A DLQ é um cemitério onde cada lápide é um efeito que não aconteceu. Precisa de alarme no primeiro registro, de dono e de *redrive* depois da correção. DLQ sem alarme é aquele bucket de logs que ninguém abre, só que cheio de dinheiro.

### Backlog: a dívida que a fila guarda para você

**Backlog** é o que entrou e ainda não foi processado. Na fila, é a profundidade; no log, é o **lag** de cada grupo, a diferença entre o último offset do log e o offset commitado, por partição (saída com as colunas de consumidor omitidas):

```text
$ kafka-consumer-groups.sh --describe --group webhooks-agendador ...
TOPIC              PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG
cobrancas.eventos  6          1830114         1830121         7
cobrancas.eventos  7          1702388         1750599         48211
cobrancas.eventos  8          1811920         1811925         5
```

Partição 7 com 48 mil de atraso e as vizinhas em dia: uma mensagem venenosa, num ensaio da Lastro antes de a DLQ existir. Lag somado esconde isso; o alarme olha por partição. E lag em mensagens mente sobre urgência (48 mil podem ser dez segundos ou um dia); a métrica é a **idade da mensagem mais antiga**. O tempo para zerar o backlog sai da diferença entre capacidade e chegada:

```text
tempo para drenar = backlog / (vazão do consumidor − taxa de chegada)
```

Consumindo 100 por segundo e chegando 90, um backlog de 36 mil leva uma hora. Chegando 100, para sempre. Chegando 101, o backlog cresce até a retenção apagar as mais velhas, e no log isso é perder dados sem nenhum erro, só um offset que pulou. Broker não cria capacidade, compra tempo, a juros.

## Na Lastro: um log para os fatos, uma fila para as entregas

Os requisitos, em números do projeto:

1. **Isolamento.** Endpoint lento ou fora do ar não afeta a API nem as entregas de outro marketplace.
2. **Retentativas longas.** Quem não responde `2xx` em 10 segundos (contrato do capítulo 11) recebe novas tentativas por dias, e o painel mostra o que morreu e permite reenviar.
3. **Ordem por cobrança.** O contrato segue dizendo que o `versao` desempata, mas a Lastro passa a entregar a cada endpoint os eventos de uma cobrança em ordem de `versao`, para a consultoria Java do Bazar parar de ver `estornada` antes de `paga` e de cobrar 40 horas para descobrir isso.
4. **Consumidores com replay.** A conciliação quer reler os eventos do dia e o Vigia pediu o fluxo de eventos para treinar regras, cada um no próprio ritmo.
5. **Volume.** Pico da Black Friday: 200 cobranças por segundo (capítulo 14), ~2,5 eventos por cobrança, 500 eventos por segundo; 1.000 no 2×.

As alternativas:

| | Só fila (RabbitMQ, ou fila gerenciada) | Só log (Kafka) | Tudo no PostgreSQL (`SKIP LOCKED`) | Log + fila de entregas |
|---|---|---|---|---|
| Isolamento por endpoint | Fila por endpoint | Endpoint lento trava a partição | Limite na consulta | Limite na consulta |
| Retry com atraso de horas | TTL + DLX, visibility | Tópicos de retry; ordem quebra | Coluna de próxima tentativa | Coluna de próxima tentativa |
| Replay | Não | Sim | Offsets reinventados | Sim |
| "Entregas mortas do marketplace X" | Sem consulta | Sem consulta | Índice | Índice |
| Peça nova | Broker | Broker | Nenhuma; carga no banco | Broker + banco pequeno |

A Lastro fica com a última coluna, em dois estágios.

**Os fatos vão para um log.** O broker é um serviço gerenciado compatível com o protocolo do Kafka (Amazon MSK e Confluent Cloud são exemplos), escolhido pelo requisito 4: replay e consumidores independentes só o log tem. Gerenciado porque a equipe não opera Kafka, e um cluster de Kafka operado pelo Carlos é um incidente com cronograma.

O tópico `cobrancas.eventos` tem 12 partições, fator de replicação 3, `min.insync.replicas=2` e retenção de 7 dias. A chave `cobranca_id` dá ordem por cobrança (requisito 3) e espalha a carga, porque nenhuma cobrança sozinha é quente. Doze partições sobram para 1.000 eventos por segundo; o número existe para nunca precisar mudar. O produtor usa `acks=all` e o modo idempotente; o registro é o envelope do capítulo 11.

**As entregas vão para uma fila no banco.** O grupo `webhooks-agendador` lê o tópico e grava uma linha por inscrição na tabela `entregas_webhook`, num PostgreSQL novo e pequeno, o `pg-notificacoes`. Separado do ledger pelo orçamento de conexões do capítulo 14 (o primário já usa 18 das ~17 a 20 que aguenta) e para que o churn das entregas não divida VACUUM com os lançamentos. A unicidade de `(evento_id, inscricao_id)` com `ON CONFLICT DO NOTHING` torna o agendador idempotente: reprocessamento gera `INSERT 0 0` e mais nada. O agendador nunca faz HTTP; grava e commita o offset em milissegundos, e nenhuma partição espera marketplace.

O `webhooks-entregador` roda em `api-01` e `api-02`, fora dos workers da API, assíncrono. Cada entrega reproduz o visibility timeout dentro do banco, sem segurar conexão durante `await` externo (capítulo 13):

```text
  API (9 workers)            broker                     pg-notificacoes
  COMMIT no ledger ──► cobrancas.eventos ──► agendador ──► entregas_webhook
                       (12 partições,          (grava,       │
                        chave cobranca_id)      commita)      │  tx curta: SKIP LOCKED,
                                                              │  estado em_voo,
                                    entregador ◄──────────────┘  lease_ate = agora + 30 s
                                        │
                                        ├── POST no endpoint (timeout 10 s)
                                        │
                                        └── tx curta: entregue | proxima_tentativa_em | morta
```

- A seleção pega, com `FOR UPDATE SKIP LOCKED` (capítulo 4), entregas vencidas cuja anterior da mesma inscrição e cobrança já terminou: ordem por `versao` sem travar mais nada.
- Se o entregador morre com a entrega `em_voo`, o lease vence e outro pega. O marketplace pode receber o evento duas vezes, e o contrato já manda deduplicar pelo `id`.
- Cada endpoint tem bulkhead de 10 entregas simultâneas por processo e circuit breaker com os parâmetros do capítulo 15. O Hornero lento ocupa no máximo 20 conexões, e o Bazar nem percebe.
- Falhou (timeout, `5xx`, `429`, erro de conexão)? Novas tentativas em 1 min, 5 min, 30 min, 2 h, 6 h, 12 h, 24 h e 24 h, com jitter de ±20%: nove tentativas em cerca de 69 horas, a ordem de grandeza que o Stripe documenta (até três dias). Depois, estado `morta`: a DLQ da Lastro, consultável no painel, com botão de reenvio e alarme na primeira linha.
- Evento que não desserializa vai para `cobrancas.eventos.dlq` e o agendador segue. A partição 7 do ensaio mandou um abraço.

A quinta, refeita: o Hornero gera 2 eventos por segundo e recebe 20 / 25 s = 0,8, acumulando backlog só dele, umas 4.300 entregas por hora. Quando volta a responder em 200 ms, as 20 conexões entregam 100 por segundo, e 4.300 a 100 − 2 = 98 por segundo drenam em 44 segundos. A API, enquanto isso, nem soube.

```text
Entregador: Hornero, evt_0192f3..., cobrança paga.
Hornero:    (25 segundos de silêncio)
Entregador: Tudo bem. Volto em 1 minuto. Depois em 5. Depois em 30.
Hornero:    (silêncio)
Entregador: Volto amanhã. E depois de amanhã. Domingo você vira lápide.
Bazar:      O meu chegou em 80 ms. Posso abrir chamado mesmo assim?
```

Sem consumidores além dos webhooks, uma fila sozinha bastaria (o par SNS e SQS, numa só nuvem, é um exemplo); com poucas dezenas de eventos por segundo e nenhum consumidor novo, tudo no PostgreSQL.

## Armadilhas e casos reais

> **Armadilha:** publicar no broker depois do COMMIT, que é o que a API da Lastro faz hoje. Processo morto entre as duas linhas: pagamento sem evento. Publicar antes: evento sem pagamento. Dois sistemas sem transação entre eles, buraco com capítulo próprio, o 18.

> **Armadilha:** confundir "o broker confirmou" com "a mensagem está segura". Com `acks=1`, o líder pode morrer antes de replicar; numa fila não durável do RabbitMQ, a mensagem confirmada mora na memória de um processo, o endereço mais instável da computação depois do celular do fundador.

> **Armadilha:** HTTP dentro do consumidor de um log. O endpoint lento de um marketplace trava os eventos de todo mundo que caiu na mesma partição. É a tarde de quinta, com retenção de sete dias.

> **Na vida real:** em 25 de novembro de 2020, o Amazon Kinesis Data Streams (um log gerenciado) falhou por horas em us-east-1. Segundo o relatório da AWS, ao ganhar capacidade, cada servidor da frota de front-end passou do limite de threads do sistema operacional, porque mantinha uma thread para cada outro servidor. Cognito e CloudWatch foram junto. O broker vira dependência de tudo que publica nele.

## Resumo

- Broker desacopla tempo, taxa e falha, ao custo de uma peça a mais, entrega posterior e at-least-once.
- Fila: apaga no ack; sem ack (conexão caída, visibility timeout vencido), entrega de novo. Consumidores concorrentes escalam e perdem a ordem.
- Log: append-only, offsets, retenção independente de consumo; consumer groups independentes; replay.
- Ordem só por partição ou grupo de mensagens; mudar partições quebra a ordem por chave.
- Ack ou commit depois de processar: at-least-once; antes: at-most-once.
- DLQ para mensagem venenosa, com alarme, dono e redrive; sem alarme, é cemitério com mensalidade.
- Backlog: lag por partição e idade da mais antiga; drena a `backlog / (vazão − chegada)`.

## A Lastro agora

Eventos em `cobrancas.eventos` (log compatível com Kafka, 12 partições, chave `cobranca_id`); entregas no `pg-notificacoes`, com lease, bulkhead por endpoint, nove tentativas em 69 horas, ordem por cobrança e DLQ no painel. A API nunca mais espera marketplace. O `create_task` do Carlos foi removido, e o garbage collector perdeu o emprego de entregador de webhook.

O Hornero ficou lento de novo na terça seguinte, e só o Hornero percebeu. A analista dele, pela primeira vez, ficou sem tempo para o crochê. Na mesma terça, o deploy das 16h reiniciou um worker exatamente entre o COMMIT de um Pix de R$ 870,00 e a publicação do evento: o ledger tem o pagamento, o tópico não tem nada, o Bazar nunca soube, e o pedido foi cancelado em 30 minutos. A Lastro aprendeu a entregar uma mensagem a qualquer um, desde que ela tenha sido enviada.

## Referências

- Apache Kafka, documentação: design (log, partições, consumer groups, semântica de entrega) e configurações de produtor, consumidor e tópico. https://kafka.apache.org/documentation/
- RabbitMQ, Consumer Acknowledgements and Publisher Confirms. https://www.rabbitmq.com/docs/confirms
- RabbitMQ, Dead Letter Exchanges. https://www.rabbitmq.com/docs/dlx
- Amazon SQS Developer Guide, visibility timeout e dead-letter queues. https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html
- Python, documentação do `asyncio.create_task` (referência fraca às tasks). https://docs.python.org/3/library/asyncio-task.html#asyncio.create_task
- Stripe, documentação de webhooks (retentativas por até três dias). https://docs.stripe.com/webhooks
- Jay Kreps, "The Log: What every software engineer should know about real-time data's unifying abstraction", 2013. https://engineering.linkedin.com/distributed-systems/log-what-every-software-engineer-should-know-about-real-time-datas-unifying
- AWS, Summary of the Amazon Kinesis Event in the Northern Virginia (US-EAST-1) Region, novembro de 2020. https://aws.amazon.com/message/11201/
