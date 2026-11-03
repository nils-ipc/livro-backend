# Concorrência na aplicação

## Dois saques, um saldo e um vendedor com duas abas abertas

O vendedor 42 tinha R$ 500,00 de saldo disponível, duas abas do painel abertas e o dedo mais rápido do Bazar Bem-te-vi. Clicou em "Sacar R$ 500,00" nas duas, e a Lastro, com a honestidade contábil do capítulo 1, registrou dois saques perfeitos, soma zero em cada um, dignos de tabelião. O banco parceiro mandou R$ 1.000,00 por Pix, e o saldo do vendedor ficou em R$ −500,00, que o ledger guarda com o mesmo carinho dos positivos.

O código do saque fazia o que qualquer pessoa sensata faria:

```text
1. saldo = SUM dos lançamentos da conta disponível do vendedor
2. se saldo >= valor: insere a transação de saque
3. senão: recusa
```

Três linhas e nenhum bug, desde que só exista um clique no universo. As duas requisições chegaram com 3 ms de diferença, as duas leram R$ 500,00 e as duas estavam certas no momento em que olharam.

O Carlos corrigiu em vinte minutos com um lock em memória por conta. Nos testes, perfeito. Na semana seguinte, o vendedor 42, que tinha descoberto um hobby, repetiu a façanha. Por que o lock funcionou no notebook do Carlos e falhou em `temp-01`, e onde a verificação de saldo precisa morar para que dois cliques nunca virem dois saques?

## Condição de corrida, o bug que só aparece quando você não está olhando

Uma **condição de corrida** (*race condition*) acontece quando o resultado depende da ordem em que execuções concorrentes intercalam seus passos, e alguma dessas ordens produz um resultado errado. Cada execução, sozinha, está correta. O erro mora entre elas, numa ordem que nenhum teste unitário produz, porque teste unitário faz uma coisa de cada vez, igual ao dev que escreveu.

O padrão do saque é o **check-then-act**: verificar uma condição (saldo suficiente) e agir com base nela (debitar). Entre as duas coisas existe um intervalo, e a condição pode deixar de valer dentro dele. Em segurança, o nome é TOCTOU (*time of check to time of use*, CWE-367), porque atacante adora um intervalo.

```text
tempo   requisição A                 requisição B
t0      lê saldo: 50000
t1                                   lê saldo: 50000
t2      50000 >= 50000, debita
t3                                   50000 >= 50000, debita
t4      commit                       commit           saldo final: -50000
```

O primo é o **read-modify-write**: duas execuções leem 10, calculam 11, gravam 11, e um incremento some sem deixar bilhete. É o *lost update*, que volta no capítulo 3 de roupa de gala.

Agora o bit favorito de quem programa em Python: "mas tem o GIL". Tem. O GIL (*global interpreter lock*) deixa uma thread por vez executar bytecode no CPython e protege as estruturas internas do interpretador. O seu saldo fica fora dessa proteção, por mais que o fundador trate `temp-01` como extensão do próprio corpo. Um `contador += 1` vira várias instruções de bytecode, e a troca de thread pode cair entre elas. E o Python 3.13 trouxe o build *free-threaded* (PEP 703), sem GIL, para quem achava que concorrência estava fácil demais.

O `asyncio` tem a sua versão do crime, numa thread só. Uma corrotina cede o controle em cada `await`. O saque fazia `await` na consulta do saldo e `await` na inserção, e entre os dois o event loop atendeu a outra aba do vendedor 42. Zero paralelismo e mesmo assim uma corrida: o equivalente técnico de bater o carro sozinho num estacionamento vazio.

E corridas dependem de *timing*: um `print` muda o tempo e a corrida some; você tira o `print` e ela volta. O mercado chama isso de *heisenbug*, e o plantão chama de "não consigo reproduzir", frase que já encerrou mais chamados do que qualquer correção.

## Seção crítica e mutex, ou ciúme com suporte do sistema operacional

O trecho que acessa um estado compartilhado e não pode ser intercalado com outro acesso ao mesmo estado é a **seção crítica**; no saque, vai da leitura do saldo à gravação do débito. A solução clássica é a **exclusão mútua**: uma execução por vez lá dentro.

O instrumento é o **mutex** (*mutual exclusion lock*, ou só *lock*), com duas operações: adquirir (`acquire`) e liberar (`release`). Quem tenta adquirir um lock ocupado espera o dono liberar. Um lock correto garante segurança (*safety*: nunca duas execuções dentro da seção crítica) e vivacidade (*liveness*: se ninguém está dentro, quem quer entrar entra). Falhar na primeira dá saque duplo; falhar na segunda dá um sistema que nunca erra porque nunca faz nada, o sonho de todo auditor.

O lock só protege se **todo** acesso ao estado passar por ele. Basta um caminho sem lock para tudo desabar, e esse caminho sempre existe: chama-se "o script de correção que o Carlos rodou direto no banco".

O custo é a serialização: a seção crítica é parte serial por definição, e a Lei de Amdahl (capítulo 14) diz que a parte serial limita qualquer paralelismo. Daí o lock fino, um por conta. Um lock global poria os 1.200 vendedores do Bazar sacando em fila indiana, o que resolve a corrida e cria uma reclamação por minuto.

## Operações atômicas: o check e o act no mesmo instante

Uma operação é **atômica** quando ninguém observa um estado intermediário dela. Fazer o check e o act numa única operação atômica elimina o intervalo, e a corrida morre de fome.

O processador oferece isso em hardware. **Compare-and-swap** (CAS) grava um valor novo num endereço só se ele ainda contém o valor esperado, numa instrução só (`CMPXCHG` no x86). Com CAS se constroem contadores, filas e o próprio mutex sem ninguém esperar ninguém, técnica chamada *lock-free*, que funciona perfeitamente até você descobrir o problema ABA e passar a dormir de luz acesa.

Servidores de dados oferecem a mesma ideia mais acima. No Redis, `INCR` é atômico. No SQL, um `UPDATE` com a condição no `WHERE` é um compare-and-set sobre uma linha:

```sql
UPDATE saldos SET disponivel = disponivel - 50000
 WHERE conta_id = 42 AND disponivel >= 50000;
-- primeira sessão:  UPDATE 1
-- segunda sessão:   UPDATE 0   (esperou a primeira, reavaliou, recusou)
```

No PostgreSQL, em *read committed* (o nível padrão), a segunda sessão espera o lock da linha e, depois do *commit* da primeira, reavalia o `WHERE` contra a versão nova. Vê 0 e não grava nada. O `UPDATE 0` é a forma mais educada que um banco tem de dizer "seu vendedor é um golpista". Repare que isso exige uma linha com o saldo, e a Lastro, desde o capítulo 1, deriva o saldo dos lançamentos.

## Deadlock e as quatro condições de Coffman

Quem usa lock descobre o **deadlock**: execuções esperando umas pelas outras, para sempre. A tem o lock da conta 7 e quer o da 9; B tem o da 9 e quer o da 7.

```text
A: Me passa a conta 9?
B: Passo, assim que você me passar a 7.
A: Passo, assim que terminar. E só termino com a 9.
B: Então ficamos assim.
(eternidade)
Bazar: URGENTE!!!!
```

Consistência perfeita: ninguém escreve nada errado porque ninguém escreve nada.

Coffman, Elphick e Shoshani mostraram em 1971 que um deadlock só acontece se quatro condições valerem ao mesmo tempo:

1. **Exclusão mútua**: o recurso só pode ser usado por um de cada vez.
2. **Posse e espera** (*hold and wait*): quem tem um recurso pode esperar por outro sem soltar o primeiro.
3. **Sem preempção**: ninguém tira um recurso de quem o tem; só o dono libera.
4. **Espera circular**: existe um ciclo de execuções, cada uma esperando um recurso que a próxima tem.

Quebrar qualquer uma elimina o deadlock. A mais usada é a quarta, com **ordem global de aquisição**: se todos adquirem locks em ordem crescente de ID, ninguém segura a 9 esperando a 7. Quebrar a segunda é adquirir tudo de uma vez. Quebrar a terceira é *timeout*: quem espera demais solta tudo e tenta de novo, e aí nasce o *livelock*, todo mundo desistindo e tentando no mesmo ritmo, muita atividade e nenhum progresso, igual a uma reunião de planejamento.

O PostgreSQL ataca depois. Quem espera um lock por mais que `deadlock_timeout` (1 segundo por padrão) dispara a busca por ciclos no grafo de espera; o servidor escolhe uma vítima e aborta a transação dela, sem direito a últimas palavras:

```text
ERROR:  deadlock detected
DETAIL:  Process 4120 waits for ShareLock on transaction 91822; blocked by process 4188.
Process 4188 waits for ShareLock on transaction 91821; blocked by process 4120.
```

A aplicação recebe o erro e repete a transação. O capítulo 4 volta aos deadlocks no banco.

## O lock do Carlos e os processos que não se conheciam

A correção do Carlos era um dicionário de `asyncio.Lock`, um por conta, na memória do processo. No teste, um processo, um lock, os dois saques em fila. Correto.

Só que `temp-01` roda o monólito em três processos, porque o fundador configurou `--workers 3` há dois anos "para aproveitar os núcleos" (o capítulo 13 explica esses *workers*). Cada processo tem a própria memória, logo o próprio dicionário, logo o próprio lock da conta 42. Com as conexões distribuídas por igual entre três processos, a chance de os dois saques caírem em processos diferentes é de 2/3. O lock do Carlos funcionava em um terço dos casos. Tecnicamente é um lock. Juridicamente é um problema.

Cada primitiva de exclusão mútua tem um escopo, e fora dele ela não existe:

| Primitiva | Exclui | Não enxerga |
|-----------|--------|-------------|
| `asyncio.Lock` | corrotinas do mesmo event loop | outras threads, outros processos |
| `threading.Lock` | threads do mesmo processo | outros processos |
| `multiprocessing.Lock` | processos que herdaram o lock do mesmo pai, na mesma máquina | outras máquinas |
| `flock` (arquivo local) | processos da mesma máquina | outras máquinas |
| lock no banco de dados | qualquer sessão no mesmo banco | quem escreve sem pegar o lock |
| lock distribuído (Redis, etcd, ZooKeeper) | clientes do serviço de lock | o recurso protegido, que nem sabe que o lock existe |

E a primitiva errada cobra caro: um `threading.Lock` em código `async` trava o event loop inteiro enquanto espera, e um `asyncio.Lock` ignora outras threads. Deadlock ou corrida, você escolhe.

Três processos numa máquina ainda são o caso fácil. Quando existir `temp-02` atrás de um balanceador (capítulo 27; o fundador já falou em "duplicar a máquina pra Black Friday"), nem o `multiprocessing.Lock` alcança. Réplicas em máquinas diferentes só compartilham o que está fora delas: o banco ou um serviço de lock.

## Locks distribuídos, ou o mutex com prazo de validade

Um **lock distribuído** é exclusão mútua entre processos em máquinas diferentes, coordenada por um serviço externo. O exemplo mais comum usa o Redis:

```text
SET lock:conta:42 9f3c1a77 NX PX 10000
OK          (primeiro cliente: adquiriu)
SET lock:conta:42 b81e0d42 NX PX 10000
(nil)       (segundo cliente: a chave já existe)
```

`NX` só grava se a chave não existir, o que torna a aquisição atômica. O valor aleatório identifica o dono, e a liberação apaga a chave só se o valor ainda for o seu. `PX 10000` dá 10 segundos de vida à chave, e é aqui que a ciência acaba e a fé começa.

O TTL existe porque processos morrem segurando lock, e sem ele a vítima do OOM killer deixaria a conta 42 travada até alguém apagar a chave na mão. Com ele, o lock vira um **lease**: posse temporária, que expira sozinha. E aí vem a falha de todo lock baseado em tempo:

```text
t=0s    processo A adquire o lease (TTL 10s)
t=1s    A entra numa pausa de GC de 12 s (ou swap, ou migração da VM)
t=10s   lease expira; processo B adquire e debita a conta 42
t=13s   A acorda, ainda convencido de que é o dono, e debita a conta 42
```

O processo A morreu aos 10 segundos e ninguém avisou. Acorda zumbi, com acesso de escrita, e faz o que zumbis com acesso de escrita fazem. Nenhum TTL resolve: pausas de processo não têm limite superior garantido.

Martin Kleppmann descreveu o problema em 2016, ao analisar o Redlock (o algoritmo sobre vários nós Redis proposto pelo criador do Redis): lock baseado em lease serve para **eficiência** (evitar trabalho duplicado que só custa CPU) e, sozinho, falha para **correção** (impedir um efeito que não pode acontecer duas vezes). Para correção, o recurso protegido precisa recusar o dono antigo com um *fencing token*, número crescente a cada aquisição que o recurso confere. O capítulo 20 constrói isso para o `repasse_final_v2_agora_vai.py`, que vai precisar.

E tem a replicação: um Redis com réplica assíncrona pode confirmar o `SET` e cair antes de replicar. O lock foi replicado em pensamento. etcd e ZooKeeper, baseados em consenso, evitam essa perda e fornecem números monotônicos para o fencing, ao custo de mais uma peça com quórum. E o PostgreSQL, onde mora o dinheiro, continua sem fazer ideia de quem o Redis acha que é o dono da conta 42.

## Na Lastro: o lock vai morar com o dinheiro

O requisito é uma invariante: o saldo disponível de um vendedor nunca fica negativo por causa de um débito, venha ele de qualquer processo, de qualquer máquina ou de qualquer script do Carlos.

| Opção | Garante | Custo | Serve quando |
|-------|---------|-------|--------------|
| Lock em memória | exclusão num processo | falha com 2+ processos | um processo, para sempre |
| Lock distribuído (Redis) | exclusão enquanto o lease vale | peça nova; sem fencing, o PostgreSQL ignora | evitar trabalho duplicado |
| `pg_advisory_xact_lock(conta_id)` | exclusão no banco até o fim da transação | chave numérica por convenção | recurso sem linha própria |
| `UPDATE` condicional em saldo materializado | check e act num comando | segunda fonte da verdade | saldo materializado já existe |
| `FOR UPDATE` na conta, `SUM` e débito na mesma transação | exclusão por conta até `COMMIT` ou `ROLLBACK` | fila por conta; `SUM` cresce | saldo derivado, como na Lastro |

A Lastro escolhe a última, porque o lock passa a viver no mesmo sistema que o dado, dentro da transação que grava o débito. Se o processo dorme segurando o lock, a transação continua aberta e a conta continua travada: o lock pertence à transação, e relógio nenhum o expira. Se o processo morre, a conexão cai, o PostgreSQL faz *rollback* e solta o lock. Sem lease, não existe dono antigo para recusar. E o saldo continua derivado, como o capítulo 1 exigiu pela conciliação explicável; o `UPDATE` condicional espera o dia em que houver saldo materializado.

O fluxo do saque fica assim:

```text
BEGIN                                    (read committed)
  SELECT ... FROM contas WHERE id = :conta FOR UPDATE   -- espera aqui, se preciso
  SELECT SUM(valor) FROM lancamentos WHERE conta_id = :conta
  saldo suficiente?  não -> ROLLBACK, saque recusado
  INSERT transação de saque + 2 lançamentos (soma zero)
COMMIT                                   (lock liberado)
depois do COMMIT: pedido de Pix ao banco parceiro
```

O segundo saque do vendedor 42 espera uns 4 ms no `FOR UPDATE`, recebe o lock depois do *commit* do primeiro, e o `SUM` dele roda num comando novo, com *snapshot* novo, que já enxerga o débito. Saldo zero, saque recusado, hobby encerrado.

Falta garantir que todo débito passe pelo `FOR UPDATE`, e caminho alternativo é a especialidade do Carlos. Por isso a verificação sai do código Python e vai para o banco: um *trigger* `BEFORE INSERT` nos lançamentos que debitam uma conta disponível trava a linha da conta, recalcula o saldo e recusa o lançamento que o deixaria negativo. Monólito, job ou `psql` do Carlos, todos passam por ele. Créditos dispensam o lock, porque só aumentam o saldo. Ao Python sobrou traduzir o erro em "saldo insuficiente".

Duas regras vêm junto. Pela quarta condição de Coffman, uma transação que debita várias contas disponíveis (um estorno que debita o vendedor e a comissão do Bazar) insere os lançamentos em ordem crescente de `conta_id`. E o pedido de Pix ao banco parceiro sai depois do `COMMIT`, porque centenas de milissegundos de rede dentro da seção crítica fariam todo saque da conta esperar a rede de outra empresa. Se esse pedido falha depois do débito, os capítulos 15 e 18 assumem.

Os números: cerca de 400 saques por dia no Bazar, quase nunca dois da mesma conta no mesmo segundo, lock segurado por uns 4 ms. A fila por conta vive vazia. Uma conta debitada centenas de vezes por segundo encheria essa fila, e o capítulo 4 trata dessa conta.

## Armadilhas e casos reais

> **Armadilha:** a mesma receita falha em *repeatable read*. Nesse nível, o `SUM` usa o snapshot do início da transação, e o `FOR UPDATE` numa linha só travada (sem alteração) pela outra transação passa sem erro: o segundo saque espera, recebe o lock e soma um saldo velho. A corrida volta fantasiada de correção. O capítulo 3 explica por quê.

> **Armadilha:** o dicionário do Carlos criava um `asyncio.Lock` por conta e nunca apagava nenhum. Além de falhar entre processos, vazava memória no formato exato do cadastro de vendedores. Um bug que falha e ainda paga aluguel.

Teste de uma requisição por vez nunca acha corrida; o de concorrência dispara tudo junto, muitas vezes, e confere a invariante, porque a corrida de uma em mil aparece todo dia em produção.

> **Na vida real:** em março de 2014, a Flexcoin, que se apresentava como banco de bitcoin, perdeu 896 BTC e fechou. Segundo a empresa, o atacante abriu uma conta e disparou milhares de transferências simultâneas entre usuários; o saldo era verificado antes de ser atualizado, e todas passaram pela mesma verificação. Na mesma semana, a Poloniex relatou ataque semelhante nos saques e perdeu 12,3% dos bitcoins que custodiava. O vendedor 42 fez a mesma coisa com duas abas; o atacante só tinha mais abas.

## Resumo

- Condição de corrida: resultado dependente da intercalação; check-then-act e read-modify-write são as formas comuns.
- O GIL deixa `+=` sem atomicidade; no `asyncio`, cada `await` é ponto de intercalação.
- Seção crítica pede exclusão mútua, e o lock só protege se todo acesso passar por ele.
- Operações atômicas (CAS, `INCR`, `UPDATE` condicional) eliminam o intervalo entre verificar e agir.
- Deadlock exige as quatro condições de Coffman; ordem de aquisição quebra a espera circular.
- Toda primitiva de lock tem escopo; lock em memória fica preso ao processo.
- Lock distribuído com TTL é lease; correção exige fencing token.
- Lock no banco, na transação que grava o dado, dispensa lease e fencing.

## A Lastro agora

O saque trava a linha da conta disponível com `SELECT ... FOR UPDATE`, recalcula o saldo pelo `SUM` e debita na mesma transação, em *read committed*; um trigger impõe a verificação a qualquer caminho de escrita, débitos em várias contas seguem a ordem de `conta_id`, e o Pix sai só depois do commit. O lock em memória foi apagado, e os três processos de `temp-01` agora podem discordar de tudo, menos do saldo.

O vendedor 42 tentou com três abas e recebeu "saldo insuficiente" em duas. Saque único, partida dobrada, do jeito que Pacioli queria. Aí o gerente de produto pediu um limite diário de saque ("mas é só somar os saques do dia, não?"), alguém sugeriu *repeatable read* "por segurança", e o vendedor 42 abriu a quarta aba.

## Referências

- Coffman, E. G.; Elphick, M.; Shoshani, A. *System Deadlocks*. ACM Computing Surveys 3(2), 1971. <https://doi.org/10.1145/356586.356588>
- PostgreSQL. *Explicit Locking*. <https://www.postgresql.org/docs/current/explicit-locking.html>
- PostgreSQL. *Transaction Isolation*. <https://www.postgresql.org/docs/current/transaction-iso.html>
- PostgreSQL. *deadlock_timeout*. <https://www.postgresql.org/docs/current/runtime-config-locks.html>
- Python. *threading: Lock Objects*. <https://docs.python.org/3/library/threading.html#lock-objects>
- Python. *asyncio: Synchronization Primitives*. <https://docs.python.org/3/library/asyncio-sync.html>
- PEP 703. *Making the Global Interpreter Lock Optional in CPython*. <https://peps.python.org/pep-0703/>
- MITRE. *CWE-367: Time-of-check Time-of-use (TOCTOU) Race Condition*. <https://cwe.mitre.org/data/definitions/367.html>
- Redis. *Distributed Locks with Redis*. <https://redis.io/docs/latest/develop/use/patterns/distributed-locks/>
- Kleppmann, M. *How to do distributed locking*, 2016. <https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html>
- Computerworld. *Withdrawal vulnerabilities enabled bitcoin theft from Flexcoin and Poloniex*, 2014. <https://www.computerworld.com/article/1383775/withdrawal-vulnerabilities-enabled-bitcoin-theft-from-flexcoin-and-poloniex.html>
