# Falhas parciais

## Recusada, segundo o cronômetro

Sexta-feira de Black Friday, 21h40, e o adquirente da Lastro resolveu ter a Black Friday dele também: o p99 das autorizações foi de 1,18 para 4 segundos. Na Lastro, alguém tinha configurado um timeout de 1,3 segundo na chamada ao adquirente, "para proteger o contrato". Esse alguém tem nome, crachá e um histórico de commits que o RH guarda numa pasta à parte. Foi o Carlos.

O contrato exige p99 abaixo de 1,5 s, então o que passasse de 1,3 s virava `recusada`. Em dez minutos, foram 3.000. O p99 da Lastro ficou lindo. O Bazar cancelou 3.000 pedidos.

No sábado, o financeiro cruzou o arquivo do adquirente com a planilha: das 3.000 "recusadas", 412 tinham sido aprovadas. 412 compradores com o limite reservado, sem pedido e com um e-mail do Bazar dizendo "tente novamente". Muitos tentaram. O financeiro desfez as 412 reservas uma por uma no portal do adquirente, numa planilha nova chamada `bf_desfazer_FINAL.xlsx`, que agora divide com a planilha de conciliação o título de banco de dados mais confiável da empresa.

O cronômetro funcionou perfeitamente. O erro foi o que a Lastro fez com a exceção: transformou "não sei" em "não". Quando uma chamada a um parceiro estoura o timeout, o comprador foi cobrado ou não? E o que um sistema de pagamentos faz com uma pergunta que não tem resposta?

## As formas criativas de uma chamada remota dar errado

Uma chamada de função tem dois finais: retorna ou levanta exceção. Pela rede aparece um terceiro: **resultado desconhecido**. É a **falha parcial**: parte do sistema funciona, parte não, e um lado não consegue saber com certeza o estado do outro. As falhas se classificam pelo comportamento visível:

- **Crash (parada):** o componente para de responder, ou volta reiniciado e sem memória. Se os outros detectam a parada com certeza, chama-se *fail-stop*. Quase nunca detectam.
- **Omissão:** uma mensagem some, na ida ou na volta.
- **Falha de tempo:** a resposta vem certa e tarde demais. A do adquirente na sexta.
- **Bizantina:** o componente responde coisa errada, por bug ou malícia. Com parceiros confiáveis e TLS, sobra o bug, que já é bizantino o suficiente.

Do lado de quem chamou, crash, omissão e lentidão produzem o mesmo sintoma: silêncio. E silêncio tem quatro explicações que você não consegue distinguir:

```text
1. a requisição se perdeu antes de chegar          -> nada aconteceu
2. o parceiro está processando, devagar            -> vai acontecer
3. o parceiro processou e a resposta se perdeu     -> aconteceu
4. o parceiro morreu no meio                       -> boa sorte
```

A Lastro, na sexta, apostou na explicação 1 para todas as 3.000. Acertou 2.588 e errou 412, uma taxa de acerto que seria excelente para um meteorologista e é demissão para um sistema de pagamentos.

E há a **falha cinzenta** (*gray failure*), descrita por pesquisadores da Microsoft em 2017: saudável para o monitoramento (health check `200`), doente para os clientes. O monitoramento diz que está tudo bem. O Bazar diz URGENTE!!!!. Só um dos dois paga a sua fatura.

**Nenhum timeout distingue um parceiro morto de um lento.** Ele só diz que você parou de esperar, e o resto do capítulo trata do que fazer depois.

## Timeout, ou o momento exato de desistir de alguém

Um timeout é uma decisão de negócio disfarçada de número. Uma chamada HTTP tem dois que importam. O de **conexão** limita TCP + TLS até a conexão existir, e tem uma propriedade preciosa: quando estoura, a requisição **com certeza não foi enviada**. É a explicação 1, garantida. O de **leitura** limita a espera pela resposta e estoura com a requisição já entregue: "não sei". Há ainda o de escrita e o total, que limita a operação inteira.

**Curto demais**, ele dispara com o parceiro saudável: com p99,9 de 2,7 s num dia normal, um timeout de 1,3 s faz, por construção, mais de 0,1% de falsas falhas, e num dia ruim muito mais. Com retry, cada uma vira carga extra no parceiro lento. O timeout curto mede a febre e aplica mais febre.

**Longo demais**, cada chamada presa segura semáforo, conexão e memória. Pela Lei de Little (capítulo 14), em andamento = taxa de chegada × espera. A 60 autorizações por segundo com o parceiro travado, um timeout de 8 s acumula 480 chamadas penduradas; um de 30 s, 1.800.

A regra: o timeout fica **acima da cauda saudável do parceiro** (o p99,9 de um dia normal, com folga), para disparar só em falha de verdade, e **abaixo da paciência de quem chamou você**, para a resposta chegar a alguém que ainda está ouvindo. Se as duas condições não cabem juntas, o problema está no contrato.

Não ter timeout também é uma escolha, tomada por omissão. A `requests` espera para sempre sem `timeout=`; o `httpx` usa 5 s por padrão. Uma chamada sem timeout é um parente desaparecido: o processo não pode fazer o velório nem reaproveitar o quarto.

## Retry, ou insistir com quem já disse que está ocupado

Tentar de novo resolve falhas transitórias e cria duas pragas: a operação executada duas vezes e a multidão insistindo ao mesmo tempo.

### Quando é seguro repetir

Uma repetição é segura em dois casos. No primeiro, você **sabe** que a primeira tentativa não teve efeito: timeout de conexão, conexão recusada, `GOAWAY` do HTTP/2 com o stream acima do último ID processado (capítulo 9), `429` ou `503` emitidos antes de processar. No segundo, a operação é **idempotente**: repeti-la tem o mesmo efeito que executá-la uma vez. Consultar uma autorização é idempotente. Autorizar um cartão, sem mecanismo extra, reserva o limite duas vezes, e o comprador ganha duas linhas na fatura e um motivo para conhecer o Procon.

Retry de operação não idempotente depois de timeout de leitura transforma "não sei se cobrei" em "talvez tenha cobrado duas vezes". O capítulo 16 mostra como tornar a autorização segura para repetir; até lá, não se repete.

### Backoff exponencial e jitter

Repetir imediatamente devolve a carga, multiplicada, ao servidor que caiu por excesso dela. O **backoff exponencial** dobra a espera a cada tentativa (100 ms, 200 ms, 400 ms, com um teto). Não basta: mil clientes que falharam no mesmo instante esperam os mesmos 100 ms e voltam juntos, em ondas sincronizadas, um flash mob de DDoS com convite agendado.

O **jitter** sorteia a espera. A variante *full jitter*, analisada por Marc Brooker no blog de arquitetura da AWS em 2015, sorteia uniformemente entre zero e o valor exponencial:

```text
espera = uniforme(0, min(teto, base × 2^tentativa))
base 0,1 s, teto 2 s:  0–0,1 | 0–0,2 | 0–0,4 | 0–0,8 | 0–1,6 s
```

Nas simulações do artigo, full jitter reduz muito o trabalho total do servidor, porque espalha as tentativas. Sem jitter, o backoff só agenda o próximo ataque.

### Retry storm, ou a multiplicação dos pães, só que de requisições

Uma requisição atravessa três camadas (cliente → API → serviço → banco), e cada camada faz até 3 retries, por segurança. O banco engasga. Cada chamada ao banco vira 4 tentativas; cada chamada ao serviço, que falhou, também vira 4, cada uma com as suas 4 ao banco; e o cliente repete por cima.

```text
amplificação = (1 + retries) ^ camadas = 4 ^ 3 = 64
```

O banco engasgou com 100 consultas por segundo e recebe até 6.400. É a única técnica de recuperação conhecida que mata o paciente com o desfibrilador.

As defesas são duas: repetir **em uma camada só**, e as outras propagam o erro; e um **orçamento de retries** (*retry budget*), que limita as repetições a uma fração das requisições normais, por exemplo 10%. Quando o parceiro piora, o orçamento acaba e os retries param, justamente quando fariam mais estrago. O gRPC implementa isso como *retry throttling*: um balde de tokens que perde um token a cada falha, ganha uma fração de token a cada sucesso e, abaixo da metade, desliga os retries.

## Circuit breaker e bulkhead, ou a arte de largar quem não te merece

Se o adquirente devolve timeout para 80% das chamadas, mandar a próxima é segurar um comprador por segundos para somar carga num parceiro afogado. O **circuit breaker** (disjuntor), popularizado por Michael Nygard em *Release It!*, é uma máquina de três estados em volta da chamada:

```text
           taxa de falha > limiar
 FECHADO ─────────────────────────> ABERTO
    ^                                  │
    │ sondas ok         após um tempo  │
    │                                  v
    └──────────────────────────── MEIO-ABERTO
             sonda falhou → volta para ABERTO
```

**Fechado**, as chamadas passam e o disjuntor conta falhas numa janela deslizante. Passou do limiar (com um mínimo de chamadas, para três falhas às 4h não abrirem o circuito), ele **abre**: as chamadas falham na hora, sem rede. Depois de um intervalo, fica **meio-aberto** e deixa passar poucas sondas; se funcionam, fecha, se falham, abre de novo. Timeout conta como falha, porque lentidão é a falha que mais consome recursos.

Quem chama recebe "não" em microssegundos em vez de "não sei" em segundos, e o parceiro doente para de apanhar e tem chance de se recuperar, uma gentileza rara em sistemas distribuídos e em ex-namorados.

O **bulkhead** (antepara) isola recursos por dependência. Se adquirente e banco do Pix dividem o mesmo semáforo, a lentidão de um ocupa tudo e o outro, saudável, morre de contágio. Com um limite por dependência, o lento esgota só o compartimento dele, e a chamada seguinte falha na hora em vez de entrar numa fila sem fim. O semáforo de 100 por processo do capítulo 13 já era um bulkhead, só que um para tudo, o que faz dele mais condomínio que antepara.

## Deadlines e degradação, ou quanto tempo ainda resta de vida

Timeouts por chamada somam mal. A API dá 2 s ao serviço, o serviço dá 2 s ao Vigia e mais 2 s ao adquirente: a requisição pode levar 4 s, e o cliente desistiu aos 3. O servidor termina tudo com zelo, serializa o JSON com carinho e entrega para um socket fechado. Psicografia: resposta para quem já partiu.

Um **deadline** é um instante absoluto ("responder até t0 + 8 s"); cada etapa usa no máximo o tempo restante. Na rede, propaga-se o **tempo restante**, e não o instante, porque os relógios das máquinas discordam (capítulo 20). O `grpc-timeout` que a Lastro manda ao Vigia (capítulo 12) é exatamente isso. No HTTP não há cabeçalho padrão.

O deadline traz o **cancelamento**: quando o cliente desiste, o trabalho que só existia para ele para. Um servidor ASGI recebe o evento de desconexão, e o asyncio cancela a Task. Cancelar uma consulta ao Vigia é economia; cancelar uma autorização já enviada ao adquirente é impossível.

**Degradação controlada** é decidir antes do incidente o que o sistema faz sem cada dependência: *fail-open* (o antifraude caiu, aprova assim mesmo) ou *fail-closed* (recusa tudo). A certa depende do que custa mais, a fraude que passou ou a venda perdida. O que não pode é a postura ser decidida pelo `except` que o Carlos escreveu às 2h.

## Na Lastro: um "não sei" honesto

O terceiro final ganha nome: a cobrança de cartão tem o estado `processando` (autorização enviada, resultado desconhecido). O enum de estado é aberto desde o capítulo 11, então é mudança aditiva, com 30 dias de changelog. No timeout de leitura, o `POST /v1/cobrancas` responde `201` com `estado: processando`, e o resultado chega por webhook.

Para resolver, a Lastro usa o contrato de integração do adquirente: toda autorização leva uma referência única (o ID da cobrança), e o adquirente permite consultar e **desfazer** por referência. Um processo de resolução consulta cada `processando` com backoff exponencial e full jitter (1 s, 2 s, 4 s, até 60 s):

```text
POST autorização ──timeout de leitura──> cobrança "processando" ──> 201 ao Bazar
                                              │
                         consulta por referência (backoff + jitter)
                 ┌────────────────────────────┼────────────────────────────┐
             aprovada                     negada                inexistente após 5 min
                 │                            │                             │
     "autorizada" + webhook       "recusada" + webhook       desfazimento por referência
                                                                (repetido até confirmar)
                                                                            │
                                                              "recusada" + webhook
```

O ramo da direita existe porque "inexistente" ainda pode ser a explicação 2, a autorização chegando atrasada. O desfazimento, aceito mesmo para referência desconhecida, bloqueia qualquer autorização posterior com a mesma referência e fecha a porta. Consulta e desfazimento são idempotentes por referência, então repeti-los é seguro.

As alternativas para o momento do timeout:

| Opção | Comprador | Bazar | Risco de dinheiro |
|-------|-----------|-------|-------------------|
| Responder `recusada` (sexta) | Limite reservado sem pedido | Cancela pedido | Cobrança sem venda: 412 casos |
| Esperar sem limite | Tela girando até o Bazar desistir (10 s) | Timeout do lado dele | Mesmo "não sei", só que no Bazar |
| `processando` + resolução | Espera segundos a minutos | Trata 1 estado novo | Nenhum: todo caso termina autorizado ou desfeito |

A Lastro fica com a terceira, porque o requisito é dinheiro sem perda nem duplicidade, e ela é a única em que todo resultado desconhecido termina num estado conhecido. Sem consulta e desfazimento por referência no adquirente, a saída honesta seria esperar o máximo possível e deixar os desconhecidos para a conciliação diária (capítulo 18).

O fluxo de autorização ganha **deadline de 8 s** a partir da chegada no proxy, abaixo dos 10 s em que o Bazar desiste (capítulo 13):

```text
t0 ── validação + tx1 ── Vigia: min(120 ms, restante) ── adquirente: restante − 300 ms ── tx2 + resposta
                                                                                     (reserva de 300 ms)
```

O adquirente recebe cerca de 7,5 s, bem acima do p99,9 saudável dele (perto de 2,7 s no histograma por etapa do capítulo 14). Na sexta, com p99 de 4 s, quase todas as autorizações teriam só demorado. A Lastro estouraria o p99 do contrato e pagaria a multa da cláusula 7.2, um número com vírgula. Os 412 compradores custaram uma planilha, três dias do financeiro e uma reunião em que o Bazar disse "confiança" onze vezes. Entre violar um percentil e mentir sobre dinheiro, o runbook agora escolhe o percentil.

Conexão ao adquirente: 500 ms, com um retry, porque nada foi enviado. Leitura: nunca repetida.

Bulkheads por parceiro, por processo: adquirente 100, Vigia 50, banco do Pix 30. Com o do adquirente cheio, a cobrança falha na hora com `503`, `Retry-After: 2` e o erro RFC 9457 `adquirente-indisponivel`, sem enviar nada. Pela Lei de Little, 9 processos × 100 slots = 900 em andamento; com o adquirente travado em 7,5 s, isso sustenta 120 autorizações por segundo, o dobro do pico. Acima disso, a fila só aumentaria a espera de quem já não vai ser atendido a tempo.

O circuit breaker é **por parceiro e por processo**: abre com mais de 50% de falhas (timeouts incluídos) numa janela de 10 s com pelo menos 20 chamadas, fica aberto 5 s e sonda com 3. Aberto, o marketplace recebe o mesmo `503` sem chamada nenhuma ao adquirente. Cada um dos 9 processos aprende sozinho: até 9 × 20 chamadas provam o parceiro doente antes de todos abrirem, em troca de não depender de um estado compartilhado que também pode falhar.

O Vigia ganha degradação definida: com timeout de 120 ms ou circuito aberto, cobranças de até R$ 300,00 seguem com as regras locais (limite por cartão em 24 h, no PostgreSQL) e as acima são recusadas com motivo `antifraude_indisponivel`. Fail-open embaixo, fail-closed em cima, fronteira no runbook, com data e sem o Carlos.

Retries só na resolução e nos timeouts de conexão, com orçamento de 10% por parceiro. O guia de integração pede que o cliente espere pelo menos 10 s.

## Armadilhas e casos reais

> **Na vida real:** em 20 de setembro de 2015, o DynamoDB em us-east-1 passou quase cinco horas com erros altos. Os servidores de armazenamento renovam periodicamente com um serviço de metadados a lista das partições que lhes cabem; os índices secundários globais tinham engordado essas listas, e depois de uma breve falha de rede as respostas passaram do tempo-limite. Quem não renovava parava de atender e tentava de novo, o serviço de metadados ficava mais lento, e os servidores saudáveis também falhavam. A AWS teve de pausar os pedidos de metadados para conseguir acrescentar capacidade. Um componente ficou lento, e o sistema inteiro decidiu ajudá-lo até a morte.

> **Armadilha:** retry em cima de retry. O Carlos pôs `@retry(tentativas=5)` na função que chama o banco do Pix, cujo cliente HTTP já repete 3 vezes. Quinze tentativas por chamada, e o banco parceiro abriu um chamado perguntando se a Lastro estava bem.

> **Armadilha:** timeout da aplicação maior que o do proxy. O proxy corta em 60 s (capítulo 12); um timeout de 90 s na aplicação nunca dispara, e o marketplace recebe um `504` que nenhum código trata como "não sei".

> **Armadilha:** health check que mede a vida do processo e ignora a do parceiro. Na sexta, os 9 processos respondiam `200` no `/saude` e "recusada" no `/v1/cobrancas`. Falha cinzenta de manual, e o Bazar soube antes, de novo.

A mais cara: o circuit breaker que conta recusa como falha. Uma recusa do emissor é o adquirente funcionando, rápido. Contar recusas abre o circuito numa noite de muita fraude, que é quando você mais precisa do adquirente, e só se descobre no postmortem, a autópsia em que o morto é você.

## Resumo

- Chamada remota tem três finais: sucesso, falha e desconhecido; timeout de leitura cai no terceiro.
- Falhas: crash, omissão, tempo, bizantina; a cinzenta engana o monitoramento.
- Timeout acima da cauda saudável do parceiro e abaixo da paciência de quem chamou; Little dá o custo de esperar.
- Retry só sem efeito comprovado ou com operação idempotente; backoff exponencial com jitter, uma camada, orçamento.
- Circuit breaker falha rápido e poupa o parceiro; bulkhead isola recursos por dependência.
- Deadline propagado como tempo restante, com cancelamento; degradação decidida antes do incidente.

## A Lastro agora

A cobrança de cartão tem um estado para "não sei", `processando`, resolvido por consulta e desfazimento por referência. A autorização tem deadline de 8 s, conexão de 500 ms com um retry, leitura nunca repetida, bulkheads por parceiro (100, 50, 30), circuit breaker por parceiro e processo, orçamento de retries de 10% e o Vigia degradando em R$ 300,00. A `bf_desfazer_FINAL.xlsx` foi arquivada ao lado da planilha de conciliação, que ganhou uma irmã mais nova e igualmente mais confiável que o sistema.

A consultoria Java do Bazar leu o guia e implementou exatamente o que este capítulo ensina: timeout de 10 s, três retries, backoff exponencial, full jitter, uma obra de arte. No `POST /v1/cobrancas`. Na terça em que a Lastro levou 7,8 s e o pool de conexões do próprio Bazar somou mais 2,6, a Lastro criou a cobrança, o Bazar desistiu, tentou de novo com elegância estatística, e o comprador pagou duas vezes, com jitter.

## Referências

- Michael T. Nygard, *Release It! Design and Deploy Production-Ready Software*, 2ª ed., Pragmatic Bookshelf, 2018.
- Marc Brooker, "Exponential Backoff And Jitter", AWS Architecture Blog, 2015: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
- Peng Huang et al., "Gray Failure: The Achilles' Heel of Cloud-Scale Systems", HotOS 2017.
- Martin Fowler, "CircuitBreaker": https://martinfowler.com/bliki/CircuitBreaker.html
- gRPC, "Deadlines": https://grpc.io/docs/guides/deadlines/
- gRPC, "Retry" (retry throttling): https://grpc.io/docs/guides/retry/
- AWS, "Summary of the Amazon DynamoDB Service Disruption and Related Impacts in the US-East Region" (setembro de 2015): https://aws.amazon.com/message/5467D2/
- Requests, "Timeouts": https://requests.readthedocs.io/en/latest/user/advanced/#timeouts
- HTTPX, "Timeouts": https://www.python-httpx.org/advanced/timeouts/
