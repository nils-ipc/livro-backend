# Transações distribuídas

## Trinta e sete flamingos para ninguém

Às 9h14 de uma segunda-feira (hipotética, mas dolorosamente plausível), o depósito de uma loja on-line de artigos de piscina despachou 37 boias de flamingo para pedidos que não existiam. Os caminhões saíram, as etiquetas estavam impecáveis e o banco de dados jurava, com toda a convicção de um sistema ACID, que aqueles pedidos nunca tinham sido criados.

O código responsável tinha onze linhas e uma boa intenção:

```python
def criar_pedido(conn, produtor, pedido):
    with conn.transaction():
        conn.execute(
            "INSERT INTO pedidos (id, cliente_id, produto) VALUES (%s, %s, %s)",
            (pedido.id, pedido.cliente_id, pedido.produto),
        )
        # avisa o depósito o quanto antes, para agilizar
        produtor.produce("pedidos", key=str(pedido.id), value=pedido.json())
        produtor.flush()
        conn.execute(
            "UPDATE estoque SET qtd = qtd - 1 WHERE produto = %s", (pedido.produto,)
        )  # CHECK (qtd >= 0) falha aqui -> ROLLBACK
```

A mensagem foi para o Kafka no meio da transação. Depois, o `UPDATE` violou a restrição de estoque, o banco desfez tudo e o Kafka, que nunca participou da transação, continuou com a mensagem. O depósito leu, separou e embalou. O depósito é muito eficiente.

A correção da sexta seguinte (às 17h50, "é só mover uma linha") foi publicar depois do `COMMIT`. Na terça, o processo levou um `OOMKilled` entre o `COMMIT` e o `produce`. Dona Neide pagou por uma boia de flamingo, recebeu o e-mail de confirmação e nunca recebeu a boia, porque o depósito nunca soube que ela existia.

Os dois erros são o mesmo erro visto de lados opostos. Como fazer dois sistemas que não compartilham transação concordarem sobre o que aconteceu?

## Escrita dupla, ou duas transações fingindo ser uma

O problema tem nome: **escrita dupla** (*dual write*). Uma operação precisa alterar dois sistemas com atomicidades independentes (banco e broker, banco e cache, banco e gateway de pagamento), e o código altera um depois do outro.

Com dois sistemas e duas escritas, a tabela de resultados possíveis tem mais linhas do que você gostaria:

| Escrita no banco | Escrita no broker | Resultado |
|---|---|---|
| sucesso | sucesso | tudo certo (o caso que aparece no teste) |
| sucesso | falha | pedido existe, ninguém fica sabendo |
| falha | sucesso | evento sobre algo que não existe (flamingos) |
| sucesso | "não sei" | timeout: a mensagem pode ou não ter chegado |

A última linha é a mais traiçoeira. Uma chamada remota que estoura o timeout tem três desfechos (sucesso, falha e "não sei"), e o capítulo 20 mostra por que nenhum protocolo elimina o terceiro. Repetir a publicação resolve a falha e cria duplicatas; não repetir resolve as duplicatas e cria buracos.

Há ainda um defeito que dispensa falhas. Duas requisições gravam no banco o preço 10 e depois o 12, e cada uma atualiza o índice de busca em seguida; em paralelo, as escritas no índice chegam na ordem inversa. O banco diz 12, a busca diz 10, nenhum erro é registrado, e a divergência dura até alguém reclamar (o cliente que achou o produto mais barato raramente abre chamado).

## Two-phase commit, ou como pedir permissão duas vezes

A resposta clássica é o **two-phase commit** (2PC), descrito por Jim Gray em 1978 e padronizado para bancos e filas na especificação X/Open XA, de 1991. Ele faz várias bases de dados confirmarem ou desfazerem uma transação juntas.

Há um **coordenador** e vários **participantes** (cada banco ou fila envolvido). A aplicação faz as suas escritas em cada participante normalmente, dentro de transações locais ainda abertas. Na hora do commit, o coordenador conduz duas fases:

```text
Coordenador                Banco A            Banco B
    |---- PREPARE ------------>|                  |
    |---- PREPARE ------------------------------->|
    |<--- SIM (preparado) -----|                  |
    |<--- SIM (preparado) ------------------------|
    | grava "COMMIT" no log (ponto de decisão)    |
    |---- COMMIT ------------->|                  |
    |---- COMMIT -------------------------------->|
    |<--- ok ------------------|                  |
    |<--- ok -------------------------------------|
```

Na **fase 1**, cada participante recebe `PREPARE`, grava em disco tudo o que precisa para confirmar a transação (alterações e um registro de "preparado" no log, com `fsync`) e vota. Votar "sim" é uma promessa irrevogável: daqui em diante, o participante perdeu o direito de desistir sozinho. Se cair e voltar, ele relê o log e continua preparado, segurando os locks.

Na **fase 2**, o coordenador decide. Se todos votaram sim, ele grava "commit" no próprio log (esse registro é o instante em que a transação passa a existir) e manda `COMMIT` para todos. Se algum votou não ou não respondeu, manda `ROLLBACK`.

O custo: quatro mensagens por participante, duas idas e voltas e gravações forçadas em disco em todo mundo. Alguns milissegundos num datacenter; centenas entre regiões.

### O bloqueio, que é a parte que ninguém coloca no slide

O problema do 2PC mora num intervalo específico: depois que um participante votou sim e antes de ele receber a decisão. Nesse estado, chamado de **incerto** (*in doubt*), o participante não pode confirmar (talvez outro participante tenha votado não) e não pode desfazer (talvez o coordenador já tenha confirmado nos outros). Ele só pode esperar.

Se o coordenador cai exatamente aí, o participante espera até o coordenador voltar. Enquanto isso, as linhas que a transação alterou continuam travadas. Toda outra transação que precisar delas espera também. Um coordenador fora do ar por 40 minutos significa 40 minutos de linhas bloqueadas em bancos que estão perfeitamente saudáveis, conversando com um coordenador que não está lá.

```text
Banco A:     Votei sim. Qual é a decisão?
Coordenador: (reiniciando há 40 minutos)
Banco A:     Vou segurar estes 3 locks por enquanto.
Banco B:     Eu também votei sim.
Banco A:     O que o coordenador decidiu?
Banco B:     Também estou esperando.
```

Esse bloqueio é inerente ao protocolo. O three-phase commit (Skeen, 1981) evita o bloqueio supondo uma rede síncrona, com atrasos limitados, hipótese que redes reais não cumprem (o capítulo 19 trata disso). A saída que funciona na prática é replicar o coordenador com consenso: Gray e Lamport descrevem o Paxos Commit em 2006, e o Google Spanner faz 2PC em que cada participante é um grupo Paxos, de modo que a queda de uma máquina não deixa ninguém incerto. O capítulo 18 trata de consenso.

### 2PC no PostgreSQL

O PostgreSQL implementa o papel de participante com `PREPARE TRANSACTION`. O coordenador fica por sua conta (ou de um gerenciador de transações externo):

```sql
-- postgresql.conf: max_prepared_transactions = 10  (o padrão é 0: desligado)
BEGIN;
UPDATE estoque SET qtd = qtd - 1 WHERE produto = 'boia-flamingo';
PREPARE TRANSACTION 'pedido-4471';
-- a sessão pode até desconectar; a transação continua preparada

SELECT gid, prepared, owner FROM pg_prepared_xacts;
```

```text
     gid     |           prepared            |  owner
-------------+-------------------------------+---------
 pedido-4471 | 2026-10-19 09:14:02.118-03    | loja_app
(1 row)
```

Depois, `COMMIT PREPARED` ou `ROLLBACK PREPARED`, de qualquer sessão. A transação preparada sobrevive a reinícios, segura locks e impede o `VACUUM` de limpar versões antigas de linhas no banco inteiro. A documentação diz que o comando existe para gerenciadores de transação externos, e o motivo é esse: uma transação preparada esquecida segura o banco por tempo indefinido, e o `pg_prepared_xacts` vira uma lista de pendências que ninguém consulta.

A limitação prática do 2PC é mais simples: todos os participantes precisam falar o protocolo. Kafka usa um 2PC interno nas próprias transações, mas não participa de XA. Amazon SQS, Redis e a API do seu gateway de pagamento também não. O dono do gateway não vai deixar o seu coordenador segurar um lock na base dele enquanto reinicia.

## Sagas, ou como desfazer o que já foi feito

Quando não dá para travar tudo e confirmar junto, a alternativa é confirmar cada passo sozinho e saber desfazer. Hector Garcia-Molina e Kenneth Salem chamaram isso de **saga**, num artigo de 1987 sobre transações longas dentro de um único banco, que seguravam locks por horas.

Uma saga é uma sequência de transações locais T1, T2, ..., Tn, cada uma confirmada no seu próprio serviço. Para cada Ti (menos a última) existe uma **ação compensatória** Ci, que desfaz o efeito de Ti do ponto de vista do negócio. A garantia é que uma de duas sequências acontece:

```text
T1, T2, ..., Tn                    (tudo deu certo)
T1, T2, ..., Tj, Cj, ..., C2, C1   (Tj+1 falhou; compensa em ordem inversa)
```

Compensar é desfazer no plano do negócio, porque no plano dos dados não há mais nada para desfazer: Ti já foi confirmada e outras transações podem ter lido o resultado. Se T2 cobrou o cartão, C2 faz um estorno, que é uma nova transação com registro próprio no extrato. Se T3 mandou um e-mail de "pedido confirmado", C3 não tem como desmandar o e-mail. C3 manda outro, pedindo desculpas. A caixa de entrada do cliente é um log só de acréscimo.

Daí sai uma classificação útil dos passos:

- **Compensáveis**: têm Ci (reservar estoque, criar pedido como pendente).
- **Pivô**: o passo depois do qual a saga só anda para frente. Se ele confirmar, a saga vai até o fim. Costuma ser o passo mais difícil de desfazer, como a cobrança.
- **Repetíveis**: os passos depois do pivô, que precisam ter sucesso garantido com retries (agendar a entrega, mandar a confirmação).

Colocar o passo menos reversível como pivô e tudo o que pode falhar por regra de negócio antes dele reduz as compensações. Validar endereço depois de cobrar é um jeito caro de gerar estornos.

### O que a saga não garante: o I do ACID

Uma saga tem atomicidade (no sentido de "tudo ou compensado"), consistência e durabilidade. Isolamento ela não tem. Entre T1 e Cn, o mundo vê os estados intermediários. O estoque mostra o flamingo reservado de um pedido que vai ser cancelado em dois segundos; um relatório de vendas soma um pedido que nunca vai ser pago.

As contramedidas conhecidas (catalogadas por Lars Frank e Torben Zahle em 1998) tratam isso no modelo de dados. O **lock semântico** é um estado como `PENDENTE` no registro, que as outras operações sabem tratar (o relatório ignora, o cancelamento espera). As **atualizações comutativas**, como débito e crédito em vez de "saldo = X", dão o mesmo resultado em qualquer ordem, e a compensação não atropela uma escrita concorrente. E **reler antes de gravar** é o controle otimista com versão do capítulo 11.

### Orquestração e coreografia

Há duas formas de coordenar os passos.

Na **orquestração**, um componente central (o orquestrador) conhece a sequência, manda cada serviço fazer o seu passo e, em caso de falha, manda compensar. A saga inteira é uma máquina de estados num lugar só.

Na **coreografia**, não há centro. Cada serviço reage a eventos dos outros: o serviço de pedidos publica `PedidoCriado`, o de estoque reage, reserva e publica `EstoqueReservado`, o de pagamentos reage, cobra e publica `PagamentoAprovado` ou `PagamentoRecusado`, e o de estoque, ouvindo o recusado, libera a reserva.

Um orquestrador mínimo, em memória:

```python
from collections.abc import Callable
from dataclasses import dataclass


class PagamentoRecusado(Exception):
    pass


@dataclass
class Passo:
    nome: str
    executar: Callable[[dict], None]
    compensar: Callable[[dict], None] | None = None


def criar_pedido(ctx):     print(f"   pedido {ctx['pedido']} criado como PENDENTE")
def cancelar_pedido(ctx):  print(f"   pedido {ctx['pedido']} marcado como CANCELADO")
def reservar(ctx):         print("   1 boia-flamingo reservada")
def liberar(ctx):          print("   reserva liberada, flamingo volta para a prateleira")
def cobrar(ctx):           raise PagamentoRecusado("limite do cartão esgotado (boias)")
def agendar_entrega(ctx):  print("   entrega agendada")


def executar_saga(passos: list[Passo], ctx: dict) -> str:
    feitos: list[Passo] = []
    for passo in passos:
        print(f"-> {passo.nome}")
        try:
            passo.executar(ctx)
        except Exception as erro:
            print(f"!! {passo.nome} falhou: {erro}")
            for anterior in reversed(feitos):
                if anterior.compensar:
                    print(f"<- compensando {anterior.nome}")
                    anterior.compensar(ctx)
            return "COMPENSADA"
        feitos.append(passo)
    return "CONCLUIDA"


saga = [
    Passo("criar_pedido", criar_pedido, cancelar_pedido),
    Passo("reservar_estoque", reservar, liberar),
    Passo("cobrar_cartao", cobrar),          # pivô: sem compensação na saga
    Passo("agendar_entrega", agendar_entrega),
]
print(executar_saga(saga, {"pedido": 4471}))
```

```text
-> criar_pedido
   pedido 4471 criado como PENDENTE
-> reservar_estoque
   1 boia-flamingo reservada
-> cobrar_cartao
!! cobrar_cartao falhou: limite do cartão esgotado (boias)
<- compensando reservar_estoque
   reserva liberada, flamingo volta para a prateleira
<- compensando criar_pedido
   pedido 4471 marcado como CANCELADO
COMPENSADA
```

As compensações saem em ordem inversa. O código também tem o defeito que todo orquestrador real precisa corrigir: a lista `feitos` vive na memória. Se o processo morrer entre `reservar_estoque` e `cobrar_cartao`, o flamingo fica reservado para sempre, num pedido pendente que ninguém vai retomar. Um orquestrador real grava o estado da saga no banco a cada passo e retoma sagas paradas; motores de workflow duráveis (o Temporal e o AWS Step Functions são exemplos) existem para isso.

Em qualquer saga, passos e compensações precisam ser idempotentes, porque serão repetidos (o capítulo 20 trata disso). E uma compensação não pode falhar de forma definitiva: ela é repetida até dar certo. Um estorno recusado porque "o pedido já foi cancelado" deveria ser tratado como sucesso.

## Outbox, ou como publicar dentro de uma transação que não sabe publicar

Sagas coreografadas e qualquer serviço que publica eventos voltam ao problema da abertura: gravar no banco e publicar no broker. O **padrão outbox** (*transactional outbox*) resolve trocando a segunda escrita por uma escrita no mesmo banco.

A mensagem vai para uma tabela, na mesma transação que altera o estado:

```sql
CREATE TABLE outbox (
    id           uuid PRIMARY KEY,
    agregado     text        NOT NULL,
    agregado_id  bigint      NOT NULL,
    tipo         text        NOT NULL,
    payload      jsonb       NOT NULL,
    criado_em    timestamptz NOT NULL DEFAULT now(),
    publicado_em timestamptz
);
CREATE INDEX outbox_pendentes ON outbox (criado_em) WHERE publicado_em IS NULL;
```

```python
import json
import uuid

import psycopg


def criar_pedido(conn: psycopg.Connection, cliente_id: int, produto: str) -> int:
    with conn.transaction():
        pedido_id = conn.execute(
            "INSERT INTO pedidos (cliente_id, produto, status)"
            " VALUES (%s, %s, 'PENDENTE') RETURNING id",
            (cliente_id, produto),
        ).fetchone()[0]
        conn.execute(
            "UPDATE estoque SET qtd = qtd - 1 WHERE produto = %s", (produto,)
        )
        conn.execute(
            "INSERT INTO outbox (id, agregado, agregado_id, tipo, payload)"
            " VALUES (%s, 'pedido', %s, 'PedidoCriado', %s)",
            (uuid.uuid4(), pedido_id, json.dumps({"pedido_id": pedido_id, "produto": produto})),
        )
    return pedido_id
```

Agora a atomicidade é a do PostgreSQL: pedido, baixa no estoque e mensagem existem juntos ou não existem. Se o `CHECK` falhar, a mensagem some com o pedido, e nenhum flamingo sai para o nada.

Um processo separado, o **relay**, lê a tabela e publica:

```python
def publicar_lote(conn: psycopg.Connection, produtor, limite: int = 100) -> int:
    erros = []

    def ao_entregar(err, msg):
        if err is not None:
            erros.append(err)

    with conn.transaction():
        linhas = conn.execute(
            "SELECT id, agregado_id, tipo, payload FROM outbox"
            " WHERE publicado_em IS NULL ORDER BY criado_em LIMIT %s"
            " FOR UPDATE SKIP LOCKED",
            (limite,),
        ).fetchall()
        for evento_id, agregado_id, tipo, payload in linhas:
            produtor.produce(
                "pedidos",
                key=str(agregado_id),
                value=json.dumps(payload),
                headers={"evento_id": str(evento_id), "tipo": tipo},
                on_delivery=ao_entregar,
            )
        if produtor.flush(10) > 0 or erros:
            raise RuntimeError(f"broker não confirmou o lote: {erros[:3]}")  # ROLLBACK
        conn.execute(
            "UPDATE outbox SET publicado_em = now() WHERE id = ANY(%s)",
            ([linha[0] for linha in linhas],),
        )
    return len(linhas)
```

```text
09:14:02.311 relay: 3 eventos publicados (pedidos 4471, 4472, 4473)
09:14:02.812 relay: 0 eventos publicados
09:14:03.104 relay: broker não confirmou o lote: [KafkaError{code=_MSG_TIMED_OUT,val=-192,str="Local: Message timed out"}]
09:14:03.611 relay: 2 eventos publicados (pedidos 4474, 4475)
```

O relay só marca como publicado depois que o broker confirmou. Se ele morrer entre o `flush` e o `COMMIT`, o lote volta a ser pendente e é publicado de novo. A garantia resultante é at-least-once: nenhum evento se perde, alguns podem chegar duas vezes. Por isso cada mensagem leva um `evento_id`, e o consumidor deduplica por ele, com a marcação gravada na mesma transação do efeito (o padrão inbox, tratado no capítulo 20). O outbox resolve a perda; a duplicata continua sendo problema do consumidor, como sempre foi.

## Change data capture, ou ler o diário do banco

O relay por polling pergunta ao banco, a cada meio segundo, se há novidades. O **change data capture** (CDC) faz o contrário: lê as alterações direto do log de escrita antecipada do banco (o WAL, no PostgreSQL), na ordem em que foram confirmadas. Nada de consulta, nada de índice de pendentes, nada de `publicado_em`.

No PostgreSQL, o mecanismo é a decodificação lógica (o capítulo 13 trata do WAL e dos slots de replicação). Com `wal_level = logical`, um slot transforma o WAL em alterações por linha:

```sql
SELECT pg_create_logical_replication_slot('espiao', 'test_decoding');
INSERT INTO pedidos (id, cliente_id, produto, status)
VALUES (4471, 88, 'boia-flamingo', 'PENDENTE');
SELECT data FROM pg_logical_slot_get_changes('espiao', NULL, NULL);
```

```text
                                           data
---------------------------------------------------------------------------------------------------
 BEGIN 7731
 table public.pedidos: INSERT: id[bigint]:4471 cliente_id[bigint]:88 produto[text]:'boia-flamingo' status[text]:'PENDENTE'
 COMMIT 7731
(3 rows)
```

Transações desfeitas não aparecem. Em produção, um conector como o Debezium lê o slot com o plugin `pgoutput`, publica cada alteração no Kafka e guarda a posição no WAL (o LSN) para continuar de onde parou.

CDC direto nas tabelas de domínio transforma o schema interno em contrato: renomear uma coluna quebra todos os consumidores, que agora dependem de uma decisão de modelagem de 2021 da qual ninguém se orgulha. A combinação comum é outbox mais CDC: o payload da `outbox` é desenhado como contrato público, e o CDC lê só essa tabela (o Debezium tem uma transformação pronta, o *outbox event router*). Como o slot entrega as linhas logo após o commit, a tabela pode ser limpa em seguida.

## Propriedades e custos

| | 2PC | Saga orquestrada | Saga coreografada | Outbox com polling | Outbox com CDC |
|---|---|---|---|---|---|
| Atomicidade | real, entre participantes | tudo ou compensado | tudo ou compensado | local + publicação garantida | local + publicação garantida |
| Isolamento | sim (locks até a fase 2) | não | não | n/a | n/a |
| Disponibilidade | bloqueia se o coordenador cai | cada passo depende só do seu serviço | idem | publicação atrasa se o relay cai | publicação atrasa se o conector cai |
| Latência extra | 2 RTTs + fsyncs, locks seguros nesse tempo | soma dos passos, assíncrona | idem | intervalo do polling (ex.: 500 ms) | dezenas de ms após o commit |
| Exige dos participantes | protocolo XA | API de compensação idempotente | eventos + compensação idempotente | nada (só o banco local) | WAL lógico, slot, conector |
| Onde está o fluxo | coordenador | orquestrador (um lugar) | espalhado nos consumidores | n/a | n/a |
| Custo operacional | transações incertas para resolver | estado das sagas, recuperação | rastrear a saga exige tracing | tabela cresce, polling no banco | slot retém WAL, mais um sistema |

Se todos os dados estão em bancos que falam XA, no mesmo datacenter, o isolamento do 2PC pode valer os milissegundos e o risco de bloqueio; com uma API de terceiros no meio, o 2PC sai da mesa. Na coreografia, um consumidor novo não muda ninguém, e entender o fluxo exige ler todos os serviços; na orquestração, o fluxo está num arquivo, do qual todos passam a depender. Polling a cada 500 ms são 172.800 consultas por dia, a maioria de madrugada, para não achar nada; CDC entrega mais cedo e na ordem do commit, ao preço de operar um slot e um conector.

## Armadilhas e casos reais

> **Armadilha:** relay que avança por `id > ultimo_id` com IDs de sequência. A transação que pegou o id 101 pode confirmar depois da que pegou o 102. O relay lê o 102, guarda "último = 102" e o evento 101, confirmado meio segundo depois, nunca será publicado. Sequências são alocadas na ordem do `nextval`, e commits acontecem em outra ordem. A marcação por linha (`publicado_em`) ou o CDC, que segue a ordem do commit, não têm esse buraco.

> **Armadilha:** vários relays com `SKIP LOCKED` publicam em paralelo e perdem a ordem por agregado. Se o pedido 4471 tem `PedidoCriado` e `PedidoCancelado` em lotes diferentes, o cancelamento pode chegar primeiro, e o consumidor cancela um pedido que ainda não existe e depois o cria, feliz da vida. Quem precisa de ordem por agregado usa um relay por partição de agregado ou um relay só.

> **Armadilha:** tabela `outbox` que só cresce. Com 200 pedidos por segundo são 17,28 milhões de linhas por dia, todas com `payload` em JSON. Apagar as publicadas em lotes (ou particionar por dia e descartar partições antigas, como mostra o capítulo 14) faz parte do padrão.

> **Armadilha:** slot de replicação de um conector CDC parado. O PostgreSQL guarda todo o WAL desde a última posição confirmada pelo slot. Um conector desligado na sexta é um disco cheio na segunda, e um banco que para de aceitar escritas por causa de um sistema que só deveria ler. `max_slot_wal_keep_size` (PostgreSQL 13+) limita o estrago, invalidando o slot.

> **Na vida real:** Pat Helland, que passou décadas construindo bancos e monitores de transação, descreveu em 2007 ("Life beyond Distributed Transactions") sistemas grandes que abandonam transações distribuídas e coordenam entidades por mensagens idempotentes. Saga, inbox e outbox estão todos lá, uma década antes do vocabulário de microsserviços.
## Resumo

- Escrita dupla: alterar dois sistemas com transações independentes. Qualquer ordem tem uma falha que deixa os dois em desacordo, e escritas concorrentes divergem mesmo sem falha.
- 2PC: fase de preparação (voto sim é irrevogável) e fase de decisão. Atomicidade e isolamento reais, ao preço de bloquear participantes incertos se o coordenador cair, e só entre sistemas que falam o protocolo.
- `PREPARE TRANSACTION` no PostgreSQL é para gerenciadores externos; transação preparada esquecida segura locks e o `VACUUM`.
- Saga: transações locais com compensações em ordem inversa, sem isolamento. Passos compensáveis, pivô e repetíveis, todos idempotentes.
- Orquestração concentra fluxo e estado; coreografia espalha o fluxo pelos eventos.
- Outbox: mensagem gravada na mesma transação do estado; relay publica com at-least-once; consumidor deduplica.
- CDC lê o WAL na ordem do commit; outbox mais CDC evita expor o schema interno. Slot parado enche o disco.

## Referências

- Jim Gray. "Notes on Data Base Operating Systems". *Operating Systems: An Advanced Course*, Lecture Notes in Computer Science 60, Springer, 1978.
- The Open Group (X/Open). *Distributed Transaction Processing: The XA Specification*, 1991.
- Dale Skeen. "Nonblocking Commit Protocols". *ACM SIGMOD*, 1981.
- Jim Gray e Leslie Lamport. "Consensus on Transaction Commit". *ACM Transactions on Database Systems*, 31(1), 2006.
- Hector Garcia-Molina e Kenneth Salem. "Sagas". *ACM SIGMOD*, 1987. <https://dl.acm.org/doi/10.1145/38713.38742>
- Lars Frank e Torben U. Zahle. "Semantic ACID Properties in Multidatabases Using Remote Procedure Calls and Update Propagations". *Software: Practice and Experience*, 28(1), 1998.
- Pat Helland. "Life beyond Distributed Transactions: an Apostate's Opinion". *CIDR*, 2007. <https://www.cidrdb.org/cidr2007/papers/cidr07p15.pdf>
- Chris Richardson. *Microservices Patterns*. Manning, 2018. Padrões: <https://microservices.io/patterns/data/saga.html> e <https://microservices.io/patterns/data/transactional-outbox.html>
- PostgreSQL. `PREPARE TRANSACTION`: <https://www.postgresql.org/docs/current/sql-prepare-transaction.html>
- PostgreSQL. `pg_prepared_xacts`: <https://www.postgresql.org/docs/current/view-pg-prepared-xacts.html>
- PostgreSQL. Logical Decoding: <https://www.postgresql.org/docs/current/logicaldecoding.html>
- Debezium. PostgreSQL connector: <https://debezium.io/documentation/reference/stable/connectors/postgresql.html>
- Debezium. Outbox Event Router: <https://debezium.io/documentation/reference/stable/transformations/outbox-event-router.html>
