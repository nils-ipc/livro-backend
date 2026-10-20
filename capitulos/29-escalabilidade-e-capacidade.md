# Escalabilidade e capacidade

## Domingo, 20h47, bolo de fubá

Às 20h47 de um domingo, a apresentadora de um programa culinário de TV olhou para a câmera, ergueu um bolo de fubá e disse: "a receita está no aplicativo, é só apontar o celular para o QR code". A situação é hipotética. O resto, infelizmente, segue a física.

O aplicativo de receitas recebia 60 requisições por segundo, servidas com folga por 3 pods. Noventa segundos depois do QR code, eram 9.000. O autoscaling, com meta de 70% de CPU, reagiu como prometia a documentação: pediu mais pods. Cada pod novo levava três minutos para ficar pronto, carregando 1,2 GB de vetores da "busca inteligente de receitas", recurso usado por 0,4% dos usuários.

Enquanto isso, os 3 pods originais devolviam timeout para quase todo mundo. Sob carga, a liveness probe deles estourou o prazo, e o Kubernetes os reiniciou, um de cada vez, com a serenidade de quem cumpre um regulamento. Cada reinício apagava as sessões guardadas num dicionário Python. Milhares de pessoas, de avental, foram deslogadas no meio da lista de ingredientes.

O sistema chegou à capacidade necessária às 21h05. O bloco do bolo tinha terminado às 20h58. Às 21h10, o autoscaling começou a remover pods, satisfeito com o trabalho.

Duas perguntas saem dessa noite. O que precisa ser verdade no código para que "mais tráfego" se resolva com "mais réplicas"? E quanto tempo antes do pico essas réplicas precisam existir?

## Crescer para cima ou para os lados

Há duas formas de aumentar a capacidade de um serviço.

**Escala vertical** (*scale up*) é trocar a máquina por uma maior. O código não muda: locks em memória e cache local continuam valendo, porque tudo continua numa máquina só. Os limites são três. As maiores instâncias dos provedores de nuvem chegam a algumas centenas de vCPUs e, nas famílias de memória alta, a dezenas de terabytes de RAM, e depois disso o catálogo acaba. A troca costuma exigir reinício ou failover. E uma máquina é um domínio de falha só: quando ela cai, cai tudo, com mais núcleos.

**Escala horizontal** (*scale out*) é adicionar cópias do serviço atrás de um balanceador. A falha de uma réplica tira só uma fração da capacidade, e réplicas nascem e morrem conforme a demanda. O preço: o serviço precisa aguentar ser copiado, e a maioria dos escritos sem pensar nisso não aguenta.

Escala horizontal também tem teto, escondido no que as réplicas compartilham. Pela Lei de Amdahl, se só a fração `p` do trabalho paraleliza, o ganho máximo é `1 / (1 − p)`. A Universal Scalability Law de Neil Gunther acrescenta um custo de coordenação que cresce com o número de réplicas e, a partir de certo ponto, faz a vazão *cair* (o capítulo 6 trata das duas). Num backend web, a parte serial costuma ter nome e endereço: o banco de dados.

> **Na vida real:** a configuração mais comum é horizontal na aplicação e vertical no banco, que depois ganha réplicas de leitura (capítulo 13) e, por último, sharding (capítulo 14). Cem réplicas da API apontando para um banco de 8 núcleos são cem formas diferentes de esperar pelo mesmo banco.

## Stateless, ou onde o estado foi parar

Um serviço é **stateless** quando qualquer réplica atende qualquer requisição, e matar qualquer réplica perde, no máximo, as requisições em andamento nela. O estado continua existindo (sem ele, o aplicativo seria um gerador de bolos aleatórios); só mora fora do processo.

O teste: se a próxima requisição deste usuário for para outra réplica, ou se esta réplica morrer agora, algo se perde? Tudo o que responde "sim" é estado local, e cada tipo tem destino conhecido:

| Estado local | Sintoma ao escalar | Para onde vai |
|---|---|---|
| Sessão num dicionário em memória | Usuário deslogado ao trocar de réplica | Redis, banco ou cookie assinado |
| Upload salvo no disco do contêiner | Arquivo some no reinício; outra réplica não acha | Armazenamento de objetos |
| Cache em processo | N cópias, cada uma desatualizada de um jeito | Aceitar a divergência com TTL curto, ou cache compartilhado |
| Contador de rate limit em memória | Limite real vira N × limite | Redis com operação atômica (capítulo 28) |
| Tarefa agendada dentro da aplicação | Roda N vezes | Agendador externo, ou lock no banco |
| Lock com `threading.Lock` | Exclui só dentro do processo | Lock no banco ou operação atômica (capítulo 5) |
| Conexão WebSocket | Mensagem publicada na réplica errada | Pub/sub entre réplicas (capítulo 24) |

O fator VI da metodologia Twelve-Factor App formaliza isso e classifica a afinidade de sessão (*sticky session*) como violação. A afinidade esconde o problema enquanto as réplicas são estáveis e o devolve inteiro no primeiro autoscaling, deploy ou reinício por liveness probe.

A sessão do aplicativo de receitas era assim:

```python
import secrets
from fastapi import Cookie, FastAPI, HTTPException, Response

app = FastAPI()
SESSOES: dict[str, str] = {}  # mora na memória DESTE processo, e só dele

@app.post("/login")
def login(resposta: Response, usuario: str):
    sid = secrets.token_urlsafe(32)
    SESSOES[sid] = usuario
    resposta.set_cookie("sid", sid, httponly=True, secure=True, samesite="lax")
    return {"ok": True}

@app.get("/favoritas")
def favoritas(sid: str | None = Cookie(default=None)):
    if sid not in SESSOES:
        raise HTTPException(401, "sessão desconhecida")
    return {"usuario": SESSOES[sid], "favoritas": ["bolo de fubá"]}
```

Com três réplicas em round robin, três requisições seguidas com o mesmo cookie produzem isto:

```text
{"usuario":"zilda","favoritas":["bolo de fubá"]}
{"detail":"sessão desconhecida"}
{"detail":"sessão desconhecida"}
```

A sessão existe, com toda a certeza, na réplica que fez o login. As outras duas nunca ouviram falar da Zilda. A correção leva a sessão para onde todas as réplicas enxergam:

```python
import os
import secrets
from redis.asyncio import Redis

redis = Redis.from_url(os.environ["REDIS_URL"])
VALIDADE = 60 * 60 * 24  # 24 h, renovada a cada uso se você quiser

async def criar_sessao(usuario: str) -> str:
    sid = secrets.token_urlsafe(32)
    await redis.set(f"sessao:{sid}", usuario, ex=VALIDADE)
    return sid

async def ler_sessao(sid: str) -> str | None:
    valor = await redis.get(f"sessao:{sid}")
    return valor.decode() if valor else None
```

A alternativa é não guardar nada no servidor: um cookie assinado com HMAC (o `SessionMiddleware` do Starlette faz isso) ou um token com expiração. O custo aparece na revogação: invalidar uma sessão antes da expiração exige que alguém lembre da invalidação, e "alguém lembrar" é estado de novo (capítulo 30).

O estado mudou de lugar e continua cobrando: o Redis virou dependência de disponibilidade e de capacidade de todas as réplicas. Tornar a aplicação stateless empurra o problema de escala para a camada de dados, que é onde ele sempre esteve.

## Autoscaling, ou um laço de controle com atraso

Autoscaling é um laço de controle: mede, compara com uma meta, ajusta as réplicas, espera, repete. Com atraso grande, ele tem dois defeitos possíveis: reagir tarde demais ou reagir demais.

### A fórmula do HPA

O Horizontal Pod Autoscaler (HPA) do Kubernetes, por padrão a cada 15 segundos, calcula:

```text
réplicas_desejadas = ceil(réplicas_atuais × valor_atual / valor_desejado)
```

Com 4 réplicas a 90% de CPU e meta de 60%, `ceil(4 × 90 / 60) = 6`. Se a razão ficar dentro de uma tolerância (10% por padrão), nada muda, para que ruído na métrica não faça a contagem dançar. Para CPU, o percentual é relativo ao *request* do contêiner, e esse detalhe vai fazer a noite do bolo durar 18 minutos.

O HPA também desconfia de pods que ainda não ficaram prontos. Para decidir um aumento, ele os conta como se usassem 0% da métrica e refaz a conta; se o recálculo inverter a decisão ou cair na tolerância, não faz nada. A intenção é evitar uma segunda onda de criação causada por pods que ainda nem receberam tráfego. O efeito colateral aparece quando a métrica satura.

### A métrica que bate no teto

No aplicativo de receitas, o *limit* de CPU era igual ao *request*, então a métrica nunca passava de 100%, mesmo com uma demanda que pedia 887%. O HPA via "100% para uma meta de 70%" e concluía que bastava crescer 43%. A simulação abaixo reproduz o algoritmo com os números daquela noite: demanda equivalente a 38 pods a 70%, três minutos para um pod ficar pronto.

```python
import math

ALVO = 70          # meta de CPU, em % do request
TETO = 100         # limit igual ao request: a métrica nunca passa de 100%
TOLERANCIA = 0.1   # padrão do HPA
PARTIDA = 180      # segundos até um pod novo ficar pronto
DEMANDA = 38 * 70  # CPU necessária, em "% de um pod" (38 pods a 70%)

prontos, chegando = 3, []  # chegando: instante em que cada pod fica pronto
for t in range(0, 30 * 60, 15):  # um ciclo do HPA a cada 15 s
    prontos += sum(1 for p in chegando if p <= t)
    chegando = [p for p in chegando if p > t]
    uso = min(TETO, DEMANDA / prontos)           # CPU média dos prontos
    if uso / ALVO <= 1 + TOLERANCIA:
        print(f"t={t:>4}s  {prontos} prontos, CPU {uso:.0f}%: estável")
        break
    total = prontos + len(chegando)
    media = prontos * uso / total                # quem não está pronto conta 0%
    if media / ALVO <= 1 + TOLERANCIA:
        continue                                 # o recálculo desfaz a decisão
    desejado = min(math.ceil(total * media / ALVO), 2 * total)
    chegando += [t + PARTIDA] * (desejado - total)
    print(f"t={t:>4}s  {prontos} prontos a {uso:.0f}%, pede {desejado}")
```

```text
t=   0s  3 prontos a 100%, pede 5
t= 180s  5 prontos a 100%, pede 8
t= 360s  8 prontos a 100%, pede 12
t= 540s  12 prontos a 100%, pede 18
t= 720s  18 prontos a 100%, pede 26
t= 900s  26 prontos a 100%, pede 38
t=1080s  38 prontos, CPU 70%: estável
```

Seis rodadas, cada uma crescendo no máximo `100 / 70 ≈ 1,43×` e esperando três minutos inteiros, porque, com os zeros dos pods não prontos, a média fica abaixo da meta e o HPA conclui, com toda a calma, que está tudo bem. São 18 minutos até 38 pods. Um limit maior que o request encurtaria a escada; um pod pronto em 20 segundos a encurtaria muito mais.

### O tempo de reação, somado

O tempo entre a carga subir e a capacidade nova atender tráfego é uma soma, e quase sempre alguém só conhece a primeira parcela:

```text
reação = janela da métrica + ciclo do autoscaler
       + agendamento (+ máquina nova, se não houver nó livre)
       + download da imagem + inicialização + readiness
```

Métrica e ciclo somam algumas dezenas de segundos. Sem nó com espaço, o pod fica `Pending` até um autoscaler de nós provisionar uma máquina virtual, da ordem de um a alguns minutos. E a inicialização é o que o seu código decidir: no aplicativo de receitas, três minutos carregando vetores que quase ninguém usava.

Se o tempo de reação é `T` minutos e a carga cresce a uma taxa `g` por minuto, a capacidade de agora precisa cobrir a carga de daqui a `T` minutos:

```text
meta ≤ utilização_máxima_aceitável / (1 + g)^T
```

Com 10% por minuto e reação de 5 minutos, `1,1^5 ≈ 1,61`. Se a latência degrada acima de 80% de CPU (o joelho da curva de filas, capítulo 6), a meta fica em `80 / 1,61 ≈ 50%`. Metade da CPU paga fica ociosa de propósito, e é por isso que encurtar a inicialização economiza dinheiro. No domingo do bolo, a carga cresceu 150 vezes em 90 segundos, e nenhuma meta de utilização absorve isso. Pico com hora marcada se resolve escalando antes, por agenda (o KEDA tem um scaler cron; grupos de autoscaling de nuvem têm ações agendadas), ou tirando o pico da aplicação: a receita do bolo de fubá é a mesma para todo mundo e cabe inteira numa CDN.

### Histerese, ou como não oscilar

Se crescer e encolher usam o mesmo limiar, o sistema oscila: passa de 70%, cresce, a carga se divide, cai para 65%, encolhe, passa de 70% de novo, e cada volta custa inicializações, conexões novas no banco e caches frios. A saída é **histerese**: separar as condições de subir e de descer por uma faixa morta ou por tempo.

O HPA usa tempo, com a **janela de estabilização**: ao reduzir, adota a *maior* recomendação dos últimos 300 segundos (padrão), e só encolhe se a carga ficou baixa a janela inteira. Para aumentar, a janela padrão é zero. Grupos de autoscaling de nuvem usam *cooldown*, um intervalo após cada ação em que novas ações ficam suspensas (300 segundos por padrão no Amazon EC2 Auto Scaling). A assimetria é proposital: crescer tarde derruba requisições, encolher tarde custa algumas horas de máquina.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: receitas-api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: receitas-api
  minReplicas: 6
  maxReplicas: 80
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 200        # pode triplicar a cada 15 s
          periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
        - type: Percent
          value: 10         # encolhe no máximo 10% por minuto
          periodSeconds: 60
```

```text
$ kubectl get hpa receitas-api
NAME           REFERENCE                 TARGETS        MINPODS   MAXPODS   REPLICAS   AGE
receitas-api   Deployment/receitas-api   cpu: 48%/50%   6         80        9          41d
```

O `minReplicas: 6` também é capacidade: às 3h de uma terça, seis pods atendem quase ninguém, porque o primeiro minuto de qualquer pico será servido só por eles.

### Qual métrica

CPU é a métrica padrão porque já vem pronta, e só mede saturação quando o gargalo é a CPU.

| Métrica | Mede bem quando | Engana quando |
|---|---|---|
| CPU por pod | O trabalho é cálculo no processo | O serviço espera I/O: workers lotados com CPU em 15%; ou o limit satura a métrica |
| Requisições em andamento por pod | Quase sempre: é taxa × latência (Little), a ocupação real | Exige métrica customizada e conhecer o limite do pod |
| Requisições por segundo por pod | O custo por requisição é estável | O mix muda: busca semântica pesa mais que receita em cache |
| Backlog da fila por worker | Workers que consomem fila (KEDA lê o backlog direto) | O processamento por mensagem varia muito |
| Latência | Quase nunca, como gatilho de escala | O banco ficou lento: escalar a API abre mais conexões no banco lento |

A última linha merece uma cena. O banco fica lento, a latência sobe, o autoscaling cria réplicas, cada uma abre seu pool de conexões (capítulo 11), o banco fica mais lento, e a latência sobe de novo. O autoscaling fez exatamente o que foi pedido, e o pedido era um laço de realimentação positiva.

## Capacidade em ordem de grandeza

Estimar capacidade antes de existir tráfego é aritmética com premissas declaradas. O objetivo é acertar a ordem de grandeza e descobrir qual recurso acaba primeiro. Três casas decimais sobre um fator de pico chutado são um chute com mais algarismos.

Os números de apoio cabem numa tabela:

| Quantidade | Valor | Aproximação útil |
|---|---|---|
| Segundos num dia | 86.400 | 10^5 |
| Segundos num mês | ~2,6 milhões | 2,5 × 10^6 |
| Segundos num ano | ~31,5 milhões | 3 × 10^7 (π × 10^7, para quem gosta) |
| 1 milhão de eventos por dia | ~11,6 por segundo | ~12/s |
| 1 Gbit/s | 125 MB/s | |
| 2^10, 2^20, 2^30, 2^40 | KiB, MiB, GiB, TiB | 10^3, 10^6, 10^9, 10^12 |

O que transforma média em capacidade é o **fator de pico**: a razão entre a taxa no pior momento e a média. Ele vem do histórico do sistema ou de um parecido; sem histórico, é uma premissa e fica escrito como premissa.

Uma estimativa para o aplicativo de receitas: 2 milhões de usuários ativos por dia, 25 requisições por usuário, fator de pico 6, 12 ms de CPU por requisição, meta de 60% de CPU, 40 mil fotos enviadas por dia com 3 MiB cada (original mais miniaturas), resposta JSON média de 40 KiB.

```python
DIA = 86_400

usuarios_dia = 2_000_000
req_por_usuario = 25
fator_pico = 6
cpu_por_req = 0.012          # segundos de CPU
fotos_dia = 40_000
foto_bytes = 3 * 1024**2     # original + miniaturas
resposta_bytes = 40 * 1024   # JSON médio

media = usuarios_dia * req_por_usuario / DIA
pico = media * fator_pico
nucleos = pico * cpu_por_req / 0.6          # meta de 60% de CPU
fotos_ano = fotos_dia * foto_bytes * 365
banda = pico * resposta_bytes * 8 / 1e6     # Mbit/s

print(f"média:   {media:.0f} req/s")
print(f"pico:    {pico:.0f} req/s")
print(f"núcleos: {nucleos:.0f} (a 60% de CPU)")
print(f"fotos:   {fotos_ano / 1024**4:.1f} TiB/ano")
print(f"banda:   {banda:.0f} Mbit/s de JSON no pico")
```

```text
média:   579 req/s
pico:    3472 req/s
núcleos: 69 (a 60% de CPU)
fotos:   41.8 TiB/ano
banda:   1138 Mbit/s de JSON no pico
```

A CPU sai da Lei de Little aplicada a núcleos: taxa × tempo de CPU por requisição. São 69 núcleos no pico, uns 18 pods de 4 vCPUs. Com latência de 80 ms, os mesmos 3.472 req/s são 278 requisições em andamento, número que workers e pools precisam comportar somados.

No banco, 2,5 linhas por usuário por dia de 500 bytes dão 2,5 GB diários; com índices dobrando o volume (premissa), 1,8 TB por ano, e 5,5 TB com duas réplicas, antes dos backups. A conta responde uma pergunta que ninguém fez ainda: em três anos essa tabela precisa de particionamento por data ou de expurgo (capítulo 14).

A banda esconde o maior número. Com 30 fotos de 300 KB vistas por usuário, são 18 TB de imagens por dia, 1,7 Gbit/s em média e uns 10 Gbit/s no pico, dez vezes o JSON. A resposta, de novo, é uma CDN (provedores costumam cobrar tráfego de saída por gigabyte, o que faz desta a linha mais cara da planilha).

## Propriedades e custos

| | Escala vertical | Escala horizontal |
|---|---|---|
| Mudança no código | Nenhuma | Serviço stateless; estado externalizado |
| Teto | Maior máquina do catálogo | Gargalo compartilhado (banco, cache, lock) |
| Tempo para crescer | Reinício ou failover | Inicialização de uma réplica (segundos a minutos) |
| Domínio de falha | A máquina inteira | Uma réplica |
| Consistência | Locks e caches locais valem | Coordenação passa a ser explícita |
| Custo | Proporcional dentro de uma família de instâncias; hardware de nicho cobra mais | Proporcional às réplicas, mais balanceador e serviços de estado |
| Uso típico | Banco relacional principal | Camada de aplicação, workers |

| Estratégia de autoscaling | Garante | Custa |
|---|---|---|
| Reativa por métrica | Acompanha cargas que crescem devagar | Capacidade ociosa proporcional a `(1 + g)^T`; perde rajadas |
| Agendada | Capacidade pronta para picos de hora marcada | Pagar pelo pico mesmo se ele não vier; alguém precisa saber da agenda |
| Mínimo alto e fixo | Rajadas do tamanho da folga | Dinheiro, 24 horas por dia |
| Escala até zero | Custo zero sem tráfego | Primeira requisição paga a inicialização inteira |

## Armadilhas e casos reais

> **Armadilha:** o cron dentro da aplicação. O job das 8h que manda a "receita do dia" funciona com uma réplica. Com 12, cada assinante recebe 12 vezes o mesmo bolo de fubá. A tarefa vai para um agendador externo (um `CronJob` do Kubernetes), ou cada execução disputa um `pg_try_advisory_lock` e só quem ganha trabalha.

> **Armadilha:** a liveness probe que testa dependências ou disputa CPU com o tráfego. Sob carga, ela estoura o prazo, o pod reinicia, os restantes recebem mais carga e as probes deles estouram também. Liveness verifica só se o processo travou (capítulo 27).

O encolhimento também derruba requisições. Ao remover um pod, o Kubernetes manda `SIGTERM` e espera `terminationGracePeriodSeconds` (30 segundos por padrão) antes do `SIGKILL`. Um servidor que ignora o sinal, ou um upload de 40 segundos, perde trabalho a cada redução, toda noite, no horário em que ninguém está olhando.

O limite de conexões é a capacidade que o autoscaling nunca consulta. `maxReplicas: 80` com 4 processos e pool de 10 por pod autoriza 3.200 conexões contra um PostgreSQL com `max_connections = 100`. A conta se faz no `maxReplicas`, o número do pior dia.

As cotas do provedor também têm teto (vCPUs por região, IPs numa sub-rede). O autoscaling pede 40 máquinas, o provedor entrega 12 e uma mensagem de cota excedida num log que ninguém lê aos domingos.

> **Na vida real:** no lançamento do Pokémon GO, em julho de 2016, o tráfego chegou a 50 vezes a meta planejada e a 10 vezes a estimativa de pior caso, segundo o post do Google Cloud sobre a infraestrutura do jogo (Google Kubernetes Engine e Cloud Datastore). A estimativa de pior caso existia e era cinco vezes a meta; a realidade passou dela por uma ordem de grandeza, e o que permitiu crescer foi uma aplicação já construída para escalar horizontalmente.

## Resumo

- Vertical: máquina maior, código igual, teto de catálogo, um domínio de falha. Horizontal: mais réplicas, exige serviço stateless.
- Stateless: qualquer réplica atende qualquer requisição e pode morrer a qualquer momento; o estado vai para fora do processo, e o gargalo, para a camada de dados.
- HPA: `ceil(réplicas × atual / desejado)` a cada 15 s, tolerância de 10%, pods não prontos contam 0% ao crescer, estabilização de 300 s ao encolher.
- Métrica que satura no limit esconde a demanda e vira escada lenta.
- Meta de utilização abaixo de `utilização_máxima / (1 + g)^T`; pico com hora marcada pede escala agendada ou CDN.
- Capacidade: premissas escritas, fator de pico, Little para núcleos e concorrência, disco por ano e banda.

## Referências

- Kubernetes, "Horizontal Pod Autoscaling": <https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/>
- Kubernetes, "Pod Lifecycle" (encerramento de pods e `terminationGracePeriodSeconds`): <https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/>
- The Twelve-Factor App, "VI. Processes": <https://12factor.net/processes>
- KEDA, documentação dos scalers: <https://keda.sh/docs/latest/scalers/>
- Amazon EC2 Auto Scaling, "Scaling cooldowns": <https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-scaling-cooldowns.html>
- Starlette, `SessionMiddleware`: <https://www.starlette.io/middleware/#sessionmiddleware>
- Neil J. Gunther, *Guerrilla Capacity Planning*, Springer, 2007 (Universal Scalability Law).
- Luke Stone, "Bringing Pokémon GO to life on Google Cloud", Google Cloud Blog, 2016: <https://cloud.google.com/blog/products/containers-kubernetes/bringing-pokemon-go-to-life-on-google-cloud>
