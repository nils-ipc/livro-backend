# HTTP em profundidade

## O link que estornava sozinho

Na quarta-feira, às 10h12, o Carlos colou um link no canal do suporte para provar ao financeiro como o painel da Lastro é prático. O link era `https://painel.lastro.com.br/cobrancas/0190c3a1.../estornar?valor=129900`. Três segundos depois, o robô de pré-visualização do chat abriu o link para gerar a miniatura, e a Capinhas Hiper Ltda. perdeu R$ 1.299,00 de uma venda de R$ 2.598,00 (um kit de 200 capinhas, porque a Capinhas nunca vende uma capinha só).

O financeiro encaminhou o link à contabilidade com o assunto "isso é normal?". O antivírus do e-mail abriu o link para ver se tinha malware. Tinha: estornou os outros R$ 1.299,00.

O Carlos abriu o link de novo para mostrar que estava tudo sob controle, levou "sem valor estornável" e chamou isso de "a validação funcionando". O tabelião do ledger registrou os dois estornos com perfeição, e nenhum foi pedido por um ser humano. O Bazar abriu o chamado às 10h31, "URGENTE!!!!", com o corpo "quem estornou?". A resposta honesta era "um robô e um antivírus", e ninguém teve coragem de mandar.

E a Lastro está abrindo a API de cobranças para mais marketplaces, começando a aceitar cartão por um adquirente e levando o checkout para o navegador do comprador. O que o HTTP promete sobre cada requisição, e como uma API de dinheiro se apoia nessas promessas em vez de ser atropelada por elas?

## HTTP/1.1, ou texto puro com pretensão de protocolo

O HTTP/1.1 (RFC 9112 no fio, RFC 9110 na semântica) é texto sobre TCP: linha de pedido, cabeçalhos, linha em branco, corpo opcional.

```http
POST /v1/cobrancas HTTP/1.1
Host: api.lastro.com.br
Content-Type: application/json
Content-Length: 59

{"valor": 259800, "metodo": "pix", "pedido_id": "BZ-88412"}
```

O fim da mensagem vem de `Content-Length`, com o número exato de bytes, ou de `Transfer-Encoding: chunked`, com pedaços prefixados pelo tamanho e um pedaço final de tamanho zero. Quando proxy e servidor discordam sobre qual vale, nasce o *request smuggling*: uma requisição escondida no corpo da outra. Um protocolo de 1997 com ambiguidade no "onde acaba". Igual reunião de planejamento.

A conexão é persistente por padrão (o *keep-alive* do capítulo 8), porém monogâmica: uma requisição por vez. O *pipelining* exige respostas na ordem dos pedidos, e uma resposta lenta segura as de trás. Esse *head-of-line blocking* fez os navegadores desligarem o pipelining e abrirem seis conexões por host. Uma geração de engenheiros otimizou páginas criando subdomínios falsos (`img1`, `img2`, `img3`) para enganar o limite, e ninguém foi preso.

## HTTP/2: cem conversas numa conexão só, e todas morrem juntas

O HTTP/2 (RFC 9113) mantém a semântica e troca o formato no fio: *frames* binários com cabeçalho de 9 bytes (tamanho, tipo, flags e o ID do *stream*, uma troca requisição-resposta). Streams do cliente têm IDs ímpares crescentes, e os frames de vários se intercalam. Isso é a **multiplexação**: cem requisições em voo numa conexão TCP, cada uma terminando quando terminar.

`SETTINGS` negocia limites, como `SETTINGS_MAX_CONCURRENT_STREAMS` (a RFC recomenda não menos que 100); `WINDOW_UPDATE` faz controle de fluxo por stream; `RST_STREAM` cancela um stream sem matar a conexão; `GOAWAY` encerra a conexão com o ID do último stream que o servidor processou ou vai processar. Streams com ID maior nunca foram tocados e podem ir para outra conexão, mesmo um `POST` de cobrança. É o único momento do HTTP em que o servidor diz com certeza "isso eu não fiz". No capítulo 16 você vai sentir saudade dele.

Os cabeçalhos são comprimidos com **HPACK** (RFC 7541): tabela estática de 61 entradas, tabela dinâmica por conexão (4.096 bytes por padrão) e Huffman. Na segunda requisição, o `Authorization` de 200 bytes vira um ou dois. O HPACK evita DEFLATE porque a compressão genérica vazou cookies no ataque CRIME, em 2012. O HTTP/2 aprendeu com a morte dos outros, o único método de ensino desta profissão.

A parte triste: todos os streams viajam num fluxo TCP, que entrega bytes em ordem, e um pacote perdido segura todos até a retransmissão. O HTTP/2 trocou seis conexões que travavam sozinhas por uma que trava todo mundo. Coletivismo de rede.

```text
Stream 1 (autorização R$ 89,90):  pronta, esperando
Stream 3 (autorização R$ 12,00):  pronta, esperando
Stream 5 (estorno R$ 1.299,00):   pronta, esperando
TCP:     perdi o segmento 4.812. ninguém sai daqui até ele chegar.
Stream 5: mas eu não estava no segmento 4.812.
TCP:     solidariedade.
```

## HTTP/3: o QUIC desistiu do TCP e foi morar no UDP

O HTTP/3 (RFC 9114) roda sobre o QUIC (RFC 9000), um transporte confiável sobre UDP. O QUIC refaz no espaço do usuário o que o TCP faz no kernel (confirmação, retransmissão, controle de congestionamento), com streams independentes no transporte: pacote perdido no stream 5 segura só o stream 5. Os cabeçalhos usam QPACK (RFC 9204).

O TLS 1.3 vem embutido no handshake: conexão nova custa 1 RTT, em vez dos 2 de TCP mais TLS. A primeira chamada do Hornero cairia de 3 RTTs para 2 (capítulo 8). O 0-RTT continua com o risco de *replay* que a Lastro já recusou, e reenviar criação de cobrança o vendedor 42 já faz sem ajuda de protocolo.

A conexão QUIC é identificada por um *connection ID*. O celular do comprador troca do Wi-Fi para o 4G no meio do checkout e a conexão sobrevive; no TCP, a quíntupla mudou, a conexão morreu, e o comprador desistiu da compra e do marketplace. O cliente descobre o HTTP/3 pelo cabeçalho `Alt-Svc` ou pelo registro DNS `HTTPS` (RFC 9460), e volta para TCP quando a rede bloqueia UDP na porta 443, porque o firewall de 2009 acha que todo UDP é torrent.

## Métodos, ou a promessa que todo robô da internet cobra do seu GET

A RFC 9110 define duas propriedades de método que explicam o estorno do Carlos inteiro. Um método é **seguro** (*safe*) quando a semântica é só leitura: o cliente não pede mudança de estado. É **idempotente** quando o efeito pretendido de N requisições idênticas no servidor é o mesmo de uma. A resposta pode variar: um `DELETE` repetido devolve `204` e depois `404`, e o recurso está apagado nos dois casos.

| Método | Seguro | Idempotente |
|--------|--------|-------------|
| `GET`, `HEAD`, `OPTIONS` | sim | sim |
| `PUT`, `DELETE` | não | sim |
| `POST`, `PATCH` | não | não |

Essas propriedades são um contrato com o resto da internet. Robôs de pré-visualização, scanners de e-mail e o *prefetch* do navegador fazem `GET` em qualquer link; clientes e proxies reenviam sozinhos requisições idempotentes quando a conexão cai, porque a RFC autoriza. O Carlos quebrou a primeira promessa, e a internet cobrou a parte dela com a eficiência de um oficial de justiça.

A RFC aceita efeitos colaterais num `GET` (log, contador), desde que o cliente não os tenha pedido nem seja responsabilizado por eles. Estornar R$ 1.299,00 foi um efeito colateral pelo qual o Carlos foi muito responsabilizado.

O `POST` não promete nada. Se a conexão caiu depois do envio, o cliente não sabe se a cobrança foi criada; a chave de idempotência, que dá ao `POST` a propriedade que o método não tem, é o capítulo 16.

## Status, ou três dígitos para dizer o que aconteceu

O status é a parte da resposta que intermediários e bibliotecas entendem sem ler o corpo, e ele dirige comportamento automático: um `503` com `Retry-After` convida a tentar de novo, um `422` avisa que repetir dá o mesmo erro. Os que uma API de pagamentos usa, na RFC 9110:

- `201 Created`, com o recurso novo em `Location`; `202 Accepted`, aceito para um processamento que ainda não terminou. A RFC chama o `202` de "intencionalmente evasivo", o status mais honesto do protocolo.
- `307` e `308` mantêm o método; `301` e `302` deixam, por histórico, o cliente trocar `POST` por `GET`, e a criação de cobrança vira consulta. Silenciosamente.
- `401` (sem credencial válida), `403` (sem permissão), `405` (com `Allow`), `409` (conflito com o estado do recurso), `412`, `422`, `429` (capítulo 28); `502` (o proxy recebeu lixo de trás), `503`, `504` (o proxy cansou de esperar).

E o `402 Payment Required` está "reservado para uso futuro" desde a RFC 2068, de 1997. Quase trinta anos de uso futuro. Mais antigo que o `temp-01` e com menos responsabilidade.

O pecado capital é o `200` com `{"erro": "saldo insuficiente"}` no corpo: o Bazar vê `200`, marca o pedido como pago e despacha o kit de capinhas. É o log `Erro: sucesso` promovido a contrato público.

## Cache e validação condicional, ou como guardar dinheiro velho

A RFC 9111 define quem guarda uma resposta e por quanto tempo: caches privados (o do navegador) ou compartilhados (proxies, CDNs). O `Cache-Control` manda neles: `max-age=N` declara a resposta fresca por N segundos (`s-maxage` só para os compartilhados); `private` proíbe os compartilhados; `public` libera; `no-store` proíbe guardar; e `no-cache` permite guardar, desde que revalide antes de cada uso. Sim, "no-cache" significa "cache, sim, com fiscalização". O nome foi escolhido por alguém que também batiza variáveis de `temp`.

Sem `Cache-Control`, um cache pode inventar frescor por heurística a partir do `Last-Modified`, e um proxy de terceiros decide quanto tempo o saldo do vendedor fica velho. A validação condicional evita reenviar o que não mudou: o servidor manda um `ETag`, identificador opaco da versão, e o cliente o devolve em `If-None-Match`:

```http
GET /v1/cobrancas/0190c3a1-7e2b-7c41-9d0f-5b2a8e6f1c33 HTTP/1.1
If-None-Match: "v4"

HTTP/1.1 304 Not Modified
ETag: "v4"
Cache-Control: private, no-cache
```

O `304` não tem corpo e economiza bytes; o RTT continua. O `ETag` pode ser forte (`"v4"`, idêntico byte a byte) ou fraco (`W/"v4"`, equivalente em significado).

O irmão de escrita é o `If-Match`: "aplique só se a versão ainda for `v4`", senão `412`. É o controle otimista do capítulo 4, e o perdedor recebe um status em vez de um `UPDATE` que afetou zero linhas. O `428` (RFC 6585) obriga o cliente a mandar a condição.

O `Vary` diz quais cabeçalhos da requisição mudam a resposta (`Vary: Origin`). Sem ele, um cache compartilhado serve a resposta de um cliente para outro. Num cadastro de gatos, é um bug. Num sistema de pagamentos, é um incidente com nome, data e advogado.

## CORS, a regra de segurança que só o navegador respeita

O navegador aplica a *same-origin policy*: um script de uma origem (esquema, host e porta) não lê respostas de outra. Pelo CORS (Fetch Standard, do WHATWG), o servidor autoriza exceções, e quem obedece é o navegador. O `curl`, o Python e o atacante não estão nem aí para CORS, e nunca estiveram.

Na requisição simples (`GET`, `HEAD` ou `POST`, com cabeçalhos da lista segura e `Content-Type` só `text/plain`, `multipart/form-data` ou `application/x-www-form-urlencoded`), o navegador manda direto, com `Origin`, e só entrega a resposta ao script se vier `Access-Control-Allow-Origin` compatível. O detalhe que derruba gente experiente: a requisição foi processada. O CORS bloqueou a leitura, e o estorno aconteceu do mesmo jeito (requisição forjada é CSRF, capítulo 32).

Qualquer outra coisa (`application/json`, `Authorization`, `DELETE`) dispara o *preflight*, um `OPTIONS` perguntando se pode:

```http
OPTIONS /v1/checkout/cobrancas/0190c3a1-7e2b-7c41-9d0f-5b2a8e6f1c33 HTTP/1.1
Origin: https://www.bazarbemtevi.com.br
Access-Control-Request-Method: GET
Access-Control-Request-Headers: authorization

HTTP/1.1 204 No Content
Access-Control-Allow-Origin: https://www.bazarbemtevi.com.br
Access-Control-Allow-Headers: authorization
Access-Control-Max-Age: 7200
Vary: Origin
```

O `Access-Control-Max-Age` diz quanto tempo o navegador guarda a resposta (o Chromium limita a 7.200 segundos), por origem e URL: cobrança nova, um RTT inteiro de "posso?" antes do "quero". Com cookies, o servidor precisa de `Access-Control-Allow-Credentials: true` e origem explícita, porque o navegador recusa o curinga `*` com credenciais. A especificação proibiu exatamente a configuração que todo mundo tenta primeiro.

## A API de cobranças da Lastro

### Os métodos e os status

O endpoint antigo do painel passa a responder `405` com `Allow: POST`, e o estorno vira um formulário com confirmação. O robô do chat agora só leva a página de confirmação, que lê com a atenção de um gerente lendo postmortem. A API pública:

| Operação | Requisição | Resposta |
|----------|-----------|----------|
| Criar cobrança Pix | `POST /v1/cobrancas` | `201`, `Location`, estado `pendente` |
| Criar cobrança cartão | `POST /v1/cobrancas` | `201`, `autorizada` ou `recusada` (adquirente síncrono, ~800 ms) |
| Consultar | `GET /v1/cobrancas/{id}` | `200` ou `304`, `ETag` |
| Capturar | `POST /v1/cobrancas/{id}/captura` | `200` |
| Estornar | `POST /v1/cobrancas/{id}/estornos` | `202`, `Location: /v1/estornos/{id}` |
| Consultar estorno | `GET /v1/estornos/{id}` | `200`: `processando`, `concluido` ou `falhou` |
| Listar moedas | `GET /v1/moedas` | `200`, `public, max-age=86400` (muda uma vez por argentino) |

Cobrança recusada pelo emissor volta `201` com estado `recusada`: recusa é resultado de negócio, e um `4xx` faria a biblioteca do cliente lançar exceção no dia mais normal de uma fintech. `422` é corpo válido com conteúdo impossível (split que soma 103%); `409`, conflito com o estado (estornar cobrança `pendente` ou mais do que resta). O formato do erro é o capítulo 11.

O estorno usa `202` porque o débito no ledger é imediato (serializable, capítulo 3), mas a devolução depende do banco parceiro ou do adquirente; o marketplace acompanha pelo `Location`, e um webhook avisa a conclusão.

A consulta leva `ETag` da coluna nova `versao` de `cobrancas`, incrementada a cada mudança de estado, e `private, no-cache`. O Hornero consulta a cobrança Pix a cada 2 segundos, e 95% das consultas voltam `304` (tempo real é o capítulo 12). O saldo responde `no-store`: nenhum cache guarda o número que decide um saque (capítulo 22).

### O adquirente e a conexão compartilhada

A autorização é uma chamada HTTPS ao adquirente de ~800 ms. No pico atual de 12 pagamentos por segundo, a Lei de Little (capítulo 14) dá 12 × 0,8 ≈ 10 autorizações simultâneas. O contrato limita cada subcredenciadora a 20 conexões simultâneas, e a Lastro tem 6 processos (3 workers em `temp-01`, 3 em `api-01`).

| Opção | Concorrência | Teto/s | Custo |
|-------|-------------|--------|-------|
| Conexão nova por chamada | 20 | 25 | handshakes em toda autorização; TIME_WAIT |
| HTTP/1.1 com pool | 20 | 25 | a Black Friday não cabe |
| HTTP/2, 1 conexão por processo | 6 × 100 = 600 | 750 | perda de pacote atrasa 1/6 das autorizações em voo |

A Lastro usa HTTP/2, negociado por ALPN: o teto de 25 por segundo do HTTP/1.1 é só o dobro do pico atual, e a Black Friday vem aí (capítulo 14). No `GOAWAY`, streams acima do último ID processado vão para uma conexão nova; os abaixo não são reenviados sem chave de idempotência. HTTP/1.1 com pool seria a escolha com adquirente sem limite de conexões ou sem HTTP/2, ou num caminho com muita perda, em que conexões independentes isolam o estrago. Para os marketplaces nada muda: o Uvicorn fala HTTP/1.1, e com o keep-alive do capítulo 8 basta; HTTP/2 na borda depende de um proxy (capítulos 10 e 27).

### O checkout no navegador

O checkout da Lastro roda na página do marketplace (`https://www.bazarbemtevi.com.br`) e consulta `https://api.lastro.com.br/v1/checkout/...` para mostrar o QR Code e o estado do Pix. Origens diferentes: CORS. O Carlos propôs `Access-Control-Allow-Origin: *` com `Allow-Credentials: true`, "pra não dar problema". O navegador recusou, e o Chromium virou o primeiro revisor da Lastro a barrar um PR do Carlos.

Só `/v1/checkout/` responde CORS; a chave secreta do marketplace nunca vai ao navegador. O checkout usa um token de curta duração, restrito a uma cobrança, no `Authorization` (capítulo 30). Na URL, o token dispensaria o preflight e terminaria impresso em log de proxy e `Referer`, então a Lastro paga o RTT. A origem é conferida contra a lista cadastrada do marketplace e devolvida como veio, com `Vary: Origin`, sem cookies e com `Max-Age` de 7.200 segundos.

## Armadilhas e casos reais

> **Na vida real:** em 2005, o Google Web Accelerator fazia prefetch dos links das páginas visitadas, e aplicações que apagavam registros com links `GET` viram dados sumir sem ninguém clicar. É o estorno do Carlos com vinte anos de antecedência. O Carlos ainda não estava na indústria; o espírito dele já estava.

> **Na vida real:** em outubro de 2023, a CVE-2023-44487 (*HTTP/2 Rapid Reset*) permitiu ataques recordes; o Google mitigou um pico de 398 milhões de requisições por segundo. O atacante abre um stream e manda `RST_STREAM` logo depois: o stream sai da conta do `MAX_CONCURRENT_STREAMS`, com o trabalho do servidor já começado. A multiplexação virou uma maternidade de requisições natimortas.

> **Armadilha:** desde a versão 1.9.13, o nginx não repassa ao próximo servidor um `POST` já enviado, a menos que `proxy_next_upstream` inclua `non_idempotent`. Alguém acrescenta o parâmetro para "resolver" um `502` e passa a cobrar o comprador duas vezes. O `502` sumiu. O comprador também.

> **Armadilha:** `no-cache` em dado pessoal, achando que nada é guardado. O dado fica no disco do proxy, e o próximo erro de `Vary` entrega o extrato de um vendedor a outro. Dado que não pode ser guardado leva `no-store`.

## Resumo

- HTTP/1.1: texto, uma requisição por vez por conexão; HTTP/2: streams multiplexados, HPACK, `GOAWAY`, head-of-line blocking do TCP; HTTP/3: QUIC, streams independentes, 1 RTT, connection ID.
- Seguro é só leitura; idempotente é N requisições com efeito de uma. Robôs e retentativas automáticas contam com isso.
- O status dirige o comportamento automático dos clientes; `202` para o que termina depois.
- `Cache-Control`, `ETag` com `If-None-Match` (`304`) e `If-Match` (`412`), `Vary`.
- CORS: o navegador aplica, o servidor autoriza; requisição simples é processada mesmo sem permissão de leitura.

## A Lastro agora

A API de cobranças da Lastro segue a semântica do HTTP: `201` para criar, `202` para estornos, `409` e `422` para erros do cliente, `ETag` nas consultas, `no-store` no saldo, estorno só por `POST`. O adquirente recebe HTTP/2 com 600 streams contra o limite de 20 conexões, e o checkout usa CORS com origens cadastradas. A Capinhas recebeu os R$ 2.598,00 de volta em dois lançamentos novos, porque o tabelião não apaga nada, nem constrangimento.

O Carlos colou o link antigo de novo "só pra testar a correção", e o robô do chat recebeu um `405` educado. Ninguém conferiu a data do certificado TLS de `api.lastro.com.br`, emitido à mão pelo fundador num sábado e com vencimento numa madrugada de domingo. Às 3h, todas essas respostas vão continuar perfeitas, com o status certo, o `ETag` certo e o CORS certo, e nenhum cliente vai conseguir abrir a conexão para receber nenhuma delas.

## Referências

- RFC 9110, *HTTP Semantics*. <https://www.rfc-editor.org/rfc/rfc9110>
- RFC 9111, *HTTP Caching*. <https://www.rfc-editor.org/rfc/rfc9111>
- RFC 9112, *HTTP/1.1*. <https://www.rfc-editor.org/rfc/rfc9112>
- RFC 9113, *HTTP/2*. <https://www.rfc-editor.org/rfc/rfc9113>
- RFC 7541, *HPACK: Header Compression for HTTP/2*. <https://www.rfc-editor.org/rfc/rfc7541>
- RFC 9000, *QUIC: A UDP-Based Multiplexed and Secure Transport*. <https://www.rfc-editor.org/rfc/rfc9000>
- RFC 9114, *HTTP/3*. <https://www.rfc-editor.org/rfc/rfc9114>
- RFC 9204, *QPACK: Field Compression for HTTP/3*. <https://www.rfc-editor.org/rfc/rfc9204>
- RFC 6585, *Additional HTTP Status Codes*. <https://www.rfc-editor.org/rfc/rfc6585>
- WHATWG, *Fetch Standard*. <https://fetch.spec.whatwg.org/>
- NVD, CVE-2023-44487. <https://nvd.nist.gov/vuln/detail/CVE-2023-44487>
- Google Cloud, "How it works: The novel HTTP/2 'Rapid Reset' DDoS attack". <https://cloud.google.com/blog/products/identity-security/how-it-works-the-novel-http2-rapid-reset-ddos-attack>
- nginx, `proxy_next_upstream`. <https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_next_upstream>
- Wikipedia, "Google Web Accelerator". <https://en.wikipedia.org/wiki/Google_Web_Accelerator>
