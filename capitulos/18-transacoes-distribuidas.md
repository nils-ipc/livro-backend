# Transações distribuídas

## Terça, 16h00min03s: o Pix existe, o evento não

Na terça às 16h00min03s, o deploy reiniciou um worker no intervalo mais caro da computação: entre o COMMIT e a linha seguinte.

O COMMIT gravou um Pix de R$ 870,00 no ledger, com split, tarifa e tudo. A linha seguinte publicaria o evento `cobranca.paga` no tópico do capítulo 17. Ela nunca rodou. O `NOTIFY` do capítulo 12 sai junto com o COMMIT, então o checkout mostrou "Pagamento confirmado!" para o comprador, com confete. O backend do Bazar, que só sabe do pagamento pelo webhook, não recebeu nada e, 30 minutos depois, cancelou o pedido por falta de pagamento. O comprador tem o comprovante, a tela de confete e um e-mail de "pedido cancelado". O chamado do Bazar: "URGENTE!!!! O CLIENTE VIU PAGO E A GENTE VIU NADA".

O Carlos propôs inverter: publicar antes do COMMIT. No ambiente de homologação, a transação de um pagamento falhou depois da publicação (o trigger de soma zero do capítulo 1 pegou um split com um centavo sobrando), o ROLLBACK apagou o pagamento, e o evento já tinha saído. O Bazar de homologação despachou 14 fones de ouvido de graça. Num ambiente de mentira, felizmente; o Carlos agora tem um prejuízo imaginário de R$ 4.898,60 no currículo.

E tem o terceiro caso, que já estava lá desde o capítulo 2. O saque debita o ledger, faz COMMIT e depois chama o banco parceiro. Na mesma terça, outro worker morreu no meio desse "depois": o vendedor 42 teve R$ 300,00 debitados e nenhum Pix enviado. Pela primeira vez na história deste livro, o vendedor 42 tem razão, e ele está aproveitando cada segundo.

A pergunta do capítulo: como dois sistemas que não compartilham uma transação concordam sobre o que aconteceu?

## A escrita dupla, ou duas linhas de código que não podem ser atômicas

O problema tem nome: **escrita dupla** (*dual write*). Uma operação precisa mudar o estado de dois sistemas (banco e broker, banco e banco parceiro, banco e adquirente), e não existe uma transação que cubra os dois. Qualquer ordem que você escolha tem uma janela em que o processo pode morrer:

| Ordem | Morre entre as duas escritas | Resultado |
|-------|------------------------------|-----------|
| Banco, depois broker | Depois do COMMIT | Pagamento sem evento (a terça) |
| Broker, depois banco | Antes do COMMIT, ou o COMMIT falha | Evento sem pagamento (os fones) |
| Banco, depois parceiro | Depois do COMMIT | Débito sem Pix (o vendedor 42) |
| Parceiro, depois banco | Depois da resposta do parceiro | Pix enviado sem débito, e o 42 descobre |

O retry não fecha a janela, porque o processo que ia repetir é o que morreu. O try/except também não, porque `kill -9` não executa `finally`; ele não dá direito a últimas palavras. A janela é pequena, alguns milissegundos por operação, e por isso é traiçoeira: com 25 mil cobranças por dia e um deploy diário que recicla 9 workers, ela acontece algumas vezes por mês, sempre em produção, sempre com o Bazar.

Existem duas famílias de solução. Uma tenta tornar as duas escritas atômicas de verdade: o two-phase commit. A outra desiste da atomicidade e garante que o sistema **converge**: sagas, outbox e, no fim de tudo, a conciliação.

## Two-phase commit, o protocolo que faz todo mundo esperar de mão levantada

O **two-phase commit** (2PC) coloca um **coordenador** acima dos **participantes**:

```text
Fase 1 (prepare)   coordenador -> participantes: "PREPARE T"
                   cada participante grava tudo de forma durável,
                   segura os locks e responde SIM ou NÃO
Fase 2 (decisão)   todos SIM  -> coordenador grava COMMIT no log dele, avisa todos
                   algum NÃO  -> coordenador grava ABORT, avisa todos
```

O ponto do protocolo é o voto: quem votou SIM perdeu o direito de desistir. Está pronto para commitar e proibido de abortar por conta própria até ouvir a decisão. Se o coordenador morre depois dos votos e antes de mandar a decisão, os participantes ficam **em dúvida** (*in doubt*): não sabem se os outros commitaram, então não podem commitar nem abortar, e seguram os locks até o coordenador voltar. É isso que significa dizer que o 2PC é **bloqueante**. A disponibilidade da operação vira o produto da disponibilidade de todos os participantes e do coordenador, e um coordenador que demora uma hora para voltar segura linhas por uma hora. Variantes como o three-phase commit evitam o bloqueio só com suposições sobre a rede (atraso limitado) que redes reais não garantem.

O PostgreSQL implementa o papel de participante: `PREPARE TRANSACTION 'id'` faz a fase 1, e `COMMIT PREPARED 'id'` ou `ROLLBACK PREPARED 'id'` faz a fase 2. Vem desligado: `max_prepared_transactions` vale 0 por padrão. Uma transação preparada sobrevive a reinício, segura os locks e impede o VACUUM de limpar qualquer tupla mais nova que ela. Uma preparada esquecida em `pg_prepared_xacts` é uma transação longa (capítulo 3) que não morre nem com reboot, um morto-vivo com atestado de imortalidade. O padrão que padroniza o protocolo entre gerenciadores de transação é o XA.

Para a Lastro, o 2PC tem um defeito anterior a todos esses: os participantes precisam implementar o protocolo. O PostgreSQL implementa. O broker de log da Lastro, não; as transações do Kafka são atômicas entre partições do próprio Kafka e não participam de XA com um banco externo. O adquirente e o banco do Pix são APIs HTTP. Ninguém vai mandar `PREPARE` para o Banco Central e esperar ele votar.

```text
Coordenador: PREPARE?
PostgreSQL:  SIM. Gravei tudo, travei as linhas, aguardo.
Outro banco: SIM.
Coordenador: Então eu dec... (kill -9)
PostgreSQL:  (seis horas depois, segurando as mesmas linhas) Alguém?
Carlos:      Posso dar um ROLLBACK PREPARED?
PostgreSQL:  Pode. Se o outro commitou, você inventou a escrita dupla com mais passos.
```

> **Na vida real:** o 2PC funciona bem dentro de um banco distribuído. O Spanner, do Google, faz 2PC entre grupos de réplicas em que cada participante é replicado por Paxos, então um participante "em dúvida" raramente fica indisponível.

## Sagas, ou desfazer em vez de não fazer

Uma **saga** (Garcia-Molina e Salem, 1987) divide a operação longa numa sequência de **transações locais** T1, T2, ..., Tn, cada uma commitada no seu sistema. Para cada Ti, exceto a última, existe uma **compensação** Ci, que desfaz semanticamente o efeito de Ti. Se Tk falha de vez, a saga executa Ck−1, ..., C1, na ordem inversa.

A compensação desfaz pelo significado: ninguém apaga o lançamento do débito; um lançamento novo devolve o valor. O ledger da Lastro faz isso desde o capítulo 1 (estorno é uma transação nova invertida) e, portanto, a Lastro escrevia compensações antes de saber o nome. O tabelião aprova: nada se apaga, tudo se registra de novo, ao contrário.

Três tipos de passo organizam a saga:

- **Compensáveis**: têm Ci. Ficam antes do pivô.
- **Pivô**: o ponto sem volta. Depois dele, a saga só termina para a frente. Um Pix enviado e aceito pelo banco é irrevogável; o arranjo prevê devolução, mas ela é outra operação, iniciada pelo recebedor.
- **Repetíveis**: depois do pivô, precisam dar certo eventualmente, então são idempotentes (capítulo 16) e repetidos até dar certo.

O preço da saga é o **I** do ACID. Os estados intermediários ficam visíveis para todo mundo: entre T1 e T3, outra operação pode ler o saldo já debitado e o Pix ainda não enviado. As contramedidas são de projeto. O **lock semântico** é um estado explícito (`enviando`, `capturando`) que outras operações respeitam. As **atualizações comutativas** são mudanças que podem ser aplicadas em qualquer ordem, como lançamentos que só somam. Sem elas, a saga produz as anomalias do capítulo 3, só que agora entre sistemas, sem SSI para salvar ninguém.

Quem decide o próximo passo? Duas formas:

| | Orquestração | Coreografia |
|---|---|---|
| Lógica do fluxo | Num orquestrador, uma máquina de estados persistida | Espalhada: cada serviço reage a eventos e publica os seus |
| Estado da saga | Uma linha, consultável | Reconstruído juntando eventos de vários serviços |
| Acoplamento | Orquestrador conhece todos os passos | Serviços conhecem só eventos |
| Risco típico | Orquestrador vira deus de tudo | Ciclo de eventos que ninguém desenhou |
| Bom para | Fluxos com compensação e prazos | Reações independentes, sem desfazer nada |

Coreografia com compensação é a forma mais distribuída de ninguém saber por que o dinheiro voltou.

## Outbox e CDC: o evento entra na mesma transação

Sobrou a escrita dupla banco + broker. O **padrão outbox** resolve sem 2PC: em vez de publicar, a transação local **grava o evento numa tabela** (a *outbox*) junto com a mudança de estado. Um COMMIT, um sistema, atomicidade de verdade: ou existem o pagamento e o evento, ou nenhum dos dois. Um processo separado, o **relay**, lê a outbox e publica no broker. Se o relay morre depois de publicar e antes de registrar que publicou, publica de novo: at-least-once, e o consumidor deduplica pelo ID do evento (capítulo 16). A janela não sumiu; foi movida para um lugar onde o pior resultado é uma duplicata.

O relay lê a outbox de dois jeitos.

**Polling**: consulta periódica pelas linhas não publicadas. Simples e com uma armadilha mecânica: quem lê "tudo com `id` maior que o último que publiquei" perde eventos, porque os IDs seguem a ordem do `nextval`, e os COMMITs seguem a ordem que quiserem.

```text
t1  tx A: INSERT outbox, id 100    (ainda sem COMMIT)
t2  tx B: INSERT outbox, id 101, COMMIT
t3  relay: lê id > 99, vê só 101, publica, salva "último = 101"
t4  tx A: COMMIT
t5  relay: lê id > 101. O 100 nunca mais será visto.
```

O polling correto marca cada linha (`publicado_em`) ou a apaga depois de publicar, o que custa uma escrita a mais por evento no banco de origem.

**CDC** (*change data capture*): o relay lê o log de escrita do banco. No PostgreSQL, com `wal_level = logical`, a **decodificação lógica** transforma o WAL em mudanças por linha, entregues por um **slot de replicação** na ordem do COMMIT, e a *publication* restringe quais tabelas saem. O Debezium é o exemplo de referência de conector, com um roteador específico para outbox. Sem consulta repetida e sem escrita a mais. O custo é operacional: o slot guarda o WAL até o consumidor confirmar, então um conector parado faz o disco do primário encher sem parar. O `max_slot_wal_keep_size` (PostgreSQL 13+) limita esse acúmulo invalidando o slot, e um slot invalidado perde o ponto de leitura. E até o PostgreSQL 16, o slot lógico não sobrevive a um failover para a réplica; o 17 passou a sincronizá-lo.

Fazer CDC direto das tabelas internas (cobranças, lançamentos) também funciona, e publica o seu schema interno como contrato. A Lei de Hyrum do capítulo 11 chega em dez dias. A outbox é o contrato explícito: o evento tem o formato que você escolheu.

## Conciliação: a verificação que não confia em ninguém

Outbox e sagas fecham as janelas que a Lastro conhece. A **conciliação** pega as que ela não conhece: bug no orquestrador, parceiro que confirmou e não fez, arquivo que diz outra coisa. É uma comparação periódica entre o estado registrado pela Lastro e o estado declarado por cada parceiro, casando registro a registro por uma chave comum, e classificando o que não casa.

Ela funciona porque não depende de nenhum mecanismo que possa ter falhado: o arquivo do adquirente nem sabe que a saga existe. É a única peça que parte do princípio de que todo o resto mentiu, e nisso o financeiro e a planilha dele estavam certos desde o capítulo 1. Eles nunca vão deixar você esquecer.

## Na Lastro: outbox, duas sagas e um arquivo às 6h

**Outbox com CDC.** Toda transação que muda o estado de uma cobrança ou de um repasse grava uma linha em `eventos_saida`, no mesmo COMMIT: `id` (o `evt_` UUIDv7 do envelope), `chave` (`cobranca_id` ou `repasse_id`), `tipo`, `payload` (o envelope do capítulo 11). Um conector CDC lê uma publication só com `eventos_saida` e publica em `cobrancas.eventos` (e no tópico novo `repasses.eventos`) com a chave da linha. A API não fala mais com o broker.

A escolha do CDC sobre o polling vem do recurso mais disputado da Lastro, o primário do ledger (capítulos 4 e 14): o polling acrescentaria uma escrita por evento, 500 por segundo no pico da Black Friday, mais consultas a cada fração de segundo, e o CDC não acrescenta nenhuma. O CDC também entrega na ordem do COMMIT, que a chave por cobrança aproveita. Os custos assumidos:

- `wal_level = logical` exige reiniciar o PostgreSQL. Foram 14 segundos de banco fora numa madrugada de quarta, com retry nos clientes (capítulo 15) e o financeiro avisado por escrito, em três vias.
- Alerta quando o slot retém mais de 5 GB de WAL; `max_slot_wal_keep_size` em 50 GB, abaixo do disco livre.
- `eventos_saida` guarda 7 dias, apagados em lotes diários (capítulo 7). Slot perdido (invalidação ou failover) se recupera republicando a outbox a partir do último evento que chegou ao tópico. Duplicatas são problema do `id`, que os consumidores já deduplicam.

Com poucos eventos por segundo e um banco sem decodificação lógica (alguns serviços gerenciados limitam isso), o polling com `publicado_em` seria a escolha, ao custo de escrita no primário.

**A saga do repasse**, orquestrada, com o estado na linha de `repasses`:

```text
T1 (local, 1 COMMIT)  débito: disponível do vendedor -> repasses_em_transito
                      estado = enviando; evento repasse.criado na outbox
T2 (banco parceiro)   Pix com o ID do repasse (idempotente, cap. 16)
        aceito ──────► PIVÔ. T3 (local): em_transito -> conta do liquidante,
        │              estado = enviado; evento repasse.enviado
        recusado ────► C1 (local): em_transito -> disponível do vendedor,
        │              estado = falhou; evento repasse.falhou
        sem resposta ► consulta pelo ID com backoff (cap. 15); decide aceito/recusado
```

A conta `repasses_em_transito` é o lock semântico: o dinheiro saiu do disponível em T1, então o vendedor 42 não consegue sacar o mesmo valor duas vezes enquanto o banco pensa, nem com a sétima aba. O ledger soma zero em todos os estados intermediários. T3 é repetível: depois do pivô, só para a frente.

**A saga do pagamento com cartão.** O processo de resolução do capítulo 15 vira o orquestrador das duas sagas: escolhe com `SKIP LOCKED` as linhas com `proxima_acao_em` vencida e executa o passo seguinte. A autorização é compensável (o desfazimento do capítulo 15). O pivô é a captura. Depois dela, os lançamentos de saldo a liberar e o evento são repetíveis, num COMMIT só, com outbox. Desfazer uma cobrança capturada é o estorno: uma saga própria com um lançamento invertido local e o estorno no adquirente, cada passo com a referência da cobrança.

Orquestração porque os dois fluxos têm compensação, prazos e precisam responder "em que passo está o repasse 88.412?" com uma consulta, que é o que o chargeback e a conciliação perguntam. Coreografia fica para quem só reage: webhooks, Vigia e a própria conciliação, que consomem eventos e não desfazem nada.

**A conciliação diária**, às 6h, depois da chegada do arquivo do adquirente (transações e liquidações do dia anterior) e do extrato do banco liquidante:

| Classe | Chave | Exemplo | Ação |
|--------|-------|---------|------|
| Casou | referência, EndToEndId, ID do repasse | Quase tudo | Nenhuma |
| Só no parceiro | Referência | Captura que a Lastro registra como `recusada` (os 412 da Black Friday) | Estorno automático pela saga, com alerta |
| Só na Lastro | Referência | Captura sem registro no adquirente | Consulta ao adquirente; se confirmar, fila manual |
| Valor diferente | Referência | MDR descontado diferente do contratado | Fila manual do financeiro |
| Estado sem efeito | ID do repasse | Repasse `enviando` há mais de 24 h | Orquestrador acordado, alerta |
| Evento sem entrega | `evt_` | `cobranca.paga` sem entrega concluída em 3 dias | Lista no painel do marketplace |

Num dia comum, com 25 mil cobranças, sobram algumas dezenas de linhas fora de "casou". A fila manual tem interface web. O financeiro exporta a fila para uma planilha.

## Armadilhas e casos reais

> **Armadilha:** compensação que pode falhar. Se C1 depende de um parceiro fora do ar, a saga fica parada no meio, num estado que nenhum desenho previu. Compensações precisam ser repetíveis e idempotentes, igual aos passos depois do pivô. A da Lastro é local de propósito.

> **Armadilha:** saga sem estado persistido. O orquestrador que guarda "em que passo estou" em memória perde a saga no primeiro reload, e reload é o que causou este capítulo inteiro.

> **Armadilha:** slot de replicação esquecido. Um conector CDC desligado "só para testar" no ambiente de homologação segura o WAL até o disco acabar. Em homologação, o Carlos descobriu num sábado. O disco tinha 200 GB e durou 11 dias.

> **Armadilha:** achar que a outbox garante o efeito. Ela garante que o evento sai; se o Bazar fez algo com ele, só a DLQ do capítulo 17 e a conciliação contam.

> **Na vida real:** Pat Helland, em "Life beyond Distributed Transactions" (2007), descreveu como sistemas grandes abandonam transações distribuídas: entidades atualizadas atomicamente uma de cada vez, mensagens entre elas com entrega at-least-once, idempotência no destino e "atividades" que guardam o que cada parceiro já respondeu. É a Lastro deste capítulo, descrita antes de o fundador saber programar.

## Resumo

- Escrita dupla: dois sistemas sem transação comum; toda ordem tem uma janela de falha, e retry não a fecha.
- 2PC: quem votou SIM espera a decisão segurando locks; bloqueante, e só entre participantes que implementam o protocolo.
- Saga: transações locais com compensações semânticas; compensáveis, pivô, repetíveis; sem isolamento, com lock semântico e atualizações comutativas.
- Orquestração para fluxos com compensação e prazo; coreografia para reações independentes.
- Outbox: evento na mesma transação; relay por polling (cuidado com a ordem dos IDs) ou CDC (decodificação lógica, slot que retém WAL); at-least-once com deduplicação.
- Conciliação: verificação independente contra os parceiros, que pega o que os mecanismos deixaram passar.

## A Lastro agora

Eventos saem pela outbox `eventos_saida`, lida por CDC num slot lógico, com alerta de WAL retido e recuperação pela própria tabela. Repasse e pagamento com cartão são sagas orquestradas pelo antigo processo de resolução, com a conta `repasses_em_transito` como lock semântico, a captura e o Pix aceito como pivôs, e o estorno como compensação. A conciliação das 6h casa o ledger com o adquirente e o banco liquidante e manda o que não casa para uma fila com interface web. O vendedor 42 recebeu os R$ 300,00 de volta pela C1, com lançamento e tudo, e está decepcionado: ele queria uma história melhor.

O `repasse_final_v2_agora_vai.py` continua no crontab de `temp-01`, com a cópia própria do código e sem saga nenhuma, porque ninguém teve coragem de abrir o arquivo. Na sexta, o vendedor 42 viu no painel R$ 870,00 de saldo disponível, clicou em sacar e recebeu `saldo-insuficiente`. Os dois números estavam certos. Só não estavam certos ao mesmo tempo.

## Referências

- Hector Garcia-Molina e Kenneth Salem, "Sagas", ACM SIGMOD, 1987. https://dl.acm.org/doi/10.1145/38713.38742
- Pat Helland, "Life beyond Distributed Transactions: an Apostate's Opinion", CIDR 2007. https://www.cidrdb.org/cidr2007/papers/cidr07p15.pdf
- PostgreSQL 16, `PREPARE TRANSACTION`. https://www.postgresql.org/docs/16/sql-prepare-transaction.html
- PostgreSQL 16, Logical Decoding. https://www.postgresql.org/docs/16/logicaldecoding.html
- PostgreSQL 17, Logical Replication Failover. https://www.postgresql.org/docs/17/logical-replication-failover.html
- Debezium, Outbox Event Router. https://debezium.io/documentation/reference/stable/transformations/outbox-event-router.html
- James C. Corbett et al., "Spanner: Google's Globally-Distributed Database", OSDI 2012. https://www.usenix.org/conference/osdi12/technical-sessions/presentation/corbett
- Chris Richardson, padrões Saga e Transactional Outbox. https://microservices.io/patterns/data/saga.html
