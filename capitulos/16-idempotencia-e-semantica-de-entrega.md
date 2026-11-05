# Idempotência e semântica de entrega

## Duas vezes, com jitter

O comprador comprou um fone de R$ 349,90 no Bazar e recebeu duas notificações do banco: duas compras de R$ 349,90, mesmo estabelecimento, com 3 segundos de diferença. Ele não clicou duas vezes. Quem clicou duas vezes foi a consultoria Java do Bazar, por ele, com backoff exponencial e full jitter, exatamente como o guia mandava.

A sequência daquela terça, cronometrada pelo financeiro com a serenidade de quem já não espera nada:

```text
10h14:02,0  Bazar envia POST /v1/cobrancas (pedido 88213)       [timeout 10 s]
10h14:04,6  ...pool de conexões do Bazar libera a requisição
10h14:12,4  Lastro responde 201, estado "processando"            [Bazar já desistiu]
10h14:13,1  Bazar repete: POST /v1/cobrancas (pedido 88213)
10h14:14,0  Lastro responde 201, estado "autorizada", outra cobrança
10h14:31,0  resolução: primeira cobrança aprovada -> webhook "autorizada"
```

Duas cobranças, dois IDs, duas referências no adquirente, duas autorizações. Para a Lastro, eram dois pedidos de pagamento perfeitamente válidos que, por coincidência, tinham o mesmo valor, o mesmo cartão e o mesmo `pedido_id`. Naquela terça foram 37 compradores. O Bazar abriu o chamado "URGENTE!!!! COBRANÇA DUPLICADA!!!!", com o recorde de 16 exclamações, e a consultoria cobrou 40 horas para explicar que o retry dela estava correto.

E estava. O capítulo 15 ensinou a regra: só se repete com segurança o que não teve efeito ou o que é idempotente. O retry do Bazar seguiu a regra pela metade, e a outra metade era responsabilidade da Lastro. Como uma API faz com que "tentar de novo" signifique "a mesma operação", e não "outra operação igual"?

## At-most-once, at-least-once e o unicórnio

Toda comunicação por uma rede que perde mensagens, entre processos que podem morrer, escolhe uma **semântica de entrega**:

| Semântica | Como se obtém | O que pode dar errado |
|-----------|---------------|------------------------|
| At-most-once (no máximo uma vez) | envia uma vez, nunca repete | a mensagem se perde |
| At-least-once (pelo menos uma vez) | repete até receber confirmação | a mensagem chega duplicada |
| Exactly-once (exatamente uma vez) | ? | o vendedor da ideia some com o dinheiro |

A escolha entre as duas primeiras é a escolha entre perder e duplicar. Não existe terceira opção na entrega, e a razão é o **problema dos dois generais** (descrito em 1975 por Akkoyunlu, Ekanadham e Huber; o nome veio de Jim Gray, em 1978): dois processos que se comunicam por um canal que pode perder mensagens não conseguem, com nenhum protocolo finito, ter certeza de que ambos sabem o mesmo fato. A última mensagem do protocolo pode se perder, e quem a enviou nunca sabe se ela chegou. Confirmar a confirmação só empurra o problema para a próxima mensagem. É o TCP do capítulo 8 com crise de ansiedade, e a terapia não converge.

O que existe, e é o que os produtos querem dizer quando escrevem "exactly-once" na página de vendas, é **efeito exatamente uma vez**: entrega at-least-once mais um receptor que reconhece duplicatas e as descarta, ou que processa de forma que a repetição não muda nada. A mensagem chega três vezes; o dinheiro sai uma.

> **Na vida real:** o Kafka anuncia exactly-once desde a versão 0.11 (2017, KIP-98), e a garantia é precisa e restrita. O produtor idempotente recebe um ID e numera as mensagens por partição, e o broker descarta números repetidos; as transações tornam atômico o ciclo consumir, processar e produzir dentro do Kafka. Um e-mail enviado, uma chamada ao adquirente ou um `INSERT` num PostgreSQL de fora estão fora da transação e voltam a ser at-least-once. O unicórnio existe, mas não sai do curral.

## Idempotência, a palavra que todo mundo usa e quase ninguém conjuga

Uma operação é **idempotente** quando aplicá-la várias vezes produz o mesmo efeito que aplicá-la uma vez: `f(f(x)) = f(x)`. A RFC 9110 (seção 9.2.2) define assim os métodos HTTP: são idempotentes os seguros (`GET`, `HEAD`, `OPTIONS`, `TRACE`) mais `PUT` e `DELETE`. O `POST` fica de fora, por definição, o que faz dele o método favorito de quem cria cobranças e de quem cria problemas.

Dois detalhes que o mercado erra:

**Idempotência fala do efeito, e não da resposta.** O primeiro `DELETE /v1/webhooks/123` responde `204`; o segundo, `404`. O estado do servidor é o mesmo depois de um ou de dois, então a operação é idempotente, mesmo com respostas diferentes.

**Idempotência isolada não protege contra intercalação.** `PUT` com `estado = pausado` é idempotente. Mas se o cliente envia A, outro cliente envia B, e o retry atrasado de A chega depois, A sobrescreve B. Cada operação é idempotente; a sequência ficou errada. Para isso existe a escrita condicional com `If-Match` e `ETag` (capítulo 9), que transforma o retry atrasado num `412`.

Algumas operações já nascem idempotentes, e vale desenhar para que nasçam:

| Operação | Idempotente? | Por quê |
|----------|--------------|---------|
| `UPDATE contas SET estado = 'bloqueada'` | sim | valor absoluto |
| `UPDATE ... SET estado = 'capturada' WHERE estado = 'autorizada'` | sim | a segunda execução afeta 0 linhas |
| `UPDATE ... SET saldo = saldo + 100` | não | valor relativo; cada execução soma |
| `INSERT` com chave gerada pelo banco | não | cada execução cria uma linha nova |
| `INSERT` com chave natural `UNIQUE` | sim, com `ON CONFLICT DO NOTHING` | a segunda colide e não faz nada |

A última linha é a ferramenta que resolve metade dos problemas de pagamento, e o PostgreSQL entrega de fábrica:

```sql
INSERT INTO pix_recebidos (end_to_end_id, valor)
VALUES ('E00038166202611041314abcdef12345', 34990)
ON CONFLICT (end_to_end_id) DO NOTHING;
-- primeira vez:  INSERT 0 1
-- segunda vez:   INSERT 0 0
```

`INSERT 0 0` é o banco dizendo "já tenho, obrigado", com a educação de quem não vai cobrar de novo. A chave natural do evento vira a chave de deduplicação, e a garantia mora numa restrição do banco, que não esquece, não tem pausa de GC e não depende do humor do Carlos.

## A chave de idempotência, ou como dar RG para uma intenção

O `POST /v1/cobrancas` não tem chave natural. Dois pedidos de R$ 349,90 no mesmo cartão podem ser duas compras legítimas (o comprador quis dois fones; ninguém julga) ou um retry. Só o cliente sabe, e a Lastro, que não lê mentes nem o código da consultoria, precisa que ele diga.

A **chave de idempotência** é um identificador que o cliente gera **uma vez por operação lógica**, antes da primeira tentativa, e reenvia igual em todos os retries. O servidor guarda a chave junto com o resultado e, ao ver a mesma chave de novo, devolve o resultado guardado em vez de executar de novo. O Stripe popularizou o cabeçalho `Idempotency-Key`, e o IETF tem um Internet-Draft que padroniza o campo (`draft-ietf-httpapi-idempotency-key-header`, ainda em andamento):

```http
POST /v1/cobrancas HTTP/1.1
Idempotency-Key: 0193f2a1-7c4e-7b55-9d1e-3f6a8b2c4d10
Content-Type: application/json

{"valor": 34990, "metodo": "cartao", "metadata": {"pedido_id": "88213"}}
```

A primeira requisição cria e responde `201`. A segunda, com a mesma chave e o mesmo corpo, recebe o mesmo `201` com o mesmo ID de cobrança, sem tocar no adquirente. O servidor precisa tratar quatro casos:

1. **Chave nova:** registra a chave como *em andamento*, executa, grava a resposta.
2. **Chave concluída, mesmo corpo:** devolve a resposta gravada, com o mesmo status.
3. **Chave em andamento** (o retry chegou antes do fim da primeira): `409`, porque executar em paralelo é exatamente o que se quer evitar.
4. **Chave conhecida, corpo diferente:** `422`. O cliente reaproveitou a chave para outra operação, e isso é bug dele que, se aceito, vira bug seu.

O draft do IETF usa esses mesmos `409` e `422`. Para o caso 4, o servidor guarda uma impressão digital da requisição (um hash do corpo canonizado e do caminho) e compara.

Três decisões definem se o mecanismo funciona ou só decora:

**Escopo.** A chave é única por cliente, não globalmente: `(marketplace_id, chave)`. Senão o Bazar e o Hornero colidem por acaso, ou um descobre as chaves do outro de propósito.

**Retenção.** A chave precisa viver mais que a janela de retry de qualquer cliente. O Stripe guarda por 24 horas. Uma chave que expira em 5 minutos protege contra o retry de 3 segundos e entrega o retry da fila de reprocessamento da madrugada.

**Atomicidade.** Chave e efeito precisam ser gravados juntos. Se a chave fica num Redis e a cobrança no PostgreSQL, existe um instante em que um foi gravado e o outro não, e um processo morto nesse instante deixa uma chave sem cobrança ou uma cobrança sem chave. A segunda opção cobra duas vezes. A chave mora no mesmo banco e na mesma transação do efeito.

E quando o efeito inclui uma chamada externa, que nenhuma transação de banco abraça? A operação é dividida em **fases atômicas** com pontos de recuperação, como descreveu Brandur Leach num artigo de 2017 sobre chaves no estilo do Stripe em PostgreSQL: cada fase local é uma transação que avança o estado da chave; a chamada externa fica entre duas fases e usa, ela própria, um identificador idempotente no parceiro. Se o processo morre no meio, quem retoma lê a fase gravada e continua dali, em vez de recomeçar. É a máquina de estados que o capítulo 15 já desenhou para o `processando`, agora com uma chave na frente.

## Deduplicação do lado de quem recebe

Do outro lado da semântica at-least-once fica o consumidor, recebendo a mesma mensagem duas, cinco, vinte vezes. Ele tem três formas de sobreviver:

- **Processamento naturalmente idempotente:** a operação é desenhada como valor absoluto ou transição condicional (tabela acima). Zero estado extra, nenhuma janela.
- **Chave natural do domínio com `UNIQUE`:** o EndToEndId do Pix, o ID da cobrança, o ID do estorno. A restrição dura para sempre, porque a linha dura para sempre.
- **Tabela de mensagens processadas** (*inbox*): o ID de cada mensagem é gravado na mesma transação do efeito; a repetição colide e é descartada. Quando não há chave de domínio, é o que sobra.

O ponto que separa a deduplicação de verdade da de enfeite é a **janela**. Toda deduplicação por cache tem uma: o Amazon SQS FIFO, por exemplo, deduplica por 5 minutos. Uma duplicata que chegar no minuto 6 é uma mensagem nova, legítima, processada com o mesmo zelo da primeira. A janela precisa cobrir o atraso máximo possível de uma repetição, e "máximo possível" inclui o reprocessamento manual que o Carlos faz na segunda-feira.

E a regra de ouro do consumidor: **duplicata reconhecida responde sucesso**. Se o banco do Pix reenvia uma notificação já processada e a Lastro responde `409`, o banco entende falha e tenta de novo, para sempre ou até desistir e marcar a Lastro como instável. A resposta correta é `200`: "recebido, e já estava".

## Na Lastro: cada efeito com um RG

O incidente teve uma causa só, e a Lastro tem várias portas de entrada com o mesmo defeito. Cada operação que produz efeito ganha um mecanismo de deduplicação ancorado no PostgreSQL:

| Operação | Duplicata vem de | Mecanismo |
|----------|------------------|-----------|
| `POST /v1/cobrancas`, `POST .../estornos` | retry do marketplace | `Idempotency-Key`, escopo marketplace, 24 h |
| `POST .../captura` | retry do marketplace | transição condicional `autorizada → capturada` |
| Autorização no adquirente | timeout de conexão, `GOAWAY` | referência única = ID da cobrança |
| Notificação de Pix recebido | retry do banco parceiro | EndToEndId `UNIQUE` (desde o capítulo 1) |
| Repasse por Pix | retry da Lastro ao banco | identificador do repasse enviado ao banco |
| Transação do ledger | qualquer uma acima | `(origem, referencia)` `UNIQUE` em `transacoes` |
| Webhook para o marketplace | retry da Lastro (capítulo 17) | `id` do evento, deduplicado pelo marketplace (capítulo 11) |

**A chave na API.** Em `/v1`, o `Idempotency-Key` é opcional, porque torná-lo obrigatório quebraria todo cliente existente (regra do capítulo 11), e passa a ser obrigatório em `/v2`. O guia de integração diz o que a consultoria precisava ler: gere a chave (um UUID) quando o pedido decide cobrar, guarde junto do pedido, reenvie a mesma em todo retry. A tabela de chaves tem, conceitualmente, `marketplace_id`, `chave`, `hash_requisicao`, `fase`, `cobranca_id`, `status_http`, `corpo_resposta` e `expira_em`, com chave primária `(marketplace_id, chave)`. A retenção de 24 horas cobre o deadline de 8 s, a resolução do `processando` e as filas de reprocessamento dos clientes. Mesmo um dia inteiro no pico projetado de 200 cobranças por segundo daria 17 milhões de linhas, e um job apaga as expiradas em lotes.

O fluxo da cobrança de cartão com chave:

```text
tx1: INSERT chave (fase = criada) + INSERT cobrança      ── COMMIT
     ── retry agora recebe 409 "requisicao-em-andamento" + Retry-After: 2
Vigia, adquirente (referência = ID da cobrança)
tx2: UPDATE cobrança + chave (fase = concluida, resposta) ── COMMIT
     ── retry agora recebe a resposta gravada, mesmo status, mesmo ID
processo morre entre tx1 e tx2?
     ── resolução do capítulo 15 consulta por referência, conclui a chave
```

Se o corpo do retry diferir do original, `422` com o `type` RFC 9457 `chave-idempotencia-reutilizada`. Se a cobrança terminou em `processando`, o retry recebe o mesmo `processando` com o mesmo ID, e não uma segunda cobrança que, por ser mais rápida, sairia `autorizada`. No incidente da terça, o retry das 10h14:13 teria devolvido a cobrança da primeira tentativa, e o fone teria sido cobrado uma vez.

**O adquirente.** A referência única que o capítulo 15 trouxe também é a chave de idempotência da Lastro com o adquirente: pelo contrato de integração, uma segunda autorização com referência já usada é recusada com o código de referência duplicada, sem nova reserva no cartão. Os retries de conexão e de `GOAWAY` ficam seguros mesmo se a premissa "nada foi enviado" falhar. O timeout de leitura segue sem retry, porque o deadline já acabou; quem resolve é a consulta.

**O ledger.** A tabela `transacoes` ganha `origem` e `referencia`, com índice único sobre o par, criado com `CONCURRENTLY` e as regras de migração do capítulo 7. Todo evento que gera lançamentos se identifica: `('pix_recebido', EndToEndId)`, `('captura', cobranca_id)`, `('estorno', estorno_id)`, `('repasse', repasse_id)`. O tabelião agora registra também o RG de quem pediu cada partida dobrada. Se dois caminhos tentarem lançar a mesma captura (um retry, um job, o `psql` do Carlos), o segundo encontra a restrição e vira um `INSERT 0 0` de uma transação inteira.

**O Pix.** A notificação do banco parceiro já era deduplicada pelo EndToEndId `UNIQUE` desde o capítulo 1, a única defesa da Lastro que funcionou na terça, escrita quinze capítulos atrás por quem nem sabia que estava se defendendo. A mudança é na resposta: duplicata reconhecida devolve `200`. No repasse, a Lastro envia ao banco o ID do repasse como identificador da requisição, e o banco recusa um segundo pagamento com o mesmo identificador: o retry após timeout fica seguro, e a "falha pós-débito" pendente desde o capítulo 2 ganha metade da resposta (a outra metade é do capítulo 18).

A alternativa descartada foi deduplicar por conteúdo (mesmo marketplace, `pedido_id`, valor e cartão em 10 minutos). Dispensa mudança no cliente e erra nos dois sentidos: bloqueia a segunda compra legítima e deixa passar o retry com `pedido_id` regerado. Serve só como alerta para cliente que não pode mudar a integração, nunca como regra que recusa pagamento.

## Armadilhas e casos reais

> **Armadilha:** a chave gerada dentro do laço de retry. A consultoria do Bazar, na primeira versão da correção, colocou `UUID.randomUUID()` dentro do `for` das tentativas. Cada retry tinha uma chave nova, a Lastro via três operações diferentes, e a idempotência funcionou perfeitamente para garantir que cada cobrança duplicada fosse única. Mais 40 horas.

> **Armadilha:** devolver o estado atual em vez da resposta original. Se o replay de uma chave concluída lê a cobrança de novo, o retry de uma criação pode receber `estado: estornada`, e o cliente conclui que a cobrança nasceu estornada. O replay devolve o que a primeira resposta disse.

> **Armadilha:** a chave e o efeito em bancos diferentes. O Carlos propôs guardar as chaves no Redis "porque é mais rápido". É, e o processo que morre entre o `SET` no Redis e o `COMMIT` no PostgreSQL deixa uma chave que diz "concluída" para uma cobrança que não existe. A velocidade de errar também melhorou.

> **Na vida real:** o Amazon SQS oferece filas padrão com entrega at-least-once e filas FIFO com deduplicação por 5 minutos, pelo ID de deduplicação ou pelo hash do corpo. A documentação é explícita sobre a janela; o que costuma falhar é o produtor que repete depois dela.

Uma última: "idempotente" usado como sinônimo de "pode repetir à vontade". O `PUT` que sobrescreve com o valor antigo depois de outro cliente ter mudado é idempotente e está errado. Idempotência resolve repetição; ordem é outro problema, com outra ferramenta (o `If-Match`), e o capítulo 20 volta a ela.

## Resumo

- Entrega at-most-once perde, at-least-once duplica, e exactly-once na entrega é impossível (dois generais); existe efeito exatamente uma vez = at-least-once + deduplicação.
- Idempotência: `f(f(x)) = f(x)`, sobre o efeito, e não sobre a resposta; não protege contra intercalação.
- Operações naturalmente idempotentes: valor absoluto, transição condicional, `INSERT` com chave natural e `ON CONFLICT DO NOTHING`.
- Chave de idempotência: gerada por operação, escopo por cliente, retenção maior que a janela de retry, gravada na mesma transação do efeito; `409` em andamento, `422` com corpo diferente.
- Chamada externa no meio: fases atômicas com recuperação e identificador idempotente no parceiro.
- Consumidor deduplica por chave natural ou inbox, com janela suficiente, e responde sucesso à duplicata.

## A Lastro agora

A API aceita `Idempotency-Key` (opcional em `/v1`, obrigatória em `/v2`), com escopo por marketplace, retenção de 24 h, `409` em andamento e `422` para chave reutilizada. A captura é transição condicional, a referência no adquirente e o ID do repasse no banco viraram chaves de idempotência com os parceiros, e `transacoes` ganhou `(origem, referencia)` único: o ledger não aceita o mesmo fato duas vezes, venha de onde vier. O financeiro estornou as 37 cobranças duplicadas, e a consultoria, na segunda tentativa, gerou a chave fora do laço.

Toda entrada da Lastro agora resiste à repetição. A saída, nem tanto: os webhooks continuam saindo de dentro da requisição, uma vez, sem retry, depois do COMMIT. A Lastro garante efeito exatamente uma vez em tudo o que recebe e entrega at-most-once em tudo o que manda. Na quinta, o servidor de webhooks do Hornero começou a responder em 25 segundos, e a API da Lastro descobriu que esperar educadamente por um cliente lento é a forma mais idempotente de cair: cai igual, quantas vezes for.

## Referências

- RFC 9110, HTTP Semantics, seção 9.2.2 (Idempotent Methods): https://www.rfc-editor.org/rfc/rfc9110#section-9.2.2
- IETF, "The Idempotency-Key HTTP Header Field" (Internet-Draft): https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/
- Stripe, "Idempotent requests": https://docs.stripe.com/api/idempotent_requests
- Brandur Leach, "Implementing Stripe-like Idempotency Keys in Postgres", 2017: https://brandur.org/idempotency-keys
- E. A. Akkoyunlu, K. Ekanadham, R. V. Huber, "Some Constraints and Tradeoffs in the Design of Network Communications", SOSP 1975.
- Jim Gray, "Notes on Data Base Operating Systems", 1978.
- KIP-98, "Exactly Once Delivery and Transactional Messaging": https://cwiki.apache.org/confluence/display/KAFKA/KIP-98+-+Exactly+Once+Delivery+and+Transactional+Messaging
- Amazon SQS, "Exactly-once processing in Amazon SQS" (FIFO): https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues-exactly-once-processing.html
- PostgreSQL 16, "INSERT ... ON CONFLICT": https://www.postgresql.org/docs/16/sql-insert.html
