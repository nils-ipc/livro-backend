# Cache

## Meia-noite, 4.000 clientes e uma chave que expirou

No código da home de um e-commerce hipotético, logo acima da linha que grava a chave `home:ofertas` no Redis, mora um comentário de 2021: `# TODO: pensar na invalidação`. São 23h59min58s da véspera de uma grande liquidação, e esse comentário está a dois segundos de ficar famoso.

A home está voando. A lista de ofertas vem de uma consulta pesada, de 800 ms, que junta preços, estoque e as regras de desconto que o time comercial alterou 31 vezes durante a tarde. Ninguém roda essa consulta a cada acesso, claro. O resultado mora no Redis, com TTL de uma hora. O banco recebe uma consulta por hora e passa o resto do tempo descansando. Taxa de acerto do cache: 99,97%. O painel está verde.

À meia-noite em ponto, a chave expira. Ela foi gravada às 23h00, quando um *deploy* reiniciou tudo, e o TTL cumpriu o prometido. Nos 800 ms seguintes, 3.200 requisições olham o Redis, não acham nada e, com toda a disciplina, vão ao banco executar a consulta pesada. As consultas passam de 30 segundos, as requisições dão timeout antes de gravar o resultado, a chave continua vazia, e as requisições seguintes também vão ao banco. Às 0h04, a liquidação está oficialmente aberta e oficialmente fora do ar.

O cache funcionou perfeitamente durante 59 minutos e 59 segundos. A pergunta deste capítulo é: como um cache que acerta 99,97% das vezes derruba o banco justamente no instante em que erra, e o que precisa existir no desenho para que errar não seja fatal?

## O que um cache promete, e a conta que ele manda depois

Um *cache* é uma cópia de dados guardada num lugar mais rápido ou mais barato de ler do que a fonte, que continua sendo a verdade. Toda cópia pode estar desatualizada. Essa frase resume todos os problemas do capítulo; o resto é detalhe de engenharia.

Uma leitura que encontra o dado no cache é um *hit* (acerto). Uma que não encontra é um *miss* (falha), e precisa ir à fonte. A **taxa de acerto** `h` é a fração de leituras que acertam. Com ela saem duas contas que governam tudo:

```text
latência média = h × t_cache + (1 − h) × (t_cache + t_fonte)
carga na fonte = (1 − h) × requisições por segundo
```

A segunda conta é a que surpreende. Com 10.000 requisições por segundo, `h = 0,99` manda 100 por segundo ao banco. Com `h = 0,98`, manda 200. Um ponto percentual de queda na taxa de acerto dobra a carga no banco. E com o cache vazio, depois de um reinício ou de um `FLUSHALL` digitado no terminal errado, o banco recebe as 10.000, cem vezes o normal.

Daí a propriedade menos lembrada: **depois que o banco foi dimensionado contando com o cache, o cache virou dependência de capacidade**. Ninguém decide isso numa reunião. Acontece sozinho, no dia em que alguém reduz a instância do banco "já que quase tudo vem do Redis".

## Os quatro padrões de leitura e escrita

Os padrões são quatro, e diferem em quem fala com o banco e quando.

**Cache-aside** (ou *lazy loading*). A aplicação consulta o cache; no *miss*, lê do banco e grava no cache. Na escrita, atualiza o banco e apaga a chave. O cache nem sabe que o banco existe. Só entra no cache o que alguém leu, e qualquer chave-valor serve. O custo: a lógica de consistência fica espalhada por cada função que escreve no banco (inclusive aquela que alguém criou em 2022 e que ninguém sabe que existe).

**Read-through.** O mesmo fluxo, mas quem vai ao banco no *miss* é a camada de cache, configurada com uma função de carga. A aplicação só chama `cache.get(chave)`, e a lógica de carga fica num lugar só.

**Write-through.** Toda escrita passa pelo cache, que grava no banco de forma síncrona e só confirma depois dos dois. A latência de escrita soma os dois sistemas, e o cache guarda dados que talvez ninguém leia. E continuam sendo duas escritas sem transação entre elas: se o processo morrer no meio, as cópias divergem (o capítulo 22 trata da escrita dupla).

**Write-behind** (ou *write-back*). A escrita vai ao cache, é confirmada na hora, e chega ao banco depois, em lote. Dez atualizações do mesmo contador viram uma. Mas, entre confirmar e persistir, o dado só existe na memória do cache, e se o nó cair nessa janela a escrita confirmada desaparece. Para um contador de visualizações, tudo bem. Para um saldo bancário, é uma conversa difícil com o setor jurídico.

```text
Cliente:  Paguei a fatura?
Cache:    Pagou. Confirmado.
Cache:    (reinicia por falta de memória)
Banco:    Que fatura?
```

## Invalidação, ou por que aquele TODO tem cinco anos

Três ferramentas mantêm o cache perto da fonte, quase sempre juntas.

**TTL** (*time to live*): a chave expira sozinha depois de N segundos. É a única que funciona quando todo o resto falhou, porque não depende de ninguém lembrar de nada. O TTL é o atraso máximo aceito: com 300 s, o dado pode estar cinco minutos velho, e o sistema precisa aguentar isso.

**Invalidação explícita**: quem escreve no banco apaga a chave. Apagar em vez de regravar tem motivo concreto: com dois escritores, as gravações podem chegar ao cache em ordem diferente da do banco, e o valor mais antigo fica por último. Um `DEL` não carrega valor que possa chegar fora de ordem.

**Chaves versionadas**: a versão entra no nome (`produto:42:v7`). Atualizar o produto incrementa a versão, e a chave antiga deixa de ser lida e morre pelo TTL. Um contador de geração por namespace (`catalogo:gen = 18`) dentro de todas as chaves do catálogo invalida milhões delas com um único `INCR`, e as antigas ficam ocupando memória até o despejo, numa aposentadoria bem remunerada.

### A corrida que o "apague depois de escrever" não resolve

Mesmo fazendo tudo certo no cache-aside (atualizar o banco, depois apagar a chave), existe uma intercalação que deixa um valor velho no cache sem prazo além do TTL:

```text
t0  Leitor:   GET produto:42          → miss
t1  Leitor:   SELECT preco ... (lê R$ 100, valor antigo)
t2  Escritor: UPDATE preco = 80; COMMIT
t3  Escritor: DEL produto:42          (apaga uma chave que nem existe)
t4  Leitor:   SET produto:42 = 100    (grava o valor velho, com TTL cheio)
```

Basta o leitor ficar lento entre `t1` e `t4` (uma pausa do garbage collector resolve). O preço de R$ 100 dura um TTL inteiro, com todo mundo jurando que a invalidação está implementada. E está. Ela só chegou cedo demais.

Gravar com `SET ... NX` não ajuda, porque em `t4` a chave realmente não existia. O **lease** resolve: no *miss*, o cache entrega um token ao leitor; um `DEL` invalida o token; o `SET` só é aceito com token válido. Em `t4`, o `DEL` de `t3` já invalidou o token, e a gravação velha é recusada. O mecanismo está no artigo do Facebook sobre memcache (NSDI 2013); no Redis, que não tem leases nativos, o equivalente é um script Lua que compara um token gravado no *miss*. O **duplo delete** (apagar de novo alguns segundos depois) fecha a janela na maioria dos casos, com aquele gosto de "na maioria dos casos". E o TTL limita o estrago em todas as alternativas.

Quando vários serviços escrevem no banco, a invalidação pode sair do log do próprio banco: um processo lê o fluxo de alterações (*change data capture*, capítulo 22) e apaga as chaves afetadas. O mesmo artigo do Facebook descreve um daemon que lê o log de commits do MySQL e distribui os deletes. Nenhuma escrita escapa, nem o script de correção rodado direto no `psql` numa sexta à noite.

## Quando a memória acaba

O cache tem tamanho finito, e quando enche precisa escolher quem sai. Essa é a **política de despejo** (*eviction*).

**LRU** (*least recently used*) despeja a chave acessada há mais tempo: dicionário mais lista duplamente ligada, tudo em O(1), que é o `functools.lru_cache` do Python. A fraqueza é a varredura: um relatório que lê um milhão de chaves uma vez só expulsa todas as chaves quentes, que perderam o posto para um visitante.

**LFU** (*least frequently used*) despeja a menos acessada. Resiste à varredura, mas a chave que foi popular ontem acumula contagem e fica ocupando memória, aposentada e com estabilidade. Por isso os contadores práticos decaem com o tempo.

O Redis implementa as duas de forma aproximada. No LRU, sorteia `maxmemory-samples` chaves (5 por padrão) e despeja a mais antiga entre as candidatas. No LFU (desde a 4.0), cada chave tem um contador **logarítmico** de 8 bits: o incremento é probabilístico e fica mais raro conforme o contador cresce (com `lfu-log-factor` 10, o padrão, o teto de 255 chega perto de um milhão de acessos). Chaves novas começam em 5, para não morrerem no primeiro segundo, e o contador decai a cada `lfu-decay-time` (1 minuto).

`allkeys-lru` e `allkeys-lfu` despejam qualquer chave; as variantes `volatile-*` só as que têm TTL. E o padrão é `noeviction`: com a memória cheia, o Redis recusa escritas com `OOM command not allowed when used memory > 'maxmemory'`. Para fila ou armazenamento, é o certo. Para cache, é uma pegadinha que espera a memória encher:

```text
127.0.0.1:6379> CONFIG GET maxmemory-policy
1) "maxmemory-policy"
2) "noeviction"
127.0.0.1:6379> INFO stats
...
keyspace_hits:918204471
keyspace_misses:2754613
evicted_keys:0
...
```

`evicted_keys:0` parece saudável. Com `noeviction`, ele sempre será zero; o problema aparece em outro lugar, nos erros de escrita da aplicação. A taxa de acerto sai de `hits / (hits + misses)`, aqui 99,70%.

## Cache stampede, ou mil processos tendo a mesma ideia

O incidente da abertura tem nome: *cache stampede* (ou *thundering herd*). Uma chave popular expira, e todas as requisições que chegam durante a recomputação concluem, cada uma corretamente, que precisam recomputar. A carga vira `taxa × tempo_de_recomputação` de uma vez: 4.000 req/s × 0,8 s = 3.200 consultas idênticas, e cada uma deixa a seguinte mais lenta, o que alarga a janela e traz mais requisições para dentro dela.

Dentro de um único processo, com mil requisições concorrentes:

```python
import asyncio

consultas_ao_banco = 0
cache: dict[str, list[str]] = {}
em_voo: dict[str, asyncio.Task] = {}


async def buscar_ofertas_no_banco() -> list[str]:
    global consultas_ao_banco
    consultas_ao_banco += 1
    await asyncio.sleep(0.8)  # a consulta de 800 ms, agora em versão econômica
    return ["geladeira", "air fryer", "outra air fryer"]


async def ofertas_ingenuo() -> list[str]:
    if "ofertas" in cache:
        return cache["ofertas"]
    valor = await buscar_ofertas_no_banco()  # TODO: pensar na invalidação
    cache["ofertas"] = valor
    return valor


async def _carregar(chave: str) -> list[str]:
    valor = await buscar_ofertas_no_banco()
    cache[chave] = valor
    return valor


async def ofertas_coalescido() -> list[str]:
    chave = "ofertas"
    if chave in cache:
        return cache[chave]
    tarefa = em_voo.get(chave)
    if tarefa is None:  # só o primeiro a chegar vai ao banco
        tarefa = asyncio.create_task(_carregar(chave))
        em_voo[chave] = tarefa
        tarefa.add_done_callback(lambda _: em_voo.pop(chave, None))
    return await asyncio.shield(tarefa)


async def main() -> None:
    global consultas_ao_banco
    await asyncio.gather(*(ofertas_ingenuo() for _ in range(1000)))
    print(f"ingênuo:    {consultas_ao_banco} consultas ao banco")
    cache.clear()
    consultas_ao_banco = 0
    await asyncio.gather(*(ofertas_coalescido() for _ in range(1000)))
    print(f"coalescido: {consultas_ao_banco} consulta ao banco")


asyncio.run(main())
```

```text
ingênuo:    1000 consultas ao banco
coalescido: 1 consulta ao banco
```

A versão ingênua não tem bug no sentido usual: são mil decisões corretas que somadas formam uma péssima. A coalescida é a **coalescência de requisições** (*request coalescing*; *singleflight* na biblioteca Go de mesmo nome): a primeira dispara a carga, as outras esperam o mesmo resultado. O `asyncio.shield` está ali porque cancelar quem faz `await` numa `Task` cancela a `Task`; sem ele, um cliente impaciente cancelaria a carga dos outros 999.

A coalescência vale por processo: com 40 processos, o banco recebe 40 consultas em vez de 3.200. Para o restante:

**Lock na recomputação.** No *miss*, o processo tenta `SET recalc:home:ofertas <token> NX PX 5000`. Quem consegue recomputa; os outros releem o cache em alguns milissegundos ou servem um valor antigo. Os limites de locks distribuídos estão no capítulo 5; aqui, uma falha do lock custa só uma recomputação a mais.

**Servir o velho enquanto recalcula** (*stale-while-revalidate*). O valor guarda um "fresco até" lógico, e o TTL físico é bem maior. Vencido o prazo lógico, uma requisição pega o lock e recalcula em segundo plano, e as outras recebem o valor velho na hora. Ninguém espera, e o banco vê uma consulta.

**Expiração antecipada probabilística.** O algoritmo XFetch (Vattani, Chierichetti e Lowenstein, VLDB 2015) faz cada leitura decidir recalcular antes do vencimento, com probabilidade que cresce conforme ele se aproxima.

```python
import math
import random
import time


def deve_recalcular(expira_em: float, delta: float, beta: float = 1.0) -> bool:
    # delta: quanto a última recomputação demorou, em segundos
    # 1.0 - random.random() está em (0, 1]: log(0) fica para outro dia
    sorteio = -delta * beta * math.log(1.0 - random.random())
    return time.time() + sorteio >= expira_em
```

A probabilidade de recalcular, faltando `t` segundos, é `e^(−t / (delta × beta))`. Com `delta = 0,8 s`:

```text
faltando 5.0 s:   0.19% por requisição
faltando 3.0 s:   2.35% por requisição
faltando 2.0 s:   8.21% por requisição
faltando 1.0 s:  28.65% por requisição
faltando 0.5 s:  53.53% por requisição
faltando 0.1 s:  88.25% por requisição
```

Com 4.000 req/s, a 5 s do vencimento já há cerca de 8 recomputações por segundo, e a primeira que terminar renova a chave antes que alguém veja a expiração. Recomputações caras (`delta` maior) começam mais cedo sozinhas. Sem coordenação nenhuma, o preço é algumas recomputações duplicadas em vez de 3.200.

**Jitter no TTL.** Um job aquece 50.000 chaves às 3h00 com TTL de 3.600 s, e todas vencem juntas às 4h00. Um TTL de 3.600 ± 10% espalha os vencimentos por 12 minutos. Uma linha de código, e uma mensagem a menos às 4h01.

## Camadas: do dicionário do processo à CDN

O mesmo dado pode estar em cache em vários lugares, cada um com latência, alcance e forma de invalidar diferentes.

| Camada | Latência típica de leitura | Compartilhado entre | Como invalidar |
|---|---|---|---|
| Memória do processo (`dict`, `lru_cache`, `cachetools`) | dezenas a centenas de ns | um processo | TTL curto; mensagem por pub/sub para cada processo |
| Cache remoto (Redis, Valkey, Memcached) | ~0,2 a 1 ms, dominado pelo RTT da rede | todas as réplicas | `DEL`, versão na chave, TTL |
| Cache HTTP do cliente (navegador, cliente HTTP) | zero rede | um cliente | só pelo prazo e por revalidação; não há como apagar remotamente |
| Proxy reverso e CDN | RTT até a borda mais próxima | todos os clientes de uma região | TTL, *purge* por URL ou por etiqueta, conforme o fornecedor |

O cache em processo é o mais rápido e o mais traiçoeiro. Com 40 processos, há 40 cópias com 40 TTLs, e depois de uma atualização o cliente que recarrega a página vê o preço alternar como num leilão. O `functools.lru_cache` nem tem TTL: o valor fica até o despejo (`maxsize=128` por padrão) ou até o processo reiniciar, e o próximo deploy vira a estratégia oficial de invalidação.

O cache HTTP segue a RFC 9111 (o capítulo 2 detalha `Cache-Control`, `ETag` e validação condicional). A RFC 5861 acrescenta `stale-while-revalidate=N`, a mesma técnica de antes executada pela CDN, e `stale-if-error=N`, que serve a resposta velha quando a origem devolve erro e transforma uma origem fora do ar em uma origem levemente desatualizada (quando a CDN implementa a diretiva).

Ninguém invalida o cache do navegador. Uma resposta com `max-age=31536000` fica lá um ano. Por isso estáticos usam hash do conteúdo no nome (`app.3f9a1c.js`): versão nova é outra URL.

## Propriedades e custos

| Padrão | Latência de leitura | Latência de escrita | Janela de inconsistência | Risco de perda | Onde fica a lógica |
|---|---|---|---|---|---|
| Cache-aside | *miss* paga cache + banco | só banco + `DEL` | até o TTL nas corridas | nenhum (banco é a verdade) | aplicação |
| Read-through | igual ao cache-aside | igual ao cache-aside | igual ao cache-aside | nenhum | camada de cache |
| Write-through | *hit* quase sempre | cache + banco, em série | divergência se falhar entre as duas escritas | nenhum para o que foi confirmado | camada de cache |
| Write-behind | *hit* quase sempre | só cache | banco atrasado por desenho | escritas confirmadas e ainda não persistidas | camada de cache |

O cache-aside pesa a favor quando a leitura domina e um atraso limitado pelo TTL é aceitável. O write-through, quando o dado escrito é lido logo depois e a latência extra de escrita cabe no orçamento. O write-behind, quando o volume de escrita é o gargalo e o dado tolera perder uma janela (contadores, métricas). Em todos, a pergunta que decide é "o que acontece se este valor estiver N segundos velho?". Se a resposta for "alguém paga duas vezes", o dado fica fora do cache.

## Armadilhas e casos reais

> **Armadilha:** chaves que nunca existem. Quem pede `produto:999999999` repetidamente sempre vai ao banco, porque "não existe" não fica gravado em lugar nenhum (*cache penetration*, um ataque barato). As defesas são cachear a ausência com TTL curto (*negative caching*) e, para espaços de chave enormes, um filtro de Bloom na frente.

> **Armadilha:** chave sem o tenant. Com `relatorio:mensal:2026-09` em vez de `tenant:812:relatorio:mensal:2026-09`, o primeiro cliente grava o relatório dele e todos os outros o recebem, com muita eficiência. A chave precisa conter tudo de que a resposta depende, e respostas autenticadas na CDN precisam de `Cache-Control: private` ou `no-store`.

> **Armadilha:** `pickle` no cache. `pickle.loads` executa código definido pelo conteúdo serializado, então quem conseguir escrever no Redis executa código em todos os processos que leem dele. JSON e MessagePack não fazem isso (o capítulo 32 trata de deserialização insegura).

> **Armadilha:** o cache que esconde o bug. Uma consulta de 6 segundos atrás de um TTL de 1 hora passa meses despercebida, porque só um usuário por hora a paga. A latência de *miss* precisa de um gráfico próprio, e o cache frio precisa ser testado antes que a produção teste por conta própria.

> **Na vida real:** em 23 de setembro de 2010, o Facebook ficou cerca de duas horas e meia fora do ar. Segundo a publicação da empresa, um sistema automático passou a considerar inválido um valor de configuração, e cada cliente que o via tentava corrigi-lo consultando um cluster de banco. Os erros do banco sobrecarregado eram lidos como mais valores inválidos, que geravam mais consultas. O laço só parou quando o tráfego para o cluster foi cortado, o que tirou o site do ar. Cada cliente reagiu corretamente à falta de um dado, e a soma das reações impediu que o dado voltasse.

> **Na vida real:** em 20 de março de 2023, o ChatGPT mostrou a alguns usuários títulos de conversas de outros. O postmortem da OpenAI atribuiu a falha a um bug na `redis-py`: uma requisição cancelada no meio deixava a conexão compartilhada corrompida, e a seguinte, de outro usuário, recebia a resposta da anterior. Segundo a empresa, dados parciais de pagamento de cerca de 1,2% dos assinantes do ChatGPT Plus ativos numa janela de nove horas podem ter ficado visíveis.

## Resumo

- Carga na fonte = `(1 − h) × taxa`: de 99% para 98% de acerto, a carga dobra. Banco dimensionado contando com o cache torna o cache dependência de capacidade.
- Cache-aside e read-through carregam no *miss*; write-through grava nos dois de forma síncrona; write-behind confirma antes de persistir e pode perder escritas.
- Invalidar é apagar. A corrida leitor lento × escritor ainda deixa valor velho por um TTL: leases resolvem, duplo delete reduz, TTL limita.
- Redis: LRU e LFU aproximados, `noeviction` por padrão.
- Stampede: coalescência, lock na recomputação, servir o velho enquanto recalcula, XFetch, jitter no TTL.
- Cache em processo diverge entre réplicas; o navegador não pode ser invalidado.
- A chave inclui o tenant; `pickle` no cache é execução remota esperando um acesso indevido.

## Referências

- RFC 9111, HTTP Caching: <https://www.rfc-editor.org/rfc/rfc9111>
- RFC 5861, HTTP Cache-Control Extensions for Stale Content: <https://www.rfc-editor.org/rfc/rfc5861>
- Nishtala et al., "Scaling Memcache at Facebook", NSDI 2013: <https://www.usenix.org/conference/nsdi13/technical-sessions/presentation/nishtala>
- Vattani, Chierichetti e Lowenstein, "Optimal Probabilistic Cache Stampede Prevention", VLDB 2015: <https://www.vldb.org/pvldb/vol8/p886-vattani.pdf>
- Redis, Key eviction: <https://redis.io/docs/latest/develop/reference/eviction/>
- Python, `functools.lru_cache`: <https://docs.python.org/3/library/functools.html#functools.lru_cache>
- Python, `pickle` (aviso de segurança): <https://docs.python.org/3/library/pickle.html>
- Facebook, "More Details on Today's Outage" (23/09/2010): <https://www.facebook.com/notes/facebook-engineering/more-details-on-todays-outage/431441338919/>
- OpenAI, "March 20 ChatGPT outage: Here's what happened": <https://openai.com/index/march-20-chatgpt-outage/>
