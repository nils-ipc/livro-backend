# Modelos de consistência

## Sexta, 17h02: dois números certos, com onze minutos de diferença

Às 17h02 de sexta, o vendedor 42 abriu o painel no notebook, viu R$ 870,00 de saldo disponível e fez o que um homem com o histórico dele faz diante de dinheiro na tela: clicou em sacar.

`saldo-insuficiente`. Ele atualizou: R$ 870,00. Clicou de novo: `saldo-insuficiente`. Na terceira, tirou um print, e print do vendedor 42 tem valor de petição inicial.

O chamado chegou pelo Bazar às 17h09: "URGENTE!!!! O SISTEMA MOSTRA O DINHEIRO E NÃO DEIXA SACAR. ISSO É CALOTE???". O financeiro achou a explicação em três segundos: às 16h58, pelo celular, o vendedor 42 tinha sacado os mesmos R$ 870,00, e o Pix já estava na conta dele. O trigger do capítulo 2 recusou o segundo saque com a frieza de um tabelião. Pela primeira vez na carreira, o vendedor 42 tentou sacar duas vezes sem querer. Ele só acreditou no painel, e o painel estava onze minutos atrasado.

O atraso tem autor. Duas semanas antes, o Carlos tirou o saldo do painel de cima do primário: 1.500 abas no pico, atualizando a cada 15 s, davam 100 `SUM`s por segundo, alguns de 0,7 s (a Capinhas Hiper, sempre ela). Agora toda transação que mexe numa conta disponível grava na outbox do capítulo 18 um evento `conta.movimentada`, publicado no tópico `contas.movimentos` (chave `conta_id`), e o consumidor `painel-saldos` o soma na tabela `saldos_painel`, no `pg-notificacoes`. Leitura de 1 ms, atraso típico de 300 ms. O Carlos chamou de "saldo em tempo real", como chama tudo, inclusive o polling de 100 ms.

Naquela sexta caiu o D+30 da Black Friday: a partir das 16h50, o job de liberação gerou 310 mil eventos. O `painel-saldos`, instância única, aplica uns 500 por segundo. O saque das 16h58 esperou na fila atrás de 300 mil liberações da Capinhas e foi aplicado às 17h13.

O gerente perguntou se não era só mostrar o número certo. O Carlos propôs fazer o saque conferir o saldo na projeção, "aí os dois batem". Batem: às 17h02 os dois diriam R$ 870,00, e o vendedor 42 receberia R$ 870,00 pela segunda vez, com tela e banco em perfeito acordo. Saque dobrado, agora com a aprovação de dois sistemas.

A pergunta deste capítulo: qual leitura precisa ver o estado de agora, qual pode ver o de alguns minutos atrás, e como garantir que a atrasada nunca contradiga o que o próprio usuário acabou de fazer?

## "Consistência", a palavra que significa três coisas e briga nas três

É a terceira palavra mais abusada da computação, atrás de "simples" e de "temporário". O C do ACID (capítulo 3) é sobre invariantes: o ledger soma zero. O C do CAP é linearizabilidade, que vem já já. E "modelo de consistência" é o contrato entre um sistema e quem lê dele: dadas as escritas que aconteceram, quais valores uma leitura pode devolver.

Formalmente, um modelo é um conjunto de histórias permitidas (operações com início, fim e valor, como os clientes observaram), e é mais forte que outro quando permite menos histórias. Em português de palco: é a lista de mentiras que o sistema está autorizado a te contar. A projeção do Carlos tinha a lista mais comprida do mercado e usou o item "seu próprio saque não aconteceu".

## Linearizabilidade, ou fingir que existe uma cópia só

A definição é de Herlihy e Wing (1990). Uma execução é **linearizável** quando cada operação parece ter efeito atômico em algum instante entre a invocação e a resposta, numa ordem compatível com o tempo real: se A terminou antes de B começar, A vem antes de B. Com cinquenta réplicas, o sistema se comporta, para quem está de fora, como uma cópia só.

```text
tempo →
Celular:   |--- saque 870 (saldo: 870 → 0) ---|
Notebook A:                                        |-- lê --| → 870   PROIBIDO
Notebook B:              |-------- lê --------|               → 870 ou 0, ambos válidos
Notebook C:                                                 |-- lê --| → depois que alguém leu 0,
                                                                         ninguém mais lê 870
```

O notebook A começou depois que o saque respondeu, então tem que ver 0. O B é concorrente e pode ver qualquer um dos dois valores. A terceira regra pega os sistemas espertinhos: depois que uma leitura devolveu o valor novo, nenhuma leitura que comece depois pode devolver o antigo. O saldo não fica piscando entre 0 e 870 conforme a réplica que atendeu, como letreiro de motel.

Linearizabilidade trata de operações sobre um objeto; serializability (capítulo 3), de transações sobre vários, sem exigir tempo real: em tese, um banco serializable pode ordenar a sua transação antes de uma que já tinha feito COMMIT quando a sua começou. As duas juntas formam a *strict serializability*. Confundir uma com a outra rende muito postmortem.

O custo: alguém decide a ordem, seja um único nó (o primário), seja um acordo entre réplicas a cada operação, que é consenso (capítulo 20). A operação paga pelo menos uma ida e volta até quem decide, 100 ms do outro lado do oceano (capítulo 8), e nenhuma otimização fura a velocidade da luz. O fundador sempre disse que no tempo dele era um servidor só e funcionava. Funcionava, e era linearizável de graça. Ele só não sabia o nome.

## Descendo a escada: sequencial, causal, eventual

**Consistência sequencial** (Lamport, 1979): existe uma ordem total única de todas as operações, todos os clientes concordam com ela, e ela respeita a ordem do programa de cada cliente. Caiu o tempo real. O notebook A poderia ler 870, contanto que todo mundo concordasse que a leitura veio "antes" do saque. Viagem no tempo liberada, desde que em excursão: todos viajam juntos.

**Consistência causal** (Ahamad e colegas, 1995): só operações com relação de causa precisam aparecer na mesma ordem para todos. Se o Bazar leu a cobrança paga e, por isso, pediu um estorno, ninguém pode ver o estorno sem ver o pagamento; operações concorrentes podem aparecer em ordens diferentes para clientes diferentes. A relação de causa é o "aconteceu antes" de Lamport, que o capítulo 20 rastreia com relógios lógicos. Ela se mantém durante uma partição, com todos os nós respondendo, e Mahajan, Alvisi e Dahlin (2011) mostraram que nada mais forte que a variante *real-time causal* é possível num sistema que sempre responde.

**Consistência eventual** (termo popularizado por Werner Vogels): se as escritas pararem, as réplicas convergem para o mesmo valor. Só isso. Sem prazo e sem promessa sobre o que você lê no caminho, inclusive valor que volta a ser mais velho. É a garantia que um político daria: vai convergir, e não pergunte quando. A projeção do Carlos convergiu direitinho às 17h13, onze minutos e um chamado em caixa alta depois.

A favor dela: saldo é soma, e soma é comutativa. Aplicar os eventos de uma conta em qualquer ordem chega ao mesmo total, e a deduplicação por `transacao_id` (capítulo 16) torna a reaplicação inofensiva. É o truque dos CRDTs, tipos replicados que convergem sozinhos. A aritmética garante o fim da história; o meio da história ela deixa para o vendedor 42 descobrir.

### Garantias de sessão: consistência eventual com modos

Entre o eventual puro e o causal ficam as garantias de sessão, de Terry e colegas (1994, sistema Bayou). Nada sobre o mundo; só coerência para cada cliente, dentro da sessão dele.

| Garantia | Promessa | Na Lastro, quando falha |
|----------|----------|-------------------------|
| Read-your-writes | Uma leitura reflete todas as escritas anteriores da mesma sessão | O vendedor saca e o painel mostra o dinheiro ainda lá (sexta, 17h02) |
| Leituras monotônicas | Uma leitura nunca reflete um estado mais antigo que o de uma leitura anterior da sessão | O painel mostra R$ 0,00, atualiza e mostra R$ 870,00 de novo |
| Escritas seguem leituras | Uma escrita feita depois de ler X é ordenada depois de X em todas as réplicas | O estorno chega a uma réplica que ainda não viu o pagamento |
| Escritas monotônicas | As escritas da sessão são aplicadas na ordem em que foram feitas | A troca da chave Pix chega depois do saque que deveria usá-la |

Terry acrescentou depois (2013) o *prefixo consistente*: o leitor vê um prefixo da ordem real das escritas, sem buracos. Quem lê o placar vê 0 a 0, 1 a 0, 2 a 0, nunca 0 a 2.

Toda linha da coluna da direita é um chamado do Bazar que ainda não foi aberto. A segunda, um saldo que some e reaparece, transforma qualquer vendedor num conspiracionista. O vendedor 42 já era um sem ajuda.

## CAP com a definição certa, e o PACELC que diz o resto

O CAP aparece em entrevista como "escolha dois entre três", dito com a solenidade de quem cita um provérbio chinês, e está errado. A conjectura é de Eric Brewer (2000); o teorema é de Gilbert e Lynch (2002), com estas definições:

- **C** (consistência): linearizabilidade de um registrador de leitura e escrita.
- **A** (disponibilidade): toda requisição recebida por um nó que não falhou recebe resposta. Toda.
- **P** (tolerância a partição): a rede pode perder arbitrariamente muitas mensagens entre os nós.

O teorema: com a rede particionada, nenhum sistema garante C e A ao mesmo tempo. A prova cabe num guardanapo. Dois nós, a rede entre eles caiu, um cliente escreve no nó 1 e outro lê do nó 2. Se o nó 2 responde, pode devolver o valor velho e quebra C. Se espera notícia do nó 1 para não mentir, não responde e quebra A.

Ninguém escolhe deixar a partição de fora: a rede particiona quando quer. A escolha é o que fazer nessa hora, recusar para manter a linearizabilidade ou responder com o que tem. Fora de partição, o CAP não diz nada. E o A do CAP é muito mais exigente que o de um contrato: um sistema "CP" pode entregar 99,99% no SLA, e um que responde tudo com dado de ontem é "A" pelo teorema. Por isso Martin Kleppmann pediu, num artigo inteiro, que parassem de classificar bancos como CP ou AP.

Daniel Abadi completou com o PACELC (2012): se há **P**artição, escolha entre **A** e **C**; senão (**E**lse), entre latência (**L**) e **C**. A segunda metade você paga todo dia: partição é rara, latência é toda requisição. Na classificação de Abadi, Dynamo, Cassandra e Riak na configuração padrão são PA/EL; sistemas ACID completos como VoltDB e Megastore são PC/EC.

O DynamoDB coloca o PACELC na fatura: uma leitura fortemente consistente de até 4 KB consome uma unidade de capacidade de leitura; a eventualmente consistente, meia. Nos índices secundários globais, a leitura forte nem existe. Um teorema de sistemas distribuídos virou item de nota fiscal, e o financeiro vai querer conciliar.

## Na Lastro: cada leitura com o contrato de que precisa

A Lastro tem um primário do ledger, sem réplica (capítulo 23). Uma leitura no primário depois que um COMMIT retornou enxerga esse COMMIT, porque o snapshot (do comando em read committed, da primeira consulta em serializable) inclui toda transação já confirmada: é a recência que a linearizabilidade pede. A projeção do Carlos foi a primeira cópia de saldo fora dele. A regra da Lastro: o modelo de cada leitura é escolhido pelo prejuízo de ela vir velha.

| Leitura | Modelo | Fonte | O que uma leitura velha causaria |
|---------|--------|-------|----------------------------------|
| Saldo na checagem de débito (saque, estorno, repasse) | linearizável, dentro da transação serializable (capítulo 3) | primário | Saque dobrado |
| Tela de confirmação do saque ("disponível agora") | linearizável | primário | Vendedor decide em cima de número falso |
| Chave de idempotência (capítulo 16) | linearizável (UNIQUE) | primário | Cobrança duplicada |
| Saldo no cabeçalho do painel e no GraphQL | eventual + read-your-writes + leituras monotônicas | `saldos_painel` | Número atrasado na tela, nunca dinheiro fora |
| Webhooks aos marketplaces | eventual, ordem por cobrança, monotônico no cliente pelo campo `versao` (capítulo 11) | broker | Estado antigo descartado pelo cliente |
| Fechamento e conciliação | snapshot (repeatable read READ ONLY) | primário | Dia fechado pela metade |

A proposta do Carlos morre na primeira linha: a leitura que autoriza a saída de dinheiro nunca vem de cópia. A projeção fica, porque o requisito que a criou continua (100 `SUM`s por segundo no pico, só para enfeitar o cabeçalho), agora com contrato de sessão.

### Read-your-writes sem token mágico

A sessão, aqui, é o vendedor: o saque saiu do celular e a leitura veio do notebook, então uma garantia presa a um cookie não teria salvado ninguém. A "última escrita da sessão" é o último débito iniciado por aquele vendedor, e quem sabe disso com certeza é o primário.

```text
Painel pede o saldo do vendedor 42
  │
  ├─ 1. primário: último débito iniciado por ele        (índice, < 1 ms)
  │      → transacao_id 98.114.230 (saque de 16h58)
  │
  ├─ 2. pg-notificacoes: inbox do painel-saldos já tem 98.114.230?
  │      ├─ sim → devolve saldos_painel (1 ms)
  │      └─ não → espera o NOTIFY de aplicação, até 2 s
  │               ├─ chegou → devolve saldos_painel
  │               └─ não chegou → devolve "atualizando", sem número
  │
  └─ tela de saque: sempre o primário, dentro da checagem
```

A parte barata ("qual escrita minha você precisa refletir") vai ao primário; a cara, a soma de 1,1 milhão de lançamentos, fica na projeção. O `painel-saldos` grava saldo e linha da inbox na mesma transação, então "a inbox tem a transação" e "o saldo inclui a transação" são o mesmo fato. O painel mostra o número certo ou "atualizando". Às 17h02, teria dito "atualizando" por onze minutos, o que irrita, mas não gera print com valor jurídico.

Leituras monotônicas saem por construção: `saldos_painel` vive numa única instância, e o consumidor só aplica, nunca desfaz, então toda leitura reflete um superconjunto da anterior. Vale enquanto houver uma cópia só; com réplica (capítulo 23), o cliente terá de carregar a posição mais alta que já viu. Fica anotado, porque o primeiro a esquecer vai ser quem anotou.

O `painel-saldos` passa a três instâncias (12 partições permitem até 12) e o atraso vira métrica com alerta acima de 30 s, porque "eventualmente" sem número é horóscopo. A recusa de saque leva no corpo RFC 9457 o saldo lido na própria transação e o último débito ("disponível: R$ 0,00; último débito: saque de R$ 870,00 às 16h58"), do mesmo snapshot que decidiu. O erro não discute com o ledger.

Na partição: sem o `pg-notificacoes`, o cabeçalho some e o saque continua. Sem o primário, a projeção segue mostrando saldo (A para quem só olha) e todo débito recebe `503` (C para quem quer levar dinheiro). Cada leitura escolheu seu lado do CAP antes da partição, o único momento em que dá para escolher com calma.

Com outros requisitos, a escolha seria outra: saldo servido em várias regiões com latência baixa pediria consistência causal com réplicas locais; dezenas de acessos por segundo em vez de 100 `SUM`s dispensariam a projeção, e ler do primário seria mais simples.

## Armadilhas e casos reais

> **Armadilha:** check-then-act com leitura eventual. A corrida do capítulo 2 durava microssegundos; com uma cópia atrasada, dura o atraso da cópia. Onze minutos, na Lastro. Toda decisão que gasta, reserva ou libera alguma coisa lê da fonte linearizável. A proposta do Carlos era essa armadilha com laço de presente.

> **Armadilha:** "fortemente consistente" no material de vendas pode significar linearizável por chave e nada entre chaves, ou só no líder, ou só com uma opção desligada por padrão. Pergunte qual história ele proíbe, em qual configuração, e se há teste publicado (a página do Jepsen tem o mapa). O vendedor do banco tem um brinde.

> **Na vida real:** o artigo do Dynamo (DeCandia e colegas, 2007) descreve o carrinho da Amazon projetado para aceitar escrita sempre; versões divergentes são mescladas, e o artigo admite que itens removidos podem reaparecer. Num carrinho, um item ressuscitado é aceitável. Num saque, a ressurreição seria o vendedor 42 recebendo duas vezes, e ele com certeza já leu esse artigo.

> **Na vida real:** até dezembro de 2020, o Amazon S3 tinha consistência eventual para sobrescritas, remoções e listagens, e ferramentas de *data lake* mantinham camadas extras só para a listagem que não mostrava o arquivo recém-gravado. Naquele mês, a AWS anunciou consistência forte de leitura após escrita em todas as operações, e muita gambiarra foi demitida sem aviso prévio.

## Resumo

- "Consistência": invariantes (ACID), linearizabilidade (CAP), modelo de consistência (o que uma leitura pode devolver).
- Linearizabilidade: efeito atômico entre início e fim, em ordem de tempo real; custa coordenação e um RTT até quem ordena. Serializability não exige tempo real; strict serializability junta as duas.
- Sequencial: ordem total única. Causal: só o que tem causa precisa de ordem; teto sem coordenação. Eventual: converge, sem prazo.
- Garantias de sessão: read-your-writes, leituras monotônicas, escritas seguem leituras, escritas monotônicas; prefixo consistente.
- CAP: na partição, linearizabilidade ou resposta de todo nó. PACELC: sem partição, latência contra consistência.
- O modelo de cada leitura sai do prejuízo de ela vir velha.

## A Lastro agora

Débitos, tela de saque e chaves de idempotência leem o primário. O cabeçalho do painel lê `saldos_painel`, com read-your-writes pelo último débito do vendedor, "atualizando" no lugar de número velho e alerta de atraso acima de 30 s. O vendedor 42 recebeu uma explicação por escrito, leu duas vezes e mandou print para o Bazar, por garantia.

O fundador leu a seção sobre o CAP, gostou muito da palavra "disponibilidade" e, na segunda-feira, copiou o crontab de `temp-01` para `api-02`, para que o `repasse_final_v2_agora_vai.py` tivesse alta disponibilidade. Agora ele tem. Roda nas duas máquinas, à meia-noite de cada uma, e as duas discordam sobre que horas é meia-noite.

## Referências

- Maurice Herlihy e Jeannette Wing, "Linearizability: A Correctness Condition for Concurrent Objects", ACM TOPLAS, 1990. https://dl.acm.org/doi/10.1145/78969.78972
- Leslie Lamport, "How to Make a Multiprocessor Computer That Correctly Executes Multiprocess Programs", IEEE Transactions on Computers, 1979. https://www.microsoft.com/en-us/research/publication/make-multiprocessor-computer-correctly-executes-multiprocess-programs/
- Mustaque Ahamad et al., "Causal Memory: Definitions, Implementation, and Programming", Distributed Computing, 1995.
- Prince Mahajan, Lorenzo Alvisi e Mike Dahlin, "Consistency, Availability, and Convergence", UTCS TR-11-22, University of Texas at Austin, 2011.
- Werner Vogels, "Eventually Consistent", Communications of the ACM, 2009. https://dl.acm.org/doi/10.1145/1435417.1435432
- Douglas Terry et al., "Session Guarantees for Weakly Consistent Replicated Data", PDIS 1994.
- Douglas Terry, "Replicated Data Consistency Explained Through Baseball", Communications of the ACM, 2013. https://www.microsoft.com/en-us/research/publication/replicated-data-consistency-explained-through-baseball/
- Seth Gilbert e Nancy Lynch, "Brewer's Conjecture and the Feasibility of Consistent, Available, Partition-Tolerant Web Services", ACM SIGACT News, 2002. https://dl.acm.org/doi/10.1145/564585.564601
- Daniel Abadi, "Consistency Tradeoffs in Modern Distributed Database System Design", IEEE Computer, 2012. https://doi.org/10.1109/MC.2012.33
- Martin Kleppmann, "Please stop calling databases CP or AP", 2015. https://martin.kleppmann.com/2015/05/11/please-stop-calling-databases-cp-or-ap.html
- Jepsen, Consistency Models. https://jepsen.io/consistency
- Giuseppe DeCandia et al., "Dynamo: Amazon's Highly Available Key-value Store", SOSP 2007. https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf
- Amazon DynamoDB, Read consistency. https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.ReadConsistency.html
- AWS News Blog, "Amazon S3 Update – Strong Read-After-Write Consistency", dezembro de 2020. https://aws.amazon.com/blogs/aws/amazon-s3-update-strong-read-after-write-consistency/
