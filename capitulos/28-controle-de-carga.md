# Controle de carga

Na segunda às 11h02, o Mercadito Hornero subiu uma versão nova da integração, e às 11h03 a Lastro descobriu que um `while True` sem condição de parada, do outro lado do continente, é um teste de carga que ninguém agendou e ninguém pode cancelar.

O laço de reconciliação do Hornero passou a consultar `GET /v1/cobrancas/{id}` em todas as cobranças do mês, sem parar, sem `If-None-Match`, por 40 conexões: 4.000 requisições por segundo, que o balanceador do capítulo 27 distribuiu com perfeição entre os nove processos de pagamentos. Cada GET custa ~1,5 ms de CPU (capítulo 14), então cada event loop passou a gastar dois terços do tempo servindo o Hornero. A autorização de cartão, que divide esses loops, foi de p99 1,3 s para 4,8 s, e a criação de Pix do Bazar começou a estourar o timeout de 10 s do próprio Bazar.

O Bazar abriu chamado às 11h09: "URGENTE!!!! O Pix de vocês está mais lento que o meu" (o Pix dele é o mesmo). Às 11h20, o Carlos bloqueou no firewall o IP de saída do Hornero. Funcionou. O Hornero parou de consultar, e parou também de criar cobranças, de capturar cartão e de receber Pix dos compradores, porque tudo sai do mesmo IP. A analista do Hornero passou 25 minutos sem vender nada e, pela primeira vez, sem tempo para o crochê, porque estava abrindo chamado.

Como uma API recusa o excesso de um cliente sem punir os outros e sem matar o próprio cliente, e o que ela sacrifica quando o excesso vem de todos ao mesmo tempo?

## Por que todo sistema tem um limite e quase nenhum sabe qual é

O capítulo 14 deu a fórmula: com utilização ρ, o tempo de resposta cresce com `S / (1 − ρ)`. A 70%, a latência é 3,3 vezes o tempo de serviço; a 90%, 10 vezes; a 99%, 100 vezes. Acima de 100%, a fila cresce sem limite, e a latência também, até alguém desistir.

E alguém desiste. O cliente tem timeout (capítulo 15), corta a conexão e manda de novo. O servidor, que não ficou sabendo, termina a requisição abandonada, gasta CPU numa resposta que ninguém vai ler e põe a nova tentativa no fim da fila. A partir de um ponto, tudo que termina já passou do prazo de quem pediu: a **vazão útil** (*goodput*) vai a zero com a CPU no talo. O dashboard de requisições processadas nunca esteve tão bonito, e nenhum cliente foi atendido. É o sistema mais produtivo e mais inútil da empresa, e ele concorre com o comitê de arquitetura.

Controle de carga mantém o sistema abaixo desse ponto, em três lugares: a **limitação de taxa** (*rate limiting*) define quanto cada cliente pode pedir, mesmo com o sistema folgado; a **contrapressão** (*backpressure*) faz quem está cheio desacelerar quem está antes; e o **descarte de carga** (*load shedding*) recusa parte do trabalho na entrada quando o servidor passa do limite, escolhendo qual parte.

## Os algoritmos de limitação, ou quatro jeitos de contar até cem

Todo limitador pergunta se esta requisição, deste cliente, cabe em N por período. Muda o que ele guarda e quanto erra.

### Janela fixa

Um contador por cliente por janela de calendário (`hornero:2026-11-09T11:03`), incrementado a cada requisição e zerado na virada. Uma chave, um `INCR`, um `EXPIRE`. O defeito está na fronteira:

```text
limite: 100 por minuto
11:03:59.5   100 requisições   (janela 11:03: 100/100, aceitas)
11:04:00.1   100 requisições   (janela 11:04: 100/100, aceitas)
             200 em 0,6 s, e o limitador acha que está tudo certo
```

O cliente pode mandar o dobro do limite em um instante, desde que tenha um relógio. E todo cliente tem um relógio, inclusive o `repasse_final_v2_agora_vai.py`, que tem dois e discorda dos dois.

### Janela deslizante

O **registro deslizante** (*sliding log*) guarda o horário de cada requisição e conta as dos últimos 60 s. É exato e custa memória proporcional ao limite por cliente: para 1.000 por minuto, mil timestamps por chave.

O **contador deslizante** (*sliding window counter*) guarda só dois contadores, a janela atual e a anterior, e estima o total ponderando a anterior pela fração que ainda cai dentro dos últimos 60 s:

```text
estimativa = anterior × (1 − decorrido/janela) + atual
ex.: anterior 84, atual 36, 15 s da janela atual decorridos
     84 × 0,75 + 36 = 99   →   aceita a 100ª, recusa a 101ª
```

A estimativa assume que a janela anterior foi uniforme, e erra pouco (ver o caso da Cloudflare nas armadilhas). Dois inteiros por cliente, quase o registro exato: raro caso em que a aproximação é mais honesta que o planejamento de sprint.

### Balde de fichas e balde furado

O **balde de fichas** (*token bucket*) tem capacidade `b` e recebe fichas à taxa `r` por segundo, até encher. Cada requisição gasta uma ficha; sem ficha, recusa. A taxa média fica limitada a `r`, e uma rajada de até `b` passa de uma vez. Na implementação, ninguém agenda o gotejamento: o balde guarda `(fichas, último_acesso)` e, a cada requisição, soma `r × (agora − último_acesso)` antes de descontar. Dois números por cliente, rajada configurável separada da taxa, e por isso é o algoritmo dos gateways e das APIs públicas.

O **balde furado** (*leaky bucket*) tem dois sentidos na literatura. Como **fila**, as requisições entram num buffer de tamanho `b` e saem à taxa constante `r`, alisando o tráfego ao custo de espera. Como **medidor**, é o balde de fichas visto do outro lado: o nível sobe a cada requisição, vaza à taxa `r`, e o que transborda é recusado. O **GCRA** (*Generic Cell Rate Algorithm*, das redes ATM) é esse medidor guardando um único número por cliente, o horário teórico da próxima chegada, e cabe num script atômico de Redis.

| Algoritmo | Estado por cliente | Rajada | Erro |
|-----------|--------------------|--------|------|
| Janela fixa | 1 contador | até 2× na fronteira | grande na virada |
| Registro deslizante | 1 timestamp por requisição | nenhuma além do limite | zero |
| Contador deslizante | 2 contadores | pequena | ~0,003% medido |
| Balde de fichas / GCRA | 2 números / 1 número | até `b`, explícita | zero para a regra que define |
| Balde furado (fila) | fila de até `b` | absorvida como espera | zero, com latência |

## Limitar com vários gateways, onde o contador mora

Com um gateway, o estado fica na memória dele. Com três, há três opções, e cada uma erra de um jeito.

**Contador central** (Redis, por exemplo): todo gateway atualiza o mesmo estado num comando atômico (script Lua com o GCRA, ou `INCR` com `EXPIRE`). É exato, custa uma ida e volta por requisição e põe uma dependência no caminho de toda chamada. Se o Redis cai, alguém decide entre deixar passar tudo (*fail open*) ou recusar tudo (*fail closed*), e recusar tudo porque o contador sumiu é derrubar a API para protegê-la.

**Contador local com o limite dividido por N**: zero latência e zero dependência, e só funciona se o tráfego de cada cliente se espalhar igual entre os gateways. O capítulo 27 explica por que não se espalha: o balanceador de camada 4 distribui conexões, e um cliente com duas conexões persistentes cai em um ou dois gateways e recebe um terço ou dois terços do contratado, conforme o sorteio de um balanceador que nunca leu o contrato.

**Híbrido**: cada gateway decide localmente e sincroniza com o contador central a cada intervalo (100 ms, por exemplo), aceitando estourar o limite por uma fração do intervalo.

## A resposta: 429, Retry-After e um corpo que explica

A recusa por limite de taxa tem status próprio, o **`429 Too Many Requests`** (RFC 6585), e o **`Retry-After`** (RFC 9110) diz quando tentar de novo, em segundos ou como data. Sobrecarga do servidor é **`503 Service Unavailable`**, também com `Retry-After`. O `429` diz "você pediu demais"; o `503` diz "eu estou cheio, e nada pessoal". Um rascunho do IETF (*RateLimit header fields for HTTP*) padroniza cabeçalhos com a política e a cota restante; até virar RFC, os nomes podem mudar.

```http
HTTP/1.1 429 Too Many Requests
Content-Type: application/problem+json
Retry-After: 1

{"type": "https://api.lastro.com.br/erros/limite-de-taxa",
 "title": "Limite de requisições excedido",
 "status": 429,
 "detail": "Classe 'leitura': 200 requisições/s. Tente em 1 s.",
 "classe": "leitura"}
```

O cliente educado espera o `Retry-After`, recua com backoff e jitter (capítulo 15) e tem orçamento de retentativas. O cliente mal-educado trata o `429` como erro transitório e repete na hora, o que transforma o limitador num gerador de tráfego com dupla contagem. O livro de SRE do Google descreve a defesa do lado do cliente: cada cliente mede as próprias requisições e aceitações recentes e recusa localmente, sem nem enviar, com probabilidade `max(0, (requisições − K × aceitas) / (requisições + 1))`, com `K = 2` como padrão. Quando o servidor recusa muito, o cliente para de insistir sozinho.

## Contrapressão e filas limitadas

Toda fila sem limite é uma promessa que o sistema não sabe que fez. A fila do event loop, o backlog do `listen`, a espera do pool, a fila do proxy: sem teto, absorvem a sobrecarga como latência, que vira timeout lá na frente, onde ninguém sabe de onde veio. Uma fila limitada transforma excesso em recusa rápida e visível.

**Contrapressão** é a fila cheia se propagando para trás. No TCP, a janela de recepção (capítulo 8) faz o remetente parar. No log (capítulo 17), o consumidor puxa no próprio ritmo e o excesso vira atraso no broker. Em HTTP, é o `429`/`503` com `Retry-After` e um cliente que respeita. No resto, o projeto constrói: `asyncio.Queue(maxsize=...)` que bloqueia o produtor, semáforo, bulkhead (capítulo 15).

O critério de corte que melhor acompanha a experiência do cliente é o **tempo na fila**, mais que o tamanho dela. O **CoDel** (RFC 8289), desenhado para roteadores, descarta quando o menor atraso de fila num intervalo fica acima de um alvo; o Facebook descreveu em 2015 (*Fail at Scale*) o uso desse critério em servidores, junto com **LIFO adaptativo**: sob fila longa, atender primeiro a requisição mais nova, porque a mais velha provavelmente já foi abandonada pelo cliente. É cruel com a requisição velha. Ela também é a única que já morreu e ainda não sabe.

## Descarte de carga, ou quem sai do bote primeiro

Se todos os clientes ficam dentro do limite ao mesmo tempo (a Black Friday, o dia 1º), a soma ainda passa da capacidade. O **descarte de carga** recusa trabalho quando o próprio servidor está no limite, por um sinal local: requisições em andamento, lag do event loop, tempo na fila. Recusa **cedo**, antes de autenticar e abrir transação; por limite fixo de concorrência ou por **limite adaptativo**, que ajusta a concorrência pela latência observada, à moda do controle de congestionamento do TCP (a biblioteca *concurrency-limits* da Netflix é um exemplo); e por **prioridade**, começando pelas classes menos importantes.

A prioridade só funciona se a classe sacrificada consumir o mesmo recurso que a protegida. Recusar relatório para salvar autorização só ajuda se os dois disputam a mesma CPU, a mesma fila ou o mesmo banco. Senão, você jogou fora o relatório e a autorização continua lenta, agora sem relatório.

## Na Lastro: limites por marketplace e uma ordem de sacrifício

Os requisitos: o excesso de um marketplace não pode afetar os outros (o p99 do Bazar está em contrato, capítulo 14); o limite é por marketplace e por classe de operação, nunca por IP, para que o Hornero em loop continue recebendo Pix; e, sob sobrecarga geral, autorização e Pix são os últimos a sofrer.

### Limitação no gateway

O gateway identifica o marketplace pela credencial (o capítulo 30 detalha) e aplica um balde de fichas (GCRA) por `(marketplace, classe)`:

| Classe | Rotas | Padrão (`r` / `b`) | Bazar |
|--------|-------|--------------------|-------|
| escrita | criar cobrança, captura, estorno, saque | 50/s / 100 | 300/s / 600 |
| leitura | GET de cobranças, estornos, listagens | 200/s / 400 | 1.000/s / 2.000 |
| painel | GraphQL, relatórios | 20/s / 40 | 60/s / 120 |
| sem limite | `webhooks-pix` (banco parceiro) | – | – |

Os valores ficam a cerca de dez vezes o pico medido de cada marketplace, e os do Bazar acima da projeção de Black Friday do capítulo 14. As classes são separadas para que o laço do Hornero gaste a cota de leitura e ele continue criando cobranças pela de escrita. As notificações do banco ficam fora: recusar uma é arriscar perder a confirmação de um Pix (o banco desiste após três tentativas, capítulo 10).

O estado mora no Redis de cache do capítulo 22: ~120 chaves com expiração, consultadas a cada requisição, as últimas que um LRU despejaria, a ~0,4 ms de ida e volta. Divisão local por três foi descartada pelo sorteio de conexões da seção anterior. Se o Redis cair, cada gateway aplica `limite / 3` localmente: impreciso por alguns minutos, e nunca um *fail closed* que derruba a API porque um contador sumiu.

A resposta é `429` com `Retry-After` e o `type` `limite-de-taxa` (capítulo 11). Status novo em rota existente é mudança de comportamento: os limites entraram no changelog com 30 dias de antecedência, com a obrigação de respeitar o `Retry-After`. Para incidente ativo, há um limite de emergência por marketplace, ajustável sem deploy, que o Carlos deveria ter usado às 11h20 no lugar do firewall.

A segunda-feira das 11h02 se repete assim: o Hornero recebe 200 respostas por segundo e 3.800 `429`, os nove loops gastam 3% do tempo com ele, ninguém mais percebe, e um e-mail automático avisa o Hornero porque a taxa de `429` dele passou de 50% por cinco minutos. A analista volta ao crochê.

### Descarte por prioridade em pagamentos

O limite por marketplace não protege da soma. Cada processo de pagamentos classifica a requisição antes de qualquer trabalho:

- **crítica**: autorização de cartão, criação de Pix, notificação do banco;
- **normal**: captura, estorno, GET de cobrança;
- **descartável**: GraphQL do painel e listagens longas.

O sinal é o lag do event loop (medido desde o capítulo 13): acima de 50 ms, as descartáveis recebem `503` com `Retry-After: 5`; acima de 150 ms, também as normais; as críticas só esbarram nos bulkheads do capítulo 15. O corte acontece no middleware de entrada, antes de banco ou transação, e custa microssegundos. As três classes dividem os mesmos event loops, então recusar uma alivia a outra.

Relatórios, no próprio serviço desde o capítulo 26, têm fila limitada: dois em execução por processo, cinco esperando; o sexto recebe `503` com `Retry-After: 60`. A fila sem limite que o Carlos propôs ("uma hora sai") acumularia, num dia 1º, os 41 relatórios do capítulo 23 mais cada clique impaciente, e andaria para um passado em que ninguém mais está esperando.

No gateway, cada rota tem concorrência máxima até o serviço, e requisição que esperou mais de 1 s na fila recebe `503`, porque o deadline de 8 s da autorização (capítulo 15) não melhora parado. O ledger, que consome `cobrancas.eventos`, tem contrapressão de graça: o pico vira atraso de consumidor, com o alerta de 30 s do capítulo 26.

## Armadilhas e casos reais

> **Armadilha:** limitar por IP numa API de servidores. Um IP de saída costuma ser um NAT com a empresa inteira atrás, e o limite pune o cliente pelo tamanho. O bloqueio do Carlos foi o caso extremo: tirou do ar a operação inteira de um marketplace para conter uma rota dele.

> **Armadilha:** retentativa sem respeitar `Retry-After`. O cliente que repete o `429` na hora, com três camadas de retry (capítulo 15), multiplica o tráfego justo quando o servidor pediu menos. O limitador precisa recusar barato, porque também vai receber o dilúvio.

> **Armadilha:** descartar depois do trabalho caro. O `503` que sai depois da consulta ao banco gastou o recurso escasso para anunciar que ele está escasso, com a eficiência de um comunicado do RH.

> **Armadilha:** health check sujeito ao descarte. O `/pronto` (capítulo 27) recebe `503` do próprio descartador, o balanceador tira a instância, as outras herdam a carga e descartam o health check também. Em minutos, o sistema que descartava 20% para sobreviver descarta 100%. O health check fica fora do descarte.

> **Na vida real:** a Cloudflare publicou em 2017 a análise do contador deslizante do seu limitador: em 400 milhões de requisições de 270 mil origens, 0,003% foram aceitas ou recusadas de forma errada.

> **Na vida real:** a Stripe descreveu em 2017 quatro mecanismos em produção: limitador de taxa por usuário (balde de fichas em Redis), limitador de requisições concorrentes e dois descartadores, um que reserva parte da frota para tráfego crítico e outro por utilização dos workers.

## Resumo

- Acima da capacidade, a vazão útil vai a zero com a CPU no talo.
- Janela fixa deixa passar 2× na fronteira; contador deslizante aproxima com dois números; balde de fichas e GCRA separam taxa de rajada.
- Contador central é exato e custa uma ida e volta; local dividido por N falha com balanceamento por conexão.
- `429` com `Retry-After` para o cliente acima do limite; `503` para o servidor cheio.
- Filas limitadas, contrapressão e corte por tempo na fila.
- Descarte cedo, por sinal local e por prioridade, entre classes que disputam o mesmo recurso.

## A Lastro agora

O gateway limita cada marketplace por classe com GCRA no Redis, devolve `429` com `Retry-After` e cai para `limite / 3` local se o Redis sumir; as notificações do banco não têm limite. Pagamentos corta descartáveis e depois normais pelo lag do event loop, relatórios têm fila de cinco, e o gateway descarta o que esperou mais de 1 s. O Hornero em loop custa 3% de CPU e um e-mail automático, e o Carlos ganhou um botão de limite de emergência, que ele chama de "firewall com pontaria".

Na sexta, o comercial fechou contrato com um marketplace de um grupo de varejo, dez vezes maior que o Bazar, com migração em quatro meses. Todos os números deste capítulo foram calculados sobre o pico do Bazar. O gerente de produto perguntou se dá para "só multiplicar tudo por dez", e o PostgreSQL do ledger, que não foi consultado, começou a suar.

## Referências

- RFC 6585, Additional HTTP Status Codes (429): https://www.rfc-editor.org/rfc/rfc6585
- RFC 9110, HTTP Semantics (Retry-After, 503): https://www.rfc-editor.org/rfc/rfc9110
- RFC 8289, Controlled Delay Active Queue Management: https://www.rfc-editor.org/rfc/rfc8289
- IETF, RateLimit header fields for HTTP (rascunho): https://datatracker.ietf.org/doc/draft-ietf-httpapi-ratelimit-headers/
- Google, Site Reliability Engineering, "Handling Overload": https://sre.google/sre-book/handling-overload/
- Maurer, B., "Fail at Scale", ACM Queue, 2015: https://queue.acm.org/detail.cfm?id=2839461
- Cloudflare, "Counting things, a lot of different things…", 2017: https://blog.cloudflare.com/counting-things-a-lot-of-different-things/
- Stripe, "Scaling your API with rate limiters", 2017: https://stripe.com/blog/rate-limiters
- Netflix, concurrency-limits: https://github.com/Netflix/concurrency-limits
