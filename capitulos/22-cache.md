# Cache

## A tarifa por sorteio

Enquanto o Redis não chegava, o Carlos resolveu as onze leituras de tarifa com uma linha de Python, e essa linha passou três dias cobrando cada cliente do Hornero por sorteio.

A linha era um decorador:

```python
@functools.lru_cache
def tarifa_do_marketplace(marketplace_id: int) -> Tarifa: ...

tarifa_do_marketplace.cache_info()
# CacheInfo(hits=204467, misses=1, maxsize=128, currsize=1)
```

Um miss por processo, em cada um dos nove workers de temp-01, api-01 e api-02. Depois disso, cada um guardou a sua cópia da tarifa do Hornero para sempre, porque `lru_cache` não tem expiração. O primário parou de receber ~2.200 consultas por segundo no pico projetado, e o Carlos ganhou um emoji de foguete no canal.

Na segunda-feira, o comercial fechou uma tarifa Pix nova com o Mercadito Hornero: de 0,99% para 0,79%, vigente a partir da meia-noite. O banco foi atualizado. Os nove workers continuaram com 0,99% na memória, cada um com a convicção de um tio no grupo da família.

O que salvou parcialmente o Hornero foi um acidente: anos atrás, o fundador mandou reciclar cada worker a cada 50 mil requisições, para conter um vazamento de memória que ninguém achou. Os workers foram renascendo um por um, em horários aleatórios, e cada renascido cobrava 0,79%. Durante três dias, a tarifa dependeu de qual processo atendia. 6.100 cobranças saíram com 0,99%. A tarifa aplicada fica gravada na cobrança (capítulo 1), então o financeiro achou todas e devolveu a diferença em lançamentos novos, com o olhar de quem já não tem mais o que perder.

No meio do incidente, o Carlos abriu um PR chamado "cache do saldo do saque no Redis (write-through, seguro)". O PR foi fechado. O Carlos está de luto.

A pergunta: o que pode ir para o cache, por quanto tempo, como apagar o que mudou, e por que o saldo do saque nunca vai?

## Por que o cache funciona, e por que ele mente

Um cache é uma cópia de um dado, guardada num lugar mais rápido ou mais barato de ler do que a origem. Ele funciona por dois fatos empíricos sobre acesso: poucas chaves concentram a maior parte das leituras, e a mesma chave tende a ser lida de novo logo. A tarifa do Hornero é lida em cada cobrança do Hornero e muda uma vez por trimestre. É o paciente ideal.

A conta que importa é a da taxa de acerto (*hit ratio*, `h`):

```text
latência efetiva   = h × t_cache + (1 − h) × t_origem
carga na origem    = (1 − h) × leituras
```

A segunda linha é a que paga a infraestrutura. Subir a taxa de acerto de 90% para 99% parece uma melhoria de 9 pontos e corta a carga na origem por dez. A recíproca também vale, e é ela que derruba sistemas: um cache que cai de 99% para 90% multiplica por dez a carga num banco que foi dimensionado contando com o cache. Nesse dia, o banco descobre que trabalhava meio período.

O preço é a mentira. A cópia pode estar velha, e o cache não tem como saber, porque ninguém o avisa quando a origem muda. Ele é uma réplica sem protocolo de replicação. Pelos modelos do capítulo 19, a melhor garantia que um cache comum dá é consistência eventual com atraso limitado pelo TTL, e sem read-your-writes: você grava no banco, lê do cache e recebe o seu passado. O resto do capítulo é sobre controlar o tamanho dessa mentira.

## Os padrões de leitura e escrita, ou quem tem a obrigação de mentir

| Padrão | Leitura | Escrita | Risco principal |
|--------|---------|---------|-----------------|
| Cache-aside | App lê o cache; no miss, lê a origem e grava no cache | App grava na origem e apaga a chave | Corrida que regrava valor velho |
| Read-through | App lê do cache; o próprio cache busca na origem no miss | Igual ao cache-aside | O cache precisa conhecer a origem |
| Write-through | Do cache | Grava no cache e na origem, de forma síncrona | Escrita dupla; valor gravado que ninguém lê |
| Write-behind | Do cache | Grava no cache e confirma; a origem recebe depois, em lote | Perda do que estava só no cache |

O **cache-aside** é o mais comum porque o cache pode ser burro: um mapa de chaves com expiração. O **read-through** move a lógica do miss para dentro da camada de cache, concentra o código e mantém as mesmas garantias.

O **write-through** é a escrita dupla do capítulo 18 com nome bonito: o banco confirma, o processo morre antes de gravar no cache, e o cache serve o valor antigo até o TTL. O **write-behind** confirma a escrita quando ela só existe na memória do cache; se o cache cai antes de descarregar, a escrita confirmada some. Para contador de visualização, aceitável. Para dinheiro, é o caminho mais curto entre a Lastro e o noticiário policial.

### A corrida que regrava o passado

O cache-aside tem uma corrida clássica, e ela acontece em produção, sim:

```text
leitor:   miss na chave tarifa:hornero
leitor:   SELECT tarifa → 0,99%           (lê antes da mudança)
escritor: UPDATE tarifa = 0,79%; COMMIT
escritor: DEL tarifa:hornero               (apaga o que nem existia ainda)
leitor:   SET tarifa:hornero 0,99%         (grava o passado no cache)
```

O escritor fez tudo certo e o cache ficou errado até o TTL. Sem TTL, para sempre. As defesas conhecidas:

- **TTL sempre**, como teto da mentira. Uma chave sem TTL num cache-aside é uma aposta de que nunca vai haver corrida.
- **Valor versionado**: o valor carrega a versão da origem, e a escrita no cache só substitui se a versão for maior (no Redis, um script Lua faz a comparação e o `SET` atomicamente).
- **Leases**: no miss, o cache entrega ao leitor um token; se a chave for apagada antes de o leitor gravar, o token deixa de valer e o `SET` é recusado. O Facebook descreveu esse mecanismo no artigo sobre o memcache em 2013.
- **Apagar depois do COMMIT**, nunca antes. Apagar antes abre uma janela em que outro leitor repõe o valor velho, que ainda é o valor commitado.

## Invalidação, a coisa difícil que tem nome de coisa fácil

A frase atribuída a Phil Karlton diz que só há duas coisas difíceis em computação: invalidação de cache e dar nome às coisas. O Carlos conseguiu errar as duas no mesmo PR, que se chamava `cache_simples`.

As estratégias, em ordem de quanto a origem precisa colaborar:

1. **TTL puro.** Nada é invalidado; tudo expira. Simples, e o atraso máximo é o TTL inteiro. Serve quando o atraso é aceitável pelo requisito.
2. **Invalidação explícita.** Quem escreve na origem apaga a chave. Exige que todo caminho de escrita conheça o cache, inclusive o `psql` do Carlos, que nunca conheceu ninguém.
3. **Invalidação por evento.** A origem publica a mudança (CDC, outbox, `NOTIFY`) e os caches apagam ao receber. Pega todo caminho de escrita, porque sai do banco; o atraso é o do fluxo de eventos, e evento perdido vira valor velho até o TTL.
4. **Chave versionada.** A chave inclui a versão (`tarifa:hornero:v14`). Valor imutável nunca fica velho; o que muda é qual chave se procura. O problema passa a ser descobrir a versão atual, que é uma leitura pequena e quente.

Sistemas sérios combinam uma invalidação com um TTL de segurança, que ninguém planeja usar e todo mundo agradece quando usa.

E o **cache negativo**: guardar "não existe" poupa a origem de chaves inexistentes (o DNS faz isso, capítulo 8) e também guarda o "não existe" de algo criado um segundo depois. O marketplace cadastrado às 10h00 que recebe "marketplace não encontrado" até as 10h05 foi vítima de um TTL negativo de cinco minutos.

## Despejo, ou quem morre quando a memória acaba

O cache tem tamanho fixo; a política de despejo (*eviction*) escolhe a vítima.

- **LRU** (*least recently used*): despeja quem foi acessado há mais tempo. Bom para recência; uma varredura única (um relatório que lê um milhão de chaves uma vez) expulsa as chaves quentes de verdade.
- **LFU** (*least frequently used*): despeja quem é menos acessado. Resiste à varredura; precisa envelhecer os contadores, senão a chave que foi popular em 2023 vive para sempre por mérito histórico.
- **Por TTL**: despeja primeiro quem expira mais cedo.

O Redis implementa LRU e LFU aproximados: sorteia algumas chaves (`maxmemory-samples`, padrão 5) e despeja a pior da amostra; o LFU usa um contador logarítmico de 8 bits com decaimento. O padrão de `maxmemory-policy` é `noeviction`: memória cheia, escrita recusada com erro. Num cache, é um jeito criativo de descobrir que ninguém configurou o despejo; num Redis com dado que não pode sumir, é o comportamento certo. As variantes `allkeys-*` escolhem entre todas as chaves; as `volatile-*`, só entre as que têm TTL.

O `lru_cache` do Carlos tem `maxsize=128` e nenhum TTL: despeja por tamanho, nunca por idade, e com dezenas de marketplaces nunca despejaria nada. A tarifa velha tinha estabilidade de servidor público.

## Cache stampede, ou a manada no portão

Uma chave muito lida expira. Nos milissegundos seguintes, todas as requisições que chegam dão miss ao mesmo tempo e vão à origem ao mesmo tempo, para calcular o mesmo valor. Se o valor custa 2 segundos de banco e chegam 200 requisições por segundo, 400 cálculos idênticos disputam o banco, que fica lento, o que estende o cálculo, o que junta mais requisições. Isso é o *cache stampede* (ou *dogpile*), e ele tem o formato exato da explosão de filas do capítulo 14.

As soluções:

- **Coalescência** (*single-flight*): só um cálculo por chave; os outros esperam o resultado ou recebem o valor velho. Dentro de um processo, um `asyncio.Lock` por chave. Entre processos, um lock no próprio cache (`SET chave:lock 1 NX PX 5000`). Esse lock só evita trabalho duplicado, que é o único uso que o capítulo 2 deixou para lock no Redis: se dois calcularem, o pior que acontece é desperdício.
- **Servir velho enquanto recalcula** (*stale-while-revalidate*): entre o prazo "fresco" e o "aceitável", devolve o velho e recalcula em segundo plano. No HTTP, é a diretiva da RFC 5861.
- **Expiração antecipada probabilística**: cada leitor decide, com probabilidade que cresce perto do vencimento, recalcular antes da hora. O algoritmo XFetch (Vattani, Chierichetti e Lowenstein, VLDB 2015) faz isso sem coordenação nenhuma.
- **Jitter no TTL**: TTL de 30 s ± 20% para que mil chaves criadas juntas não expirem juntas. É o full jitter do capítulo 15, aplicado à data de morte.

## Camadas, e por que o atraso soma

| Camada | Latência típica | Compartilhado entre | Invalidação | Custo escondido |
|--------|-----------------|---------------------|-------------|-----------------|
| Memória do processo | ~100 ns | um processo | só local; cada processo é uma ilha | N cópias, N misses, N versões da verdade |
| Cache distribuído (Redis/Valkey) | ~0,2–0,5 ms (1 RTT na rede local) | todos os processos | `DEL` atinge todos | mais uma peça para operar e falhar |
| Cache HTTP no cliente ou proxy (capítulo 9) | 0 a 1 RTT | depende de `private`/`public` | por TTL ou validação condicional | dado privado em cache compartilhado |
| CDN | 1 RTT até a borda | todos os usuários de uma região | purga por API, segundos a minutos | servir uma página de um usuário para outro |

As camadas empilham as mentiras. Um valor com TTL de 60 s no Redis, lido por um processo que guarda 60 s em memória e entrega com `max-age=60` para uma CDN, pode chegar ao usuário com até 3 minutos de atraso, e cada camada jura que respeitou o próprio TTL. Todas respeitaram. Ninguém respeitou o usuário.

## O que a Lastro põe em cache

O critério vem do capítulo 19: cada leitura recebe a garantia de que precisa, e o cache só pode servir leituras que aceitam atraso. A tabela de decisões:

| Dado | Leitura | Mudança | Decisão |
|------|---------|---------|---------|
| Tarifas e configuração de split | 11 por cobrança, ~2.200/s no pico | ~1 vez por trimestre por marketplace | Memória do processo, com vigência |
| Resumo do dia no painel (GraphQL) | 40 abas por marketplace, refresh 15 s | contínua | Redis, TTL 30 s, coalescência |
| `GET /v1/moedas`, JS do checkout | todo mundo | quase nunca | HTTP e CDN |
| Cobrança na API, chave de idempotência | linearizável (capítulo 19) | toda hora | Sem cache |
| Saldo do saque | linearizável | a cada lançamento | Nunca |

**Tarifas e split: vigência em vez de invalidação.** A tarifa do Hornero falhou porque tinha efeito imediato. Agora toda tarifa e configuração de split tem `vigente_desde` e é imutável (versão nova em vez de `UPDATE`); a vigência começa na próxima hora cheia, com pelo menos 10 minutos de antecedência. Cada processo guarda todas as vigências (dezenas de linhas, menos de 1 MB), com TTL de 60 s ± 20%, e escolhe a vigente pelo `now()` da transação no banco, nunca pelo relógio da máquina (capítulo 20). Com TTL de 60 s e 10 minutos de antecedência, toda versão chega a todos os processos antes de valer. O cache pode estar atrasado; o resultado nunca está errado.

Para correção urgente (vírgula no lugar errado), a gravação dispara `NOTIFY config_tarifas`, e a conexão `LISTEN` que cada processo mantém desde o capítulo 12 apaga o cache local; notificação perdida cai no TTL. A versão aplicada vai para a cobrança, e a conciliação confere. Redis aqui custaria um salto de rede de 0,3 ms em cada uma das onze leituras para guardar menos de 1 MB.

**Painel: aqui entra o Redis.** O resumo de vendas do dia custa ~15 ms de CPU e ~40 ms de banco, e um marketplace grande tem 40 abas abertas. Em memória de processo, seriam nove misses por marketplace a cada expiração; um Redis (ou Valkey) gerenciado, compartilhado, faz uma conta por marketplace a cada 30 s. Cache-aside, chave `painel:resumo:{marketplace}:{dia}`, TTL 30 s ± 20%, coalescência com `SET NX PX`, valor velho servido enquanto recalcula, e a tela mostra "atualizado às 14h32min10s". `allkeys-lru` com `maxmemory` fixo, porque tudo ali pode sumir. Com o Redis fora do ar, cada processo calcula com coalescência local: no máximo nove cálculos por marketplace a cada 30 s, conta feita antes de o Redis entrar.

**HTTP e CDN:** `GET /v1/moedas` segue com `public, max-age=86400` (capítulo 9). O JavaScript do checkout vai para uma CDN (o Amazon CloudFront e o Cloudflare são exemplos) com o hash do conteúdo no nome do arquivo e `Cache-Control: public, max-age=31536000, immutable`: versão nova é arquivo novo, e invalidação deixa de existir. Resposta com dado de cobrança continua `private`.

**O saldo do saque fica fora.** O write-through do Carlos é escrita dupla (capítulo 18): processo morto entre o COMMIT e o `SET` deixa o Redis com saldo antigo. O Redis replica de forma assíncrona, e um failover pode perder a última atualização confirmada. E, com tudo certo, a leitura no Redis continua sem o lock da conta e sem o snapshot da transação de débito (capítulos 2 e 3). A única fonte linearizável do saldo é o `SUM` sob lock, no primário. O painel já tem a sua cópia eventual, `saldos_painel` (capítulo 19), um cache com invalidação embutida; Redis na frente dela empilharia atraso para economizar 1 ms numa leitura de 1 ms.

Outra escolha seria a certa se as tarifas mudassem várias vezes por dia (invalidação por evento via broker) ou se o painel tivesse milhares de marketplaces pouco acessados, com acerto baixo demais para pagar o Redis.

## Armadilhas e casos reais

> **Armadilha:** cache que vira dependência de capacidade sem ninguém perceber. O banco foi dimensionado com 99% de acerto, o cache reinicia vazio, e a primeira hora é de 0%. Todo cache precisa de uma resposta escrita para "e se ele acordar vazio no pico".

> **Na vida real:** em 23 de setembro de 2010, o Facebook ficou fora do ar por cerca de duas horas e meia. Um sistema automático trocava valores de configuração inválidos no cache pelo valor do banco; uma mudança no valor do banco foi interpretada como inválida, e todos os clientes foram ao banco ao mesmo tempo para "corrigir". Os erros do banco sobrecarregado também eram lidos como valor inválido, e o ciclo só parou com o site desligado. Um stampede com autocorreção, que corrigiu o site até ele sumir.

> **Na vida real:** no Natal de 2015, uma mudança na configuração de cache da Steam durante um ataque de negação de serviço fez páginas personalizadas serem guardadas e servidas para outros usuários. A Valve informou que dados de cerca de 34 mil usuários foram expostos. Resposta privada em cache compartilhado é o vazamento mais barato de produzir.

E a da própria Lastro: um cache sem TTL é um banco de dados sem backup que discorda do banco de verdade.

## Resumo

- Cache é cópia sem replicação: eventual, atraso limitado pelo TTL.
- Carga na origem = (1 − h) × leituras.
- Cache-aside, read-through, write-through (escrita dupla), write-behind (perde escrita).
- Corrida do cache-aside: TTL, valor versionado, leases, apagar após o COMMIT.
- Invalidação: TTL, explícita, por evento, chave versionada; cache negativo.
- Despejo LRU, LFU, por TTL; Redis aproximado por amostragem, padrão `noeviction`.
- Stampede: coalescência, stale-while-revalidate, expiração probabilística, jitter.
- Camadas somam atraso.

## A Lastro agora

Tarifas e split viraram versões imutáveis com vigência, cacheadas em cada processo (TTL 60 s, `NOTIFY` para urgência); o primário deixou de receber ~2.200 consultas por segundo no pico. Um Redis gerenciado entrou para o resumo do painel, o JavaScript do checkout foi para uma CDN, e o saldo do saque continua no primário, sob lock. O financeiro devolveu as 6.100 diferenças do Hornero e pediu que a palavra "sorteio" fosse banida do canal de incidentes.

O Carlos abriu outro PR: os relatórios mensais dos marketplaces, que rodam no primário e levam 40 segundos cada, disputando I/O com os lançamentos no dia 1º às 9h. A proposta dele é "cachear o relatório por 30 dias". O relatório é gerado uma vez por mês. A taxa de acerto prevista é zero, e o PR já tem dois aprovadores.

## Referências

- Nishtala et al., "Scaling Memcache at Facebook", NSDI 2013: https://www.usenix.org/conference/nsdi13/technical-sessions/presentation/nishtala
- Vattani, Chierichetti, Lowenstein, "Optimal Probabilistic Cache Stampede Prevention", VLDB 2015: https://www.vldb.org/pvldb/vol8/p886-vattani.pdf
- RFC 5861, HTTP Cache-Control Extensions for Stale Content: https://www.rfc-editor.org/rfc/rfc5861
- RFC 9111, HTTP Caching: https://www.rfc-editor.org/rfc/rfc9111
- Redis, "Key eviction": https://redis.io/docs/latest/develop/reference/eviction/
- Python, `functools.lru_cache`: https://docs.python.org/3/library/functools.html#functools.lru_cache
- Robert Johnson, "More Details on Today's Outage", Facebook Engineering, 23 set. 2010.
- Valve, comunicado sobre o incidente de cache da Steam em 25 dez. 2015.
