# Estilos de comunicação

## Três pedidos, três protocolos e um gerente que acha tudo igual

O gerente de produto entrou com três pedidos e a convicção de que eram um pedido escrito três vezes.

O primeiro veio do Mercadito Hornero. O painel deles mostra as vendas do dia com vendedor, split e estornos, e cada tela custa 201 chamadas à API: uma listagem, cem de vendedor, cem de estornos. Com 100 ms de RTT até a Virgínia (capítulo 8), a tela leva mais de 20 segundos. O N+1 do capítulo 6 emigrou: agora são 201 viagens por um cabo no fundo do Atlântico, e cada uma paga pedágio para os tubarões. O Hornero pediu GraphQL, "como todo mundo".

O segundo veio do checkout, que pergunta a cada 2 segundos se o Pix foi pago. No pico, 600 checkouts abertos geram 300 requisições por segundo, e 99,6% recebem a mesma resposta: `pendente`. A Lastro responde "ainda não" um milhão de vezes por hora, o que faz dela a ex mais requisitada do país. O Carlos propôs polling de 100 ms, "pra ficar tempo real": 6.000 requisições por segundo. O Carlos chamou de tempo real; o PostgreSQL chamaria de ataque, se sobrevivesse para chamar alguma coisa.

O terceiro veio da Vigia, o novo fornecedor de antifraude, que avalia cada transação de cartão antes da autorização e só oferece gRPC. A documentação tem uma frase: "não temos JSON, temos princípios".

```text
Gerente:  É tudo API. É só chamar.
Hornero:  Quero escrever a minha consulta.
Checkout: Quero que me avisem.
Vigia:    Quero bytes, HTTP/2 e um deadline.
Carlos:   Quero polling de 100 ms.
Todos:    Não.
```

Estilo de comunicação é marketing até alguém olhar o tráfego. O que separa REST, gRPC, GraphQL, WebSocket, SSE e webhooks no fio, e qual propriedade de cada canal da Lastro decide o estilo dele?

## REST, o estilo que já pagava as contas

Cinco perguntas separam os estilos: quem inicia, quantas mensagens por chamada (uma de cada lado, a chamada unária, ou uma sequência, o *streaming*), o que trafega, quem guarda cache e o que a infraestrutura no caminho suporta, do proxy ao firewall corporativo de 2009. REST é o estilo descrito por Roy Fielding na tese dele, em 2000: recursos identificados por URL, interface uniforme, nenhum estado de sessão no servidor. No mercado, é o que a Lastro já faz, JSON sobre a semântica da RFC 9110 do capítulo 9. O cliente inicia, a chamada é unária, o cache HTTP funciona completo (o `GET` é seguro e a URL é a chave), e qualquer proxy da face da Terra entende, inclusive o que ninguém sabe quem configurou.

O custo: o servidor decide a forma da resposta. Precisando de menos, o cliente recebe campos que joga fora (*over-fetching*); precisando de mais, faz outra chamada (*under-fetching*), e cada chamada custa um RTT. Para o Bazar, a 2 ms, isso é ruído. Para o Hornero, a 100 ms, é o motivo de o analista financeiro deles ter aprendido crochê enquanto o painel carrega.

## gRPC, um contrato binário com HTTP/2 obrigatório e nenhum ser humano no meio

gRPC é o framework de RPC publicado pelo Google em 2015. Serviços e mensagens ficam num arquivo `.proto`, um gerador produz cliente e servidor em cada linguagem, e o código chama um método remoto que parece local. A rede continua lá, só que agora com cara de função.

### Protocol Buffers no fio

O formato é o Protocol Buffers. O schema numera cada campo, e é o número que trafega, nunca o nome:

```text
message Transacao {
  int64  valor = 1;
  string moeda = 2;
}

valor = 150, moeda = "BRL"

protobuf: 08 96 01 12 03 42 52 4c             (8 bytes)
JSON:     {"valor":150,"moeda":"BRL"}         (27 bytes)
```

Cada campo começa com uma *tag*, `(número << 3) | tipo_no_fio`. O `08` é o campo 1, tipo 0 (*varint*); `96 01` é 150 em varint, 7 bits por byte com o bit alto avisando que vem mais; `12` é o campo 2, tipo 2 (tamanho prefixado), com tamanho `03` e os bytes de "BRL". O JSON manda a palavra "valor" em toda mensagem, por toda a eternidade, como quem rubrica cada página do contrato.

Número desconhecido é pulado (o tipo no fio diz quantos bytes) e, desde o protobuf 3.5, guardado para reserializar: o leitor tolerante do capítulo 11 vem de fábrica, e o Jackson da consultoria do Bazar teria um colapso nervoso. O número é o contrato: renomear campo é inofensivo, reutilizar o número de um removido faz o cliente antigo ler `moeda` onde agora vai `pais`. Por isso existe `reserved 3;`, a lápide que impede enterrar outro campo na mesma cova.

### O gRPC sobre o HTTP/2

O gRPC exige HTTP/2. Cada chamada é um stream: `POST` para `/pacote.Servico/Metodo`, cada mensagem com 1 byte de flag de compressão e 4 de tamanho, e o resultado nos *trailers*, cabeçalhos que chegam depois do corpo:

```text
:method: POST
:path: /vigia.v1.Avaliacao/Avaliar
content-type: application/grpc
te: trailers
grpc-timeout: 120m

(corpo: 00 00 00 00 2a + 42 bytes de protobuf)

trailers -> grpc-status: 0
```

Num stream, o servidor só sabe se deu certo depois de mandar as mensagens, daí o status no trailer: 17 códigos (`OK`, `DEADLINE_EXCEEDED`, `UNAVAILABLE`...), com o HTTP em `200` quase sempre. É o único protocolo que responde "200, morreu" sem ironia.

O `grpc-timeout: 120m` é o *deadline*: "m" minúsculo é mili, maiúsculo é minuto, e alguém já confundiu os dois em produção. O servidor desiste quando o prazo passa e repassa o restante às chamadas que fizer (capítulo 15).

Como cada chamada é um stream, há quatro formas: unária, streaming do servidor, streaming do cliente e bidirecional, em que os dois lados falam quando querem, sem esperar a vez, como em toda reunião de postmortem.

Os custos: sem cache HTTP, é tudo `POST`; o navegador não expõe trailers ao JavaScript e precisa do gRPC-Web com um proxy tradutor; o log vira binário ilegível sem o `.proto`; e a conexão HTTP/2 longa engana o balanceador de camada 4 (ver armadilhas).

## GraphQL, ou o cliente escreve a consulta e você paga a conta

O GraphQL nasceu no Facebook em 2012, para os apps móveis, e saiu em 2015. O servidor publica um schema de tipos e relações; o cliente manda a forma exata da resposta, num endpoint só, via `POST`:

```graphql
query VendasDoDia {
  cobrancas(primeiros: 100, de: "2026-11-03T00:00:00-03:00") {
    nos {
      id
      valor
      vendedor { nome documento }
      estornos { valor estado }
    }
    proximoCursor
  }
}
```

Uma viagem, nem um campo a mais. O Hornero leu e chorou.

### Resolvers, ou o N+1 com certificado de origem

Cada campo tem um *resolver*, a função que produz o valor dele a partir do objeto pai. O de `cobrancas` devolve 100 cobranças; o executor chama o de `vendedor` 100 vezes e o de `estornos` mais 100. Do jeito óbvio, são 201 consultas. O GraphQL tirou o N+1 da rede do Hornero e o reinstalou no seu banco, com nota fiscal.

A saída é o padrão *DataLoader*: o resolver só registra o ID que quer e devolve uma promessa; o loader junta os IDs da mesma rodada do event loop numa consulta (`WHERE id = ANY(...)`), com cache por requisição. As 201 viram 3, o número do `selectinload` do capítulo 6, porque a matemática do N+1 não muda de nacionalidade.

### O custo de uma consulta que o cliente escreveu

No REST, você escreve as consultas e sabe o pior caso. No GraphQL, o cliente escreve, e o pior caso é criatividade:

```graphql
{ cobrancas(primeiros: 100) { nos {
    vendedor { cobrancas(primeiros: 100) { nos {
      vendedor { cobrancas(primeiros: 100) { nos { id } } } } } } } } } }
```

São 100 × 100 × 100 = 1 milhão de nós, numa requisição de menos de 200 bytes. As defesas rodam antes da execução: limite de profundidade, paginação obrigatória com teto em toda lista e uma análise de custo estática que multiplica os tetos aninhados e recusa o que passar do orçamento. Sem isso, sua API pública vira um gerador de produto cartesiano com o cartão de crédito de outra pessoa.

O cache HTTP morre, porque tudo é `POST` na mesma URL (consultas persistidas, chamadas por hash via `GET`, ressuscitam o cache, mas exigem conhecer os clientes). E erro de execução volta, por convenção, com status `200`, `data` parcial e uma lista `errors`: o monitoramento que conta `5xx` jura que está tudo bem enquanto metade dos campos volta `null`.

## Empurrar do servidor: WebSocket, SSE e webhooks

Até aqui, o servidor só fala quando perguntado. Para ele tomar a iniciativa, há três mecanismos.

### WebSocket

O WebSocket (RFC 6455) começa como HTTP/1.1 e troca de protocolo no meio da conversa:

```http
GET /chat HTTP/1.1
Host: servidor.example
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13

HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
```

O `Accept` é o SHA-1 da chave com um GUID fixo da RFC, em Base64: prova que o servidor entende WebSocket e ninguém está ecoando cabeçalhos por educação. Depois do `101`, acabou o HTTP: o TCP vira um canal bidirecional de frames, e os do cliente vão mascarados com uma chave de 32 bits, para nenhum proxy antigo confundir bytes do usuário com uma requisição e envenenar o próprio cache.

Somem status por mensagem, cache e reconexão automática. A conexão tem estado e mora num processo: o proxy precisa repassar o `Upgrade`, o balanceador aguenta conexões de horas, e o deploy derruba todo mundo junto. É conexão persistente no sentido mais carente da expressão.

### Server-Sent Events

O SSE, do HTML Living Standard, é uma resposta HTTP que nunca termina, com `Content-Type: text/event-stream`:

```text
retry: 3000

id: 7
event: estado
data: {"estado":"pendente"}

: ping

id: 8
event: estado
data: {"estado":"paga"}
```

Linha em branco separa eventos; linha com `:` é comentário, o *heartbeat* que impede o proxy de matar a conexão ociosa. O `EventSource` do navegador reconecta após `retry` milissegundos e manda o último `id` em `Last-Event-ID`.

É HTTP, com o TLS e a autenticação que já existem. Os limites: uma direção, só texto (binário vai em Base64, chorando), e o `EventSource` não aceita cabeçalhos customizados, detalhe que vai custar uma reunião inteira na Lastro.

O terceiro, o webhook (capítulo 11), é o servidor virando cliente e exige endpoint HTTPS público no destinatário, coisa que o navegador do comprador, felizmente, não tem.

### A tabela que o gerente vai imprimir e não vai ler

| Estilo | Quem inicia | Mensagens | No fio | Cache HTTP | Exige da infraestrutura |
|--------|-------------|-----------|--------|------------|-------------------------|
| REST | cliente | unária | JSON | completo | só HTTP |
| gRPC | cliente | unária e streaming | protobuf | não | HTTP/2 ponta a ponta, balanceamento por requisição |
| GraphQL | cliente | unária | JSON | com consultas persistidas | análise de custo, DataLoader |
| WebSocket | os dois | bidirecional | frames próprios | não | `Upgrade`, conexões longas com estado |
| SSE | servidor | streaming | texto | não | proxy sem buffer, heartbeat |
| Webhook | servidor | unária | JSON | não | endpoint público no destino |

## Na Lastro, cada canal recebe o estilo que pede

Os comandos da API pública continuam REST, apoiados no `201`, no `202` e no `If-Match` do capítulo 9, e os webhooks continuam iguais. Os três pedidos novos recebem três decisões.

### O painel do Hornero: GraphQL só de leitura

| Opção | Viagens por tela (Hornero, 100 ms) | Custo para a Lastro |
|-------|-------------------------------------|---------------------|
| REST atual | 201, mais de 20 s | nenhum |
| REST com `expandir=vendedor,estornos` | 1, ~140 ms | um parâmetro por relação, formas fixas |
| GraphQL | 1, ~140 ms | limites de custo, DataLoader, autorização por resolver |

O `expandir` resolve a tela do Hornero, mas cada marketplace pede outra combinação de cobrança, split, estornos, vendedor e lançamentos. Com `expandir`, cada combinação nova é trabalho da Lastro; com GraphQL, é consulta do cliente. A Lastro publica `POST /v1/graphql`, só com `query`; escritas ficam no REST, com `201`, `If-Match` e, em breve, idempotência.

Limites verificados antes da execução: profundidade 5; `primeiros` obrigatório, máximo 100; custo estático (objeto vale 1, listas multiplicam pelo teto) até 5.000 pontos; `statement_timeout` de 3 segundos. Toda relação passa por DataLoader, e a CI conta o SQL de cada consulta de exemplo, com a raiva do `lazy="raise"` do capítulo 6. Paginação usa o cursor assinado do capítulo 11; erros trazem em `extensions.type` as URIs da RFC 9457; o schema evolui por adição e `@deprecated`. Cada resolver confere o marketplace da credencial, e o capítulo 31 volta nisso com sangue.

Com poucos clientes e telas fixas, `expandir` custaria menos e manteria o cache HTTP; com dezenas desenhando painéis próprios, a conta inverte.

### O checkout: SSE, porque só um lado tem algo a dizer

O checkout espera um fato só: a cobrança mudou de estado. O navegador não tem nada a dizer durante a espera, exceto "e aí?", que o polling diz 300 vezes por segundo.

| Opção | Requisições no pico (600 checkouts) | Atraso até o comprador ver "paga" | Peças novas |
|-------|-------------------------------------|-----------------------------------|-------------|
| Polling 2 s (atual) | 300/s | 1 s em média, mais o RTT | nenhuma |
| Polling 100 ms (Carlos) | 6.000/s | 50 ms, até o banco cair | um novo emprego |
| WebSocket | 600 conexões abertas | milissegundos após o commit | `Upgrade` no proxy, protocolo próprio |
| SSE | 600 conexões abertas | milissegundos após o commit | proxy sem buffer, heartbeat |

O WebSocket entregaria uma direção que ninguém usa e cobraria a perda do HTTP por ela; o SSE passa pelo proxy, pelo TLS e pelo CORS que já existem. WebSocket seria a escolha se o checkout mandasse dados continuamente, como num chat com o vendedor.

Aí veio a reunião inteira. O capítulo 9 pôs o token do checkout no `Authorization`, fora da URL e dos logs, e o `EventSource` não manda cabeçalhos customizados (a API `WebSocket` do navegador também não). O checkout lê o `text/event-stream` com `fetch`, aos pedaços, e reimplementa a reconexão com `retry` e `Last-Event-ID`. O Carlos sugeriu token na URL "só desta vez". O log do proxy guardaria o token por 90 dias, que é quanto dura "só desta vez" no ramo de vazamentos.

O endpoint é `GET /v1/checkout/cobrancas/{id}/eventos`; o `id` do evento é a `versao` da cobrança, e na reconexão a versão maior que o `Last-Event-ID` sai na hora. `: ping` a cada 15 segundos, proxy sem buffer com 60 segundos de tolerância, stream fechado na mudança de estado ou na expiração do QR Code.

Falta o problema de verdade: a notificação do Pix chega a um dos 6 processos (3 em `temp-01`, 3 em `api-01`) e o stream do comprador está em outro. A Lastro usa o `LISTEN`/`NOTIFY` do PostgreSQL, sem peça nova:

```text
 banco parceiro ──notificação Pix──▶ webhooks-pix.lastro.com.br (processo A)
                                       │ BEGIN
                                       │   lançamentos do pagamento
                                       │   UPDATE cobrancas ... versao + 1
                                       │   NOTIFY cobrancas, '<id>:<versao>'
                                       │ COMMIT ── notificação só sai aqui
                                       ▼
                               PostgreSQL ──▶ LISTEN cobrancas (1 conexão
                                                dedicada por processo)
                                                     │
                navegador ◀── SSE ── processo B ◀────┘ (lê o estado, envia)
```

O `NOTIFY` dentro da transação só sai no `COMMIT`; se ela aborta, a notificação morre junto, e o comprador nunca vê "paga" antes de o tabelião registrar o lançamento. Cada processo tem uma conexão fora do pool para o `LISTEN`: 6 a mais, ociosas, longe do teto de 17 a 20 ativas do capítulo 4. O stream que espera não segura conexão do pool; se segurasse, 600 checkouts disputariam 15 conexões e o `QueuePool limit` voltaria em formato de Pix.

O `NOTIFY` também não guarda nada: processo desconectado perde a notificação. Por isso o handler faz `LISTEN` antes de ler o estado, e a reconexão relê. A notificação acorda; a verdade mora no banco.

### A Vigia: gRPC unário com deadline

Aqui quem escolheu foi o fornecedor. Cada autorização de cartão chama `Avaliar` antes do adquirente, unária, com `grpc-timeout` de 120 ms (a Vigia promete p99 de 60 ms); o que fazer quando estoura fica para o capítulo 15. Cada processo mantém um canal, uma conexão HTTP/2 com TLS, como a do adquirente. O `.proto` entra no repositório com versão fixada, e os campos da decisão usam `optional` (ver armadilhas).

## Armadilhas e casos reais

> **Armadilha:** no proto3, campo escalar sem `optional` confunde "ausente" com "zero". Se a Vigia não mandar `score`, a Lastro lê `score = 0`, "risco nenhum" no contrato deles. É o `null` × ausente do capítulo 11, só que aqui o default aprova a fraude. Com `optional` (protobuf 3.15+), o código gerado ganha `HasField`.

> **Na vida real:** o blog do Kubernetes descreveu em 2018 o gRPC atrás de um Service comum, que balanceia por conexão (camada 4), enquanto o cliente gRPC manda tudo por uma conexão HTTP/2. Uma réplica recebe todo o tráfego, as outras recebem o salário. A correção é balancear por requisição, num proxy de camada 7 ou no cliente (capítulo 27).

> **Armadilha:** proxy com buffer de resposta (o `proxy_buffering` do nginx vem ligado) segura os eventos SSE até encher o buffer ou a resposta acabar. É polling com etapas extras. Desligue o buffer na rota ou responda `X-Accel-Buffering: no`, no caso do nginx.

> **Armadilha:** aliases do GraphQL (`a1: cobranca(id: 1)`, `a2: cobranca(id: 2)`...) põem 10.000 tentativas numa requisição só, e o rate limit por requisição dá desconto de atacado ao atacante. A análise de custo conta cada alias.

> **Na vida real:** a API GraphQL do GitHub exige `first`/`last` de 1 a 100 em toda conexão e recusa consultas acima de 500.000 nós.

## Resumo

- Estilos se separam por quem inicia, mensagens por chamada, formato no fio, cache e exigências de infraestrutura.
- REST: semântica e cache do HTTP; cada chamada a mais custa um RTT.
- gRPC: protobuf com campos por número; HTTP/2, status nos trailers, deadline em `grpc-timeout`; sem cache HTTP nem navegador direto.
- GraphQL: o cliente define a forma; DataLoader contra o N+1; limites de custo antes de executar.
- WebSocket: bidirecional após `101`. SSE: resposta HTTP infinita com `Last-Event-ID`. Webhook: servidor como cliente.
- `NOTIFY` só sai no commit e se perde sem ouvinte conectado.

## A Lastro agora

A Lastro fala quatro dialetos: REST para comandos; `POST /v1/graphql` só de leitura para os painéis, com profundidade 5, listas de até 100 e 5.000 pontos; SSE no checkout, lido por `fetch` com o token no `Authorization` e acordado por `NOTIFY` no commit do pagamento; gRPC unário de 120 ms para a Vigia. 300 polls por segundo viraram 600 conexões quietas; o Hornero vê o painel em 140 ms. O analista deles largou o crochê com o casaco pela metade.

O Carlos integrou a Vigia com o stub síncrono do gRPC dentro de um `async def`, "porque é só uma chamada", ao lado do cliente do adquirente, que sempre foi síncrono. Cada autorização trava o processo por quase um segundo, e os 100 checkouts dele congelam junto, educadamente, sem erro. O polling pelo menos falhava com status.

## Referências

- Fielding, R. *Architectural Styles and the Design of Network-based Software Architectures*, 2000: https://ics.uci.edu/~fielding/pubs/dissertation/top.htm
- RFC 9110, HTTP Semantics: https://www.rfc-editor.org/rfc/rfc9110
- Protocol Buffers, Encoding: https://protobuf.dev/programming-guides/encoding/
- gRPC over HTTP/2: https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md
- gRPC-Web: https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md
- GraphQL Specification: https://spec.graphql.org/
- DataLoader: https://github.com/graphql/dataloader
- GitHub, Rate limits and node limits for the GraphQL API: https://docs.github.com/en/graphql/overview/rate-limits-and-node-limits-for-the-graphql-api
- RFC 6455, The WebSocket Protocol: https://www.rfc-editor.org/rfc/rfc6455
- HTML Living Standard, Server-sent events: https://html.spec.whatwg.org/multipage/server-sent-events.html
- PostgreSQL, `NOTIFY`: https://www.postgresql.org/docs/current/sql-notify.html
- Kubernetes Blog, gRPC Load Balancing on Kubernetes without Tears (2018): https://kubernetes.io/blog/2018/11/07/grpc-load-balancing-on-kubernetes-without-tears/
