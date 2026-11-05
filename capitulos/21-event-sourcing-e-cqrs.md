# Event sourcing e CQRS

## O comprador tem memória, a Lastro tem amnésia

A pizza do Carlos chegou antes do backup, e isso já diz tudo sobre o plano.

Um comprador do Bazar abriu um *chargeback* contra uma venda de setembro. Chargeback, ou contestação, é a devolução que o comprador pede direto ao emissor do cartão; o adquirente repassa a disputa para a Lastro, que tem um prazo para apresentar provas. No contrato com o adquirente, sete dias corridos. A Lastro gastou dois discutindo o sabor da pizza.

A venda: um notebook de R$ 2.390,00, vendedor Sabiá Eletrônicos. A alegação do comprador: "no dia 14 de setembro, às 15h, o vendedor me prometeu estorno parcial de R$ 400,00 e o estorno nunca apareceu". Para contestar, a Lastro precisa dizer o que existia naquela cobrança às 15h do dia 14. Ela consultou a tabela `cobrancas` e recebeu isto:

```text
 id              | estado    | valor  | valor_estornado | versao | atualizado_em
-----------------+-----------+--------+-----------------+--------+---------------------
 0192d6e1-...    | capturada | 239000 |           40000 |      7 | 2025-09-16 10:04:11
```

Sete versões. Seis delas foram assassinadas por um `UPDATE` e enterradas sem lápide. A linha sabe que houve estorno de R$ 400,00 e sabe que mudou sete vezes. Quando, por quê e por ordem de quem, ela esqueceu. O banco guardou o resultado e jogou fora o processo, que é exatamente o contrário do que um juiz pede.

O tópico `cobrancas.eventos` e a outbox guardam sete dias (capítulos 17 e 18). E o plano do Carlos esbarra num detalhe: o backup diário é das 3h, o comprador falou das 15h, e restaurar o banco inteiro leva seis horas para ler uma linha que, às 3h, ainda nem tinha mudado.

Quem salvou a contestação foi, claro, a planilha do financeiro. Linha 4.812: "14/09 14h53 estorno Sabiá FALHOU saldo insuficiente, ver segunda". O financeiro não disse nada. Só girou o monitor.

Então a pergunta: como um sistema responde "qual era o estado disto no instante T" sem restaurar o mundo e sem depender de alguém que anota tudo numa planilha por trauma?

## Event sourcing, ou parar de dar UPDATE na própria biografia

A cobrança da Lastro segue o padrão de todo CRUD: uma linha por entidade, cada mudança sobrescreve a linha, e o passado é lixo que o `UPDATE` recolhe de graça.

**Event sourcing** inverte isso. A fonte da verdade passa a ser a sequência de **eventos**: fatos imutáveis, no passado (`cobranca.criada`, `estorno.solicitado`). O estado atual é **derivado** aplicando os eventos em ordem:

```text
estado_atual = fold(aplicar, eventos, estado_inicial)
```

`aplicar(estado, evento)` é uma função pura que recebe o estado e um evento e devolve o estado seguinte. Quem já escreveu um reducer no React escreveu exatamente isso: o reducer é `aplicar`, as actions são os eventos, e o estado da tela é o fold de tudo o que aconteceu. A diferença é que no event sourcing as actions ficam gravadas para sempre, inclusive aquela que você disparou duas vezes sem querer em 2019.

Daí sai a consulta que a Lastro não conseguia fazer: o estado no instante T é o fold dos eventos registrados até T. Sem backup, sem pizza.

Três definições sustentam o resto:

- **Agregado** (*aggregate*): a unidade de consistência. Uma cobrança é um agregado; toda regra que precisa valer de uma vez (não estornar mais do que foi capturado) vale dentro dele.
- **Stream**: a sequência de eventos de um agregado, numerada de 1 em diante. A cobrança `0192d6e1` tem um stream com versões 1, 2, 3 e assim por diante.
- **Comando** contra **evento**: o comando (`estornar 400`) é validado contra o estado atual e pode ser recusado; se aceito, gera eventos. O evento já aconteceu e não se recusa. Se `aplicar` lança exceção, o bug está no código, e o evento continua tendo acontecido, igual àquele deploy de sexta.

O evento diz o que aconteceu no domínio. `cobranca.atualizada` com o diff dos campos é o `UPDATE` fantasiado de evento: diz que `valor_estornado` foi de 0 para 40000, sem dizer se foi o marketplace, um chargeback ou o Carlos no `psql` às 2h.

### Duas datas, e as duas mentem de jeitos diferentes

Todo evento carrega o momento em que foi **registrado** (o `now()` do banco) e, às vezes, o momento em que **ocorreu** no mundo (o horário que o banco parceiro informa para um Pix, que pode chegar minutos depois). As duas linhas do tempo formam o modelo **bitemporal**: "o que a Lastro sabia às 15h" contra "o que tinha acontecido às 15h". Num chargeback, as respostas podem diferir, e o advogado do adquirente vai querer as duas.

A ordem dentro do stream vem da versão, nunca do relógio. Da última vez que a Lastro confiou no relógio de parede, 380 vendedores receberam duas vezes (capítulo 20).

## O event store, um banco que só aceita confissão

O **event store** é o armazenamento dos streams. As operações que ele precisa oferecer são poucas e exigentes:

1. **Anexar** eventos ao fim de um stream, atomicamente (vários eventos de um comando entram juntos ou nenhum entra).
2. **Ler** um stream inteiro, ou a partir de uma versão, em ordem.
3. **Controle de concorrência otimista**: anexar com uma **versão esperada**. Se outro comando gravou no stream nesse meio-tempo, o anexo falha.
4. **Assinar** todos os eventos em uma ordem global, para quem constrói visões (as projeções, adiante).

O item 3 é o coração da coisa. Dois comandos leem a cobrança na versão 4, os dois validam "dá para estornar 400", e os dois tentam gravar a versão 5. Num PostgreSQL, a chave primária `(cobranca_id, versao)` faz o trabalho sozinha:

```sql
INSERT INTO eventos_cobranca (cobranca_id, versao, tipo, dados)
VALUES ('0192d6e1-7c3e-7d4e-9f3a-2b8c6d1e0f47', 5,
        'estorno.solicitado', '{"valor": 40000}');
```

```text
ERROR:  duplicate key value violates unique constraint "eventos_cobranca_pkey"
DETAIL:  Key (cobranca_id, versao)=(0192d6e1-7c3e-7d4e-9f3a-2b8c6d1e0f47, 5) already exists.
```

O perdedor relê o stream, revalida e tenta de novo, ou devolve `409`. É o controle otimista do capítulo 4, com a versão sendo a posição do próprio fato na história. O banco recusa a segunda versão da mesma verdade com a frieza de um cartório que já tem firma reconhecida.

O item 4 é onde os event stores caseiros sangram. Uma posição global `BIGSERIAL` é atribuída no INSERT, mas fica visível no COMMIT: a 1.001 pode aparecer antes da 1.000, e o leitor que avançou para 1.001 nunca vê a 1.000. É o furo de IDs da outbox do capítulo 18, e as saídas são as mesmas: ler pelo CDC, na ordem do COMMIT, ou serializar os anexos e pagar em vazão.

Existem bancos feitos só para isso (o EventStoreDB é um exemplo). E existe a tentação de sempre: o Kafka como event store. Ele resolve o item 4 com sobra e falha nos itens 2 e 3: não há anexo condicional por chave, e ler o stream de uma cobrança exige varrer a partição inteira. Com retenção de sete dias, ainda é um cartório que incinera as escrituras toda segunda.

## Projeções e snapshots, ou como ler o passado sem reler a vida inteira

Uma **projeção** (*read model*) é um consumidor que lê os eventos em ordem e mantém uma estrutura pronta para uma consulta: uma tabela, um índice de busca, um contador. O `saldos_painel` do capítulo 19 é uma projeção que ainda não sabia o próprio nome. Propriedades:

- **Descartável.** Apagar e reconstruir a partir do evento 1 dá o mesmo resultado; mudar uma tela vira criar a projeção nova, alimentar desde o começo e trocar o ponteiro. É o único dado da empresa que você apaga sem avisar o jurídico.
- **Idempotente.** Guarda até onde aplicou (checkpoint) e ignora o que já viu, porque a entrega é at-least-once (capítulo 16).
- **Inline ou assíncrona.** A **inline** é atualizada na mesma transação do evento: leitura linearizável, custo na escrita. A **assíncrona** consome depois: escrita barata, leitura atrasada, e os truques de sessão do capítulo 19 voltam a ser problema seu.

Um **snapshot** é o estado de um agregado na versão N, salvo para que a leitura faça o fold só de N+1 em diante. É cache: apagável sem perda, e invalidado quando `aplicar` muda, porque carrega as regras do código velho. Só compensa em stream longo. Fold de 8 eventos custa microssegundos; snapshot para isso é contratar segurança armado para vigiar um pote de sal.

## Versionar eventos, porque o passado não aceita migração

No CRUD, mudar formato é migração (capítulo 7). No event sourcing, o `estorno.solicitado` de 2025 vai existir com o formato de 2025 enquanto a empresa existir, e o seu código de 2031 vai ler isso resmungando. As técnicas, da mais barata para a mais cara:

| Técnica | Como funciona | Custo |
|---------|---------------|-------|
| Esquema tolerante | Campo novo opcional; leitor ignora o que não conhece e trata ausente como padrão (o leitor tolerante do capítulo 11) | Quase nenhum; só serve para mudanças aditivas |
| Upcasting | Cada evento leva `versao_schema`; ao ler, uma função converte v1 → v2 → v3 antes de `aplicar` | Uma função por salto, para sempre, testada contra eventos reais antigos |
| Tipo novo | O significado mudou: `estorno.solicitado.v2` convive com o velho, e `aplicar` conhece os dois | Código que trata os dois tipos até o fim dos tempos |
| Copiar e transformar | Reescreve o store num novo, convertendo tudo | Quebra a imutabilidade; exige parar escritas ou rodar em paralelo; perde a prova de que o dado original era aquele |

A última linha é a favorita de quem nunca explicou a um perito por que o passado mudou de formato numa terça.

E tem o dado pessoal. A LGPD (Lei 13.709/2018) prevê, em certas hipóteses, a eliminação de dados pessoais, e um log imutável com CPF dentro descumpre isso para sempre. As saídas: o evento referencia o comprador por ID e o cadastro mora numa tabela que aceita `DELETE`, ou o dado é cifrado com uma chave por titular que se apaga quando for preciso esquecer (*crypto-shredding*, KMS no capítulo 33). O evento continua lá, intacto e ilegível, igual ao código do fundador.

## CQRS, a sigla que a Lastro já praticava escondida

Bertrand Meyer descreveu em 1988 o princípio CQS (*Command-Query Separation*): um método ou muda estado ou devolve dado, nunca as duas coisas. Greg Young levou a ideia do método para a arquitetura e chamou de **CQRS** (*Command Query Responsibility Segregation*): o modelo que recebe escritas é separado do modelo que serve leituras.

O modelo de escrita valida regras e mantém invariantes: normalizado, transações curtas. O modelo de leitura serve uma consulta: desnormalizado, já agregado, às vezes em outro banco. A ponte entre os dois costuma ser um fluxo de eventos.

CQRS não exige event sourcing: uma view materializada para relatório já é CQRS em miniatura. O contrário quase sempre vale, porque listar "as cobranças pendentes do Hornero" fazendo fold de cada stream é inviável sem projeção. CQRS também não exige dois bancos; a separação é de modelos. O custo fica na leitura assíncrona, que é eventual: com CQRS, o vendedor 42 olhando um saldo que ainda não sabe do próprio saque (capítulo 19) deixa de ser acidente e vira cláusula.

A Lastro já fazia isso escondida. O `saldos_painel` é um modelo de leitura. E o ledger, desde o capítulo 1, é event sourcing de cabo a rabo: lançamentos imutáveis, saldo derivado por `SUM` (um fold com `+` no lugar de `aplicar`), estorno como fato novo, baldes de `saldos_parciais` como projeção inline. Pat Helland pôs isso num título de seção: contadores não usam borracha. O tabelião do capítulo 1 fazia event sourcing antes de o Carlos saber soletrar a expressão.

## O que a Lastro guarda como evento (e o que continua sendo foto)

O requisito vem da contestação e da conciliação: para cada cobrança, o estado em qualquer instante, o fato que causou cada mudança e quem pediu (marketplace, adquirente, banco parceiro, conciliação), em segundos e com valor de evidência.

| Alternativa | O que guarda | Responde "estado em T"? | Responde "por quê"? | Custo |
|-------------|--------------|-------------------------|---------------------|-------|
| Backup + restauração | Foto do banco às 3h | Só às 3h, em ~6 h | Não | Sala, pizza e o Carlos |
| Tabela de histórico por trigger | Cópia da linha a cada `UPDATE` | Sim | Não: guarda o diff, sem intenção nem autor | Baixo; o código de escrita não muda |
| Tabelas versionadas do SQL:2011 | Igual, com sintaxe `FOR SYSTEM_TIME AS OF` | Sim | Não | O PostgreSQL não implementa; exigiria extensão |
| Event sourcing do agregado | Fatos com autor e causa | Sim, pelo fold | Sim | Reescrever o caminho de escrita da cobrança; versionar eventos para sempre |

A tabela de histórico responde "qual era o estado" e falha na pergunta que decidiu a contestação: `valor_estornado` igual a zero antes e depois das 14h53 esconde um estorno pedido às 14h52 e recusado por saldo um minuto depois.

A Lastro adota event sourcing **para o ciclo de vida da cobrança e só para ele**:

```text
              comando (API, resolução, banco, conciliação, chargeback)
                                    │
                                    ▼
          lê stream da cobrança ─▶ valida ─▶ uma transação no primário:
                                             ├─ INSERT eventos_cobranca (versão esperada)
                                             ├─ UPDATE cobrancas (projeção inline)
                                             ├─ INSERT lançamentos (se mexe em dinheiro)
                                             └─ INSERT eventos_saida (outbox, cap. 18)
                                                         │ CDC
                                                         ▼
                              cobrancas.eventos / contas.movimentos (broker)
                                                         │
                                  ┌──────────────────────┼─────────────────┐
                                  ▼                      ▼                 ▼
                           saldos_painel          extrato_linhas      webhooks
```

As decisões e os motivos:

- **Event store no PostgreSQL do ledger**: `eventos_cobranca`, chave `(cobranca_id, versao)`, com `tipo`, `versao_schema`, `dados` (`jsonb`), `autor`, `registrado_em`, `ocorrido_em`. O evento entra no mesmo COMMIT dos lançamentos e da outbox; em outro sistema, volta a escrita dupla do capítulo 18.
- **`cobrancas` vira projeção inline.** A coluna `versao`, que já alimentava o `ETag` (capítulo 9) e os webhooks (capítulo 11), passa a ser a versão do stream. A leitura segue linearizável (capítulo 19), e nenhum dos 40 trechos de código que leem `cobrancas` mudou. O Carlos contou 40; a CI contou 43.
- **Eventos de domínio ficam internos.** O webhook público segue o contrato do capítulo 11; publicar o store direto congelaria o formato interno pela Lei de Hyrum.
- **Volume:** ~25 mil cobranças/dia × ~5 eventos × ~1 KB ≈ 45 GB por ano, conta que vai para o capítulo 24. O maior stream tem 31 eventos (14 estornos parciais; ninguém quer conhecer esse comprador). **Sem snapshots**: o pior fold leva menos de 1 ms.
- **Migração:** cada cobrança antiga ganha o evento sintético `cobranca.importada`, com `autor = migracao`, para nenhum perito confundir o começo do stream com o começo da cobrança.

A consulta da contestação, refeita sobre o stream, passa a ter esta cara:

```text
v  registrado_em        tipo                  autor          efeito
1  10/09 19h22min04s    cobranca.criada       api:bazar      pendente
2  10/09 19h22min05s    cobranca.autorizada   adquirente     autorizada
3  10/09 19h22min05s    cobranca.capturada    api:bazar      capturada
4  14/09 14h52min10s    estorno.solicitado    api:bazar      R$ 400,00
5  14/09 14h53min02s    estorno.falhou        ledger         saldo-insuficiente
6  16/09 10h04min09s    estorno.solicitado    api:bazar      R$ 400,00
7  16/09 10h04min11s    estorno.concluido     adquirente     estornado 40000
-- fold até 14/09 15h00: capturada, estorno pedido e recusado, nada devolvido
```

O extrato do vendedor, que lia o primário (capítulos 5 e 6), vira a projeção assíncrona `extrato_linhas`: cada linha precisa mostrar a história ligada a ela (venda, estorno recusado, valor bloqueado por chargeback), e montar isso no primário junta lançamentos, cobranças e stream a cada página. O evento `conta.movimentada` (capítulo 19) passa a carregar a descrição pronta, e o consumidor grava no `pg-notificacoes`, que virou o banco de leitura da Lastro e só não mudou de nome por respeito ao crontab. Leitura com o read-your-writes do capítulo 19; reconstrução a partir dos ~60 milhões de lançamentos numa tabela paralela, ~5 mil linhas/s, ~3h20, troca de ponteiro no fim.

**Continuam foto**, com histórico por trigger: cadastro de vendedores, inscrições de webhook, configurações de tarifa e split. Conciliação e fechamento seguem no ledger do primário, porque o financeiro não aceita "atualizando" como saldo. Se a Lastro só precisasse de auditoria, a tabela de histórico bastaria para tudo; event sourcing se paga quando a intenção de cada mudança precisa sobreviver a ela.

## Armadilhas e casos reais

> **Armadilha:** event sourcing em tudo. O cadastro do vendedor como stream de `vendedor.telefone_alterado` cobra projeção, versionamento e consistência eventual para responder uma pergunta que ninguém faz. O resultado é um CRUD com custo de banco central e utilidade de diário de adolescente.

> **Armadilha:** projeção que lê o relógio ou chama uma API dentro de `aplicar`. A reconstrução de amanhã dá resultado diferente da de hoje, e "descartável" morre na primeira tentativa. Tudo que a projeção precisa tem de estar no evento. E cronometre a reconstrução: 3h20 para refazer o extrato é um RTO de 3h20 para aquela tela.

> **Na vida real:** a LMAX, bolsa de câmbio de Londres, roda a lógica de negócio num único thread em memória, com cerca de 6 milhões de pedidos por segundo, segundo o artigo de Martin Fowler de 2011. Os eventos de entrada vão para um journal; se o processo cai, volta de um snapshot e reaplica o resto. O banco de dados virou um arquivo de log e um botão de replay.

O erro mais frequente: eventos que descrevem tabelas, como `cobranca.atualizada` e `cobranca.salva`. O time paga o preço inteiro do event sourcing e recebe de volta a amnésia do `UPDATE`, agora em JSON.

## Resumo

- Event sourcing: eventos imutáveis são a fonte da verdade; estado = fold; estado em T = fold até T.
- Comando pode ser recusado; evento já aconteceu. Agregado = unidade de consistência; stream = seus eventos, numerados.
- Event store: anexo atômico, leitura por stream, versão esperada, assinatura em ordem global.
- Bitemporal: registro e ocorrência; ordem pela versão, nunca pelo relógio.
- Projeções descartáveis e idempotentes, inline ou assíncronas; snapshot é cache para stream longo.
- Versionamento: esquema tolerante, upcasting, tipo novo, copiar e transformar; dado pessoal fora do evento.
- CQRS: modelos separados de escrita e leitura, sem exigir event sourcing nem dois bancos.

## A Lastro agora

O ciclo de vida da cobrança é um stream em `eventos_cobranca`, no mesmo COMMIT dos lançamentos e da outbox; `cobrancas` virou projeção inline linearizável e o extrato, a projeção assíncrona `extrato_linhas`. Cadastros e configurações seguem como tabela com histórico por trigger. A contestação do Sabiá foi respondida no sexto dia, com a planilha do financeiro anexada como "evidência complementar"; agora o próprio stream responde em 4 ms, e o financeiro, pela primeira vez desde o capítulo 1, apagou uma aba.

O Carlos comeu a pizza sozinho, porque o backup terminou às 2h. Já o gerente de produto notou que a criação de cobrança lê a tabela de tarifas e a configuração de split do marketplace onze vezes por requisição, as mesmas onze vezes, com os mesmos valores, que mudam uma vez por mês. O Carlos ouviu a palavra "Redis" numa conversa de corredor e já propôs guardar tudo lá, inclusive o saldo do saque, "porque é só um cache".

## Referências

- Martin Fowler, "Event Sourcing" (2005): https://martinfowler.com/eaaDev/EventSourcing.html
- Martin Fowler, "CQRS" (2011): https://martinfowler.com/bliki/CQRS.html
- Martin Fowler, "The LMAX Architecture" (2011): https://martinfowler.com/articles/lmax.html
- Greg Young, "CQRS Documents" (2010): https://cqrs.files.wordpress.com/2010/11/cqrs_documents.pdf
- Pat Helland, "Immutability Changes Everything", CIDR 2015: https://www.cidrdb.org/cidr2015/Papers/CIDR15_Paper16.pdf
- Bertrand Meyer, *Object-Oriented Software Construction*, Prentice Hall, 1988 (princípio CQS).
- Lei nº 13.709/2018 (LGPD): https://www.planalto.gov.br/ccivil_03/_ato2015-2018/2018/lei/l13709.htm
