# Modelagem relacional

## Um centavo, um sábado e um financeiro que nunca mais foi o mesmo

O financeiro da Lastro achou uma divergência de R$ 0,01 às 23h de um sábado, e desde então ele fala desse centavo com a voz baixa de quem voltou de uma guerra.

Contexto rápido, porque hoje é o seu primeiro dia. A Lastro é uma plataforma de pagamentos para marketplaces: o marketplace cria uma **cobrança** na API, o comprador paga por Pix ou cartão, a Lastro divide o valor entre marketplace e vendedores (o *split*), desconta a tarifa, guarda os saldos e repassa o dinheiro. Um cliente, o Bazar Bem-te-vi: 1.200 vendedores, umas 3.000 cobranças por dia. E você, o novo líder técnico do backend, contratado no dia em que o fundador admitiu que "a gente escala depois" tem data de vencimento.

O fundador escreveu a primeira versão num fim de semana, num servidor chamado `temp-01`. O nome diz "temporário". O *uptime* diz dois anos e três meses.

O saldo de cada vendedor mora numa coluna `saldo double precision`. A cada pagamento, `UPDATE vendedores SET saldo = saldo + 87.01 WHERE id = 42`. A cada saque, o mesmo com o sinal trocado. Não existe histórico, existe um número que muda.

Todo mês, o financeiro compara esses saldos com a planilha de conciliação, a fonte oficial da verdade da Lastro, digam o que disserem. Neste mês, 37 vendedores divergem: 34 por um centavo, ao acaso; três por valores como R$ 412,30, uma venda somada duas vezes por um *retry*. Provar é impossível: a coluna tem a memória de um peixinho dourado e a responsabilidade de um banco.

```text
Financeiro: Por que o vendedor 42 tem R$ 412,30 a mais?
Banco:      O saldo dele é 9871.440000000001.
Financeiro: E de onde veio isso?
Banco:      Eu não guardo "de onde". Eu guardo float.
Fundador:   No meu tempo a gente arredondava na tela e pronto.
Carlos:     (já está editando o saldo na mão, em produção)
```

A pergunta deste capítulo: como guardar dinheiro num banco relacional de modo que todo centavo tenha origem conhecida, o saldo seja incapaz de discordar da própria história e o banco recuse dado errado, inclusive quando quem tenta gravar é o Carlos?

## Ponto flutuante, ou como errar com dezessete dígitos de convicção

O `double precision` do PostgreSQL e o `float` do Python são o formato *binary64* da IEEE 754: 1 bit de sinal, 11 de expoente e 52 de fração, 53 bits de precisão efetiva, todo valor na forma m × 2^e. Um decimal só tem representação exata se for soma finita de potências de 2. O 0,25 tem. O 0,1, em binário, é a dízima periódica 0,000110011001100..., e o hardware guarda o binary64 mais próximo. Quase todo valor com centavos nasce errado. Pouquinho, mas nasce.

```python
>>> 0.1 + 0.2
0.30000000000000004
>>> sum([0.1] * 10)
0.9999999999999999
>>> round(2.675, 2)
2.67
```

O último é o mais cruel: o valor guardado é 2,67499999999999982236..., um número que você nunca digitou.

O erro por operação é minúsculo, mas se acumula ao longo de dois anos de somas. E a adição em ponto flutuante perde a associatividade: (a + b) + c pode diferir de a + (b + c). O `SUM` sobre `float8` depende da ordem das linhas, que depende do plano; com agregação paralela, a mesma consulta sobre os mesmos dados pode variar nas últimas casas. O saldo passa a depender de quantos *workers* acordaram de bom humor.

A documentação do PostgreSQL manda usar `numeric` para valores monetários. O ponto flutuante foi desenhado para física e computação gráfica, onde errar na décima sexta casa é ruído e ninguém processa ninguém por um pixel torto.

As alternativas exatas:

- **Inteiro em unidades mínimas**: centavos num `BIGINT`. Oito bytes, aritmética exata, máximo de 9.223.372.036.854.775.807 centavos (uns R$ 92 quatrilhões, o bastante até para o fundador pedir aumento). A escala fica implícita: a coluna diz `10000` e só a convenção diz que isso é R$ 100,00.
- **`NUMERIC(p, s)`**: decimal exato, aritmética em base 10 feita em software. Ocupa 2 bytes por grupo de 4 dígitos mais 3 a 8 de cabeçalho, e cada soma custa bem mais que uma soma de inteiros.

```sql
SELECT 0.1::float8 + 0.2::float8 AS flutuante,
       0.1::numeric + 0.2::numeric AS decimal,
       10 + 20 AS centavos;
--       flutuante      | decimal | centavos
-- ---------------------+---------+----------
--  0.30000000000000004 |     0.3 |       30
```

No Python, o par exato do `numeric` é o `decimal.Decimal`, que o psycopg 3 e o SQLAlchemy devolvem por padrão. O `float` aparece quando alguém declara a coluna como `Float` "porque o tutorial fazia assim". O tutorial não tinha um financeiro.

## Arredondamento: o centavo órfão precisa de um tutor legal

Tipo exato nenhum salva você da divisão. R$ 100,00 entre três vendedores dão R$ 33,33 para cada um, a soma dá R$ 99,99 e um centavo fica órfão, vagando pelo sistema até ser adotado pela planilha do financeiro.

**Meio para cima** (*half-up*) leva 2,345 a 2,35; todo empate sobe, e milhões de operações acumulam viés. **Meio para o par** (*half-even*, o "arredondamento bancário") leva 2,345 a 2,34 e 2,355 a 2,36, e o viés some em média. **Truncamento** descarta as casas, com viés sempre na mesma direção; adiante você vê o que isso fez com uma bolsa de valores. E o `round()` do Python usa meio para o par, enquanto o `round(numeric)` do PostgreSQL arredonda empates para longe do zero: dois componentes, duas regras, um centavo por empate.

A regra para dinheiro: calcular exato, arredondar uma única vez, num ponto e com regra definidos, e fechar por diferença: a última parcela recebe o total menos as outras, e a soma bate por construção. Em rateios maiores, o método dos maiores restos dá os centavos que sobram a quem mais perdeu no arredondamento. Arredondar cada parte e torcer para a soma bater é uma loteria de centavos em que o único apostador é o financeiro e o prêmio é um sábado à noite.

## Partidas dobradas: dinheiro não nasce nem morre, só muda de conta

O ledger de partidas dobradas foi descrito por Luca Pacioli em 1494. É o padrão mais antigo deste livro: mais de cinco séculos sem migração de schema, e nenhum incidente atribuído a ele, porque o incidente sempre é atribuído a quem implementou.

O modelo tem três entidades. A **conta** é onde dinheiro fica: o disponível do vendedor 42, a comissão do Bazar, a receita de tarifas, o banco liquidante. A **transação** é um evento de negócio (pagamento, estorno, saque). O **lançamento** movimenta um valor com sinal numa conta, dentro de uma transação.

E três invariantes. Toda transação tem pelo menos dois lançamentos, com soma zero. Lançamentos são imutáveis: entram por `INSERT` e nunca saem por `UPDATE` ou `DELETE`. O saldo de uma conta é a soma dos lançamentos dela. Consequência global: a soma de todos os lançamentos do sistema é zero, sempre, e um centavo que surge do nada vira uma consulta em vez de um sábado à noite.

Convenção de sinal: positivo é débito, negativo é crédito. Contas de ativo (o banco liquidante) ficam positivas; de passivo (o que a Lastro deve a vendedores e marketplace) e de receita, negativas. Sim, no razão o vendedor mais rico do Bazar tem o saldo mais negativo da empresa. Contabilidade é a única área em que dever dinheiro a alguém se chama crédito e ninguém acha estranho. O extrato do vendedor inverte o sinal, por caridade.

Um pagamento Pix de R$ 100,00 no Bazar, com comissão de 12% e tarifa Pix da Lastro de 0,99% descontada do vendedor:

```text
Transação 7781 · pagamento Pix · cobrança 01J9ZB4Q...
conta                            valor (centavos)
banco_liquidante                          +10000
vendedor_42:disponivel                     -8701
bazar:comissao                             -1200
lastro:receita_tarifas                       -99
                                   soma:       0
```

A parcela do vendedor foi fechada por diferença (10000 − 1200 − 99), e a soma zero vem de graça. Um estorno vira uma transação nova, com cada lançamento invertido e referência à original. O passado da Lastro fica imutável, igual ao do Carlos, só que documentado.

```text
Carlos: Esse lançamento tá errado. Vou dar um UPDATE.
Ledger: Aqui não tem UPDATE.
Carlos: DELETE, então.
Ledger: Também não.
Carlos: E como eu conserto?
Ledger: Com um lançamento novo que desfaz o antigo. Com data e motivo.
Carlos: Isso é praticamente uma confissão assinada.
Ledger: Agora você entendeu o modelo.
```

De brinde, o saldo de qualquer instante passado vira um `SUM` com filtro de data, e um pagamento duplicado aparece como duas transações da mesma cobrança.

## Chaves, ou quem é quem quando todo mundo tem dois documentos

Uma **chave candidata** é um conjunto mínimo de atributos que identifica uma linha; a primária é a escolhida, as demais viram `UNIQUE`.

Uma **chave natural** tem significado fora do banco: CNPJ, CPF, o EndToEndId do Pix. Como `UNIQUE`, ela impede duplicar a coisa real. Como chave primária, ela amarra o seu schema às regras de outra pessoa. A Instrução Normativa RFB nº 2.229, de 2024, deu letras aos CNPJs emitidos a partir de julho de 2026. Todo sistema que usou CNPJ em `BIGINT` como chave em quarenta tabelas ganhou, por decreto, uma migração de quarenta tabelas.

Uma **chave substituta** é gerada pelo banco, sem significado, e nunca muda. Duas famílias:

- **Sequência** (`GENERATED ALWAYS AS IDENTITY`): 8 bytes, crescente, cada inserção no fim do índice B-tree (capítulo 5). O `nextval` nunca é desfeito por *rollback*, então há buracos, e o ID exposto conta segredos. Se a cobrança de hoje é a 310.200 e a de amanhã é a 313.180, qualquer concorrente sabe que você fez 2.980 cobranças no intervalo, sem nem precisar subornar o Carlos.
- **UUID**: 128 bits, gerado em qualquer lugar sem coordenação. A versão 4 tem 122 bits aleatórios, e cada inserção cai numa página aleatória do índice: mais páginas sujas, mais escrita no WAL. A versão 7 (RFC 9562) começa com 48 bits de *timestamp* Unix em milissegundos, então as inserções voltam para o fim do índice, ao custo de revelar o instante de criação. O PostgreSQL ganhou `uuidv7()` na versão 18.

| Entidade | Chave primária | Outras chaves | Motivo |
|----------|----------------|---------------|--------|
| Contas, transações, lançamentos | `BIGINT` identity | Nenhuma | Internas; maior volume, 8 bytes por entrada de índice e FK |
| Cobranças | UUIDv7, também o ID público | Nenhuma por ora | Exposto na API sem revelar volume; ordenado por tempo |
| Marketplaces, vendedores | `BIGINT` identity | CNPJ/CPF `UNIQUE`, em `TEXT` | Documento muda de formato |
| Transações Pix | Ligadas à cobrança | EndToEndId `UNIQUE` | Mesmo Pix registrado uma vez só (capítulo 16) |

UUID em tudo seria a escolha certa com vários bancos ou clientes *offline* gerando IDs sem coordenação. Chave natural primária serve quando o valor é estável e seu, o que exclui qualquer coisa emitida pela Receita Federal.

## Formas normais: cada fato num lugar só, que nem segredo de família

Quando o mesmo fato mora em vários lugares, aparecem as **anomalias**: **de atualização** (muda uma cópia, as outras ficam velhas), **de inserção** (só dá para registrar um fato inventando outro) e **de exclusão** (apagar um fato leva junto outro). A coluna `saldo` do `temp-01` é a anomalia de atualização em estado puro: a Lastro guardava a cópia e jogava fora o original.

As formas normais são condições sobre **dependências funcionais**: X → Y quando o valor de X determina o valor de Y.

- **1FN**: atributos atômicos, sem grupos repetidos. Uma coluna `recebedores` com `42:8701;77:1200` viola: é um CSV escondido numa célula, esperando um vendedor com ponto e vírgula no nome.
- **2FN**: 1FN, e nenhum atributo fora da chave depende de só parte de uma chave composta. Com chave (`cobranca_id`, `vendedor_id`), uma coluna `vendedor_nome` viola. O vendedor muda o nome fantasia e 40 mil linhas mentem.
- **3FN**: 2FN, e nenhum atributo fora da chave depende de outro atributo fora da chave. Uma `tarifa_pix_do_marketplace` na tabela de cobranças viola: depende do marketplace.
- **BCNF** (Boyce-Codd): para toda dependência não trivial X → Y, X é superchave. É mais estrita que a 3FN.

Sutileza que vale dinheiro: a tarifa *contratada* depende do marketplace, mas a tarifa *aplicada* no dia do pagamento é um fato da cobrança e fica gravada nela. O contrato muda em março; a cobrança de fevereiro continua tendo pago 0,99%. Valor histórico copiado registra outro fato.

3FN e BCNF divergem com chaves candidatas sobrepostas. Na tabela (`marketplace`, `bandeira`, `contrato`), {`marketplace`, `bandeira`} → `contrato` e `contrato` → `bandeira`. Todo atributo pertence a uma chave candidata, então está na 3FN; `contrato` falha em ser superchave, então viola a BCNF, e "o contrato C é da Visa" se repete por marketplace. Decompor em (`contrato`, `bandeira`) e (`marketplace`, `contrato`) elimina a repetição e perde a garantia de um contrato por bandeira por marketplace, que deixa de caber num `UNIQUE`. A 3FN sempre admite decomposição que preserva as dependências; a BCNF nem sempre. Ela entrega a pureza prometida e cobra em restrição perdida, igual consultor por hora.

## Desnormalização: toda cópia é uma promessa, e promessa se quebra

Desnormalizar é guardar de propósito um dado derivável, para ler mais rápido. A conta chega na escrita: cada mudança na origem atualiza a cópia na mesma transação, ou um processo corrige a diferença depois. Cópia sem esse mecanismo é a coluna `saldo` do `temp-01` com outro nome e a mesma ficha criminal.

| Estratégia | Custo da leitura | Custo da escrita | Risco |
|------------|------------------|------------------|-------|
| Saldo derivado (`SUM`) | Todos os lançamentos da conta | Só `INSERT` | Lento com volume (capítulo 5) |
| Materializado na mesma transação | Uma linha | `INSERT` + `UPDATE` da conta | Contenção na linha (capítulo 4); bug grava cópia errada |
| Projeção assíncrona | Uma linha | `INSERT` + consumidor | Leitura atrasada (capítulos 19 e 21) |

A Lastro fica com o saldo derivado. Quem decide é a conciliação: o saldo precisa ser explicável lançamento por lançamento, e um valor derivado é incapaz de divergir do histórico porque ele é o histórico somado. O volume permite: uns 12 mil lançamentos por dia, e a conta mais movimentada, a comissão do Bazar, recebe cerca de 1,1 milhão por ano. O materializado vira a escolha certa quando ler o saldo vira gargalo mesmo com índices, ou quando uma verificação precisa travar o saldo numa linha só. Mesmo aí ele é cache: se discordar do `SUM`, o `SUM` ganha e a cópia vai para o paredão.

## Restrições: o banco como último adulto na sala

Regra validada só no Python protege só as escritas que passam pelo Python. Na Lastro, escrevem no banco a API, o job `repasse_final_v2_agora_vai.py`, as migrações e o Carlos, com o `psql` aberto e a confiança de quem nunca foi demitido. Restrição declarada no banco vale para os quatro.

`NOT NULL` e `CHECK` validam uma linha por vez (`valor <> 0`). Chaves estrangeiras com `ON DELETE RESTRICT` impedem lançamento órfão e conta com histórico apagada. `UNIQUE` barra o EndToEndId repetido.

A soma zero envolve várias linhas, e o `CHECK` enxerga uma só. Uma saída é um *constraint trigger* `DEFERRABLE INITIALLY DEFERRED`: no `COMMIT`, soma os lançamentos de cada transação tocada e, se a soma der diferente de zero, levanta erro e desfaz tudo, ao custo de uma consulta a mais por *commit*. A outra é uma função SQL de escrita que valida antes de inserir, e o Carlos vai achar o caminho que não passa por ela.

A imutabilidade usa duas camadas: o papel (*role*) da aplicação recebe só `INSERT` e `SELECT` nos lançamentos, e um *trigger* `BEFORE UPDATE OR DELETE` recusa a operação até para o dono da tabela. Contra um superusuário, que pode desligar *triggers*, nada resolve; o fundador tem esse acesso, e o capítulo 31 trata de quem pode o quê.

```text
lastro=> INSERT INTO lancamentos (transacao_id, conta_id, valor) VALUES (7781, 42, 0);
ERROR:  new row for relation "lancamentos" violates check constraint "lancamentos_valor_check"
lastro=> UPDATE lancamentos SET valor = -870100 WHERE id = 991203;
ERROR:  lancamentos: append-only, registre um estorno
```

A primeira mensagem é do PostgreSQL; a segunda, do *trigger*. O `-870100` é o Carlos "corrigindo" R$ 87,01 com dois zeros a mais, e o banco salvou a Lastro de dar R$ 8.701,00 de presente a um vendedor.

## Armadilhas e casos reais

> **Na vida real:** a Bolsa de Valores de Vancouver lançou um índice em janeiro de 1982, valendo 1.000, recalculado a cada negociação e truncado em três casas, com o valor truncado alimentando o cálculo seguinte. Em novembro de 1983 ele fechou uma sexta em 524,811; recalculado corretamente no fim de semana, abriu em 1.098,892. O mercado dobrou sem uma única negociação, a melhor semana da história para quem não fez nada.

> **Armadilha:** a RFC 8259 avisa que implementações de JSON costumam usar binary64, e o JavaScript usa: acima de 2^53, inteiros perdem precisão (`9007199254740993` chega como `9007199254740992`), e `87.01` cai no ponto flutuante do outro lado. Valor monetário trafega como inteiro em centavos ou string, senão o `Number` do JavaScript repete o erro do `temp-01` no navegador do comprador.

> **Armadilha:** `NUMERIC(12, 2)` recebe `10.005` e grava `10.01`, sem aviso. Arredondamento silencioso: a gentileza que o financeiro chama de fraude.

> **Armadilha:** sequência tem buraco. O auditor pergunta pelo lançamento 1.042, e a resposta honesta é "morreu num *rollback* de terça-feira".

## Resumo

- Ponto flutuante erra decimais, acumula o erro e perde a associatividade; dinheiro vai em inteiro de unidades mínimas ou `NUMERIC`.
- Arredondar uma vez, com regra definida, e fechar a última parcela por diferença.
- Ledger: lançamentos imutáveis com soma zero por transação, saldo derivado, estorno como transação nova.
- Chave natural traz regras de fora; sequência delata volume; UUIDv7 ordena por tempo.
- 1FN, 2FN, 3FN e BCNF eliminam anomalias; a BCNF pode perder dependências.
- Desnormalizar é assinar um contrato de manutenção de cópia.
- Restrição no banco vale até para o Carlos.

## A Lastro agora

A coluna `saldo double precision` morreu, e ninguém foi ao velório. O dinheiro da Lastro mora num ledger de partidas dobradas no PostgreSQL: lançamentos em centavos `BIGINT`, soma zero por *constraint trigger* adiado, imutabilidade por privilégio e *trigger*, estorno como transação nova, saldo derivado por `SUM`. Taxas em `NUMERIC` com quatro casas, tarifa arredondada uma vez (meio para o par), parcela do vendedor fechada por diferença, tarifa aplicada gravada na cobrança. Cobranças com UUIDv7 público; o resto com `BIGINT` identity.

Na conciliação seguinte, planilha e ledger bateram até o último centavo, e o financeiro dormiu num sábado pela primeira vez em dois anos. Durou até quarta. Um vendedor com R$ 500,00 de saldo disparou dois saques de R$ 500,00 no mesmo milissegundo, e cada um gerou uma transação perfeita, soma zero, registrada com a precisão de um tabelião. Partida dobrada, saque dobrado, e o Bazar já abriu o chamado: "URGENTE!!!!".

## Referências

- IEEE. *IEEE Standard for Floating-Point Arithmetic* (IEEE 754-2019). <https://standards.ieee.org/ieee/754/6210/>
- GOLDBERG, David. *What Every Computer Scientist Should Know About Floating-Point Arithmetic*. ACM Computing Surveys, 1991. <https://docs.oracle.com/cd/E19957-01/806-3568/ncg_goldberg.html>
- Python. *decimal: Decimal fixed-point and floating-point arithmetic*. <https://docs.python.org/3/library/decimal.html>
- PostgreSQL. *Numeric Types*. <https://www.postgresql.org/docs/current/datatype-numeric.html>
- PostgreSQL. *Mathematical Functions and Operators* (`round`). <https://www.postgresql.org/docs/current/functions-math.html>
- PostgreSQL. *CREATE TRIGGER* (constraint triggers). <https://www.postgresql.org/docs/current/sql-createtrigger.html>
- RFC 9562. *Universally Unique IDentifiers (UUIDs)*. <https://www.rfc-editor.org/rfc/rfc9562>
- RFC 8259. *The JavaScript Object Notation (JSON) Data Interchange Format*. <https://www.rfc-editor.org/rfc/rfc8259>
- CODD, E. F. *A Relational Model of Data for Large Shared Data Banks*. Communications of the ACM, 1970. <https://doi.org/10.1145/362384.362685>
- Receita Federal. Instrução Normativa RFB nº 2.229, de 15 de outubro de 2024 (CNPJ alfanumérico).
- QUINN, Kevin. *Ever Had Problems Rounding Off Figures? This Stock Exchange Has*. The Wall Street Journal, 8 nov. 1983, p. 37 (caso do índice da Bolsa de Vancouver).
