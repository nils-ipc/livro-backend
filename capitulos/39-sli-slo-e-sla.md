# SLI, SLO e SLA

## O anexo 3, ou como um nove a mais virou cláusula de multa

O contrato definitivo do Tuiuiú chegou com 84 páginas, e o gerente de produto respondeu "de acordo" em onze minutos, ou seja, leu o assunto do e-mail e a assinatura.

Na página 61 mora o anexo 3: disponibilidade mensal mínima de 99,99%, multa de 10% da mensalidade abaixo disso, 25% abaixo de 99,9% e 50% abaixo de 99,5%. O gerente justificou: "a gente já tem 99,9, é só um nove a mais". Ninguém sabia de onde saiu o 99,9. Estava no slide de vendas desde 2023, ao lado da foto de um homem apertando a mão de um servidor.

A migração do Tuiuiú termina em seis semanas, e o jurídico dele quer saber qual foi a disponibilidade da Lastro no mês passado. O Carlos respondeu "100%", porque nenhum Deployment ficou com zero réplicas. O fundador respondeu "o temp-01 ficou seis anos no ar", frase que só se diz em velório. O financeiro abriu uma aba nova chamada "SLA" e já calculou a multa.

Você foi aos contadores da borda (capítulo 38). Contando como falha todo `5xx` e toda requisição sem resposta no gateway, os últimos três meses deram 99,971%, 99,938% e 99,989%. Com o anexo 3 como está, multa nos três. A Lastro viraria uma empresa que fatura o Tuiuiú e devolve 10% por esporte.

O que a Lastro deve medir, quanto pode prometer, e como saber, numa terça às 15h, que está gastando a indisponibilidade que não tem?

## Três siglas, três níveis de compromisso

O mercado usa as três siglas como sinônimos, do mesmo jeito que usa "deploy na sexta" como sinônimo de "fim de semana livre".

O **SLI** (*service level indicator*) é uma medição de um aspecto do serviço visto pelo usuário. A forma mais útil é a razão entre eventos bons e válidos:

```text
SLI = eventos bons / eventos válidos

ex.: requisições POST /v1/cobrancas respondidas sem 5xx
     ------------------------------------------------  = 0,99971
     requisições POST /v1/cobrancas válidas
```

O **SLO** (*service level objective*) é uma meta para um SLI numa janela: "99,97% das autorizações sem `5xx`, nos últimos 30 dias". É uma promessa que você faz a si mesmo, sem advogado. O **SLA** (*service level agreement*) é um contrato: um SLO, uma regra de medição aceita pelas duas partes e uma consequência financeira. Se ninguém paga nada quando a meta falha, você tem um SLO, por mais que o slide diga SLA.

O SLO precisa ser mais rígido que o SLA: é o alarme que toca antes da multa. SLO igual ao SLA é detector de fumaça que dispara quando a casa termina de queimar.

### O que é um evento bom

**Válido** decide o denominador. Um `422` por JSON malformado foi culpa do cliente e fica fora; um `429` por limite de taxa (capítulo 28) também. Um `503` do load shedding entra, como ruim: a Lastro descartou a requisição do comprador para salvar outras. Load shedding salva o sistema e gasta orçamento, as duas coisas ao mesmo tempo.

**Bom** decide o numerador. Latência se escreve como proporção, "respostas em até 1,5 s / respostas válidas", em vez de "p99 < 1,5 s". As duas dizem o mesmo, mas a proporção soma entre processos e minutos, e percentil não soma. Média de percentil, como no capítulo 14, tem alma de horóscopo.

Os tipos de SLI que cobrem quase todo backend:

| Tipo | Evento bom | Exemplo |
|------|-----------|---------|
| Disponibilidade | resposta sem falha do servidor | `POST` sem `5xx` |
| Latência | resposta abaixo do limite | resposta final em ≤ 1,5 s |
| Qualidade | resposta completa, sem degradação | autorização avaliada com todos os sinais |
| Frescor | dado atualizado dentro do prazo | webhook iniciado ≤ 10 s após o pagamento |
| Correção | resultado certo | lançamento confere com o arquivo do adquirente |
| Durabilidade | dado gravado continua legível | lançamento confirmado sobrevive a falha |

A linha de qualidade existe por causa da sexta-feira do capítulo 38: zero `5xx`, gráficos verdes, aprovação despencando. A disponibilidade deu nota 10 a um serviço que recusava cliente bom por falta de memória no Redis. O SLI mede o que você mandou medir, com o zelo de um fiscal que confere se a obra tem porta e nunca abre a porta.

### Onde medir

No **servidor**, você tem detalhe e não vê o que morreu antes dele: o balanceador que derrubou a conexão, o certificado vencido. Na **borda** (gateway), você vê tudo que chegou, inclusive o que nenhum pod respondeu. No **cliente**, vê a experiência inteira e não controla nada. Na **sonda sintética**, um robô de fora faz uma requisição conhecida a cada tantos segundos.

Agora o bit do capítulo 10. Domingo, 3h12, certificado expirado, nenhum handshake completa. O gateway não recebe requisição HTTP nenhuma, logo não registra falha nenhuma:

```text
eventos válidos:  0
eventos bons:     0
SLI:              0 / 0  -> o painel mostra "sem dados", ou pior, 100%
```

Duas horas e 35 minutos fora do ar, e o SLI tranquilo: é a disponibilidade do morto, zero reclamações, 100% de satisfação no túmulo. Por isso o SLI por requisição precisa de uma sonda externa medida por tempo, em que cada tentativa falha conta como intervalo ruim.

## Os noves, ou quanto tempo você pode passar morto por mês

Uma meta em noves é o tempo fora que a janela tolera, escrito de forma curta:

| Meta | Indisponível em 30 dias | Indisponível por ano |
|------|------------------------|----------------------|
| 99% | 7,2 h | 3,65 dias |
| 99,9% | 43,2 min | 8,76 h |
| 99,95% | 21,6 min | 4,38 h |
| 99,97% | ~13 min | ~2,6 h |
| 99,99% | 4,32 min | 52,6 min |
| 99,999% | ~26 s | ~5,3 min |

Cada nove divide o orçamento por dez. Isso é aritmética, e é a aritmética mais cruel do livro.

Cinco noves dão 26 segundos por mês. O failover do Patroni no ledger leva de 30 a 40 s (capítulo 23). Uma falha de máquina, tratada com perfeição, estoura o mês. Cinco noves exigem que o primário nunca morra, requisito que só o temp-01 cumpriu, e por teimosia.

Quatro noves dão 4 minutos e 19 segundos: um rolling update torto que leva três minutos para voltar consome 70% do mês. O "só um nove a mais" do gerente é um corte de 90% no tempo que a Lastro tem para errar, vendido como adesivo novo no notebook.

### Dependências cobram juros

Serviços em série multiplicam disponibilidades (capítulo 26). Se o adquirente entrega 99,9% no mês, a autorização da Lastro não passa disso, por mais noves que tenha por dentro. Prometer 99,99% sobre uma dependência de 99,9% é assinar a multa de outra empresa com a sua caneta.

As saídas custam. Degradar sem a dependência (o antifraude abaixo de R$ 300,00, capítulo 15) troca falha por qualidade menor. Dois adquirentes em paralelo (`1 − 0,001²`) dobram integração e conciliação. Excluir a dependência do SLA protege o caixa e nada muda para o comprador cujo cartão não passou. O comprador não lê o anexo 3.

## Error budget, ou a licença para quebrar

Com meta de 99,97%, os 0,03% restantes são o **error budget** (orçamento de erro): os eventos ruins que a janela aceita. Com uns 50 milhões de cobranças por mês, 15 mil eventos ruins, ou 13 minutos de indisponibilidade total.

Com orçamento, um incidente vira gasto com valor: aquele failover consumiu 4% do mês, aquele deploy ruim, 30%. Serviço que termina todo mês com 95% sobrando tem meta frouxa ou muda devagar demais. E o orçamento tem uso automático: o canary (capítulo 37) pode alongar os degraus quando ele está curto. O sistema passa a ter medo proporcional ao histórico recente, mais maturidade emocional do que boa parte da profissão alcança.

A janela pode ser **de calendário** (zera no dia 1º) ou **deslizante** (os últimos 30 dias). Contratos usam calendário, porque a fatura é mensal. SLOs internos usam a deslizante, porque o calendário é estúpido: no dia 29, com orçamento sobrando, todo risco parece barato, e no dia 1º o passado é perdoado como promessa de ano-novo de entrar na academia.

## Alertas por burn rate

O alerta ingênuo é "erro acima de 0,03% por 5 minutos, acorda alguém". Um pico de 0,05% por 5 minutos gasta quase nada do mês e acorda alguém às 3h; um vazamento de 0,02% nunca dispara e come 67% do orçamento em silêncio, até o jurídico do Tuiuiú perguntar.

A métrica certa é a **taxa de consumo** (*burn rate*): quão rápido o orçamento está sendo gasto em relação ao ritmo que o esgotaria exatamente no fim da janela.

```text
burn rate = taxa de erro observada / (1 − SLO)

SLO 99,97%  ->  orçamento 0,03%
taxa de erro 0,03%  -> burn rate 1    (acaba em 30 dias, no limite)
taxa de erro 0,432% -> burn rate 14,4 (acaba em ~50 horas)

tempo até esgotar = janela / burn rate
fração gasta em t = burn rate × t / janela
```

O livro de exercícios de SRE da Google propõe um ponto de partida para 30 dias: chamar alguém se 2% do orçamento sumir em 1 hora (burn rate 14,4) ou 5% em 6 horas (burn rate 6), e abrir chamado sem acordar ninguém se 10% sumirem em 3 dias (burn rate 1). Confere: 2% de 720 horas em 1 hora dá 14,4.

Uma janela só demora a esquecer: depois de um pico de 10 minutos resolvido, a de 1 hora fica acima do limiar por mais 50 minutos, gritando sobre um incidente que já virou ata. A correção é exigir também uma janela curta de 1/12 da longa (5 minutos para 1 hora, 30 para 6 horas). A longa prova que o gasto é relevante; a curta, que ainda está acontecendo. Em PromQL, com nomes genéricos:

```text
(
  sum(rate(http_requests_total{rota="criar_cobranca", status=~"5.."}[1h]))
  / sum(rate(http_requests_total{rota="criar_cobranca"}[1h]))
) / (1 - 0.9997) > 14.4
and
(
  sum(rate(http_requests_total{rota="criar_cobranca", status=~"5.."}[5m]))
  / sum(rate(http_requests_total{rota="criar_cobranca"}[5m]))
) / (1 - 0.9997) > 14.4
```

No incidente do capítulo 35, 100% de falha no Pix por 6 minutos, a janela de 1 hora cruza 0,432% em uns 16 segundos e o alerta sai em menos de um minuto. Naquela noite, quem avisou foi o Bazar. Um vazamento de 0,2% (burn rate 6,7) dispara o alerta de 6 horas em cerca de 5,4 horas, com 5% do orçamento gasto e o mês intacto.

Tráfego baixo engana: às 4h, com 30 requisições em 5 minutos, uma falha é burn rate 111, e o plantonista acorda por um comprador insone. Pouco volume pede mínimo de eventos por janela e sonda para o resto.

## Na Lastro: o que medir, quanto prometer

### Os SLIs

O SLI é calculado no gateway, que já exporta contadores RED e o histograma do capítulo 38, com a sonda por fora.

| SLI | Válidos | Bom | SLO (30 dias deslizantes) |
|-----|---------|-----|---------------------------|
| Autorização: disponibilidade | `POST /v1/cobrancas` cartão, exceto 4xx de cliente e `429` | sem `5xx`, com resposta | 99,97% |
| Autorização: latência | as mesmas, respondidas | estado final em ≤ 1,5 s (`processando` conta como ruim) | 99% |
| Autorização: qualidade | autorizações avaliadas | antifraude respondeu com todos os sinais | 99,9% |
| Criação de Pix | `POST /v1/cobrancas` Pix | sem `5xx`, em ≤ 500 ms | 99,97% |
| Notificação do banco | `POST` em `webhooks-pix` | `2xx` em ≤ 1 s | 99,97% |
| Webhook aos marketplaces | eventos de cobrança | 1ª tentativa iniciada em ≤ 10 s do COMMIT | 99,9% |
| Consultas | `GET /v1/cobrancas/{id}` | sem `5xx`, em ≤ 300 ms | 99,95% |
| Sonda externa | tentativas a cada 30 s | sucesso | 99,95% |

Recusa do emissor é evento bom: o comprador é que não tinha limite. Avaliação sem sinais é ruim no SLI de qualidade, que lê o `antifraude_sinais_ausentes_total` do capítulo 38. A sexta do Vigia cego teria queimado esse orçamento em 40 minutos, e o alerta sairia antes do Bazar. O Bazar segue a sonda sintética mais confiável do país, mas agora tem concorrência.

O webhook mede o início da entrega, e não o `2xx` do marketplace: o endpoint do Hornero de 25 s (capítulo 17) é problema do Hornero.

A sonda roda em dois provedores fora da rede da Lastro, cria um Pix de R$ 1,00 no marketplace Lastro Interna (capítulo 37) e o consulta, pegando DNS, TLS, balanceador, gateway e banco de uma vez. O certificado do capítulo 10 viraria alerta no primeiro minuto, e o financeiro teria dormido um domingo, coisa que neste livro aconteceu uma vez.

O Tuiuiú tem SLIs próprios, filtrados por `marketplace_id`; os outros 41 marketplaces entram no agregado, somando bons e válidos, nunca tirando média.

### SLO interno e SLA do contrato

A contraproposta saiu dos três meses medidos:

```text
              medido      99,99%      99,95%
mês 1        99,971%     multa       ok
mês 2        99,938%     multa       multa (10%)
mês 3        99,989%     multa       ok

orçamento:   99,95% -> 21,6 min/mês     SLO interno 99,97% -> ~13 min
```

O SLA ficou em 99,95% mensal de calendário para criação e consulta de cobranças: um minuto é indisponível se mais de 5% das requisições válidas do Tuiuiú falharam na borda ou se a sonda falhou duas vezes seguidas. Latência: 99% das autorizações com estado final em até 2 s. Multa de 10% abaixo de 99,95%, 25% abaixo de 99,9% e 50% abaixo de 99,5%. Ficam fora as falhas de adquirente e banco do Pix comprovadas por relatório do parceiro. A Lastro abriu mão da exclusão por manutenção programada, porque não faz manutenção programada (o Pix é 24x7, e a equipe também, contra a vontade de todos).

O SLO interno é mais rígido em tudo: 99,97% contra 99,95%, 1,5 s contra 2 s, janela deslizante, sem exclusão de parceiro. Quando ele esgota, sobram uns 9 minutos antes da multa. Adquirente fora do ar gasta o orçamento interno, porque o comprador que não pagou não quer saber de quem foi a culpa. Os alertas carregam o rótulo `causa`, para o plantonista saber às 3h se o problema é dele ou do adquirente. Muda o tom do palavrão.

### Alertas e orçamento

Cada SLO ganhou as três regras de burn rate (14,4 em 1 h e 5 min; 6 em 6 h e 30 min; 1 em 3 dias e 6 h), avaliadas a cada 30 s, com mínimo de 100 eventos na janela curta; abaixo disso, vale a sonda. Alertas de limiar fixo foram apagados; os de causa do capítulo 38 viraram chamado, sem acordar ninguém.

O canary de pagamentos lê o orçamento da autorização antes de cada degrau. Abaixo de 25%, cada degrau dura o dobro, inclusive nas flags de regra de dinheiro. Abaixo de zero, a promoção automática para; o rollback segue liberado, porque devolve orçamento.

## Armadilhas e casos reais

> **Armadilha:** SLO de 100%. Orçamento zero faz de todo deploy uma violação, e o único jeito de cumprir é nunca mudar nada, o plano de carreira do temp-01. O livro de SRE da Google observa que o usuário chega por celular, rede doméstica e provedor de internet, todos bem menos confiáveis que cinco noves: acima de certo ponto, ele não percebe a diferença, e você paga por ela.

> **Na vida real:** o mesmo livro conta o caso do Chubby, o serviço de locks distribuídos da Google. A instância global era tão estável que equipes passaram a depender dela contando que nunca caísse. Nos trimestres em que a disponibilidade real ficava muito acima da meta, a equipe de SRE a derrubava de propósito, para gastar o orçamento e expor quem dependia do impossível. O único lugar do mundo onde sobrar orçamento é tratado como incidente.

O medidor dentro do medido é o erro clássico. Em 28 de fevereiro de 2017, um comando com parâmetro digitado errado removeu servidores demais no Amazon S3 da região us-east-1, fora do ar por cerca de quatro horas, e o painel de status da própria AWS não conseguia mostrar a falha, porque dependia do S3. Por isso a sonda da Lastro roda fora, contra o desejo do Carlos de hospedá-la "no cluster, que é mais barato".

- **SLI que mede a coisa errada.** O "100%" do Carlos media pods vivos. Pod vivo atrás de certificado vencido atende o mesmo número de clientes que pod morto.
- **SLA mais rígido que o SLO.** A multa chega antes do alarme. Era o que o "de acordo" de onze minutos teria produzido.
- **Contrato sem regra de medição.** "99,95%" sem fonte vira duas planilhas brigando. O anexo 3 revisado diz que a fonte é a borda mais a sonda, contestável em 15 dias. O financeiro já criou a aba de contestação.

## Resumo

- SLI é medição (bons sobre válidos), SLO é a meta interna numa janela, SLA é o contrato com consequência financeira.
- `4xx` de cliente e `429` saem do denominador; load shedding entra como ruim; latência vira proporção abaixo de um limite.
- Borda, servidor, cliente e sonda veem falhas diferentes; SLI por requisição é cego quando nada chega.
- Cada nove divide por dez o tempo tolerado; dependências em série limitam os noves.
- Error budget = 1 − SLO; janela deslizante para operar, calendário para contrato.
- Burn rate = erro / (1 − SLO); alertas em duas janelas (14,4 em 1 h, 6 em 6 h, 1 em 3 dias).
- O SLO interno é mais rígido que o SLA e não exclui o que o contrato exclui.

## A Lastro agora

A Lastro tem oito SLIs medidos na borda e uma sonda externa que cria um Pix de R$ 1,00 no Lastro Interna a cada 30 segundos. Os SLOs internos são 99,97% para autorização, Pix e notificações do banco, 99% de autorizações finalizadas em 1,5 s e 99,9% com sinais completos do antifraude, em janela deslizante de 30 dias, com alertas por burn rate. O Tuiuiú assinou SLA de 99,95% mensal, com exclusão de falha comprovada de parceiro e multa de 10%, 25% e 50%. O canary lê o orçamento antes de cada degrau. O gerente aprendeu que "um nove a mais" é 90% a menos, e pediu a estimativa do décimo nove em horas.

São 13 minutos de orçamento por mês, e o financeiro reservou uma linha da planilha para cada um. Nenhum deles cobre a API respondendo `200` com perfeição sobre uma tabela de contas destruída. Treze minutos dão para muita coisa, menos para restaurar um banco depois de um `UPDATE` sem `WHERE`, e menos ainda se, no mesmo mês, a região inteira resolver tirar folga junto.

## Referências

- Beyer, B. et al. *Site Reliability Engineering*, capítulo 3, "Embracing Risk". Google, 2016. <https://sre.google/sre-book/embracing-risk/>
- Beyer, B. et al. *Site Reliability Engineering*, capítulo 4, "Service Level Objectives" (inclui o caso do Chubby). Google, 2016. <https://sre.google/sre-book/service-level-objectives/>
- Beyer, B. et al. *The Site Reliability Workbook*, "Implementing SLOs". Google, 2018. <https://sre.google/workbook/implementing-slos/>
- Beyer, B. et al. *The Site Reliability Workbook*, "Alerting on SLOs". Google, 2018. <https://sre.google/workbook/alerting-on-slos/>
- AWS. "Summary of the Amazon S3 Service Disruption in the Northern Virginia (US-EAST-1) Region", março de 2017. <https://aws.amazon.com/message/41926/>
