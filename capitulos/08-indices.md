# Índices

## O dia em que o rastreio aprendeu a aceitar minúsculas

A página de rastreio passou anos recusando códigos digitados em minúsculas, até que, numa quinta-feira às 16h40, alguém do time de logística resolveu fazer as pazes com quem não usa o caps lock. Foi uma correção de uma linha. A consulta que era assim:

```sql
SELECT * FROM entregas WHERE codigo_rastreio = $1;
```

virou assim:

```sql
SELECT * FROM entregas WHERE upper(codigo_rastreio) = upper($1);
```

O *deploy* saiu em quatro minutos. Às 16h52, a consulta que levava 3 ms passou a levar 11 segundos. A tabela `entregas` tem 80 milhões de linhas, e o índice em `codigo_rastreio` continuava lá, intacto, com seus 2,4 GB, olhando a consulta passar sem ser chamado.

Às 17h30, alguém propôs a solução definitiva: "cria índice em tudo". A tabela já tinha 14 índices, entre eles um chamado `idx_entregas_tmp_nao_apagar`, criado em 2021 por um motivo que ninguém lembra e que ninguém tem coragem de investigar. As inserções de novas entregas já levavam o triplo do que levavam um ano antes.

Duas perguntas, então. Por que um índice que existe deixa de ser usado por causa de um `upper()`? E por que mais índices deixam a leitura mais rápida e a escrita mais lenta, e onde fica o ponto de equilíbrio?

## A B-tree por dentro, ou como achar uma linha entre 80 milhões em quatro leituras

O PostgreSQL guarda tudo em páginas de 8 KB. A tabela em si (o *heap*) é uma pilha de páginas sem ordem nenhuma: cada linha vai para onde houver espaço. Cada versão de linha tem um endereço físico, o TID (ou `ctid`), formado pelo número da página e pela posição dentro dela, como `(48213, 7)`.

Um índice B-tree é outra estrutura, separada da tabela, que guarda pares `(chave, TID)` em ordem. Ele é uma árvore balanceada com três tipos de página:

```text
                     [raiz]
              /        |         \
        [interna]  [interna]  [interna]       <- só chaves separadoras e ponteiros
        /   |   \
   [folha]<->[folha]<->[folha]<-> ...          <- (chave, TID) ordenados, ligadas entre si
      |
   heap: página 48213, item 7
```

A busca é uma busca binária generalizada para nós com muitas chaves. Na raiz, uma busca binária entre as chaves separadoras diz para qual filho descer. Repete-se até a folha, onde está a chave procurada e o TID da linha. Com o TID, o banco lê a página certa do heap e devolve a linha.

O que deixa isso rápido é o *fan-out*: uma página de 8 KB comporta algumas centenas de entradas. Com chaves de 8 bytes (`bigint`, `timestamptz`), cada entrada ocupa por volta de 20 bytes contando o cabeçalho e o ponteiro de linha, o que dá na ordem de 350 a 400 entradas por página. Com 300 de *fan-out* (um número redondo e pessimista):

```text
altura 2:  300² =            90.000 linhas
altura 3:  300³ =        27.000.000 linhas
altura 4:  300⁴ =     8.100.000.000 linhas
```

As 80 milhões de entregas cabem numa árvore de altura 4. Achar uma linha custa quatro páginas de índice mais uma de heap, e a raiz e os níveis internos quase sempre já estão em memória, porque todo mundo passa por eles. Uma varredura sequencial, para comparação, leria cerca de 1,1 milhão de páginas, todas com a mesma paciência burocrática.

As folhas são ligadas entre si nos dois sentidos. Por isso a B-tree resolve faixas (`BETWEEN`, `>`, `<`) e ordenação: o banco desce até a primeira chave da faixa e caminha pelas folhas vizinhas até passar do fim. `ORDER BY criado_em DESC LIMIT 20` com um índice em `criado_em` lê 20 entradas e para, sem ordenar coisa alguma.

O PostgreSQL implementa a variante de Lehman e Yao (1981), cujo ponteiro para a página irmã à direita deixa leitores percorrerem a árvore enquanto outra transação divide uma página. Desde a versão 13, chaves repetidas viram uma entrada só com uma lista de TIDs (deduplicação).

E aqui está a resposta da primeira pergunta. O índice em `codigo_rastreio` está ordenado pelos valores de `codigo_rastreio`. A consulta procura um valor de `upper(codigo_rastreio)`. O banco não tem como saber, sem calcular `upper()` em cada uma das 80 milhões de linhas, onde `'BR123456789XX'` estaria na ordem de outra função. Para o planejador, `upper(codigo_rastreio)` é uma coluna nova, sem índice. O mesmo acontece com `date(criado_em) = '2026-03-10'`, com `codigo + 0 = 5` e com uma comparação entre uma coluna `text` e um número que força conversão de tipo na coluna.

## Os outros tipos de índice

A B-tree atende igualdade, faixa, ordenação, `IS NULL` e prefixo de `LIKE` (com uma condição de collation que aparece nas armadilhas). Ela cobre a grande maioria dos casos. Os outros tipos existem para os dados que não cabem numa ordem linear.

### Hash

O índice hash guarda um código de hash de 4 bytes de cada chave e só responde a `=`. Não faz faixa, não ordena, não garante unicidade e aceita uma coluna só. Compensa com chaves longas: uma URL de 300 caracteres vira 4 bytes. Até o PostgreSQL 9.6, o hash não gravava no WAL e precisava ser reconstruído depois de uma queda (a documentação avisava, com a calma de quem descreve a previsão do tempo); desde a versão 10, é seguro contra falhas e replicado.

### GIN

O GIN (*Generalized Inverted Index*) é um índice invertido: para cada elemento contido num valor, guarda a lista das linhas que o contêm. O valor `'{urgente,fragil,refrigerado}'` de um array gera três entradas no índice, uma por elemento. É o tipo usado para arrays, `jsonb`, busca textual (`tsvector`) e trigramas (`pg_trgm`, que resolve `LIKE '%abc%'`).

```sql
CREATE INDEX idx_entregas_atributos ON entregas USING gin (atributos jsonb_path_ops);

-- usa o índice: contenção
SELECT id FROM entregas WHERE atributos @> '{"refrigerado": true}';
```

A classe `jsonb_path_ops` gera índices menores que a padrão (`jsonb_ops`), mas só atende `@>` e os operadores de jsonpath (`@?`, `@@`); a padrão também atende os operadores de existência de chave (`?`, `?|`, `?&`).

O preço do GIN está na escrita: um documento de 40 chaves atualiza 40 posições no índice. A *pending list* (`fastupdate`, ligado por padrão) amortiza isso guardando entradas novas numa lista sem ordem, incorporada no `VACUUM` ou ao passar de `gin_pending_list_limit` (4 MB). Toda busca varre essa lista, e a inserção azarada que dispara a limpeza paga a conta de todas as anteriores.

### GiST

O GiST (*Generalized Search Tree*) é uma árvore balanceada em que cada entrada interna guarda um predicado que engloba tudo o que está abaixo dela, como um retângulo que contém todos os pontos da subárvore. A busca desce só pelos ramos cujo predicado pode conter a resposta. Serve para geometria (o PostGIS usa GiST), intervalos (`tstzrange` com `&&`), restrições de exclusão (o capítulo 7 mostra um `EXCLUDE` contra reservas sobrepostas) e busca do vizinho mais próximo:

```sql
-- as 5 bases mais próximas de um ponto, sem calcular a distância para todas
SELECT nome FROM bases ORDER BY localizacao <-> point(-46.63, -23.55) LIMIT 5;
```

Como os predicados internos se sobrepõem, a busca pode descer por mais de um ramo, e cada candidato é conferido de novo contra a linha (*recheck*).

### BRIN, de brinde

O BRIN (*Block Range Index*) guarda só o mínimo e o máximo de cada faixa de 128 páginas do heap (`pages_per_range`). Numa tabela que só recebe inserções em ordem de tempo, como um log de eventos, um BRIN em `criado_em` ocupa alguns kilobytes onde uma B-tree ocuparia gigabytes. Se as linhas estiverem fora de ordem física, cada faixa cobre o ano inteiro e o índice responde "pode estar em qualquer lugar", com toda a sinceridade.

## Índices compostos e a ordem das colunas

Um índice em `(cliente_id, criado_em)` ordena as entradas por `cliente_id` e, dentro de cada cliente, por `criado_em`. É a mesma ordem de um `sorted()` em Python sobre tuplas: compara o primeiro elemento e só olha o segundo em caso de empate.

Daí sai a regra do prefixo à esquerda. O índice atende bem:

- `WHERE cliente_id = 42`
- `WHERE cliente_id = 42 AND criado_em >= '2026-01-01'`
- `WHERE cliente_id = 42 ORDER BY criado_em DESC LIMIT 20`

E atende mal `WHERE criado_em >= '2026-01-01'` sozinho, porque as datas recentes estão espalhadas por todos os clientes, uma fatia em cada trecho do índice.

A ordem que funciona para consultas mistas é: colunas comparadas por igualdade primeiro, a coluna de faixa ou de ordenação por último. Com `(criado_em, cliente_id)`, a consulta `cliente_id = 42 AND criado_em >= X` desce até a primeira data da faixa e percorre todas as entregas de todos os clientes desde então, filtrando o cliente 42 entrada por entrada. O índice é usado, aparece no plano, e mesmo assim lê 300 mil entradas para devolver 12. É o tipo de índice que trabalha muito e entrega pouco.

O PostgreSQL 18 trouxe o *skip scan*: se a consulta omite a primeira coluna e ela tem poucos valores, o banco desce uma vez para cada valor. Com `(status, criado_em)` e cinco status, são cinco descidas; com 2 milhões de clientes, seriam 2 milhões, e o planejador sensatamente desiste.

## Índices de cobertura e o index-only scan

Depois de achar o TID na folha, o banco ainda vai ao heap buscar a linha. Se a consulta pede só colunas que estão no índice, essa ida pode ser evitada: é o *index-only scan*. O `INCLUDE` (PostgreSQL 11+) acrescenta colunas às folhas sem que elas participem da ordenação:

```sql
CREATE INDEX idx_entregas_cliente_data
    ON entregas (cliente_id, criado_em DESC) INCLUDE (status);
```

Agora `SELECT criado_em, status FROM entregas WHERE cliente_id = 42` pode ser respondida só com o índice, com uma condição. Por causa do MVCC (capítulo 10), o índice aponta para versões de linha que talvez não sejam visíveis para a sua transação, e isso só se confirma no heap. O atalho é o *visibility map*, um bit por página do heap que diz "tudo aqui é visível para todo mundo", ligado pelo `VACUUM` e desligado por qualquer escrita na página. Numa tabela com muitas escritas e um `autovacuum` atrasado, o index-only scan vira um index scan com nome mais bonito, e o `EXPLAIN` denuncia com `Heap Fetches` alto.

## Índices parciais e de expressão

Um índice parcial indexa só as linhas que satisfazem um `WHERE`:

```sql
CREATE INDEX idx_entregas_pendentes ON entregas (criado_em)
    WHERE status = 'pendente';
```

Das 80 milhões de entregas, 320 mil estão pendentes. O índice parcial tem 7 MB, contra 1,7 GB do equivalente completo, cabe inteiro em memória, e as entregas concluídas não pagam nada por ele na escrita. A condição: o planejador só usa o índice se conseguir provar que o `WHERE` da consulta implica o do índice. `status = 'pendente'` escrito literalmente funciona; `status = $1` com parâmetro, num plano genérico, não prova nada.

O índice parcial único resolve um problema clássico de exclusão lógica:

```sql
-- e-mail único entre os ativos; os excluídos podem repetir à vontade
CREATE UNIQUE INDEX uq_clientes_email_ativo ON clientes (email)
    WHERE excluido_em IS NULL;
```

O índice de expressão indexa o resultado de uma função, e é a resposta do rastreio da quinta-feira:

```sql
CREATE INDEX idx_entregas_upper_codigo ON entregas (upper(codigo_rastreio));
```

A expressão da consulta precisa ser a mesma do índice, e a função precisa ser `IMMUTABLE` (mesma entrada, mesma saída, para sempre). `upper()` passa; `now()` e funções que dependem do fuso da sessão, não. Um bônus: o `ANALYZE` coleta estatísticas da expressão indexada, e o planejador para de chutar.

## Seletividade e cardinalidade, ou quando o índice perde para a força bruta

**Cardinalidade** é o número de valores distintos de uma coluna. **Seletividade** de um predicado é a fração das linhas que ele devolve: `id = 7` tem seletividade de 1/80 milhões; `status = 'entregue'` pode ter 0,96.

Um índice compensa quando a seletividade é baixa. Cada linha encontrada é uma leitura aleatória no heap, e o planejador atribui custo 4,0 a ela (`random_page_cost`) contra 1,0 da sequencial (`seq_page_cost`), valores da era dos discos giratórios (em SSD, é comum baixar para perto de 1,1). Com custo 4, ler 30% das linhas via índice sai mais caro do que ler a tabela inteira em ordem, e o planejador escolhe o *seq scan* sem remorso. Entre os dois extremos existe o *bitmap scan*, que coleta os TIDs, ordena por página e visita cada página do heap uma vez (o capítulo 9 detalha os tipos de varredura).

O planejador estima a seletividade a partir de `pg_stats`: valores mais comuns e suas frequências, histograma, `n_distinct` e `correlation` (o quanto a ordem física das linhas acompanha a ordem da coluna). Sem estatística, como na expressão `upper(codigo_rastreio)` antes do índice, ele usa um palpite fixo de 0,5% para igualdade. Foi esse palpite que apareceu no plano da quinta-feira: 0,5% de 80 milhões são as 400 mil linhas estimadas, contra 1 linha real.

Por isso uma B-tree num booleano fica parada: `ativo = true` devolve 98% da tabela. O índice útil é o parcial, sobre os 2% interessantes.

## Na prática

O plano da consulta problemática, antes do índice de expressão:

```sql
EXPLAIN ANALYZE
SELECT * FROM entregas WHERE upper(codigo_rastreio) = 'BR123456789XX';
```

```text
 Gather  (cost=1000.00..1520433.10 rows=400000 width=96) (actual time=10842.117..11203.554 rows=1 loops=1)
   Workers Planned: 2
   Workers Launched: 2
   ->  Parallel Seq Scan on entregas  (cost=0.00..1479433.10 rows=166667 width=96) (actual time=10835.904..11196.212 rows=0 loops=3)
         Filter: (upper(codigo_rastreio) = 'BR123456789XX'::text)
         Rows Removed by Filter: 26666666
 Planning Time: 0.118 ms
 Execution Time: 11203.601 ms
```

Três processos (dois workers e o líder) leram 26,7 milhões de linhas cada, aplicaram `upper()` a todas e jogaram fora todas menos uma. Depois do `CREATE INDEX` e do `ANALYZE`:

```text
 Index Scan using idx_entregas_upper_codigo on entregas  (cost=0.57..8.59 rows=1 width=96) (actual time=0.041..0.043 rows=1 loops=1)
   Index Cond: (upper(codigo_rastreio) = 'BR123456789XX'::text)
 Planning Time: 0.142 ms
 Execution Time: 0.068 ms
```

De 11,2 segundos para 0,07 ms, e a estimativa caiu de 400 mil para 1 linha. O `CREATE INDEX` comum bloqueia as escritas enquanto constrói; o capítulo 12 mostra o `CREATE INDEX CONCURRENTLY` e por que criar índice no horário de pico é esporte radical.

Em SQLAlchemy 2.x, os mesmos índices ficam declarados junto do modelo:

```python
from sqlalchemy import Index, func, text
from sqlalchemy.dialects import postgresql
from sqlalchemy.schema import CreateIndex

from modelos import Entrega  # tabela "entregas"

indices = [
    Index("idx_entregas_upper_codigo", func.upper(Entrega.codigo_rastreio)),
    Index(
        "idx_entregas_cliente_data",
        Entrega.cliente_id,
        Entrega.criado_em.desc(),
        postgresql_include=["status"],
    ),
    Index(
        "idx_entregas_pendentes",
        Entrega.criado_em,
        postgresql_where=text("status = 'pendente'"),
    ),
]

for indice in indices:
    print(CreateIndex(indice).compile(dialect=postgresql.dialect()))
```

```text
CREATE INDEX idx_entregas_upper_codigo ON entregas (upper(codigo_rastreio))
CREATE INDEX idx_entregas_cliente_data ON entregas (cliente_id, criado_em DESC) INCLUDE (status)
CREATE INDEX idx_entregas_pendentes ON entregas (criado_em) WHERE status = 'pendente'
```

Agora o outro lado. As estatísticas acumuladas dizem quais índices nunca foram usados desde o último reset:

```sql
SELECT indexrelname AS indice,
       idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS tamanho
FROM pg_stat_user_indexes
WHERE relname = 'entregas'
ORDER BY idx_scan, pg_relation_size(indexrelid) DESC
LIMIT 4;
```

```text
           indice             | idx_scan | tamanho
------------------------------+----------+---------
 idx_entregas_tmp_nao_apagar  |        0 | 2318 MB
 idx_entregas_ativo           |        0 | 534 MB
 idx_entregas_criado_cliente  |       17 | 1702 MB
 idx_entregas_status          |      211 | 541 MB
```

O `idx_entregas_tmp_nao_apagar` ocupa 2,3 GB, nunca foi lido e é atualizado em toda inserção, com a dedicação de um funcionário que mantém em dia uma planilha que ninguém abre. Antes de apagar, vale conferir as réplicas (cada uma tem as próprias estatísticas de uso) e se o índice sustenta alguma restrição `UNIQUE`, que protege dados mesmo com `idx_scan` zerado.

## Quanto custa cada índice

Todo índice é uma estrutura a mais para manter em cada escrita:

| Operação | O que acontece com os índices |
|----------|-------------------------------|
| `INSERT` | Uma entrada nova em cada índice da tabela (no GIN, uma por elemento) |
| `UPDATE` sem tocar coluna indexada, com espaço na página | Atualização HOT: nenhum índice é tocado |
| `UPDATE` que muda coluna indexada ou não cabe na página | Entrada nova em todos os índices, inclusive nos das colunas que não mudaram |
| `DELETE` | Nada na hora; o `VACUUM` remove as entradas mortas depois |

A linha do meio é a que surpreende. No PostgreSQL, um `UPDATE` cria uma nova versão da linha com um novo TID. Se nenhuma coluna indexada mudou e a nova versão cabe na mesma página, o banco faz um *HOT update* (*heap-only tuple*): encadeia a versão nova à antiga dentro da página e os índices continuam apontando para o começo da cadeia. Se qualquer coluna indexada mudou, todos os 14 índices recebem uma entrada nova, porque todos precisam apontar para o novo TID. Criar um índice em `atualizado_em` numa tabela em que toda atualização muda `atualizado_em` desliga o HOT para todas as escritas dessa tabela. A proporção aparece em `pg_stat_user_tables` (`n_tup_hot_upd` contra `n_tup_upd`), e um `fillfactor` abaixo de 100 deixa espaço livre nas páginas para a versão nova caber.

Cada entrada de índice gera WAL, que vai para o disco, as réplicas e o backup. E o `shared_buffers` ocupado por páginas de `idx_entregas_tmp_nao_apagar` deixa de guardar páginas úteis.

A comparação entre os tipos, para uma mesma tabela grande:

| Tipo | Consultas que atende | Tamanho relativo | Custo de escrita |
|------|----------------------|------------------|------------------|
| B-tree | `=`, faixa, ordenação, prefixo | Referência | Uma entrada por linha |
| Hash | Só `=` | Menor com chaves longas | Uma entrada por linha |
| GIN | Contenção, elementos, texto, trigramas | Grande | Uma entrada por elemento; amortizado pela *pending list* |
| GiST | Sobreposição, proximidade, geometria, exclusão | Médio | Uma entrada por linha, com divisão de página mais cara |
| BRIN | Faixa em dados fisicamente ordenados | Minúsculo | Quase nenhum |

Cada índice acelera um padrão de consulta e cobra espaço, memória, WAL e latência em toda escrita, com ou sem uso. Em tabela de leitura intensa, dez índices podem se pagar com folga; em tabela de ingestão (eventos, logs, telemetria), cada um a mais reduz a vazão de inserção.

## Armadilhas e casos reais

> **Armadilha:** `LIKE 'BR12%'` só usa uma B-tree comum se a collation da coluna for `C`. Com `pt_BR.UTF-8`, a ordem do índice segue regras linguísticas que não garantem prefixos contíguos, e o planejador ignora o índice. A saída é criar o índice com a classe de operadores `text_pattern_ops` ou declarar a coluna com collation `C`. Para `LIKE '%12'`, nenhuma B-tree ajuda; aí entra o GIN com `pg_trgm`.

> **Armadilha:** tipo divergente entre parâmetro e coluna. Uma coluna `varchar` comparada com um parâmetro enviado como `numeric` força a conversão na coluna, com o mesmo efeito do `upper()` da quinta-feira. O ORM geralmente acerta o tipo; o SQL montado à mão às 23h nem sempre.

> **Na vida real:** em 2016, a Uber publicou os motivos técnicos da migração do PostgreSQL para o MySQL. Um deles era a amplificação de escrita: uma atualização não HOT grava em todos os índices da tabela, e tudo isso viaja pelo WAL até as réplicas. No InnoDB, os índices secundários apontam para a chave primária, e a mudança de uma coluna toca só os índices que a contêm; em troca, cada busca por índice secundário paga uma segunda descida, na árvore da chave primária.

> **Na vida real** (hipotética, como a quinta-feira): o `idx_entregas_tmp_nao_apagar` foi removido numa terça, depois de conferidas as três réplicas, e as inserções ficaram 11% mais rápidas. Ninguém sentiu falta dele, o que encerrou cinco anos de suspense sobre o que acontecia se alguém o apagasse.

## Resumo

- B-tree: pares `(chave, TID)` ordenados, *fan-out* de centenas, 80 milhões de linhas em altura 4, folhas ligadas para faixas e ordenação.
- O índice atende só a expressão com que foi construído; `upper()`, `date()` e conversão de tipo na coluna o anulam.
- Hash: só igualdade. GIN: elementos (arrays, `jsonb`, texto, trigramas), caro na escrita. GiST: sobreposição, proximidade, exclusão. BRIN: faixas de dados fisicamente ordenados.
- Compostos: prefixo à esquerda, igualdade antes de faixa.
- `INCLUDE` permite *index-only scan*, que depende do *visibility map*.
- Parciais indexam só o subconjunto consultado e permitem unicidade condicional.
- Com seletividade alta, o *seq scan* ganha.
- Cada índice custa em toda inserção, em todo `UPDATE` não HOT, em WAL e em memória.

## Referências

- PostgreSQL, documentação, capítulo "Indexes": <https://www.postgresql.org/docs/current/indexes.html>
- PostgreSQL, "B-Tree Indexes": <https://www.postgresql.org/docs/current/btree.html>
- PostgreSQL, "GIN Indexes": <https://www.postgresql.org/docs/current/gin.html>
- PostgreSQL, "GiST Indexes": <https://www.postgresql.org/docs/current/gist.html>
- PostgreSQL, "BRIN Indexes": <https://www.postgresql.org/docs/current/brin.html>
- PostgreSQL, "Index-Only Scans and Covering Indexes": <https://www.postgresql.org/docs/current/indexes-index-only-scans.html>
- PostgreSQL, "Partial Indexes": <https://www.postgresql.org/docs/current/indexes-partial.html>
- PostgreSQL, "Indexes on Expressions": <https://www.postgresql.org/docs/current/indexes-expressional.html>
- PostgreSQL, "Heap-Only Tuples (HOT)": <https://www.postgresql.org/docs/current/storage-hot.html>
- Bayer, R.; McCreight, E. "Organization and Maintenance of Large Ordered Indices". *Acta Informatica*, 1972.
- Lehman, P. L.; Yao, S. B. "Efficient Locking for Concurrent Operations on B-Trees". *ACM Transactions on Database Systems*, 1981.
- Markus Winand, *Use The Index, Luke*: <https://use-the-index-luke.com/>
- Uber Engineering, "Why Uber Engineering Switched from Postgres to MySQL" (2016): <https://www.uber.com/blog/postgres-to-mysql-migration/>
