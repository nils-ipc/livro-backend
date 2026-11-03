# Índices

## O extrato de seis segundos e o índice de quarenta e oito

O gerente de produto disse que era só um índice, e o Carlos, que nunca deixou um gerente sem resposta, criou um índice às 15h40 de uma quinta-feira, em produção, sem perguntar a ninguém. Foi o único momento da história da Lastro em que o gerente e o Carlos concordaram, e o banco puniu os dois.

O vendedor 7310, a Capinhas Hiper Ltda., maior do Bazar, espera seis segundos pela primeira página do extrato de outubro. `lancamentos` passou de 40 milhões de linhas, 1,1 milhão delas da Capinhas, e o extrato filtra por conta e por `criado_em` (`timestamptz`, *default* `now()`). Os índices eram três: chave primária, `transacao_id` e `conta_id`, este desde o trigger de saque do capítulo 2. O Carlos:

```sql
CREATE INDEX lancamentos_criado_em_idx ON lancamentos (criado_em);
-- 48 segundos. "Rapidinho." (Carlos, 15h40)
```

`CREATE INDEX` sem `CONCURRENTLY` pega um lock `SHARE` na tabela, que conflita com o `ROW EXCLUSIVE` de qualquer escrita (capítulo 4). O `lock_timeout` de 2 segundos, aquele que salvou o pool, cumpriu o dever: os pagamentos receberam `55P03` e morreram limpos, sem fila. Quarenta e oito segundos de Pix recusado. O Carlos chama isso de "rapidinho"; o Bazar chamou de "URGENTE!!!!", assunto que já tem template próprio no helpdesk.

E o extrato foi de 6,0 para 5,8 segundos. Por que um índice em `criado_em` quase não ajudou uma consulta que filtra por `criado_em`? E qual índice resolve sem cobrar pedágio em cada lançamento de cada pagamento?

## A B-tree por dentro, ou a busca binária que foi para a academia

O índice padrão do PostgreSQL é a *B-tree* (`nbtree`, variante de Lehman e Yao): chaves ordenadas em páginas de 8 KB, em níveis. A busca é uma busca binária em que cada página interna divide o intervalo em centenas, e não em dois.

```text
                 [raiz: ... | 5000 | 9100 | ...]
                 /              |              \
   [interno: ...|7300|7320|...]   ...           ...
             |
   [folha: (7310, out/01 00:02) ... (7310, out/01 00:09)] <-> [folha seguinte]
             |
           TID (bloco 811204, item 7) -> linha na tabela (heap)
```

As **páginas internas** (a raiz é uma delas) guardam chaves separadoras e ponteiros para as páginas de baixo. As **folhas** guardam as chaves, cada uma com um **TID** (*tuple identifier*: bloco e posição da linha na tabela), e são encadeadas às vizinhas: uma busca por faixa desce até o primeiro valor e depois anda de lado. O ponteiro para a irmã da direita é o truque de Lehman e Yao que deixa a leitura seguir enquanto outra transação divide uma página.

A conta do fan-out: uma entrada `BIGINT` ocupa uns 20 bytes, e uma página comporta perto de 400. Para 40 milhões de chaves, cerca de 110 mil folhas, umas 280 páginas internas e uma raiz. Três níveis. Com 400 vezes mais dados, quatro. Raiz e internos ficam em memória; a folha custa no máximo uma leitura de disco.

Folha cheia se divide (*page split*): metade das entradas vai para uma página nova e o pai ganha uma separadora. Se o pai enche, divide também, até a raiz, que ganha uma raiz nova acima dela. A árvore só cresce para cima, e todas as folhas ficam à mesma distância da raiz. Única hierarquia do planeta em que todo mundo lá embaixo está a exatamente três reuniões do topo.

Desde o PostgreSQL 13, a **deduplicação** guarda uma chave repetida uma vez só, com a lista de TIDs: o índice em `conta_id`, com 1,1 milhão de entradas `7310`, agradece. A B-tree responde a `=`, faixas, `IN`, `IS NULL`, prefixo de `LIKE` (com ressalva de *collation*, nas armadilhas) e `ORDER BY` nos dois sentidos, porque as folhas são percorridas para a frente e para trás. Dado que sai ordenado do índice dispensa o `Sort`, a etapa do plano que mais ama memória e a sua espera.

## O que o índice guarda, e a visita obrigatória à tabela

A folha guarda a chave e o TID. Só isso. Ela não sabe se a linha apontada está viva.

Pelo MVCC (capítulo 3), a visibilidade mora no `xmin` e no `xmax` da linha, e o índice aponta para todas as versões, vivas, mortas e não nascidas. É um necrotério com a ficha de todo mundo e sem atestado de óbito de ninguém. Saber se a linha existe para você exige ir à tabela, o *heap*, e olhar: um *index scan* que devolve 96 mil linhas faz até 96 mil visitas a blocos espalhados.

A saída é o **index-only scan**: se todas as colunas de que a consulta precisa estão no índice, o banco pula o heap, desde que a página esteja marcada como *all-visible* no **visibility map** (um bit por página, mantido pelo `VACUUM`). Página não marcada, visita obrigatória, contada no plano como `Heap Fetches`. Para pôr colunas no índice sem fazê-las parte da chave, existe o **índice de cobertura** com `INCLUDE`: as colunas extras vão só nas folhas e servem para devolver, nunca para buscar. Custa tamanho, e índice com `INCLUDE` não usa deduplicação.

Tabela append-only é o caso ideal: linha sem `UPDATE` nem `DELETE` fica visível para sempre depois do `VACUUM`, que desde o PostgreSQL 13 também dispara por volume de inserções. O ledger imutável do capítulo 1 ganha o elogio do VACUUM. Única tabela da Lastro com ficha limpa, e só porque é proibida de fazer qualquer coisa.

## A ordem das colunas, ou o índice lê da esquerda para a direita

Um **índice composto** em `(a, b)` ordena por `a` e, dentro de cada `a`, por `b`:

| Condição | Índice `(conta_id, criado_em)` | Índice `(criado_em, conta_id)` |
|----------|-------------------------------|-------------------------------|
| `conta_id = 7310` | faixa contígua | varre o índice inteiro |
| `conta_id = 7310 AND criado_em` em outubro | faixa contígua e exata | faixa de outubro inteira, filtrando conta |
| `criado_em` em outubro, todas as contas | varre o índice inteiro | faixa contígua |
| `ORDER BY criado_em DESC` com `conta_id = 7310` | já ordenado | precisa ordenar |

A regra: igualdade primeiro, faixa ou ordenação por último. Com a igualdade na frente, a Capinhas em outubro ocupa folhas contíguas; com a faixa na frente, aparece salpicada no outubro de todo mundo, uma entrada a cada quarenta.

O índice do Carlos, só em `criado_em`, é a faixa na frente sem nem ter a conta atrás. Outubro tem 5,4 milhões de lançamentos; o índice acha todos, o heap é visitado para cada um, e 98% vão para o lixo por serem de outro vendedor. O planner fez a conta e voltou para o índice em `conta_id`, com a cara de quem recebeu um presente de amigo secreto e já guardou a nota para trocar. O Carlos indexou o calendário e ficou magoado quando o calendário não sabia quem era a Capinhas. Em defesa dele, o índice sabia exatamente quando ela vendeu. Junto com outros 9 mil vendedores. No mesmo milissegundo.

`(conta_id, criado_em)` serve também a buscas só por `conta_id` (o prefixo da esquerda está ordenado), e o índice antigo vira redundante. Sem condição na primeira coluna, o composto fica quase inútil. Quase: o PostgreSQL 18 trouxe o *skip scan*, que pula entre os valores distintos da primeira coluna quando eles são poucos. Com uns 9 mil valores distintos de `conta_id`, o skip scan desceria a árvore 9 mil vezes para achar outubro, o que dá mais trabalho do que o Carlos teve para derrubar o Pix.

## Seletividade, cardinalidade e o dia em que o planner ignora o seu índice

**Cardinalidade** é o número de valores distintos de uma coluna; **seletividade**, a fração das linhas que uma condição devolve: `conta_id = 7310` devolve 2,75%; `estado = 'paga'` em `cobrancas`, uns 95%. Índice em coluna de 95% é decoração.

O planner pesa I/O: por padrão, `seq_page_cost = 1` e `random_page_cost = 4`, ou seja, pular de bloco em bloco seguindo TIDs custa quatro vezes mais por página do que ler em sequência. Com fração grande, o *seq scan* ganha. No meio fica o *bitmap scan*: junta os TIDs num mapa de blocos e lê cada bloco do heap uma vez, em ordem física.

As frações vêm das estatísticas do `ANALYZE`: valores mais comuns, histograma e a **correlação** entre a ordem física da tabela e a do índice. `criado_em` numa tabela append-only tem correlação perto de 1; `conta_id`, perto de zero, porque a Capinhas vende o dia todo junto com todo mundo e tem lançamento em quase toda página. Leitura de planos é o capítulo 6; aqui basta o extrato antes da correção:

```text
Limit (actual time=6011.4..6011.5 rows=50 loops=1)
  ->  Sort (actual time=6011.4..6011.4 rows=50 loops=1)
        Sort Key: criado_em DESC
        ->  Bitmap Heap Scan on lancamentos (actual time=401.2..5968.0 rows=96211 loops=1)
              Recheck Cond: (conta_id = 7310)
              Filter: ((criado_em >= '2026-10-01 03:00:00+00') AND (criado_em < '2026-11-01 03:00:00+00'))
              Rows Removed by Filter: 1004127
              Heap Blocks: exact=287412
              ->  Bitmap Index Scan on lancamentos_conta_id_idx (rows=1100338 loops=1)
Execution Time: 6012.9 ms
```

O índice achou 1,1 milhão de linhas, o banco visitou 287 mil dos 330 mil blocos da tabela para jogar fora um milhão delas por serem de outro mês, e ordenou o resto para mostrar cinquenta. Leu 2,2 GB para exibir uma página. Dava para baixar o extrato em forma de filme.

## Parciais, de expressão e os índices que não são árvore

Um **índice parcial** tem `WHERE`: só guarda as linhas do predicado, e só serve à consulta cuja condição o implica. Um **índice de expressão** indexa o resultado de uma expressão, como `lower(email)`, e só serve para consultas com a mesma expressão; a função precisa ser `IMMUTABLE`, porque o valor no índice não pode mudar sem a linha mudar. Fora da B-tree:

| Tipo | Estrutura | Responde a | Custo e limite |
|------|-----------|------------|----------------|
| Hash | buckets do hash de 32 bits | só `=` | sem `UNIQUE`, multicoluna nem ordem; WAL só desde o 10 |
| GIN | invertido: elemento → lista de linhas | arrays, `jsonb` (`@>`, `?`), texto | escrita cara; `fastupdate` gera lista pendente que a leitura varre |
| GiST | árvore de "caixas" que contêm as de baixo | geometria, faixas (`&&`), vizinho mais próximo, exclusão | busca desce por ramos sobrepostos |
| BRIN | mínimo e máximo por faixa de blocos | faixas em coluna correlacionada | minúsculo; inútil sem correlação |

O hash guarda 4 bytes por chave e ganha em tamanho com chave longa. O GIN existe porque uma B-tree num `jsonb` indexa o documento inteiro como um valor, e ninguém procura cobrança pelo JSON completo. O BRIN indexa `criado_em` dos 40 milhões de lançamentos em algumas dezenas de KB. O índice do Carlos tinha 500 MB e foi ignorado; um BRIN do tamanho de um GIF de gatinho teria servido melhor à conciliação.

## Cada índice é um imposto sobre a escrita

Cada `INSERT` grava a linha no heap e uma entrada em cada índice, cada uma com seu registro no WAL. Como o índice do PostgreSQL aponta para a posição física, um `UPDATE` que põe a versão nova em outro lugar precisa de entrada nova em todos os índices, inclusive nos das colunas que nem mudaram. A linha mudou um centavo, e cinco índices precisaram ser avisados, por escrito, com cópia para o WAL.

A exceção é o **HOT** (*heap-only tuple*): sem coluna indexada alterada e com espaço na página, a versão nova é encadeada à antiga, sem tocar índice. Indexar uma coluna que vive mudando, como `cobrancas.estado`, desliga o HOT de toda transição de estado (coluna de predicado de índice parcial conta como indexada). Um índice "inofensivo" dobra o custo do `UPDATE` mais frequente do sistema, e a fatura chega no fim do mês junto com a do disco.

E há localidade. Um índice em `criado_em` recebe toda inserção na folha mais à direita, sempre quente; um em `(conta_id, criado_em)`, no fim da faixa de cada conta, espalhada por milhares de folhas. Depois de cada *checkpoint*, a primeira alteração de cada página grava a página inteira no WAL (*full-page write*): mais páginas distintas, mais WAL. O imposto da escrita é pago por todo mundo, inclusive por quem nunca abriu o extrato na vida.

## Os índices do ledger, escolhidos pelo que se lê

Uma semana de produção medida em `lancamentos`, no pico: ~50 inserções/s; ~20 extratos/s (conta mais faixa de `criado_em`, ordenado); ~5 buscas/s por `transacao_id` (estorno); ~1 `SUM` por conta/s no trigger de débito; e a conciliação, uma vez por dia, lendo o dia inteiro. As alternativas para o extrato:

| Opção | Extrato da Capinhas | Escrita | Tamanho estimado |
|-------|---------------------|---------|------------------|
| Manter `(conta_id)` | 6 s | 1 entrada | ~300 MB (deduplicado) |
| `(criado_em)` do Carlos | 5,8 s | 1 entrada, página quente | ~500 MB |
| `(conta_id, criado_em)` | ~3 ms, visita o heap | 1 entrada | ~1,2 GB |
| `(conta_id, criado_em) INCLUDE (valor, transacao_id)` | ~0,3 ms, index-only | 1 entrada | ~2 GB |

A Lastro escolhe a última e apaga a do Carlos e a de `conta_id`. O requisito: extrato de qualquer vendedor abaixo de 100 ms, incluindo o saldo anterior ao período, um `SUM(valor)` sobre a mesma faixa de chave. Com `valor` nas folhas, listagem e soma viram index-only scan, e o `SUM` do trigger de débito (capítulos 2 e 3) ganha o mesmo atalho. Sendo append-only, `Heap Fetches` fica perto de zero:

```text
Limit (actual time=0.041..0.198 rows=50 loops=1)
  ->  Index Only Scan Backward using lancamentos_conta_criado_idx on lancamentos
        Index Cond: ((conta_id = 7310) AND (criado_em >= '2026-10-01 03:00:00+00')
                     AND (criado_em < '2026-11-01 03:00:00+00'))
        Heap Fetches: 0
Execution Time: 0.231 ms
```

Seis segundos viraram 0,23 milissegundo, e o `Backward` entrega o `ORDER BY criado_em DESC` lendo as folhas de trás para a frente, sem `Sort`.

O imposto: continuam três índices e três entradas por inserção. O composto espalha escrita, e em homologação o `INSERT` de lançamento foi de 0,11 para 0,13 ms, com 15% a mais de WAL, folga larga no orçamento de posse de 2 ms do capítulo 4. A conciliação, que lê um dia inteiro de todas as contas, ganha um BRIN em `criado_em`: dezenas de KB, escrita desprezível, até as partições por tempo do capítulo 24.

Fora do ledger, em `cobrancas`:

- `(expira_em) WHERE estado = 'pendente'`, parcial, para o job que expira Pix não pagos. Só 0,3% das cobranças estão pendentes, e o HOT perdido é o de uma transição que acontece uma vez por cobrança.
- `(marketplace_id, (metadata->>'pedido_id'))`, de expressão, para o Bazar buscar pelo pedido que manda no `metadata` (`jsonb`). Com uma chave só buscada, a B-tree basta; se os marketplaces passarem a buscar chaves arbitrárias, um GIN com `jsonb_path_ops`, mais caro na escrita, vira a escolha certa.

E as chaves de identificação (CNPJ, chave Pix, EndToEndId) passam a `COLLATE "C"`, pelo motivo da primeira armadilha.

O Carlos pediu para manter o índice dele "por segurança". O `pg_stat_user_indexes` mostrou `idx_scan = 0`. Foi enterrado com honras: 500 MB, zero leituras, uma vida inteira dedicada a atrasar `INSERT`. Deixa viúva (a fatura do disco) e nenhum herdeiro.

## Armadilhas e casos reais

> **Na vida real:** a glibc 2.28, de 2018, mudou a ordenação de texto de quase todas as *locales*, sobretudo pontuação e espaços. Quem atualizou o sistema operacional sem `REINDEX` ficou com B-trees ordenadas pela regra velha e consultadas pela nova: buscas que não acham linhas existentes e `UNIQUE` deixando passar duplicatas (a wiki do PostgreSQL documenta). CPF com pontos e traço é a vítima típica. Com `COLLATE "C"` a ordem é a dos bytes, e o `LIKE 'prefixo%'` ainda usa a B-tree sem `text_pattern_ops`. Seu índice pode corromper sem um bit mudar no disco: basta mudarem o alfabeto por baixo dele.

> **Na vida real:** em 2016, a Uber explicou a troca de PostgreSQL por MySQL num sistema central, e o primeiro item era amplificação de escrita: os índices do PostgreSQL apontam para a posição física, então um `UPDATE` sem HOT gera entradas em todos os índices, enquanto os secundários do InnoDB apontam para a chave primária. A comunidade PostgreSQL contestou parte das conclusões; a conta por índice é a deste capítulo.

> **Armadilha:** `WHERE date(criado_em) = '2026-10-15'` ignora o índice em `criado_em`: o índice guarda `criado_em`, e a consulta pede outra coisa. Índice de expressão também falha, porque `date(timestamptz)` depende do fuso da sessão e é só `STABLE`. A forma certa é a faixa, `criado_em >= '2026-10-15 03:00:00+00' AND criado_em < '2026-10-16 03:00:00+00'`. Função na coluna é o jeito mais discreto de dar `DROP INDEX` sem deixar digital.

> **Armadilha:** `CREATE INDEX` sem `CONCURRENTLY` trava as escritas durante o build inteiro, como o Carlos demonstrou ao vivo. O `CONCURRENTLY` evita isso com duas passadas na tabela e pode deixar um índice `INVALID` se falhar; detalhes no capítulo 7, onde o Carlos ganha outra chance de virar exemplo. Índice sem uso (`idx_scan = 0` depois de semanas) continua cobrando em toda escrita; antes do enterro, confira se ele garante um `UNIQUE`, porque esse trabalha sem nunca ser lido.

## Resumo

- B-tree: páginas de 8 KB, fan-out de centenas, três ou quatro níveis, folhas encadeadas para faixas e ordenação.
- O índice guarda chave e TID; index-only scan exige as colunas no índice (`INCLUDE`) e páginas all-visible.
- Composto: igualdade primeiro, faixa ou ordenação por último; o prefixo da esquerda serve sozinho.
- Seletividade e correlação decidem entre index, bitmap e seq scan.
- Parcial e de expressão; hash, GIN, GiST e BRIN para o que a B-tree não cobre.
- Cada índice cobra em toda escrita e pode desligar o HOT.

## A Lastro agora

O extrato caiu de 6 segundos para 0,23 milissegundo com `(conta_id, criado_em) INCLUDE (valor, transacao_id)`, que substitui o de `conta_id` e serve ao trigger de débito. O índice do Carlos morreu, um BRIN atende a conciliação, `cobrancas` ganhou um parcial e um de expressão, e as chaves de identificação passaram a `COLLATE "C"`. O ledger segue com três B-trees, agora todas lidas.

O gerente de produto disse que era só um índice, e era: só não era o do Carlos. Animado, pediu um painel com as vendas do dia do Bazar, e o ORM entregou um painel que dispara 400 consultas por tela, cada uma usando o índice com perfeição, 400 vezes. E a estagiária da Capinhas acaba de clicar na página 4.000 do extrato completo. O índice acha a primeira linha em três níveis; o `OFFSET` manda pular 199.950 delas, uma por uma, cada uma encontrada com toda a eficiência do mundo antes de ser jogada fora.

## Referências

- PostgreSQL 16, documentação, capítulo "Indexes": <https://www.postgresql.org/docs/16/indexes.html>
- PostgreSQL 16, "B-Tree Indexes" (implementação, deduplicação, remoção bottom-up): <https://www.postgresql.org/docs/16/btree.html>
- PostgreSQL 16, "Index-Only Scans and Covering Indexes": <https://www.postgresql.org/docs/16/indexes-index-only-scans.html>
- PostgreSQL 16, "Heap-Only Tuples (HOT)": <https://www.postgresql.org/docs/16/storage-hot.html>
- PostgreSQL 16, `CREATE INDEX`: <https://www.postgresql.org/docs/16/sql-createindex.html>
- PostgreSQL 18, notas de lançamento (skip scan em B-tree): <https://www.postgresql.org/docs/18/release-18.html>
- Lehman, P. L.; Yao, S. B. "Efficient Locking for Concurrent Operations on B-Trees". ACM TODS, 1981.
- PostgreSQL Wiki, "Locale data changes": <https://wiki.postgresql.org/wiki/Locale_data_changes>
- Uber Engineering, "Why Uber Engineering Switched from Postgres to MySQL" (2016): <https://www.uber.com/blog/postgres-to-mysql-migration/>
