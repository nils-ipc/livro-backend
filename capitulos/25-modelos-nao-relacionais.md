# Modelos não relacionais

O Carlos tinha razão: a consulta dele termina. Termina aos 8 segundos, quando o deadline da autorização (capítulo 15) cancela a coitada, e termina três vezes por segundo, porque estava ligada em 5% das autorizações de cartão por uma feature flag chamada `sinal_anel_beta`.

O Vigia lançou um `Avaliar` (capítulo 12) que aceita "sinais" calculados pela Lastro, que vê 41 marketplaces: tentativas do cartão em 10 minutos, cartões distintos por dispositivo, ligação do comprador com um anel que já tomou chargeback. O Carlos criou `grafo_de_fraude (de, para)` no primário do ledger, com arestas sem tipo entre compradores, cartões, dispositivos e IPs, e um `WITH RECURSIVE` de até quatro saltos.

Numa quarta às 15h20, no pico de 60 autorizações por segundo da campanha de aniversário do Bazar, um comprador entrou pelo IP de um CGNAT de operadora móvel, o NAT do capítulo 8 em escala industrial, compartilhado por 11 mil celulares. Do comprador ao IP, do IP a 11 mil contas, delas aos cartões, dos cartões aos dispositivos: 40 milhões de caminhos, 30 GB de arquivos temporários. Cada consulta segurava uma das 2 conexões do pool do worker (capítulo 14) por 8 segundos. Lei de Little: 3 por segundo × 8 s = 24 conexões, contra 18 no total. Às 15h22 o Pix parou de confirmar pagamento; às 15h23 o Bazar abriu chamado "URGENTE!!!!" com o corpo "vocês estão investigando a gente?".

Contadores em milissegundos, um grafo e agregações sobre anos de dados: qual modelo de dados responde cada pergunta, e por que o ledger fica exatamente onde está?

## O padrão de acesso escolhe o modelo, nunca o contrário

O modelo relacional começa pelas entidades. Você normaliza (capítulo 1), cria as tabelas, escreve as consultas depois, e o planejador (capítulo 6) responde qualquer pergunta que o SQL expresse, inclusive as imprevistas. O preço são junções na leitura e um único formato de armazenamento, linhas, para tudo.

Os não relacionais invertem: primeiro as perguntas, com frequência e latência, e os dados gravados já no formato da resposta. Pergunta fora da lista fica entre cara e impossível. A modelagem atende o relatório que o gerente pediu e quebra no que ele vai pedir depois.

Cada família abaixo vem com modelo, operações, garantias e o que não faz, que é a parte que o vendedor do banco esquece.

### Chave-valor

Um `dict` do Python distribuído: chave opaca, valor, e operações de ler, gravar e apagar por chave em tempo constante. "Todas as chaves cujo valor passa de 100" exige varrer tudo.

O Redis (ou o Valkey) acrescenta estruturas ao valor, e aí ele fica útil para contar. `INCR` incrementa atomicamente, porque o servidor executa comandos numa thread única. `EXPIRE` faz a chave sumir sozinha. O HyperLogLog conta distintos em no máximo 12 KB por chave, com erro padrão de 0,81%: ótimo para contar cartões, péssimo para contar centavos.

```text
127.0.0.1:6379> INCR sinal:cartao:c9f2:tentativas:202611041520
(integer) 7
127.0.0.1:6379> EXPIRE sinal:cartao:c9f2:tentativas:202611041520 7200
(integer) 1
127.0.0.1:6379> PFADD sinal:disp:a17e:cartoes:2026110415 c9f2 b011 77d3
(integer) 1
127.0.0.1:6379> PFCOUNT sinal:disp:a17e:cartoes:2026110415
(integer) 3
```

Sétima tentativa do mesmo cartão no mesmo minuto. Nem a estagiária da Capinhas compra capinha sete vezes por minuto.

As garantias são a parte mórbida. O Redis guarda tudo em memória e persiste por snapshot (RDB) ou por log de comandos (AOF); com `appendfsync everysec`, uma queda perde até cerca de um segundo de escritas. A replicação é assíncrona: o failover promove uma réplica que pode não ter os últimos incrementos, e o `WAIT` só conta quantas réplicas confirmaram, sem tornar nada linearizável. Chave-valor gerenciado (o Amazon DynamoDB é um exemplo) traz durabilidade replicada e escrita condicional, e cobra em modelagem: toda consulta precisa caber na chave.

Chave-valor não faz consulta por valor, junção nem agregação, e não garante que o contador sobreviva ao failover com o número certo. Contador de fraude errado por três unidades durante 30 segundos é tolerável. Saldo errado por três unidades durante 30 segundos é um processo com o nome do vendedor 42.

### Documento

Cada documento é uma árvore (o MongoDB guarda em BSON, até 16 MB), identificada por chave e consultável por campos internos, com índices secundários. A unidade de modelagem é o agregado (capítulo 21): o que é lido e escrito junto mora junto, embutido. O pedido com seus itens vira um documento, e a tela faz uma leitura em vez de quatro junções.

O schema continua existindo, só que no código que lê ("schema-on-read"), que precisa entender os documentos de 2019, os de 2022 e o que o Carlos gravou "rapidinho" com o campo `vlaor`.

A atomicidade natural é por documento. Transações com vários documentos chegaram no MongoDB 4.0 (2018, replica sets) e 4.2 (sharded), mais caras e com limite de duração. Junções existem (`$lookup`) e são a confissão de que o dado foi modelado para outra pergunta. Documento sofre com muitos-para-muitos e com invariantes que atravessam documentos, como "a soma de todos os lançamentos é zero".

### Colunar, que são duas coisas com o mesmo nome

"Colunar" nomeia duas famílias quase sem nada em comum, e metade das reuniões sobre o tema são duas pessoas concordando sobre coisas diferentes.

A primeira é a **wide-column** (Bigtable, Cassandra, ScyllaDB). A chave de partição escolhe o nó (hash, capítulo 24), e dentro da partição as linhas ficam ordenadas pelas colunas de clustering. A consulta eficiente é "linhas da partição X entre A e B", leitura sequencial num nó só. O armazenamento é uma LSM-tree: a escrita vai para um log e para uma tabela em memória (memtable), despejada em arquivos imutáveis ordenados (SSTables) e fundida em segundo plano (compaction). Escrever é barato, porque nada é reescrito no lugar; ler pode consultar vários SSTables; apagar é gravar uma lápide (*tombstone*). O Cassandra aborta a leitura que encontra mais de 100.000 lápides (`tombstone_failure_threshold`): o banco tem cemitério com lotação máxima. A consistência é escolhida por operação, com quórum (capítulo 23), e conflito se resolve por timestamp, o last-write-wins que o capítulo 20 já autopsiou.

A segunda é o **armazenamento colunar analítico** (ClickHouse, Parquet, DuckDB, data warehouses gerenciados). Continua sendo tabela com SQL; muda o disco. Cada coluna é gravada separada e comprimida: `SELECT avg(valor)` lê só `valor`, e uma coluna de estados com quatro valores repetidos 90 milhões de vezes comprime para quase nada com dicionário e run-length. O ClickHouse ordena a tabela por uma chave e guarda uma entrada de índice a cada 8.192 linhas (`index_granularity`): um BRIN (capítulo 5) que faz academia.

O colunar analítico não busca linha por ID com pressa, não atualiza linha (vira reescrita de bloco ou mutação assíncrona) e não gosta de inserção unitária. Ele quer lotes de milhares de linhas. Inserir uma por vez no ClickHouse é crime contra a compressão.

### Grafo

O grafo de propriedades tem nós e arestas, ambos com tipo e atributos. A pergunta natural é a travessia: "a partir deste nó, siga arestas destes tipos até N saltos". Bancos nativos de grafo (o Neo4j, com a linguagem Cypher, é o exemplo clássico; o Amazon Neptune é um gerenciado) guardam cada nó com ponteiros diretos para suas arestas, a *index-free adjacency*: seguir uma aresta custa um acesso a registro, sem descer B-tree. A travessia custa proporcionalmente ao trecho visitado, independente do tamanho total.

No relacional, cada salto é uma junção, uma descida de índice O(log n). Com 9 milhões de arestas a B-tree tem três níveis, e a diferença por salto é pequena. A diferença grande é de expressão: o banco de grafos escreve "caminho de tamanho variável com tipos alternados" numa linha, e o SQL escreve num `WITH RECURSIVE` que o Carlos fez sem detecção de ciclo.

```sql
WITH RECURSIVE anel(no, saltos) AS (
    SELECT para, 1 FROM grafo_de_fraude WHERE de = 'comprador:91822'
  UNION ALL
    SELECT g.para, a.saltos + 1
    FROM anel a JOIN grafo_de_fraude g ON g.de = a.no
    WHERE a.saltos < 4          -- "termina" (Carlos, 2026)
)
SELECT count(*) FROM anel;
```

O limite de saltos garante o término; não garante que ele aconteça nesta encarnação. O `UNION ALL` revisita o mesmo nó por todos os caminhos, e o primeiro supernó (o IP do CGNAT, com 11 mil vizinhos) multiplica tudo por 11 mil. Desde o PostgreSQL 14, a cláusula `CYCLE` do padrão SQL marca caminhos que repetem nó: resolve o ciclo, ignora o supernó. Banco de grafos sofre igual, porque 11 mil arestas custam 11 mil acessos em qualquer motor. Supernó se trata como dado ruim e sai da travessia.

Grafo vai mal em agregação sobre o conjunto inteiro e em particionamento. Cortar um grafo em shards sem cortar as travessias é NP-difícil, e você tem reunião às 16h.

### Séries temporais

O modelo é (série, instante, valor), e a série é um nome com rótulos (`aprovacoes{marketplace="bazar", metodo="cartao"}`). O acesso é inserção no fim, leitura por janela, agregação por intervalo e descarte por retenção. Bancos de séries temporais (Prometheus, InfluxDB, o TimescaleDB como extensão do PostgreSQL) particionam por tempo (o capítulo 24 no automático), apagam blocos inteiros e fazem *downsampling*: depois de 30 dias, um ponto por minuto vira um por hora.

A compressão aproveita a regularidade. O Gorilla, do Facebook (VLDB 2015), grava o delta do delta dos timestamps (pontos a cada 15 s dão zero, que cabe em um bit) e o XOR de cada valor com o anterior: 1,37 byte por ponto, contra 16 sem compressão.

O limite é a cardinalidade: cada combinação de rótulos é uma série nova, com índice próprio. `cobranca_id` como rótulo cria 25 mil séries por dia, de um ponto cada, e o banco morre com a memória cheia delas. É o jeito mais caro de reinventar uma tabela.

| Modelo | Acesso que faz bem | Consistência típica | O que não faz |
|--------|--------------------|---------------------|---------------|
| Chave-valor | ler, gravar, incrementar por chave; TTL | por chave; réplica assíncrona (Redis) ou configurável | consulta por valor, junção, agregação |
| Documento | ler e gravar o agregado inteiro | atômica por documento; multi-documento mais cara | muitos-para-muitos, invariantes entre documentos |
| Wide-column | faixa ordenada dentro de uma partição; escrita em volume | quórum por operação; last-write-wins | junção, consulta fora da chave, apagar barato |
| Colunar analítico | varrer e agregar poucas colunas de muitas linhas | lotes; sem transação de linha | busca pontual, UPDATE, inserção unitária |
| Grafo | travessia de tamanho variável | depende do motor (o Neo4j é ACID numa instância) | agregação global, sharding |
| Séries temporais | janela de tempo, agregação, retenção | inserção no fim; pontos tardios custam | cardinalidade alta de rótulos |

## Na Lastro: três perguntas, três modelos, um ledger intocado

Primeira decisão: nada disso mora no primário do ledger. O Carlos desligou a flag às 15h24 e pediu para registrar o horário; `grafo_de_fraude` saiu do `pg-ledger-1` às 15h31.

### Contadores: Redis separado, com baldes de minuto

O orçamento do capítulo 14 dá 20 ms para validação e primeira transação, e os sinais cabem ali ou não existem. São oito contadores por autorização: tentativas e valor por cartão em 10 minutos, 1 hora e 24 horas, mais cartões e contas distintos por dispositivo em 24 horas, a 60 autorizações por segundo no pico. O cartão entra por um identificador derivado, nunca pelo número (o dado de cartão é assunto do capítulo 33).

| Alternativa | Latência por autorização | Carga no ledger | Garantia |
|-------------|--------------------------|-----------------|----------|
| `count`/`sum` em `cobrancas` no primário | 5–30 ms, 8 consultas | +480 consultas/s no pico | exata |
| Mesma consulta na réplica síncrona | 5–30 ms + lag | nenhuma no primário | exata com atraso |
| Redis, baldes por minuto/hora | ~1 ms, 1 ida e volta em pipeline | nenhuma | aproximada; perde segundos no failover |

A Lastro escolheu o Redis porque o sinal precisa de ~1 ms e tolera erro pequeno: o Vigia decide com dezenas de variáveis, e três tentativas a menos durante um failover mudam uma probabilidade, enquanto o saldo continua intocado no ledger. Os contadores ficam numa instância **separada** do cache do painel (capítulo 22), `redis-sinais`, com `noeviction`: contador de fraude despejado por LRU para abrir espaço para resumo de painel é a pior troca do mercado. Toda chave tem TTL, e a memória fica limitada pelo próprio esquema, cerca de 2 GB para 24 horas de baldes.

A janela deslizante é aproximada por baldes: 1 hora soma 60 baldes de minuto (um `MGET`), 24 horas soma 24 baldes de hora, e distintos usam HyperLogLog por hora, unidos por `PFCOUNT` com várias chaves. Leitura e incremento da tentativa atual vão no mesmo pipeline, antes do Vigia, e contam as tentativas recusadas, que são justamente as que importam.

Se o `redis-sinais` cair, os sinais vão ausentes no `Avaliar` (campos `optional`, capítulo 12) e a regra local do capítulo 15 segue valendo, com o limite por cartão em 24 horas lido no PostgreSQL. A degradação de lá previa o Vigia fora; agora prevê o Vigia cego de um olho.

### O anel: grafo fora do caminho da autorização

O grafo entrou por um requisito exploratório: a analista de risco, contratada depois do chargeback do capítulo 21, pergunta coisas como "contas a até 4 saltos que compartilham dispositivo ou conta de repasse com quem tomou chargeback", com tipos de aresta novos toda semana. São ~2 milhões de nós (compradores, vendedores, cartões, dispositivos, contas de repasse) e 9 milhões de arestas.

O fluxo:

```text
cobrancas.eventos ─┐
repasses.eventos ──┼─> consumidor grafo-anel ─> banco de grafos (nós e arestas tipados)
cadastro vendedor ─┘                                   │
                                                       │ job a cada 5 min:
                                                       │ componentes ligados, sem supernós
                                                       v
                                redis-sinais: sinal:anel:{conta} = pontuação, TTL 1 h
                                                       │
autorização ── 1 GET ──────────────────────────────────┘ (~1 ms)
```

A autorização nunca faz travessia: lê uma pontuação pronta por chave, e o grafo responde com paciência de analista. Nós com mais de 500 arestas (o CGNAT, o Wi-Fi do shopping, o celular de demonstração da loja) viram atributo e saem da travessia. O supernó deixou de ser vizinho e virou fofoca.

O custo é mais um sistema para operar e até 5 minutos de atraso na pontuação. Uma tabela de arestas tipadas no `pg-notificacoes`, com `CYCLE` e corte de supernó, seria a escolha certa se as perguntas fossem fixas e de até dois saltos, sem sistema novo. A Lastro escolheu o banco de grafos porque as perguntas mudam toda semana e a analista escreve Cypher sem pedir PR a ninguém.

### Agregações: colunar alimentado pelo log

A terceira pergunta é o relatório semanal de risco: taxa de chargeback por vendedor, faixa de valor, BIN e hora do dia, sobre dois anos de cobranças. A `pg-ledger-relat` (capítulo 23) leva 90 segundos lendo linhas inteiras para usar cinco colunas. Um banco colunar analítico (o ClickHouse é um exemplo; Parquet num armazenamento de objetos com um motor de consulta também serve) recebe `cobrancas.eventos` em lotes de 10 segundos, ordenados por `(marketplace_id, criado_em)`, e responde em menos de 1 segundo. Como UPDATE ali é caro, o chargeback vira linha nova e a consulta pega a versão mais recente de cada cobrança: o event sourcing do capítulo 21, agora num banco que gosta dele.

Séries temporais ficam para o capítulo 38, com as métricas. O gerente de produto registrou a ausência delas como "atraso no roadmap".

### Por que o ledger continua relacional

O ledger precisa exatamente do que essas famílias abrem mão: transação atômica sobre várias linhas (o split do capítulo 3), restrições no banco (soma zero, FK, o tabelião), serializable para débitos e consulta ad hoc para a conciliação. Num banco de documentos, a transação com seus lançamentos caberia num documento atômico, mas o saldo soma lançamentos de milhões de documentos, e a verificação do capítulo 2 vira transação multi-documento. No relacional, "não perder um centavo" é restrição verificada pelo banco; fora dele, vira esperança da aplicação.

## Armadilhas e casos reais

> **Armadilha:** usar o Redis do cache como banco de contadores. Com `allkeys-lru` (capítulo 22), ele apaga contadores sob pressão de memória, sem erro, e o cartão que tentou 40 vezes aparece com 3. O ataque passou porque o resumo do painel do Hornero precisava de espaço.

> **Na vida real:** o Discord guardava mensagens no MongoDB e migrou para o Cassandra em 2017, quando dados e índices deixaram de caber em memória. A chave de partição virou `(channel_id, bucket)`, com o bucket como janela fixa de tempo, para nenhuma partição crescer sem limite. A lição do capítulo 24, num banco sem `ATTACH PARTITION`.

> **Na vida real:** a análise do Jepsen sobre o MongoDB 4.2.6 (2020) encontrou anomalias nas transações multi-documento, inclusive com os níveis mais fortes de read concern e write concern. Garantia se lê na especificação e se confere em teste; a página de marketing segue um modelo de consistência próprio, chamado otimismo.

> **Armadilha:** HyperLogLog onde se exige número exato. Erro de 0,81% em cartões distintos por dispositivo é ruído; em contagem de cobranças para faturar tarifa, é o financeiro processando o Redis.

## Resumo

- Modelagem não relacional parte do padrão de acesso; pergunta não prevista fica cara.
- Chave-valor: operações por chave, contadores atômicos, TTL; o Redis perde escritas no failover.
- Documento: agregado embutido, atomicidade por documento; sofre com muitos-para-muitos.
- Wide-column: partição, clustering, LSM-tree, lápides, quórum. Colunar analítico: colunas comprimidas, varredura, lotes.
- Grafo: travessia custa o trecho visitado; supernó é problema em qualquer motor.
- Séries temporais: partição por tempo, retenção, downsampling; o limite é a cardinalidade.
- Dinheiro precisa de transação entre linhas e restrição no banco: fica no relacional.

## A Lastro agora

Os sinais do Vigia saem do `redis-sinais` (separado, `noeviction`, TTL em tudo) em ~1 ms: oito contadores em baldes e HyperLogLog para distintos. O grafo mora num banco de grafos alimentado pelos tópicos, sem supernós, e só a pontuação de anel chega à autorização, a cada 5 minutos. O relatório de risco roda num colunar em menos de 1 segundo. O ledger, o tabelião e a planilha do financeiro continuam relacionais, cada um à sua maneira.

A consulta do Carlos foi preservada num comentário com a anotação "termina", e ele segue tecnicamente correto, que é o tipo de correto que derruba o Pix. A Lastro agora é um monólito que fala com dois PostgreSQL, dois Redis, um log, um banco de grafos e um colunar. O deploy da semana que vem é o relatório novo de risco, que sobe no mesmo processo que autoriza cartão. O que pode dar errado num deploy de relatório?

## Referências

- Redis, documentação de persistência (RDB e AOF): https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/
- Redis, HyperLogLog: https://redis.io/docs/latest/develop/data-types/probabilistic/hyperloglogs/
- PostgreSQL 16, `WITH` queries (`SEARCH` e `CYCLE`): https://www.postgresql.org/docs/16/queries-with.html
- MongoDB, Transactions: https://www.mongodb.com/docs/manual/core/transactions/
- Chang et al., "Bigtable: A Distributed Storage System for Structured Data", OSDI 2006: https://research.google/pubs/bigtable-a-distributed-storage-system-for-structured-data/
- O'Neil et al., "The Log-Structured Merge-Tree (LSM-Tree)", Acta Informatica, 1996: https://doi.org/10.1007/s002360050048
- Pelkonen et al., "Gorilla: A Fast, Scalable, In-Memory Time Series Database", VLDB 2015: https://www.vldb.org/pvldb/vol8/p1816-teller.pdf
- ClickHouse, MergeTree: https://clickhouse.com/docs/engines/table-engines/mergetree-family/mergetree
- Discord, "How Discord Stores Billions of Messages", 2017: https://discord.com/blog/how-discord-stores-billions-of-messages
- Jepsen, "MongoDB 4.2.6", 2020: https://jepsen.io/analyses/mongodb-4.2.6
