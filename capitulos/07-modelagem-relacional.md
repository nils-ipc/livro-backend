# Modelagem relacional

## O cliente que tinha três e-mails

O Ricardo recebeu o mesmo cupom de aniversário da loja em três endereços: o e-mail de um emprego de 2019, um com erro de digitação corrigido há dois anos e o certo, o único que caiu no spam. O marketing, que disparou a campanha naquela manhã, ficou muito satisfeito com a taxa de entrega.

A query fez o que pediam: `SELECT DISTINCT cliente_email FROM pedidos_v2_final`. Essa tabela (47 colunas, nenhuma restrição além da chave primária, criada "provisoriamente" em 2020) guarda o e-mail do cliente em cada pedido. Quando o Ricardo atualizou o cadastro, o código atualizou `clientes` e os pedidos abertos. Os antigos ficaram com o e-mail da época.

O banco nunca reclamou. Aceitaria um quarto e-mail, e também um pedido com quantidade `-3` de um produto inexistente para um cliente apagado em março.

Este capítulo responde a duas perguntas que essa tabela levanta: onde cada fato deve morar para existir uma vez só, e o que o banco consegue garantir sozinho, sem depender de que todo código que escreve nele se lembre das regras?

## Chaves, ou como o banco sabe quem é quem

Uma **superchave** é qualquer conjunto de colunas cujos valores nunca se repetem em duas linhas. Uma **chave candidata** é uma superchave mínima: tirando qualquer coluna dela, ela deixa de identificar a linha. A **chave primária** é a chave candidata escolhida para ser referenciada pelas outras tabelas. As outras candidatas continuam existindo e merecem uma restrição `UNIQUE`, porque continuam sendo regras do domínio.

A escolha da chave primária tem uma consequência mecânica: o valor dela é copiado para toda tabela que a referencia e para todo índice que a inclui. Escolher a chave é escolher o que vai se espalhar pelo banco inteiro.

### Chave natural

Uma **chave natural** vem do domínio: CPF, ISBN, placa do carro, código IATA do aeroporto. Ela tem uma vantagem real. Se `pedidos.uf` referencia `estados.sigla`, uma consulta que só precisa da sigla dispensa o `JOIN`.

O problema é que o domínio muda de ideia. O ISBN passou de 10 para 13 dígitos em 1º de janeiro de 2007. E-mail, o favorito de quem modela `usuarios` às 18h de uma sexta, muda com o emprego (o Ricardo que o diga). Cada mudança vira um `UPDATE` em cascata por todas as tabelas que copiaram a chave, segurando locks em cada linha tocada. Uma chave natural precisa ser única, obrigatória e imutável; muitos identificadores do mundo real cumprem duas das condições, e o sistema descobre qual faltou em produção.

### Chave substituta e sequências

Uma **chave substituta** (*surrogate key*) não significa nada fora do banco: é um número ou um identificador gerado só para identificar a linha. Como não significa nada, ela nunca precisa mudar.

No PostgreSQL 10+, a forma padrão é a coluna de identidade do SQL:2003, `bigint GENERATED ALWAYS AS IDENTITY`, que usa por baixo uma **sequência** (o objeto que devolve o próximo número com `nextval()`). O `ALWAYS` impede ids escritos à mão, como aquele `INSERT` de teste com `id = 1000000` que um dia colide com o número gerado.

A sequência **não é transacional**: o `nextval()` entrega o número na hora, e um `ROLLBACK` não o devolve. Transações concorrentes nunca recebem o mesmo valor nem esperam umas pelas outras, e o preço disso são buracos normais na numeração (depois de um crash, até 32 valores pré-registrados no WAL também somem). Nota fiscal sem lacunas precisa de uma linha contadora atualizada dentro da transação, com o lock e a fila que isso implica.

Um `integer` vai até 2.147.483.647; a 100 inserções por segundo, acaba em 248 dias. Um `bigint` vai até 9,22 × 10¹⁸; a um milhão de inserções por segundo, dura cerca de 292 mil anos, tempo suficiente para alguém remover o `TODO` da tabela. A diferença é de 4 bytes por linha e por referência.

### UUID

Um **UUID** tem 128 bits (16 bytes no tipo `uuid`) e pode ser gerado em qualquer lugar sem consultar ninguém, o que permite criar o id antes do `INSERT` ou mesclar dados de vários bancos sem colisão.

A versão 4 tem 122 bits aleatórios; a colisão chega a 50% de chance depois de uns 2,7 × 10¹⁸ ids. O problema prático é o índice. Com sequências, toda inserção vai para a folha mais à direita da B-tree, quente no cache, e o PostgreSQL a divide deixando a página da esquerda cheia (até o *fillfactor*, 90% por padrão). Com UUIDv4, cada inserção cai numa folha aleatória, as divisões no meio deixam páginas pela metade e o conjunto de páginas que precisa estar em memória passa a ser o índice inteiro. Com 500 milhões de linhas, o disco percebe e manda lembranças. O capítulo 8 detalha a B-tree.

A RFC 9562 (maio de 2024) definiu o **UUIDv7**: os primeiros 48 bits são o timestamp Unix em milissegundos, e o resto é versão, variante e aleatoriedade. Valores gerados em sequência ficam aproximadamente ordenados. O PostgreSQL 18 tem `uuidv7()`, e o Python 3.14 tem `uuid.uuid7()`:

```python
import uuid
from datetime import datetime, UTC

v7 = [uuid.uuid7() for _ in range(3)]
v4 = [uuid.uuid4() for _ in range(3)]

for u in v7:
    print(u)
print("v7 ordenado:", sorted(v7) == v7)
print("v4 ordenado:", sorted(v4) == v4)

ms = int(v7[0].hex[:12], 16)  # os 48 bits do timestamp
print(datetime.fromtimestamp(ms / 1000, tz=UTC))
```

```text
01a15479-2378-7a3c-8e41-0b2d9f6c1e57
01a15479-2378-7a3c-8e41-0b2e4a83d0f2
01a15479-2378-7a3c-8e41-0b2f71c5b98e
v7 ordenado: True
v4 ordenado: False
2026-10-19 14:03:07.512000+00:00
```

Os três nasceram no mesmo milissegundo, e o Python usa parte dos bits aleatórios como contador para manter a ordem (`0b2d`, `0b2e`, `0b2f`). A última linha mostra o custo: quem vê o id sabe quando a linha foi criada. Num id de conta exposto na URL, alguns ids coletados revelam a taxa de crescimento da base, o que transforma o concorrente num analista de dados bastante motivado.

## Dependências funcionais, ou quem decide o valor de quem

A normalização inteira se apoia numa definição. Uma **dependência funcional** `X → Y` vale numa tabela quando quaisquer duas linhas com os mesmos valores em `X` têm, obrigatoriamente, os mesmos valores em `Y`. `produto_id → produto_nome` quer dizer que um produto tem um nome só. `X` é o **determinante**.

A dependência vem das regras do domínio. Se cada cliente atual mora numa cidade diferente, os dados parecem satisfazer `cidade → cliente_id`, até o segundo cliente de Campinas. A tabela da campanha, com as colunas que interessam:

```text
pedidos_v2_final(
    pedido_id, produto_id,              -- chave primária composta
    quantidade, preco_unitario,
    produto_nome,
    data_pedido, cliente_id, cliente_email, cliente_cidade
)

pedido_id, produto_id → quantidade, preco_unitario
produto_id            → produto_nome
pedido_id             → data_pedido, cliente_id
cliente_id            → cliente_email, cliente_cidade
```

As formas normais são condições sobre essas dependências, cada uma mais exigente que a anterior.

### Primeira forma normal

Na **1FN**, cada coluna guarda um valor atômico, sem grupos repetidos. A violação clássica é `telefones = '11 99999-0001, 11 3333-0002'`, ou `telefone1`, `telefone2`, `telefone3` (e o quarto telefone, que mora nas observações). Um array do PostgreSQL sempre lido inteiro não incomoda; quando a aplicação precisa buscar ou referenciar elementos individuais, cada um virou um fato e precisa de uma linha.

### Segunda forma normal

Na **2FN**, nenhuma coluna fora da chave depende de só uma parte de uma chave candidata. A tabela da campanha viola isso duas vezes: `produto_nome` depende só de `produto_id`, e `data_pedido` e `cliente_id` só de `pedido_id`. A correção separa `itens_pedido(pedido_id, produto_id, quantidade, preco_unitario)`, `produtos(produto_id, produto_nome)` e `pedidos(pedido_id, data_pedido, cliente_id, ...)`. Tabela com chave de coluna única satisfaz a 2FN automaticamente, o que a torna a forma normal mais fácil de passar sem estudar.

### Terceira forma normal

Na **3FN**, nenhuma coluna fora das chaves depende de outra coluna fora das chaves. Em `pedidos`, `pedido_id → cliente_id → cliente_email` é uma **dependência transitiva**, a mesma que mandou três cupons para o Ricardo. A correção deixa `cliente_email` e `cliente_cidade` só em `clientes`. O resumo atribuído a William Kent: cada coluna depende "da chave, da chave inteira e de nada além da chave".

### Forma normal de Boyce-Codd

A **BCNF** é mais curta de enunciar: para toda dependência funcional não trivial `X → Y`, `X` é uma superchave. A 3FN tem uma brecha que a BCNF fecha: ela tolera um determinante que não é chave quando a coluna determinada faz parte de alguma chave candidata.

O exemplo canônico precisa de três colunas. Uma escola oferece reforço: cada aluno tem um monitor por disciplina, e cada monitor atende uma única disciplina.

```text
reforco(aluno, disciplina, monitor)

aluno, disciplina → monitor
monitor           → disciplina

chaves candidatas: {aluno, disciplina} e {aluno, monitor}
```

Toda coluna está em alguma chave, então a 3FN passa. Mas `monitor → disciplina` tem determinante que não é superchave, e a tabela repete "o Paulo dá Química" em cada aluno do Paulo; esquecer uma linha na atualização produz um monitor com duas disciplinas.

A decomposição em BCNF, `monitores(monitor, disciplina)` e `reforco(aluno, monitor)`, não perde informação (o `JOIN` reconstrói a original), mas perde a regra "um monitor por aluno e disciplina", que deixa de caber num `UNIQUE` e passa a exigir trigger ou checagem na aplicação. É um resultado conhecido: toda tabela tem decomposição em 3FN que preserva as dependências, e nem toda tem uma em BCNF. Na maioria dos esquemas reais as duas coincidem, e o monitor aparece mais em prova do que em produção.

## As anomalias que a normalização evita

Codd descreveu no início dos anos 1970 os defeitos de uma tabela com fatos repetidos, e eles continuam aparecendo em tabelas criadas ontem. Na **anomalia de atualização**, a do Ricardo, o mesmo fato está em várias linhas e uma atualização parcial deixa o banco com duas versões, e qual aparece depende de qual linha a consulta encontrou primeiro. Na **anomalia de inserção**, um fato não pode ser registrado sem outro não relacionado: em `pedidos_v2_final`, um produto só ganha nome quando alguém o compra, e o cadastro depende de um primeiro cliente corajoso. Na **anomalia de exclusão**, apagar o último pedido de um cliente apaga o único registro do e-mail dele, e o suporte, ao limpar um pedido de teste, faz o cliente deixar de existir. A causa é sempre uma linha guardando mais de um fato independente.

## Desnormalização, ou o preço de cada cópia

**Desnormalizar** é reintroduzir de propósito uma cópia de um dado, para que uma leitura frequente evite um `JOIN` ou uma agregação (guardar `clientes.qtd_pedidos` em vez de contar a cada abertura do perfil). Daí em diante, toda escrita na fonte precisa atualizar a cópia, e a anomalia de atualização volta a ser possível. O mecanismo de manutenção define o custo:

| Mecanismo | Consistência da cópia | Custo na escrita | Escopo |
|-----------|-----------------------|------------------|--------|
| Código da aplicação | Só se todo caminho de escrita lembrar | Baixo | Qualquer |
| Trigger | Mesma transação | Alto: trabalho extra e lock na linha da cópia | Mesmo banco |
| Coluna gerada (`GENERATED ... STORED`) | Sempre igual | Cálculo por linha | Só a mesma linha |
| View materializada | Envelhece até o `REFRESH` | Zero na escrita; custo no refresh | Qualquer consulta |
| Replicação para outro sistema (CDC) | Atrasada (segundos) | Zero no banco; operação de um pipeline | Outro banco, busca, cache |

O trigger garante a consistência porque roda na mesma transação, mas transforma a linha da cópia num ponto de contenção:

```sql
CREATE FUNCTION conta_pedido() RETURNS trigger AS $$
BEGIN
    -- toda inserção em pedidos agora passa por esta linha. Sem pressão.
    UPDATE clientes SET qtd_pedidos = qtd_pedidos + 1
     WHERE id = NEW.cliente_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pedidos_conta_pedido
    AFTER INSERT ON pedidos
    FOR EACH ROW EXECUTE FUNCTION conta_pedido();
```

Para a conta corporativa que importa 40 mil pedidos por hora, cada inserção espera o lock da mesma linha de `clientes`, e as importações concorrentes andam em fila indiana (o capítulo 11 trata de contenção). E o trigger só cobre o `INSERT`: `DELETE` e troca de `cliente_id` precisam de outros dois, exatamente a parte que fica para depois.

A coluna gerada (`valor_total numeric GENERATED ALWAYS AS (quantidade * preco_unitario) STORED`) é a cópia mais barata, mas só usa colunas da mesma linha e funções imutáveis. No PostgreSQL 18 ela também pode ser `VIRTUAL`, calculada na leitura.

Guardar `preco_unitario` em `itens_pedido` mesmo havendo `produtos.preco` está normalizado: são dois fatos, o preço atual e o preço daquela venda. Se o pedido de ontem acompanhasse o preço de hoje, o financeiro descobriria que a receita do trimestre passado foi revisada por uma promoção. O critério é se a cópia deve acompanhar a fonte; se não deve, é um fato histórico com o mesmo nome de coluna.

## O banco como último revisor

Uma restrição de integridade é uma regra que o banco verifica em toda escrita, venha ela do ORM, de uma migração ou de um `psql` aberto às 23h. A validação na aplicação protege só o caminho que passa por ela. E verificar "esse e-mail existe?" com `SELECT` antes do `INSERT` é um check-then-act que duas requisições simultâneas atravessam juntas (capítulo 5); o índice único verifica e insere num passo só.

```sql
CREATE TABLE clientes (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       text NOT NULL,
    nome        text NOT NULL,
    qtd_pedidos integer NOT NULL DEFAULT 0
);
-- UNIQUE (email) aceitaria 'Ana@Example.com' e 'ana@example.com'
CREATE UNIQUE INDEX clientes_email_lower_key ON clientes (lower(email));

CREATE TABLE pedidos (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cliente_id  bigint NOT NULL REFERENCES clientes (id),
    status      text NOT NULL DEFAULT 'aberto'
                CHECK (status IN ('aberto', 'pago', 'enviado', 'cancelado')),
    criado_em   timestamptz NOT NULL DEFAULT now()
);
-- o PostgreSQL não cria índice no lado que referencia
CREATE INDEX pedidos_cliente_id_idx ON pedidos (cliente_id);
```

E o banco passa a recusar o que antes aceitava em silêncio:

```text
loja=> INSERT INTO pedidos (cliente_id) VALUES (999);
ERROR:  insert or update on table "pedidos" violates foreign key constraint "pedidos_cliente_id_fkey"
DETAIL:  Key (cliente_id)=(999) is not present in table "clientes".

loja=> UPDATE pedidos SET status = 'quase pago' WHERE id = 1;
ERROR:  new row for relation "pedidos" violates check constraint "pedidos_status_check"
DETAIL:  Failing row contains (1, 1, quase pago, 2026-10-19 11:02:44.81233-03).

loja=> INSERT INTO clientes (email, nome) VALUES ('Ana@Example.com', 'Ana');
ERROR:  duplicate key value violates unique constraint "clientes_email_lower_key"
DETAIL:  Key (lower(email))=(ana@example.com) already exists.
```

O status `quase pago` existia em produção desde um hotfix de 2022, e ninguém sabia qual relatório o tratava como pago. A sequência, por sua vez, não devolve números:

```text
loja=> BEGIN;
loja=*> INSERT INTO clientes (email, nome) VALUES ('bia@example.com', 'Bia') RETURNING id;
 id
----
  7
(1 row)

INSERT 0 1
loja=*> ROLLBACK;
loja=> INSERT INTO clientes (email, nome) VALUES ('bia@example.com', 'Bia') RETURNING id;
 id
----
  8
(1 row)

INSERT 0 1
```

O "cliente 7 desaparecido" da auditoria morreu num `ROLLBACK`, sem nenhum ataque hacker envolvido.

Na chave estrangeira, `ON DELETE` define o destino das dependentes: `NO ACTION` (padrão) e `RESTRICT` recusam a exclusão, `CASCADE` apaga, `SET NULL` limpa. `CASCADE` em `pedidos → clientes` apaga o histórico financeiro do cliente, e quem descobre costuma ser a contabilidade. `DEFERRABLE INITIALLY DEFERRED` adia a verificação para o `COMMIT`.

`CHECK` aceita qualquer expressão sobre a própria linha (`fim > inicio`). Uma função que consulte outra tabela passa pela sintaxe, mas o banco não reavalia a restrição quando a outra tabela muda, e a garantia é falsa. `EXCLUDE` generaliza o `UNIQUE`, proibindo que duas linhas satisfaçam um operador ao mesmo tempo, como reservas sobrepostas:

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- permite '=' em bigint num índice GiST

CREATE TABLE reservas (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sala_id  bigint NOT NULL,
    periodo  tstzrange NOT NULL,
    EXCLUDE USING gist (sala_id WITH =, periodo WITH &&)
);
```

```text
loja=> INSERT INTO reservas (sala_id, periodo)
       VALUES (1, '[2026-03-10 14:00, 2026-03-10 15:00)');
ERROR:  conflicting key value violates exclusion constraint "reservas_sala_id_periodo_excl"
DETAIL:  Key (sala_id, periodo)=(1, ["2026-03-10 14:00:00-03","2026-03-10 15:00:00-03")) conflicts with existing key (sala_id, periodo)=(1, ["2026-03-10 13:30:00-03","2026-03-10 14:30:00-03")).
```

O intervalo semiaberto `[início, fim)` deixa uma reserva terminar às 14h e a seguinte começar às 14h; fechado, as duas disputariam o mesmo instante, e a sala de reunião ganharia mais um motivo para ser disputada.

## Propriedades e custos das chaves

| Chave | Tamanho | Geração | Inserção na B-tree | Expõe informação | Muda? |
|-------|---------|---------|--------------------|------------------|-------|
| Natural (e-mail, CPF) | Variável | Domínio | Depende do valor | O próprio dado | Quando o domínio quiser |
| `integer` identity | 4 bytes | No banco, 1 por `nextval` | No fim do índice | Volume e ordem de criação | Não; esgota em 2,1 bi |
| `bigint` identity | 8 bytes | No banco | No fim do índice | Volume e ordem de criação | Não |
| UUIDv4 | 16 bytes | Em qualquer lugar | Página aleatória | Nada | Não |
| UUIDv7 | 16 bytes | Em qualquer lugar | Perto do fim do índice | Momento da criação | Não |

O `bigint` exige ir ao banco para obter o id, e bancos independentes colidem ao mesclar dados. Os UUIDs resolvem isso com o dobro de bytes em cada índice e chave estrangeira. O Snowflake (Twitter, 2010) fica no meio: 64 bits com 41 de milissegundos, 10 de máquina e 12 de sequência, desde que cada gerador tenha id único e o relógio não ande para trás.

Restrições custam microssegundos por linha (a chave estrangeira consulta a referenciada; cada `UNIQUE` mantém um índice). A alternativa custa reuniões para descobrir de onde veio o `quase pago`.

## Armadilhas e casos reais

> **Armadilha:** o PostgreSQL não cria índice na coluna que referencia. Sem `pedidos_cliente_id_idx`, apagar um cliente varre `pedidos` inteira para conferir dependentes, e um expurgo de 10 mil clientes inativos vira 10 mil varreduras sequenciais.

> **Armadilha:** por padrão, dois `NULL` são distintos, e `UNIQUE (cpf)` aceita infinitos nulos; para "no máximo um", há `UNIQUE NULLS NOT DISTINCT` (PostgreSQL 15). No sentido oposto, o pesquisador Joseph Tartaro contou na DEF CON 27 (2019) que registrou na Califórnia a placa `NULL` e passou a receber multas de carros sem placa identificada no sistema.

> **Na vida real:** em novembro de 2018, o Basecamp 3 ficou somente leitura por horas porque a chave primária de 32 bits da tabela de eventos chegou a 2.147.483.647. Migrar para 64 bits reescreve a tabela inteira (o capítulo 12 trata de mudanças assim sem downtime), e comparar o `last_value` das sequências com o máximo do tipo custa uma linha de SQL.

> **Armadilha:** `ADD CONSTRAINT` numa tabela grande valida todas as linhas, e a primeira inválida aborta tudo depois de minutos de varredura. `NOT VALID` seguido de `VALIDATE CONSTRAINT` separa as duas coisas, com lock mais leve na validação.

A tabela `pedidos_v2_final`, aliás, continua em produção. Hoje ela tem 51 colunas e uma view chamada `pedidos_v2_final_corrigida`.

## Resumo

- Chave candidata é a superchave mínima; a primária é a candidata escolhida para ser referenciada, e as outras merecem `UNIQUE`.
- Chave natural evita `JOIN`, mas precisa ser única, obrigatória e imutável, e o domínio costuma mudar de ideia.
- `bigint GENERATED ALWAYS AS IDENTITY` usa uma sequência não transacional: sem espera entre transações, com buracos normais. `integer` esgota em 2.147.483.647.
- UUIDv4 espalha inserções pela B-tree; UUIDv7 (RFC 9562) mantém a ordem e expõe o momento da criação.
- Dependência funcional `X → Y`: mesmo `X`, mesmo `Y`. 2FN elimina dependência parcial da chave; 3FN, dependência transitiva; BCNF exige que todo determinante seja superchave, às vezes ao custo de perder uma dependência.
- Anomalias de atualização, inserção e exclusão vêm de uma linha com mais de um fato.
- Desnormalizar cria uma cópia que toda escrita precisa manter; o mecanismo (aplicação, trigger, coluna gerada, view materializada, CDC) define a consistência e o custo. Preço de venda no item do pedido é fato histórico.
- Restrições no banco (`NOT NULL`, `UNIQUE`, `FOREIGN KEY`, `CHECK`, `EXCLUDE`) valem para todo caminho de escrita e resolvem a corrida do check-then-act.

## Referências

- E. F. Codd, "A Relational Model of Data for Large Shared Data Banks", *Communications of the ACM* 13(6), 1970: https://dl.acm.org/doi/10.1145/362384.362685
- William Kent, "A Simple Guide to Five Normal Forms in Relational Database Theory", *Communications of the ACM* 26(2), 1983.
- RFC 9562, Universally Unique IDentifiers (UUIDs): https://www.rfc-editor.org/rfc/rfc9562
- PostgreSQL, Constraints: https://www.postgresql.org/docs/current/ddl-constraints.html
- PostgreSQL, CREATE SEQUENCE: https://www.postgresql.org/docs/current/sql-createsequence.html
- PostgreSQL, UUID Functions: https://www.postgresql.org/docs/current/functions-uuid.html
- PostgreSQL, Generated Columns: https://www.postgresql.org/docs/current/ddl-generated-columns.html
- PostgreSQL, Materialized Views: https://www.postgresql.org/docs/current/rules-materializedviews.html
- PostgreSQL, btree_gist: https://www.postgresql.org/docs/current/btree-gist.html
- Python, módulo `uuid`: https://docs.python.org/3/library/uuid.html
- Twitter, Snowflake (repositório arquivado): https://github.com/twitter-archive/snowflake
- Joseph Tartaro, palestra sobre a placa `NULL` na DEF CON 27 (2019).
- Basecamp, relato público da indisponibilidade de novembro de 2018 no Basecamp 3 (limite de inteiro de 32 bits).
