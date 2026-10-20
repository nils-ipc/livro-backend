# Controle de carga

## Quatro mil previsões do tempo por segundo

Às 6h03 de uma segunda-feira, a API de previsão do tempo para produtores rurais recebeu 4.000 requisições por segundo. Numa segunda normal, ela recebe 140. Os 3.000 agricultores que abriram o aplicativo para decidir se plantavam milho naquele dia receberam uma previsão uniforme para todo o país: `503 Service Unavailable`, com 100% de chance.

Todo o tráfego extra vinha de uma única chave de API, a da Cooperativa Vale do Milho, e de um único processo: `sync_chuva.py`. No topo do arquivo, um comentário honesto: `# roda uma vez por dia, não precisa de sleep`. Um bug de fuso horário tinha transformado "uma vez por dia" em "sempre", e o laço `while True` passou a pedir a previsão de 5.570 municípios, sem pausa. Quando as respostas começaram a falhar, o script tentou de novo, imediatamente, três vezes.

Ninguém foi malicioso; a cooperativa só queria saber se ia chover. O sistema caiu porque aceitou cada requisição que chegou, de qualquer cliente, em qualquer quantidade.

Duas perguntas saem dessa manhã. Como impedir que um cliente sozinho consuma a capacidade de todos? E, quando a soma de clientes bem-comportados passa da capacidade, o que o servidor deve fazer com o excesso?

## Rate limiting, ou a arte de contar requisições

*Rate limiting* é limitar quantas requisições uma identidade pode fazer num intervalo de tempo: 100 por minuto por chave de API, 10 por segundo por IP, 5 tentativas de login por hora por conta. A identidade é a chave do limite, e escolhê-la é metade do problema (a outra metade é contar direito). Os algoritmos abaixo diferem em memória, rajada permitida e erro na fronteira.

### Janela fixa

O mais simples: divide o tempo em janelas alinhadas ao relógio (12h00:00 a 12h00:59, 12h01:00 a 12h01:59) e mantém um contador por chave e janela. Requisição chega, contador sobe; passou do limite, recusa. Em Redis são dois comandos, `INCR rl:chave:12h00` e `EXPIRE` na primeira vez, e a documentação do próprio `INCR` usa esse padrão como exemplo.

O defeito está na emenda. Com limite de 100 por minuto, um cliente pode fazer 100 requisições às 12h00:59 e mais 100 às 12h01:00. São 200 requisições em um segundo, todas legais: o dobro do limite. Há um segundo efeito colateral, mais social: todos os clientes bloqueados sabem exatamente quando o contador zera, e voltam juntos, no mesmo segundo.

### Janela deslizante

A janela deslizante conta as requisições dos últimos 60 segundos a partir de agora. A versão exata, *sliding window log*, guarda o instante de cada requisição num sorted set do Redis (`ZREMRANGEBYSCORE` apaga o que saiu, `ZCARD` conta, `ZADD` registra). Um limite de 10.000 por hora guarda até 10.000 timestamps por cliente, e o cliente mais ativo é justamente o que mais ocupa memória.

A versão aproximada, *sliding window counter*, guarda só o contador da janela atual e o da anterior, e estima:

```text
estimativa = anterior × (1 − decorrido / janela) + atual
```

Aos 15 segundos da janela atual, com 80 requisições na anterior e 30 na atual, a estimativa é 80 × 0,75 + 30 = 90. A fórmula supõe a janela anterior uniforme, o que é falso no detalhe e bom o bastante na média; a Cloudflare descreveu o uso dela com erro medido muito pequeno no tráfego real. Custa dois inteiros por chave.

### Token bucket

O *token bucket* modela o limite com dois números: capacidade `b` e taxa `r`. Cada chave tem um saldo de fichas, que começa em `b` e é reposto a `r` fichas por segundo, sem passar de `b`. Cada requisição gasta uma ficha (ou várias, se for cara). Sem ficha, recusa.

Não existe um processo enchendo baldes em segundo plano, o que seria um desperdício heroico de CPU com milhões de chaves. A reposição é calculada na hora da requisição, a partir do saldo e do instante da última atualização: `fichas = min(b, fichas + (agora − último) × r)`.

A taxa `r` define a média sustentada; a capacidade `b`, a maior rajada aceita depois de um período parado. Com `b = 50` e `r = 10`, uma tela que dispara 30 chamadas de uma vez passa sem punição, desde que não se repita a cada segundo. Em qualquer intervalo `t`, o máximo aceito é `b + r × t`.

### Leaky bucket e GCRA

O nome *leaky bucket* designa duas coisas diferentes, e a confusão é tradicional. Como medidor, ele é matematicamente equivalente ao token bucket, visto do avesso: o balde enche com cada requisição e esvazia à taxa `r`; se transbordar, recusa. Como fila, ele modela o tráfego: as requisições entram num buffer e saem a taxa constante. O `limit_req` do nginx segue esse modelo: `rate=10r/s` é a vazão, `burst=20` o tamanho da fila, e quem encontra a fila cheia é recusado (com `nodelay`, a rajada é atendida na hora, mas as vagas voltam no ritmo da taxa).

O GCRA (*generic cell rate algorithm*, das redes ATM) implementa o mesmo medidor com um único número por chave: o TAT, *theoretical arrival time*, instante em que a próxima requisição chegaria se o cliente andasse exatamente na taxa. Com intervalo `T = 1/r` e tolerância `τ = (b − 1) × T`:

```text
tat = max(tat_guardado, agora)
se tat − agora > τ:  recusa (pode tentar de novo em tat − τ − agora)
senão:               aceita e guarda tat + T
```

O tempo de espera sai de graça da conta, pronto para virar `Retry-After`. O módulo `redis-cell` implementa o GCRA como comando do Redis.

## Rate limiting distribuído

Com uma réplica, o contador mora na memória do processo e tudo é simples. Com doze réplicas atrás de um balanceador, cada uma vê um doze avos do tráfego, e o limite de 100 por minuto vira, na prática, 1.200 por minuto. O cliente agradece.

A primeira saída é um contador central, quase sempre em Redis, com três custos. Latência: uma ida e volta por requisição, algo como 0,2 a 1 ms no mesmo datacenter. Atomicidade: ler o saldo, calcular e gravar em comandos separados é um *read-modify-write*, e duas réplicas gastam a mesma ficha duas vezes (o capítulo 5 trata dessa corrida); a correção é um script Lua, que o Redis executa sem intercalar outros comandos. Disponibilidade: o Redis acaba de entrar no caminho crítico de todas as requisições.

Quando ele cai, *fail open* aceita tudo (a API fica no ar e sem proteção justamente durante um incidente) e *fail closed* recusa tudo (a proteção é perfeita e a API está, para todos os efeitos, desligada). Limites de login e de envio de SMS costumam falhar fechados, porque deixar passar custa dinheiro ou conta invadida. Limites de uso geral costumam falhar abertos, com timeout curto na consulta, para que um Redis lento não vire uma API lenta.

A segunda saída é local: cada réplica aplica `limite / N`. Funciona enquanto `N` for conhecido e o balanceamento for uniforme; o autoscaling muda `N` às 14h e o limite efetivo muda junto. Rotear por hash da chave de API (capítulo 27) concentra cada cliente numa réplica e torna o contador local quase exato, ao custo de hot spots com clientes grandes. No meio do caminho, cada réplica pode pegar fichas do Redis em lotes de 50: consultas divididas por 50, estouro máximo de um lote por réplica. O Envoy oferece rate limit local (token bucket no proxy) e global (serviço externo via gRPC).

## Quando o problema é a soma

O rate limiting protege os clientes uns dos outros. Ele não protege o servidor de todos eles juntos. Se 500 clientes, cada um dentro da sua cota, somam 3.000 requisições por segundo e o sistema aguenta 2.000, ninguém violou regra nenhuma e o sistema cai do mesmo jeito.

Por que cai, e não fica apenas lento? Com chegada acima da capacidade, a fila cresce sem limite e a espera cresce junto (a Lei de Little, `L = λ × W`, está no capítulo 6). Quando a espera passa do timeout, o cliente desiste, mas o servidor não fica sabendo: processa a requisição abandonada e responde para uma conexão que já fechou. A vazão medida continua alta. O *goodput*, a vazão de respostas que chegaram a tempo de servir para alguma coisa, vai a zero. E o cliente que desistiu tenta de novo, o que aumenta a chegada. O servidor trabalha a 100% de CPU produzindo exclusivamente lixo, com muita dedicação.

### Filas limitadas e backpressure

Toda fila sem limite é uma promessa de latência infinita feita a crédito. O `asyncio.Queue()` sem argumento tem `maxsize=0`, que significa infinito; o `queue.Queue()` também. Ou a memória acaba antes da paciência dos clientes, ou o contrário, e as duas ordens terminam mal.

Com limite, é preciso escolher o que fazer quando a fila enche. A primeira opção é *backpressure*: o consumidor sinaliza ao produtor que pare, e o produtor espera. O TCP faz isso com a janela de recepção, que vai a zero e para o emissor (capítulo 1). Num processo, `await fila.put(item)` numa `asyncio.Queue(maxsize=100)` suspende o produtor enquanto a fila estiver cheia, e a pressão sobe pela cadeia até a origem; `put_nowait` levanta `QueueFull` na hora.

A segunda opção é recusar. Backpressure serve quando o produtor pode esperar, como um job em lote. Na borda de uma API pública, o usuário não espera; ele aperta F5.

### Load shedding

*Load shedding* é recusar trabalho deliberadamente quando o servidor está perto do limite, para que o trabalho aceito termine a tempo. A recusa tem de ser barata: sem ler o corpo, sem bcrypt, sem banco. Uma recusa que custa tanto quanto o atendimento só troca uma sobrecarga por outra.

O critério mais direto é concorrência: no máximo `C` requisições em andamento por processo, e a seguinte recebe 503. Pela Lei de Little, 400 requisições por segundo a 50 ms cada dão cerca de 20 em andamento; um teto de 30 deixa margem. O Uvicorn oferece isso pronto com `--limit-concurrency`.

Outro critério é o tempo na fila: se o proxy anota o instante de chegada num cabeçalho, a aplicação descarta quem esperou demais. Responder em 900 ms a quem tem timeout de 800 ms é trabalho jogado fora com capricho.

Um teto fixo envelhece a cada deploy que deixa as requisições mais lentas. Limites adaptativos ajustam `C` pela latência, com a lógica do controle de congestionamento do TCP: latência subindo indica fila, e o limite desce. A biblioteca `concurrency-limits`, da Netflix, implementa variações disso (uma delas derivada do TCP Vegas).

E há prioridade: recusar primeiro o que importa menos. O livro de SRE do Google descreve quatro níveis de criticidade propagados entre serviços (`CRITICAL_PLUS`, `CRITICAL`, `SHEDDABLE_PLUS`, `SHEDDABLE`), e o descarte começa pelo último. O `sync_chuva.py` estaria no fim da fila com folga.

A ordem da fila também conta. Sob sobrecarga, FIFO atende primeiro a requisição mais antiga, cujo cliente provavelmente já desistiu. O artigo "Fail at Scale" (ACM Queue, 2015) descreve o que o Facebook usa: uma variação do CoDel (RFC 8289), em que, se a fila não esvaziou nenhuma vez nos últimos 100 ms, a espera máxima cai para 5 ms; e LIFO adaptativo, que passa a atender primeiro as mais novas quando a fila acumula. É injusto com a requisição antiga, que provavelmente já foi embora mesmo.

## Dizer não com educação: 429, 503 e Retry-After

O `429 Too Many Requests` (RFC 6585) significa que este cliente mandou requisições demais. O `503 Service Unavailable` (RFC 9110, seção 15.6.4) significa que o servidor está temporariamente incapaz de atender, seja quem for que pediu. Rate limiting responde 429; load shedding responde 503. Um diz "você, mais devagar"; o outro, "todo mundo, mais devagar".

O `Retry-After` (RFC 9110, seção 10.2.3) aceita dois formatos: um número de segundos (`Retry-After: 30`) ou uma data HTTP (`Retry-After: Mon, 19 Oct 2026 06:04:00 GMT`). A data depende do relógio do cliente estar certo; os segundos, só de ele saber contar.

Para mostrar a cota antes do estouro, APIs usam cabeçalhos próprios (`x-ratelimit-remaining`, no GitHub), e um rascunho do IETF padroniza os campos `RateLimit-Policy` e `RateLimit`.

Do lado do cliente, honrar o `Retry-After` com backoff e jitter é o mínimo (capítulo 19). O livro de SRE do Google descreve o *throttling adaptativo no cliente*: cada cliente conta, nos últimos dois minutos, quantas requisições fez e quantas foram aceitas, e recusa localmente, sem enviar, com probabilidade:

```text
p = max(0, (requisições − K × aceitas) / (requisições + 1))
```

Com `K = 2`, o cliente só começa a se recusar quando o servidor rejeita mais da metade. A recusa local custa zero para o servidor, o que é o tipo de ajuda que um servidor sobrecarregado aprecia.

## Na prática

### Um token bucket com relógio de mentira

O token bucket cabe numa classe pequena. O instante entra como parâmetro, o que torna o comportamento determinístico e fácil de acompanhar:

```python
from dataclasses import dataclass


@dataclass
class TokenBucket:
    capacidade: float  # tamanho máximo da rajada
    taxa: float        # fichas repostas por segundo
    fichas: float | None = None
    ultimo: float = 0.0

    def __post_init__(self) -> None:
        if self.fichas is None:
            self.fichas = self.capacidade

    def permitir(self, agora: float, custo: float = 1.0) -> bool:
        repostas = (agora - self.ultimo) * self.taxa
        self.fichas = min(self.capacidade, self.fichas + repostas)
        self.ultimo = agora
        if self.fichas >= custo:
            self.fichas -= custo
            return True
        return False


balde = TokenBucket(capacidade=5, taxa=1)
chegadas = [0.0] * 7 + [0.5, 1.0, 3.0, 3.0, 3.0]
for t in chegadas:
    ok = balde.permitir(agora=t)
    print(f"t={t:.1f}s  {'aceita' if ok else 'recusa'}  fichas={balde.fichas:.1f}")
```

```text
t=0.0s  aceita  fichas=4.0
t=0.0s  aceita  fichas=3.0
t=0.0s  aceita  fichas=2.0
t=0.0s  aceita  fichas=1.0
t=0.0s  aceita  fichas=0.0
t=0.0s  recusa  fichas=0.0
t=0.0s  recusa  fichas=0.0
t=0.5s  recusa  fichas=0.5
t=1.0s  aceita  fichas=0.0
t=3.0s  aceita  fichas=1.0
t=3.0s  aceita  fichas=0.0
t=3.0s  recusa  fichas=0.0
```

A rajada de sete no instante zero leva cinco; meio segundo depois, meia ficha não paga nada; dois segundos parados rendem duas fichas e não três. Esta classe serve para um processo. Com várias réplicas, ela precisa morar no Redis.

### O mesmo balde no Redis

O script Lua faz leitura, cálculo e gravação sem que outro comando se intercale. Ele usa o relógio do próprio Redis (`TIME`), e não o das réplicas, para que um servidor com o relógio adiantado não ganhe fichas de presente:

```python
import os

import redis

TOKEN_BUCKET = """
local capacidade = tonumber(ARGV[1])
local taxa = tonumber(ARGV[2])
local custo = tonumber(ARGV[3])

local t = redis.call('TIME')
local agora = tonumber(t[1]) + tonumber(t[2]) / 1000000

local estado = redis.call('HMGET', KEYS[1], 'fichas', 'ultimo')
local fichas = tonumber(estado[1]) or capacidade
local ultimo = tonumber(estado[2]) or agora

fichas = math.min(capacidade, fichas + (agora - ultimo) * taxa)
local aceita, espera = 0, 0
if fichas >= custo then
  fichas = fichas - custo
  aceita = 1
else
  espera = math.ceil((custo - fichas) / taxa)
end

redis.call('HSET', KEYS[1], 'fichas', fichas, 'ultimo', agora)
redis.call('EXPIRE', KEYS[1], math.ceil(capacidade / taxa) + 1)
return {aceita, espera}
"""

r = redis.Redis.from_url(os.environ["REDIS_URL"])
token_bucket = r.register_script(TOKEN_BUCKET)


def permitir(chave_api: str) -> tuple[bool, int]:
    aceita, espera = token_bucket(keys=[f"rl:{chave_api}"], args=[100, 10, 1])
    return bool(aceita), espera


resultados = [permitir("vale-do-milho") for _ in range(103)]
aceitas = sum(1 for ok, _ in resultados if ok)
print(f"aceitas: {aceitas}, recusadas: {103 - aceitas}")
print(f"última recusa: Retry-After {resultados[-1][1]}")
```

```text
aceitas: 100, recusadas: 3
última recusa: Retry-After 1
```

O `EXPIRE` apaga a chave quando o balde já estaria cheio de novo, e a espera devolvida vai direto para o `Retry-After` do 429.

### Load shedding num middleware ASGI

Um limite de concorrência por processo, com recusa antes de qualquer trabalho:

```python
from starlette.responses import JSONResponse


class LimiteDeConcorrencia:
    def __init__(self, app, maximo: int) -> None:
        self.app = app
        self.maximo = maximo
        self.em_andamento = 0

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http" or scope["path"] == "/pronto":
            return await self.app(scope, receive, send)
        if self.em_andamento >= self.maximo:
            recusa = JSONResponse(
                {"type": "about:blank", "title": "Service Unavailable", "status": 503},
                status_code=503,
                headers={"Retry-After": "2"},
                media_type="application/problem+json",
            )
            return await recusa(scope, receive, send)
        self.em_andamento += 1
        try:
            await self.app(scope, receive, send)
        finally:
            self.em_andamento -= 1


# app.add_middleware(LimiteDeConcorrencia, maximo=30)
```

O contador dispensa lock porque não há `await` entre a checagem e o incremento (capítulo 5). A rota de readiness fica de fora de propósito, como as armadilhas explicam. Acima de 30 em andamento, a recusa sai em microssegundos:

```bash
curl -i https://previsao.exemplo.com/v1/previsao/3550308
```

```text
HTTP/1.1 503 Service Unavailable
date: Mon, 19 Oct 2026 06:03:41 GMT
server: uvicorn
retry-after: 2
content-length: 65
content-type: application/problem+json

{"type":"about:blank","title":"Service Unavailable","status":503}
```

## Propriedades e custos

| Algoritmo | Estado por chave | Rajada | Precisão | Observação |
|-----------|------------------|--------|----------|------------|
| Janela fixa | 1 contador | até 2× o limite na emenda | baixa na fronteira | reset sincronizado de todos os clientes |
| Janela deslizante (log) | 1 timestamp por requisição | nenhuma além do limite | exata | memória cresce com o limite |
| Janela deslizante (contador) | 2 contadores | pequena | aproximada | supõe distribuição uniforme na janela anterior |
| Token bucket | saldo + timestamp | até `b`, configurável | exata para `b + r × t` | rajada e média ajustáveis em separado |
| Leaky bucket (fila) | fila + timestamp | nenhuma na saída | exata | adiciona latência de espera |
| GCRA | 1 timestamp | até `b` | exata | tempo de espera sai direto da conta |

O contador central é exato e custa uma ida e volta por requisição mais uma dependência no caminho crítico; o local custa zero de rede e erra conforme o desbalanceamento. Backpressure preserva todo o trabalho e exige um produtor que possa esperar; load shedding perde trabalho de propósito para manter a latência do aceito. O limite fixo é simples e envelhece; o adaptativo acompanha as mudanças e é mais difícil de entender quando dispara às 3h.

## Armadilhas e casos reais

> **Armadilha:** limitar por IP. Atrás de um CGNAT, milhares de usuários de uma operadora móvel compartilham um IPv4 e são bloqueados juntos pelo excesso de um. No IPv6, cada cliente costuma receber um /64 inteiro, o que torna o limite por endereço decorativo; o limite vai no prefixo. E ler o IP de um `X-Forwarded-For` que o cliente controla entrega a chave do limite ao próprio cliente (capítulo 27).

A janela fixa e o `Retry-After` combinam mal. Depois do incidente, a API ganhou janela fixa por minuto, e a cooperativa ganhou o `sync_chuva.py` versão 2, que respeita o `Retry-After` com precisão de relógio atômico e foi copiado para as 900 cooperativas parceiras. Todas foram bloqueadas no mesmo minuto, receberam `Retry-After: 37` e voltaram juntas, no mesmo segundo. Jitter no valor devolvido desfaz o pelotão.

> **Armadilha:** aplicar shedding na rota de readiness. O pod sobrecarregado responde 503 ao health check, sai de rotação, e o tráfego dele sobrecarrega os outros, que saem também. Em poucos ciclos sobra um pod, que dura pouco.

Contar requisições quando o custo varia também surpreende: uma busca que lê 2 GB e um `GET /status` valem uma ficha cada num limite ingênuo. Token bucket com custo por operação resolve (o capítulo 24 mostra APIs GraphQL cobrando pontos por consulta). E um rate limit de login aplicado depois de verificar a senha com Argon2 protege a conta e deixa a CPU desprotegida: o atacante paga uma requisição, o servidor paga um hash caro.

> **Na vida real:** a Stripe descreveu em 2017 ("Scaling your API with rate limiters") quatro limitadores em produção: requisições por usuário com token bucket em Redis, requisições concorrentes, e dois load shedders, um que reserva parte da frota para requisições críticas e outro que descarta tráfego de menor prioridade com os workers saturados. Antes de bloquear alguém, os limitadores passaram um tempo só registrando quem seria bloqueado.

## Resumo

- A chave do limite (API key, conta, prefixo IP) decide quem paga pelo excesso.
- Janela fixa deixa passar o dobro na emenda; janela deslizante corrige com log exato ou contador aproximado.
- Token bucket separa média (`r`) e rajada (`b`); GCRA faz o mesmo com um timestamp.
- Distribuído: contador central atômico (Lua no Redis) ou local `limite / N`; fail open ou fail closed por tipo de limite.
- Sobrecarga total pede fila limitada com backpressure ou load shedding barato e cedo; sem isso, o goodput vai a zero.
- 429 para cliente acima da cota, 503 para servidor sobrecarregado, `Retry-After` com jitter.

## Referências

- RFC 6585, Additional HTTP Status Codes (429): https://www.rfc-editor.org/rfc/rfc6585
- RFC 9110, HTTP Semantics (`Retry-After`, 503): https://www.rfc-editor.org/rfc/rfc9110
- RFC 8289, Controlled Delay Active Queue Management: https://www.rfc-editor.org/rfc/rfc8289
- IETF httpapi, RateLimit header fields for HTTP (rascunho): https://datatracker.ietf.org/doc/draft-ietf-httpapi-ratelimit-headers/
- Redis, documentação do `INCR` (padrão de rate limiter): https://redis.io/docs/latest/commands/incr/
- nginx, módulo `ngx_http_limit_req_module`: https://nginx.org/en/docs/http/ngx_http_limit_req_module.html
- Uvicorn, configurações (`--limit-concurrency`): https://www.uvicorn.org/settings/
- Cloudflare, "How we built rate limiting capable of scaling to millions of domains" (2017): https://blog.cloudflare.com/counting-things-a-lot-of-different-things/
- Stripe, "Scaling your API with rate limiters" (2017): https://stripe.com/blog/rate-limiters
- Google SRE Book, "Handling Overload": https://sre.google/sre-book/handling-overload/
- Ben Maurer, "Fail at Scale", ACM Queue (2015): https://queue.acm.org/detail.cfm?id=2839461
- Netflix, concurrency-limits: https://github.com/Netflix/concurrency-limits
- brandur, redis-cell (GCRA no Redis): https://github.com/brandur/redis-cell
