# Replicação

O PR do Carlos para "cachear o relatório mensal por 30 dias" foi aprovado, foi para produção e, no dia 1º às 9h, atingiu a taxa de acerto prevista: zero. Os 41 relatórios dos marketplaces rodaram no primário do ledger, agora em paralelo, porque o Carlos aproveitou o PR para "acelerar a geração": 41 processos lendo um mês de lançamentos num PostgreSQL de 8 núcleos que também registrava o Pix das 9h de uma segunda-feira.

Os relatórios expulsaram do cache do banco as páginas quentes dos índices do ledger. O INSERT de lançamento, que levava 0,13 ms (capítulo 5), passou a esperar disco e chegou a 9 ms, e a posse do lock nos baldes das contas quentes (capítulo 4) foi junto. A autorização subiu de p99 1,3 s para 2,4 s, e o Bazar abriu o chamado às 9h07, com uma exclamação por relatório ainda rodando.

No meio do incidente, o fundador perguntou: "e se esse servidor morrer?". A resposta oficial era o backup das 3h, restaurado em seis horas (capítulo 21): até um dia de lançamentos perdidos e uma manhã sem Pix. O financeiro foi buscar um copo d'água, que ninguém acredita que era água.

Os dois problemas pedem mais de uma cópia do banco. O que custa mantê-las iguais, e o que acontece com o dinheiro enquanto não estão?

## Primário e réplica, ou quem manda e quem copia

**Replicação** é manter cópias dos mesmos dados em mais de uma máquina, para escalar leitura, sobreviver à perda de uma máquina ou ler perto do usuário. Na **replicação com líder**, o **primário** aceita todas as escritas e envia as mudanças às **réplicas** (no PostgreSQL, *standbys*), que só leem. O mercado chamou isso de *master* e *slave* por décadas e trocou os nomes. A relação continua a mesma: um manda, o outro repete tudo, na mesma ordem, sem direito a opinião.

A questão técnica é o que o primário envia:

- **Comandos** (*statement-based*): o SQL. Barato, até o comando ser não determinístico. O MySQL classifica como inseguros para esse modo um `UUID()` ou um `UPDATE ... LIMIT` sem `ORDER BY`: cada réplica gera os seus UUIDs, escolhe as suas linhas, e as cópias divergem em silêncio. Replicação com fé.
- **Log físico**: o **WAL**, o log que ele já grava para sobreviver a uma queda (capítulo 3). Descreve bytes em páginas, e a réplica vira uma cópia idêntica, página por página.
- **Log lógico**: o WAL decodificado em mudanças por linha, como o CDC do capítulo 18 já faz para a outbox.

No PostgreSQL, a física é a **streaming replication**: o `walsender` envia o WAL por TCP, o `walreceiver` grava, e o `startup` reaplica como na recuperação de uma queda. A réplica é um banco se recuperando de um crash para sempre. Com `hot_standby = on` (padrão desde a versão 10), aceita leituras durante essa convalescença eterna.

Cada posição no WAL é um **LSN** (*log sequence number*), um deslocamento em bytes escrito como `0/3A2B1C8`. É o relógio lógico do banco (capítulo 20), e a distância entre o LSN do primário e o aplicado na réplica é o atraso dela.

A cópia física leva o cluster inteiro, exige a mesma versão principal e recusa qualquer escrita. A **replicação lógica** (publication e subscription, PostgreSQL 10+) leva tabelas escolhidas, entre versões diferentes, para um banco que também escreve, mas até o PostgreSQL 17 não replica DDL nem o valor das sequências. Esqueça a sequência e, quando o destino virar primário, o próximo `INSERT` tenta o ID 1. O tabelião do capítulo 1 pede demissão.

## Síncrona ou assíncrona, ou quanto tempo o COMMIT espera pela réplica

Perder dinheiro numa falha depende de quando o primário responde "COMMIT".

Na **replicação assíncrona**, o primário grava o WAL no próprio disco, responde e envia para a réplica quando der. Se morrer entre responder e enviar, a réplica promovida nunca ouviu falar da transação. O cliente tem recibo de uma transação que o banco novo desconhece: perda de dado com papel timbrado.

Na **replicação síncrona**, o primário só responde depois que pelo menos uma réplica confirma ter recebido. Ele não termina enquanto o parceiro não confirma que também chegou lá. Cada COMMIT paga uma ida e volta de rede, e o primário passa a depender da réplica para escrever.

No PostgreSQL, `synchronous_standby_names` diz quais réplicas contam:

```text
synchronous_standby_names = 'ANY 1 (pg_ledger_2, pg_ledger_3)'
```

`ANY 1` é o **commit por quórum** (PostgreSQL 10+): basta uma confirmar. E `synchronous_commit`, ajustável por transação, diz o que ela confirma:

| `synchronous_commit` | O COMMIT espera | Perde transação confirmada se |
|---|---|---|
| `off` | nada, nem o disco local (capítulo 3) | o primário cai |
| `local` | disco do primário | o primário cai antes de enviar |
| `remote_write` | réplica entregou o WAL ao sistema operacional | primário e sistema operacional da réplica caem juntos |
| `on` | réplica gravou o WAL no disco (fsync) | primário e réplica perdem o disco juntos |
| `remote_apply` | réplica aplicou: a transação já é visível lá | idem `on` |

Se nenhuma réplica síncrona responde, o PostgreSQL não troca para assíncrono: o COMMIT espera para sempre. É o C do CAP (capítulo 19) sem frescura. E se você cancelar a espera:

```text
WARNING:  canceling wait for synchronous replication due to user request
DETAIL:  The transaction has already committed locally, but might not
         have been replicated to the standby.
```

A transação já está no disco do primário; cancelar só a torna visível sem a garantia que você pagou para ter. "Eu fiz, só não posso provar." Com uma réplica síncrona só, cada manutenção dela congela as escritas; daí o quórum com duas.

Com a réplica a 1 ms e fsync de ~0,5 ms, o COMMIT ganha ~1,5 ms, e os locks só são liberados depois da espera: toda conta quente fica 1,5 ms mais quente.

## Lag de replicação, ou a réplica que vive no passado

Mesmo na síncrona com `on`, a réplica aplica o WAL depois de gravá-lo: é o **lag de replicação**, em geral milissegundos. Mas o `startup` aplica num processo só, o primário escreve com dezenas de conexões, e qualquer rajada (backfill, `CREATE INDEX`, limpeza da outbox) vira fila. O primário escreve com 40 mãos e a réplica copia com uma.

O `pg_stat_replication` mostra o lag de cada réplica:

```text
 application_name |   state   | sync_state |   flush_lag     |   replay_lag
------------------+-----------+------------+-----------------+-----------------
 pg_ledger_2      | streaming | quorum     | 00:00:00.00114  | 00:00:00.00187
 pg_ledger_3      | streaming | quorum     | 00:00:00.00121  | 00:00:00.00203
 pg_ledger_relat  | streaming | async      | 00:00:00.00098  | 00:04:12.84117
```

A terceira linha vive quatro minutos no passado, por motivos que o Carlos vai explicar.

O VACUUM do primário remove versões mortas de linha (capítulo 3) e manda a remoção pelo WAL. Se uma consulta longa na réplica ainda precisa delas, o `startup` espera, e o lag cresce, até `max_standby_streaming_delay` (30 s por padrão). Depois, executa a consulta:

```text
ERROR:  canceling statement due to conflict with recovery
DETAIL:  User query might have needed to see row versions that must be removed.
```

Com `hot_standby_feedback = on`, a réplica avisa ao primário quais versões ainda usa, e o VACUUM passa a respeitar consultas de outra máquina: a consulta sobrevive e o primário incha pelo tempo que ela durar. As vítimas possíveis são a consulta, a atualidade da réplica ou o tamanho do primário. Não existe "nenhuma das anteriores", e o Carlos procurou.

## Ler o que você acabou de escrever

O **read-your-writes** do capítulo 19 some com uma réplica atrasada, sem ninguém mexer no código: o vendedor saca, a tela seguinte lê na réplica, e lá o saque ainda não aconteceu. O vendedor 42 lê isso como convite. Três técnicas:

1. **Ler do primário por alguns segundos após escrever.** Falha quando o lag passa do prazo, justamente quando importa.
2. **`remote_apply` na escrita.** Vale só na réplica síncrona, com o COMMIT esperando o replay.
3. **Token de posição.** Após o COMMIT, a aplicação guarda `pg_current_wal_lsn()` do primário como posição mínima que o usuário precisa ver, e confere a réplica antes de ler:

```sql
SELECT pg_last_wal_replay_lsn() >= '0/3A2B1C8'::pg_lsn AS pode_ler;
-- pode_ler: f  (a réplica ainda não viu o saque; espere ou leia do primário)
```

O token também dá **leituras monotônicas**: o cliente guarda o maior LSN que já viu e recusa réplica abaixo dele. Sem isso, duas réplicas seguidas fazem o saque aparecer e sumir, e o saldo pisca como o letreiro de motel do capítulo 19.

## Failover, split-brain e como aposentar um primário à força

**Failover** é promover uma réplica quando o primário morre. O comando (`pg_promote()`, PostgreSQL 12+) é a parte fácil. O processo:

1. **Detectar** que o primário parou, ou que a rede até ele parou, o que daqui é idêntico (capítulo 15).
2. **Escolher** a réplica com o maior LSN recebido.
3. **Promover** e **redirecionar os clientes**: DNS com TTL baixo (capítulo 8), IP virtual, proxy ou cliente com vários hosts.
4. **Impedir que o antigo volte a aceitar escrita.** O passo que derruba empresas.

Se o antigo estava só isolado, há dois primários aceitando escritas que o outro não vê: o **split-brain**. Dois ledgers legítimos, e nenhum `merge` decide qual saque vale. O banco ganha um segundo cérebro, e os dois gastam o mesmo dinheiro.

Decidir o primário é consenso (capítulo 20), e com dois nós, numa partição, cada lado acha que o outro morreu. O padrão é guardar a liderança num armazenamento com consenso (etcd, Consul ou ZooKeeper). No PostgreSQL, o exemplo de referência é o Patroni: o primário renova uma chave de líder com TTL (30 s por padrão) e, se não consegue, rebaixa a si mesmo; um watchdog reinicia a máquina se o Patroni travar. É o lease do capítulo 20: quem perde o lease se mata antes que alguém precise matá-lo. A literatura chama a última instância de STONITH, *shoot the other node in the head*. Alta disponibilidade sempre teve humor de pistoleiro.

O primário antigo volta com WAL que o novo nunca recebeu. O `pg_rewind` descarta os blocos divergentes e o religa como réplica. Se algum cliente recebeu COMMIT por aquelas transações, você perdeu dado confirmado e vai saber pela conciliação.

## Multi-líder e sem líder, ou democracia na escrita

Na **replicação multi-líder**, vários nós aceitam escrita (um por região ou por dispositivo offline) e trocam mudanças de forma assíncrona. O preço são **conflitos**: duas regiões alteram a mesma linha ao mesmo tempo. *Last write wins* descarta uma escrita confirmada com base num relógio que deriva (capítulo 20); fusão exige estruturas que comutam, como CRDTs (capítulo 19); rotear cada registro sempre ao mesmo líder reinventa o líder único com mais passos. Num ledger, conflito resolvido por relógio é saque dobrado com carimbo de data.

Na **replicação sem líder** (o Dynamo da Amazon, seguido por Cassandra e Riak), o cliente escreve em várias réplicas. Com **N** réplicas por chave, a escrita vale quando **W** confirmam, e a leitura consulta **R** e fica com a versão mais nova. Se `W + R > N`, todo conjunto de leitura cruza todo conjunto de escrita: é o **quórum**. Com N = 3, W = 2 e R = 2, uma réplica pode estar fora.

Réplicas atrasadas se atualizam por **read repair** (a leitura que achou versão velha regrava a nova) e por **anti-entropia** (comparação de árvores de Merkle). Com o **quórum relaxado** do Dynamo, a escrita vai para réplicas que não são donas da chave (*hinted handoff*), e o `W + R > N` deixa de garantir interseção. E nem o quórum estrito dá linearizabilidade: escritas concorrentes resolvidas por relógio e uma escrita que falhou numa réplica e venceu em outra cabem dentro dele. É uma democracia em que todo mundo vota e cada um conta os votos do seu jeito.

## Na Lastro: três cópias, um primário e nenhuma dúvida sobre quem manda

Os requisitos: nenhum lançamento confirmado some num failover; o Pix é 24x7, então a troca de primário leva segundos, e não as seis horas do backup; e os relatórios do dia 1º não tocam no primário.

| Opção | Perda num failover | Custo no COMMIT | Operação |
|---|---|---|---|
| Física assíncrona | últimos ms a s | nenhum | baixa |
| Física síncrona, 1 réplica | zero | ~1,5 ms | réplica parada congela o ledger |
| Física síncrona, `ANY 1` de 2 | zero | ~1,5 ms | 3 máquinas + consenso |
| Lógica | últimos ms a s + sequências | nenhum | DDL à mão |
| Multi-líder / sem líder | conflito resolvido por relógio | baixo | sem ordem única |

Multi-líder e sem líder saem porque o lock da conta, o serializable e o dia contábil dependem de uma ordem única (capítulos 2, 3 e 20); a assíncrona, pelo primeiro requisito. Fica o quórum síncrono, com as zonas (partes isoladas da região, capítulo 36) a ~1 ms:

```text
            etcd (3 nós, 1 por zona) guarda a chave de líder
                 |
   zona A        |         zona B              zona C
 +--------------------+  +--------------+  +--------------+
 | pg-ledger-1        |  | pg-ledger-2  |  | pg-ledger-3  |
 | PRIMÁRIO           |->| standby      |  | standby      |
 | Patroni            |  | síncrono*    |  | síncrono*    |
 +--------------------+  +--------------+  +--------------+
        |          * ANY 1: basta um confirmar
        +--> pg-ledger-relat (zona A, assíncrono, nunca promovido)
```

- **Quórum síncrono** `ANY 1` com `synchronous_commit = on`: todo COMMIT está em disco em duas zonas antes de o cliente saber dele, e uma réplica pode parar sem congelar o ledger.
- **Modo estrito** (`synchronous_mode_strict` do Patroni): sem nenhuma réplica, o Patroni não rebaixa para assíncrono, e débitos e pagamentos recebem `503`. A escolha do capítulo 19: o painel pode mentir um pouco, o ledger não.
- **Failover automático** só para réplica síncrona, em 30 a 40 s. A aplicação usa a lista de hosts do libpq com `target_session_attrs=read-write`, que procura o primário.
- **Cerca de graça**: um primário antigo isolado não confirma nada, porque nenhuma réplica responde mais a ele. O modo estrito vira o fencing token do capítulo 20, sem uma linha de código.
- **Contas quentes**: a posse do lock no balde sobe de ~2 para ~3,5 ms, e o teto por conta cai de 8.000 para ~4.500 créditos por segundo, contra ~200 da comissão do Bazar no pico (capítulo 14).
- **CDC da outbox**: no PostgreSQL 16, o slot lógico se perde no failover (recuperação do capítulo 18), e a decodificação pode publicar uma transação que nenhuma réplica confirmou: se o primário morrer nesse instante, o evento existe e o lançamento não. O PostgreSQL 17 fecha isso com `synchronized_standby_slots`; a migração para o 17, por replicação lógica, entra no planejamento, e até lá a conciliação das 6h pega o caso.

Os relatórios foram para `pg-ledger-relat`, assíncrona e marcada `nofailover`, com a configuração padrão. Aos 30 segundos, o `startup` cancelou 41 relatórios de 40 segundos; o agendador repetiu, e às 9h05 eram 380 cancelamentos, Sísifo com cron. O Carlos ligou o `hot_standby_feedback`, e o primário começou a inchar. A configuração final, só nessa réplica: `max_standby_streaming_delay = 15min`, feedback desligado, rodapé "dados até 09h03min12s" (`pg_last_xact_replay_timestamp()`) e alerta com lag acima de 20 minutos.

O painel GraphQL (capítulo 12) passou a ler nas réplicas síncronas. No segundo dia, com o replay 4 s atrasado pela limpeza da outbox, o vendedor 42 sacou R$ 300,00, "Meus repasses" veio sem o saque, e ele sacou de novo. O trigger recusou por saldo, mas o print com "saque sumiu" chegou ao Bazar antes do fim do lag.

A regra agora: depois do COMMIT de uma escrita do vendedor, a API grava o LSN em `posicao:vendedor:{id}` no Redis (TTL 5 min) e o devolve ao painel, que guarda o maior que já viu. A leitura usa uma réplica que já aplicou o maior dos dois ou, depois de 200 ms, o primário. O Redis guarda posição, nunca dado, e dá read-your-writes entre aparelhos; o painel dá as leituras monotônicas.

Em outras condições, a escolha mudaria: relatórios cruzando vários sistemas pediriam um banco analítico (capítulo 25); usuários em vários continentes, réplicas regionais com token; perda de segundos aceitável, assíncrona pura.

## Armadilhas e casos reais

> **Na vida real:** em 21 de outubro de 2018, uma manutenção de rede isolou por 43 segundos o datacenter principal do GitHub na Costa Leste. O Orchestrator promoveu primários MySQL na Costa Oeste, cada lado ficou com escritas que o outro não tinha, e o GitHub passou 24 horas e 11 minutos degradado. Quarenta e três segundos de partição, um dia de conserto: a taxa de juros do split-brain.

> **Na vida real:** em 31 de janeiro de 2017, recriando uma réplica atrasada do PostgreSQL do GitLab.com, alguém apagou o diretório de dados do servidor errado: o primário. Cerca de 300 GB sumiram, e a restauração veio de um snapshot de seis horas antes. Réplica protege contra máquina que morre, e replica em milissegundos o comando que mata.

> **Armadilha:** tratar réplica como backup. Um `DELETE` sem `WHERE` chega às réplicas síncronas antes de você tirar o dedo do Enter. Dado apagado se recupera com point-in-time recovery (capítulo 40).

> **Armadilha:** monitorar só se a réplica está conectada. Uma réplica em `streaming` com 40 minutos de `replay_lag` está viva e inútil, como plantonista dormindo de crachá.

## Resumo

- Replicação física (WAL, cópia idêntica) ou lógica (por linha, sem DDL nem sequências).
- Assíncrona perde transação confirmada no failover; síncrona paga uma ida e volta por COMMIT; quórum `ANY 1` evita travar com uma réplica fora.
- Consulta longa na réplica: cancelamento, lag ou inchaço do primário.
- Read-your-writes e leituras monotônicas com réplicas pedem token de posição (LSN).
- Failover inclui cercar o primário antigo; errar é split-brain.
- Multi-líder troca ordem por conflitos; sem líder usa `W + R > N`, que não garante linearizabilidade.

## A Lastro agora

O ledger tem três cópias em três zonas, quórum síncrono, Patroni sobre etcd e failover em 30 a 40 s sem perder lançamento confirmado, a ~1,5 ms por COMMIT. Os relatórios moram em `pg-ledger-relat`; o painel lê nas réplicas síncronas, guiado pelo LSN. O PR "cachear por 30 dias" foi revertido, e o Carlos defendeu que a taxa de acerto tinha sido exatamente a prevista.

No dia 1º seguinte, com os relatórios em paz, alguém olhou o que eles liam: com 41 marketplaces, `lancamentos` tem 420 milhões de linhas, recebe 1,5 milhão por dia e, com a retenção de dez anos da Lastro, caminha para mais de cinco bilhões. O índice do extrato já não cabe na memória de nenhuma das três cópias, e o fundador, satisfeito, comentou que agora o problema estava replicado com perfeição: três bancos idênticos, igualmente grandes demais.

## Referências

- PostgreSQL 16, High Availability, Load Balancing, and Replication: https://www.postgresql.org/docs/16/high-availability.html
- PostgreSQL 16, Replication (parâmetros `synchronous_standby_names`, `max_standby_streaming_delay`, `hot_standby_feedback`): https://www.postgresql.org/docs/16/runtime-config-replication.html
- PostgreSQL 16, Hot Standby (conflitos de consulta): https://www.postgresql.org/docs/16/hot-standby.html
- PostgreSQL 16, Logical Replication: https://www.postgresql.org/docs/16/logical-replication.html
- PostgreSQL 17, Logical Replication Failover: https://www.postgresql.org/docs/17/logical-replication-failover.html
- Patroni, documentação: https://patroni.readthedocs.io/
- MySQL 8.0, Determination of Safe and Unsafe Statements in Binary Logging: https://dev.mysql.com/doc/refman/8.0/en/replication-rbr-safe-unsafe.html
- DeCandia et al., "Dynamo: Amazon's Highly Available Key-value Store", SOSP 2007: https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf
- GitHub, "October 21 post-incident analysis", 2018: https://github.blog/2018-10-30-oct21-post-incident-analysis/
- GitLab, "Postmortem of database outage of January 31", 2017: https://about.gitlab.com/blog/2017/02/10/postmortem-of-database-outage-of-january-31/
