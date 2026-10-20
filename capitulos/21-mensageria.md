# Mensageria

## Três canecas e um papagaio

Seu Valdemar abriu a porta numa segunda-feira de manhã e recebeu três canecas idênticas com a foto do papagaio dele, o Comandante, de óculos escuros. Ele tinha comprado uma. A loja (situação hipotética) mandou também três notas fiscais, o que pelo menos manteve a contabilidade coerente com o estoque.

A API gravava o pedido e publicava uma mensagem numa fila gerenciada. Workers liam a fila, renderizavam a arte em alta resolução e mandavam o arquivo para a impressora. A fila estava na configuração padrão, que dá ao worker 30 segundos para terminar; a renderização levava 12 em média.

A foto do Comandante tinha 48 megapixels, porque o sobrinho do Seu Valdemar tem uma câmera nova e muito entusiasmo. A renderização levou 41 segundos. Aos 30, a fila concluiu que o primeiro worker tinha morrido e entregou a mesma mensagem a um segundo. Aos 60, a um terceiro. Os três imprimiram e gravaram no log `caneca impressa com sucesso`. O log estava certo três vezes.

Nenhum componente falhou; o defeito estava na conversa entre a fila e os consumidores. A pergunta do capítulo: como um sistema de mensageria decide que uma mensagem foi processada, e o que ele faz quando decide errado?

## Fila e log, os dois jeitos de guardar uma mensagem

Um *broker* de mensagens recebe mensagens de produtores, guarda e entrega a consumidores. O produtor publica e segue a vida; o consumidor processa quando puder, mesmo que estivesse fora do ar na publicação. Existem dois modelos de armazenamento.

Na **fila**, cada mensagem existe para ser consumida uma vez e apagada. O broker mantém estado por mensagem: pronta, entregue aguardando confirmação, confirmada (e removida). O RabbitMQ e o Amazon SQS seguem esse modelo. No RabbitMQ (protocolo AMQP 0-9-1), o produtor publica numa *exchange*, e *bindings* decidem para quais filas a mensagem é copiada.

No **log**, cada partição é uma sequência só de acréscimo, e toda mensagem recebe um *offset*, um inteiro crescente. Consumir não apaga nada: as mensagens ficam até vencer a retenção (no Kafka, `retention.ms` tem padrão de 7 dias). Por consumidor, o broker só precisa saber um número por partição: o próximo offset a ler.

Essa estrutura é o WAL de um banco de dados exposto como produto. A réplica de um PostgreSQL também lê um log de acréscimo e guarda só até onde já aplicou (capítulo 13). Jay Kreps, um dos criadores do Kafka, escreveu em 2013 um artigo inteiro sobre essa relação.

Com um bug no consumidor, num log você corrige, volta o offset para a semana passada e reprocessa. Numa fila, as mensagens confirmadas já eram, e sobra uma conversa constrangedora com o time de dados.

As fronteiras borraram: o RabbitMQ ganhou os *streams* (3.9), que são logs, e o Kafka ganhou os *share groups* (KIP-932), com semântica de fila, em acesso antecipado no 4.0. Por isso o capítulo fala de modelos, com os produtos como exemplos.

## Acknowledgment, ou como o consumidor diz "terminei"

O *acknowledgment* (*ack*) é o aviso do consumidor ao broker de que terminou de processar. Ele existe porque o broker não enxerga dentro do worker. Cada broker implementa o ack de um jeito, e cada jeito tem sua forma própria de produzir canecas extras.

### RabbitMQ: ack por conexão

O RabbitMQ entrega mensagens por um canal dentro de uma conexão TCP de longa duração. Cada entrega carrega um *delivery tag*, e o consumidor responde com `basic.ack` (terminei) ou `basic.nack`/`basic.reject` (falhei, devolvendo ou não à fila). Enquanto o ack não chega, a mensagem fica reservada, sem prazo por mensagem.

O sinal de morte é a conexão. Se ela fecha com mensagens sem ack, o broker devolve todas à fila com o campo `redelivered` ligado. O limite de segurança é o `consumer_timeout`, de 30 minutos por padrão. Um worker que renderiza por 41 segundos com a conexão viva nunca perde a mensagem, e o Comandante teria chegado em uma caneca só.

O *prefetch* (`basic.qos`) limita quantas mensagens sem ack um consumidor pode ter. Com prefetch 1, a próxima só vem depois do ack da anterior. Com prefetch 0 (ilimitado), o primeiro consumidor a se conectar recebe a fila inteira na memória, enquanto os outros dezenove workers assistem. No modo *auto-ack*, a mensagem conta como confirmada ao ser enviada: at-most-once em estado puro.

### SQS: ack por prazo

O SQS conversa por HTTP, sem conexão persistente, então usa um prazo. Quando `ReceiveMessage` devolve uma mensagem, ela fica invisível para os outros durante o *visibility timeout* (padrão de 30 segundos, máximo de 12 horas). Se o consumidor chama `DeleteMessage` com o *receipt handle* dentro do prazo, ela é removida. Se o prazo vence, ela reaparece para o próximo que pedir.

```text
SQS:      Mensagem 3f9a para você, worker-1. Você tem 30 segundos.
Worker-1: (renderizando o Comandante em 48 megapixels)
SQS:      ...
SQS:      Worker-1 morreu, coitado. Worker-2, mensagem 3f9a para você.
Worker-1: Pronto! Mandando para a impressora.
Worker-2: Pronto! Mandando para a impressora.
```

A fila não distingue worker lento de worker morto, pelo mesmo motivo que um cliente HTTP não distingue servidor lento de servidor fora do ar (o capítulo 19 trata desse "não sei"). O consumidor pode estender o prazo com `ChangeMessageVisibility`, um *heartbeat* durante trabalhos longos, ou zerá-lo para devolver a mensagem na hora, que é o nack do SQS.

### Kafka: ack por posição

O Kafka não tem ack por mensagem. O consumidor faz *commit* de um offset por partição, gravado no tópico interno `__consumer_offsets`. O commit do offset 815 significa "processei tudo antes de 815". Se a 812 está demorando e a 813 já terminou, não há como confirmar só a 813.

Commit antes de processar dá at-most-once; depois, at-least-once (capítulo 20). O padrão `enable.auto.commit=true` confirma, a cada 5 segundos e dentro do `poll()`, os offsets do poll anterior. Se o laço entrega as mensagens para threads e volta direto ao `poll()`, ele confirma trabalho que nem começou.

O prazo do Kafka tem outro nome. Se o consumidor passa mais de `max.poll.interval.ms` (padrão de 5 minutos) sem chamar `poll()`, ele é expulso do grupo, e outro consumidor reprocessa tudo depois do último commit. É a caneca tripla com outra configuração.

Nos três modelos, a configuração que não perde mensagens entrega pelo menos uma vez, e o consumidor precisa ser idempotente. Para o Seu Valdemar, isso significa um prazo compatível com a renderização, um heartbeat para as fotos gigantes e uma tabela `impressoes` com `UNIQUE (pedido_id)` gravada antes da impressão.

## Consumidores concorrentes e consumer groups

Numa fila, o paralelismo vem de *consumidores concorrentes* (*competing consumers*): qualquer número de workers lê a mesma fila, e cada mensagem vai para um deles. Para dobrar a vazão, você dobra os workers, sem redistribuição a negociar, porque nenhum worker é dono de nada. O teto passa a ser o broker e o banco que os workers martelam.

No Kafka, um *consumer group* divide as partições de um tópico entre seus consumidores, cada partição atribuída a exatamente um. O paralelismo máximo é o número de partições. Com 12 partições e 20 consumidores, oito ficam ociosos, recebendo salário (em CPU) para olhar o teto.

Partições podem aumentar, nunca diminuir. Quando um consumidor entra ou sai, as partições são redistribuídas num *rebalance*. No protocolo original (*eager*), todos largam tudo e esperam, uma pausa geral a cada deploy. O cooperativo (KIP-429) move só o necessário, e o do KIP-848, coordenado pelo broker, é estável desde o Kafka 4.0.

Grupos diferentes têm offsets independentes: `notificacoes` e `faturamento` leem o mesmo tópico, cada um no seu ritmo. Esse é o *fan-out* de graça do log. Numa fila, fan-out exige cópias: uma exchange `fanout` no RabbitMQ, ou um tópico gerenciado (Amazon SNS, Google Pub/Sub) entregando uma cópia a cada fila assinante.

## Ordem, a garantia que some quando você escala

No Kafka, a ordem só vale dentro de uma partição. O particionador padrão calcula o hash murmur2 da chave e tira o resto pelo número de partições: mesma chave, mesma partição, mesma ordem. Retries poderiam inverter lotes; o produtor idempotente, padrão desde o Kafka 3.0, numera os lotes e preserva a ordem.

Numa fila, o broker guarda em ordem FIFO, mas a ordem de processamento some com dois consumidores: a mensagem 1 vai para o worker A, a 2 para o B, e B termina primeiro. Reentregas embaralham mais. O cliente recebe "sua caneca foi enviada" antes de "recebemos seu pedido" e fica feliz e confuso na mesma proporção.

Ordem em fila tem custo explícito. O RabbitMQ tem o *single active consumer* (3.8): vários consumidores conectados, só um recebendo. O SQS padrão promete ordem por melhor esforço e pode duplicar. O SQS FIFO garante ordem por `MessageGroupId`: enquanto uma mensagem do grupo está em processamento, as seguintes não são entregues. O teto é de 300 transações por segundo por ação de API (3.000 mensagens com lotes de 10), maior no modo de alta vazão.

O custo comum é o *head-of-line blocking*: uma mensagem lenta segura todas as seguintes da mesma partição ou grupo. Ordem global exige uma partição só, ou seja, a vazão de um worker. Na prática, a chave é o que precisa de ordem: os eventos de um pedido, as transações de uma conta.

## Mensagem venenosa e dead letter queue

Uma *mensagem venenosa* (*poison message*) falha sempre: um JSON malformado, um campo que o código novo não espera, um TIFF de 48 MB que estoura a memória do worker. O último é o mais divertido: o processo morre por falta de memória, a mensagem volta, mata o worker seguinte, volta de novo, até a frota inteira reiniciar em sequência enquanto o painel de CPU mostra lindos 3%.

A defesa é limitar as tentativas e mover a mensagem para uma *dead letter queue* (DLQ), onde ela espera por um humano.

- No SQS, a *redrive policy* define o `maxReceiveCount`; passou disso, a mensagem vai para a DLQ.
- No RabbitMQ, uma *dead letter exchange* (`x-dead-letter-exchange`) recebe mensagens rejeitadas sem devolução, com TTL vencido, descartadas por limite de tamanho e, nas *quorum queues*, acima do limite de entregas (`x-delivery-limit`, padrão 20 desde o RabbitMQ 4.0).
- No Kafka, o broker não tem DLQ: o consumidor publica num tópico como `pedidos.dlq` e faz commit. O Kafka Connect oferece isso com `errors.deadletterqueue.topic.name`.

Erro permanente (validação, formato) vai direto para a DLQ, porque tentar de novo só gasta CPU. Erro transitório (timeout, `503`) merece retry com backoff e jitter (capítulo 19). No Kafka, retry dentro do consumidor bloqueia a partição, por isso é comum usar tópicos de retry com atraso crescente.

Uma DLQ sem alarme é um cemitério. Toda empresa com mais de dois anos tem uma com 41 mil mensagens de 2022, que alguém vai olhar "na semana que vem". Ela precisa de alarme e de caminho de volta (o *redrive* do SQS).

## Backlog, a fila que cresce

*Backlog* é o que está esperando para ser processado. No Kafka, a medida é o *consumer lag* por partição: o offset final do log menos o offset confirmado pelo grupo. No SQS, as métricas são `ApproximateNumberOfMessagesVisible` e `ApproximateAgeOfOldestMessage`.

A idade da mensagem mais antiga descreve o que o usuário sente. Um backlog de 50 mil mensagens são 10 segundos de atraso a 5 mil por segundo, ou quase três horas a 5 por segundo. Pela Lei de Little (capítulo 6), a espera média é `W = L / λ`. O tempo para zerar um backlog é:

```text
T = backlog / (taxa_de_consumo − taxa_de_produção)
```

Se o consumo não supera a produção, T é infinito, e o backlog só para de crescer quando a retenção começa a apagar mensagens. O SQS retém por 4 dias por padrão (máximo de 14). No Kafka, quando o lag ultrapassa a retenção, os segmentos somem por baixo do consumidor, o offset dele deixa de existir e entra em ação o `auto.offset.reset`, cujo padrão é `latest`: o consumidor pula para o fim do log, sem erro, sem exceção, sem contar a ninguém.

Uma fila absorve picos, e também esconde sobrecarga: sem limite, ela transforma "o sistema não aguenta" em "o sistema responde em quatro horas" (o capítulo 28 trata de backpressure). O RabbitMQ, ao atingir os alarmes de memória ou disco, bloqueia os produtores com `connection.blocked`.

## Na prática

### Um consumidor de SQS que não imprime três canecas

O consumidor usa *long polling* (`WaitTimeSeconds=20`: espera até 20 segundos em vez de responder vazio), estende o prazo com heartbeat e só apaga no fim.

```python
import os
import threading

import boto3

sqs = boto3.client("sqs")
FILA = os.environ["FILA_CANECAS_URL"]


def manter_viva(recibo: str, parar: threading.Event) -> None:
    # A cada 20 s, pede mais 60 s de invisibilidade
    while not parar.wait(20):
        sqs.change_message_visibility(
            QueueUrl=FILA, ReceiptHandle=recibo, VisibilityTimeout=60
        )
        print("heartbeat: ainda vivo, só lento")


def consumir() -> None:
    while True:
        resp = sqs.receive_message(
            QueueUrl=FILA,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,
            VisibilityTimeout=60,
            MessageSystemAttributeNames=["ApproximateReceiveCount"],
        )
        for msg in resp.get("Messages", []):
            recibo = msg["ReceiptHandle"]
            tentativa = msg["Attributes"]["ApproximateReceiveCount"]
            print(f"recebida {msg['MessageId'][:8]} (tentativa {tentativa})")
            parar = threading.Event()
            batimento = threading.Thread(target=manter_viva, args=(recibo, parar))
            batimento.start()
            try:
                renderizar_e_imprimir(msg["Body"])  # idempotente por pedido_id
                sqs.delete_message(QueueUrl=FILA, ReceiptHandle=recibo)
                print("apagada: uma caneca, um papagaio")
            except Exception as erro:
                # Sem delete: a mensagem volta quando o prazo vencer
                print(f"falhou ({erro!r}); fica para a próxima tentativa")
            finally:
                parar.set()
                batimento.join()
```

Com a foto do Comandante, dois heartbeats e uma entrega:

```text
recebida 3f9a1c2e (tentativa 1)
heartbeat: ainda vivo, só lento
heartbeat: ainda vivo, só lento
apagada: uma caneca, um papagaio
```

O heartbeat cobre o worker lento; o prazo continua cobrindo o morto, porque ninguém estende nada e a mensagem reaparece em até 60 segundos. A idempotência de `renderizar_e_imprimir` cobre o resto: o heartbeat que falha por um problema de rede no segundo errado.

### Ordem por chave no Kafka

O produtor publica eventos de dois pedidos com o ID como chave, usando `confluent-kafka`.

```python
import json
import os

from confluent_kafka import Producer

produtor = Producer({
    "bootstrap.servers": os.environ["KAFKA_SERVERS"],
    "enable.idempotence": True,
    "acks": "all",
})


def confirmado(erro, msg) -> None:
    status = json.loads(msg.value())["status"]
    print(f"{msg.key().decode()} {status:<8} -> partição {msg.partition()}, offset {msg.offset()}")


eventos = [
    ("ped-1001", "criado"), ("ped-2002", "criado"), ("ped-1001", "pago"),
    ("ped-1001", "enviado"), ("ped-2002", "pago"),
]
for pedido, status in eventos:
    produtor.produce(
        "pedidos",
        key=pedido,
        value=json.dumps({"pedido": pedido, "status": status}),
        on_delivery=confirmado,
    )
produtor.flush()
```

```text
ped-2002 criado   -> partição 1, offset 377
ped-2002 pago     -> partição 1, offset 378
ped-1001 criado   -> partição 4, offset 812
ped-1001 pago     -> partição 4, offset 813
ped-1001 enviado  -> partição 4, offset 814
```

Os eventos de `ped-1001` caíram todos na partição 4, em ordem; entre os dois pedidos não há ordem nenhuma. O consumidor desliga o commit automático e confirma depois de processar:

```python
from confluent_kafka import Consumer

consumidor = Consumer({
    "bootstrap.servers": os.environ["KAFKA_SERVERS"],
    "group.id": "notificacoes",
    "enable.auto.commit": False,
    "auto.offset.reset": "earliest",
})
consumidor.subscribe(["pedidos"])

while True:
    msg = consumidor.poll(1.0)
    if msg is None:
        continue
    if msg.error():
        print(f"erro do consumidor: {msg.error()}")
        continue
    notificar_cliente(json.loads(msg.value()))
    consumidor.commit(message=msg, asynchronous=False)
    print(f"p{msg.partition()} offset {msg.offset()} notificado; commit em {msg.offset() + 1}")
```

```text
p4 offset 812 notificado; commit em 813
p4 offset 813 notificado; commit em 814
p4 offset 814 notificado; commit em 815
p1 offset 377 notificado; commit em 378
p1 offset 378 notificado; commit em 379
```

O commit grava o offset da próxima mensagem, daí o "+1". Com `earliest`, um grupo sem offset válido começa do início da retenção. O commit síncrono custa uma ida e volta ao broker por evento; com vazão alta, o commit é por lote.

### Quanto tempo o backlog leva para zerar

Na Black Friday, a fila acumulou 1,8 milhão de pedidos. Entram 300 por segundo, e cada worker processa 25.

```python
def tempo_para_zerar(backlog: int, consumo: float, producao: float) -> float | None:
    folga = consumo - producao
    return backlog / folga if folga > 0 else None


for workers in (12, 20, 40):
    t = tempo_para_zerar(1_800_000, consumo=workers * 25, producao=300)
    print(f"{workers:>2} workers: " + (f"{t / 60:.0f} min" if t else "nunca"))
```

```text
12 workers: nunca
20 workers: 150 min
40 workers: 43 min
```

Com 12 workers o consumo empata com a entrada e o backlog nunca diminui. Dobrar de 20 para 40 corta o tempo em mais de três vezes, porque a folga sobe de 200 para 700 por segundo. A conta supõe que a impressora acompanha, e a impressora, que tem uma cabeça só, discorda.

## Propriedades e custos

| Propriedade | RabbitMQ (fila) | SQS padrão / FIFO | Kafka (log) |
|---|---|---|---|
| Após o ack | Apagada | Apagada | Fica até a retenção |
| Reprocessar | Impossível | Impossível | Voltar o offset |
| Consumidor morto | Conexão fecha | Prazo vence | Sessão ou `max.poll.interval.ms` |
| Ack | Por mensagem | Por mensagem | Por posição |
| Paralelismo | Consumidores | Consumidores | Partições |
| Ordem | Um consumidor ativo | Melhor esforço / `MessageGroupId` | Por partição |
| Fan-out | Exchange copia | Tópico copia | Grupos, sem cópia |
| DLQ | Dead letter exchange | Redrive policy | Consumidor publica |
| Operação | Cluster próprio | Sem servidor | Cluster próprio ou gerenciado |

Reprocessar o passado importa quando vários sistemas derivam dados do mesmo fluxo ou quando um bug precisa ser corrigido retroativamente. O ack por mensagem importa quando o tempo de processamento varia muito, porque uma mensagem lenta numa partição segura o commit das seguintes. Paralelismo por partição exige decidir o número de partições antes do pico; por consumidor, ajusta-se no autoscaling. E "nenhum servidor" pesa quando o time tem três pessoas e nenhuma quer ser chamada às 3h da manhã por causa do broker.

## Armadilhas e casos reais

> **Armadilha:** gravar o pedido no banco e publicar a mensagem são duas escritas sem transação entre elas. Se o processo morre no meio, o pedido existe e a caneca nunca é impressa; na ordem inversa, a caneca sai para um pedido que deu rollback. O padrão outbox resolve isso (capítulo 22).

**`auto.offset.reset=latest` num grupo novo.** Sem offset gravado, ele começa no fim do log. Quem cria um consumidor para "processar o histórico" e esquece essa configuração ganha um histórico vazio e um consumidor muito eficiente.

**A DLQ que expira antes de você olhar.** Nas filas padrão do SQS, a expiração conta a partir da entrada na fila de origem, mesmo depois da mudança para a DLQ. Uma mensagem que passou três dias e meio falhando numa fila com retenção de 4 dias chega à DLQ com meio dia de vida. A retenção da DLQ precisa ser maior que a da origem.

**Aumentar partições quebra a ordem.** Com 12 partições, `ped-1001` vai para a 4; com 16, pode cair na 9. Durante a transição, dois consumidores processam o mesmo pedido em paralelo.

**Mensagens grandes.** Brokers limitam o tamanho da mensagem (no Kafka, `message.max.bytes` fica em cerca de 1 MB por padrão). A foto do Comandante vai para um armazenamento de objetos, e a mensagem carrega só a referência. O padrão se chama *claim check* e evita que o broker vire servidor de arquivos de 48 megapixels.

> **Na vida real:** em 25 de novembro de 2020, o Amazon Kinesis Data Streams (um log particionado gerenciado) ficou horas fora do ar em us-east-1. Uma adição de capacidade à frota de front-end fez o número de threads de cada servidor (uma por servidor da frota) passar do limite configurado no sistema operacional. Cognito, CloudWatch e outros serviços dependentes caíram em cascata. O broker estava ali para desacoplar sistemas e acabou acoplando todos a ele.

## Resumo

- Fila apaga após o ack e guarda estado por mensagem; log guarda até a retenção, e o consumidor guarda um offset por partição.
- Consumidor morto: RabbitMQ percebe pela conexão, SQS pelo visibility timeout, Kafka pela sessão e por `max.poll.interval.ms`. Todos reentregam.
- Sem perda significa pelo menos uma vez: consumidor idempotente.
- Fila escala por consumidores concorrentes; Kafka, até o número de partições, com offsets por consumer group.
- Ordem só por partição ou grupo de mensagens, ao custo de head-of-line blocking.
- Mensagem venenosa vai para a DLQ após um limite de tentativas; DLQ precisa de alarme.
- Backlog se mede pela idade da mensagem mais antiga; zerar leva `backlog / (consumo − produção)`.

## Referências

- RabbitMQ, "Consumer Acknowledgements and Publisher Confirms": https://www.rabbitmq.com/docs/confirms
- RabbitMQ, "Dead Letter Exchanges": https://www.rabbitmq.com/docs/dlx
- RabbitMQ, "Quorum Queues": https://www.rabbitmq.com/docs/quorum-queues
- Especificação AMQP 0-9-1: https://www.rabbitmq.com/resources/specs/amqp0-9-1.pdf
- Amazon SQS, "Visibility timeout": https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html
- Amazon SQS, "Dead-letter queues": https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html
- Amazon SQS, "FIFO queues": https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-fifo-queues.html
- Documentação do Apache Kafka: https://kafka.apache.org/documentation/
- KIP-429, Kafka Consumer Incremental Rebalance Protocol: https://cwiki.apache.org/confluence/display/KAFKA/KIP-429%3A+Kafka+Consumer+Incremental+Rebalance+Protocol
- KIP-848, The Next Generation of the Consumer Rebalance Protocol: https://cwiki.apache.org/confluence/display/KAFKA/KIP-848%3A+The+Next+Generation+of+the+Consumer+Rebalance+Protocol
- KIP-932, Queues for Kafka: https://cwiki.apache.org/confluence/display/KAFKA/KIP-932%3A+Queues+for+Kafka
- Jay Kreps, "The Log: What every software engineer should know about real-time data's unifying abstraction" (2013): https://engineering.linkedin.com/distributed-systems/log-what-every-software-engineer-should-know-about-real-time-datas-unifying
- Jay Kreps, Neha Narkhede e Jun Rao, "Kafka: a Distributed Messaging System for Log Processing", NetDB 2011.
- AWS, "Summary of the Amazon Kinesis Event in the Northern Virginia (US-EAST-1) Region": https://aws.amazon.com/message/11201/
