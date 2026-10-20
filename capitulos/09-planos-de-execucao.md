# Planos de execução

## A escola que o banco achava que tinha quatro alunos

Segunda-feira, 8h04. O suporte abre um chamado com o título "painel lento". Às 8h20, o título vira "painel MUITO lento". Às 8h41, alguém troca para "URGENTE: painel não abre", e o chamado ganha um ícone de fogo que ninguém sabia que o sistema de chamados tinha.

É o painel de cobrança de uma plataforma de cursos que atende 3.000 escolas, e a consulta, a mesma há dois anos, lista os alunos com boletos em aberto. Para as outras escolas, ela leva 30 ms. Para a escola 9001, o Colégio Grande, 47 segundos.

O Colégio Grande chegou no domingo à noite: uma importação colocou 48.000 alunos numa tabela `alunos` de 2 milhões. Nenhum índice mudou, nenhuma linha de código mudou. O último deploy, na quinta, trocou a cor de um botão.

O que mudou foi uma decisão que o PostgreSQL tomou sozinho, em 0,4 ms, antes de ler a primeira linha: o plano de execução. O banco estimou que a escola 9001 tinha quatro alunos. Para quatro alunos, o plano era excelente. Para 48.000, ele fez 2,88 bilhões de comparações.

Como o banco decide de que jeito executar uma consulta, por que ele acreditou em quatro alunos, e como se lê o que ele decidiu?

## O mecanismo

### Do SQL ao plano

O SQL é declarativo: você diz o que quer, e o banco decide como buscar. O PostgreSQL passa o texto pelo *parser* (sintaxe e árvore), pelo *rewriter* (expansão de views e regras), pelo *planner*, também chamado de otimizador, que escolhe como executar, e pelo *executor*, que faz o trabalho e leva a culpa.

Para a mesma consulta existem muitos planos equivalentes: ler a tabela inteira ou usar um índice, começar por `alunos` ou por `boletos`, juntar por laço aninhado, por hash ou por ordenação. Todos devolvem o mesmo resultado, em tempos que variam de milissegundos a horas.

O planner do PostgreSQL é baseado em custo, na linha do otimizador do System R da IBM (Selinger e coautores, 1979): estima o custo de cada alternativa e fica com a mais barata. Para poucas tabelas, usa programação dinâmica, calculando o melhor plano para cada subconjunto e combinando. As ordens de junção crescem de forma fatorial (10 tabelas têm 3.628.800 ordens lineares), então, a partir de 12 tabelas no `FROM` (`geqo_threshold`), ele troca a busca exaustiva por um algoritmo genético. Sim, o relatório com 14 `JOIN`s escrito em 2019 tem o plano escolhido por seleção natural.

### O custo, em unidades que não são milissegundos

O custo é um número sem unidade, calibrado por parâmetros. Os padrões são:

| Parâmetro | Padrão | O que representa |
|-----------|--------|------------------|
| `seq_page_cost` | 1,0 | ler uma página de 8 KB em sequência |
| `random_page_cost` | 4,0 | ler uma página em posição aleatória |
| `cpu_tuple_cost` | 0,01 | processar uma linha |
| `cpu_index_tuple_cost` | 0,005 | processar uma entrada de índice |
| `cpu_operator_cost` | 0,0025 | avaliar um operador ou função |

O custo de uma leitura sequencial com um filtro é páginas × `seq_page_cost` + linhas × `cpu_tuple_cost` + linhas × `cpu_operator_cost`. Para a tabela `boletos`, com 11.586 páginas e 900.000 linhas: 11.586 + 9.000 + 2.250 = 22.836. Esse número vai aparecer daqui a pouco, igualzinho, na saída do `EXPLAIN`, num raro momento em que uma conta de papel bate com o sistema.

As páginas o banco conhece com boa precisão. As linhas que passam por cada filtro e por cada junção ele precisa adivinhar, e é nessa adivinhação que nasce quase todo plano ruim. O estudo de Leis e coautores (VLDB 2015) mediu isso em vários bancos: os erros de cardinalidade crescem rapidamente a cada junção e pesam mais na qualidade do plano que o modelo de custo.

### Estatísticas, ou de onde vêm as adivinhações

O comando `ANALYZE` lê uma amostra de 300 × `default_statistics_target` linhas (30.000, com o padrão de 100, tenha a tabela 50 mil ou 5 bilhões de linhas) e grava estatísticas por coluna, visíveis na view `pg_stats`: fração de nulos (`null_frac`), valores distintos (`n_distinct`), até 100 valores mais comuns com suas frequências (`most_common_vals` e `most_common_freqs`), um histograma dos demais (`histogram_bounds`) e a `correlation` entre ordem física e ordem dos valores.

Para estimar `escola_id = 9001`, o planner procura 9001 entre os valores mais comuns. Se não encontra, divide a fração restante igualmente entre os outros valores distintos. Com 3.000 escolas pequenas, o resultado foi quatro linhas.

E por que 9001 não estava lá? Porque o último `ANALYZE` aconteceu na sexta, quando o Colégio Grande ainda não existia. O *autovacuum* dispara um `ANALYZE` quando as linhas modificadas passam de `autovacuum_analyze_threshold` + `autovacuum_analyze_scale_factor` × linhas da tabela: 50 + 0,1 × 2.000.000 = 200.050. Os 48.000 alunos novos são 2,4% da tabela. Para o autovacuum, foi um fim de semana tranquilo.

Há um segundo limite. As estatísticas são por coluna, e o planner assume colunas independentes. Para `cidade = 'Campinas' AND estado = 'SP'`, ele multiplica as seletividades e admite, com toda a seriedade, a hipótese de Campinas ficar no Acre. Com 2% dos alunos em Campinas e 30% em São Paulo, estima 0,6% em vez de 2%. O `CREATE STATISTICS` (PostgreSQL 10+) cria estatísticas sobre grupos de colunas (`dependencies`, `ndistinct`, `mcv`) e corrige esse erro.

### Os métodos de acesso

O **Seq Scan** lê todas as páginas em ordem e testa o filtro em cada linha. Custo proporcional ao tamanho da tabela, com a leitura mais barata por página. Nas tabelas pequenas, ganha de qualquer índice, o que explica por que o banco de desenvolvimento com 200 linhas nunca reproduz o plano de produção.

O **Index Scan** percorre o índice e busca cada linha no heap pelo TID, o endereço físico dela. Cada busca pode cair numa página diferente, daí o `random_page_cost`. Ganha quando a condição seleciona poucas linhas. O **Index Only Scan** responde só com o índice, quando ele tem todas as colunas pedidas e o *visibility map* permite (o capítulo 8 trata disso em detalhe).

O **Bitmap Index Scan** com **Bitmap Heap Scan** é o meio-termo: percorre o índice, monta em memória um mapa de bits das páginas com linhas candidatas e depois lê essas páginas em ordem física, uma vez cada. Se o bitmap não cabe em `work_mem`, ele guarda só as páginas (fica *lossy*), e cada linha precisa ser testada de novo, o `Recheck Cond` do plano. Esse método também combina índices com `BitmapAnd` e `BitmapOr`.

### Os três jeitos de juntar tabelas

O **Nested Loop** pega cada linha do lado externo e procura as correspondentes no interno. Com índice no interno, o total é proporcional a N × log M. Sem índice, cada linha externa varre o interno inteiro, e o total vira N × M. Funciona para qualquer condição, inclusive desigualdades, e é ótimo com lado externo pequeno. Com lado externo pequeno só na estimativa, ele produz segundas-feiras memoráveis.

O **Hash Join** monta uma tabela hash com o lado menor e percorre o maior consultando a hash. Custo proporcional a N + M, só com igualdade, e nada sai antes de a hash ficar pronta. A memória é `work_mem` × `hash_mem_multiplier` (4 MB × 2,0 nos padrões do PostgreSQL 15+); se não couber, a hash é dividida em lotes em arquivos temporários, e o plano mostra `Batches` maior que 1.

O **Merge Join** anda pelos dois lados ordenados pela chave, que é o passo de intercalação do merge sort. Se a ordem vem de um índice, sai barato para lados grandes; se não vem, o plano ganha um `Sort` antes, que pode ir para o disco.

| Método | Custo típico | Exige | Brilha quando |
|--------|--------------|-------|---------------|
| Nested Loop | N × custo de buscar no interno | nada | lado externo pequeno e índice no interno |
| Hash Join | N + M, mais memória para a hash | condição de igualdade | lados grandes sem ordem útil |
| Merge Join | N + M, mais ordenação se necessário | igualdade e lados ordenáveis | lados grandes já ordenados |

Com quatro linhas do lado externo, o Nested Loop sai mais barato que montar uma hash; com 48.000, perde por ordens de grandeza. O planner fez a conta certa com o número errado.

## Na prática

### Lendo um EXPLAIN

`EXPLAIN` mostra o plano escolhido e as estimativas, sem executar a consulta. `EXPLAIN ANALYZE` executa a consulta de verdade e põe os números reais ao lado das estimativas. A opção `BUFFERS` acrescenta páginas vindas do cache do PostgreSQL (`shared hit`) e lidas fora dele (`read`); no PostgreSQL 18, ela vem ligada por padrão com `ANALYZE`. As saídas abaixo são do PostgreSQL 16, e esta é a consulta do painel às 8h41:

```sql
EXPLAIN ANALYZE
SELECT a.nome, b.valor, b.vencimento
FROM alunos a
JOIN boletos b ON b.aluno_id = a.id
WHERE a.escola_id = 9001
  AND b.status = 'aberto';
```

```text
                                       QUERY PLAN
----------------------------------------------------------------------------------------------------------
 Nested Loop  (cost=0.43..23941.27 rows=4 width=45) (actual time=61.904..47212.553 rows=51870 loops=1)
   Join Filter: (b.aluno_id = a.id)
   Rows Removed by Join Filter: 2879948130
   ->  Index Scan using idx_alunos_escola on alunos a  (cost=0.43..12.51 rows=4 width=37) (actual time=0.031..41.877 rows=48000 loops=1)
         Index Cond: (escola_id = 9001)
   ->  Materialize  (cost=0.00..23135.35 rows=59870 width=16) (actual time=0.001..0.461 rows=60000 loops=48000)
         ->  Seq Scan on boletos b  (cost=0.00..22836.00 rows=59870 width=16) (actual time=0.012..61.203 rows=60000 loops=1)
               Filter: (status = 'aberto'::text)
               Rows Removed by Filter: 840000
 Planning Time: 0.412 ms
 Execution Time: 47219.880 ms
```

O plano é uma árvore: cada nó recebe linhas dos filhos (as linhas com `->` mais recuadas) e entrega ao pai, e a leitura começa pelas folhas. O primeiro parêntese é a estimativa: `cost=início..total` (custo até a primeira linha e até a última), `rows` estimadas na saída e `width`, o tamanho médio da linha em bytes. O segundo é a realidade: tempos até a primeira e a última linha, em milissegundos, linhas devolvidas e `loops`, quantas vezes o nó executou.

O detalhe que engana todo mundo pelo menos uma vez: `actual time` e `rows` são médias por execução. O `Materialize` mostra modestos 0,461 ms e 60.000 linhas, com `loops=48000`. O total é 0,461 × 48.000 ≈ 22 segundos. O nó com a cara mais inocente da saída gastou metade do tempo.

O diagnóstico é a comparação entre estimado e real. O `Seq Scan` em `boletos` estimou 59.870 e devolveu 60.000, com o custo 22.836 da conta feita à mão. O `Index Scan` em `alunos` estimou 4 e devolveu 48.000, um erro de 12.000 vezes, e o resto do plano foi construído sobre esse 4. Como `boletos.aluno_id` não tem índice (chave estrangeira não cria índice no lado que referencia), cada aluno é comparado com cada boleto. O `Rows Removed by Join Filter` contabiliza, com uma honestidade quase cruel, 2.879.948.130 comparações inúteis.

A confirmação está em `pg_stat_user_tables`:

```sql
SELECT relname, n_live_tup, n_mod_since_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE relname = 'alunos';
```

```text
 relname | n_live_tup | n_mod_since_analyze |       last_autoanalyze
---------+------------+---------------------+-------------------------------
 alunos  |    2048000 |               48000 | 2026-10-16 03:12:44.81907+00
```

São 48.000 modificações desde o último `ANALYZE`, abaixo do gatilho de 200.050. Depois de um `ANALYZE alunos;`, que leva poucos segundos e deveria ter sido o último passo da importação:

```text
                                       QUERY PLAN
----------------------------------------------------------------------------------------------------------
 Hash Join  (cost=27589.29..51302.95 rows=51210 width=45) (actual time=102.117..168.302 rows=51870 loops=1)
   Hash Cond: (b.aluno_id = a.id)
   ->  Seq Scan on boletos b  (cost=0.00..22836.00 rows=59870 width=16) (actual time=0.010..52.114 rows=60000 loops=1)
         Filter: (status = 'aberto'::text)
         Rows Removed by Filter: 840000
   ->  Hash  (cost=26990.13..26990.13 rows=47930 width=37) (actual time=101.880..101.881 rows=48000 loops=1)
         Buckets: 65536  Batches: 1  Memory Usage: 3714kB
         ->  Bitmap Heap Scan on alunos a  (cost=538.17..26990.13 rows=47930 width=37) (actual time=6.211..96.430 rows=48000 loops=1)
               Recheck Cond: (escola_id = 9001)
               Heap Blocks: exact=1104
               ->  Bitmap Index Scan on idx_alunos_escola  (cost=0.00..526.19 rows=47930 width=0) (actual time=5.870..5.871 rows=48000 loops=1)
                     Index Cond: (escola_id = 9001)
 Planning Time: 0.538 ms
 Execution Time: 171.204 ms
```

Com 47.930 estimados, o planner usou um Bitmap Heap Scan (os alunos importados juntos ocupam 1.104 páginas vizinhas, e `exact` indica bitmap sem perda), montou uma hash de 3,7 MB num único lote e percorreu os boletos uma vez. De 47,2 segundos para 171 ms, sem índice novo e sem código novo. O chamado com ícone de fogo foi fechado como "resolvido sozinho", o que, de certo ponto de vista, é verdade.

### O N+1, ou mil consultas perfeitas

Há um jeito de deixar uma tela lenta com consultas de plano impecável, e o ORM faz isso com muita naturalidade:

```python
from sqlalchemy import select
from sqlalchemy.orm import Session

with Session(engine) as session:
    cursos = session.scalars(select(Curso).order_by(Curso.id).limit(50)).all()
    for curso in cursos:
        # curso.matriculas é carregado sob demanda: um SELECT por curso
        print(curso.titulo, len(curso.matriculas))
```

Com `echo=True` no engine, o log do SQLAlchemy revela o que aconteceu:

```text
SELECT cursos.id, cursos.titulo FROM cursos ORDER BY cursos.id LIMIT %(param_1)s
[generated in 0.00019s] {'param_1': 50}
SELECT matriculas.id, matriculas.curso_id, matriculas.aluno_id FROM matriculas WHERE %(param_1)s = matriculas.curso_id
[generated in 0.00021s] {'param_1': 1}
SELECT matriculas.id, matriculas.curso_id, matriculas.aluno_id FROM matriculas WHERE %(param_1)s = matriculas.curso_id
[cached since 0.004122s ago] {'param_1': 2}
... (mais 48 vezes)
```

Uma consulta para a lista e uma por item: 1 + N. O relacionamento padrão do SQLAlchemy usa *lazy loading*, que emite um `SELECT` quando o atributo é acessado pela primeira vez. Cada `SELECT` usa o índice em `matriculas(curso_id)` e leva 0,1 ms no banco; o custo está nas idas e voltas. Com 0,5 ms de RTT, 51 consultas custam uns 30 ms, e a tela com 2.000 cursos custa um segundo inteiro de consultas individualmente exemplares. Repare no `[cached since ...]`: o SQLAlchemy, orgulhoso, reaproveita a compilação da mesma consulta desnecessária 50 vezes.

O `EXPLAIN` de qualquer uma delas sai perfeito. Quem denuncia é a contagem: a extensão `pg_stat_statements` agrega consultas por formato, e `calls` na casa dos milhões com `mean_exec_time` de 0,1 ms é a assinatura do N+1. A correção é carregar os relacionamentos junto:

```python
from sqlalchemy.orm import selectinload

stmt = (
    select(Curso)
    .options(selectinload(Curso.matriculas))
    .order_by(Curso.id)
    .limit(50)
)
cursos = session.scalars(stmt).all()
```

```text
SELECT cursos.id, cursos.titulo FROM cursos ORDER BY cursos.id LIMIT %(param_1)s
[generated in 0.00018s] {'param_1': 50}
SELECT matriculas.curso_id AS matriculas_curso_id, matriculas.id AS matriculas_id, matriculas.aluno_id AS matriculas_aluno_id
FROM matriculas WHERE matriculas.curso_id IN (%(primary_keys_1)s, %(primary_keys_2)s, ...)
[generated in 0.00031s] {'primary_keys_1': 1, 'primary_keys_2': 2, ...}
```

Duas consultas, qualquer que seja N. O `selectinload` faz um `IN` com as chaves da primeira; o `joinedload` faz um `LEFT OUTER JOIN` numa consulta só, repetindo as colunas do curso em cada matrícula. A opção `lazy="raise"` no relacionamento faz o acesso sob demanda levantar exceção, e é assim que se descobre, ainda no teste, que o template acessa `aluno.escola.endereco.cidade` dentro de três laços aninhados.

### Paginação por offset e por cursor

A paginação mais comum é `LIMIT` com `OFFSET`. Veja a página 10.001 de uma listagem de matrículas, com um índice em `(criada_em, id)`:

```sql
EXPLAIN ANALYZE
SELECT id, aluno_id, criada_em
FROM matriculas
ORDER BY criada_em DESC, id DESC
LIMIT 20 OFFSET 200000;
```

```text
 Limit  (cost=17398.77..17400.51 rows=20 width=24) (actual time=212.704..212.718 rows=20 loops=1)
   ->  Index Scan Backward using idx_matriculas_criada_id on matriculas  (cost=0.43..1043890.43 rows=12000000 width=24) (actual time=0.022..204.950 rows=200020 loops=1)
 Planning Time: 0.091 ms
 Execution Time: 212.740 ms
```

O índice é usado, de trás para a frente (`Backward`), sem problema. Só que ele entregou 200.020 linhas para o `Limit` descartar 200.000. O `OFFSET` precisa produzir as linhas para contá-las, então o custo cresce linearmente com o número da página, e o robô de indexação que visita a página 600.000 custa 12 milhões de linhas lidas para mostrar 20.

Há também um problema de correção: se 3 matrículas novas entram entre a página 1 e a página 2, tudo escorrega 3 posições, e os 3 últimos itens da página 1 reaparecem no topo da 2. Exclusões fazem itens sumirem entre as páginas.

A paginação por cursor (*keyset pagination*) guarda a posição pelo valor da última linha vista:

```sql
EXPLAIN ANALYZE
SELECT id, aluno_id, criada_em
FROM matriculas
WHERE (criada_em, id) < ('2026-03-14 10:22:31.512+00', 8812345)
ORDER BY criada_em DESC, id DESC
LIMIT 20;
```

```text
 Limit  (cost=0.44..2.18 rows=20 width=24) (actual time=0.031..0.058 rows=20 loops=1)
   ->  Index Scan Backward using idx_matriculas_criada_id on matriculas  (cost=0.44..520411.80 rows=5980000 width=24) (actual time=0.030..0.054 rows=20 loops=1)
         Index Cond: (ROW(criada_em, id) < ROW('2026-03-14 10:22:31.512+00'::timestamp with time zone, '8812345'::bigint))
 Planning Time: 0.104 ms
 Execution Time: 0.077 ms
```

A comparação de linhas vira condição de índice: o banco desce a B-tree até a posição e lê 20 entradas, em 0,077 ms tanto na página 2 quanto na 600.000. O `id` desempata `criada_em` repetido; sem ele, duas matrículas no mesmo microssegundo na fronteira da página fariam uma delas sumir. Na API, a posição costuma virar um token opaco:

```python
import base64
import json
from datetime import datetime


def codificar_cursor(criada_em: datetime, id_: int) -> str:
    bruto = json.dumps([criada_em.isoformat(), id_]).encode()
    return base64.urlsafe_b64encode(bruto).decode()


def decodificar_cursor(token: str) -> tuple[datetime, int]:
    criada_em, id_ = json.loads(base64.urlsafe_b64decode(token))
    return datetime.fromisoformat(criada_em), int(id_)


print(codificar_cursor(datetime.fromisoformat("2026-03-14T10:22:31.512+00:00"), 8812345))
```

```text
WyIyMDI2LTAzLTE0VDEwOjIyOjMxLjUxMjAwMCswMDowMCIsIDg4MTIzNDVd
```

Opaco, mas legível por qualquer um que conheça base64, o que inclui praticamente todo mundo que vai ler este parágrafo. Se a posição não pode ser adulterada, o token precisa de assinatura (HMAC).

| Propriedade | Offset | Cursor |
|-------------|--------|--------|
| Custo da página k | proporcional a k × tamanho da página | constante (descida na B-tree) |
| Pular para uma página arbitrária | sim | não, só próxima e anterior |
| Itens repetidos ou perdidos com escritas concorrentes | sim | não, para a ordem escolhida |
| Exige | nada | ordem total estável e índice compatível |
| Total de páginas | um `count(*)` separado | um `count(*)` separado |

O offset oferece "ir para a página 37", com custo que só aparece nas páginas profundas. O cursor oferece custo constante e consistência, sem salto arbitrário. Rolagem infinita e exportação em lote não precisam de salto; uma tela de administração com dez páginas nunca chega às profundezas. O capítulo 25 trata da paginação no contrato da API.

## Propriedades e custos das ferramentas de diagnóstico

| Ferramenta | O que mostra | Custo |
|------------|--------------|-------|
| `EXPLAIN` | plano e estimativas | quase nenhum, não executa |
| `EXPLAIN ANALYZE` | plano, estimativas e números reais | executa a consulta inteira, com efeitos colaterais |
| `auto_explain` | plano das consultas acima de `log_min_duration` | medição por nó, se `log_analyze` estiver ligado |
| `pg_stat_statements` | totais por formato de consulta | pequeno; não mostra plano |

O `auto_explain` existe porque o plano ruim aparece em produção às 3h, com o parâmetro que ninguém testou, enquanto a reprodução das 15h usa outro parâmetro e mostra um plano lindo.

## Armadilhas e casos reais

> **Armadilha:** `EXPLAIN ANALYZE` executa a consulta. `EXPLAIN ANALYZE DELETE FROM boletos WHERE ...` apaga os boletos e, como bônus, informa com precisão de microssegundos quanto tempo levou para apagá-los. Para analisar escritas, a consulta vai dentro de `BEGIN; ... ROLLBACK;`, e os locks e triggers acontecem do mesmo jeito.

**O plano genérico das consultas preparadas.** O psycopg 3 prepara no servidor a consulta executada 5 vezes na mesma conexão (`prepare_threshold`, padrão 5). O PostgreSQL usa planos customizados para os valores dos parâmetros nas cinco primeiras execuções; depois, compara um plano genérico, feito sem olhar os valores, com a média dos customizados e adota o genérico se ele não sair mais caro. Com dados assimétricos, a escola 9001 passa a usar um plano feito para a escola média de 40 alunos, mesmo com estatísticas em dia. `plan_cache_mode = force_custom_plan` (PostgreSQL 12+) desliga isso, ao custo de planejar toda vez.

**O JIT acordado por uma estimativa.** Desde o PostgreSQL 12, a compilação JIT vem ligada e dispara quando o custo estimado passa de `jit_above_cost` (100.000). Uma superestimativa faz uma consulta de 5 ms gastar dezenas ou centenas de milissegundos compilando código que vai executar uma única vez. Quando a seção `JIT:` do `EXPLAIN ANALYZE` ocupa metade do tempo total, o compilador é o protagonista que ninguém escalou.

**Importação sem `ANALYZE`.** O Colégio Grande é hipotético; o mecanismo é o padrão. `autovacuum_analyze_scale_factor` pode ser ajustado por tabela com `ALTER TABLE ... SET (...)`, e um `ANALYZE` explícito no fim da carga cobre o resto.

> **Na vida real:** a página "No Offset", de Markus Winand (site Use The Index, Luke), compara as duas paginações. Em bancos sem bom suporte à comparação de linhas, a condição é escrita por extenso: `a < x OR (a = x AND b < y)`.

## Resumo

- O planner escolhe o plano de menor custo estimado (`seq_page_cost` 1,0, `random_page_cost` 4,0); busca exaustiva até 12 tabelas, algoritmo genético acima.
- O custo depende de linhas estimadas a partir das estatísticas do `ANALYZE`, que assumem colunas independentes; `CREATE STATISTICS` corrige colunas correlacionadas.
- O `ANALYZE` automático só dispara após 50 + 10% de linhas modificadas.
- No `EXPLAIN ANALYZE`, tempos e linhas são por loop, e o diagnóstico é a distância entre `rows` estimado e real.
- N+1 é invisível no `EXPLAIN`; `pg_stat_statements` o revela e `selectinload` o resolve.
- Offset custa proporcional à profundidade e repete itens; cursor custa constante e não salta páginas.

## Referências

- PostgreSQL, "Using EXPLAIN": https://www.postgresql.org/docs/current/using-explain.html
- PostgreSQL, "Statistics Used by the Planner": https://www.postgresql.org/docs/current/planner-stats.html
- PostgreSQL, "Row Estimation Examples": https://www.postgresql.org/docs/current/row-estimation-examples.html
- PostgreSQL, "Query Planning" (parâmetros de custo, `plan_cache_mode`, `geqo_threshold`): https://www.postgresql.org/docs/current/runtime-config-query.html
- PostgreSQL, "CREATE STATISTICS": https://www.postgresql.org/docs/current/sql-createstatistics.html
- PostgreSQL, "auto_explain": https://www.postgresql.org/docs/current/auto-explain.html
- PostgreSQL, "pg_stat_statements": https://www.postgresql.org/docs/current/pgstatstatements.html
- P. G. Selinger et al., "Access Path Selection in a Relational Database Management System", SIGMOD 1979.
- V. Leis et al., "How Good Are Query Optimizers, Really?", PVLDB vol. 9, n. 3, 2015: https://www.vldb.org/pvldb/vol9/p204-leis.pdf
- SQLAlchemy 2.0, "Relationship Loading Techniques": https://docs.sqlalchemy.org/en/20/orm/queryguide/relationships.html
- Psycopg 3, "Prepared statements": https://www.psycopg.org/psycopg3/docs/advanced/prepare.html
- Markus Winand, "No Offset": https://use-the-index-luke.com/no-offset
