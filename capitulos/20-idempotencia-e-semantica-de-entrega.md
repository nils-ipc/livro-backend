# Idempotência e semântica de entrega

## Quatro sacos de ração e um gato chamado Almirante

Numa terça-feira chuvosa, Dona Lurdes recebeu em casa quatro sacos de ração de 15 kg. Ela tinha pedido um. O gato dela, Almirante, pesa 4 kg e come uns 60 gramas por dia, o que garante o estoque da casa até meados de 2029 (a conta é real; a paciência do Almirante com o mesmo sabor, não).

O caso é hipotético, e cada passo dele acontece todos os dias em algum lugar. Dona Lurdes tocou em "Repetir pedido" dentro do elevador. O servidor criou o pedido, cobrou o cartão e respondeu `201`. A resposta morreu entre o quarto e o quinto andar, e o aplicativo, depois de 10 segundos de silêncio, mandou de novo. Segundo pedido.

Depois, o worker de estoque leu a mensagem "pedido criado", reservou o saco e foi morto pelo orquestrador por excesso de memória antes de confirmar a mensagem. A fila, fiel ao contrato, entregou a mensagem a outro worker. Terceiro saco. O quarto veio de um retry do proxy, que ninguém da equipe sabia que existia.

Nenhum componente teve defeito. Cada um cumpriu à risca uma promessa razoável, e a soma das promessas razoáveis deu 60 kg de ração.

Qual garantia de entrega dá para pedir a uma rede que perde mensagens, e como se constrói um sistema em que repetir uma requisição deixa de criar um saco novo?

## O mecanismo

### O terceiro resultado de uma chamada remota

Uma chamada local termina de dois jeitos: retorna ou lança exceção. Uma chamada remota tem um terceiro resultado, o "não sei". Quando o timeout dispara, o cliente não tem como distinguir entre três situações: a requisição se perdeu na ida, o servidor está processando devagar, ou o servidor processou tudo e a resposta se perdeu na volta. As três produzem exatamente o mesmo silêncio.

Esse silêncio tem teorema. O problema dos dois generais (Akkoyunlu, Ekanadham e Huber, 1975; o nome é de Jim Gray, 1978) mostra que, num canal que pode perder mensagens, nenhum protocolo com número finito de mensagens garante que os dois lados saibam que o outro sabe. Cada confirmação precisa de uma confirmação da confirmação, e a última sempre pode se perder. O TCP, com todos os seus números de sequência, também fica sem saída: a conexão pode cair depois de o servidor gravar e antes de o cliente ler a resposta.

Diante do "não sei", o remetente tem duas escolhas, e cada uma define uma semântica de entrega.

### As promessas de entrega

***At-most-once*** (no máximo uma vez): o remetente envia e não repete. Nunca há duplicata; pode haver perda. É a semântica de um `POST` sem retry e de uma métrica enviada por UDP. Para um contador de visualizações, perder 0,01% das contagens passa despercebido. Para Dona Lurdes, significa nenhum saco em vez de quatro.

***At-least-once*** (pelo menos uma vez): o remetente repete até receber confirmação. Nunca há perda (enquanto alguém continuar tentando); pode haver duplicata. É a semântica padrão de quase toda fila e de todo cliente HTTP com retry. As filas padrão do Amazon SQS, por exemplo, documentam que uma mensagem pode ser entregue mais de uma vez.

Numa fila, a diferença entre as duas está só na posição de uma linha de código, o *acknowledgment* (a confirmação ao broker de que a mensagem foi tratada):

```python
# at-most-once: confirma antes de processar
msg = fila.receber()
msg.ack()
processar(msg)   # se o processo morrer aqui, a mensagem sumiu para sempre

# at-least-once: confirma depois de processar
msg = fila.receber()
processar(msg)   # se o processo morrer aqui, a mensagem volta para outro worker
msg.ack()
```

Na segunda versão, morrer entre `processar` e `ack` devolve a mensagem já processada. Nenhuma terceira posição do `ack` elimina os dois problemas, por mais que alguém tente no meio do `processar` (já tentaram). O capítulo 21 trata de acknowledgments e reentregas.

### Exactly-once, ou o que sobra quando se lê o contrato

***Exactly-once*** (exatamente uma vez) aparece em muito material de produto, e no sentido literal de entrega é impossível pelo argumento dos dois generais. O que os sistemas oferecem com esse nome é ***exactly-once processing***, ou efeito exatamente uma vez: a entrega continua at-least-once, e o processamento garante que a segunda cópia não muda nada. A fórmula por trás de toda promessa de exactly-once:

```text
efeito exatamente uma vez = entrega at-least-once + processamento idempotente (ou deduplicado)
```

O Apache Kafka é o exemplo mais citado. Desde a versão 0.11 (KIP-98, 2017), o produtor idempotente recebe do broker um *producer ID* e numera cada lote por partição; o broker descarta um lote cujo número de sequência já foi gravado. A partir do Kafka 3.0 (KIP-679), isso vem ligado por padrão (`enable.idempotence=true`, com `acks=all`). Além disso, as transações gravam as mensagens de saída e o *offset* consumido juntos, e consumidores com `isolation.level=read_committed` só enxergam o que foi confirmado.

O detalhe do contrato: isso vale para o caminho Kafka → processamento → Kafka. Se o processamento envia um e-mail, o e-mail sai duas vezes do mesmo jeito. O Kafka entrega exactly-once dentro do Kafka; o servidor SMTP nunca assinou esse contrato.

As filas FIFO do Amazon SQS usam o mesmo nome para outra coisa: deduplicam envios com o mesmo `MessageDeduplicationId` dentro de uma janela de 5 minutos. Um envio repetido 6 minutos depois entra como mensagem nova. A janela tem prazo, e a rede não sabe disso.

### Idempotência no sentido exato

Na matemática, uma função é idempotente quando `f(f(x)) = f(x)`: aplicar duas vezes dá o mesmo resultado que aplicar uma. `abs`, `sorted` e `str.lower` são idempotentes. `list.append` passa longe disso, e o Almirante tem quatro sacos de prova.

A RFC 9110 (seção 9.2.2) define para HTTP: um método é idempotente quando o efeito pretendido no servidor de várias requisições idênticas é o mesmo de uma só. `PUT`, `DELETE` e os métodos seguros (`GET`, `HEAD`, `OPTIONS`, `TRACE`) são idempotentes; `POST` e `PATCH` ficam de fora (o capítulo 2 trata de cada método). Dois detalhes passam batido. A definição fala do **efeito no estado**, e a resposta pode mudar: o primeiro `DELETE /pedidos/7` devolve `204`, o segundo `404`, e o pedido 7 está apagado nos dois casos. E ela é uma **promessa do servidor**, que o protocolo não verifica. Um `PUT` que faz `append` numa lista continua sendo um `PUT` para todo proxy e todo SDK do caminho, que vão repeti-lo com a certeza de quem leu a especificação.

### Operações que já nascem idempotentes

O jeito mais barato de lidar com duplicatas é escrever operações que não ligam para elas. A regra prática é gravar **estado absoluto** em vez de **delta**:

| Operação | Repetida 3 vezes | Idempotente? |
|----------|------------------|--------------|
| `UPDATE contas SET saldo = saldo + 10 WHERE id = 1` | +30 | Não |
| `UPDATE contas SET saldo = 110 WHERE id = 1` | 110 | Sim |
| `INSERT INTO pedidos (...) VALUES (...)` | 3 pedidos | Não |
| `INSERT ... ON CONFLICT (pedido_id) DO NOTHING` | 1 pedido | Sim |
| `UPDATE pedidos SET status = 'pago' WHERE id = 7 AND status = 'pendente'` | 1ª atualiza, demais `UPDATE 0` | Sim |
| `DELETE FROM sessoes WHERE id = 'abc'` | Apaga uma vez | Sim |
| Redis `INCR visitas` | +3 | Não |
| Redis `SADD curtidas:post9 u42` | 1 membro | Sim |

A transição condicionada (`WHERE status = 'pendente'`) é a mais versátil: numa máquina de estados em que cada transição exige o estado de origem, todo evento repetido vira `UPDATE 0`, que a aplicação trata como "já feito".

A pegadinha: idempotência protege contra a **repetição** da mesma operação e deixa passar a **reordenação** de operações diferentes. Se `preco = 50` sofre um retry atrasado que chega depois de `preco = 70`, o preço volta a 50, com duas operações impecavelmente idempotentes. A proteção é uma versão (`UPDATE ... SET preco = 70, versao = 8 WHERE id = 1 AND versao = 7`, ou `If-Match` com `ETag`): a escrita velha encontra a versão errada e não faz nada, a mesma lógica do fencing token do capítulo 18.

### Chaves de idempotência

"Crie um pedido" não tem forma natural idempotente: dois pedidos idênticos podem ser legítimos (dois gatos) ou uma duplicata (um gato e um elevador ruim). Só o cliente sabe qual dos dois aconteceu, então é ele quem precisa dizer.

A ***chave de idempotência*** (*idempotency key*) é esse aviso: um identificador único que o cliente gera **uma vez por intenção** e reenvia igual em cada tentativa. A Stripe popularizou o cabeçalho `Idempotency-Key`, e um rascunho da IETF no grupo `httpapi` padroniza o comportamento:

- O cliente gera a chave (um UUID, tipicamente) antes da primeira tentativa e a guarda até receber uma resposta definitiva.
- O servidor grava a chave junto com uma impressão digital da requisição (um hash do corpo) e o resultado.
- Requisição repetida com a mesma chave e o mesmo corpo recebe a resposta gravada, sem reexecutar nada.
- Mesma chave com corpo diferente: erro `422`, porque devolver a resposta antiga em silêncio seria pior.
- Mesma chave enquanto a primeira ainda está em execução: erro `409`.
- Chave ausente num endpoint que a exige: `400`.

A Stripe documenta que guarda o status e o corpo da primeira execução, inclusive quando ela termina em `500`, e que as chaves podem ser removidas depois de pelo menos 24 horas. O cliente que repete depois disso cria uma operação nova: a janela de retry do cliente precisa caber dentro da retenção do servidor.

O ponto delicado é a atomicidade entre "gravei a chave" e "fiz o efeito". Se os dois moram no mesmo banco, uma transação resolve. No PostgreSQL, o `INSERT ... ON CONFLICT DO NOTHING` na tabela de chaves ainda trata a concorrência de graça: uma segunda transação com a mesma chave **espera** no índice único pelo resultado da primeira. Se a primeira confirmar, o `ON CONFLICT` dispara e a segunda lê a resposta gravada; se desfizer, a segunda executa normalmente. Ninguém escreve um lock, e o banco serializa os dois gêmeos sozinho.

Quando o efeito sai do banco (cobrar num gateway, enviar um SMS), nenhuma transação cobre os dois lados (o problema da escrita dupla, tema do capítulo 22). O padrão usa estados explícitos: a chave nasce `em_andamento` numa transação curta, a chamada externa leva **uma chave de idempotência derivada** (o gateway também precisa deduplicar), e a chave passa a `concluida` com a resposta. Se o processo morrer no meio, o próximo retry pode retomar com segurança justamente porque a chamada ao gateway também é idempotente. Brandur Leach descreveu esse desenho, com pontos de recuperação por etapa, num artigo de 2017.

### Deduplicação no consumidor

No consumidor de mensagens, o problema é o mesmo. Cada mensagem carrega um identificador estável atribuído pelo produtor (o broker pode gerar outro ID na reentrega). O consumidor mantém uma tabela de mensagens processadas, e a ordem entre "marcar" e "processar" decide a semântica, de novo:

- Marcar e depois processar: um crash entre as duas deixa a mensagem marcada e não processada. At-most-once com passos extras.
- Processar e depois marcar: um crash entre as duas reprocessa. At-least-once com passos extras.
- Marcar e processar **na mesma transação**: a marcação e o efeito são confirmados juntos. Efeito exatamente uma vez, desde que o efeito more no mesmo banco.

Marcar num Redis com `SET NX EX` e gravar o efeito no PostgreSQL recria a primeira ou a segunda linha, conforme a ordem: dois armazenamentos não compartilham transação. Esse arranjo é o *inbox*; o espelho dele no produtor, o *outbox*, está no capítulo 22.

## Na prática

### Uma API de pedidos que reconhece a repetição

A tabela de chaves usa o cliente na chave primária. Uma chave sem escopo de cliente deixaria o cliente B, por coincidência ou de propósito, receber a resposta gravada do pedido do cliente A:

```sql
CREATE TABLE chaves_idempotencia (
    cliente_id  bigint      NOT NULL,
    chave       text        NOT NULL,
    impressao   text        NOT NULL,
    status_http smallint,
    resposta    jsonb,
    criada_em   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (cliente_id, chave)
);
```

O endpoint, em FastAPI com psycopg 3, faz tudo numa única transação, porque o efeito (o pedido) mora no mesmo banco:

```python
import hashlib
import json
import os

import psycopg
from fastapi import FastAPI, Header, Request
from fastapi.responses import JSONResponse
from psycopg.types.json import Jsonb

app = FastAPI()
DSN = os.environ["DATABASE_URL"]


@app.post("/pedidos")
async def criar_pedido(request: Request, idempotency_key: str = Header(max_length=255)):
    corpo = await request.body()
    impressao = hashlib.sha256(corpo).hexdigest()
    cliente = request.state.cliente_id  # preenchido pelo middleware de autenticação

    async with await psycopg.AsyncConnection.connect(DSN) as conn:
        async with conn.transaction():
            cur = await conn.execute(
                """INSERT INTO chaves_idempotencia (cliente_id, chave, impressao)
                   VALUES (%s, %s, %s)
                   ON CONFLICT DO NOTHING
                   RETURNING chave""",
                (cliente, idempotency_key, impressao),
            )
            if await cur.fetchone() is None:
                # chave já existia: devolve o que foi gravado, sem criar saco novo
                return await repetir_resposta(conn, cliente, idempotency_key, impressao)

            pedido = json.loads(corpo)
            cur = await conn.execute(
                "INSERT INTO pedidos (cliente_id, produto, kg) VALUES (%s, %s, %s) RETURNING id",
                (cliente, pedido["produto"], pedido["kg"]),
            )
            (pedido_id,) = await cur.fetchone()
            resposta = {"pedido_id": pedido_id, "produto": pedido["produto"], "kg": pedido["kg"]}
            await conn.execute(
                """UPDATE chaves_idempotencia SET status_http = 201, resposta = %s
                   WHERE cliente_id = %s AND chave = %s""",
                (Jsonb(resposta), cliente, idempotency_key),
            )
    return JSONResponse(resposta, status_code=201)


async def repetir_resposta(conn, cliente, chave, impressao):
    cur = await conn.execute(
        """SELECT impressao, status_http, resposta FROM chaves_idempotencia
           WHERE cliente_id = %s AND chave = %s""",
        (cliente, chave),
    )
    impressao_original, status_http, resposta = await cur.fetchone()
    if impressao_original != impressao:
        return JSONResponse({"erro": "Idempotency-Key reutilizada com outro corpo"}, status_code=422)
    return JSONResponse(resposta, status_code=status_http, headers={"Idempotent-Replayed": "true"})
```

O `SELECT` de `repetir_resposta` enxerga a linha da outra transação porque, em `READ COMMITTED`, cada comando tira um snapshot novo (capítulo 10). O `409` nunca aparece: a requisição concorrente espera no índice único e recebe a resposta pronta, sem saber que ficou na fila atrás da própria gêmea.

O pedido original, com cabeçalhos resumidos:

```bash
curl -s -i -X POST https://api.exemplo.com/pedidos \
  -H "Authorization: Bearer $TOKEN" \
  -H "Idempotency-Key: 6f1c2a9e-3b7d-4e1a-9c55-0d2f8b7a1e33" \
  -H "Content-Type: application/json" \
  -d '{"produto": "racao-salmao", "kg": 15}'
```

```text
HTTP/1.1 201 Created
content-type: application/json

{"pedido_id":48213,"produto":"racao-salmao","kg":15}
```

A mesma chamada, repetida pelo aplicativo depois do elevador:

```text
HTTP/1.1 201 Created
content-type: application/json
idempotent-replayed: true

{"pedido_id":48213,"produto":"racao-salmao","kg":15}
```

Mesmo `pedido_id`, mesmo `201`, e a tabela `pedidos` continua com uma linha. Agora a mesma chave com `"kg": 30`, porque algum código reaproveitou a variável:

```text
HTTP/1.1 422 Unprocessable Entity
content-type: application/json

{"erro":"Idempotency-Key reutilizada com outro corpo"}
```

A impressão é o hash do corpo bruto: o mesmo JSON com um espaço a mais recebe `422`. Um hash sobre forma canônica (`json.dumps(pedido, sort_keys=True)`) tolera isso; sem ela, o cliente precisa reenviar os mesmos bytes, o que um retry faz naturalmente.

### Um worker que ignora reentregas

O worker de separação de estoque grava a marcação e a reserva na mesma transação, e só confirma a mensagem à fila depois do commit:

```python
import logging

log = logging.getLogger("separacao")


def tratar(conn: psycopg.Connection, msg) -> None:
    with conn.transaction():
        cur = conn.execute(
            "INSERT INTO mensagens_processadas (mensagem_id) VALUES (%s) ON CONFLICT DO NOTHING",
            (msg.id,),
        )
        if cur.rowcount == 0:
            log.info("mensagem %s repetida, ignorada (o Almirante agradece)", msg.id)
        else:
            conn.execute(
                "INSERT INTO reservas (pedido_id, kg) VALUES (%s, %s)",
                (msg.corpo["pedido_id"], msg.corpo["kg"]),
            )
            log.info("mensagem %s processada, pedido %s reservado", msg.id, msg.corpo["pedido_id"])
    msg.ack()
```

O log de uma manhã em que o orquestrador matou o `worker-2` logo depois do commit e antes do `ack`:

```text
09:14:02 worker-2 mensagem ev-90311 processada, pedido 48213 reservado
09:14:02 worker-2 [processo encerrado: OOMKilled]
09:14:32 worker-5 mensagem ev-90311 repetida, ignorada (o Almirante agradece)
```

A reentrega veio 30 segundos depois (o tempo de invisibilidade da fila), achou a marcação e só fez o `ack` que faltava. Se o processo tivesse morrido antes do commit, não haveria marcação, e o `worker-5` faria a reserva do zero. Nos dois casos, uma reserva.

## Propriedades e custos

| Abordagem | Garante | Custa | Quando pesa |
|-----------|---------|-------|-------------|
| At-most-once | Nunca duplica | Perde mensagens na falha | Telemetria, notificações descartáveis, quando perder é mais barato que repetir |
| At-least-once sem deduplicação | Nunca perde | Duplica na falha | Operações naturalmente idempotentes (estado absoluto, `ON CONFLICT`, transição condicionada) |
| At-least-once + chave de idempotência | Efeito único por intenção do cliente | Uma escrita a mais por requisição, armazenamento das respostas, cliente que gera e guarda a chave | APIs públicas com efeito financeiro ou físico |
| At-least-once + deduplicação no consumidor | Efeito único por mensagem | Tabela de IDs, transação que cubra marcação e efeito | Consumidores de filas que escrevem no próprio banco |
| Transações do broker (Kafka) | Efeito único no caminho Kafka → Kafka | Latência do commit transacional, consumidores em `read_committed` | Processamento de streams sem efeito externo |

O armazenamento das chaves se estima em uma linha. Uma API com 200 `POST` por segundo grava 200 × 86.400 = 17,28 milhões de chaves por dia; com 1 KB por linha e retenção de 24 horas, são uns 17 GB permanentes de respostas que quase ninguém vai pedir de novo, mais índice, e um expurgo diário de 17 milhões de linhas (particionar por dia e fazer `DROP` de partição evita o `DELETE` gigante; ver capítulo 14). Guardar só o status e o ID do recurso, em vez da resposta inteira, corta uma ordem de grandeza. A latência extra é um `INSERT` num índice único, décimos de milissegundo, e a espera só aparece quando duas tentativas da mesma chave se sobrepõem, ou seja, com o cliente já em retry (o capítulo 19 trata do retry em si).

## Armadilhas e casos reais

**A chave gerada dentro do laço de retry.** É o erro mais comum, e anula toda a infraestrutura do servidor:

```python
# errado: cada tentativa vira uma intenção nova
for tentativa in range(4):
    chave = str(uuid.uuid4())
    resp = await cliente.post("/pedidos", json=pedido, headers={"Idempotency-Key": chave})

# certo: uma chave por clique em "Repetir pedido"
chave = str(uuid.uuid4())
for tentativa in range(4):
    resp = await cliente.post("/pedidos", json=pedido, headers={"Idempotency-Key": chave})
```

A primeira versão envia quatro chaves únicas, e o servidor cria quatro pedidos com toda a correção do mundo. Num aplicativo móvel, a chave precisa ser persistida: se o sistema operacional matar o processo no meio do retry, a próxima abertura gera outra.

**Deduplicação por conteúdo.** Rejeitar "pedido idêntico nos últimos 5 minutos" bloqueia o segundo saco legítimo de quem tem dois gatos e deixa passar a duplicata do sexto minuto. Só um identificador gerado no momento da intenção separa repetição de pedido novo.

**Chave sem escopo de cliente.** Com a chave primária só em `chave`, dois clientes com o mesmo valor colidem, e o segundo recebe a resposta do primeiro, com dados de outra pessoa. Vazamento de dados com cara de bug inofensivo.

**Retenção menor que a janela de retry.** Uma fila com retenção de 7 dias e uma tabela de mensagens processadas expurgada em 24 horas deixam passar a reentrega do quarto dia.

**`em_andamento` eterno.** Um processo que morre deixa a chave presa, e todo retry recebe `409` para sempre. A linha precisa de um carimbo de início e de uma regra de retomada após um prazo.

**Exactly-once usado com efeito externo.** Um consumidor Kafka transacional que chama um gateway de pagamentos pode chamá-lo duas vezes: a transação abortada é desfeita no Kafka, e a cobrança fica. O gateway precisa da sua própria chave, derivada de algo estável da mensagem (tópico, partição e offset, ou o ID do evento).

**Retry em camadas que ninguém mapeou.** O quarto saco de Dona Lurdes veio do proxy.

> **Na vida real:** a diretiva `proxy_next_upstream` do NGINX tenta outro servidor quando o primeiro falha. Desde a versão 1.9.13, requisições com métodos não idempotentes (`POST`, `LOCK`, `PATCH`) deixam de ser repassadas ao próximo servidor depois de enviadas a um upstream, a menos que a opção `non_idempotent` seja ligada explicitamente. Quem liga `non_idempotent` "para melhorar a disponibilidade" está encomendando ração para 2029.

## Resumo

- Chamada remota: sucesso, falha ou "não sei", e nenhum protocolo cura o "não sei".
- At-most-once pode perder; at-least-once pode duplicar. Numa fila, a diferença é a posição do `ack`.
- Exactly-once real é efeito único: at-least-once mais processamento idempotente ou deduplicado. O do Kafka vale dentro do Kafka.
- Idempotência (RFC 9110) trata do efeito no estado; reordenação pede versão.
- Chave de idempotência: uma por intenção, com escopo de cliente, impressão do corpo, resposta gravada e retenção maior que a janela de retry.
- No consumidor, marcação e efeito na mesma transação; efeito externo leva a chave adiante.

## Referências

- RFC 9110, *HTTP Semantics*, seção 9.2.2 (métodos idempotentes): <https://www.rfc-editor.org/rfc/rfc9110#section-9.2.2>
- IETF, rascunho *The Idempotency-Key HTTP Header Field* (grupo httpapi): <https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/>
- Stripe, *Idempotent requests*: <https://docs.stripe.com/api/idempotent_requests>
- Brandur Leach, *Implementing Stripe-like Idempotency Keys in Postgres* (2017): <https://brandur.org/idempotency-keys>
- KIP-98, *Exactly Once Delivery and Transactional Messaging*: <https://cwiki.apache.org/confluence/display/KAFKA/KIP-98+-+Exactly+Once+Delivery+and+Transactional+Messaging>
- KIP-679, *Producer will enable the strongest delivery guarantee by default*: <https://cwiki.apache.org/confluence/display/KAFKA/KIP-679%3A+Producer+will+enable+the+strongest+delivery+guarantee+by+default>
- Amazon SQS, *Exactly-once processing in Amazon SQS* (filas FIFO): <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues-exactly-once-processing.html>
- NGINX, diretiva `proxy_next_upstream`: <https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_next_upstream>
- PostgreSQL, `INSERT ... ON CONFLICT`: <https://www.postgresql.org/docs/current/sql-insert.html>
- Jim Gray, *Notes on Data Base Operating Systems* (1978), em *Operating Systems: An Advanced Course*, Springer, LNCS 60.
