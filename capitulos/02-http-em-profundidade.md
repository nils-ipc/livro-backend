# HTTP em profundidade

## O link que cancelava pedidos sozinho

Entre sexta e segunda, 214 pedidos da loja foram cancelados sem que nenhum cliente clicasse em nada. O suporte abre o chamado com um título que já admite o histórico: "pedidos se cancelando sozinhos (de novo?)". Nos logs, cada uma dessas requisições tem token válido, resposta `200 OK` e o IP de um serviço de segurança de e-mail.

A história é hipotética, e o mecanismo é banal. Na sexta às 17h50 (claro), entrou no ar o novo e-mail de confirmação, com um botão "Cancelar pedido" apontando para `GET /pedidos/{id}/cancelar?token=...`. O scanner de links do e-mail corporativo dos clientes abriu cada link para procurar malware. O servidor recebeu o `GET`, cancelou o pedido e agradeceu com um `200 OK`.

Na mesma semana, a página de produto passou uma hora mostrando o preço antigo depois de uma alteração, e o front-end novo, em `https://loja.example.com`, começou a receber erros de CORS, que alguém "resolveu" em produção com `Access-Control-Allow-Origin: *` e um commit chamado `fix definitivo`.

Os três problemas têm a mesma raiz: entre a sua API e o seu front-end existem navegadores, proxies, CDNs e scanners, e todos agem conforme o que a especificação diz sobre cada método e cabeçalho. O que o protocolo autoriza cada um deles a fazer com as suas requisições?

## HTTP/1.1, texto puro com quebra de linha obrigatória

A semântica do HTTP (RFC 9110) e o cache (RFC 9111) valem para todas as versões; o formato no fio tem uma RFC por versão (9112, 9113 e 9114).

No HTTP/1.1, a mensagem é texto: linha inicial, cabeçalhos `Nome: valor`, cada linha terminada em CRLF, uma linha vazia e o corpo:

```http
POST /pedidos HTTP/1.1
Host: api.example.com
Content-Type: application/json
Content-Length: 24

{"produto": 7, "qtd": 2}
```

O `Host` é obrigatório e permite vários domínios no mesmo IP. O tamanho do corpo vem de `Content-Length` ou de `Transfer-Encoding: chunked` (pedaços precedidos do tamanho, para respostas de tamanho desconhecido, como um CSV de 2 GB gerado por uma consulta que ninguém deveria ter permitido). Se proxy e servidor discordam sobre qual usar, um atacante esconde uma requisição dentro da outra (*request smuggling*).

### Keep-alive, ou por que abrir conexão custa caro

No HTTP/1.0, cada requisição abria e fechava uma conexão TCP. No 1.1, a conexão é persistente por padrão (*keep-alive*) e fica aberta até alguém enviar `Connection: close` ou fechar por inatividade.

O motivo é o preço da abertura: uma conexão HTTPS nova paga 1 RTT de TCP e 1 RTT de TLS 1.3 antes do primeiro byte. Com 40 ms de RTT, são 80 ms de cerimônia para um endpoint que responde em 3 ms. Reusar a conexão também evita acumular sockets em TIME_WAIT (o capítulo 1 mostra como isso esgota as portas efêmeras).

O limite estrutural do 1.1: uma requisição de cada vez por conexão. O *pipelining* existe na especificação, mas as respostas voltam na ordem dos pedidos, e uma resposta lenta trava as de trás (*head-of-line blocking*); proxies o implementavam tão mal que os navegadores o desligaram. A saída foi abrir umas seis conexões por origem, multiplicando handshakes em nome da otimização.

## HTTP/2, binário e multiplexado

O HTTP/2 mantém a semântica e troca o formato: a conexão carrega *frames* binários com cabeçalho de 9 bytes (tamanho, tipo, flags e o identificador do *stream*, que é uma troca requisição/resposta). Os tipos mais vistos são `HEADERS`, `DATA`, `SETTINGS`, `WINDOW_UPDATE`, `RST_STREAM` (cancela um stream) e `GOAWAY` (a conexão vai fechar).

Como cada frame diz a que stream pertence, streams diferentes se intercalam na mesma conexão TCP: cem requisições simultâneas numa conexão só, com respostas voltando na ordem em que ficam prontas. O servidor limita a concorrência com `SETTINGS_MAX_CONCURRENT_STREAMS` (a RFC recomenda pelo menos 100), e cada stream tem janela de controle de fluxo própria, para que um download enorme não sufoque as requisições pequenas ao lado.

A linha de requisição virou pseudo-cabeçalhos (`:method`, `:scheme`, `:authority`, `:path`), e os nomes de cabeçalho são obrigatoriamente minúsculos. O código que comparava `"Content-Type"` na mão descobriu a regra numa madrugada.

### HPACK

Toda requisição de um cliente repete o mesmo `user-agent` e o mesmo `cookie` de 1 KB. O HPACK (RFC 7541) usa uma tabela estática de 61 entradas comuns (`:method: GET` é o índice 2), uma tabela dinâmica de 4.096 bytes por padrão com os cabeçalhos já enviados na conexão, e Huffman para os literais. Na segunda requisição, o `cookie` de 1 KB vira um índice de um byte. A tabela dinâmica exige que os dois lados processem os cabeçalhos exatamente na mesma ordem, detalhe que derruba o HPACK no HTTP/3.

O HTTP/2 é negociado no handshake TLS pela extensão ALPN (o cliente oferece `h2` e `http/1.1`, o servidor escolhe). O *server push* continua na RFC 9113, mas o Chrome o removeu em 2022: ele vivia empurrando arquivos que o navegador já tinha em cache.

O problema que sobrou mora uma camada abaixo. O TCP entrega bytes em ordem, e um pacote perdido faz tudo o que chegou depois esperar a retransmissão, inclusive frames de streams que não tinham nada a ver com ele. O head-of-line blocking só mudou de endereço. Com perda alta, uma conexão HTTP/2 pode render menos que seis conexões HTTP/1.1, porque uma perda trava todos os streams de uma vez.

## HTTP/3, ou o TCP reescrito em cima do UDP

O HTTP/3 roda sobre o QUIC (RFC 9000), transporte construído sobre UDP em espaço de usuário, que refaz entrega confiável e controle de congestionamento e acrescenta o que o TCP não ganharia sem atualizar todos os kernels do planeta.

- **Streams independentes no transporte.** A perda de um pacote atrasa só o stream a que ele pertence.
- **TLS 1.3 embutido.** Transporte e criptografia num handshake só: conexão nova custa 1 RTT em vez de 2.
- **0-RTT.** Numa reconexão, a requisição vai no primeiro pacote, mas pode ser repetida por quem a capturar (*replay*). Por isso servidores liberam 0-RTT só para métodos seguros e podem recusar o resto com `425 Too Early` (RFC 8470), reabrindo por outro caminho o problema do scanner de e-mail.
- **Connection ID.** A conexão sobrevive quando o celular troca do Wi-Fi para a rede móvel.

Sem ordem garantida entre streams, o HTTP/3 troca o HPACK pelo QPACK (RFC 9204), que atualiza a tabela num stream separado.

O cliente descobre o HTTP/3 pelo cabeçalho `Alt-Svc: h3=":443"; ma=86400` ou pelo registro DNS `HTTPS` (RFC 9460), e mantém o TCP como plano B, porque redes que bloqueiam UDP na porta 443 ainda existem. E o QUIC gasta mais CPU por byte que o TCP do kernel, que tem décadas de otimização e ajuda da placa de rede.

## Métodos, segurança e idempotência

Agora a parte que cancelou 214 pedidos: as duas propriedades de método da RFC 9110.

Um método é **seguro** quando o cliente não pede mudança de estado no servidor: `GET`, `HEAD`, `OPTIONS` e `TRACE`. O servidor pode registrar log ou contar visitas, mas o cliente não pediu nada disso, e crawlers, pré-carregamento de links e scanners seguem `GET` sem pedir licença. O scanner do primeiro parágrafo cumpriu a RFC à risca; quem a descumpriu foi o endpoint.

Um método é **idempotente** quando o efeito pretendido de N requisições iguais é o mesmo de uma. Os seguros são idempotentes por definição, e `PUT` e `DELETE` também. A definição fala de efeito no servidor, e não da resposta: o primeiro `DELETE /pedidos/42` devolve `204` e o segundo devolve `404`, e o estado final é o mesmo.

`POST` e `PATCH` não são nem uma coisa nem outra. A idempotência importa por causa da falha mais chata da rede: a conexão cai depois de a requisição sair e antes de a resposta chegar, e o cliente não sabe se o servidor executou. A RFC 9110 permite que clientes e proxies repitam sozinhos requisições idempotentes nessa situação e pede que não repitam as outras. Um `PUT` repetido grava o mesmo valor duas vezes. Um `POST /pagamentos` repetido cobra duas vezes, e tornar esse `POST` seguro para retry exige chave de idempotência (capítulo 20).

```text
Proxy:    POST /pagamentos (a conexão caiu, sem resposta)
Cliente:  E aí?
Proxy:    Não sei se foi. A RFC pede que eu não tente de novo.
Cliente:  Então eu tento.
Servidor: (cobra duas vezes, desta vez por decisão sua)
```

## Códigos de status que mudam o comportamento de alguém

A classe vem do primeiro dígito (2xx sucesso, 3xx redirecionamento, 4xx erro do cliente, 5xx erro do servidor), e clientes, proxies e monitoramento decidem por ela. Devolver `200 OK` com `{"erro": "falhou"}` engana todos de uma vez: o painel mostra 100% de sucesso, ninguém faz retry, e o log registra, com toda a seriedade, `Erro: sucesso`.

Os que mais surpreendem:

- **`301` e `302` contra `308` e `307`.** Ao seguir `301` ou `302`, clientes podem trocar `POST` por `GET`, por razões históricas; `307` e `308` proíbem a troca. E o `301` é cacheável por padrão: um redirecionamento permanente errado vive no navegador de cada usuário até ele limpar o cache.
- **`401` contra `403`.** "Não sei quem você é" contra "sei quem você é, e a resposta continua sendo não".
- **`429`** (RFC 6585) **e `503`**, com `Retry-After` opcional (capítulo 28).
- **`502` e `504`.** Gerados quase sempre pelo proxy ou balanceador: o upstream fechou a conexão ou respondeu lixo (`502`), ou não respondeu a tempo (`504`). Um pico de `502` sem nenhum erro no log da aplicação aponta para o trecho entre o proxy e ela.

## Cache HTTP, ou como servir o preço antigo por uma hora

A RFC 9111 rege caches privados (o do navegador) e compartilhados (proxies, CDNs), e quem manda neles é o `Cache-Control`. Enquanto a resposta está **fresca**, o cache a entrega sem falar com o servidor; depois que fica **velha** (*stale*), precisa revalidar. O frescor vem de `max-age` em segundos ou de `s-maxage`, que vale só para caches compartilhados. Sem nada explícito, a RFC permite frescor heurístico, sugerindo 10% do tempo desde o `Last-Modified`: um arquivo modificado há 10 dias ganha um dia de cache que ninguém configurou, cortesia do protocolo.

| Diretiva | O que faz |
|----------|-----------|
| `no-cache` | pode guardar, mas revalida antes de cada uso |
| `no-store` | proíbe guardar |
| `private` | só o navegador guarda; CDN e proxy não |
| `must-revalidate` | velha nunca é servida sem revalidar, nem com a origem fora do ar |
| `stale-while-revalidate=30` | serve a velha por até 30 s enquanto revalida (RFC 5861) |
| `immutable` | o conteúdo daquela URL nunca muda, nem revalida (RFC 8246) |

Sim, `no-cache` permite cache; quem quer impedir usa `no-store`, e a especificação segue sem pedir desculpas pelos nomes. A página de produto da introdução tinha `max-age=3600` herdado da configuração dos arquivos estáticos, e por isso o preço antigo durou exatamente uma hora.

### Validação condicional

O `ETag` identifica a versão do recurso, como `"15d172abbe2c1c11"` (com prefixo `W/`, é fraco: equivalência semântica, sem garantir bytes idênticos). O cliente reenvia o valor em `If-None-Match`; se nada mudou, o servidor responde `304` sem corpo e o cache renova a cópia que tem. O par antigo, `Last-Modified` e `If-Modified-Since`, tem resolução de um segundo e perde duas alterações no mesmo segundo.

A mesma mecânica protege escritas: um `PUT` com `If-Match: "15d172abbe2c1c11"` recebe `412 Precondition Failed` se outro cliente alterou o recurso no meio do caminho, em vez de atropelar a alteração alheia. É controle otimista via HTTP contra a *lost update* (o capítulo 11 mostra o mesmo padrão no banco).

O `Vary` lista os cabeçalhos da requisição que entram na chave do cache. Sem ele, o cache entrega a versão em inglês para quem pediu português. O capítulo 16 aprofunda cache em camadas e invalidação.

## CORS, a regra que só o navegador cumpre

A *same-origin policy* impede que o JavaScript de uma origem (esquema, host e porta) leia respostas de outra. `http://localhost:3000` e `http://localhost:8000` são origens diferentes, o que explica metade das dúvidas de CORS em desenvolvimento.

Com o CORS (padrão Fetch do WHATWG), o servidor declara quais origens podem ler suas respostas, e o navegador aplica a regra. `curl`, `httpx` e o script de um atacante ignoram CORS solenemente: ele protege usuários de navegador contra sites que leem dados com as credenciais deles, e mais ninguém.

1. **Requisição simples**: `GET`, `HEAD` ou `POST`, com cabeçalhos da lista segura e `Content-Type` de formulário ou `text/plain`. O navegador envia direto, com `Origin`; sem `Access-Control-Allow-Origin` compatível, o JavaScript não lê a resposta. Mas a requisição foi executada.
2. **Preflight**: todo o resto, inclusive `POST` com `application/json` ou `Authorization`. Antes, o navegador envia um `OPTIONS` com `Access-Control-Request-Method` e `Access-Control-Request-Headers` e só prossegue se autorizado. O `Access-Control-Max-Age` guarda a autorização, com teto de duas horas no Chromium e 24 no Firefox.

Com cookies ou autenticação HTTP (`credentials: "include"` no `fetch`), a resposta precisa de `Access-Control-Allow-Credentials: true` e de uma origem explícita no `Access-Control-Allow-Origin`. O `*` é proibido nessa combinação. Por isso o "fix definitivo" da introdução funcionou só até o primeiro login.

## Na prática

O keep-alive medido com `httpx`, com servidor de 5 ms e RTT de 30 ms:

```python
import time
import httpx

URL = "https://api.example.com/saude"

inicio = time.perf_counter()
for _ in range(100):
    httpx.get(URL)  # conexão nova a cada chamada: TCP, TLS, tchau
print(f"sem reuso: {time.perf_counter() - inicio:.2f} s")

inicio = time.perf_counter()
with httpx.Client() as cliente:  # pool de conexões, keep-alive
    for _ in range(100):
        cliente.get(URL)
print(f"com reuso: {time.perf_counter() - inicio:.2f} s")

with httpx.Client(http2=True) as cliente:
    print(cliente.get(URL).http_version)
```

```text
sem reuso: 9.61 s
com reuso: 3.62 s
HTTP/2
```

Sem reuso, cada requisição paga TCP, TLS e a ida e volta: 3 × 30 + 5 = 95 ms. Com reuso, só a primeira paga os handshakes, e as outras custam 35 ms. Seis segundos de cerimônia que ninguém pediu.

A validação condicional num endpoint FastAPI:

```python
import hashlib
import json

from fastapi import FastAPI, Request, Response

app = FastAPI()
PRODUTO = {"id": 7, "nome": "Mouse sem fio", "preco": "129.90"}


@app.get("/produtos/7")
def produto(request: Request) -> Response:
    corpo = json.dumps(PRODUTO).encode()
    etag = f'"{hashlib.sha256(corpo).hexdigest()[:16]}"'
    cabecalhos = {"ETag": etag, "Cache-Control": "no-cache"}
    # simplificado: If-None-Match pode trazer uma lista de ETags
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=cabecalhos)
    return Response(corpo, media_type="application/json", headers=cabecalhos)
```

Com `no-cache`, o navegador guarda a resposta e pergunta a cada uso se ela mudou:

```bash
curl -si https://api.example.com/produtos/7 \
  -H 'If-None-Match: "15d172abbe2c1c11"'
```

```text
HTTP/2 304
etag: "15d172abbe2c1c11"
cache-control: no-cache
```

Os nomes em minúsculas denunciam o HTTP/2. Se o preço mudar, o hash muda e o cliente recebe `200` com o corpo novo na hora.

Um preflight contra uma API que aceita a origem da loja com credenciais:

```bash
curl -si -X OPTIONS https://api.example.com/pedidos \
  -H 'Origin: https://loja.example.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type, authorization'
```

```text
HTTP/2 204
access-control-allow-origin: https://loja.example.com
access-control-allow-methods: GET, POST
access-control-allow-headers: authorization, content-type
access-control-allow-credentials: true
access-control-max-age: 600
vary: Origin
```

O `vary: Origin` existe porque a resposta muda conforme a origem; sem ele, um cache poderia entregar a autorização de uma origem para a seguinte.

## Propriedades e custos

| Propriedade | HTTP/1.1 | HTTP/2 | HTTP/3 |
|-------------|----------|--------|--------|
| Transporte | TCP | TCP | QUIC sobre UDP |
| Requisições simultâneas por conexão | 1 | muitas (limite negociado, 100 é comum) | muitas |
| Head-of-line blocking | no HTTP e no TCP | só no TCP | só dentro do stream afetado |
| Handshake de conexão nova com TLS 1.3 | 2 RTT | 2 RTT | 1 RTT (0-RTT em reconexão) |
| Compressão de cabeçalhos | nenhuma | HPACK | QPACK |
| Depuração | texto legível | binário | binário e cifrado |
| Custo de CPU | baixo | baixo | maior |

HTTP/2 e HTTP/3 ganham com muitas requisições concorrentes e RTT alto (páginas com dezenas de recursos, celulares em rede instável), e o HTTP/3 ganha mais quanto maior a perda e quanto mais o cliente troca de rede. No mesmo datacenter, com RTT abaixo de 1 ms, a diferença entre as versões encolhe, e o que pesa é o reuso de conexões; o gRPC exige HTTP/2 (capítulo 24). E como um cliente HTTP/2 usa uma única conexão longa, um balanceador de camada 4, que distribui conexões, joga toda a carga dele num só backend (capítulo 27), que passa a ser, sem saber, o servidor favorito daquele cliente.

## Armadilhas e casos reais

> **Na vida real:** em outubro de 2023 foi divulgado o ataque *HTTP/2 Rapid Reset* (CVE-2023-44487). O atacante abre um stream e o cancela na hora com `RST_STREAM`: o stream sai da conta do limite de concorrência, mas o servidor já começou a trabalhar nele. Em loop, isso dá requisições sem limite prático por conexão, e o Google relatou um pico de 398 milhões por segundo. Tudo dentro da especificação, que deixava cancelar de graça. As correções limitam a taxa de cancelamentos por conexão.

> **Armadilha:** a corrida do keep-alive. O balanceador guarda conexões ociosas com a aplicação por 60 segundos; o Uvicorn as fecha depois de 5 (seu padrão). De vez em quando, o servidor fecha a conexão no instante em que o balanceador a reaproveita, e sai um `502` sem nenhuma linha no log da aplicação. O timeout de keep-alive da aplicação precisa ser maior que o do balanceador.

> **Na vida real:** no Natal de 2015, a loja do Steam mostrou a usuários páginas de conta de outros, com dados pessoais de cerca de 34 mil pessoas. Segundo a Valve, uma mudança na configuração de cache, feita durante um ataque de negação de serviço, fez páginas autenticadas serem guardadas e servidas a terceiros. É o desfecho extremo da resposta personalizada sem `private` ou `no-store`.

> **Armadilha:** CORS não protege contra CSRF. Um formulário de outro site envia um `POST` simples com os cookies do usuário; o navegador esconde a resposta, mas o pedido já foi criado. A defesa são cookies `SameSite`, tokens anti-CSRF ou um cabeçalho obrigatório que force preflight. E refletir qualquer `Origin` no `Access-Control-Allow-Origin`, com credenciais, autoriza a internet inteira a ler os dados dos seus usuários logados.

E os 214 pedidos? O link virou uma página com um botão que envia `POST`. O scanner continua abrindo todos os links que encontra; agora só encontra uma página perguntando se ele tem certeza.

## Resumo

- Semântica (RFC 9110) e cache (RFC 9111) valem para todas as versões. HTTP/1.1: uma requisição por vez por conexão; HTTPS novo custa 2 RTTs. HTTP/2: streams multiplexados, HPACK, head-of-line blocking no TCP. HTTP/3: QUIC, 1 RTT, 0-RTT com replay.
- Seguro: o cliente não pede mudança de estado. Idempotente: N iguais valem uma. Scanners seguem `GET` e proxies repetem os idempotentes.
- `no-cache` revalida, `no-store` proíbe, `private` tira das CDNs. `If-None-Match` gera `304`; `If-Match`, `412`.
- CORS só vale no navegador, não impede a execução de requisições simples e proíbe `*` com credenciais.

## Referências

- RFC 9110, HTTP Semantics: https://www.rfc-editor.org/rfc/rfc9110
- RFC 9111, HTTP Caching: https://www.rfc-editor.org/rfc/rfc9111
- RFC 9112, HTTP/1.1: https://www.rfc-editor.org/rfc/rfc9112
- RFC 9113, HTTP/2: https://www.rfc-editor.org/rfc/rfc9113
- RFC 7541, HPACK: https://www.rfc-editor.org/rfc/rfc7541
- RFC 9114, HTTP/3: https://www.rfc-editor.org/rfc/rfc9114
- RFC 9000, QUIC: https://www.rfc-editor.org/rfc/rfc9000
- RFC 9204, QPACK: https://www.rfc-editor.org/rfc/rfc9204
- RFC 9460, registros DNS SVCB e HTTPS: https://www.rfc-editor.org/rfc/rfc9460
- RFC 8470, Using Early Data in HTTP: https://www.rfc-editor.org/rfc/rfc8470
- RFC 6585, Additional HTTP Status Codes: https://www.rfc-editor.org/rfc/rfc6585
- RFC 5861, HTTP Cache-Control Extensions for Stale Content: https://www.rfc-editor.org/rfc/rfc5861
- RFC 8246, HTTP Immutable Responses: https://www.rfc-editor.org/rfc/rfc8246
- WHATWG Fetch Standard (CORS): https://fetch.spec.whatwg.org/
- NVD, CVE-2023-44487 (HTTP/2 Rapid Reset): https://nvd.nist.gov/vuln/detail/CVE-2023-44487
- Google Cloud, "How it works: The novel HTTP/2 'Rapid Reset' DDoS attack" (2023): https://cloud.google.com/blog/products/identity-security/how-it-works-the-novel-http2-rapid-reset-ddos-attack
- Incidente do Steam (25/12/2015): comunicado público da Valve, dezembro de 2015
