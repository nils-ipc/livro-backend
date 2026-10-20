# Replicação

## O e-mail que voltou no tempo

Dona Cecília troca o e-mail no cadastro da loja, clica em "Salvar" e recebe a mensagem verde: "Dados atualizados com sucesso". A página recarrega e mostra o e-mail antigo. Ela clica em "Salvar" de novo. Verde de novo. E-mail antigo de novo. Na quarta tentativa, abre um chamado com o título "o site está mentindo para mim", que é a descrição técnica mais precisa que o suporte recebeu naquele mês.

A equipe (desta situação hipotética) não encontra bug nenhum. O `UPDATE` foi confirmado no banco principal; a leitura seguinte foi para a réplica `replica-b`, que naquela tarde estava 3,4 segundos atrás porque alguém rodava nela o `relatorio_trimestral_completo_v2.sql`.

Ninguém mentiu, tecnicamente. Então como funciona uma cópia de banco de dados, quanto ela pode ficar para trás, e o que é preciso fazer para ter várias cópias sem que o sistema contradiga a si mesmo?

## O mecanismo

*Replicação* é manter os mesmos dados em mais de uma máquina, para sobreviver à perda de uma delas, distribuir leituras ou ficar perto de usuários em outra região. A primeira pergunta é quem aceita escritas: um nó só (**líder único**, com o principal e as réplicas, ou *standbys*), vários (**multi-líder**) ou qualquer um (**sem líder**). O PostgreSQL, referência deste capítulo, faz o primeiro tipo nativamente.

### O WAL, o diário que o banco escreve antes de mexer em qualquer coisa

O PostgreSQL nunca altera uma página de dados sem antes registrar a alteração no *WAL* (*write-ahead log*). Cada registro do WAL descreve uma mudança física: "na página 4.817 do arquivo tal, a tupla na posição 12 passou a ter este conteúdo". A posição de um registro no log é o **LSN** (*log sequence number*), um deslocamento em bytes que só cresce, escrito como `0/3A2F1B8`.

Depois de um crash, o banco relê o WAL desde o último *checkpoint* e reaplica o que faltou. A replicação física reaproveita isso de forma quase preguiçosa: uma réplica é um PostgreSQL em recuperação permanente, que nunca termina de se recuperar porque o principal nunca para de produzir WAL.

Na *streaming replication*, o `walsender` do principal envia o WAL por TCP; na réplica, o `walreceiver` o grava em disco e o processo `startup` o reaplica. Com `hot_standby = on` (padrão), a réplica aceita leituras enquanto isso. Escritas recebem `ERROR: cannot execute UPDATE in a read-only transaction`, o que pelo menos é honesto.

Como o WAL descreve bytes em páginas, a réplica física é uma cópia byte a byte do cluster inteiro: todas as bases, tabelas, índices e sequências, com a mesma versão principal do PostgreSQL e a mesma arquitetura de CPU. Não dá para replicar só a tabela `clientes`, nem criar na réplica um índice só para o relatório do trimestre.

Uma réplica que ficou desconectada precisa de WAL que o principal talvez já tenha reciclado. Um **slot de replicação** faz o principal guardar todo WAL que a réplica ainda não confirmou, e faz isso com uma lealdade sem limite: réplica desligada há duas semanas, duas semanas de WAL no disco, até o disco encher (ver "Armadilhas").

### Leitura na réplica, ou a briga entre o relatório e o replay

O replay e as consultas na réplica às vezes querem coisas incompatíveis: o `VACUUM` do principal removeu versões antigas de linhas, o WAL manda removê-las na réplica, e uma consulta longa ainda precisa delas. O replay espera até `max_standby_streaming_delay` (padrão 30 s) e depois cancela a consulta:

```text
ERROR:  canceling statement due to conflict with recovery
DETAIL:  User query might have needed to see row versions that must be removed.
```

Aumentar esse limite deixa a réplica atrasar mais (o caso da `replica-b`). Ligar `hot_standby_feedback` faz a réplica pedir ao principal que não limpe essas linhas, e o relatório passa a causar inchaço (*bloat*) nas tabelas do principal. Em toda configuração, alguém paga a conta do relatório trimestral.

### Síncrona ou assíncrona

Por padrão, a replicação é **assíncrona**: o `COMMIT` retorna após o `fsync` do WAL no principal, e o envio às réplicas vem depois. Se o principal pegar fogo nesse intervalo, a transação existiu, foi confirmada e deixou de existir. Na **síncrona**, o `COMMIT` espera réplicas listadas em `synchronous_standby_names`, até o ponto definido por `synchronous_commit`:

| `synchronous_commit` | O `COMMIT` espera até | Sobrevive a |
|---|---|---|
| `off` | nada (nem o disco local) | quase nada; perde até 3 × `wal_writer_delay` |
| `local` | `fsync` no principal | queda do processo do banco |
| `remote_write` | réplica recebeu e escreveu no sistema operacional | queda do principal, não queda simultânea da réplica |
| `on` | réplica fez `fsync` do WAL | perda total do principal |
| `remote_apply` | réplica aplicou o WAL (dado visível em consultas) | perda do principal, e leitura na réplica já enxerga |

Sem réplica síncrona configurada, os três últimos valem `local`. O detalhe que engana: com `on`, a réplica tem o WAL no disco, mas talvez não o tenha reaplicado, e a transação fica segura e invisível ao mesmo tempo.

Dá para exigir quórum entre réplicas:

```text
synchronous_standby_names = 'ANY 1 (replica_a, replica_b, replica_c)'
synchronous_standby_names = 'FIRST 2 (replica_a, replica_b, replica_c)'
```

`ANY 1` espera a primeira das três que responder; `FIRST 2`, as duas primeiras da lista por prioridade.

O custo é latência e disponibilidade. Cada `COMMIT` ganha um RTT até a réplica: frações de milissegundo na mesma zona, algo na casa de 120 ms entre São Paulo e a costa leste dos Estados Unidos. E, se a única réplica síncrona cair, nenhum `COMMIT` retorna. Eles esperam, para sempre se ninguém mexer na configuração. O banco continua funcionando perfeitamente; só não termina nada.

Como `synchronous_commit` aceita `SET LOCAL` por transação, dá para pagar `remote_apply` só no pagamento e deixar assíncrono o registro de "último acesso", que ninguém vai processar na justiça por ter perdido.

### Replicação lógica

A replicação lógica envia mudanças por linha: "na tabela `clientes`, a linha `id = 4012` passou a ter `email = 'cecilia@exemplo.com'`". Com `wal_level = logical`, o PostgreSQL decodifica o WAL nessas mudanças (*logical decoding*), empacotadas desde a versão 10 em `CREATE PUBLICATION` e `CREATE SUBSCRIPTION`.

Ela replica só as tabelas escolhidas, funciona entre versões principais diferentes (caminho comum para atualizar de versão com pouca indisponibilidade) e o destino é um banco gravável, com índices próprios. Os limites vêm do mesmo nível de linha. DDL fica de fora: um `ALTER TABLE` esquecido no destino para a replicação no primeiro registro com uma coluna que ele não conhece. Valores de sequência não são replicados até o PostgreSQL 18, e o destino promovido descobre isso no primeiro `INSERT`, com um `duplicate key value violates unique constraint`. `UPDATE` e `DELETE` exigem que a tabela tenha *replica identity*, normalmente a chave primária, para que o destino saiba qual linha alterar.

A decodificação lógica também é a base do *change data capture* (CDC), tratado no capítulo 22.

### Lag, a distância entre o principal e a réplica

O *lag de replicação* é quanto a réplica está atrás do principal, em bytes de WAL ou em tempo; `pg_stat_replication` mostra `write_lag`, `flush_lag` e `replay_lag` (PostgreSQL 10+).

Em condições normais, o lag fica em milissegundos. Ele cresce quando uma consulta na réplica segura o replay, quando o principal gera WAL mais rápido do que um único processo `startup` consegue reaplicar (um `UPDATE` de 40 milhões de linhas) ou quando a réplica ganhou disco menor porque "é só réplica". E a réplica assíncrona não tem limite de lag: três segundos ou três horas atrás, ela responde do mesmo jeito, sem aviso nenhum na resposta.

### Read-your-writes e as outras garantias de sessão

Uma réplica assíncrona devolve um estado passado do banco, e isso gera anomalias com nome. Sem **read-your-writes** (ler as próprias escritas), o usuário não enxerga o que acabou de gravar: o caso de Dona Cecília. Sem **leituras monotônicas**, o tempo anda para trás: a primeira leitura vai para a `replica-a`, em dia, a segunda para a `replica-b`, e um comentário aparece e some. Essas garantias de sessão (Terry e colegas, 1994) são tratadas no capítulo 17. Com réplicas de leitura, as técnicas comuns são:

1. **Ler do principal por um tempo depois de escrever**, digamos 10 segundos. Funciona até o dia em que o lag passa de 10 segundos.
2. **Ler do principal tudo o que o usuário pode editar**: o próprio perfil vem do principal, o catálogo vem da réplica.
3. **Esperar pelo LSN.** Depois do `COMMIT`, a aplicação guarda o LSN do principal e, na leitura, pergunta à réplica se ela já aplicou até ali. É a única técnica baseada no estado real da réplica, em vez de um palpite sobre o lag.
4. **Fixar o usuário numa réplica** (hash do ID da sessão), o que dá leituras monotônicas enquanto ela estiver viva.

### Failover, ou a promoção que ninguém pediu

A **promoção** (`pg_promote()`, PostgreSQL 12+) faz a réplica parar o replay, abrir uma nova *timeline* (cada ramo da história do WAL ganha um número) e aceitar escritas. Fazer é trivial; o difícil é decidir quando.

Pela rede, um principal morto, um principal lento e uma rede partida são indistinguíveis. O detector de falha usa timeout: curto, uma pausa de 5 segundos promove uma réplica à toa; longo, um principal morto fica minutos sem substituto (o capítulo 19 trata da escolha de timeouts). Com replicação assíncrona, a promovida ainda tem uma história um pouco mais curta, sem as últimas transações confirmadas.

E então o principal antigo volta. Se ele voltar achando que ainda é o principal, e algum cliente ainda apontar para ele, temos dois nós aceitando escritas com histórias divergentes. Isso é *split-brain*:

```text
Principal antigo: Voltei. Pode mandar os pedidos.
Principal novo:   Eu sou o principal desde 14:03.
Aplicação A:      Pedido novo, da Ana.     Antigo: id 9001.
Aplicação B:      Pedido novo, do Bruno.   Novo:   id 9001.
Pedido 9001:      Sou de quem, afinal?
```

A prevenção tem duas partes. A primeira é *fencing*: impedir o principal antigo de aceitar escritas, desligando-o à força (STONITH, *shoot the other node in the head*, nome que diz muito sobre quem opera clusters), isolando-o da rede ou exigindo um *fencing token* em cada escrita. A segunda é decidir o principal por consenso. O Patroni, por exemplo, guarda uma chave de líder com TTL no etcd (ou Consul, ou ZooKeeper); um nó só atua como principal enquanto renova a chave, e quem perde contato rebaixa a si mesmo. O capítulo 18 trata de consenso, *leases* e fencing tokens.

O principal antigo volta como réplica com `pg_rewind`, que desfaz as páginas divergentes desde a separação das timelines; as escritas que só ele recebeu são descartadas. Os clientes acham o novo principal por DNS (sujeito ao TTL, capítulo 1), IP virtual, proxy ou pela própria libpq, que com `host=db1,db2,db3` e `target_session_attrs=read-write` fica com o host que aceita escrita.

### Multi-líder

Na replicação multi-líder, mais de um nó aceita escritas e replica para os outros de forma assíncrona. O caso típico é um líder por região; um caso menos óbvio é o aplicativo com modo offline, em que cada celular é um líder que sincroniza quando encontra sinal.

O preço são os conflitos: dois líderes aceitam, ao mesmo tempo, valores diferentes para a mesma linha, e cada um já confirmou o seu ao cliente. Na **última escrita vence** (*last write wins*, LWW), fica o maior timestamp e a outra escrita some em silêncio; como os relógios de máquinas diferentes divergem (capítulo 18), um servidor 2 segundos adiantado vence todas as disputas, muito confiante e sem razão nenhuma. A alternativa é mesclar com estruturas que convergem por construção, os CRDTs (*conflict-free replicated data types*), ou guardar as versões em conflito para a aplicação resolver na leitura. O PostgreSQL não faz multi-líder nativamente.

### Sem líder e quórum

No modelo sem líder (artigo do Dynamo, Amazon, 2007; Cassandra e Riak), um coordenador envia cada escrita e cada leitura para várias réplicas ao mesmo tempo:

```text
N = número de réplicas de cada dado
W = confirmações exigidas para a escrita ter sucesso
R = respostas exigidas para a leitura ter sucesso

Se W + R > N, todo conjunto de leitura cruza com todo conjunto de escrita
em pelo menos uma réplica.
```

Com N = 3, W = 2 e R = 2, escrita e leitura sobrevivem a uma réplica fora do ar, e toda leitura consulta pelo menos uma réplica com a última escrita confirmada. Cada valor carrega uma versão, a leitura fica com a mais nova e corrige na hora a réplica que respondeu velho (*read repair*); um processo de fundo compara réplicas com árvores de Merkle para achar as diferenças que ninguém leu.

O quórum dá menos do que a conta sugere. Ele garante a interseção, e só ela: escritas concorrentes ainda conflitam, uma escrita que "falhou" com 1 de 2 confirmações continua gravada naquela réplica e pode reaparecer, e o *sloppy quorum* aceita escritas fora do conjunto original durante falhas, quebrando a interseção de propósito. No Cassandra, os níveis `ONE`, `QUORUM`, `LOCAL_QUORUM` e `ALL` escolhem W e R por requisição.

## Na prática

### Quanto a `replica-b` está atrás

No principal, a visão `pg_stat_replication` mostra cada réplica conectada:

```sql
SELECT application_name, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS atraso,
       replay_lag
FROM pg_stat_replication;
```

```text
 application_name |   state   | sync_state |  atraso  |   replay_lag
------------------+-----------+------------+----------+-----------------
 replica-a        | streaming | async      | 0 bytes  | 00:00:00.000412
 replica-b        | streaming | async      | 212 MB   | 00:00:03.418772
```

A `replica-b` recebe o WAL, mas tem 212 MB ainda não aplicados: o preço de um relatório trimestral. Na própria réplica, a medida comum é `now() - pg_last_xact_replay_timestamp()`, que engana sem escritas: 10 minutos sem nada gravado no principal parecem 10 minutos de atraso. Um alerta baseado só nela dispara toda madrugada de domingo.

### Read-your-writes com LSN

A versão por LSN, com psycopg 3. Depois da escrita, a aplicação guarda o LSN na sessão do usuário:

```python
import logging
import os

import psycopg

log = logging.getLogger("cadastro")

URL_PRINCIPAL = os.environ["DATABASE_URL_PRINCIPAL"]
URL_REPLICA = os.environ["DATABASE_URL_REPLICA"]


def atualizar_email(cliente_id: int, email: str) -> str:
    with psycopg.connect(URL_PRINCIPAL) as conn:
        conn.execute(
            "UPDATE clientes SET email = %s WHERE id = %s", (email, cliente_id)
        )
        conn.commit()
        # Depois do COMMIT, o LSN atual está à frente do registro de commit.
        lsn = conn.execute("SELECT pg_current_wal_lsn()::text").fetchone()[0]
    return lsn  # vai para a sessão do usuário, junto com a promessa de que salvou


def buscar_email(cliente_id: int, lsn_minimo: str | None) -> str:
    consulta = "SELECT email FROM clientes WHERE id = %s"
    with psycopg.connect(URL_REPLICA) as conn:
        if lsn_minimo is not None:
            em_dia = conn.execute(
                "SELECT pg_last_wal_replay_lsn() >= %s::pg_lsn", (lsn_minimo,)
            ).fetchone()[0]
            if not em_dia:
                log.info("replica atrasada para LSN %s; lendo do principal", lsn_minimo)
                with psycopg.connect(URL_PRINCIPAL) as principal:
                    return principal.execute(consulta, (cliente_id,)).fetchone()[0]
        return conn.execute(consulta, (cliente_id,)).fetchone()[0]
```

Com a `replica-b` atrasada, o log das duas chamadas fica assim:

```text
INFO:cadastro:replica atrasada para LSN 2/9C41E7A8; lendo do principal
cecilia@exemplo.com
```

O código abre conexões a cada chamada para caber na página (um sistema real usa pools, capítulo 11). Se a réplica vive atrasada, toda leitura pós-escrita vai para o principal, e a réplica vira um enfeite caro.

## Propriedades e custos

| Modo | Perda no failover | Latência extra no `COMMIT` | Leitura na réplica logo após escrita | Se a réplica cair |
|---|---|---|---|---|
| Assíncrona | transações ainda não enviadas | nenhuma | pode ver dado antigo | nada muda no principal |
| Síncrona `on` | nenhuma | 1 RTT + `fsync` na réplica | pode ver dado antigo (replay pendente) | commits esperam, se for a única síncrona |
| Síncrona `remote_apply` | nenhuma | 1 RTT + `fsync` + replay | vê a escrita | commits esperam, se for a única síncrona |
| Quórum `ANY 1` de 3 | nenhuma, se a promovida for a que confirmou | RTT da réplica mais rápida | depende de qual réplica é lida | tolera 2 réplicas fora |

A perda "nenhuma" depende de promover justamente uma réplica que confirmou: com `ANY 1`, só uma das três tem garantidamente a última transação, e a ferramenta de failover precisa saber qual.

| Modelo | Quem escreve | Onde mora o problema | Latência de escrita entre regiões |
|---|---|---|---|
| Líder único | um nó | failover e split-brain | RTT até o principal |
| Multi-líder | um por região | conflitos entre líderes | local |
| Sem líder | qualquer réplica | versões concorrentes, escolha de W e R | depende de W |

A condição que pesa: se a aplicação não tolera duas escritas concorrentes no mesmo dado sem intervenção, multi-líder e sem líder transferem para o código um problema que o líder único resolvia de graça.

## Armadilhas e casos reais

> **Armadilha:** réplica não substitui backup. Um `DELETE FROM clientes` sem `WHERE` chega à réplica em milissegundos, com a mesma fidelidade que qualquer outra escrita. A replicação protege contra perda de máquina; contra erro humano, só backup com recuperação para um ponto no tempo (capítulo 40). O PostgreSQL tem `recovery_min_apply_delay`, que mantém uma réplica propositalmente atrasada, digamos, 1 hora, o que dá uma janela para salvar os dados antes que a réplica também os apague.

> **Armadilha:** o slot de replicação esquecido. Réplica de testes criada em março, desligada em abril, slot ainda no principal; em junho, o disco enche de WAL que ninguém vai ler e o principal para de aceitar escritas. `pg_replication_slots` com `active = false` encontra o fantasma, e `max_slot_wal_keep_size` (PostgreSQL 13+) invalida o slot antes do desastre.

Outra que aparece em toda primeira configuração síncrona: o cliente cancela um `COMMIT` que está esperando a réplica, por timeout ou Ctrl+C, e recebe isto:

```text
WARNING:  canceling wait for synchronous replication due to user request
DETAIL:  The transaction has already committed locally, but might not have been replicated to the standby.
```

A transação já está confirmada no principal; cancelar só tira a garantia de que chegou à réplica. Quem trata esse cancelamento como "falhou, vou tentar de novo" grava duas vezes, com o capítulo 20 de testemunha.

> **Na vida real:** em 21 de outubro de 2018, o GitHub perdeu por 43 segundos a conectividade entre o hub de rede da costa leste dos Estados Unidos e o data center principal da mesma costa. O Orchestrator, ferramenta que gerenciava a topologia dos clusters MySQL, interpretou isso como falha e promoveu principais no data center da costa oeste. O leste tinha escritas que não chegaram ao oeste, o oeste passou a receber escritas novas, e voltar ao leste sem perder dados de um dos lados ficou impossível. A equipe preservou os dados, restaurou backups, reconciliou as escritas, e o serviço ficou degradado por 24 horas e 11 minutos. Quarenta e três segundos de rede, um dia inteiro de conciliação.

E a `replica-b` ganhou um destino melhor: o relatório trimestral foi para uma réplica dedicada, o perfil passou a ser lido pelo LSN, e agora só o catálogo fica alguns segundos no passado. Ninguém abre chamado porque um tênis demorou três segundos para mudar de preço.

## Resumo

- Replicação física envia o WAL; a réplica é cópia byte a byte do cluster, em recuperação permanente.
- Slots retêm WAL e podem encher o disco; consultas na réplica disputam com o replay.
- Assíncrona perde as últimas transações no failover; síncrona custa 1 RTT por `COMMIT` e trava se a única réplica síncrona cair; só `remote_apply` garante ler na réplica o que acabou de ser gravado.
- Replicação lógica escolhe tabelas e cruza versões, sem DDL nem sequências.
- Lag de réplica assíncrona não tem limite; read-your-writes vem de ler do principal ou esperar o LSN.
- Split-brain se previne com fencing e consenso.
- Multi-líder e sem líder precisam resolver conflitos; W + R > N garante interseção, não linearizabilidade.
- Réplica não substitui backup.

## Referências

- PostgreSQL 16, "High Availability, Load Balancing, and Replication": https://www.postgresql.org/docs/16/high-availability.html
- PostgreSQL 16, parâmetros de replicação: https://www.postgresql.org/docs/16/runtime-config-replication.html
- PostgreSQL 16, `synchronous_commit` e WAL: https://www.postgresql.org/docs/16/runtime-config-wal.html
- PostgreSQL 16, replicação lógica: https://www.postgresql.org/docs/16/logical-replication.html
- PostgreSQL 16, `pg_stat_replication`: https://www.postgresql.org/docs/16/monitoring-stats.html
- PostgreSQL 16, `pg_rewind`: https://www.postgresql.org/docs/16/app-pgrewind.html
- Patroni, documentação: https://patroni.readthedocs.io/
- DeCandia et al., "Dynamo: Amazon's Highly Available Key-value Store", SOSP 2007: https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf
- Terry et al., "Session Guarantees for Weakly Consistent Replicated Data", PDIS 1994.
- GitHub, "October 21 post-incident analysis": https://github.blog/2018-10-30-oct21-post-incident-analysis/
