# Transações e isolamento

## O plantão que ficou vazio

Sexta-feira, 23h58. Tadeu e Lívia, os dois engenheiros de plantão da semana, abrem o painel interno ao mesmo tempo e clicam em "Sair do plantão". Nenhum dos dois combinou nada com o outro. O sistema tem uma regra simples e muito bem testada: **pelo menos uma pessoa precisa continuar de plantão**.

O código da regra é este:

```python
def sair_do_plantao(sessao, engenheiro: str) -> None:
    # verificado, não tem como dar errado
    restantes = sessao.scalar(
        select(func.count()).select_from(Plantao).where(Plantao.de_plantao)
    )
    if restantes < 2:
        raise PlantaoVazio("Alguém precisa ficar. Esse alguém é você.")
    sessao.execute(
        update(Plantao)
        .where(Plantao.engenheiro == engenheiro)
        .values(de_plantao=False)
    )
    sessao.commit()
```

Tudo dentro de uma transação. As duas requisições leram `restantes = 2`, as duas passaram na verificação, as duas fizeram o `UPDATE` na própria linha e as duas receberam `200 OK`. Às 2h47, o banco de produção começou a recusar conexões, o alerta tocou e ninguém atendeu, porque, segundo a tabela `plantao`, a quantidade de pessoas responsáveis pela empresa era zero.

O banco seguiu cada regra que prometeu seguir. A transação estava lá, o `COMMIT` foi aceito, nenhum erro apareceu no log. A pergunta deste capítulo é: o que exatamente uma transação garante, e por que "estava tudo dentro de uma transação" não impediu que as duas pessoas saíssem do plantão?

## ACID, letra por letra (e uma letra de enfeite)

O acrônimo ACID foi cunhado por Theo Härder e Andreas Reuter em 1983. Cada letra promete uma coisa diferente, e uma delas está ali mais pela sonoridade.

**Atomicidade** significa que a transação acontece inteira ou não acontece. Se ela fez três `INSERT` e falhou no quarto, os três primeiros somem. No PostgreSQL, cada versão de linha carrega o identificador da transação que a criou; se essa transação abortou, a versão fica invisível para todo mundo. Atomicidade fala de falha, e sobre concorrência ela não diz uma palavra.

**Consistência** é a letra de enfeite. A transação leva o banco de um estado válido a outro, onde "válido" significa "respeita as invariantes". As invariantes que o banco conhece são as restrições declaradas (`NOT NULL`, `UNIQUE`, `CHECK`, chaves estrangeiras; o capítulo 7 trata delas). "Pelo menos um engenheiro de plantão" existe só no código da aplicação, e o banco não tem como protegê-la.

**Durabilidade** significa que, depois que o `COMMIT` retornou, os dados sobrevivem a uma queda. O PostgreSQL grava a transação no WAL (*write-ahead log*) e chama `fsync` antes de responder. Com `synchronous_commit = off`, o `COMMIT` responde antes do `fsync`, e uma queda pode perder as transações de até três vezes `wal_writer_delay` (200 ms por padrão). O banco continua íntegro; só fica com amnésia de até 600 ms.

**Isolamento** é a letra que interessa aqui. A definição ideal é: transações concorrentes produzem o mesmo resultado que produziriam se rodassem uma depois da outra, em alguma ordem. Isso tem nome, **serializabilidade**. O problema é que garantir serializabilidade custa caro, e por isso os bancos oferecem níveis mais fracos, cada um deixando passar um conjunto diferente de anomalias. O plantão vazio foi uma delas.

## O padrão SQL e suas três anomalias oficiais

O padrão SQL (ISO/IEC 9075) define quatro níveis de isolamento a partir de três fenômenos proibidos. Uma **anomalia** é um resultado que nenhuma execução em série produziria.

**Dirty read** (leitura suja): T1 altera uma linha, T2 lê a alteração, T1 faz `ROLLBACK`. T2 tomou uma decisão com base num dado que oficialmente nunca existiu.

**Non-repeatable read** (leitura não repetível): T1 lê uma linha, T2 altera essa linha e faz `COMMIT`, T1 lê de novo e encontra outro valor. A mesma consulta, na mesma transação, devolveu duas respostas.

**Phantom** (fantasma): T1 lê o conjunto de linhas que satisfaz um predicado (`WHERE de_plantao`), T2 insere ou altera uma linha que passa a satisfazer o predicado e faz `COMMIT`, T1 repete a consulta e aparece uma linha que antes não estava lá. Fantasmas, em banco de dados, entram pelo `INSERT`.

Os níveis do padrão ficam assim:

| Nível | Dirty read | Non-repeatable read | Phantom |
|-------|-----------|---------------------|---------|
| READ UNCOMMITTED | permitido | permitido | permitido |
| READ COMMITTED | proibido | permitido | permitido |
| REPEATABLE READ | proibido | proibido | permitido |
| SERIALIZABLE | proibido | proibido | proibido |

A tabela tem um defeito sério. Em 1995, Berenson, Bernstein, Gray e outros publicaram "A Critique of ANSI SQL Isolation Levels" mostrando que as definições eram ambíguas e que proibir os três fenômenos ainda deixava passar anomalias. Trinta anos depois, a tabela continua aparecendo em entrevistas de emprego com cara de verdade completa.

## As anomalias que o padrão esqueceu

O artigo de 1995 deu nome a duas anomalias que todo backend encontra cedo ou tarde.

**Lost update** (atualização perdida): duas transações leem o mesmo valor, calculam um novo valor a partir dele na aplicação e gravam. A segunda gravação apaga a primeira.

```text
T1: SELECT estoque FROM produto WHERE id = 7;   -- 10
T2: SELECT estoque FROM produto WHERE id = 7;   -- 10
T1: UPDATE produto SET estoque = 9 WHERE id = 7; COMMIT;
T2: UPDATE produto SET estoque = 9 WHERE id = 7; COMMIT;
-- duas unidades vendidas, uma unidade descontada
```

O capítulo 5 trata do lado da aplicação; aqui interessa qual nível detecta isso e qual deixa passar.

**Write skew** (escrita enviesada): duas transações leem um conjunto de linhas que se sobrepõe, cada uma decide com base no que leu e cada uma escreve numa linha **diferente**. Nenhuma linha foi escrita por duas transações, então nenhum mecanismo que procure conflito de escrita encontra nada. Mesmo assim, o resultado viola uma invariante que dependia das duas linhas juntas. É o plantão da abertura:

```text
T1: SELECT count(*) FROM plantao WHERE de_plantao;   -- 2
T2: SELECT count(*) FROM plantao WHERE de_plantao;   -- 2
T1: UPDATE plantao SET de_plantao = false WHERE engenheiro = 'Tadeu';
T2: UPDATE plantao SET de_plantao = false WHERE engenheiro = 'Lívia';
T1: COMMIT;
T2: COMMIT;
-- de plantão: 0
```

Em série, a segunda transação teria lido `1` e recusado a saída. Em paralelo, cada uma leu um mundo em que a outra ainda estava trabalhando. Write skew aparece em reservas de sala, em limites de gasto somados entre contas e em qualquer regra do tipo "no máximo N" ou "pelo menos N".

## MVCC: cada transação lê a própria fotografia do passado

Para entender qual nível pega qual anomalia, é preciso saber como o PostgreSQL guarda as linhas. Ele usa MVCC (*multiversion concurrency control*): um `UPDATE` nunca sobrescreve a linha. Ele marca a versão antiga como encerrada e grava uma versão nova, em outro lugar da página ou em outra página. Cada versão (o PostgreSQL chama de *tuple*) carrega duas colunas de sistema:

- `xmin`: o ID da transação que criou a versão.
- `xmax`: o ID da transação que apagou ou substituiu a versão (0 se ninguém fez isso).

Os IDs de transação são números de 32 bits crescentes. Para ler, a transação recebe um **snapshot**: quais transações já tinham terminado naquele instante.

```sql
SELECT pg_current_snapshot();
```

```text
 pg_current_snapshot
---------------------
 1012:1015:1012,1014
```

O formato é `xmin:xmax:lista`. Transações com ID menor que 1012 já terminaram; a partir de 1015, ainda não existem para este snapshot. A 1012 e a 1014 estavam em andamento, e a 1013 já tinha terminado.

A regra de visibilidade sai daí: uma versão é visível se o `xmin` dela fez `COMMIT` antes do snapshot e o `xmax` está vazio ou pertence a uma transação que, para este snapshot, ainda não terminou. Cada leitura percorre as versões e escolhe a que obedece a regra. O resultado prático é a propriedade mais famosa do MVCC: **leitores não bloqueiam escritores, e escritores não bloqueiam leitores**. Um relatório de vinte minutos lendo a tabela inteira não impede ninguém de fazer `UPDATE`; ele só continua enxergando o passado, com a serenidade de quem não lê notícia desde as 9h.

O custo fica no disco. Cada `UPDATE` deixa uma versão morta, e o `VACUUM` só remove versões que nenhum snapshot ativo ainda enxerga. Uma transação esquecida aberta segura a limpeza do banco inteiro.

Os IDs de 32 bits também dão a volta, e o `VACUUM` "congela" versões antigas para que elas não pareçam, de repente, vir do futuro. Se o congelamento ficar muito atrasado, o PostgreSQL para de aceitar transações novas: prefere parar a perder a noção do tempo.

## Os três níveis do PostgreSQL por dentro

O PostgreSQL aceita os quatro nomes do padrão, mas implementa três comportamentos. `READ UNCOMMITTED` funciona exatamente como `READ COMMITTED`: com MVCC, dirty read daria mais trabalho de implementar do que de evitar.

### READ COMMITTED: um snapshot novo a cada comando

É o padrão do PostgreSQL. Cada **comando** recebe um snapshot novo. Dois `SELECT` iguais na mesma transação podem devolver resultados diferentes, porque cada um vê os `COMMIT` que aconteceram até o seu início. Non-repeatable read e phantom estão liberados.

Se um `UPDATE` encontra uma linha que outra transação está alterando, ele espera o `COMMIT` dela, pega a versão nova, reavalia o `WHERE` e aplica a alteração. Por isso `UPDATE produto SET estoque = estoque - 1 WHERE id = 7 AND estoque > 0` funciona em READ COMMITTED. Já "`SELECT`, conta em Python, `UPDATE` com o valor pronto" perde atualizações em silêncio: o banco não sabe que o `9` gravado veio de um `10` que já ficou velho.

### REPEATABLE READ: snapshot isolation

No PostgreSQL, REPEATABLE READ é **snapshot isolation**: a transação inteira usa um único snapshot, tirado no primeiro comando (no primeiro comando, repare, e não no `BEGIN`). Todas as leituras veem o banco congelado naquele instante. Isso elimina non-repeatable read e também phantom, que o padrão permitiria neste nível.

A diferença aparece nas escritas. Se a transação tenta alterar uma linha que outra transação alterou e confirmou depois do snapshot, o PostgreSQL não reavalia nada. Ele desiste:

```text
ERROR:  could not serialize access due to concurrent update
```

O código SQLSTATE é `40001`. O lost update do estoque vira erro: a segunda transação a escrever na linha 7 é abortada e recomeça, agora lendo `9`. Quem confirma primeiro fica; quem chega depois refaz (*first-committer-wins*).

E o plantão? Tadeu escreveu na linha do Tadeu. Lívia escreveu na linha da Lívia. Não houve conflito de escrita em linha nenhuma, então snapshot isolation deixa as duas confirmarem. Write skew passa intacto pelo REPEATABLE READ, que é a anomalia que define a fronteira entre snapshot isolation e serializabilidade.

Outros bancos usam os mesmos nomes para coisas diferentes, o que garante emprego para muita gente. O `SERIALIZABLE` do Oracle é snapshot isolation e permite write skew. No REPEATABLE READ do MySQL com InnoDB, o `UPDATE` lê a versão mais recente confirmada sem abortar, e o lost update do estoque passa se a conta for feita na aplicação. Migrar de banco mantendo o nome do nível muda a semântica sem mudar uma linha de código.

### SERIALIZABLE: snapshot isolation com um detetive

Desde a versão 9.1 (2011), o SERIALIZABLE do PostgreSQL usa SSI (*Serializable Snapshot Isolation*), algoritmo publicado por Michael Cahill, Uwe Röhm e Alan Fekete em 2008. As leituras continuam usando snapshot, sem bloquear ninguém. A diferença é que o banco passa a anotar o que cada transação leu.

Essas anotações são os **SIREAD locks** (*predicate locks*), que, apesar do nome, não bloqueiam nada. Servem para o banco descobrir que A leu uma versão que B substituiu. Essa relação é uma dependência **rw** (leitura e escrita): em qualquer ordem em série equivalente, A precisa vir antes de B.

A teoria (de Fekete e outros, 2005) mostra que toda anomalia de snapshot isolation contém uma estrutura específica: duas dependências rw seguidas, T1 → T2 → T3, em que T2, chamada de **pivô**, tem uma aresta chegando e outra saindo, e as transações envolvidas se sobrepõem no tempo. T1 e T3 podem ser a mesma transação. No plantão é exatamente isso:

```text
Tadeu leu as linhas "de plantão"  →  Lívia escreveu uma delas   (Tadeu antes de Lívia)
Lívia leu as linhas "de plantão"  →  Tadeu escreveu uma delas   (Lívia antes de Tadeu)
```

Cada transação precisa vir antes da outra, o que nenhuma ordem em série consegue. Quando o PostgreSQL encontra essa estrutura, ele aborta uma das transações:

```text
ERROR:  could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during commit attempt.
HINT:  The transaction might succeed if retried.
```

O detetive tem dois hábitos. Primeiro, aceita falsos positivos: a estrutura perigosa é condição necessária para anomalia, e não suficiente, então às vezes um inocente é abortado. Segundo, a precisão depende da leitura. Uma leitura por índice anota tuplas e páginas específicas; um seq scan anota a **tabela inteira**, e qualquer escrita em qualquer linha vira suspeita. Quando as anotações passam de certos limites (`max_pred_locks_per_transaction`, 64 por padrão), o banco as promove de tupla para página e de página para tabela.

A garantia vale entre transações SERIALIZABLE; uma escrita em READ COMMITTED fica fora da investigação.

## Na prática: o plantão em Python

A tabela de exemplo:

```sql
CREATE TABLE plantao (
    engenheiro text PRIMARY KEY,
    de_plantao boolean NOT NULL
);
INSERT INTO plantao VALUES ('Tadeu', true), ('Lívia', true);
```

O script abaixo reproduz a sexta-feira com duas conexões psycopg 3 em REPEATABLE READ, intercalando os comandos à mão. Como cada `UPDATE` mexe numa linha diferente, nenhum espera pelo outro, e o script dispensa threads.

```python
import os

import psycopg
from psycopg import IsolationLevel

DSN = os.environ["DATABASE_URL"]


def conectar(nivel: IsolationLevel) -> psycopg.Connection:
    conn = psycopg.connect(DSN)
    conn.isolation_level = nivel
    return conn


def quantos_de_plantao(conn: psycopg.Connection) -> int:
    return conn.execute(
        "SELECT count(*) FROM plantao WHERE de_plantao"
    ).fetchone()[0]


tadeu = conectar(IsolationLevel.REPEATABLE_READ)
livia = conectar(IsolationLevel.REPEATABLE_READ)

print("Tadeu vê:", quantos_de_plantao(tadeu))
print("Lívia vê:", quantos_de_plantao(livia))

tadeu.execute("UPDATE plantao SET de_plantao = false WHERE engenheiro = 'Tadeu'")
livia.execute("UPDATE plantao SET de_plantao = false WHERE engenheiro = 'Lívia'")
tadeu.commit()
livia.commit()

with psycopg.connect(DSN) as conn:
    print("De plantão agora:", quantos_de_plantao(conn))
```

```text
Tadeu vê: 2
Lívia vê: 2
De plantão agora: 0
```

Nenhuma exceção, nenhum aviso. Com `IsolationLevel.SERIALIZABLE` nas duas conexões (e a tabela restaurada), o segundo `COMMIT` explode:

```text
Tadeu vê: 2
Lívia vê: 2
Traceback (most recent call last):
  ...
psycopg.errors.SerializationFailure: could not serialize access due to read/write dependencies among transactions
```

Dependendo de quando o conflito é detectado, o erro pode sair no `UPDATE`. Em qualquer caso, a Lívia continua de plantão. Ela não vai gostar, mas a empresa vai.

O erro `40001` faz parte do contrato desses níveis: a aplicação repete a transação inteira, desde a primeira leitura, porque a decisão foi tomada com dados velhos.

```python
import random
import time

from psycopg import errors


class PlantaoVazio(Exception):
    pass


def em_transacao_serializavel(conn, operacao, tentativas: int = 5):
    # conn criada com isolation_level = SERIALIZABLE e autocommit desligado
    for tentativa in range(1, tentativas + 1):
        try:
            with conn.transaction():
                return operacao(conn)
        except errors.SerializationFailure:
            if tentativa == tentativas:
                raise
            time.sleep(random.uniform(0, 0.01 * 2**tentativa))  # backoff com jitter


def sair_do_plantao(conn, engenheiro: str) -> None:
    def operacao(conn):
        restantes = conn.execute(
            "SELECT count(*) FROM plantao WHERE de_plantao"
        ).fetchone()[0]
        if restantes < 2:
            raise PlantaoVazio(f"{engenheiro}, você é a última linha de defesa.")
        conn.execute(
            "UPDATE plantao SET de_plantao = false WHERE engenheiro = %s",
            (engenheiro,),
        )

    em_transacao_serializavel(conn, operacao)
```

Na segunda tentativa, a transação da Lívia lê `1` e levanta `PlantaoVazio`, sem uma linha de lock na aplicação. Com SQLAlchemy 2.x, o nível vai em `create_engine(url, isolation_level="SERIALIZABLE")`, e a exceção chega embrulhada em `OperationalError`, com a original em `.orig`.

Outro caminho, sem mudar o nível, é trazer o conflito para as linhas lidas com `SELECT ... WHERE de_plantao FOR UPDATE`: a segunda transação espera a primeira e relê o conjunto. Isso funciona porque as linhas em disputa existem. Numa reserva de sala, o conflito é entre linhas que **ainda não existem**, e `FOR UPDATE` não trava o vazio; ali entra uma restrição `EXCLUDE` (capítulo 7) ou SERIALIZABLE. O capítulo 11 trata de `FOR UPDATE` e controle otimista.

## Propriedades e custos

| Nível no PostgreSQL | Impede | Deixa passar | Custo principal |
|---------------------|--------|--------------|-----------------|
| READ COMMITTED | dirty read | non-repeatable read, phantom, lost update feito na aplicação, write skew | quase nenhum; nenhuma falha de serialização |
| REPEATABLE READ (snapshot isolation) | os anteriores, phantom, lost update (vira `40001`) | write skew | retries em conflito de escrita; snapshot longo segura o `VACUUM` |
| SERIALIZABLE (SSI) | todas as anomalias, entre transações SERIALIZABLE | nada | anotação de leituras (memória e CPU), falsos positivos, retries, transações curtas obrigatórias |

READ COMMITTED pesa a favor quando cada transação é um único comando ou quando a conta acontece dentro do SQL (`estoque = estoque - 1`), com invariantes cobertas por restrições. Aí as anomalias liberadas não têm onde acontecer, e o código dispensa laço de retry.

Snapshot isolation pesa a favor em leituras longas que precisam de um retrato coerente, como um relatório que não pode ver metade de uma transferência. O custo é o horizonte do `VACUUM`: um relatório de duas horas mantém vivas todas as versões mortas dessas duas horas, em todas as tabelas.

SERIALIZABLE pesa a favor quando as invariantes envolvem várias linhas e você não quer descobrir, uma a uma, quais combinações de transações precisam de lock. O preço é uma taxa de abortos que cresce com a contenção e com o tamanho das transações. Nos benchmarks de Ports e Grittner (VLDB 2012), o SSI ficou próximo de snapshot isolation e bem acima de um serializable feito com locks de leitura (S2PL). Para leituras longas, `SERIALIZABLE READ ONLY DEFERRABLE` espera um snapshot garantidamente seguro e depois roda sem anotações e sem risco de aborto.

## Armadilhas e casos reais

> **Armadilha:** efeito colateral dentro da transação repetida. Se a função do laço de retry envia um e-mail ou cobra um cartão, cada tentativa abortada repete o efeito. A transação volta atrás; o e-mail já está na caixa de entrada de alguém, anunciando com toda a confiança uma saída de plantão que nunca aconteceu. Efeitos externos ficam depois do `COMMIT` (o capítulo 22 trata do padrão outbox).

> **Armadilha:** `idle in transaction`. Uma conexão que abriu transação e foi esperar uma API externa segura o snapshot, os locks e o horizonte do `VACUUM` pelo tempo que a API quiser. O parâmetro `idle_in_transaction_session_timeout` encerra essas sessões; o padrão é 0, desligado, e muita sessão já completou aniversário assim.

> **Armadilha:** checar antes e inserir depois. `SELECT` para ver se o nome de usuário existe, seguido de `INSERT`, é um phantom esperando acontecer. Uma restrição `UNIQUE` resolve no índice, em qualquer nível de isolamento.

> **Na vida real:** em março de 2014, a Flexcoin, um banco de bitcoins, encerrou as atividades depois de perder 896 BTC. Segundo o comunicado da empresa, o atacante enviou milhares de transferências simultâneas entre contas internas, e várias passaram na mesma verificação de saldo antes que qualquer uma gravasse o débito. Lost update de livro-texto, com a diferença de que o livro-texto não fecha a empresa no final.

> **Na vida real:** no artigo "ACIDRain" (SIGMOD 2017), Todd Warszawski e Peter Bailis analisaram 12 aplicações de e-commerce populares e encontraram 22 ataques críticos de concorrência, como usar o mesmo vale-presente várias vezes. O código tinha sido escrito para um mundo com uma requisição por vez.

> **Na vida real:** em 2020, a análise Jepsen do PostgreSQL 12.3, de Kyle Kingsbury, encontrou anomalias do tipo G2-item (write skew) em transações SERIALIZABLE, causadas por um bug na detecção de conflitos, corrigido nas versões menores seguintes. Até o detetive precisa de auditoria.

## Resumo

- Atomicidade trata de falha, durabilidade de `COMMIT` que sobrevive a queda, consistência das restrições declaradas; isolamento decide o que transações concorrentes enxergam.
- O padrão SQL define níveis por dirty read, non-repeatable read e phantom; Berenson e outros (1995) nomearam lost update e write skew.
- MVCC guarda versões com `xmin` e `xmax`; o snapshot decide o que cada leitura vê.
- No PostgreSQL: READ COMMITTED tira snapshot por comando; REPEATABLE READ é snapshot isolation, aborta lost update com `40001` e deixa write skew passar; SERIALIZABLE (SSI) aborta o pivô de duas dependências rw.
- Com `40001`, a aplicação repete a transação inteira, sem efeitos externos dentro dela.
- Tadeu e Lívia continuam disputando a saída do plantão, mas agora um deles sempre perde.

## Referências

- ISO/IEC 9075-2, SQL/Foundation.
- Härder, T.; Reuter, A. "Principles of Transaction-Oriented Database Recovery". *ACM Computing Surveys*, 1983.
- Berenson, H. et al. "A Critique of ANSI SQL Isolation Levels". SIGMOD 1995. <https://arxiv.org/abs/cs/0701157>
- Fekete, A. et al. "Making Snapshot Isolation Serializable". *ACM TODS*, 2005.
- Cahill, M.; Röhm, U.; Fekete, A. "Serializable Isolation for Snapshot Databases". SIGMOD 2008.
- Ports, D.; Grittner, K. "Serializable Snapshot Isolation in PostgreSQL". VLDB 2012. <https://arxiv.org/abs/1208.4179>
- Documentação do PostgreSQL, "Transaction Isolation". <https://www.postgresql.org/docs/current/transaction-iso.html>
- Documentação do PostgreSQL, "Asynchronous Commit". <https://www.postgresql.org/docs/current/wal-async-commit.html>
- Documentação do psycopg 3, "psycopg.errors". <https://www.psycopg.org/psycopg3/docs/api/errors.html>
- Warszawski, T.; Bailis, P. "ACIDRain: Concurrency-Related Attacks on Database-Backed Web Applications". SIGMOD 2017.
- Kingsbury, K. "Jepsen: PostgreSQL 12.3", 2020. <https://jepsen.io/analyses/postgresql-12.3>
- Flexcoin, comunicado de encerramento, março de 2014.
