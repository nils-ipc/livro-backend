# Planos de execução

## O painel das 400 consultas e a estagiária na página 4.000

O gerente de produto ganhou o painel que pediu, e o painel ganhou o banco de dados inteiro de brinde.

A tela mostra as últimas 100 vendas do dia do Bazar, com vendedor, comprador, split e estornos. O ORM fez uma consulta para as 100 cobranças e, depois, uma por relação, por cobrança: cem compradores, cem splits, cem listas de estornos e 99 vendedores, porque o *identity map* do SQLAlchemy já tinha a Capinhas na sessão e poupou uma ida ao banco. Total: 400 consultas por tela. O gerente chamou isso de "tempo real". O PostgreSQL chamou de assédio.

Cada ida e volta, somando rede e ORM, custa perto de 1 ms. A tela demora 420 ms com uma conexão do pool de 15 (capítulo 4) presa o tempo todo, e se atualiza a cada 15 segundos em 40 abas abertas no Bazar: mais de mil consultas por segundo para mostrar 100 linhas, num banco que recebe 50 lançamentos por segundo no pico. O painel virou o maior cliente da Lastro e não paga tarifa.

Enquanto isso, a estagiária da Capinhas clicou na página 4.000 do extrato completo: `OFFSET 199950`, 3,4 segundos, com o índice perfeito do capítulo 5 sendo usado. O Bazar abriu o chamado. O helpdesk tem template.

Às 18h, o cabeçalho do painel, com o total vendido por vendedor, que às 9h saía em meio segundo, leva 7,4 segundos. Ninguém mudou nada. O banco ficou mais burro ao longo do dia, igual a todos nós.

Como o banco decide o que fazer com uma consulta, e como você descobre isso antes do Bazar?

## EXPLAIN, ou como fazer o banco confessar

O SQL diz o que você quer; o *planner* (planejador) decide como buscar: gera planos alternativos, estima o custo de cada um e executa o mais barato. O plano é uma árvore de nós, cada um entregando linhas ao pai.

`EXPLAIN` mostra o plano sem executar. `EXPLAIN ANALYZE` executa e mostra, ao lado de cada estimativa, o que aconteceu: é o banco tirando a roupa na sua frente, e ninguém fica bonito. `BUFFERS` acrescenta quantas páginas de 8 KB cada nó achou no cache (`shared hit`) e quantas pediu ao sistema operacional (`read`); no PostgreSQL 18, vem ligado por padrão com `ANALYZE`.

Cada nó traz dois grupos de números:

- `cost=0.43..8.45 rows=1 width=16`: custo de partida (até a primeira linha), custo total, linhas estimadas e largura média em bytes. O custo é uma unidade arbitrária, calibrada em leituras de página: `seq_page_cost = 1`, `random_page_cost = 4`, `cpu_tuple_cost = 0.01`, `cpu_index_tuple_cost = 0.005`, `cpu_operator_cost = 0.0025`. Milissegundo, nunca. Custo é a fé do planner expressa em páginas.
- `actual time=0.019..21.330 rows=11802 loops=1`: tempo real até a primeira linha e até a última, em milissegundos, linhas produzidas e quantas vezes o nó rodou. Tempo e linhas são médias **por loop**. Um nó com `actual time=0.6` e `loops=11802` custou sete segundos, e o plano não soma isso para você, porque o PostgreSQL acha que você é adulto.

As folhas são os nós de leitura do capítulo 5 (`Seq Scan`, `Index Scan`, `Index Only Scan`, `Bitmap Heap Scan`); acima ficam `Sort`, `Limit`, `HashAggregate` e as junções. A pergunta que resolve metade dos planos ruins: em que nó `rows` estimado e `rows` real se separam por uma ordem de grandeza? Dali para cima, tudo foi escolhido com base numa mentira.

> **Armadilha:** `EXPLAIN ANALYZE` executa a consulta. Inclusive `UPDATE` e `DELETE`. O Carlos descobriu isso com um `EXPLAIN ANALYZE DELETE FROM lancamentos WHERE ...` "só para ver o plano", e quem salvou o ledger foi o trigger de imutabilidade do capítulo 1, que recusou o `DELETE` com a dignidade de um tabelião. Para medir escrita, o comando vai dentro de `BEGIN` e termina em `ROLLBACK`.

## Três jeitos de juntar duas tabelas

O `JOIN` que você escreve é uma intenção. O banco tem três algoritmos para cumpri-la, e cada um tem o seu fetiche.

**Nested loop.** Para cada linha do lado externo, procura as correspondentes no lado interno: N buscas de O(log M) com índice no interno, N varreduras completas sem ele. Tem custo de partida quase zero (combina com `LIMIT`) e aceita qualquer condição, inclusive desigualdade. É a relação de muitos para muitos atendida um de cada vez, e o algoritmo que transforma uma estimativa de 1 linha em 11.802 varreduras. Já chegamos lá.

**Hash join.** Lê o lado menor inteiro (o *build*), monta uma tabela hash pela chave e percorre o lado maior (o *probe*) consultando a tabela. Custa O(N + M), só serve para igualdade e paga a construção antes da primeira linha. A tabela cabe em `work_mem × hash_mem_multiplier` (4 MB × 2,0 por padrão desde o PostgreSQL 15); se não couber, o plano mostra `Batches: 8` e o resto vai para disco.

**Merge join.** Recebe os dois lados ordenados pela chave e avança em paralelo, o passo de intercalação do merge sort. Custa O(N + M) mais as ordenações que faltarem; com os dois lados saindo ordenados de índices, sai quase de graça.

| Algoritmo | Custo típico | Bom quando | Ruim quando |
|-----------|--------------|------------|-------------|
| Nested loop | N × busca no interno | Externo pequeno, índice no interno, `LIMIT` | Externo grande e interno sem índice |
| Hash join | N + M, memória do lado menor | Igualdade, nenhum lado pequeno, sem ordem útil | Lado de build maior que a memória |
| Merge join | N + M + ordenações | Entradas grandes já ordenadas | Ordenar tudo só para juntar |

A escolha depende de quantas linhas cada lado tem, e o planner nunca conta linhas: ele estima.

## Estatísticas, ou o planner decide com o que viu há 19 dias

As estimativas vêm de `pg_statistic` (legível pela view `pg_stats`), preenchida pelo `ANALYZE`. Por coluna: fração de nulos, número estimado de valores distintos (`n_distinct`), os valores mais comuns com suas frequências (MCV), um histograma de faixas com o mesmo número de linhas cada para o resto, e a `correlation` do capítulo 5. Com `default_statistics_target = 100`, são até 100 valores comuns e 100 faixas, tirados de uma amostra de 300 × 100 = 30.000 linhas, tenha a tabela mil linhas ou um bilhão. O planner decide o destino de 40 milhões de lançamentos com base numa pesquisa de opinião.

Igualdade usa o MCV, faixa interpola no histograma, e duas condições juntas multiplicam as seletividades, assumindo colunas independentes. Em `cidade = 'Campinas' AND uf = 'SP'`, isso divide a estimativa pela fração de SP sem motivo, porque toda Campinas do cadastro já está em SP. `CREATE STATISTICS` (tipos `dependencies`, `ndistinct` e `mcv`) coleta estatística sobre combinações de colunas.

O autovacuum roda `ANALYZE` quando as linhas alteradas desde o último passam de `autovacuum_analyze_threshold + autovacuum_analyze_scale_factor × linhas`: por padrão, 50 + 10% da tabela. Em `cobrancas`, com 9 milhões de linhas, são 900 mil alterações; a umas 12 mil cobranças por dia, um `ANALYZE` a cada 75 dias. O último foi há 19.

O histograma de `criado_em` termina 19 dias atrás. Para ele, hoje não existe: a estimativa para `criado_em >= current_date` cai para quase zero e vira `rows=1`. Quando há uma B-tree que começa pela coluna, o planner lê no índice o valor máximo real e corrige o extremo do histograma; o índice do painel é `(marketplace_id, criado_em)` e começa pela coluna errada. O banco acredita, com a convicção de um sistema determinístico, que o Bazar vendeu uma coisa hoje. Uma. Provavelmente uma capinha.

O cabeçalho do painel junta as cobranças do dia com a conta disponível de cada vendedor, e `contas.vendedor_id` não tem índice (o PostgreSQL nunca indexa sozinho a coluna que referencia numa chave estrangeira). Com 1 linha prevista do lado de fora, o mais barato é um nested loop que varre `contas` uma vez. Uma vez por venda, e foram 11.802:

```text
HashAggregate  (cost=214.02..214.03 rows=1 width=40) (actual time=7409.80..7410.21 rows=1187 loops=1)
  Group Key: k.id
  ->  Nested Loop  (cost=0.43..214.01 rows=1 width=16) (actual time=0.08..7398.10 rows=11802 loops=1)
        Join Filter: (k.vendedor_id = c.vendedor_id)
        Rows Removed by Join Filter: 14150598
        ->  Index Scan using cobrancas_marketplace_criado_idx on cobrancas c
              (cost=0.43..8.45 rows=1 width=16) (actual time=0.02..21.33 rows=11802 loops=1)
              Index Cond: ((marketplace_id = 1) AND (criado_em >= CURRENT_DATE))
        ->  Seq Scan on contas k  (cost=0.00..202.50 rows=1200 width=16) (actual time=0.01..0.62 rows=1200 loops=11802)
              Filter: (tipo = 'disponivel'::text)
              Rows Removed by Filter: 7800
Execution Time: 7410.63 ms
```

De baixo para cima: `rows=1` contra `rows=11802` em `cobrancas`, ali nasceu a mentira. O `Seq Scan` em `contas` leva 0,62 ms, ótimo até você ver `loops=11802`, e o nested loop jogou fora 14 milhões de pares para achar 11.802. Às 9h, com 500 vendas, eram 500 varreduras e meio segundo. O banco punia o sucesso comercial com uma precisão que o financeiro respeitaria.

Depois de um `ANALYZE cobrancas`, que lê 30 mil linhas de amostra e termina em menos de um segundo:

```text
HashAggregate  (actual time=29.95..30.41 rows=1187 loops=1)
  ->  Hash Join  (rows=11650) (actual time=1.92..26.07 rows=11802 loops=1)
        Hash Cond: (c.vendedor_id = k.vendedor_id)
        ->  Index Scan using cobrancas_marketplace_criado_idx on cobrancas c (rows=11650) (actual rows=11802 loops=1)
        ->  Hash  (actual rows=1200 loops=1)
              ->  Seq Scan on contas k  (actual rows=1200 loops=1)
Execution Time: 30.88 ms
```

Mesma consulta, mesmos dados. A estimativa certa trocou o algoritmo, `contas` passou a ser lida uma vez, e 7,4 segundos viraram 31 ms sem mudar uma linha de código.

## N+1, o ORM que pergunta uma coisa de cada vez

A lista do painel tem outro defeito, e esse nenhum `ANALYZE` conserta. N+1: uma consulta traz N objetos, e o acesso a uma relação em cada um dispara mais uma. A culpa mora num inocente `cobranca.vendedor.nome` dentro de um laço do template, que o *lazy loading* transforma em ida ao banco. Cada consulta tem plano ótimo e índice certo. O problema é haver 400 delas.

O log do SQLAlchemy entrega o crime em forma de poesia concreta:

```text
SELECT ... FROM cobrancas WHERE marketplace_id = 1 AND criado_em >= ... ORDER BY criado_em DESC LIMIT 100
SELECT ... FROM compradores WHERE compradores.id = 991827
SELECT ... FROM recebedores_split WHERE recebedores_split.cobranca_id = 8812340
SELECT ... FROM estornos WHERE estornos.cobranca_id = 8812340
SELECT ... FROM vendedores WHERE vendedores.id = 7310
SELECT ... FROM compradores WHERE compradores.id = 1004512
... (mais 394)
```

Em produção, quem denuncia é o `pg_stat_statements`, que agrega por texto normalizado: `SELECT ... FROM estornos WHERE cobranca_id = $1` com milhões de `calls` e 0,1 ms de média. Média ótima, total obsceno. É o bandido que só rouba um centavo por vez e já levou a empresa inteira.

O custo mora fora do banco: ida e volta na rede, serialização, um `await` e o ORM montando objetos. A 1 ms por ida e volta, 400 consultas custam 400 ms mesmo com o banco respondendo instantaneamente.

A cura, em qualquer ORM, é dizer antes o que vai ser lido:

- Junção na própria consulta (`joinedload` no SQLAlchemy, `select_related` no Django): uma consulta só. Perfeita para muitos-para-um. Em coleções, multiplica: 100 cobranças × 4 recebedores × 2 estornos viram 800 linhas para montar 100 objetos, o produto cartesiano do amor.
- Uma consulta por relação com `IN` (`selectinload`, `prefetch_related`): `WHERE cobranca_id IN (...)` com os 100 IDs de uma vez, sem multiplicação.
- SQL escrito para a tela, com agregação no banco, quando a tela mostra um resumo e não objetos.

Para o N+1 não voltar quando alguém acrescentar uma coluna ao template, o SQLAlchemy aceita `lazy="raise"` na relação: acessar algo não carregado levanta exceção em vez de consultar em silêncio. A lentidão em produção vira erro no teste. Crime desses merece flagrante.

## OFFSET, o banco que conta até 199.950 em voz alta

A documentação do PostgreSQL avisa: as linhas puladas por `OFFSET` ainda são computadas no servidor. O nó `Limit` puxa linhas do filho e descarta as primeiras, e tudo abaixo dele (índice, heap, a junção com `transacoes` para buscar a descrição) roda 200.000 vezes. É uma chacina de 199.950 linhas para entregar 50, com atestado de óbito:

```text
Limit  (actual time=3021.40..3022.17 rows=50 loops=1)
  Buffers: shared hit=402118 read=187441
  ->  Nested Loop  (actual time=0.05..3008.62 rows=200000 loops=1)
```

O custo cresce linear com a página: a 1 sai em 1 ms, a 4.000 em 3 segundos, e a 22.012 (a última da Capinhas) leva o tempo de a estagiária ser efetivada. Some o `COUNT(*)` que o paginador roda para escrever "página 4.000 de 22.012", contando 1,1 milhão de lançamentos a cada clique.

E tem um defeito de correção: se entra um lançamento entre a página 1 e a 2, tudo escorrega uma posição, e o último item da 1 reaparece no topo da 2. Em extrato financeiro, linha repetida vira chamado com o assunto que você conhece.

A paginação por cursor (*keyset pagination*) troca "pule N linhas" por "continue de onde parou": o cliente devolve a chave da última linha vista, e ela vira limite de faixa no índice:

```sql
SELECT criado_em, id, valor, transacao_id
FROM lancamentos
WHERE conta_id = $1
  AND (criado_em, id) < ($2, $3)   -- última linha da página anterior
ORDER BY criado_em DESC, id DESC
LIMIT 50;
```

A comparação de linha é lexicográfica: `criado_em` e, só no empate, `id`. O desempate é obrigatório, porque lançamentos da mesma transação têm o mesmo `criado_em` (`now()` devolve o início da transação), e um cursor só por `criado_em` pularia ou repetiria linhas. Com a chave de índice `(conta_id, criado_em, id)`, o banco desce três níveis da B-tree até o cursor e lê 50 entradas, na página 1 ou na 4.000.

O preço: nada de pular direto para a página 4.000, nada de "página X de Y", e a ordenação precisa casar com um índice. Quem quer outubro usa o extrato por período do capítulo 5.

## O painel e o extrato da Lastro

A lista do painel passa a carregar vendedor e comprador por junção (muitos-para-um) e split e estornos por `selectinload`: 3 consultas por tela no lugar de 400, com todas as relações em `lazy="raise"`. O total por vendedor segue como agregação no banco.

| Opção para a lista | Consultas por tela | Linhas transferidas | Custo |
|--------------------|--------------------|---------------------|-------|
| Lazy loading (antes) | 400 | ~800 | 420 ms, conexão presa o tempo todo |
| `joinedload` em tudo | 1 | ~800, com repetição | Produto cartesiano entre split e estornos |
| Junção + `selectinload` (escolhida) | 3 | ~900, sem repetição | ~6 ms |
| SQL próprio com `json_agg` | 1 | 100 | Menos linhas; mapeamento à mão para cada tela |

O requisito é atualizar 40 abas a cada 15 segundos sem prender o pool de 15 conexões: 3 idas e voltas por tela resolvem, e o código segue no ORM. SQL próprio com `json_agg` vira a escolha certa quando a tela tiver relações aninhadas em vários níveis, onde até o `selectinload` empilha consultas.

Para as estimativas, `cobrancas` e `lancamentos` ganham autovacuum próprio: `autovacuum_analyze_scale_factor = 0` e `autovacuum_analyze_threshold = 5000`, um `ANALYZE` a cada 5 mil linhas alteradas, algumas vezes por dia em `cobrancas` e de hora em hora em `lancamentos` no pico. O requisito é o painel do dia: consulta que filtra "hoje" precisa de um histograma que saiba que hoje existe, e cada `ANALYZE` custa menos de um segundo. `contas.vendedor_id` ganha índice com `CONCURRENTLY` (o Carlos foi consultado e disse que dessa vez quer só assistir): 9 mil linhas, escrita rara, custo quase nulo.

O extrato completo pagina por cursor: a API devolve 50 lançamentos e um `proximo_cursor` opaco, a codificação de `(criado_em, id)` da última linha, validado como qualquer entrada e restrito à conta que o cliente já pode ver (o contrato fica para o capítulo 11). Sem `COUNT(*)` e sem número de página.

Isso muda o índice do capítulo 5 para `(conta_id, criado_em, id) INCLUDE (valor, transacao_id)`. O `id` entra na chave porque precisa participar da ordem e do limite de faixa; são 8 bytes por entrada, de 2 GB para perto de 2,3 GB, e o prefixo `conta_id` segue servindo ao extrato por período e ao `SUM` do trigger de débito. O novo nasce com `CONCURRENTLY` antes de o antigo sair com `DROP INDEX CONCURRENTLY` (detalhes no capítulo 7). Qualquer página sai em 0,4 ms. A estagiária nem percebeu: agora não existe página 4.000, existe "carregar mais", e ela está clicando nele há vinte minutos.

## Armadilhas e casos reais

> **Armadilha:** otimizar pela média do `pg_stat_statements`. A consulta de 0,1 ms com 30 milhões de `calls` por dia gasta mais banco que o relatório de 4 segundos que roda duas vezes.

> **Armadilha:** confiar no plano do ambiente de teste. Com mil linhas, o seq scan ganha de tudo e qualquer plano parece genial; as estatísticas de uma base pequena descrevem outro banco. O plano que importa é o de produção, que o `auto_explain` grava no log quando a consulta passa de `auto_explain.log_min_duration`.

> **Armadilha:** cursor por `criado_em` para sincronização. Uma transação que começou antes e confirmou depois grava um `criado_em` mais antigo que o cursor que o cliente já passou, e a linha some da listagem. Para exibir extrato, serve; para um consumidor que precisa ver todas as linhas, o assunto volta nos capítulos 17 e 18.

> **Na vida real:** o Rails tem a gem Bullet só para avisar quando uma página dispara carregamento preguiçoso em laço. Cada ORM popular reinventou a mesma cura (`includes`, `prefetch_related`, `selectinload`) para a mesma doença, o que diz muito sobre a doença.

> **Na vida real:** Markus Winand mantém a página "No Offset" no *Use The Index, Luke!* com o argumento de custo do OFFSET. Os frameworks continuam gerando `OFFSET` por padrão, porque "página 4.000 de 22.012" fica bonito na tela até alguém clicar.

## Resumo

- `EXPLAIN` mostra o plano, `EXPLAIN ANALYZE` executa e mostra o real; tempo e linhas são por loop.
- Nested loop para externo pequeno; hash join para igualdade entre entradas grandes; merge join para entradas ordenadas.
- Estimativas vêm de `pg_stats`, amostradas pelo `ANALYZE`, com colunas independentes salvo `CREATE STATISTICS`; em tabela grande, o histograma envelhece.
- N+1: carregamento explícito (junção ou `IN`) e `lazy="raise"`.
- OFFSET custa linear na página e repete linhas sob inserção; cursor custa constante e exige ordem total casada com um índice.

## A Lastro agora

O painel caiu de 400 consultas para 3; o total por vendedor, de 7,4 s para 31 ms, com `ANALYZE` a cada 5 mil alterações e índice em `contas.vendedor_id`. O extrato pagina por cursor `(criado_em, id)` sobre o índice `(conta_id, criado_em, id) INCLUDE (valor, transacao_id)`, em 0,4 ms por página.

O banco passou 19 dias convencido de que o Bazar vendia uma coisa por dia, e a única pessoa da empresa com o mesmo nível de certeza sobre um dado errado é o fundador. Agora o gerente de produto voltou de uma reunião com um marketplace argentino e diz que suporte a outra moeda "é só uma coluna" em `lancamentos`. Uma coluna, numa tabela que não para de receber Pix nem às 3h da manhã. O Carlos já se ofereceu para o `ALTER TABLE`, rapidinho.

## Referências

- PostgreSQL 16, "Using EXPLAIN": <https://www.postgresql.org/docs/16/using-explain.html>
- PostgreSQL 16, "Statistics Used by the Planner": <https://www.postgresql.org/docs/16/planner-stats.html>
- PostgreSQL 16, "Row Estimation Examples": <https://www.postgresql.org/docs/16/row-estimation-examples.html>
- PostgreSQL 16, "Planner Cost Constants" e demais parâmetros de consulta: <https://www.postgresql.org/docs/16/runtime-config-query.html>
- PostgreSQL 16, "CREATE STATISTICS": <https://www.postgresql.org/docs/16/sql-createstatistics.html>
- PostgreSQL 16, "Routine Vacuuming" (autovacuum e `ANALYZE`): <https://www.postgresql.org/docs/16/routine-vacuuming.html>
- PostgreSQL 16, "LIMIT and OFFSET": <https://www.postgresql.org/docs/16/queries-limit.html>
- PostgreSQL 16, `pg_stat_statements`: <https://www.postgresql.org/docs/16/pgstatstatements.html>
- PostgreSQL 16, `auto_explain`: <https://www.postgresql.org/docs/16/auto-explain.html>
- SQLAlchemy 2.0, "Relationship Loading Techniques": <https://docs.sqlalchemy.org/en/20/orm/queryguide/relationships.html>
- Django, `select_related` e `prefetch_related`: <https://docs.djangoproject.com/en/stable/ref/models/querysets/>
- Markus Winand, "No Offset", Use The Index, Luke!: <https://use-the-index-luke.com/no-offset>
