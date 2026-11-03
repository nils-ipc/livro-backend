# Transações e isolamento

## A quarta aba

Segunda-feira, 9h12, e o vendedor 42 voltou ao hobby, agora com quatro abas, porque ele aprende rápido e a Lastro aprende por chamado. Saldo disponível de R$ 6.000,00, R$ 1.000,00 já sacados no dia, e o limite diário novo do gerente de produto ("mas é só somar os saques do dia, não?") é de R$ 5.000,00. Duas abas pediram R$ 4.000,00 no mesmo segundo. As duas passaram.

Resultado: R$ 9.000,00 sacados num dia com limite de R$ 5.000,00 e saldo de R$ −2.000,00. O saldo negativo que o capítulo 2 tinha enterrado saiu do caixão de terno, gravata e chave Pix cadastrada.

O *pull request* subiu numa sexta, claro. Ele somava os saques do dia dentro do *trigger* que já verificava o saldo e trazia uma linha do Carlos trocando o isolamento para *repeatable read*, com o comentário `# por segurança`. Nenhum teste falhou, porque nenhum teste abre duas abas. O Bazar abriu o chamado às 9h40: "URGENTE!!!! VENDEDOR COM SALDO NEGATIVO DE NOVO". O "de novo" doeu mais que as exclamações.

O financeiro, que não dorme desde o capítulo 1, emendou: "e se o servidor cair no meio de um split? O vendedor recebe e o Bazar não?". O que garante que um pagamento que escreve em quatro contas nunca fica pela metade? E como um isolamento mais rígido quebrou o que o mais frouxo protegia?

## Uma transação, quatro contas e zero meio-termo

Um Pix de R$ 100,00 no Bazar vira uma transação do ledger com quatro lançamentos (sinal do capítulo 1: positivo é débito, negativo é crédito):

```text
conta                              valor (centavos)
banco liquidante (ativo)                 +10000
vendedor 42, disponível                   -8701
comissão do Bazar (12%)                   -1200
receita de tarifas da Lastro (0,99%)        -99
soma                                          0
```

Os R$ 87,01 do vendedor voltam, desta vez sem os dois zeros a mais do Carlos. "Transação" agora tem dois sentidos, a linha em `transacoes` e a transação do banco, e a primeira só existe direito se couber inteira na segunda.

Uma **transação** de banco de dados é um grupo de operações com as garantias da sigla ACID (Härder e Reuter, 1983, quando o maior risco de um banco era alguém tropeçar no cabo).

**Atomicidade**: ou todas as escritas valem, ou nenhuma. No PostgreSQL, cada linha gravada carrega o identificador da transação que a criou (`xmin`). O *commit* é um registro no WAL (*write-ahead log*, o log que vai para o disco antes dos dados) e uma marca de "confirmada" no `pg_xact`. Se o processo morre antes, a transação conta como abortada. Abortar não apaga nada: as linhas ficam no disco, mortas e sem atestado de óbito, invisíveis, até o `VACUUM` passar recolhendo os corpos. O *rollback* do PostgreSQL é o luto mais barato da computação: ele só para de olhar.

**Consistência** é a letra intrusa: fala das invariantes da aplicação, e o banco só impõe as que você declarou. O *constraint trigger* do capítulo 1 confere a soma zero no `COMMIT`, e só consegue porque as quatro inserções estão na mesma transação. Fora de um `BEGIN` explícito, cada comando é uma transação sozinha; com quatro *commits*, o primeiro lançamento chegaria ao trigger somando +10000 e morreria ali.

**Durabilidade**: depois que o `COMMIT` retorna, a transação sobrevive a uma queda. Com `synchronous_commit = on` (o padrão), o `COMMIT` só responde depois do `fsync` do WAL. Com `off`, responde antes, e uma queda pode perder as últimas transações confirmadas, até três vezes o `wal_writer_delay` (600 ms com o padrão de 200 ms), sem corromper nada. Seiscentos milissegundos de pagamentos confirmados e esquecidos são uma tarde inteira de planilha. Perda de disco: capítulos 23 e 40.

**Isolamento**: transações concorrentes não enxergam o trabalho pela metade umas das outras. Quanto cada uma enxerga é o nível de isolamento, e foi aí que o Carlos tropeçou "por segurança".

## O padrão SQL define isolamento pelos defeitos

O padrão SQL (ISO/IEC 9075) define quatro níveis pelos fenômenos que cada um proíbe, a forma mais honesta já inventada de vender um produto: "este modelo vem sem *dirty read*; o *phantom* é opcional de fábrica".

- **Dirty read**: ler o que outra transação escreveu e não confirmou. Se ela aborta, você decidiu com dado que nunca existiu.
- **Non-repeatable read**: ler a mesma linha duas vezes e receber valores diferentes, porque outra transação alterou e confirmou no meio.
- **Phantom**: repetir uma consulta com `WHERE` e receber outro conjunto de linhas, porque outra transação inseriu ou apagou linhas do predicado.

| Nível | Dirty read | Non-repeatable read | Phantom |
|-------|-----------|---------------------|---------|
| Read uncommitted | possível | possível | possível |
| Read committed | não | possível | possível |
| Repeatable read | não | não | possível |
| Serializable | não | não | não |

Serializable ainda tem uma exigência a mais: o resultado de transações concorrentes precisa ser igual ao de alguma execução delas uma de cada vez, em alguma ordem.

Em 1995, Berenson, Bernstein, Gray, Melton e os dois O'Neil publicaram "A Critique of ANSI SQL Isolation Levels": as definições do padrão são ambíguas, e evitar os três fenômenos não basta para ser serializable. O artigo nomeou anomalias que a tabela esquece, o **lost update** (duas transações leem, calculam e gravam por cima, e uma escrita some) e o **write skew**, que logo será apresentado ao vendedor 42. E definiu o **snapshot isolation**, que não cabe em nenhuma linha da tabela e acabou implementado em metade do mercado com o nome de outra linha.

O "repeatable read" do PostgreSQL é snapshot isolation. O "serializable" do Oracle também, então lá o write skew passa até no nível mais alto, de crachá. O padrão do InnoDB (MySQL) é repeatable read, com semântica própria; o do PostgreSQL, read committed. O nome do nível é rótulo de embalagem; as anomalias ficam na documentação, em letra de bula.

## MVCC: o banco que guarda todas as versões da sua vida

O PostgreSQL implementa isolamento com **MVCC** (*multiversion concurrency control*). O `UPDATE` nunca altera a linha no lugar: grava uma versão nova (*tuple*) com `xmin` da transação atual e marca a velha com `xmax`. O `DELETE` só preenche o `xmax`. O banco é aquele ex que guarda todas as versões de você e escolhe qual mostrar conforme quem pergunta.

Quem pergunta carrega um **snapshot**: o maior identificador de transação já iniciado e a lista das que estavam em andamento naquele instante. Uma versão é visível se a transação do `xmin` confirmou antes do snapshot e a do `xmax`, se existir, não. Leitor não bloqueia escritor nem o contrário; só duas escritas na mesma linha se esperam, pelo lock de linha. O preço é o lixo: versões mortas se acumulam até o `VACUUM`, que só remove o que nenhum snapshot aberto ainda enxerga.

Os dois níveis diferem em quando tiram o snapshot:

- **Read committed**: um snapshot novo a cada comando. Por isso o `SUM` depois do `FOR UPDATE` do capítulo 2 enxergava o débito recém-confirmado.
- **Repeatable read**: um snapshot só, tirado no primeiro comando da transação (no primeiro comando, não no `BEGIN`), usado até o fim. Retrato congelado, que não muda por mais saques que aconteçam lá fora.

Nas escritas também. Em read committed, o `UPDATE` que encontra uma linha alterada por transação concorrente espera e, se a outra confirma, reavalia o `WHERE` na versão nova (o `UPDATE` condicional do capítulo 2). Em repeatable read, "o primeiro a atualizar vence": a segunda espera e, se a primeira confirmou, recebe isto:

```text
lastro=*> UPDATE contas SET bloqueada = true WHERE id = 42;
ERROR:  could not serialize access due to concurrent update
```

Isso mata o lost update: ler, somar no Python e gravar por cima, que em read committed apaga a escrita do vizinho, vira erro. O Carlos acertou metade do comentário. A outra metade custou R$ 2.000,00.

O detalhe que derruba a Lastro: a regra só dispara quando a outra transação **alterou ou apagou** a linha. Linha apenas travada com `FOR UPDATE` passa sem erro.

## Write skew: dois médicos de plantão e nenhum no hospital

O exemplo clássico da literatura: regra de pelo menos um médico de plantão, dois escalados, os dois pedem para sair ao mesmo tempo. Cada transação conta dois de plantão, conclui que pode sair e altera a própria linha. Nenhuma escrita colide, o snapshot isolation confirma as duas, e o hospital fica sem ninguém. Eu já fui esse plantão, e o monitoramento também tinha ido pra casa.

A definição: **write skew** acontece quando duas transações concorrentes leem dados que se sobrepõem, cada uma decide com base no que leu e cada uma escreve em linhas diferentes. Sozinha, cada uma preserva a invariante; juntas, violam. O snapshot isolation só detecta conflito de escrita na mesma linha, e aqui nenhuma linha foi escrita pelas duas. Quando a leitura é um predicado ("os saques do dia da conta 42"), as linhas do problema nem existiam na hora: são inserções novas, fantasmas que o snapshot nunca vai mostrar.

Na segunda-feira, foi isto:

```text
T1 (aba 2, R$ 4.000,00)                 T2 (aba 3, R$ 4.000,00)
BEGIN ISOLATION LEVEL REPEATABLE READ   BEGIN ISOLATION LEVEL REPEATABLE READ
primeiro comando: snapshot S1           primeiro comando: snapshot S2 (= S1)
INSERT saque -> trigger:                INSERT saque -> trigger:
  FOR UPDATE conta 42 (obtém)             FOR UPDATE conta 42 (espera...)
  saldo 6.000, sacado hoje 1.000: ok
COMMIT
                                          (obtém: linha só travada, sem erro)
                                          saldo 6.000, sacado hoje 1.000 (S2): ok
                                        COMMIT
resultado: saldo -2.000,00; sacado hoje 9.000,00
```

O trigger roda dentro da transação, com o snapshot dela. O `FOR UPDATE` fez as duas passarem em fila indiana pela porta, e o snapshot fez a segunda passar de olhos vendados. O débito de T1 já estava confirmado, mas T2 tinha tirado o retrato antes, e repeatable read é um juramento solene de nunca olhar a foto nova. Era a armadilha anunciada no capítulo 2, com limite diário de brinde.

Dentro do snapshot isolation há duas saídas. Uma é **materializar o conflito**: fazer as duas transações escreverem na mesma linha (um `UPDATE` na conta), e o write skew vira conflito de escrita que o "primeiro vence" detecta. A outra é voltar ao read committed com o lock do capítulo 2, em que o comando depois do lock lê dados frescos. As duas exigem descobrir, para cada regra, qual linha concentra o conflito, e que ela exista; quando não existe, alguém inventa uma linha só para brigar por ela.

## Serializable de verdade, com nota fiscal

Desde a versão 9.1, o serializable do PostgreSQL é **SSI** (*Serializable Snapshot Isolation*), algoritmo de Cahill, Röhm e Fekete (2008), implementado por Ports e Grittner. Ele roda sobre o snapshot isolation e acrescenta vigilância: cada leitura deixa um **SIRead lock**, um lock de predicado que não bloqueia ninguém e só anota "esta transação leu isto". Quando uma transação escreve algo que outra leu sem enxergar, o banco registra uma dependência leitura-escrita (*rw-antidependency*) entre as duas.

A base teórica: toda execução não serializável sob snapshot isolation tem um ciclo com duas arestas leitura-escrita consecutivas entre transações concorrentes. O PostgreSQL não procura o ciclo inteiro; ao ver a estrutura perigosa (uma transação "pivô" com uma aresta entrando e outra saindo), aborta uma das envolvidas, mesmo que o ciclo nunca se fechasse. Daí os falsos positivos, abortos por excesso de cautela, como o gerente que cancela o deploy de sexta que ia funcionar. Na conversa:

```text
App:        COMMIT.
PostgreSQL: ERROR: could not serialize access due to read/write
            dependencies among transactions
            DETAIL: Reason code: Canceled on identification as a pivot,
            during commit attempt.
            HINT: The transaction might succeed if retried.
App:        Mas eu fiz algo errado?
PostgreSQL: Você ia fazer. Tenta de novo.
```

O código do erro é SQLSTATE `40001` (`serialization_failure`). O preço do serializable fica todo aqui:

- **Retry obrigatório.** A aplicação repete a transação inteira, do `BEGIN`, refazendo leituras e decisões. Repetir só o `COMMIT` é inútil, e reaproveitar valores da tentativa anterior traz o write skew de volta pela porta dos fundos. O deadlock (`40P01`, capítulo 2) entra no mesmo tratamento.
- **Granularidade.** Leituras por índice travam linhas e páginas; um *seq scan* trava a tabela inteira para fins de SSI, e locks finos demais são promovidos a grossos (`max_pred_locks_per_transaction`, padrão 64). Mais grosso, mais falsos positivos: índice vira também questão de taxa de abort (capítulo 5).
- **Só vale entre serializables.** Uma transação em read committed ao lado fica fora da vigilância, como o `psql` do Carlos.
Em troca, protege qualquer invariante entre transações serializable, inclusive as que ninguém se deu ao trabalho de proteger, que são a maioria.

## Na Lastro: um nível para cada operação

Os requisitos: o pagamento com split grava tudo ou nada; todo débito de conta disponível respeita saldo e limite diário, venha de onde vier; extrato e conciliação leem um estado coerente ao longo de várias consultas. Para os débitos:

| Opção | Saldo e limite | Custo | Serve quando |
|-------|----------------|-------|--------------|
| Repeatable read (o PR de sexta) | write skew | nenhum, até segunda-feira | nunca, com regra sobre conjunto de linhas |
| Read committed + `FOR UPDATE` (capítulo 2) | corretos se a regra cabe sob o lock da conta | achar a linha que cobre cada regra nova | regras sobre uma linha; muitos débitos por conta |
| Repeatable read + conflito materializado | corretos | versão nova e WAL por débito; mesma análise por regra | sistema preso a repeatable read |
| Serializable | corretos para qualquer regra | `40001`, retry, falsos positivos | conflitos raros, regras que mudam |

Saldo e limite diário cabem sob o lock da conta, e o read committed do capítulo 2 resolveria os dois. A Lastro escolhe serializable pela fila do gerente de produto: limite noturno para Pix e limite menor para chave Pix cadastrada há menos de 24 horas, que lê a tabela de chaves, fora do lock da conta. Em read committed, cada regra nova exige descobrir qual linha travar, análise feita por quem estiver de plantão naquela sexta; em serializable, o SSI detecta o ciclo seja qual for a regra. O custo é pequeno: uns 400 saques por dia, conflito só quando a mesma conta debita duas vezes no mesmo instante, ou seja, quando o vendedor 42 está acordado.

| Operação | Nível | Motivo |
|----------|-------|--------|
| Pagamento com split | read committed, uma transação | só insere; nenhuma leitura decide escrita; soma zero no `COMMIT` |
| Débito de conta disponível (saque, estorno) | serializable, com retry | regras sobre conjuntos de linhas |
| Extrato, conciliação | repeatable read, `READ ONLY` | saldo inicial, lançamentos e saldo final no mesmo snapshot |

O fluxo do saque passa a ser:

```text
tentativa 1 a 3:
  BEGIN ISOLATION LEVEL SERIALIZABLE
    INSERT transação de saque + 2 lançamentos
      trigger: FOR UPDATE na conta; saldo e saques do dia
  COMMIT
  40001 ou 40P01 -> espera aleatória de 5 a 50 ms, próxima tentativa
  3 falhas ou outro erro -> saque recusado com erro temporário
depois do COMMIT: pedido de Pix ao banco parceiro
```

A espera aleatória evita nova colisão no mesmo milissegundo (capítulo 15). O Pix fica fora do laço: transação abortada não deixa rastro, Pix enviado não volta. Reenvio do saque pelo marketplace é assunto do capítulo 16.

O trigger mantém o `FOR UPDATE` do capítulo 2: em serializable, só organiza a fila (a segunda transação ainda recebe `40001` e repete); em read committed, segue protegendo os caminhos que escapam da regra, como o `psql` do Carlos. E passa a recusar débito em repeatable read, o único nível em que a receita falha:

```text
lastro=*> INSERT INTO lancamentos (transacao_id, conta_id, valor)
          VALUES (88231, 42, 400000);
ERROR:  débito em conta disponível recusado em repeatable read
HINT:   use serializable ou read committed (capítulo 3, vendedor 42)
```

A segunda-feira reprisada: T2 recebe `40001`, repete, tira um snapshot que já contém o débito de T1, encontra R$ 2.000,00 de saldo e R$ 5.000,00 sacados no dia, e recusa.

Com centenas de débitos por segundo na mesma conta, a taxa de `40001` cresce, cada abort joga trabalho fora, e o lock em read committed (mais as técnicas de conta quente do capítulo 4) custa menos. Num banco cujo serializable é snapshot isolation com outro nome, só o conflito materializado protege.

## Armadilhas e casos reais

> **Armadilha:** o retry que repete efeitos colaterais. Se o laço manda e-mail, chama o banco parceiro ou publica evento, cada `40001` gera um efeito a mais, e o vendedor recebe três "seu saque foi aprovado" para um saque recusado. Dentro do laço, só o que o `ROLLBACK` desfaz.

> **Armadilha:** a transação longa em repeatable read. Uma conciliação de 40 minutos segura um snapshot por 40 minutos, e o `VACUUM` não remove nenhuma versão morta que ele ainda possa ver, em tabela nenhuma. O ledger incha de cadáveres que ninguém pode enterrar porque um relatório ainda está olhando para eles. A sessão `idle in transaction` faz o mesmo sem nem trabalhar; `idle_in_transaction_session_timeout` executa a sessão parada.

> **Na vida real:** em 2017, Todd Warszawski e Peter Bailis publicaram "ACIDRain" (SIGMOD), sobre aplicações de e-commerce populares nos níveis de isolamento padrão dos bancos: 22 ataques em 12 aplicações, entre eles gastar o mesmo vale-presente várias vezes com requisições concorrentes. O vendedor 42 tem concorrência acadêmica.

> **Na vida real:** em 2020, o Jepsen testou o PostgreSQL 12.3 e encontrou anomalias do tipo write skew (G2-item, na nomenclatura de Adya) no nível serializable, por um bug no SSI corrigido na 12.4. Até o banco que vigia leituras teve um dia de vista cansada.

## Resumo

- ACID: atomicidade pelo *commit* no WAL; consistência são as invariantes declaradas; durabilidade pelo `fsync` do WAL.
- Níveis do padrão SQL definidos por fenômenos; lost update, write skew e snapshot isolation vêm de Berenson et al. (1995).
- MVCC: versões com `xmin` e `xmax`; snapshot por comando (read committed) ou por transação (repeatable read).
- Repeatable read do PostgreSQL é snapshot isolation: impede lost update, permite write skew.
- Serializable do PostgreSQL é SSI: abort com `40001`, falsos positivos, retry da transação inteira, efeitos externos fora do laço.

## A Lastro agora

O pagamento com split grava os quatro lançamentos numa transação só, em read committed, com a soma zero conferida no `COMMIT`. Débitos de conta disponível (saque e estorno) rodam em serializable, com até três tentativas para `40001` e `40P01`, espera aleatória de 5 a 50 ms e o Pix só depois do `COMMIT`. O trigger mantém o `FOR UPDATE`, confere saldo e limite diário de R$ 5.000,00 e recusa débito em repeatable read. Extrato e conciliação leem em repeatable read, `READ ONLY`. A linha `# por segurança` foi apagada, e foi a mudança mais segura do PR.

O vendedor 42 abriu a quinta aba, ganhou um `40001` particular e, na segunda tentativa, "saldo insuficiente". Saque único, partida dobrada, agora com nota fiscal do PostgreSQL. Enquanto isso, toda venda do Bazar escreve na mesma conta de comissão, e o Bazar acabou de anunciar a campanha "Black Friday o mês inteiro". Por enquanto ninguém trava essa conta. Por enquanto.

## Referências

- ISO/IEC 9075-2, *SQL/Foundation*, níveis de isolamento.
- Berenson, H. et al. *A Critique of ANSI SQL Isolation Levels*. SIGMOD 1995. <https://arxiv.org/abs/cs/0701157>
- Cahill, M. J.; Röhm, U.; Fekete, A. D. *Serializable Isolation for Snapshot Databases*. SIGMOD 2008.
- Ports, D. R. K.; Grittner, K. *Serializable Snapshot Isolation in PostgreSQL*. VLDB 2012. <https://arxiv.org/abs/1208.4179>
- Härder, T.; Reuter, A. *Principles of Transaction-Oriented Database Recovery*. ACM Computing Surveys, 1983.
- PostgreSQL. *Transaction Isolation*. <https://www.postgresql.org/docs/current/transaction-iso.html>
- PostgreSQL. *Serialization Failure Handling*. <https://www.postgresql.org/docs/current/mvcc-serialization-failure-handling.html>
- PostgreSQL. *Asynchronous Commit*. <https://www.postgresql.org/docs/current/wal-async-commit.html>
- Warszawski, T.; Bailis, P. *ACIDRain: Concurrency-Related Attacks on Database-Backed Web Applications*. SIGMOD 2017.
- Jepsen. *PostgreSQL 12.3*. <https://jepsen.io/analyses/postgresql-12.3>
