# Modelos de consistência

## A resposta que chegou antes da pergunta

Às 7h12 de uma segunda-feira, o grupo de moradores de um aplicativo de condomínio (um sistema hipotético, com moradores hipotéticos e um cachorro hipotético chamado Paçoca) exibiu, para metade do prédio, a seguinte conversa:

```text
Apto 1204:  Achei! Está aqui comigo, muito dócil, comeu meu chinelo.
Apto 302:   Alguém viu um cachorro caramelo? Fugiu agora, atende por Paçoca.
```

A resposta veio antes da pergunta. Durante quarenta segundos, o prédio inteiro discutiu se o morador do 1204 tinha poderes premonitórios ou se tinha sequestrado o Paçoca de propósito.

Na mesma manhã, o contador de reações da mensagem oscilou de 14 para 9 e voltou para 14 em três recarregamentos da tela. E o morador do 507 tirou o síndico do subgrupo "Reclamações do salão de festas", postou a reclamação sobre o síndico e descobriu que o síndico leu a reclamação. Foi o incidente mais grave do dia, sem nenhum servidor caído.

O banco replica os dados entre três servidores, e cada leitura vai para qualquer um deles. Nenhum byte se perdeu, nenhum log registrou erro. O banco estava quebrado ou cumprindo exatamente o que prometeu? E qual promessa o aplicativo deveria ter exigido, e quanto ela custa?

## Um modelo de consistência é um contrato sobre histórias

Um **modelo de consistência** é o conjunto de resultados que um sistema tem permissão de devolver quando várias operações acontecem ao mesmo tempo. Ele descreve o comportamento visível pelos clientes, e o mesmo banco pode oferecer modelos diferentes conforme a configuração (o que explica boa parte das brigas em postmortems).

Cada operação tem uma **invocação** (a chamada) e uma **resposta** (o resultado). A lista de invocações e respostas de todos os clientes é uma **história**. Operações cujos intervalos se sobrepõem são **concorrentes**; quando uma termina antes de a outra começar, há uma ordem de **tempo real** entre elas. O objeto mais simples é um **registrador**: uma chave com `write(x)` e `read()`. Quanto mais histórias desse registrador o modelo proíbe, mais forte ele é, e mais coordenação os servidores precisam fazer. Coordenação custa mensagens de rede, mensagens de rede custam milissegundos, e milissegundos custam a paciência de quem está procurando o Paçoca.

## Linearizabilidade, a ilusão de uma cópia só

A **linearizabilidade** (Herlihy e Wing, 1990) é o modelo mais forte para um objeto único: cada operação parece acontecer de forma atômica em algum instante entre a invocação e a resposta, e a ordem resultante respeita o tempo real.

Para quem observa de fora, existe uma única cópia dos dados. E uma regra pega muita implementação: depois que **qualquer** cliente leu o valor novo, nenhum outro cliente pode ler o antigo, mesmo que a escrita ainda esteja em andamento.

```text
tempo (ms)    0    2    4    6    8    10
A  write(1)   |=========================|
B  read() 1        |====|
C  read() 0                  |====|
```

Essa história é proibida. A escrita de A ainda está em andamento quando B lê, então B pode ver 0 ou 1. B viu 1. A partir daí o valor 1 "aconteceu", e C, que começa depois de B terminar, perdeu o direito de ver 0. Uma réplica atualizada e outra atrasada produzem essa história sem esforço nenhum: B leu da rápida, C leu da lenta.

A linearizabilidade é **local** (ou composicional): se cada objeto é linearizável, o sistema inteiro é. Dá para raciocinar chave por chave, um luxo que os outros modelos fortes não oferecem.

Num sistema replicado, isso exige acordo. Ou um líder confirma com a maioria, a cada leitura, que ainda é o líder (o *ReadIndex* do Raft), ou o líder recebe um *lease* de tempo e confia no relógio para não existirem dois líderes. Consenso, leases e por que relógios mentem ficam no capítulo 18.

> **Armadilha:** quórum com `W + R > N` (capítulo 13) garante que a leitura encontra uma réplica com a escrita mais recente, e só. Com a escrita em andamento, um leitor pega o valor novo e o seguinte pega o antigo, exatamente a história do diagrama. O quórum cumpriu a matemática dele; quem prometeu linearizabilidade foi o slide.

## Consistência sequencial, ou o tempo real sai da sala

A **consistência sequencial** (Lamport, 1979) mantém uma ordem total de todas as operações, igual para todos e fiel à sequência de cada cliente (a ordem do programa), e dispensa o tempo real entre clientes diferentes.

Na história do diagrama, a ordem `C:read 0`, `A:write 1`, `B:read 1` é válida sob consistência sequencial: cada cliente fez uma operação só, não há ordem de programa para violar, e C pode "ter acontecido antes" mesmo tendo começado depois. O sistema pode viver no passado, desde que seja o mesmo passado para todo mundo. Em troca, a consistência sequencial perde a composição: dois objetos sequencialmente consistentes, usados juntos, podem produzir uma história que nenhuma ordem total explica.

> **Na vida real:** no ZooKeeper, as escritas são linearizáveis e as leituras vêm do servidor ao qual o cliente está conectado, possivelmente atrasado. Quem precisa do valor mais recente chama `sync()` antes de ler.

Serializabilidade é outra família: trata de **transações** sobre vários objetos, sem exigir tempo real (capítulo 10). Um banco serializable pode servir uma transação somente leitura com o snapshot de ontem e continuar serializable. Somar as duas exigências dá a **serializabilidade estrita**, que o Spanner do Google chama de *external consistency* e paga esperando a incerteza do relógio antes de cada commit (capítulo 18).

## Consistência causal, a ordem que importa

A **consistência causal** usa a relação *aconteceu antes* de Lamport: a operação B depende causalmente de A se o mesmo cliente fez A e depois B, se B leu um valor escrito por A, ou se existe uma cadeia dessas ligando as duas. O modelo exige que todo cliente veja operações causalmente relacionadas na mesma ordem. Operações sem relação causal são **concorrentes**, e clientes diferentes podem vê-las em ordens diferentes.

O morador do 1204 leu a pergunta antes de responder, então a resposta depende da pergunta. O 507 removeu o síndico e depois postou: duas operações do mesmo cliente, em ordem. Um sistema causal impede os dois incidentes. Já duas reações de vizinhos que não viram a reação um do outro são concorrentes, e cada morador pode vê-las numa ordem sem prejuízo para ninguém.

Para implementar, cada escrita carrega as dependências (vetores de versão; vector clocks no capítulo 18), e a réplica só a torna visível depois de aplicar todas. A resposta do 1204 fica numa sala de espera até a pergunta do Paçoca chegar (COPS, Lloyd et al., 2011).

A consistência causal sobrevive a partições, desde que cada cliente fique preso aos mesmos servidores (*sticky*). Mahajan, Alvisi e Dahlin (2011) mostraram que nenhum modelo mais forte que uma variante dela cabe num sistema que permanece disponível durante partições. É o teto do que se consegue sem coordenação.

## Consistência eventual, a promessa mais curta do mundo

A **consistência eventual** diz uma coisa só: se as escritas pararem, depois de algum tempo todas as réplicas convergem para o mesmo valor (Vogels, 2009). Quanto tempo, e o que as leituras devolvem enquanto isso, a definição não diz. Um sistema que devolve 42 para toda leitura até as escritas pararem, e só então converge, cumpre a definição com louvor.

Os sistemas reais costumam se comportar melhor que a definição, com lag de milissegundos. Mas o contrato é o que vale num dia ruim, e num dia ruim o lag é de minutos.

Escritas concorrentes na mesma chave precisam de um vencedor. *Last write wins* fica com a de maior timestamp e descarta a outra em silêncio, deixando os relógios dos servidores decidirem qual morador perdeu a edição. A **consistência eventual forte** (Shapiro et al., 2011) garante que réplicas com as mesmas atualizações estão no mesmo estado, e os CRDTs (tipos de dados replicados livres de conflito) entregam isso por construção. O contador de reações do Paçoca é o candidato ideal: cada réplica conta as suas, e o total é a soma.

## Garantias de sessão, consistência sob medida para um cliente

O usuário raramente reclama do que os outros veem; reclama do que ele mesmo vê. Terry et al. (1994) definiram quatro **garantias de sessão**, do ponto de vista de um cliente:

| Garantia | O que promete | Incidente que evita |
|----------|---------------|---------------------|
| Ler as próprias escritas (*read your writes*) | Uma leitura vê as escritas anteriores da mesma sessão | Postar e não ver o próprio post |
| Leituras monotônicas (*monotonic reads*) | Uma leitura nunca vê um estado mais antigo que uma leitura anterior da sessão | Reações 14 → 9 → 14 |
| Escritas monotônicas (*monotonic writes*) | As escritas da sessão são aplicadas em todo lugar na ordem em que foram feitas | Reclamação aplicada antes da remoção do síndico |
| Escritas seguem leituras (*writes follow reads*) | Uma escrita é aplicada depois das escritas que a sessão já tinha lido | Resposta antes da pergunta |

A consistência causal implica as quatro. A implementação usual: o cliente carrega um *token de sessão* com a maior versão que já viu ou escreveu (um LSN, no PostgreSQL do capítulo 13; o `clusterTime`, nas sessões causais do MongoDB 3.6+), e o servidor que ainda não chegou lá recusa ou espera.

## O teorema CAP, com a letra miúda

O **teorema CAP** foi conjectura de Eric Brewer em 2000 e virou teorema com a prova de Gilbert e Lynch em 2002. A versão popular ("escolha dois de três", que o próprio Brewer chamou de enganosa em 2012) cabe numa camiseta e está errada em quase todas as estampas. As definições da prova são estreitas:

- **C** é linearizabilidade de um registrador. O C do ACID, a serializabilidade e "os dados estão certos" ficam de fora.
- **A** exige que toda requisição recebida por um nó que não falhou produza uma resposta. Sem limite de tempo: responder depois de três horas conta. Responder com erro, não.
- **P** é a rede poder perder arbitrariamente muitas mensagens entre nós.

A prova: dois nós, G1 e G2, separados por uma partição. Um cliente escreve `x = 1` em G1, que precisa confirmar (A) sem falar com G2. Depois, outro cliente lê `x` em G2, que precisa responder (A) e não tem como saber da escrita.

```text
  cliente 1                         cliente 2
      |  write(x=1)                     |
      v                                 |
    [G1] ----- X  partição  X ----- [G2]
      |  ok                             |  read(x)
      |                                 v
                                     x = 0   (linearizabilidade: tchau)
```

Partições acontecem sem pedir licença, então P fica fora do cardápio, e um sistema "CA" só existe num nó só. A escolha real é o comportamento **durante** a partição: recusar requisições em algum lado (sem A) ou responder com dado possivelmente velho (sem C). Sem partição, o teorema fica calado. E muitos sistemas reais ficam sem as duas letras: um PostgreSQL com réplicas assíncronas servindo leituras falha em C (réplica atrasada) e em A (o lado sem o principal recusa escritas). Por isso Martin Kleppmann pediu, em 2015, que se parasse de chamar bancos de "CP" ou "AP".

## PACELC, o custo que existe todo dia

Daniel Abadi (2012) cobriu a parte em que o CAP fica calado. **PACELC**: se há partição (**P**), escolher entre disponibilidade (**A**) e consistência (**C**); senão (**E**, de *else*), entre latência (**L**) e consistência (**C**).

A segunda metade chega na fatura todo dia. Uma leitura linearizável custa pelo menos uma ida e volta até a maioria: frações de milissegundo na mesma zona, 100 ms ou mais com réplicas em continentes diferentes. Uma leitura eventual local custa o tempo de ler a memória do servidor mais próximo. Abadi classifica Dynamo, Cassandra e Riak como PA/EL nas configurações padrão; quando o banco deixa escolher por requisição, a sigla passa a ser de cada chamada.

## Na prática

### Um verificador de linearizabilidade em 50 linhas

Verificar linearizabilidade é procurar uma ordem total que respeite o tempo real e a semântica do registrador. No caso geral o problema é NP-completo (Gibbons e Korach, 1997), e ferramentas como Knossos e Porcupine usam busca com podas. Para três operações, força bruta dá conta. O código verifica a história do diagrama (H1) e uma variante com C sobreposto a B (H2):

```python
from itertools import permutations
from typing import NamedTuple


class Op(NamedTuple):
    cliente: str
    tipo: str       # "w" (escrita) ou "r" (leitura)
    valor: int
    inicio: float   # instante da chamada, em ms
    fim: float      # instante da resposta, em ms


def respeita_registrador(ordem: tuple[Op, ...], inicial: int = 0) -> bool:
    atual = inicial
    for op in ordem:
        if op.tipo == "w":
            atual = op.valor
        elif op.valor != atual:
            return False  # leitura devolveu algo que ninguém tinha escrito ainda
    return True


def precede(a: Op, b: Op, tempo_real: bool) -> bool:
    if tempo_real:
        return a.fim < b.inicio  # a terminou antes de b começar
    return a.cliente == b.cliente and a.fim < b.inicio  # só a ordem do programa


def achar_ordem(historico: list[Op], tempo_real: bool) -> tuple[Op, ...] | None:
    for ordem in permutations(historico):  # força bruta: honesta para 3 operações
        pos = {op: i for i, op in enumerate(ordem)}
        if all(pos[a] < pos[b] for a in historico for b in historico
               if precede(a, b, tempo_real)) and respeita_registrador(ordem):
            return ordem
    return None


def relatorio(nome: str, historico: list[Op]) -> None:
    print(nome)
    for modelo, tempo_real in [("linearizável", True), ("sequencial", False)]:
        ordem = achar_ordem(historico, tempo_real)
        if ordem:
            passos = " -> ".join(f"{o.cliente}:{o.tipo}({o.valor})" for o in ordem)
            print(f"  {modelo:<13} sim  {passos}")
        else:
            print(f"  {modelo:<13} NÃO")


relatorio("H1: C lê 0 depois que B já leu 1", [
    Op("A", "w", 1, 0, 10),
    Op("B", "r", 1, 2, 4),
    Op("C", "r", 0, 6, 8),
])
relatorio("H2: C lê 0 enquanto B lê 1", [
    Op("A", "w", 1, 0, 10),
    Op("B", "r", 1, 2, 4),
    Op("C", "r", 0, 1, 3),
])
```

```text
H1: C lê 0 depois que B já leu 1
  linearizável  NÃO
  sequencial    sim  C:r(0) -> A:w(1) -> B:r(1)
H2: C lê 0 enquanto B lê 1
  linearizável  sim  C:r(0) -> A:w(1) -> B:r(1)
  sequencial    sim  C:r(0) -> A:w(1) -> B:r(1)
```

Cinco milissegundos no início da leitura de C decidem tudo. Em H2, as leituras de B e C se sobrepõem, e o verificador põe C antes da escrita. Em H1, B terminou em 4 e C começou em 6, e nenhuma ordem explica C ter lido 0. A consistência sequencial aceita as duas sem pestanejar.

### Leituras monotônicas com token de sessão

O contador de reações do Paçoca, reproduzido com duas réplicas (uma atrasada) e um balanceador alternando entre elas. A sessão guarda a maior versão já vista e recusa réplicas anteriores a ela:

```python
from dataclasses import dataclass


@dataclass
class Replica:
    nome: str
    versao: int
    reacoes: int


@dataclass
class Sessao:
    visto: int = 0  # maior versão que este cliente já leu


class SemReplicaAtualizada(Exception):
    pass


def ler(replicas: dict[str, Replica], ordem: list[str],
        sessao: Sessao | None = None) -> str:
    for nome in ordem:
        r = replicas.get(nome)
        if r is None:
            continue  # réplica fora do ar
        if sessao is None or r.versao >= sessao.visto:
            if sessao is not None:
                sessao.visto = r.versao
            return f"{r.nome} v{r.versao}: {r.reacoes} reações"
    raise SemReplicaAtualizada(f"nenhuma réplica alcançou a versão {sessao.visto}")


replicas = {"sp-1": Replica("sp-1", 42, 14), "sp-2": Replica("sp-2", 37, 9)}
rodizio = [["sp-1", "sp-2"], ["sp-2", "sp-1"], ["sp-1", "sp-2"]]

print("sem sessão:")
for ordem in rodizio:
    print(f"  {ler(replicas, ordem)}")

sessao = Sessao()
print("com sessão:")
for ordem in rodizio:
    print(f"  {ler(replicas, ordem, sessao)}")

del replicas["sp-1"]  # sp-1 cai; sp-2 continua firme no passado
try:
    ler(replicas, ["sp-2"], sessao)
except SemReplicaAtualizada as erro:
    print(f"sp-1 caiu: {erro}")
```

```text
sem sessão:
  sp-1 v42: 14 reações
  sp-2 v37: 9 reações
  sp-1 v42: 14 reações
com sessão:
  sp-1 v42: 14 reações
  sp-1 v42: 14 reações
  sp-1 v42: 14 reações
sp-1 caiu: nenhuma réplica alcançou a versão 42
```

A última linha é o custo da garantia, impresso. Sem sessão, sempre há resposta, às vezes do passado. Com sessão, a resposta nunca volta no tempo, e quando só sobra a réplica atrasada o cliente recebe um erro (ou espera ela chegar à versão 42). É o CAP na escala de um usuário.

## Propriedades e custos

A tabela segue Bailis et al. (2014) para disponibilidade na partição: **total** (qualquer servidor vivo responde), **sticky** (responde se o cliente continuar nos mesmos servidores) e **indisponível** (algum lado precisa recusar).

| Modelo | Garante | Disponibilidade na partição | Custo de leitura sem partição |
|--------|---------|------------------------------|-------------------------------|
| Serializabilidade estrita | Transações em série, respeitando tempo real | Indisponível | Ida e volta à maioria + coordenação de transação |
| Linearizável | Cópia única, tempo real | Indisponível | Ida e volta à maioria (ou lease com relógio confiável) |
| Sequencial | Ordem total igual para todos | Indisponível | Leitura local possível; escrita ordenada globalmente |
| Causal | Ordem de causa e efeito | Sticky | Local, com espera por dependências |
| Ler as próprias escritas | A sessão vê o que escreveu | Sticky | Local, com checagem de token |
| Leituras e escritas monotônicas | A sessão não volta no tempo | Total | Local, com checagem de token |
| Eventual | Convergência quando as escritas param | Total | Local |

Unicidade (nome de usuário, último assento do voo, lock) exige linearizabilidade ou consenso na operação que decide: nenhum modelo disponível em partição impede os dois lados de aceitarem o mesmo nome ao mesmo tempo. Perfil e carrinho pedem pelo menos ler as próprias escritas. Conversas e permissões pedem causalidade, porque o incidente do síndico só a ordem causal impede. Contadores toleram consistência eventual, de preferência com CRDT.

O preço também aparece em dinheiro: no Amazon DynamoDB, uma leitura fortemente consistente de até 4 KB consome uma unidade de capacidade de leitura, e uma eventual consome metade. Consistência forte custa o dobro, literalmente.

## Armadilhas e casos reais

> **Na vida real:** em junho de 2014, Kyle Kingsbury (Jepsen) mostrou que as leituras "consistentes" do etcd e do Consul podiam devolver valores velhos: um nó isolado que ainda se achava líder respondia com o valor local enquanto um novo líder já aceitava escritas. O etcd ganhou leituras por quórum, e o Consul, o modo `consistent`, em que o líder confirma a liderança com a maioria antes de responder. Hoje o etcd v3 usa leituras linearizáveis por padrão e oferece `serializable` (locais, possivelmente velhas) como opção mais rápida.

> **Na vida real:** até 1º de dezembro de 2020, o Amazon S3 era eventualmente consistente para sobrescritas e listagens, e ferramentas como o S3Guard (Hadoop) e o EMRFS Consistent View mantinham um índice à parte só para saber quais objetos existiam de verdade. Nessa data, `GET`, `PUT` e `LIST` passaram a ter consistência forte, em todas as regiões, sem custo adicional.

- **"Consistência forte" em documentação** pode significar linearizabilidade, serializabilidade, ler as próprias escritas ou só "replicação síncrona". A pergunta que resolve: uma leitura que começa depois de uma escrita confirmada, em outro cliente e outro servidor, sempre vê a escrita?
- **Um cache na frente de um banco linearizável** desfaz a linearizabilidade. O banco continua impecável; quem responde é o cache, com o valor de dez minutos atrás (capítulo 16).
- **Timeout numa escrita** deixa o resultado indeterminado, e repetir sem idempotência transforma "talvez" em "duas vezes" (capítulo 20).
- **Leituras por lease** dependem de relógios com desvio limitado. Uma pausa longa de garbage collector no líder antigo basta para ele responder com um lease já vencido.

## Resumo

- Modelo de consistência: quais histórias concorrentes o sistema pode produzir. Mais forte, mais coordenação.
- Linearizabilidade: cópia única, tempo real, composicional, exige a maioria.
- Sequencial: ordem total única, sem tempo real. Serializabilidade estrita: transações mais tempo real.
- Causal: efeito nunca antes da causa; o mais forte que sobrevive a partições, com clientes sticky.
- Eventual: só convergência. CRDTs dão consistência eventual forte.
- Garantias de sessão: token de versão por cliente, pago em disponibilidade.
- CAP: C é linearizabilidade, A é resposta de todo nó vivo, P acontece. PACELC: sem partição, latência contra consistência, todo dia.

## Referências

- Herlihy, M.; Wing, J. "Linearizability: A Correctness Condition for Concurrent Objects". ACM TOPLAS, 1990. https://doi.org/10.1145/78969.78972
- Lamport, L. "How to Make a Multiprocessor Computer That Correctly Executes Multiprocess Programs". IEEE Transactions on Computers, 1979. https://lamport.azurewebsites.net/pubs/multi.pdf
- Gilbert, S.; Lynch, N. "Brewer's Conjecture and the Feasibility of Consistent, Available, Partition-Tolerant Web Services". ACM SIGACT News, 2002. https://doi.org/10.1145/564585.564601
- Brewer, E. "CAP Twelve Years Later: How the 'Rules' Have Changed". IEEE Computer, 2012. https://www.infoq.com/articles/cap-twelve-years-later-how-the-rules-have-changed/
- Abadi, D. "Consistency Tradeoffs in Modern Distributed Database System Design". IEEE Computer, 2012. https://doi.org/10.1109/MC.2012.33
- Terry, D. et al. "Session Guarantees for Weakly Consistent Replicated Data". PDIS, 1994.
- Vogels, W. "Eventually Consistent". Communications of the ACM, 2009. https://queue.acm.org/detail.cfm?id=1466448
- Shapiro, M. et al. "Conflict-free Replicated Data Types". SSS, 2011.
- Lloyd, W. et al. "Don't Settle for Eventual: Scalable Causal Consistency for Wide-Area Storage with COPS". SOSP, 2011.
- Mahajan, P.; Alvisi, L.; Dahlin, M. "Consistency, Availability, and Convergence". UT Austin, TR-11-22, 2011.
- Bailis, P. et al. "Highly Available Transactions: Virtues and Limitations". VLDB, 2014. https://www.vldb.org/pvldb/vol7/p181-bailis.pdf
- Jepsen. "Consistency Models". https://jepsen.io/consistency
- Kingsbury, K. "Call me maybe: etcd and Consul". 2014. https://aphyr.com/posts/316-call-me-maybe-etcd-and-consul
- Kleppmann, M. "Please stop calling databases CP or AP". 2015. https://martin.kleppmann.com/2015/05/11/please-stop-calling-databases-cp-or-ap.html
- etcd. "KV API guarantees". https://etcd.io/docs/v3.5/learning/api_guarantees/
- Apache ZooKeeper. "ZooKeeper Programmer's Guide". https://zookeeper.apache.org/doc/current/zookeeperProgrammers.html
- AWS. "Amazon S3 Update – Strong Read-After-Write Consistency". 2020. https://aws.amazon.com/blogs/aws/amazon-s3-update-strong-read-after-write-consistency/
- AWS. "Read consistency" (Amazon DynamoDB). https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.ReadConsistency.html
