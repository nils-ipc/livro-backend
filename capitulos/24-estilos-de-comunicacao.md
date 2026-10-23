# Estilos de comunicação

## Dezoito mil celulares perguntando pela mesma pizza

O celular de Dona Zuleica fez 1.140 perguntas sobre uma pizza meia calabresa, meia portuguesa, e 1.135 delas receberam exatamente a mesma resposta. Ela pediu a pizza às 20h14 de um sábado e abriu a tela "Acompanhe seu pedido". O aplicativo (a situação é hipotética) perguntou como estava o pedido 7781 e ouviu `{"etapa": "no_forno"}`. Dois segundos depois, perguntou de novo, e continuou perguntando pelos 38 minutos que a pizza levou para chegar.

No pico de sábado, eram 18 mil celulares com a mesma tela aberta: 9 mil requisições por segundo no servidor `polling-01`, cada uma com um `SELECT` pela chave primária e um JSON de 21 bytes entregue com a solenidade de quem traz uma notícia. Em 99,6% das vezes, a notícia era que nada tinha mudado. A equipe dobrou as réplicas duas vezes, e o banco chegou a 70% de CPU respondendo "já saiu?". A pizza seguia, indiferente, no forno.

Uma pizza muda de etapa umas cinco vezes na vida: com 18 mil pedidos abertos, são umas 40 mudanças por segundo para contar. A diferença entre 40 e 9.000 é escolha de estilo de comunicação. Quais são os estilos disponíveis (REST, gRPC, GraphQL, SSE, WebSocket), o que cada um coloca no fio, o que permite em cache e em streaming, e o que exige da infraestrutura?

## REST, ou o HTTP usado conforme o manual

*REST* (Representational State Transfer) foi definido por Roy Fielding na tese de doutorado dele, em 2000, como um estilo arquitetural com restrições: cliente e servidor separados, servidor sem estado de sessão (*stateless*), respostas que se declaram cacheáveis, sistema em camadas e interface uniforme, em que tudo é recurso identificado por URI, com hipermídia indicando as próximas ações (HATEOAS). Quase nenhuma API de mercado implementa a hipermídia. O que o mercado chama de REST é "JSON sobre HTTP com URLs de substantivos e a semântica de métodos da RFC 9110". Fielding reclamou disso publicamente em 2008, num texto chamado "REST APIs must be hypertext-driven", com o mesmo efeito prático de um aviso de "não alimente os pombos".

Essa versão herda do HTTP métodos com semântica que qualquer proxy e biblioteca de retry entendem sem ler a sua documentação, cache por URL no navegador e na CDN (`Cache-Control`, `ETag`) e `curl` como depurador universal. O capítulo 2 trata disso.

O corpo costuma ser JSON, que repete o nome de cada campo em cada objeto: uma lista de 500 pedidos carrega `"previsao_entrega_em_minutos"` 500 vezes. A compressão recupera os bytes, e a CPU paga duas vezes, para comprimir e para analisar. E quando a tela precisa de vários recursos, são várias requisições (*underfetching*), enquanto `/clientes/42` devolve 31 campos para uma tela que usa dois (*overfetching*). O aplicativo em 4G ruim espera quatro RTTs em sequência para mostrar um nome e um endereço.

## gRPC: contrato primeiro, bytes depois

O *gRPC* é um framework de chamada remota de procedimento (RPC): um contrato em Protocol Buffers, um formato de mensagem sobre HTTP/2 e stubs gerados a partir do contrato, em que a chamada remota vira uma chamada de método com tipos verificados.

```protobuf
syntax = "proto3";

package pizzaria.v1;

service Pedidos {
  rpc ObterPedido(PedidoId) returns (Pedido);
  rpc AcompanharPedido(PedidoId) returns (stream StatusPedido);
}

message PedidoId { int64 id = 1; }

message Pedido {
  int64 id = 1;
  string sabor = 2;
}

enum Etapa {
  ETAPA_DESCONHECIDA = 0;
  NO_FORNO = 1;
  SAIU_PARA_ENTREGA = 2;
  ENTREGUE = 3;
}

message StatusPedido { Etapa etapa = 1; }
```

### Protocol Buffers no fio

Os números depois do sinal de igual são o que vai para o fio. O nome do campo nunca é transmitido. Cada campo é codificado como uma *tag* seguida do valor, e a tag é um inteiro calculado assim:

```text
tag = (número_do_campo << 3) | tipo_no_fio
```

Os tipos no fio usados hoje são `0` (VARINT), `1` (8 bytes fixos), `2` (LEN: tamanho seguido de bytes, para strings e mensagens aninhadas) e `5` (4 bytes fixos). Os tipos 3 e 4 eram dos *groups*, descontinuados, e seguem na documentação como um parente que ninguém convida mais para o almoço. O VARINT usa 7 bits por byte para o número e o bit mais alto para dizer "tem mais byte depois": 150 vira `0x96 0x01`. Um pedido com `id = 150` e `sabor = "calabresa"`:

```python
from pizzaria.v1 import pedidos_pb2

pedido = pedidos_pb2.Pedido(id=150, sabor="calabresa")
dados = pedido.SerializeToString()

print(dados)
print(len(dados), "bytes")
print(dados.hex(" "))
```

```text
b'\x08\x96\x01\x12\tcalabresa'
14 bytes
08 96 01 12 09 63 61 6c 61 62 72 65 73 61
```

O `0x08` é o campo 1 com tipo 0 (`1 << 3 | 0`), seguido de `96 01`. O `0x12` é o campo 2 com tipo 2 (`2 << 3 | 2 = 18`), seguido do tamanho 9 e de "calabresa". O `\t` no `repr` é o Python mostrando o byte `0x09` como tabulação, por pura cortesia. Em JSON, `{"id":150,"sabor":"calabresa"}` ocupa 30 bytes.

Como só o número viaja, renomear um campo não quebra ninguém, e mudar o número ou o tipo quebra todos. Um campo removido tem o número marcado como `reserved`, para que ninguém o reaproveite daqui a dois anos e um cliente antigo leia um CPF no lugar da quantidade de bordas recheadas. Um leitor que encontra um número desconhecido pula o campo, porque o tipo no fio diz quantos bytes pular, e é isso que deixa versões diferentes do contrato conviverem (capítulo 25). No proto3, valores padrão (`0`, string vazia) não são transmitidos, e "veio zero" fica igual a "não veio", a não ser que o campo seja declarado `optional`.

### O gRPC em cima do HTTP/2

O gRPC exige HTTP/2. Cada chamada é um stream: o método vira o caminho, a mensagem vai num frame DATA com um prefixo de 5 bytes, e o resultado da chamada vai nos *trailers*, cabeçalhos enviados depois do corpo. A chamada `ObterPedido` no fio:

```text
HEADERS (cliente → servidor)
  :method = POST
  :path = /pizzaria.v1.Pedidos/ObterPedido
  content-type = application/grpc
  te = trailers
  grpc-timeout = 2S

DATA
  00 00 00 00 03 08 96 01
  │  └─────────┘ └──────┘
  │   tamanho=3   PedidoId(id=150)
  └ flag de compressão

HEADERS (servidor → cliente)
  :status = 200
  content-type = application/grpc

DATA
  00 00 00 00 0e 08 96 01 12 09 63 61 6c 61 62 72 65 73 61

HEADERS (trailers, fim do stream)
  grpc-status = 0
```

O status HTTP diz só que o transporte funcionou. O resultado fica em `grpc-status`, com 17 códigos, de `0` (`OK`) a `16` (`UNAUTHENTICATED`). Um pedido inexistente volta como HTTP 200 com `grpc-status = 5` (`NOT_FOUND`), e um painel que conta só os 5xx do balanceador mostra 100% de sucesso com a serenidade de quem nunca leu os trailers. O `grpc-timeout` carrega o deadline relativo da chamada (capítulo 19).

### Quatro formatos de chamada

Como streams HTTP/2 são bidirecionais, o gRPC oferece chamadas unárias (uma mensagem de cada lado), streaming do servidor, streaming do cliente (leituras de GPS em lote) e bidirecional (chat entre entregador e central). O `AcompanharPedido` é streaming do servidor: uma chamada aberta, uma mensagem por mudança de etapa.

```python
import grpc
from pizzaria.v1 import pedidos_pb2, pedidos_pb2_grpc

async def acompanhar(pedido_id: int) -> None:
    credenciais = grpc.ssl_channel_credentials()
    async with grpc.aio.secure_channel("pedidos.interno.example:443", credenciais) as canal:
        stub = pedidos_pb2_grpc.PedidosStub(canal)
        async for status in stub.AcompanharPedido(pedidos_pb2.PedidoId(id=7781)):
            print("etapa:", pedidos_pb2.Etapa.Name(status.etapa))
```

```text
etapa: NO_FORNO
etapa: SAIU_PARA_ENTREGA
etapa: ENTREGUE
```

Três mensagens em 38 minutos, contra 1.140 respostas do polling. O `polling-01` ficaria comovido, se tivesse sentimentos.

A conta vem na infraestrutura. O navegador não dá à aplicação acesso aos trailers, então um front-end em React precisa do gRPC-Web, com um proxy traduzindo (o Envoy é um exemplo), e só com chamadas unárias e streaming do servidor. Tudo é `POST`, então cache HTTP e CDN ficam de fora. E as conexões longas mudam o balanceamento, assunto das armadilhas.

## GraphQL: o cliente escolhe os campos e o servidor paga a conta

O *GraphQL* é uma linguagem de consulta e um ambiente de execução, especificados pela GraphQL Foundation. O servidor publica um schema tipado; o cliente envia um documento dizendo exatamente quais campos quer, inclusive atravessando relações; o servidor responde com um JSON no mesmo formato da pergunta.

```graphql
query {
  pedidos(ultimos: 50) {
    id
    etapa
    cliente { nome }
  }
}
```

Uma requisição, só os campos pedidos: underfetching e overfetching somem. `query` lê (campos de topo executados em paralelo, se o servidor quiser), `mutation` altera (campos de topo em série, por especificação) e `subscription` recebe eventos, normalmente sobre WebSocket. Sobre HTTP, a convenção é um endpoint só (`POST /graphql`), e muitos servidores respondem `200 OK` com os erros num array `errors` no corpo; o rascunho "GraphQL over HTTP" define o tipo `application/graphql-response+json`, com 4xx para documentos inválidos. Quem monitora só o status HTTP precisa saber qual convenção o servidor segue, ou comemora uma taxa de erro de zero que só existe no painel.

### Resolvers e o N+1 que vem de brinde

O servidor percorre a árvore de campos chamando, para cada campo, uma função *resolver*. O resolver de `pedidos` devolve 50 pedidos; para cada um, o executor chama o resolver de `cliente`, escrito sem saber dos outros. Daí vem o N+1 (o capítulo 9 trata dele no ORM). Com Strawberry, uma biblioteca de GraphQL para Python:

```python
import strawberry

@strawberry.type
class Cliente:
    id: int
    nome: str

@strawberry.type
class Pedido:
    id: int
    etapa: str
    cliente_id: strawberry.Private[int]

    @strawberry.field
    async def cliente(self) -> Cliente:
        # cada pedido busca o próprio cliente, com toda a boa vontade do mundo
        return await buscar_cliente(self.cliente_id)
```

```text
SELECT id, etapa, cliente_id FROM pedidos ORDER BY id DESC LIMIT 50
SELECT id, nome FROM clientes WHERE id = 412
SELECT id, nome FROM clientes WHERE id = 87
SELECT id, nome FROM clientes WHERE id = 412
... (mais 47 linhas, incluindo o cliente 412 pela terceira vez)
```

Cinquenta e uma consultas. Com `itens { produto { nome } }` e quatro itens por pedido, seriam mais 250: o cliente escreveu oito linhas de GraphQL, o banco recebeu trezentas consultas. A correção é o *DataLoader*, padrão publicado pelo Facebook: o resolver pede uma chave ao loader, que junta as chaves pedidas na mesma iteração do event loop, faz uma busca em lote e guarda um cache por requisição.

```python
from strawberry.dataloader import DataLoader

async def carregar_clientes(ids: list[int]) -> list[Cliente]:
    linhas = await banco.fetch(
        "SELECT id, nome FROM clientes WHERE id = ANY($1)", ids
    )
    por_id = {l["id"]: Cliente(id=l["id"], nome=l["nome"]) for l in linhas}
    return [por_id[i] for i in ids]  # mesma ordem das chaves pedidas

async def contexto() -> dict:
    # loader novo a cada requisição: o cache dele não pode vazar entre usuários
    return {"clientes": DataLoader(load_fn=carregar_clientes)}

@strawberry.type
class Pedido:
    id: int
    etapa: str
    cliente_id: strawberry.Private[int]

    @strawberry.field
    async def cliente(self, info: strawberry.Info) -> Cliente:
        return await info.context["clientes"].load(self.cliente_id)
```

```text
SELECT id, etapa, cliente_id FROM pedidos ORDER BY id DESC LIMIT 50
SELECT id, nome FROM clientes WHERE id = ANY('{412,87,1033,...}')
```

A função de lote devolve os resultados na ordem das chaves; na ordem que o banco achou melhor, cada pedido ganha o nome de outro cliente, um jeito criativo de vazar dados pessoais.

### Custo de consulta

No REST, o servidor decide o que cada endpoint custa. No GraphQL, quem decide é o cliente, e ele pode escrever isto:

```graphql
query {
  clientes(primeiros: 100) {
    pedidos(primeiros: 100) {
      itens(primeiros: 100) {
        produto { avaliacoes(primeiras: 100) { autor { nome } } }
      }
    }
  }
}
```

São 100⁴ = 100 milhões de avaliações numa requisição de menos de 200 bytes. As defesas analisam o documento antes de executar: limite de profundidade, paginação obrigatória com teto e custo estimado, em que listas multiplicam o peso pelo tamanho pedido. A API GraphQL do GitHub, por exemplo, exige `first` ou `last` entre 1 e 100, recusa chamadas que possam devolver mais de 500 mil nós e cobra o rate limit em pontos, 5.000 por hora por usuário. Com *persisted queries*, o servidor aceita só documentos registrados, identificados por hash, o que fecha a porta para consultas arbitrárias e permite enviar o hash por `GET`, devolvendo ao GraphQL o cache em CDN. Sem isso, o cache migra para o cliente (o Apollo Client normaliza respostas por tipo e `id`), num banco de dados em miniatura dentro do navegador.

## Empurrar dados do servidor

No pedido e resposta, o servidor só fala quando perguntam. *Polling*, o que Dona Zuleica sofreu, custa clientes ÷ intervalo, mudando ou não, com atraso médio de meio intervalo. *Long polling* segura a requisição até haver novidade ou até um timeout (30 s é comum): 18 mil requisições pendentes e 600 renovações por segundo, em qualquer infraestrutura HTTP, com uma requisição completa por evento.

### Server-Sent Events

*SSE* (Server-Sent Events) é uma resposta HTTP comum que nunca termina. Está especificado no HTML Living Standard, do WHATWG, junto com a API `EventSource` dos navegadores. O tipo de mídia é `text/event-stream`, e o formato é texto UTF-8, em linhas:

```text
id: 3
event: status
data: {"etapa": "no_forno", "previsao_min": 18}

: comentário, ignorado pelo cliente

```

Um evento termina numa linha em branco; `retry:` diz em quantos milissegundos reconectar; linha começando com dois-pontos é comentário. O `EventSource` reconecta sozinho e envia o último `id` no cabeçalho `Last-Event-ID`, para o servidor retomar de onde parou. Nenhuma outra técnica traz reconexão e retomada de fábrica.

Em FastAPI:

```python
import json
from fastapi import FastAPI
from fastapi.responses import StreamingResponse

app = FastAPI()

@app.get("/pedidos/{pedido_id}/eventos")
async def eventos(pedido_id: int):
    async def gerar():
        # assinar() lê de um pub/sub e entrega None após 15 s sem eventos
        async for ev in assinar(pedido_id):
            if ev is None:
                yield ": ping\n\n"  # mantém a conexão viva nos intermediários
                continue
            yield f"id: {ev.seq}\nevent: status\ndata: {json.dumps(ev.dados)}\n\n"

    return StreamingResponse(
        gerar(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
```

```bash
curl -N https://api.pizzaria.example/pedidos/7781/eventos
```

```text
id: 3
event: status
data: {"etapa": "no_forno", "previsao_min": 18}

: ping

: ping

id: 4
event: status
data: {"etapa": "saiu_para_entrega", "previsao_min": 12}

```

O `-N` desliga o buffer do `curl`; o `X-Accel-Buffering: no` pede o mesmo ao NGINX, que por padrão junta a resposta do upstream e entregaria os eventos em lote, minutos depois, no ritmo de um jornal impresso. O `: ping` a cada 15 s existe porque balanceadores fecham conexões ociosas (60 s é um padrão comum). Os limites: só o servidor envia, só texto, e em HTTP/1.1 o navegador abre cerca de 6 conexões por origem, então a sétima aba fica pendurada esperando a pizza alheia. Em HTTP/2, cada `EventSource` é um stream da mesma conexão.

### WebSocket

O *WebSocket* (RFC 6455) é um canal bidirecional de mensagens sobre uma conexão TCP, que começa como HTTP e depois deixa de ser:

```text
GET /chat HTTP/1.1
Host: api.pizzaria.example
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
Origin: https://app.pizzaria.example

HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

O `Sec-WebSocket-Accept` é o Base64 do SHA-1 da chave concatenada com o GUID fixo `258EAFA5-E914-47DA-95CA-C5AB0DC85B11` (a chave e a resposta acima são o exemplo da RFC). Ele não protege nada: só prova que o servidor entendeu o pedido, em vez de devolver um 101 por educação.

Depois do `101`, trafegam frames com cabeçalho de 2 a 14 bytes: bit `FIN`, *opcode* (`0x1` texto, `0x2` binário, `0x8` fechamento, `0x9` ping, `0xA` pong), bit `MASK` e tamanho. Todo frame do cliente é mascarado por XOR com 4 bytes aleatórios, porque uma pesquisa de 2011 (Huang e outros, "Talking to Yourself for Fun and Profit") mostrou que, sem máscara, um script podia montar bytes que proxies transparentes tomavam por requisições HTTP e guardavam no cache. O servidor não mascara nada, e ninguém se ofende. A RFC para no canal: sem identificador de mensagem, retomada, reconexão ou confirmação de entrega, tudo por conta da aplicação.

A API `WebSocket` do navegador não deixa definir cabeçalhos, então nada de `Authorization` no handshake (cookie ou token na primeira mensagem). E o CORS não se aplica: qualquer site abre uma conexão para o seu servidor com os cookies do usuário. Sem verificar o `Origin`, um site qualquer usa o chat da pizzaria em nome do cliente logado (*Cross-Site WebSocket Hijacking*, capítulo 32).

### O que conexões longas pedem da infraestrutura

Long polling, SSE, WebSocket e streaming de gRPC mantêm uma conexão aberta por cliente, e cada uma ocupa um descritor e alguns kilobytes em cada salto. Num servidor assíncrono (capítulo 4), 18 mil conexões ociosas cabem em poucos processos; com workers síncronos, pedem 18 mil workers, um jeito caro de acompanhar pizzas.

A pizza saiu do forno na réplica 2, que tratou o `POST` da cozinha; o celular de Dona Zuleica está pendurado na réplica 5. As réplicas precisam de publicação e assinatura entre elas (Redis Pub/Sub, NATS, um broker; capítulo 21). E todo deploy derruba conexões: encerrar uma réplica com 3 mil clientes gera 3 mil reconexões no mesmo segundo, com TCP, TLS e autenticação. Drenagem no servidor e backoff com jitter no cliente (capítulo 19) evitam que cada deploy vire um pequeno ataque de negação de serviço encomendado pela própria empresa.

## Propriedades e custos

| | REST (JSON/HTTP) | gRPC | GraphQL | SSE | WebSocket |
|---|---|---|---|---|---|
| Formato no fio | texto (JSON) | binário (Protobuf) | texto (JSON) | texto UTF-8 | frames, texto ou binário |
| Direção | pedido e resposta | 4 formatos, inclusive bidirecional | pedido e resposta; subscription | servidor → cliente | bidirecional |
| Cache HTTP / CDN | sim, por URL com `GET` | não (`POST`) | só com persisted queries por `GET` | não | não |
| Navegador direto | sim | não (gRPC-Web + proxy) | sim | sim (`EventSource`) | sim |
| Contrato | opcional (OpenAPI) | `.proto` | schema | nenhum | nenhum |
| Retomada após queda | n/a | aplicação | n/a | `Last-Event-ID` | aplicação |
| Balanceamento | por requisição | L7 ou cliente | por requisição | por conexão | por conexão |

O cache por URL pesa em leituras públicas repetidas (catálogo, preço): a requisição nem chega ao servidor. Bytes, CPU de serialização e tipos verificados pesam entre serviços internos de volume alto, ao preço de L7 e depuração com ferramenta própria. Telas diferentes sobre os mesmos dados favorecem o GraphQL, que transfere o custo para DataLoaders e análise de consulta no servidor. Notificação num sentido só cabe no SSE, sobre o HTTP que a infraestrutura já entende; troca contínua nos dois sentidos (chat, edição colaborativa) pede WebSocket e o que a RFC deixou de fora.

Para a pizzaria, com 18 mil pedidos abertos e cerca de 40 mudanças de etapa por segundo:

| Técnica | Requisições ou mensagens por segundo | Conexões abertas | Atraso médio para ver a mudança |
|---|---|---|---|
| Polling de 2 s | 9.000 requisições | curtas | 1 s |
| Long polling, timeout 30 s | ~640 requisições | 18.000 | ~1 RTT |
| SSE | ~40 eventos + 1.200 pings | 18.000 | ~0,5 RTT |
| WebSocket | ~40 mensagens + pings | 18.000 | ~0,5 RTT |

Os 1.200 pings por segundo são comentários de uma linha, sem banco nem transação. O `polling-01` pode, enfim, tirar férias.

## Armadilhas e casos reais

> **Armadilha:** gRPC atrás de balanceador de camada 4. O L4 distribui conexões, e o HTTP/2 põe todas as chamadas numa conexão longa, então cada cliente se cola numa réplica para sempre. Ao escalar de 3 para 10 réplicas, as 7 novas assistem às 3 antigas trabalharem. Um `Service` ClusterIP do Kubernetes balanceia em L4, e o blog oficial do projeto dedicou um texto ao problema em 2018. As saídas são balanceamento L7 (proxy ou service mesh, capítulo 27) ou no cliente, com política `round_robin`.

> **Armadilha:** DataLoader global, criado no módulo em vez de por requisição, vira cache sem expiração compartilhado entre usuários. Passa nos testes e, em produção, mostra a um cliente o endereço de outro, com desempenho excelente.

> **Armadilha:** aliases no GraphQL. `a1: login(senha: "1")` até `a1000` num documento só: o rate limit por requisição vê uma requisição, o servidor executa mil tentativas de senha. A OWASP descreve o ataque e a defesa, que é contar operações e custo por documento.

> **Na vida real:** as bibliotecas oficiais do gRPC recusam por padrão mensagens recebidas acima de 4 MB, com `RESOURCE_EXHAUSTED`. O relatório de 3,9 MB para de funcionar no primeiro mês bom de vendas; aumentar o limite resolve até o mês bom seguinte.

## Resumo

- REST de mercado: JSON sobre HTTP com a semântica da RFC 9110, cache por URL, overfetching e underfetching.
- Protobuf transmite número e tipo do campo, nunca o nome; renumerar quebra, campo removido vira `reserved`.
- gRPC: HTTP/2, prefixo de 5 bytes, resultado em `grpc-status` nos trailers com HTTP 200; gRPC-Web no navegador; balanceamento L7 ou no cliente.
- GraphQL: N+1 nos resolvers, DataLoader por requisição, custo limitado antes da execução, cache HTTP só com persisted queries.
- SSE: resposta HTTP sem fim, num sentido, com `Last-Event-ID`; buffering desligado e heartbeat.
- WebSocket (RFC 6455): bidirecional, máscara do cliente, sem retomada; verificar `Origin`.
- Conexões longas pedem pub/sub entre réplicas e reconexão com jitter.

## Referências

- Roy Fielding, "Architectural Styles and the Design of Network-based Software Architectures", tese, 2000: <https://ics.uci.edu/~fielding/pubs/dissertation/top.htm>
- RFC 9110, HTTP Semantics: <https://www.rfc-editor.org/rfc/rfc9110>
- Protocol Buffers, Encoding: <https://protobuf.dev/programming-guides/encoding/>
- gRPC over HTTP2: <https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md>
- gRPC, Status Codes: <https://grpc.io/docs/guides/status-codes/>
- gRPC-Web: <https://github.com/grpc/grpc-web>
- GraphQL Specification, October 2021: <https://spec.graphql.org/October2021/>
- GraphQL over HTTP (rascunho): <https://graphql.github.io/graphql-over-http/draft/>
- DataLoader: <https://github.com/graphql/dataloader>
- GitHub, Rate limits and query limits for the GraphQL API: <https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api>
- OWASP GraphQL Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/GraphQL_Cheat_Sheet.html>
- HTML Living Standard, Server-sent events: <https://html.spec.whatwg.org/multipage/server-sent-events.html>
- RFC 6455, The WebSocket Protocol: <https://www.rfc-editor.org/rfc/rfc6455>
- Kubernetes Blog, "gRPC Load Balancing on Kubernetes without Tears", 2018: <https://kubernetes.io/blog/2018/11/07/grpc-load-balancing-on-kubernetes-without-tears/>
- Lin-Shung Huang, Eric Y. Chen, Adam Barth, Eric Rescorla e Collin Jackson, "Talking to Yourself for Fun and Profit", W2SP 2011.
