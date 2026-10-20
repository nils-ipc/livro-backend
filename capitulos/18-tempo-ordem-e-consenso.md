# Tempo, ordem e consenso

## O lance que chegou depois e ganhou mesmo assim

O leilão da bicicleta ergométrica usada (anúncio: "pouco uso, serviu de cabide por três anos") terminava às 21:00:00. A situação é hipotética: dois servidores, `leilao-a` e `leilao-b`, carimbavam cada lance com o relógio local. Ganhava o maior lance anterior a 21:00:00.

Marta deu R$ 310 às 20:59:59,900 do tempo real, no `leilao-a`, de relógio certo. Jorge viu o lance dela, suspirou e deu R$ 320 às 21:00:00,150, depois do fechamento, no `leilao-b`, cujo relógio estava 400 ms atrasado. Carimbo do lance de Jorge: 20:59:59,750.

Jorge levou a bicicleta. O log:

```text
20:59:59.750  leilao-b  lance  jorge  R$ 320
20:59:59.900  leilao-a  lance  marta  R$ 310
```

Segundo o log, Jorge cobriu um lance que ainda não existia. Ou ele lê pensamentos, ou o `leilao-b` vive no passado. A segunda hipótese tem mais respaldo técnico. O suporte respondeu à reclamação de Marta com "vamos verificar os horários", o que tem graça, porque o problema todo eram os horários. A pergunta que este capítulo responde é: quando nenhum relógio merece confiança total, como várias máquinas concordam sobre o que aconteceu primeiro, e sobre quem manda?

## Relógios físicos, ou quartzo com opinião própria

O **relógio de parede** (*wall clock*) diz que horas são: segundos desde 1970 em UTC, o `time.time()` do Python, o `CLOCK_REALTIME` do Linux. Ele pode andar para trás, por um salto do NTP ou um `date -s` de administrador.

O **relógio monotônico** (`time.monotonic()`, `CLOCK_MONOTONIC`) só avança. O valor absoluto é arbitrário (costuma contar desde o boot) e serve para medir intervalos: timeouts, durações, expiração de lease. Comparar o monotônico de duas máquinas tem o mesmo valor científico que comparar a idade dos dois servidores em dias.

### Por que relógios divergem

O relógio vem de um cristal de quartzo, e cada cristal oscila numa frequência ligeiramente diferente da nominal, que ainda varia com a temperatura. O erro se mede em partes por milhão (ppm):

```text
1 ppm   = 1 µs por segundo = 86,4 ms por dia
50 ppm  = 4,32 s por dia
200 ppm = 17,3 s por dia
```

Servidores comuns ficam nas dezenas de ppm. Sem correção, dois servidores saídos da mesma caixa divergem segundos por semana, e cada um jura que o outro é que está errado. A taxa se chama *drift* (deriva); a diferença acumulada entre dois relógios é o *offset* (desvio).

### NTP em quatro carimbos

O NTP (versão 4, RFC 5905) corrige o relógio perguntando a hora a servidores mais confiáveis, organizados em *stratum*: 0 é a fonte física (GPS, relógio atômico), 1 é o servidor ligado a ela, 2 consulta o 1, e assim por diante, até o `temp-01` no stratum 4 que todo mundo usa e ninguém configurou. Uma ida e volta registra quatro carimbos:

```text
t1 = cliente envia      (relógio do cliente)
t2 = servidor recebe    (relógio do servidor)
t3 = servidor responde  (relógio do servidor)
t4 = cliente recebe     (relógio do cliente)

atraso δ = (t4 − t1) − (t3 − t2)
desvio θ = ((t2 − t1) + (t3 − t4)) / 2
```

O desvio supõe que ida e volta levaram o mesmo tempo. Com ida de 5 ms e volta de 25 ms, o erro chega a metade da diferença, 10 ms, e o NTP não tem como detectar isso. Ele confia na simetria com a fé de quem confia no "deploy rápido de sexta".

No **slew**, o relógio acelera ou desacelera levemente (o ntpd limita a 500 ppm) até zerar a diferença, sem andar para trás. No **step**, salta direto para a hora certa, inclusive para trás; o ntpd faz isso acima de 128 ms. Numa rede local, o NTP mantém servidores a menos de um milissegundo entre si; pela internet, a dezenas de milissegundos. Quem precisa de microssegundos usa PTP (IEEE 1588).

### O segundo que dura dois segundos

Para acompanhar a rotação irregular da Terra, o UTC às vezes ganha um **segundo bissexto** (*leap second*), 23:59:60, que o tempo Unix não representa; o kernel repete o último segundo. Quem calcula `fim − início` com relógio de parede recebe uma duração negativa, o tipo de valor que nenhuma biblioteca esperava receber num feriado.

O Google adotou o *leap smear*: o segundo extra se espalha por 24 horas (cerca de 11,6 ppm), sem relógio andando para trás, ao custo de até meio segundo fora do UTC oficial. A Conferência Geral de Pesos e Medidas decidiu em 2022 abolir os segundos bissextos até 2035; o último foi inserido no fim de 2016.

## Relógio com margem de erro

Se o relógio erra, uma saída é admitir o erro em voz alta. O **TrueTime**, do Spanner, devolve um intervalo `[mais_cedo, mais_tarde]` que contém a hora real; com GPS e relógios atômicos, a incerteza ε ficava entre 1 e 7 ms no artigo de 2012.

O Spanner obtém *external consistency* (serializabilidade estrita, capítulo 17) pelo **commit wait**: escolhe o carimbo `s = TT.now().mais_tarde` e espera, de propósito, até `TT.now().mais_cedo > s` antes de responder. Aí todo relógio do planeta já passou de `s`, ao preço de dormir cerca de 2ε por escrita.

Sem relógio atômico no orçamento, há o **relógio lógico híbrido** (HLC, 2014): o maior relógio de parede visto mais um contador de desempate. O CockroachDB usa HLC com desvio máximo entre nós (500 ms por padrão), e o nó que passa do limite se encerra sozinho, num raro caso de software que pede demissão.

## Ordem sem relógio: Lamport

Em 1978, Leslie Lamport trocou a pergunta "que horas aconteceu?" por "o que pode ter influenciado o quê?".

A relação **aconteceu antes** (→): `a → b` se a vem antes de b no mesmo processo; ou se a é o envio de uma mensagem e b o recebimento; ou, por transitividade, se `a → c` e `c → b`. Se nenhum dos dois aconteceu antes do outro, são **concorrentes**. No leilão, o lance de Marta → a tela de Jorge mostrá-lo → o lance de Jorge. O carimbo de parede inverteu uma relação causal, e foi isso que fez o log parecer obra de vidente.

O **relógio de Lamport** é um contador inteiro por processo, com três regras:

1. Antes de cada evento local, incrementa o contador.
2. Ao enviar uma mensagem, incrementa e anexa o valor.
3. Ao receber uma mensagem com carimbo `m`, faz `c = max(c, m) + 1`.

A garantia: se `a → b`, então `C(a) < C(b)`. A recíproca é falsa: os eventos podem ser concorrentes e um processo só estava mais movimentado. Ordenando por `(contador, id_do_processo)`, sai uma ordem total, arbitrária entre concorrentes, mas igual em todos os nós, e muitas vezes concordar já basta.

## Vector clocks, ou quem sabia o quê

Para detectar concorrência, o **vector clock** (Fidge e Mattern, 1988, de forma independente) guarda um contador por processo: no processo i, `V[j]` é quantos eventos de j ele conhece.

1. Evento local: `V[i] += 1`.
2. Envio: incrementa e anexa o vetor inteiro.
3. Recebimento de `W`: `V[j] = max(V[j], W[j])` para todo j, depois `V[i] += 1`.

`V ≤ W` se todo componente de V for menor ou igual ao de W, e `a → b` se e somente se `V(a) ≤ V(b)` com vetores diferentes. Se nenhum for menor ou igual ao outro, os eventos são concorrentes, e você sabe disso com certeza, em vez de descobrir pela reclamação da Marta.

O Dynamo, da Amazon (2007), versionava valores assim e devolvia versões concorrentes para a aplicação unir (no carrinho, um item removido às vezes ressuscitava). O custo é um contador por participante.

## Consenso, ou como cinco máquinas concordam sem confiar em nenhuma

O **consenso** pede que processos, alguns dos quais podem falhar, escolham um único valor com **acordo** (todos que decidem, decidem o mesmo), **validade** (o valor foi proposto por alguém) e **terminação** (todo processo vivo acaba decidindo).

O resultado FLP (1985) provou que, sem limite para atraso de mensagem, nenhum algoritmo determinístico garante consenso se um processo puder parar: lento e morto são indistinguíveis. Os algoritmos práticos nunca violam o acordo e só decidem quando a rede colabora. É o comitê que nunca aprova nada errado porque, durante a crise, não aprova nada.

O instrumento é o **quórum de maioria**: com N = 2f + 1 nós, cada decisão exige f + 1 votos, e duas maiorias quaisquer têm um nó em comum, que carrega a decisão anterior para a próxima.

| Nós | Maioria | Falhas toleradas |
|-----|---------|------------------|
| 1 | 1 | 0 |
| 3 | 2 | 1 |
| 4 | 3 | 1 |
| 5 | 3 | 2 |
| 7 | 4 | 3 |

O quarto nó paga servidor, aumenta a maioria e tolera as mesmas falhas que três: o colega contratado para ajudar que precisa ser consultado em toda decisão.

O Paxos, de Lamport, saiu em 1998 como a história de um parlamento grego fictício, o que não ajudou ninguém a entender. O Raft (2014) foi projetado para ser compreensível e roda no etcd (e, portanto, no Kubernetes), no Consul e no modo KRaft do Kafka.

## Raft no que importa

O Raft decide um **log replicado**: comandos aplicados na mesma ordem por todos os nós. Cada nó é *follower*, *candidate* ou *leader*.

### Eleição

O tempo se divide em **termos** (*terms*) crescentes, cada um com no máximo um líder. Um nó que vê um termo maior que o seu adota esse termo e volta a ser follower na hora, sem discussão; mensagens de termos menores são rejeitadas.

O líder envia *heartbeats*. Um follower que passa um **election timeout** sem notícias incrementa o termo, vota em si mesmo e pede votos com `RequestVote`; cada nó vota uma vez por termo, e a maioria elege. O timeout é sorteado (150 a 300 ms no artigo) para os followers não se candidatarem juntos e dividirem os votos para sempre. No etcd, os padrões são heartbeat de 100 ms e election timeout de 1.000 ms.

A segurança vem de uma restrição: só se vota em candidato cujo log esteja pelo menos tão atualizado quanto o do eleitor (termo da última entrada, depois índice). Uma entrada confirmada está numa maioria, o candidato precisa de uma maioria, e o eleitor em comum recusa quem não a tem.

```text
nó-1 (líder, termo 7):  ... silêncio (GC de 2 s) ...
nó-3: 1.000 ms sem heartbeat. Termo 8. Voto em mim. RequestVote!
nó-2: Seu log está em dia. Voto em você no termo 8.
nó-3: Maioria. Sou o líder do termo 8.
nó-1: (acorda) AppendEntries, termo 7!
nó-2: Estamos no termo 8.
nó-1: Ah. (vira follower, sem ressentimento registrado no log)
```

### Replicação e confirmação

O líder anexa o comando ao log e envia `AppendEntries` com a entrada e o par (índice, termo) da anterior. O follower só aceita se tiver esse mesmo par; senão recusa, e o líder recua até o ponto em comum e sobrescreve o resto. Daí a **propriedade de correspondência do log**: dois logs com uma entrada de mesmo índice e termo são idênticos até ali.

A entrada está **confirmada** (*committed*) quando gravada numa maioria; só então o líder aplica e responde. Custo mínimo por escrita: um RTT até a maioria mais próxima mais um `fsync` em cada nó dela. Detalhe sutil: o líder só conta réplicas de entradas do próprio termo; as antigas são confirmadas junto com elas (a figura 8 do artigo mostra uma entrada "confirmada" sendo apagada quando a regra é ignorada).

Numa partição, o líder antigo, no lado minoritário, aceita comandos e nunca confirma nenhum; os clientes recebem timeout. O lado majoritário elege outro líder num termo maior, e quando a rede volta o antigo desce e tem as entradas pendentes sobrescritas.

### Leituras

Um líder isolado não sabe que foi deposto e pode servir dados velhos, com toda a convicção. No **ReadIndex**, ele confirma a liderança com uma rodada de heartbeats à maioria antes de responder: um RTT por leitura ou lote. Na **leitura com lease**, ele responde sem rodada extra enquanto teve resposta da maioria há menos de um election timeout. Essa segunda opção exige relógios que andem em ritmos parecidos (drift limitado); tolera horas diferentes, mas não relógios que pulam.

## Leases e fencing tokens

Um **lease** é um lock com prazo: "você é o dono por 10 segundos, renove antes disso". Se o dono morre, o lease vence sozinho, sem ninguém precisar declarar óbito. etcd, ZooKeeper e Consul emitem leases apoiados em consenso; o capítulo 5 mostra a versão com Redis e seus limites.

Entre consultar o relógio e agir, o mundo pode parar: pausa de *garbage collector*, VM migrada a quente, `SIGSTOP`. O processo checa "meu lease vale mais 2 s", pausa 15 s e acorda convencido de que ainda está nos 2 s. Para ele, nenhum tempo passou; para o cluster, ele foi substituído, e o substituto já gravou.

Checar no cliente não resolve, porque a pausa pode cair entre a checagem e a escrita. A defesa fica no recurso: o **fencing token**, número crescente entregue com cada lease (a *revision* no etcd, o `zxid` no ZooKeeper, o termo no Raft), que o armazenamento compara, rejeitando tokens menores que o maior já visto.

O armazenamento precisa participar. Um banco faz isso com `UPDATE ... WHERE token <= :token`; uma API de terceiros que só recebe `POST /enviar-sms` não tem onde checar nada, e resta a idempotência (capítulo 20). O STONITH do capítulo 13 é a mesma ideia levada ao extremo: em vez de recusar o token velho, desliga a máquina velha.

## Na prática

A conta do NTP para o `leilao-b`, com os carimbos de uma troca real de mensagens:

```python
def ntp(t1: float, t2: float, t3: float, t4: float) -> tuple[float, float]:
    atraso = (t4 - t1) - (t3 - t2)
    desvio = ((t2 - t1) + (t3 - t4)) / 2
    return atraso, desvio

# t1 e t4 no relógio do leilao-b; t2 e t3 no relógio do servidor NTP
atraso, desvio = ntp(t1=10.000, t2=10.410, t3=10.411, t4=10.021)
print(f"atraso de ida e volta:   {atraso * 1000:.0f} ms")
print(f"desvio do relógio local: {desvio * 1000:+.0f} ms")
```

```text
atraso de ida e volta:   20 ms
desvio do relógio local: +400 ms
```

O relógio local precisa avançar 400 ms: o `leilao-b` estava exatamente tão atrasado quanto Jorge precisava. Um servidor saudável sob chrony mostra:

```bash
chronyc tracking
```

```text
Reference ID    : 0A000002 (10.0.0.2)
Stratum         : 4
Ref time (UTC)  : Mon Oct 19 21:00:03 2026
System time     : 0.000021394 seconds slow of NTP time
Last offset     : -0.000004127 seconds
RMS offset      : 0.000018530 seconds
Frequency       : 11.204 ppm slow
Residual freq   : -0.001 ppm
Skew            : 0.021 ppm
Root delay      : 0.000482160 seconds
Root dispersion : 0.000391204 seconds
Update interval : 16.1 seconds
Leap status     : Normal
```

`System time` é o desvio atual; `Frequency`, a deriva compensada (11,2 ppm, quase um segundo por dia). Um alerta sobre `System time` acima de alguns milissegundos teria salvo a bicicleta da Marta. Agora o relógio de Lamport no mesmo leilão:

```python
from dataclasses import dataclass

@dataclass
class Lamport:
    no: str
    c: int = 0

    def evento(self) -> int:
        self.c += 1
        return self.c

    def enviar(self) -> int:
        return self.evento()

    def receber(self, carimbo: int) -> int:
        self.c = max(self.c, carimbo) + 1
        return self.c

a, b = Lamport("leilao-a"), Lamport("leilao-b")
a.evento(); a.evento(); a.evento()   # leilao-a está movimentado
msg = a.enviar()                     # lance de Marta vai para a tela de Jorge
b.evento()                           # leilao-b, tranquilo, mostrando um anúncio de sofá
print("lance de Marta:", msg)
print("Jorge vê o lance:", b.receber(msg))
print("lance de Jorge:", b.evento())
```

```text
lance de Marta: 4
Jorge vê o lance: 5
lance de Jorge: 6
```

O contador do `leilao-b` saltou de 1 para 5 ao receber a mensagem, e a ordem causal ficou preservada sem consultar relógio nenhum. Para detectar concorrência, o vector clock:

```python
def comparar(v: dict[str, int], w: dict[str, int]) -> str:
    nos = v.keys() | w.keys()
    v_menor = all(v.get(n, 0) <= w.get(n, 0) for n in nos)
    w_menor = all(w.get(n, 0) <= v.get(n, 0) for n in nos)
    if v_menor and w_menor:
        return "iguais"
    if v_menor:
        return "v aconteceu antes de w"
    if w_menor:
        return "w aconteceu antes de v"
    return "concorrentes: ninguém sabia do outro"

print(comparar({"a": 2, "b": 0}, {"a": 2, "b": 1}))
print(comparar({"a": 3, "b": 0}, {"a": 2, "b": 1}))
```

```text
v aconteceu antes de w
concorrentes: ninguém sabia do outro
```

No segundo caso, cada lado tem um evento que o outro desconhece, e quem decide é a aplicação ou um CRDT. Por fim, o fencing token, com o worker que declara o vencedor segurando um lease de 10 s:

```python
class Armazenamento:
    def __init__(self) -> None:
        self.maior_token = 0
        self.dados: dict[str, str] = {}

    def gravar(self, chave: str, valor: str, token: int) -> None:
        if token < self.maior_token:
            raise PermissionError(f"token {token} vencido; o atual é {self.maior_token}")
        self.maior_token = token
        self.dados[chave] = valor
        print(f"gravado {chave}={valor!r} com token {token}")

disco = Armazenamento()
disco.gravar("vencedor", "Marta", token=33)  # worker-1, lease válido
# worker-1 entra numa pausa de GC de 15 s; o lease de 10 s vence
disco.gravar("vencedor", "Jorge", token=34)  # worker-2 recebe o lease
disco.gravar("vencedor", "Marta", token=33)  # worker-1 acorda, cheio de confiança
```

```text
gravado vencedor='Marta' com token 33
gravado vencedor='Jorge' com token 34
Traceback (most recent call last):
  ...
PermissionError: token 33 vencido; o atual é 34
```

Sem a checagem, o vencedor dependeria de qual worker teve a pausa de GC mais longa, critério que nenhum edital de leilão prevê.

## Propriedades e custos

| Mecanismo | O que garante | Custo |
|-----------|---------------|-------|
| Relógio de parede + NTP | Hora com erro de sub-ms (LAN) a dezenas de ms | Pode voltar; sem garantia de ordem |
| Relógio monotônico | Intervalos na mesma máquina | Inútil entre máquinas |
| TrueTime + commit wait | Ordem coerente com o tempo real | GPS e relógio atômico; ~2ε por escrita |
| HLC | Carimbo quase físico e causal | Exige desvio máximo limitado |
| Lamport | a → b implica C(a) < C(b) | 1 inteiro; não detecta concorrência |
| Vector clock | Causalidade e concorrência exatas | N inteiros por mensagem |
| Raft | Acordo com f falhas em 2f+1 nós | RTT à maioria + fsync; escrita só no líder; para sem maioria |
| Lease | Dono único com drift limitado | Troca de dono espera o vencimento |
| Fencing token | Rejeita donos antigos | Recurso precisa comparar o token |

Carimbo de parede falha sempre que o desvio entre relógios supera o intervalo entre eventos (400 ms do `leilao-b` contra 250 ms entre os lances). O consenso cobra a distância do líder à maioria em cada escrita: com regiões a 30 ms, cada confirmação leva pelo menos 30 ms, e por isso ele guarda pouca coisa (configuração, liderança, metadados). Ninguém põe o log de cliques num cluster que vota cada clique.

## Armadilhas e casos reais

> **Armadilha:** medir duração com `time.time()`. Um step do NTP produz durações negativas e timeouts que disparam na hora ou nunca. Intervalos pedem `time.monotonic()` ou `time.perf_counter()`.

> **Armadilha:** *last write wins* com o relógio de parede de cada nó. O nó adiantado vence todas as disputas, e escritas posteriores feitas no nó atrasado somem em silêncio. O `leilao-b` faria carreira nesse sistema.

> **Armadilha:** três nós em duas zonas (dois numa, um na outra) perdem a maioria quando a zona dos dois cai. E election timeout menor que as pausas de GC faz o cluster passar mais tempo votando do que trabalhando.

> **Na vida real:** no segundo bissexto de 30/06/2012, um bug de timers do kernel Linux pôs processos com futex a 100% de CPU, com Reddit e Mozilla entre os afetados. O paliativo que circulou foi `date -s "$(date)"`, que reinicializava os timers.

> **Na vida real:** no segundo bissexto de 31/12/2016, o relógio andou para trás num servidor DNS da Cloudflare escrito em Go. Uma duração negativa chegou a `rand.Int63n`, que entra em pânico com argumento não positivo, e parte das resoluções de CNAME falhou na virada do ano. A correção usou relógio monotônico, que o Go 1.9 passou a embutir em `time.Time`.

> **Na vida real:** em 02/11/2020, a falha parcial de um switch na Cloudflare fez nós de um cluster etcd enxergarem uns aos outros só em parte. O cluster trocou de líder repetidamente e o gerenciador dos bancos do plano de controle disparou um failover: falha parcial de rede é o pior caso para algoritmos que supõem que um nó ou responde ou está morto.

## Resumo

- Relógio de parede pode voltar; monotônico mede intervalos dentro da máquina.
- Cristais derivam dezenas de ppm; NTP corrige com slew ou step e supõe rede simétrica.
- TrueTime paga commit wait pela incerteza; HLC soma tempo físico e contador.
- Lamport: a → b implica C(a) < C(b). Vector clock também detecta concorrência.
- Consenso: 2f+1 nós toleram f falhas; FLP impede terminação garantida.
- Raft: termos, timeout sorteado, voto só para log atualizado, confirmação por maioria.
- Lease precisa de fencing token checado pelo recurso.

## Referências

- Leslie Lamport. "Time, Clocks, and the Ordering of Events in a Distributed System". Communications of the ACM, 1978. <https://lamport.azurewebsites.net/pubs/time-clocks.pdf>
- RFC 5905: Network Time Protocol Version 4. <https://www.rfc-editor.org/rfc/rfc5905>
- Diego Ongaro e John Ousterhout. "In Search of an Understandable Consensus Algorithm". USENIX ATC 2014. <https://raft.github.io/raft.pdf>
- Fischer, Lynch e Paterson. "Impossibility of Distributed Consensus with One Faulty Process". Journal of the ACM, 1985. <https://groups.csail.mit.edu/tds/papers/Lynch/jacm85.pdf>
- Corbett et al. "Spanner: Google's Globally-Distributed Database". OSDI 2012. <https://www.usenix.org/conference/osdi12/technical-sessions/presentation/corbett>
- DeCandia et al. "Dynamo: Amazon's Highly Available Key-value Store". SOSP 2007. <https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf>
- Google Public NTP, leap smear. <https://developers.google.com/time/smear>
- Documentação do etcd, ajuste de heartbeat e election timeout. <https://etcd.io/docs/v3.5/tuning/>
- Martin Kleppmann. "How to do distributed locking", 2016. <https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html>
- Cloudflare. "How and why the leap second affected Cloudflare DNS". <https://blog.cloudflare.com/how-and-why-the-leap-second-affected-cloudflare-dns/>
- Cloudflare. "A Byzantine failure in the real world". <https://blog.cloudflare.com/a-byzantine-failure-in-the-real-world/>
