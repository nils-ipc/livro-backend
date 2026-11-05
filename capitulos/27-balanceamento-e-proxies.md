# Balanceamento e proxies

O processo do antifraude em `api-02` morreu numa quarta às 14h10, e durante 47 minutos o serviço de pagamentos continuou mandando um terço das avaliações para ele, com a lealdade de quem não lê obituário.

A causa da morte foi um segfault, assunto de outro postmortem. O supervisor tentou reiniciar cinco vezes em dez segundos e desistiu, que é o comportamento configurado e também o do Carlos às sextas. Cada processo de pagamentos lia, na partida, a variável que o Carlos mantém à mão desde o capítulo 26:

```text
ANTIFRAUDE_HOSTS=10.0.1.10:7100,10.0.1.11:7100,10.0.1.12:7100
# não mexa. são só seis serviços. (Carlos)
```

O cliente fazia round robin na lista. Uma chamada em cada três ia para `10.0.1.12:7100`, onde ninguém escutava. O kernel de `api-02`, educadíssimo, respondia RST em menos de um milissegundo, e o pagamentos caía na degradação do capítulo 15: até R$ 300,00, regras locais; acima, `recusada` com `antifraude_indisponivel`.

O circuit breaker ficou fechado o tempo todo. Ele abre com mais de 50% de falhas, e a falha era de 33%, uma taxa de erro desenhada com precisão para passar por baixo do radar. Foram 1.128 cartões recusados. O Bazar abriu chamado às 14h31, assunto "URGENTE!!!!", corpo "vocês têm alguma coisa contra notebook?". O Carlos tirou o IP da variável às 14h57 e reiniciou os nove processos de pagamentos, um a um.

Quem decide para onde vai cada requisição, e como esse alguém percebe que uma réplica morreu sem concluir, por conta própria, que morreram todas?

## Camada 4 e camada 7, ou quanto da conversa o balanceador tem coragem de ler

Um **balanceador de carga** recebe tráfego endereçado a um serviço e escolhe, para cada unidade de trabalho, uma das instâncias que o atendem (o *backend*). Qual unidade ele enxerga depende da camada (capítulo 8).

Um **balanceador de camada 4** decide por conexão TCP (ou fluxo UDP), olhando só a quíntupla. Pode reescrever o destino dos pacotes (NAT, com a resposta voltando por ele), entregar o pacote e deixar o backend responder direto ao cliente (DSR, útil quando a resposta é cem vezes maior que a pergunta) ou terminar a conexão e abrir outra até o backend (proxy TCP). Ele não lê HTTP nem precisa das chaves TLS, e segura milhões de conexões com pouca CPU. O preço: balanceia conexões, sem saber o que é uma requisição. Com HTTP/2 e gRPC, uma conexão carrega tudo, e o capítulo 12 já mostrou o resultado: uma réplica afogada e as outras de folga, recebendo salário.

No modo proxy TCP, o backend vê o IP do balanceador e o cliente some do log. O **PROXY protocol**, criado no HAProxy, devolve a origem: antes do primeiro byte do cliente, o balanceador escreve uma linha de texto (versão 1) ou um cabeçalho binário (versão 2):

```text
PROXY TCP4 198.51.100.22 203.0.113.50 51234 443\r\n
<aqui começa o ClientHello do TLS, intocado>
```

Backend que aceita esse prefixo de qualquer origem deixa qualquer um na internet escolher o próprio IP, o que é ótimo para quem quer culpar outra pessoa pelo ataque.

Um **balanceador de camada 7** termina a conexão e o TLS, lê a requisição e escolhe um backend **por requisição**, com conexões próprias até cada instância. Roteia por `Host`, caminho ou cabeçalho, repete o que falhou ao conectar, impõe timeout por rota e balanceia cada stream HTTP/2. Custa CPU, a chave privada guardada nele e um parser HTTP a mais, capaz de entender a requisição diferente do backend (o *request smuggling* do capítulo 9). O L4 deixa passar sem perguntar nada; o L7 abre a mochila, lê o diário, corrige a ortografia e só então decide a sala.

## Os algoritmos, ou como dividir trabalho sem saber quanto trabalho é

**Round robin** percorre a lista em ordem (o ponderado repete as instâncias maiores) e assume que toda requisição custa igual; a instância que pegou três autorizações de 900 ms seguidas recebe a quarta com a mesma alegria. **Aleatório** dispensa estado compartilhado, mas com `n` requisições em `n` instâncias a mais carregada recebe da ordem de `ln n / ln ln n`, longe da média 1. **Menos conexões** (*least connections*) e **menos requisições pendentes** (*least outstanding requests*) mandam para quem tem menos trabalho em andamento, uma medida direta de carga que se adapta a custo variado.

Com uma armadilha de humor negro embutida. A instância que responde erro em 1 ms (porta fechada, `503` imediato) nunca tem nada pendente, e para o least connections ela é a mais saudável do grupo:

```text
Balanceador: Quem está livre?
Réplica 1:   Tenho 14 em andamento.
Réplica 2:   Tenho 12.
Réplica 3:   Zero! Termino tudo na hora!
Balanceador: Que funcionária exemplar. (manda 80% para a 3)
Réplica 3:   (devolve 503 em todas, na hora, como prometido)
```

Na quarta-feira da Lastro, com least connections, o defunto teria recebido quase tudo, e o Bazar perguntaria se a Lastro tem algo contra cartão em geral. Algoritmo por carga só funciona junto com detecção de falha.

**Duas escolhas aleatórias** (*power of two choices*, P2C) sorteia duas instâncias e manda para a menos carregada. Pelo resultado de Azar, Broder, Karlin e Upfal (1994), a carga máxima cai de `ln n / ln ln n` para `ln ln n / ln 2` mais uma constante, uma melhora exponencial por olhar um número a mais. E como a escolha é sorteada, balanceadores com informação atrasada não correm todos para a mesma instância vazia. O `LEAST_REQUEST` do Envoy faz P2C por padrão.

**Hash** manda a mesma chave (IP, cabeçalho, recurso) sempre à mesma instância, o que serve a cache local; o **hash consistente** (capítulo 24) e o **Maglev** do Google (NSDI 2016) movem só ~1/N das chaves quando uma instância sai.

## Health checks, ou o exame médico que pode matar o paciente e a família

Na **checagem ativa**, o balanceador chama um endpoint de cada instância a cada intervalo e a tira de rotação após `k` falhas seguidas; acha morto sem tráfego, com atraso de até `intervalo × k`. Na **checagem passiva** (*outlier detection*), ejeta por tempo crescente a instância com erros reais seguidos; detecta em milissegundos e pega parte das falhas cinzentas do capítulo 15, em que o health check responde lindo e as requisições morrem.

O que o endpoint verifica tem dois sentidos, que o capítulo 35 reencontra no Kubernetes. **Vivacidade** (*liveness*): o processo travou sem conserto? Reinicie. **Prontidão** (*readiness*): a instância consegue atender agora? Se não, pare de mandar tráfego, sem matar ninguém.

Vocês já repararam que todo dev, no primeiro health check, faz um check-up completo? Consulta o banco, pinga o Redis, chama o parceiro e, se der tempo, mede a pressão. Acompanhe a falha: o Redis faz failover e some por 20 segundos, todas as instâncias consultam o mesmo Redis, todas falham o check no mesmo intervalo, e o balanceador, obediente, tira todas de rotação. Uma dependência que o sistema tolerava em parte vira 100% de `503`. É o único exame médico da história que mata o paciente, a família e o médico.

Por isso a prontidão verifica só o que é **local** à instância; dependências compartilhadas por todas as réplicas são tratadas na requisição, com timeout, breaker e degradação (capítulo 15). Duas proteções completam: o **limite de ejeção** impede a checagem passiva de tirar mais que uma fração das instâncias, e o **limiar de pânico** (50% por padrão no Envoy) faz o balanceador ignorar os health checks e distribuir para todos quando sobram poucas saudáveis, em vez de matar as sobreviventes de cansaço.

Na **drenagem** (*connection draining*), a instância falha a prontidão, termina o que está em andamento e só então recebe o sinal de encerramento (capítulo 34). E o tempo ocioso do keep-alive do backend precisa ser maior que o do balanceador: se o backend fecha primeiro, o balanceador escreve numa conexão recém-morta e devolve `502` sem que o backend leia um byte. É o motivo dos 65 s do Uvicorn contra os 60 s dos clientes no capítulo 8; um proxy na frente é só mais um cliente obrigado a ir embora antes de ser expulso.

## Sticky sessions, o casamento por conveniência

**Afinidade de sessão** (*sticky session*) manda o mesmo cliente sempre à mesma instância, por cookie do balanceador, hash do IP ou cabeçalho, porque a instância guarda estado em memória (sessão, WebSocket, cache local). A carga fica desigual: hash de IP com o CGNAT do capítulo 25 manda 11 mil celulares para uma réplica só, e o supernó volta como problema de balanceamento. A instância morre e leva o estado; a drenagem dura a sessão mais longa. É um relacionamento que só funciona enquanto ninguém morre, e no backend alguém sempre morre. A alternativa é tirar o estado da instância (capítulo 29).

## Reverse proxy, API gateway, service mesh e CDN, o mesmo programa com quatro crachás

Os quatro são proxies de camada 7 em posições diferentes. O **reverse proxy** fica na frente de uma aplicação: termina TLS e lê a requisição inteira antes de ocupar um worker, protegendo-o de cliente lento (a Lastro tem um por máquina desde o capítulo 10). O **API gateway** acrescenta política de API: autentica o cliente (capítulo 30), limita taxa por cliente (capítulo 28), roteia por caminho e versão para serviços diferentes e carimba um ID de requisição. O risco conhecido é a regra de negócio migrar para lá, uma transformação de payload por vez, até o gateway virar um monólito escrito em YAML, a forma mais cruel de monólito já inventada.

A **service mesh** põe um proxy ao lado de cada instância (o *sidecar*) e um **plano de controle** que distribui rotas e certificados; ganha-se mTLS, retries, balanceamento por requisição e telemetria sem mexer no código. Custa dois saltos de proxy por chamada, memória de um proxy por instância e um plano de controle que, configurado errado, quebra todas as chamadas ao mesmo tempo. Istio e Linkerd são exemplos.

A **CDN** espalha reverse proxies perto dos usuários: cache, TLS terminado perto do cliente e absorção de ataque volumétrico. Custa um terceiro lendo o tráfego em claro e o risco de uma chave de cache mal definida entregar o extrato de um vendedor a outro, um vazamento de dados com latência de borda.

## Na Lastro: uma porta de entrada, um proxy por máquina e um IP para os parceiros

Hoje `api.lastro.com.br` responde com dois registros A, `api-01` e `api-02`. DNS round robin não sabe quem está vivo, os clientes guardam a resposta por 300 s (capítulo 8), e `temp-01` ainda atende a integração do Bazar que resolveu o nome há mais de 200 dias e nunca mais perguntou. Os requisitos: tirar réplica morta de rotação em segundos; nenhuma falha de dependência compartilhada pode tirar todas as réplicas juntas (a degradação do antifraude, capítulo 15, não pode ser anulada pelo balanceador); autenticação e limite de taxa por marketplace num ponto só (capítulos 28 e 30); verificar o certificado cliente do banco em `webhooks-pix.lastro.com.br` (capítulo 10); e um IP de saída fixo, porque o adquirente, na renovação do contrato, passou a exigir allowlist de no máximo dois IPs, como o banco do Pix já exige desde o capítulo 8.

| Opção | Saber quem está vivo | Política por marketplace | mTLS do banco | Saltos L7 |
|-------|----------------------|--------------------------|---------------|-----------|
| DNS round robin (hoje) | não | em cada máquina | no proxy local | 1 |
| L7 gerenciado + gateway próprio | sim | no gateway | depende do produto | 2 |
| L4 gerenciado + gateway próprio | sim | no gateway | no gateway | 1 |

A Lastro fica com a terceira. O gateway próprio é obrigatório pela política por marketplace, e um L7 gerenciado na frente dele seria uma segunda terminação TLS e um segundo lugar para o mTLS do banco dar errado. O L4 entrega IP público estável, health check dos gateways e o IP do comprador pelo PROXY protocol v2, aceito só da faixa privada do balanceador. Isso muda a previsão do capítulo 10 (certificado gerenciado no balanceador): o ACME por máquina continua, nos gateways. Um L7 gerenciado que verificasse a CA privada do banco e autenticasse os marketplaces tornaria a segunda linha a certa.

```text
  marketplaces · checkout (navegador) · banco parceiro (webhooks-pix, mTLS)
                              │ api.lastro.com.br → 203.0.113.50
                              ▼
               balanceador L4 gerenciado (PROXY protocol v2)
               │                   │                    │
        gateway temp-01     gateway api-01       gateway api-02
        (TLS, mTLS do banco, rotas, X-Forwarded-For, ID de requisição)
               └──────────┬────────┴─────────┬──────────┘
                          ▼                  ▼
         proxy local de cada máquina (127.0.0.1:71xx, um por serviço)
         pagamentos ×9 · antifraude ×6 · ledger ×6 · repasses · notificações · relatórios
                          │
                          ▼
         proxy de saída ativo/passivo (api-01, api-02) com IP 203.0.113.10
                          ▼
                adquirente · banco do Pix · webhooks dos marketplaces
```

Sim, `temp-01` virou gateway. Agora atende o mundo e recebe health check a cada 2 segundos. É a primeira vez que alguém mede a saúde dele, e ninguém quer ver o resultado do exame.

Os gateways roteiam por `Host` e prefixo para cada serviço (`webhooks-pix` só com certificado cliente válido). Na criação de cobrança, o timeout do gateway é 9 s, acima do deadline de 8 s do capítulo 15, para que responda a aplicação, com `processando`, e nunca o gateway, com um `504` que não diz se o cartão foi cobrado. Nenhuma rota usa afinidade: nenhum serviço guarda estado de cliente em memória, e o SSE do checkout reconecta em qualquer instância com `Last-Event-ID` (capítulo 12).

No tráfego interno, cada máquina roda um proxy local (o Envoy é um exemplo), com uma porta em `127.0.0.1` por serviço, que conhece as réplicas das três máquinas pela lista gerada no deploy. A variável do Carlos foi aposentada com honras. Pagamentos chama `127.0.0.1:7100`, e o proxy aplica P2C por requisição (inclusive streams gRPC); checagem ativa de `/pronto` a cada 2 s, fora após 2 falhas; ejeção passiva após 5 falhas de conexão ou `5xx` seguidos, por 30 s dobrando a cada reincidência, no máximo um terço das instâncias; pânico em 50%; e repete uma vez, em outra instância, só a falha de conexão, em que a requisição comprovadamente não saiu (capítulo 15).

`/pronto` verifica o que é local: tarifas carregadas, processo fora de drenagem, lag do loop abaixo de 50 ms. O Carlos abriu um PR com `/saude` testando PostgreSQL, Redis, Vigia e adquirente "por segurança". A conta da revisão: um soluço de 3 s do Vigia derruba o check das seis réplicas do antifraude ao mesmo tempo, e o balanceador remove o serviço que o capítulo 15 ensinou a sobreviver sem o Vigia, por causa do Vigia. PR fechado, com a conta no comentário.

Com essas regras, a quarta-feira vira uns quinze RSTs repetidos em outra réplica, ejeção em cada proxy local na quinta falha, confirmação ativa em 4 s e nenhum cartão recusado.

Na saída, todo HTTPS para parceiros e webhooks passa por um proxy de saída (*forward proxy*) com `CONNECT`: o TLS vai de ponta a ponta pelo túnel, e o proxy só confere o destino contra uma lista permitida (o capítulo 32 vai cobrá-la). Roda ativo em `api-01` e passivo em `api-02`, com o IP `203.0.113.10`, que o banco já cadastrou no capítulo 8, reassociado no failover em ~30 s (hipótese de projeto). O formulário com firma reconhecida para tirar o IP de `temp-01` da allowlist do banco foi protocolado: 10 dias úteis. O capítulo 36 leva a saída para NAT na rede.

A service mesh fica de fora: com seis serviços em três máquinas, os proxies locais já entregam o que ela daria, sem plano de controle; vira a escolha com dezenas de serviços, mTLS interno obrigatório ou Kubernetes (capítulo 35). A API fica fora de CDN: nenhuma resposta pode ir para cache (`private`, capítulo 22), e TLS terminado num terceiro levaria o escopo do PCI DSS junto (capítulo 33).

## Armadilhas e casos reais

> **Armadilha:** retry no balanceador para qualquer erro. Um L7 que repete `POST /v1/cobrancas` após timeout de leitura cria a segunda cobrança do capítulo 16 sem ajuda de nenhuma consultoria Java.

> **Armadilha:** confiar no primeiro valor de `X-Forwarded-For`. O cliente escreve o começo da lista; o confiável é o que o seu último proxy acrescentou, contado da direita. Quem lê o da esquerda deixa o rate limiting do capítulo 28 limitar o IP que o atacante achou mais engraçado.

> **Armadilha:** health check respondido pelo próprio gateway ou servido de cache. Fica verde para sempre, inclusive no velório, enquanto o Bazar abre o chamado.

> **Na vida real:** em 8 de junho de 2021, um bug que a Fastly tinha posto em produção em 12 de maio foi disparado pela mudança de configuração válida de um cliente, e cerca de 85% da rede passou a devolver erros. A causa foi identificada em cerca de um minuto, e 95% da rede voltou em 49 minutos. Um componente compartilhado na frente de todo mundo transformou um defeito em falha simultânea de milhares de sites que não tinham mudado nada.

## Resumo

- L4 decide por conexão, sem ler HTTP; L7 decide por requisição, com rota e retry, ao custo de CPU, chave e um parser a mais. PROXY protocol devolve o IP do cliente.
- Least connections ama a instância que falha rápido; P2C derruba a carga máxima para `ln ln n / ln 2`; hash consistente e Maglev servem afinidade por chave.
- Checagem ativa e passiva; prontidão só com o que é local; limite de ejeção e limiar de pânico; drenagem; keep-alive do backend maior que o do balanceador.
- Sticky session paga estado em memória com carga desigual.
- Reverse proxy, API gateway, service mesh e CDN: proxies L7 em posições diferentes.

## A Lastro agora

`api.lastro.com.br` aponta para um balanceador L4 gerenciado que distribui entre três gateways; entre serviços, proxies locais com P2C, `/pronto` e ejeção passiva; na saída, um proxy `CONNECT` com o IP `203.0.113.10`, o único que os parceiros conhecem. A quarta-feira de 47 minutos virou quinze RSTs que ninguém viu, e `temp-01`, promovido a borda, passa por exame médico a cada dois segundos e, para surpresa de todos, passa.

Agora existe uma porta só, e ela atende qualquer um com a mesma educação. Na segunda, o Hornero sobe uma integração cujo laço de reconciliação perdeu a condição de parada e consulta `GET /v1/cobrancas/{id}` quatro mil vezes por segundo. O balanceador distribui as quatro mil com perfeição, e as cobranças dos outros marketplaces ficam na fila, atrás de um `while True` muito bem balanceado.

## Referências

- Azar, Y.; Broder, A.; Karlin, A.; Upfal, E., "Balanced Allocations", STOC 1994 (SIAM Journal on Computing, 1999): https://doi.org/10.1137/S0097539795288490
- Mitzenmacher, M., "The Power of Two Choices in Randomized Load Balancing", IEEE TPDS, 2001: https://doi.org/10.1109/71.963420
- Eisenbud, D. E. et al., "Maglev: A Fast and Reliable Software Network Load Balancer", NSDI 2016: https://www.usenix.org/conference/nsdi16/technical-sessions/presentation/eisenbud
- HAProxy, "The PROXY protocol" (versões 1 e 2): https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt
- Envoy, balanceadores de carga (least request com P2C): https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/load_balancers
- Envoy, limiar de pânico: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/panic_threshold
- Envoy, outlier detection: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier
- RFC 7239, Forwarded HTTP Extension: https://www.rfc-editor.org/rfc/rfc7239
- Fastly, "Summary of June 8 outage", 2021: https://www.fastly.com/blog/summary-of-june-8-outage
