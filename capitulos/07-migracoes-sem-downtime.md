# Migrações de schema sem downtime

## "É só uma coluna", às 3h11 de um domingo

Às 3h11 de um domingo, dia 1º, o Carlos aplicou uma migração de duas linhas e a Lastro passou dezoito minutos sem registrar um centavo. Uma empresa de pagamentos que não registra pagamento tem nome técnico: ONG.

Na sexta, o gerente de produto tinha voltado de uma reunião com o Mercadito Hornero, um marketplace argentino, com a frase de sempre: "suporte a peso é só uma coluna". O Carlos escolheu domingo de madrugada "porque não tem ninguém usando". O Pix funciona 24x7. Às 3h de domingo, quem usa é exatamente o tipo de pessoa que vai reclamar.

O SQL que o Alembic gerou:

```sql
-- 0042_multimoeda.py  (autor: Carlos; descrição: "rapidinho")
ALTER TABLE lancamentos ADD COLUMN moeda text NOT NULL DEFAULT 'BRL';
ALTER TABLE lancamentos ALTER COLUMN valor TYPE numeric(20,4);
```

A segunda linha era o plano do Carlos para "caber qualquer moeda". Nem chegou a vez dela: a primeira travou antes, e travou tudo. A sessão de diagnóstico mostrava isto:

```text
 pid  | wait_event | blocked_by | query
------+------------+------------+---------------------------------------------
 8812 |            | {}         | SELECT ... -- fechamento mensal, desde 03:00
 9120 | relation   | {8812}     | ALTER TABLE lancamentos ADD COLUMN moeda ...
 9133 | relation   | {9120}     | INSERT INTO lancamentos ...
 9134 | relation   | {9120}     | INSERT INTO lancamentos ...
 9141 | relation   | {9120}     | SELECT ... FROM lancamentos -- extrato
```

O fechamento mensal do financeiro, uma transação repeatable read `READ ONLY` que começa às 3h do dia 1º e passa 38 minutos lendo o mês inteiro, segurava a tabela. O `ALTER` esperava por ele. E todo `INSERT` de pagamento esperava pelo `ALTER`, estourava o `lock_timeout` de 2 segundos (capítulo 4) e voltava com `55P03`. Às 3h19 o Bazar abriu chamado: "URGENTE!!!!". O template do helpdesk já preenche sozinho. Às 3h29 o Carlos viu o canal e apertou Ctrl+C. Na segunda, o financeiro conciliou 47 Pix à mão, com a calma de quem já perdeu tudo que tinha para perder.

O melhor: no PostgreSQL 16, a primeira linha leva milissegundos. Uma operação instantânea parou a empresa por dezoito minutos. A segunda reescreveria 45 milhões de linhas com a tabela trancada.

A pergunta do capítulo: como mudar o schema de uma tabela com 45 milhões de lançamentos, que recebe Pix a qualquer hora, sem parar nada?

## Todo ALTER TABLE quer a tabela só para ele

O capítulo 4 apresentou os oito modos de lock de tabela e prometeu os locks de DDL para cá. Promessa cumprida, com juros.

Quase todo `ALTER TABLE` pede `ACCESS EXCLUSIVE`, que conflita com todos os modos, inclusive com o `ACCESS SHARE` do `SELECT` mais inocente. Concedido, ninguém lê nem escreve na tabela. Mas ele dura o tempo da operação, e operação que só mexe no catálogo dura milissegundos.

O que assusta é a fila. O gerenciador de locks do PostgreSQL atende os pedidos em ordem: um pedido novo que conflita com um pedido **que está esperando** entra na fila atrás dele, mesmo que fosse compatível com o lock que está concedido agora. Isso evita que o `ALTER` morra de fome com uma procissão infinita de `SELECT`s passando na frente. O efeito colateral é o domingo do Carlos:

```text
Fechamento: (lendo o mês inteiro, ACCESS SHARE, sem pressa)
ALTER:      Preciso da tabela inteira. Espero.
INSERT:     Só quero inserir um Pix. Sou compatível com o fechamento.
Banco:      É, mas o ALTER chegou antes. Fila.
INSERT:     E se eu esperar dois segundos?
Banco:      55P03. Próximo.
Bazar:      (abre chamado)
```

O `ALTER` em si não fez nada por dezoito minutos. Ficou parado na porta, de braços abertos, impedindo a passagem. Um segurança de balada que nem trabalha na balada.

A defesa tem três partes:

1. **`lock_timeout` curto na sessão da migração**, de 1 a 2 segundos: sem lock, a migração desiste e libera a fila. A sessão do Carlos tinha o padrão do PostgreSQL, zero, que significa esperar para sempre. Paciência infinita é virtude em monge e defeito em migração.
2. **Retentativa com espera.** Uma hora a transação longa termina.
3. **Olhar antes de entrar.** `pg_stat_activity.xact_start` mostra as transações longas. O fechamento mensal estava lá desde 3h00, com o nome escrito no comentário.

```sql
SET lock_timeout = '1s';
ALTER TABLE lancamentos ADD COLUMN moeda text NOT NULL DEFAULT 'BRL';
-- ERROR:  canceling statement due to lock timeout
```

O pior caso vira "pagamentos esperaram 1 segundo, algumas vezes". Ninguém abre chamado por um segundo. (Mentira, o Bazar abre. Mas por um segundo ele abre com um ponto de exclamação só.)

Alguns subcomandos pegam só `SHARE UPDATE EXCLUSIVE`, que convive com leituras e escritas: `VALIDATE CONSTRAINT`, `SET STATISTICS` e parâmetros de armazenamento, como os de autovacuum. Por isso o `ALTER TABLE ... SET (autovacuum_analyze_scale_factor = 0)` do capítulo 6 passou sem ninguém notar. Único DDL do ano sem chamado, e ninguém comemorou.

## Seguras, perigosas e as que mentem sobre o que são

Uma operação de DDL pode custar três coisas, em ordem crescente de dor:

- **Só catálogo:** muda metadados em `pg_class` e `pg_attribute`. Milissegundos.
- **Varredura:** lê a tabela inteira para verificar uma restrição, com o lock segurado durante a leitura.
- **Reescrita:** copia a tabela linha a linha e reconstrói todos os índices, com disco dobrado e lock até o fim. É a migração que manda o plantonista atualizar o currículo.

No PostgreSQL 16:

| Operação | Custo | Lock | Alternativa sem parar |
|----------|-------|------|------------------------|
| `ADD COLUMN` sem default | catálogo | `ACCESS EXCLUSIVE` breve | já é segura (com `lock_timeout`) |
| `ADD COLUMN ... DEFAULT` constante | catálogo (desde a versão 11) | idem | já é segura |
| `ADD COLUMN ... DEFAULT` volátil (`clock_timestamp()`, `gen_random_uuid()`) | reescrita | `ACCESS EXCLUSIVE` longo | coluna sem default + backfill em lotes |
| `ALTER COLUMN TYPE` | reescrita + índices (salvo conversões binárias, como `varchar(n)` para `text`) | `ACCESS EXCLUSIVE` longo | coluna nova + expand/contract |
| `SET NOT NULL` | varredura | `ACCESS EXCLUSIVE` longo | `CHECK (col IS NOT NULL) NOT VALID`, `VALIDATE`, então `SET NOT NULL` |
| `ADD CONSTRAINT ... CHECK` / `FOREIGN KEY` | varredura | `ACCESS EXCLUSIVE` / `SHARE ROW EXCLUSIVE` | `NOT VALID` + `VALIDATE CONSTRAINT` |
| `CREATE INDEX` | leitura completa | `SHARE` (bloqueia escritas) | `CREATE INDEX CONCURRENTLY` |
| `ADD CONSTRAINT ... UNIQUE` | leitura + índice | `ACCESS EXCLUSIVE` | índice único `CONCURRENTLY` + `UNIQUE USING INDEX` |
| `DROP COLUMN` | catálogo | `ACCESS EXCLUSIVE` breve | segura para o banco; perigosa para o código antigo |
| `RENAME COLUMN` | catálogo | `ACCESS EXCLUSIVE` breve | segura para o banco; fatal para o código antigo |

A primeira linha do Carlos estava na segunda linha da tabela. Desde o PostgreSQL 11, um default constante não toca nas linhas existentes: o valor fica guardado no catálogo e o banco o devolve para toda linha antiga que não tem a coluna fisicamente.

```sql
SELECT attname, atthasmissing, attmissingval
FROM pg_attribute
WHERE attrelid = 'lancamentos'::regclass AND attname = 'moeda';
```

```text
 attname | atthasmissing | attmissingval
---------+---------------+---------------
 moeda   | t             | {BRL}
```

Quarenta e cinco milhões de linhas passam a ter moeda `BRL` sem que nenhuma tenha sido escrita. A maior mentira coletiva já contada por um banco de dados, e perfeitamente consistente. Default volátil não tem esse atalho: `clock_timestamp()` precisa de um valor por linha, e o banco reescreve a tabela para calcular cada um.

A segunda linha, `bigint` para `numeric(20,4)`, reescreve ~3 GB de heap e reconstrói ~4,5 GB de índices sob `ACCESS EXCLUSIVE`: pela conta da equipe, seis a dez minutos de Lastro fechada, fora a fila. De brinde, desfazia a decisão do capítulo 1 de guardar dinheiro em inteiro. Uma migração com dois defeitos, e o menor era derrubar a produção.

`ADD CONSTRAINT ... NOT VALID` registra a restrição e a aplica a toda linha nova ou alterada, sem verificar as existentes; o lock é breve. Depois, `VALIDATE CONSTRAINT` varre a tabela com `SHARE UPDATE EXCLUSIVE` (mais `ROW SHARE` na tabela referenciada, se for chave estrangeira), que não bloqueia `INSERT` nem `UPDATE`. A varredura demora o mesmo tanto, só que ninguém espera por ela. E, desde o PostgreSQL 12, `SET NOT NULL` pula a varredura se houver um `CHECK (col IS NOT NULL)` válido: o banco aceita a palavra de uma restrição já verificada, coisa que nenhum auditor faz.

`CREATE INDEX CONCURRENTLY` já apareceu no capítulo 5, quando o índice do Carlos derrubou o Pix numa quinta. Dois detalhes importam aqui: ele não aceita bloco de transação (no Alembic, exige o `autocommit_block()`) e, se falhar no meio, deixa para trás um índice `INVALID`, que não serve consultas e continua sendo atualizado em toda escrita. Um índice zumbi: morto para a leitura, vivo para a fatura.

## Expand/contract, a migração em prestações

Mesmo com DDL instantâneo, sobra o código. Em `temp-01`, o reload troca os 3 workers um por vez, e por uns 40 segundos v1 e v2 atendem juntas. Se o deploy der errado, v1 volta para o schema que v2 deixou. O schema precisa servir duas versões de código ao mesmo tempo, sempre.

O padrão expand/contract (também chamado *parallel change*) quebra uma mudança incompatível numa sequência de mudanças compatíveis:

1. **Expand:** acrescentar a estrutura nova sem tirar a velha. Coluna nova, tabela nova, restrição `NOT VALID`.
2. **Migrar escritas:** deploy de código que escreve nos dois lugares.
3. **Backfill:** copiar o histórico para a estrutura nova.
4. **Migrar leituras:** deploy de código que lê da estrutura nova.
5. **Contract:** quando nenhuma versão viva usa mais a estrutura velha, removê-la.

É a mesma sequência de deprecar um parâmetro de função numa biblioteca: aceitar os dois nomes, avisar, migrar os chamadores, e só então remover o antigo. Ninguém remove um parâmetro e publica a biblioteca na mesma versão, a não ser quem quer receber issues em caixa alta.

Renomear `cliente_email` para `email` vira cinco passos em três deploys. O `RENAME COLUMN` direto também leva três: um para quebrar, um para tentar consertar e um de rollback às 4h. A compatibilidade:

| | Schema antigo | Schema expandido | Schema contraído |
|---|---|---|---|
| Código v1 | funciona | funciona | quebra |
| Código v2 | quebra | funciona | funciona |

A ordem segura sai daí: expand antes do deploy de v2, contract depois que v1 morreu e não pode voltar por rollback. Nenhuma combinação viva pode cair num "quebra".

## Backfill em lotes, ou como atualizar 45 milhões de linhas sem ninguém perceber

O passo 3 é onde a migração costuma ficar gorda. A tentação é um `UPDATE` só:

```sql
UPDATE clientes SET email = cliente_email;  -- uma transação, 45 milhões de linhas
```

No MVCC (capítulo 3), cada linha atualizada ganha uma versão nova e a antiga vira tupla morta. Numa transação só, são 45 milhões de versões novas: a tabela quase dobra, o WAL sai numa enxurrada, o lock de cada linha fica até o `COMMIT` e o VACUUM não limpa nada mais novo que ela enquanto durar. Se falhar no minuto 40, o rollback é instantâneo, e os 40 minutos de tuplas mortas ficam lá, como cadáveres que ninguém vai reclamar.

O backfill em lotes troca uma transação gigante por milhares de transações pequenas:

```sql
-- lote de 5.000 pela chave primária; o próximo começa em 1210000
UPDATE clientes
SET email = cliente_email
WHERE id >= 1205000 AND id < 1210000
  AND email IS NULL;
-- UPDATE 4987
```

As propriedades que importam:

- **Lote pequeno por faixa da PK.** Cada lote termina em milissegundos e segura poucos locks. É a paginação por cursor do capítulo 6 aplicada a escrita.
- **Idempotente e retomável.** Com `email IS NULL`, repetir um lote não faz nada; o processo pode morrer na faixa 1.205.000 e recomeçar dali. Morrer é normal; ressuscitar sem duplicar é o que se pede.
- **Ritmo controlado.** A pausa entre lotes deixa o autovacuum limpar e as réplicas acompanharem o WAL (lag de replicação, capítulo 23). Uma hora ou uma noite custam as mesmas escritas; só uma aparece no gráfico de latência.
- **Escrita dupla antes do backfill.** Senão, toda linha alterada depois que o lote passou fica com o valor velho, a verificação acha 3 mil buracos e alguém descobre que a ordem dos passos tinha motivo.

Se a coluna não tem índice e a página tem espaço, o `UPDATE` é HOT (capítulo 5) e nem toca nos índices.

## O ledger da Lastro aprende espanhol

O Mercadito Hornero vai cobrar em pesos argentinos, e o ledger precisa parar de supor que todo número é real. As restrições:

- Pix 24x7: não há janela de manutenção, nem às 3h de domingo, como foi demonstrado empiricamente.
- `lancamentos` tem ~45 milhões de linhas, ~3 GB de heap, ~4,5 GB de índices, e é imutável: o trigger "tabelião" do capítulo 1 recusa `UPDATE`. Backfill em `lancamentos` morre na porta do cartório.
- Valores seguem em `bigint` na unidade mínima (capítulo 1). O ISO 4217 define as casas decimais: BRL e ARS têm 2, o iene 0, o dinar do Bahrein 3. Uma tabela `moedas (codigo, casas_decimais)` guarda isso; o `numeric(20,4)` do Carlos não resolvia nem o dinar.

As alternativas:

| Alternativa | Lock pesado | Disco extra | Pix durante | Custo |
|-------------|-------------|-------------|-------------|-------|
| Migração do Carlos numa janela | `ACCESS EXCLUSIVE` por 6 a 10 min, mais a fila | ~7,5 GB temporários | parado | proibida pelo 24x7 |
| Tabela nova + cópia + troca de nome (o método do gh-ost e do pt-online-schema-change no MySQL) | segundos, na troca | ~7,5 GB | segue | sincronizar 45 milhões de linhas com a tabela mais quente da empresa; troca ainda pede `ACCESS EXCLUSIVE` |
| Expand/contract com default constante | milissegundos por passo | quase zero | segue | duas migrações em dois deploys e disciplina de ordem |

A Lastro fica com expand/contract: o 24x7 exige que nenhum passo segure `ACCESS EXCLUSIVE` por mais que o `lock_timeout`, e o default constante entrega isso. E encaixa na imutabilidade: todo lançamento histórico é em real, e o `attmissingval` diz isso sem `UPDATE` nenhum. O tabelião nem acorda.

A moeda vai para `contas` (uma moeda por conta; o vendedor argentino ganha contas em ARS) e é copiada em `lancamentos`. O capítulo 1 cobrou o custo de manter cópias; aqui o banco paga: a chave estrangeira composta `lancamentos (conta_id, moeda) → contas (id, moeda)` torna impossível um lançamento em pesos numa conta em reais. Em troca, o trigger de soma zero agrupa por `(transacao_id, moeda)` sem juntar com `contas`, a tabela mais disputada do ledger (capítulo 4). Câmbio, quando existir, serão duas pernas com uma conta de câmbio em cada moeda.

```text
FASE 1  EXPAND  (migração 0043, antes do deploy)      serve v1 e v2
  moedas (codigo, casas_decimais): BRL 2, ARS 2
  contas.moeda       NOT NULL DEFAULT 'BRL'  FK -> moedas   (~9 mil linhas)
  índice único (id, moeda) em contas: CONCURRENTLY + UNIQUE USING INDEX
  lancamentos.moeda  NOT NULL DEFAULT 'BRL'                 (só catálogo)
  FK (conta_id, moeda) -> contas (id, moeda)  NOT VALID
  VALIDATE CONSTRAINT                          (~4 min, sem bloquear)
  trigger de soma zero por (transacao_id, moeda)

FASE 2  DEPLOY v2                                     v1 e v2 convivem
  v2 grava moeda explicitamente; janela de rollback: 7 dias

FASE 3  USO
  contas ARS do Mercadito Hornero e de seus vendedores

FASE 4  CONTRACT  (migração 0044, só depois que v1 não pode voltar)
  lancamentos.moeda  DROP DEFAULT
  DROP da FK simples conta_id -> contas (redundante com a composta)
```

Cada passo usa `lock_timeout = '1s'`, até cinco tentativas com espera crescente e `statement_timeout` próprio. O `VALIDATE` lê os 45 milhões de linhas por uns 4 minutos (estimativa) com pagamentos entrando, porque a FK `NOT VALID` já vale para toda linha nova. Nenhuma migração começa com transação longa em `lancamentos`, e o calendário do fechamento mensal entrou no checklist.

O `DROP DEFAULT` da fase 4 existe porque, com contas ARS, um caminho esquecido que insere sem moeda gravaria `BRL` por omissão; a FK composta recusaria, mas o erro de `NOT NULL` é mais claro. O histórico não muda: o `attmissingval` continua lá. O caminho esquecido tem nome: `repasse_final_v2_agora_vai.py`, que roda pelo cron com a própria cópia do código, atualizada quando alguém pensa nele. Na fase 4, ele quebra em vez de pagar um argentino em reais. Pela primeira vez na história, o job vai falhar do jeito certo.

Com janela de manutenção (um produto só de cartão em horário comercial, por exemplo), a migração direta seria mais simples e o risco, aceitável. Se fosse preciso mudar o tipo de `valor` de verdade, o default não ajudaria, o backfill esbarraria na imutabilidade, e a cópia para tabela nova com troca de nome passaria a ser a opção viável, com todo o seu custo.

## Armadilhas e casos reais

> **Armadilha:** o autovacuum comum cede: se ele bloqueia o lock de um DDL, o PostgreSQL o cancela. O autovacuum de prevenção de *wraparound* de ID de transação não cede. Sua migração entra na fila atrás dele, os pagamentos entram na fila atrás da migração, e o log mostra `(to prevent wraparound)`, a única mensagem do PostgreSQL que soa como ameaça.

> **Armadilha:** o SQLAlchemy lista as colunas do model em todo `SELECT` e `INSERT`. Remova uma coluna que v1 ainda mapeia e cada requisição de v1 morre com `column "x" does not exist`, em ordem de chegada. Primeiro o deploy que deixa de mapear, depois o `DROP`.

> **Armadilha:** o `CREATE INDEX CONCURRENTLY` que falhou por violação de unicidade deixa o índice `INVALID` atualizado em toda escrita, sem servir consulta nenhuma. `\d tabela` mostra a palavra `INVALID` no fim da linha. Ninguém olha. O disco olha.

> **Na vida real:** o GitHub criou o gh-ost, migração online para MySQL, porque ferramentas baseadas em triggers, como o pt-online-schema-change da Percona, somavam carga e disputa de locks às tabelas mais movimentadas. O gh-ost lê o log binário em vez de usar triggers. Os dois copiam a tabela e trocam o nome no fim, a alternativa que a Lastro descartou.

> **Na vida real:** a gem strong_migrations, do Rails, recusa por padrão operações perigosas no PostgreSQL (default volátil, `ALTER COLUMN TYPE`, índice sem `CONCURRENTLY`) e indica a sequência segura de cada uma. A documentação dela vira checklist de revisão em qualquer linguagem, inclusive em Python, que ela ignora com toda razão.

O Carlos, para constar, propôs aplicar a migração 0043 "na hora do almoço, que é tranquilo". O almoço é o pico de Pix do Bazar.

## Resumo

- `ALTER TABLE` quase sempre pede `ACCESS EXCLUSIVE`; o DDL esperando bloqueia quem chega depois. `lock_timeout` curto e retentativa.
- DDL custa catálogo, varredura ou reescrita; default constante é catálogo (PostgreSQL 11+); mudança de tipo reescreve.
- `NOT VALID` + `VALIDATE`; `SET NOT NULL` via `CHECK`; índices `CONCURRENTLY`.
- Expand/contract: schema compatível com duas versões de código.
- Backfill em lotes pela PK, idempotente, retomável, depois da escrita dupla.

## A Lastro agora

O ledger tem moeda: `moedas` com as casas decimais do ISO 4217, `contas.moeda` e `lancamentos.moeda` com default `'BRL'` só no catálogo, FK composta `(conta_id, moeda)` e soma zero por moeda. Toda migração usa `lock_timeout` de 1 segundo, retentativa, checagem de transações longas, e expand e contract em deploys separados; a 0044 espera 7 dias de rollback. O Pix não percebeu nada.

O gerente acertou: era só uma coluna. Foram duas migrações, dois deploys, uma FK composta, um trigger novo e 47 Pix conciliados à mão, mas era só uma coluna. Agora o Mercadito Hornero reclama que cada chamada à API leva 300 ms a mais do que o processamento, e o fundador quer trocar `temp-01` por um servidor novo: "é só mudar o IP no DNS". É só um registro.

## Referências

- PostgreSQL 16, `ALTER TABLE` (locks por subcomando, `NOT VALID`, `VALIDATE CONSTRAINT`, `SET NOT NULL`): https://www.postgresql.org/docs/16/sql-altertable.html
- PostgreSQL 16, locks explícitos e conflitos entre modos: https://www.postgresql.org/docs/16/explicit-locking.html
- PostgreSQL 16, `CREATE INDEX` (construção concorrente e índices inválidos): https://www.postgresql.org/docs/16/sql-createindex.html
- PostgreSQL 16, parâmetros `lock_timeout` e `statement_timeout`: https://www.postgresql.org/docs/16/runtime-config-client.html
- PostgreSQL 16, autovacuum e prevenção de wraparound: https://www.postgresql.org/docs/16/routine-vacuuming.html
- PostgreSQL 11, notas de versão (`ADD COLUMN` com default não volátil sem reescrita): https://www.postgresql.org/docs/release/11.0/
- Danilo Sato, "ParallelChange": https://martinfowler.com/bliki/ParallelChange.html
- ISO 4217, códigos de moeda: https://www.iso.org/iso-4217-currency-codes.html
- Alembic, `MigrationContext.autocommit_block`: https://alembic.sqlalchemy.org/en/latest/api/runtime.html
- gh-ost: https://github.com/github/gh-ost
- strong_migrations: https://github.com/ankane/strong_migrations
