# Balanceamento e proxies

## A réplica mais rápida da empresa

O Biscoito é um dachshund com horário fixo de passeio e pouca tolerância a atrasos, e o Seu Horácio tentava pela sétima vez marcar esse horário no aplicativo. Enquanto isso, o painel do mesmo aplicativo comemorava um recorde naquela segunda-feira de manhã: a latência mediana tinha caído de 80 ms para 3 ms. Ninguém tinha otimizado nada, e 58% dos agendamentos falhavam.

A situação é hipotética; o mecanismo, não. O deploy subiu seis réplicas, de `passeio-01` a `passeio-06`. A `passeio-04` recebeu uma variável de ambiente errada que apontava o banco para `localhost`, onde morava apenas silêncio. Cada requisição nela voltava com `503` em 2 ms. O `/health` dela respondia `{"status": "ok"}`, porque só conferia se o processo estava de pé. E estava, servindo erros com eficiência admirável.

O balanceador usava *least connections*: mandar cada requisição para a réplica com menos requisições em andamento. As saudáveis levavam 80 ms e acumulavam algumas abertas. A `passeio-04` quase sempre estava com zero. Para o algoritmo, era a funcionária do mês. As outras cinco ficaram com CPU em 9%, olhando o movimento.

Por que um balanceador que fez exatamente o que foi configurado mandou mais da metade do tráfego para o único servidor quebrado, e por que o health check não viu nada?

## O que o balanceador enxerga: camada 4 e camada 7

Um balanceador de carga recebe tráfego num endereço (muitas vezes um IP virtual, o VIP) e o distribui entre servidores de trás, os *backends*. "Camada 4" e "camada 7" são apelidos herdados do modelo OSI (o capítulo 1 trata das camadas do TCP/IP). O que muda entre eles é a unidade de decisão.

### Camada 4: conexões

Um balanceador L4 olha IPs e portas, decide **por conexão TCP** (ou fluxo UDP) e depois só repassa bytes, sem saber se dentro deles há HTTP, gRPC ou um protocolo que alguém escreveu em 2011 e não documentou. Ele pode ser um proxy completo (aceita a conexão e abre outra até o backend), fazer NAT de destino ou usar *direct server return* (DSR), em que o backend responde direto ao cliente e a resposta nem passa pelo balanceador.

No proxy completo, o backend vê o IP do balanceador. A solução em L4 é o **PROXY protocol**, do HAProxy: antes do primeiro byte, o balanceador envia a origem real, numa linha de texto na versão 1 (`PROXY TCP4 198.51.100.23 10.0.1.14 51234 443\r\n`) ou num bloco binário na versão 2. Um backend que não espera esse cabeçalho lê `PROXY TCP4...` no lugar do método HTTP e responde `400`, com toda a razão do mundo.

O L4 custa pouco: nada de parsing, e o TLS pode passar direto (*passthrough*, capítulo 3). O limite é a granularidade. Uma conexão HTTP/2 com 40 mil requisições leva as 40 mil para o mesmo backend, porque a decisão aconteceu uma vez, no SYN. O capítulo 24 mostra o efeito com gRPC.

### Camada 7: requisições

Um balanceador L7 termina a conexão, decifra o TLS, interpreta o HTTP e decide **por requisição**: roteia por `Host`, caminho ou cabeçalho, reescreve cabeçalhos, repete requisições, responde `429` e registra o status de cada resposta. Esse último item é o que interessa à `passeio-04`: só o L7 sabe que ela devolve `503`. Para um L4, ela é uma conexão TCP saudável que fecha rápido.

O L7 informa a origem por cabeçalho: `Forwarded` (RFC 7239) no padrão, `X-Forwarded-For` e `X-Forwarded-Proto` no uso de mercado. O `X-Forwarded-For` é uma lista em que cada proxy acrescenta no fim o IP de quem falou com ele. O preço do L7 é CPU para TLS e parsing, buffers e uma conexão a mais.

### Quem balanceia o balanceador

Um balanceador único é um ponto único de falha com um nome mais bonito. As saídas: IP flutuante entre dois balanceadores com VRRP (keepalived), ECMP no roteador espalhando fluxos por hash entre várias máquinas balanceadoras (o Maglev, do Google, NSDI 2016) e anycast.

## Algoritmos, ou como escolher sem perguntar a ninguém

**Round robin** percorre a lista em ordem e ignora a carga, o que é ao mesmo tempo defeito e proteção: na manhã do Biscoito, ele mandaria para a `passeio-04` exatamente um sexto do tráfego, 16,7%. Ruim, mas bem menos ruim que 58%. O **round robin ponderado** dá peso a máquinas maiores (a versão suavizada do nginx aparece adiante).

**Least connections** escolhe o backend com menos conexões (ou requisições, no L7) em andamento. Ele se adapta à lentidão real, porque um backend lento acumula requisições e passa a receber menos. A falha é a da abertura: pela Lei de Little, em andamento = taxa × tempo, então com 2 ms por resposta a réplica quebrada precisa receber 40 vezes mais tráfego que uma de 80 ms para ter a mesma fila. E recebe.

**Duas escolhas** (*power of two choices*) sorteia dois backends e manda para o menos ocupado dos dois. Parece preguiça e é matemática: com n requisições em n servidores, o mais carregado fica com cerca de ln n / ln ln n no sorteio simples e ln ln n / ln 2 + O(1) com duas escolhas (Azar, Broder, Karlin e Upfal, 1994; Mitzenmacher, 2001), uma queda exponencial. Com seis réplicas, a `passeio-04` aparece num sorteio em 1 − C(5,2)/C(6,2) = 1/3 das vezes; quando aparece, ganha. O estrago fica num teto conhecido de um terço. O Envoy usa duas escolhas no `LEAST_REQUEST` por padrão; o nginx oferece `random two least_conn`.

**EWMA de latência** escolhe pela média móvel do tempo de resposta (o Linkerd usa uma variante) e tem o mesmo ponto cego, ao quadrado: erro rápido tem latência ótima, e por isso as implementações penalizam respostas de erro.

**Hash** escolhe pelo valor de algo da requisição (IP, cookie, chave do cache): a mesma chave cai sempre no mesmo backend. O hash consistente move só cerca de 1/N das chaves quando N muda (capítulo 14). Para a chave popular que esmaga um backend, o hash consistente com cargas limitadas (Mirrokni, Thorup e Zadimoghaddam, 2018) desvia a chave para o próximo do anel quando o atual passa de um fator acima da média; no HAProxy, `hash-balance-factor`.

Todos tratam um backend recém-chegado como pronto, e ele quase nunca está: caches vazios, pool fechado. Least connections vê zero conexões e o soterra. O **slow start** faz o peso dele crescer de zero ao nominal durante um intervalo (`slowstart 30s` no HAProxy).

## Health checks: quem está vivo

O **health check ativo** consulta cada backend periodicamente: uma conexão TCP (L4) ou um `GET` com conferência do status (L7). O tempo de detecção é intervalo × limiar de falhas: com 10 s e 3 falhas, um backend morto recebe tráfego por até 30 s. A 50 requisições por segundo por réplica, são 1.500 requisições entregues a um processo que já foi embora.

O **health check passivo** (*outlier detection*) observa o tráfego real. O Envoy, por padrão, ejeta um backend depois de 5 respostas `5xx` seguidas, por 30 s multiplicados pelo número de ejeções anteriores, e nunca ejeta mais que 10% do grupo. O nginx open source só tem a versão passiva (`max_fails=1 fail_timeout=10s` por padrão). Na manhã do Biscoito, a detecção passiva teria tirado a `passeio-04` do grupo no quinto `503`, milissegundos depois do deploy.

A decisão difícil é o que o check consulta. O Kubernetes separou duas perguntas (capítulo 35): **liveness** (o processo travou? então reinicie) e **readiness** (esta réplica consegue atender agora? então tire do balanceamento, sem matar). O `/health` da `passeio-04` era um liveness usado como readiness. O erro oposto é um readiness que consulta o banco, o Redis, a API de pagamentos e o horóscopo. Quando o banco fica lento por 20 segundos, todas as réplicas reprovam juntas, o balanceador remove todas e passa a responder `503` por conta própria, com muita convicção.

O critério que sai do mecanismo: o readiness verifica o que é **local à réplica**. A variável errada da `passeio-04` é local: o pool dela não abre, o das outras abre. Um banco fora do ar é compartilhado, e tirar todas as réplicas não conserta o banco. Os balanceadores trazem uma rede de proteção para esse erro: o Envoy entra em **modo pânico** quando menos de 50% do grupo está saudável e distribui entre todos, e o balanceador de aplicação da AWS faz *fail open* quando todos os alvos reprovam. Um check que reprova todo mundo provavelmente mede a coisa errada.

## Sticky sessions

*Sticky session* (afinidade de sessão) faz o mesmo cliente cair sempre no mesmo backend, por cookie inserido pelo balanceador (o `AWSALB` da AWS, o `cookie SRV insert` do HAProxy) ou por hash do IP de origem. O hash de IP funciona até mil pessoas estarem atrás do mesmo NAT de operadora (CGNAT) e um único backend receber o bairro inteiro.

A afinidade existe porque algum estado ficou na memória do processo, como o carrinho guardado num dicionário Python. Os custos: clientes pesados ficam presos onde caíram, a perda de um backend apaga as sessões dele, e drenar um backend no deploy significa esperar sessões que duram horas. Tirar o estado do processo resolve (capítulo 29); a afinidade continua útil quando é só otimização, como um cache local mais quente.

## Reverse proxy, API gateway e service mesh

Os três são proxies L7. A diferença está em onde ficam e no que fazem além de repassar.

### Reverse proxy

Um *reverse proxy* (nginx, HAProxy, Envoy, Caddy) fica na frente dos servidores de aplicação e, além de balancear, termina TLS (capítulo 3) e absorve clientes lentos. Um celular em 3G envia um upload a 20 KB/s; direto num worker síncrono do Gunicorn, o worker fica preso a transferência inteira. O proxy recebe a requisição completa no próprio buffer e só então a entrega ao backend, que a processa em milissegundos. O mesmo buffer neutraliza o Slowloris, que envia cabeçalhos um byte por vez, com a paciência de quem não tem mais nada para fazer.

O proxy também reaproveita conexões com o backend, desde que configurado para isso (o exemplo do nginx vem adiante). O keep-alive do backend precisa durar mais que o do proxy, ou a corrida entre um fechando e outro enviando gera `502` esporádicos (capítulo 2).

### API gateway

Um *API gateway* é um reverse proxy com regras por consumidor: autenticação (JWT, chaves de API), rate limiting e cotas por cliente (capítulo 28), roteamento por versão e transformação de requisições. Kong, Tyk e os gateways gerenciados dos provedores (o Amazon API Gateway é um) são exemplos. O custo é um salto a mais e uma tentação permanente: como o gateway vê tudo, regras de negócio começam a morar nele. "Só um `if` para o cliente premium." Três anos depois, metade da lógica de preços está num plugin Lua que só uma pessoa entende, e ela está de férias.

### Service mesh

Um *service mesh* põe um proxy ao lado de cada serviço. No modelo clássico (Istio, Linkerd), cada pod ganha um *sidecar* que intercepta o tráfego de entrada e saída, e um *control plane* distribui rotas, pesos, certificados e políticas para todos eles (pelas APIs xDS, no caso do Envoy). Ganha-se mTLS entre todos os serviços, balanceamento por requisição para gRPC e retries, timeouts e circuit breakers (capítulo 19) fora do código.

Paga-se com dois proxies a mais em cada chamada (frações de milissegundo a alguns milissegundos por salto, conforme versão e carga), um sidecar por pod consumindo memória e um sistema distribuído novo para operar. O modo *ambient* do Istio (estável desde a 1.24, de 2024) troca os sidecars por um proxy L4 por nó e proxies L7 sob demanda.

Retries em camadas se multiplicam: cliente, mesh e gateway repetindo 3 vezes cada transformam uma falha em 27 tentativas. O capítulo 19 trata do *retry storm*; o capítulo 20, de por que um proxy só pode repetir requisições idempotentes.

## CDN

Uma CDN (*content delivery network*) é uma rede de reverse proxies em pontos de presença (PoPs) espalhados pelo mundo, alcançados por anycast. O cliente em Recife negocia TLS com um PoP em Fortaleza, a 8 ms, em vez da origem na Virgínia, a mais de 100 ms. A CDN serve do cache o que `Cache-Control` permitir (capítulos 2 e 16), mantém conexões quentes com a origem e absorve picos e ataques volumétricos. O preço é que a CDN entra no caminho crítico de tudo, e um erro de chave de cache serve a fatura de um cliente para outro.

## Na prática

### A configuração que teria salvado o Biscoito

Um HAProxy na frente das seis réplicas, com check ativo de readiness, detecção passiva de erros, slow start e duas escolhas:

```text
backend passeios
    balance random(2)                 # duas escolhas
    option httpchk
    http-check send meth GET uri /pronto
    http-check expect status 200
    # check a cada 2 s; fora após 3 falhas; volta após 2 sucessos
    default-server check inter 2s fall 3 rise 2 slowstart 30s
    # detecção passiva: 5 erros seguidos no tráfego real derrubam o servidor
    default-server observe layer7 error-limit 5 on-error mark-down
    server passeio-01 10.0.1.11:8000
    server passeio-02 10.0.1.12:8000
    server passeio-03 10.0.1.13:8000
    server passeio-04 10.0.1.14:8000  # a funcionária do mês
    server passeio-05 10.0.1.15:8000
    server passeio-06 10.0.1.16:8000
```

Do lado da aplicação, liveness e readiness separados. O readiness testa se esta réplica consegue falar com o banco, com uma consulta trivial e timeout curto:

```python
import asyncio
from fastapi import FastAPI, Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import create_async_engine
import os

app = FastAPI()
engine = create_async_engine(os.environ["DATABASE_URL"], pool_size=10)


@app.get("/vivo")
async def vivo():
    # Liveness: se o event loop respondeu, o processo não travou.
    return {"status": "vivo"}


@app.get("/pronto")
async def pronto(response: Response):
    try:
        async with asyncio.timeout(0.5):
            async with engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
    except Exception as erro:
        response.status_code = 503
        return {"status": "indisponivel", "motivo": type(erro).__name__}
    return {"status": "pronto"}
```

Na `passeio-04`, com o banco apontado para `localhost`:

```bash
curl -s -i http://10.0.1.14:8000/pronto
```

```text
HTTP/1.1 503 Service Unavailable
content-type: application/json

{"status":"indisponivel","motivo":"OperationalError"}
```

Três checks depois, 6 segundos, ela sai do grupo; as outras cinco continuam `200`. Se o banco cair para todos, entra o modo pânico, ou um alerta para uma pessoa, que é quem de verdade conserta bancos.

### Round robin ponderado sem rajadas

O *smooth weighted round robin* do nginx: a cada escolha, todo servidor soma o próprio peso a um contador; o maior vence e subtrai o total dos pesos.

```python
def round_robin_suave(pesos: dict[str, int], n: int):
    contador = dict.fromkeys(pesos, 0)
    total = sum(pesos.values())
    for _ in range(n):
        for servidor, peso in pesos.items():
            contador[servidor] += peso
        vencedor = max(contador, key=contador.get)
        contador[vencedor] -= total
        yield vencedor


pesos = {"grandona": 5, "miuda-1": 1, "miuda-2": 1}
print(" ".join(round_robin_suave(pesos, 7)))
```

```text
grandona grandona miuda-1 grandona miuda-2 grandona grandona
```

A `grandona` recebe 5 de 7, mas nunca mais de duas seguidas.

### O pool de conexões do nginx com o backend

```text
upstream passeios {
    least_conn;
    server 10.0.1.11:8000 max_fails=3 fail_timeout=10s;
    server 10.0.1.12:8000 max_fails=3 fail_timeout=10s;
    keepalive 32;                       # até 32 conexões ociosas por worker
}

server {
    location / {
        proxy_pass http://passeios;
        proxy_http_version 1.1;         # keep-alive exige HTTP/1.1
        proxy_set_header Connection ""; # não repassar "Connection: close"
    }
}
```

Sem as duas linhas `proxy_`, nas versões em que o padrão com o upstream é HTTP/1.0, o `keepalive 32` fica lá, configurado e ignorado, e cada requisição abre e fecha uma conexão TCP.

### O IP do cliente, lido do lado certo

O cliente pode enviar o próprio `X-Forwarded-For`, e o balanceador só acrescenta no fim o IP que viu. Quem lê o primeiro item lê o que o cliente quis escrever:

```python
from ipaddress import ip_address, ip_network

PROXIES_CONFIAVEIS = [ip_network("10.0.0.0/8")]  # o balanceador mora aqui


def confiavel(ip: str) -> bool:
    return any(ip_address(ip) in rede for rede in PROXIES_CONFIAVEIS)


def ip_do_cliente(x_forwarded_for: str, ip_da_conexao: str) -> str:
    # Da direita para a esquerda: cada proxy confiável acrescenta
    # no fim quem falou com ele. O primeiro desconhecido é o cliente.
    cadeia = [p.strip() for p in x_forwarded_for.split(",") if p.strip()]
    cadeia.append(ip_da_conexao)
    for ip in reversed(cadeia):
        if not confiavel(ip):
            return ip
    return cadeia[0]


# O cliente 203.0.113.7 mandou um X-Forwarded-For de presente.
xff = "1.2.3.4, 203.0.113.7"
print("primeiro da lista:", xff.split(",")[0])
print("lido da direita:  ", ip_do_cliente(xff, "10.0.3.17"))
```

```text
primeiro da lista: 1.2.3.4
lido da direita:   203.0.113.7
```

O `1.2.3.4` é invenção do cliente, e um rate limit por IP baseado nele cai diante de um cabeçalho novo a cada requisição. No Uvicorn, `--forwarded-allow-ips` define em quais proxies acreditar.

## Propriedades e custos

| Componente | Decide por | Vê status HTTP | Custo por requisição | Quando a propriedade pesa |
|---|---|---|---|---|
| Balanceador L4 | conexão | não | muito baixo; DSR tira a resposta do caminho | volume alto, protocolos não HTTP, TLS de ponta a ponta |
| Balanceador L7 | requisição | sim | TLS + parsing + 1 conexão | HTTP/2 e gRPC, roteamento por caminho, retries, detecção passiva |
| API gateway | requisição e consumidor | sim | L7 + autenticação e políticas | API pública, cotas por cliente |
| Service mesh (sidecar) | requisição, em cada salto | sim | 2 proxies por chamada + memória por pod | muitos serviços, mTLS interno, políticas uniformes |
| CDN | requisição, na borda | sim | negativo para conteúdo em cache | clientes distantes, conteúdo cacheável, picos |

O custo "negativo" da CDN é literal: a requisição mais barata para a origem é a que nunca chega lá. E os algoritmos, diante da `passeio-04`:

| Algoritmo | Informação usada | Backend que erra rápido |
|---|---|---|
| Round robin | nenhuma | recebe 1/N |
| Least connections | requisições em andamento | atrai a maior parte |
| Duas escolhas | carga de 2 sorteados | até ~2/N |
| EWMA de latência | tempo de resposta | atrai, sem penalidade de erro |
| Hash consistente | chave da requisição | recebe as chaves dele |

## Armadilhas e casos reais

> **Armadilha:** o *connection draining*. Ao remover um backend no deploy, o balanceador para de mandar requisições novas e espera as em andamento por um prazo (300 s é o padrão de *deregistration delay* do ALB da AWS). Se a aplicação morre no `SIGTERM` sem esperar, as requisições em voo viram `502`. Se o prazo é grande demais, um deploy de vinte réplicas em lotes dura um filme longo (capítulo 37).

> **Na vida real:** em 2 de julho de 2019, a Cloudflare distribuiu de uma vez para toda a borda uma regra de WAF com uma expressão regular sujeita a *backtracking* catastrófico. A CPU dos núcleos que processavam HTTP foi a 100% no mundo inteiro, e por 27 minutos os clientes receberam `502`. Configuração aplicada a todos os PoPs ao mesmo tempo tem o raio de impacto da rede inteira.

> **Na vida real:** em 8 de junho de 2021, uma configuração válida de um cliente da Fastly acionou um bug latente desde um deploy de 12 de maio. Cerca de 85% da rede passou a devolver erros; 95% voltou ao normal em 49 minutos. Nesse intervalo, grandes sites de notícias tiveram dificuldade para noticiar a própria queda.

## Resumo

- L4 decide por conexão e repassa bytes; L7 decide por requisição, vê o status HTTP e paga TLS e parsing.
- IP do cliente: PROXY protocol em L4; `X-Forwarded-For` em L7, lido da direita até o primeiro proxy não confiável.
- Least connections atrai backends que erram rápido; duas escolhas limita o estrago a ~2/N; hash consistente dá afinidade; slow start protege quem acabou de subir.
- Detecção ativa leva intervalo × limiar; a passiva reage ao tráfego real. Readiness checa só o que é local à réplica.
- Reverse proxy termina TLS e absorve clientes lentos; gateway soma políticas por consumidor; mesh custa dois proxies por chamada; CDN concentra o risco de configuração global.

## Referências

- RFC 7239, Forwarded HTTP Extension: https://www.rfc-editor.org/rfc/rfc7239
- HAProxy, The PROXY protocol: https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt
- HAProxy, documentação de configuração: https://docs.haproxy.org/
- nginx, módulo `ngx_http_upstream_module`: https://nginx.org/en/docs/http/ngx_http_upstream_module.html
- Envoy, outlier detection: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier
- Envoy, panic threshold: https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/panic_threshold
- Eisenbud et al., "Maglev: A Fast and Reliable Software Network Load Balancer", NSDI 2016: https://www.usenix.org/conference/nsdi16/technical-sessions/presentation/eisenbud
- Azar, Broder, Karlin e Upfal, "Balanced Allocations", STOC 1994.
- Mitzenmacher, "The Power of Two Choices in Randomized Load Balancing", IEEE TPDS, 2001.
- Mirrokni, Thorup e Zadimoghaddam, "Consistent Hashing with Bounded Loads", SODA 2018.
- Kubernetes, liveness, readiness e startup probes: https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/
- Istio, modo ambient: https://istio.io/latest/docs/ambient/
- Cloudflare, "Details of the Cloudflare outage on July 2, 2019": https://blog.cloudflare.com/details-of-the-cloudflare-outage-on-july-2-2019/
- Fastly, "Summary of June 8 outage": https://www.fastly.com/blog/summary-of-june-8-outage
