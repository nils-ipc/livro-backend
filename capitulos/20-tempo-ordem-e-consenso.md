# Tempo, ordem e consenso

## Meia-noite, duas vezes, com seis minutos de intervalo

A meia-noite de terça chegou duas vezes na Lastro, e as duas pagaram.

Na segunda, o fundador tinha copiado o crontab de `temp-01` para `api-02`, para dar alta disponibilidade ao `repasse_final_v2_agora_vai.py`. Deu. O relógio de `api-02` estava 3 min 40 s adiantado: o firewall que o fundador configurou ("fecha tudo menos a 443") bloqueia a porta UDP 123, e a máquina passou seis semanas sem NTP, derivando uns 60 ppm. O relógio de `temp-01` estava 2 min 10 s atrasado, porque o daemon de NTP dele morreu em algum momento do ano passado e ninguém foi ao velório.

Às 23h56min20s reais, `api-02` achou que era meia-noite e pagou os repasses automáticos de 380 vendedores. Às 00h02min10s reais, `temp-01` achou que era meia-noite e pagou de novo.

Alguém finalmente abriu o arquivo. O script gera um UUID novo para cada repasse, manda o Pix ao banco e só depois debita o ledger. Na segunda rodada, o banco recebeu IDs inéditos e pagou; o trigger do capítulo 2 recusou cada débito por saldo insuficiente; e o script capturou a exceção com um `except: pass` assinado pelo Carlos, às 2h de uma madrugada de 2024. O ledger ficou impecável. O banco pagou R$ 186.420,00 a mais. O tabelião protegeu o livro, e o dinheiro saiu pela janela do vizinho.

A conciliação das 6h achou 380 Pix de saída sem lançamento. O financeiro passou a semana ligando para vendedores. O vendedor 42 devolveu em dez minutos, com um bilhete: "dessa vez não fui eu". Ele está gostando muito da fase de vítima.

O script também gera o fechamento do dia, com `criado_em < hoje 00:00` no relógio da máquina. Saíram dois fechamentos diferentes: o de `api-02` sem os últimos 3 min 40 s de Pix, o de `temp-01` com 2 min 10 s do dia seguinte. A planilha do financeiro tinha um terceiro número, e era o certo.

A pergunta: como garantir um único executor para um job que duas máquinas querem disparar, e como decidir o que pertence a um dia, quando nenhum relógio concorda com outro?

## Relógios físicos, ou cada máquina tem a sua opinião sobre que horas são

Todo servidor conta o tempo com um cristal de quartzo, e todo cristal erra. O erro é a deriva, em partes por milhão: 1 ppm são 86 ms por dia; os 200 ppm que o Google assume como pior caso (artigo do Spanner) são 17 segundos por dia. Ela muda com a temperatura: o vizinho de rack esquentando mexe no seu.

O NTP corrige trocando quatro carimbos com um servidor de referência: o cliente envia em t1, o servidor recebe em t2 e responde em t3, o cliente recebe em t4.

```text
atraso (δ)       = (t4 − t1) − (t3 − t2)
deslocamento (θ) = ((t2 − t1) + (t3 − t4)) / 2
```

A fórmula supõe que ida e volta levam o mesmo tempo. Quando a rota é assimétrica, o erro chega a δ/2, e nada no protocolo detecta isso. Na mesma rede, o NTP costuma manter as máquinas a poucos milissegundos umas das outras; pela internet, dezenas de milissegundos. Alguns milissegundos de incerteza, garantidos por uma suposição que ninguém confere: é o horóscopo da infraestrutura, só que com RFC (a 5905).

Pior que errar é corrigir. Se o deslocamento é pequeno, o daemon acelera ou freia o relógio (*slew*, no máximo 500 ppm no ntpd). Se é grande, ele pula (*step*), para frente ou para trás. Um relógio de parede pode voltar no tempo, e um `fim - inicio` medido com ele pode dar negativo. Duração se mede com o relógio monotônico (`CLOCK_MONOTONIC`; em Python, `time.monotonic()`), que nunca volta e não significa nada fora da máquina: vale para medir intervalo, nunca para comparar com outro servidor.

E tem o segundo bissexto, que acerta o UTC com a rotação da Terra e produz 23:59:60, horário que metade do software do mundo considera ficção científica (dois casos na seção de armadilhas). Grandes provedores espalham o segundo extra ao longo de horas (*leap smear*), e a CGPM decidiu em 2022 abandonar os segundos bissextos até 2035. A humanidade desistiu de acertar o relógio com o planeta. Você vai desistir de acertar o seu com o do vizinho já já.

## Ordem sem relógio: Lamport e os vetores

Em 1978, Leslie Lamport fez a pergunta certa: para ordenar eventos, eu preciso mesmo do tempo? Ele definiu a relação **aconteceu antes** (→): a → b se a e b ocorreram no mesmo processo e a veio antes; ou se a é o envio de uma mensagem e b o recebimento dela; ou, por transitividade, se existe c com a → c e c → b. Quando nem a → b nem b → a, os eventos são **concorrentes**. Concorrente quer dizer que nenhum soube do outro, e não que aconteceram "ao mesmo tempo", conceito que, como a seção anterior mostrou, ninguém consegue medir.

O **relógio de Lamport** é um contador por processo, com três regras: incrementa a cada evento; envia o valor junto de cada mensagem; ao receber, ajusta para `max(local, recebido) + 1`. Garantia: se a → b, então L(a) < L(b). A volta não vale: L(a) < L(b) pode ser só coincidência. Para uma ordem total, desempata pelo identificador do processo. É uma ordem coerente com a causalidade, sem um único cristal de quartzo envolvido, e é por isso que o Lamport tem o prêmio Turing e o fundador tem um crontab.

Para saber se dois eventos são concorrentes, entra o **vector clock** (Fidge e Mattern, 1988): cada processo mantém um vetor com um contador por processo, incrementa a própria posição a cada evento, envia o vetor e, ao receber, faz o máximo posição a posição. a → b se e só se V(a) ≤ V(b) em toda posição e o vetor é diferente; se nenhum domina o outro, são concorrentes, e alguém precisa decidir o conflito. O Dynamo usava essa estrutura para detectar versões divergentes do carrinho (aquele, do capítulo 19, com itens zumbis). O custo é o tamanho: um contador por participante, viajando em toda mensagem.

O Spanner foi pelo caminho oposto e caro: GPS e relógios atômicos em cada data center, uma API que devolve um intervalo de incerteza em vez de um instante, e escrita que espera a incerteza passar antes de confirmar. Quem tem dinheiro compra relógio atômico. Quem tem `temp-01` usa Lamport.

## Consenso, ou como três máquinas concordam sem confiar no relógio de nenhuma

Escolher qual máquina roda o job é um caso de **consenso**: processos propõem valores e todos decidem o mesmo (acordo), o valor decidido foi proposto por alguém (validade), e todo processo que não falhou decide (terminação). Parece trivial até o capítulo 15 voltar: quem não responde pode estar morto, lento ou isolado.

Fischer, Lynch e Paterson provaram em 1985 (o resultado FLP) que, num sistema totalmente assíncrono, nenhum algoritmo determinístico garante consenso se um único processo puder falhar. Os algoritmos práticos contornam isso usando timeouts para suspeitar de falha: nunca decidem errado, e só deixam de decidir enquanto a rede se comporta pior que os timeouts. Segurança sempre, progresso quando dá. É o acordo pré-nupcial dos sistemas distribuídos.

O **Raft** (Ongaro e Ousterhout, 2014) é o algoritmo de consenso que se pode ler sem pedir licença médica. As regras:

- Cada nó é seguidor, candidato ou líder. O tempo é dividido em mandatos (*terms*) numerados, e cada número de mandato só ocorre uma vez, crescendo sempre.
- O líder manda *heartbeats*. O seguidor que passa um timeout aleatório (o artigo sugere 150 a 300 ms) sem ouvir nada vira candidato, incrementa o mandato e pede votos.
- Cada nó vota em no máximo um candidato por mandato, e só em quem tem o log pelo menos tão atualizado quanto o seu. Quem junta maioria vira líder. Duas maiorias de um mesmo grupo sempre se cruzam em ao menos um nó, então dois líderes no mesmo mandato são impossíveis.
- O líder acrescenta cada comando ao log e replica para os seguidores; o comando está confirmado (*committed*) quando a maioria o gravou, e só então é aplicado.
- Um nó que recebe mensagem com mandato maior que o seu desce a seguidor na hora. Um líder antigo que acorda de uma pausa descobre que foi deposto na primeira resposta que recebe.

```text
mandato 7:  A (líder) ── heartbeat ──▶ B, C
            A congela (pausa de GC, 12 s)
mandato 8:  B: "faz 240 ms que não ouço ninguém" → candidato
            B ── pede voto (mandato 8) ──▶ C: "seu log está em dia, voto em você"
            B: 2 de 3 → líder
            A acorda: "sou o líder do mandato 7!"
            C: "estamos no 8, querido"   → A vira seguidor
```

São `2f + 1` nós para tolerar `f` falhas: 3 aguentam 1, 5 aguentam 2. Usam Raft o etcd (o banco de configuração do Kubernetes), o Consul e o Kafka no modo KRaft; o ZooKeeper usa o ZAB, parecido. Ninguém implementa Raft na aplicação, e quem tenta passa os anos seguintes colecionando casos de borda.

## Leases e fencing tokens: o líder que não sabe que morreu

Consenso decide quem é o líder agora. O problema é que "agora" já passou quando a mensagem chega.

Um **lease** é um lock com prazo: "você é o dono até T". Se o dono morre, o lease expira e outro assume, sem ninguém precisar provar a morte. O prazo depende de os relógios andarem em ritmo parecido (a deriva, e não a hora certa), e o dono precisa ser pessimista: mede com o relógio monotônico a partir de antes de enviar o pedido, e para de agir um pouco antes do fim.

Nem assim basta. Entre "confiro que o lease vale" e "escrevo", o processo pode congelar: pausa de GC, VM migrada, `SIGSTOP`, disco que demora 40 s para devolver uma página. Ele acorda achando que ainda é dono, o lease venceu há 10 s, outro assumiu, e agora existem dois líderes, um deles zumbi com credencial de escrita. O capítulo 2 deixou isso prometido; esta é a conta.

```text
Processo 1: pega lease (token 33) ── congela 15 s ──────────────────▶ escreve (token 33) ✗ recusado
Processo 2:                  lease vence → pega lease (token 34) ─▶ escreve (token 34) ✓
Recurso:    guarda o maior token visto; recusa qualquer token menor
```

O **fencing token** é um número que cresce a cada concessão do lease, e quem confere é o recurso protegido, nunca o processo. O zumbi pode acreditar no que quiser; a escrita dele é recusada. Martin Kleppmann usou esse argumento em 2016 contra o Redlock: um lock sem token não protege nada contra pausas, por mais réplicas do Redis que se usem. O mandato do Raft, a revisão do etcd e o `zxid` do ZooKeeper servem de token.

## Na Lastro: um dono, um token e um dia que não depende de relógio

O requisito tem duas metades que brigam. O repasse automático precisa sair todo dia mesmo se `temp-01` morrer, o que pede duas máquinas. E cada repasse precisa sair exatamente uma vez, o que pede um único executor. Lease com fencing resolve as duas.

| Onde guardar o lease | Garante | Custa |
|----------------------|---------|-------|
| Lock em Redis (`SET NX PX`) | Exclusão enquanto nada pausa | Sem token natural; peça nova; o capítulo 2 já descartou |
| etcd, ZooKeeper ou Consul | Consenso real, revisão como token | Cluster de 3 nós para operar; o ledger ainda precisa conferir o token |
| Linha no primário do ledger | Token conferido na mesma transação da escrita, um só relógio (o do banco) | Disponível só enquanto o primário estiver (já é verdade para o repasse) |

A Lastro escolhe a linha no primário. O recurso a proteger é o próprio ledger, e conferir o token dentro da transação que debita é a cerca mais curta possível. A tabela `lideranca_jobs` tem `job`, `dono`, `epoca` e `expira_em`. Assumir é um `UPDATE` que só vence se o lease expirou e devolve `epoca + 1`; renovar, a cada 10 s, é um `UPDATE` que só vence se dono e época ainda são os mesmos. O prazo é 30 s, medido pelo `now()` do primário, então o relógio das máquinas não entra na conta. Quem não conseguiu renovar em 20 s, pelo monotônico, para.

E cada transação de repasse começa conferindo o token:

```sql
-- primeira linha de cada transação de repasse
SELECT epoca FROM lideranca_jobs WHERE job = 'repasse' FOR SHARE;
--  epoca
-- -------
--      8
-- token do processo = 7 → ROLLBACK: existe um dono mais novo
```

O `FOR SHARE` conflita com o `UPDATE` de quem quer assumir: a troca de dono espera os repasses em andamento, e nenhuma transação com token velho faz COMMIT depois dela. Com algumas centenas de repasses por dia, o lock não pesa.

O banco parceiro não confere tokens, então o lado de fora se protege como no capítulo 16: o ID do repasse passa a ser determinístico, `(vendedor, dia contábil)`, e o banco recusa um ID repetido. O script, finalmente aberto, vira só o agendador: cria as sagas de repasse do capítulo 18, que debitam antes de enviar o Pix. O nome do arquivo ficou. Renomear quebraria o crontab, o monitoramento e a fé.

O etcd seria a escolha certa se o recurso protegido não soubesse conferir tokens numa transação, ou se vários serviços precisassem do mesmo líder (o Kubernetes, no capítulo 35, traz leases apoiados nele). E o failover do primário (capítulo 23) vai depender de consenso para não haver dois primários.

### O dia contábil sem relógio de parede

O fechamento por `criado_em` tem dois defeitos. Um é o relógio da máquina. O outro sobrevive a qualquer NTP: no PostgreSQL, `now()` é o instante de início da transação. Uma transação que começa às 23h59min59,8s e faz COMMIT às 00h00min00,3s ganha carimbo de ontem, e uma consulta à meia-noite em ponto não a enxerga. Na consulta de amanhã, ela é de ontem. O lançamento fica órfão de dia, igual aos buracos de ID do capítulo 18.

A Lastro corta pela ordem dos commits. Toda transação do ledger pega um advisory lock compartilhado da época contábil e carimba nela `dia_contabil`, lido de `periodo_aberto`. O job de corte pega o mesmo advisory lock em modo exclusivo, o que espera as transações em andamento terminarem e segura as novas por alguns milissegundos, avança `periodo_aberto` e faz COMMIT. Tudo o que carimbou o dia D fez COMMIT antes do corte; tudo depois carimba D+1. O relógio decide só quando cortar. O que pertence ao dia é decidido pela ordem dos commits, e o fechamento do dia é `WHERE dia_contabil = D`.

```text
transações do ledger:  [T1 D]  [T2 D]  [T3 D......]          [T5 D+1]
corte (exclusivo):                      espera T3 ─▶ D+1 ─▶ COMMIT
nova transação:                              [T4 espera] ──────▶ [T4 D+1]
```

Dentro do ledger, a ordem que importa para corretude já é explícita: o estorno referencia a transação original (capítulo 1), uma relação causal registrada, sem carimbo de hora envolvido. Com um único primário ordenando todas as escritas, a Lastro não precisa de relógios de Lamport nem de vetores. Eles entram em cena quando há mais de um nó aceitando escrita, o assunto da replicação multi-líder no capítulo 23.

Por fim, NTP (o chrony, por exemplo) em todas as máquinas, porta 123 de saída liberada para os servidores de tempo, e alerta com deslocamento acima de 100 ms. O relógio sincronizado serve a logs, certificados (capítulo 10) e à hora de disparar o corte, nunca à decisão de quem é dono ou do que é de qual dia.

## Armadilhas e casos reais

> **Armadilha:** "último a escrever vence" com carimbo de relógio. Em bancos que resolvem conflito por timestamp, como o Cassandra na configuração padrão, a máquina adiantada ganha todas as discussões, inclusive com escritas que aconteceram depois dela. Um relógio 3 min 40 s adiantado vira um usuário com poder de voltar no tempo e apagar o que os outros escreveram.

> **Na vida real:** no segundo bissexto de 30 de junho de 2012, um bug no subsistema de timers do kernel Linux deixou processos em laço de CPU após a virada; sites grandes passaram a madrugada reiniciando servidores Java e MySQL, e a solução de emergência era acertar a hora na mão. Um único segundo extra, e o planeta inteiro de plantão.

> **Na vida real:** em 1º de janeiro de 2017, a Cloudflare documentou que o segundo bissexto fez o RRDNS calcular um tempo negativo e entrar em pânico ao passá-lo para `rand.Int63n`, derrubando parte das resoluções de DNS. A Go 1.9 passou a embutir uma leitura monotônica em `time.Now()`. Feliz ano-novo, e que o seu `fim - inicio` nunca dê negativo.

## Resumo

- Relógios derivam (1 ppm = 86 ms/dia); o NTP erra até δ/2 e pode pular para trás. Duração: relógio monotônico.
- Aconteceu antes: ordem causal. Lamport: a → b implica L(a) < L(b). Vector clock detecta concorrência.
- Consenso: acordo, validade, terminação; FLP; algoritmos práticos são sempre seguros e progridem quando a rede colabora.
- Raft: mandatos, eleição com maioria e log atualizado, commit por maioria, `2f + 1` nós.
- Lease: lock com prazo, dependente da deriva. Fencing token: número crescente conferido pelo recurso, que recusa o dono zumbi.
- Corte por ordem de commit, nunca por carimbo de início de transação.

## A Lastro agora

O `repasse_final_v2_agora_vai.py` roda em `temp-01` e `api-02` e virou agendador de sagas: só o dono do lease em `lideranca_jobs` age, com prazo de 30 s pelo relógio do banco, renovação a cada 10 s e a época conferida com `FOR SHARE` em cada transação de repasse. O ID de repasse é determinístico por vendedor e dia contábil. O ledger carimba `dia_contabil` sob advisory lock compartilhado, e o corte, exclusivo, fecha o dia pela ordem dos commits. Todas as máquinas têm NTP e alerta de deslocamento. O financeiro recuperou 377 dos 380 repasses em dobro; os outros três viraram linha nova na planilha, que continua sendo a única coisa da empresa com horário certo.

Enquanto isso, um chargeback de uma venda de setembro pede o estado exato da cobrança no dia 14, às 15h, e a Lastro só guarda o estado de agora. O Carlos sugeriu restaurar o backup do banco inteiro daquele dia, "rapidinho", para ler uma linha. Ele já reservou a sala e pediu pizza.

## Referências

- Leslie Lamport, "Time, Clocks, and the Ordering of Events in a Distributed System", Communications of the ACM, 1978. https://lamport.azurewebsites.net/pubs/time-clocks.pdf
- RFC 5905, Network Time Protocol Version 4. https://www.rfc-editor.org/rfc/rfc5905
- Colin Fidge, "Timestamps in Message-Passing Systems That Preserve the Partial Ordering", 1988; Friedemann Mattern, "Virtual Time and Global States of Distributed Systems", 1988.
- Michael Fischer, Nancy Lynch e Michael Paterson, "Impossibility of Distributed Consensus with One Faulty Process", Journal of the ACM, 1985. https://dl.acm.org/doi/10.1145/3149.214121
- Diego Ongaro e John Ousterhout, "In Search of an Understandable Consensus Algorithm", USENIX ATC 2014. https://raft.github.io/raft.pdf
- James C. Corbett et al., "Spanner: Google's Globally-Distributed Database", OSDI 2012. https://www.usenix.org/conference/osdi12/technical-sessions/presentation/corbett
- Martin Kleppmann, "How to do distributed locking", 2016. https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html
- Cloudflare, "How and why the leap second affected Cloudflare DNS", 2017. https://blog.cloudflare.com/how-and-why-the-leap-second-affected-cloudflare-dns/
- BIPM, Resolução 4 da 27ª CGPM (2022), sobre o uso do UTC. https://www.bipm.org/en/cgpm-2022/resolution-4
- PostgreSQL 16, Explicit Locking (advisory locks e locks de linha). https://www.postgresql.org/docs/16/explicit-locking.html
- PostgreSQL 16, Date/Time Functions (`now()` e início da transação). https://www.postgresql.org/docs/16/functions-datetime.html
