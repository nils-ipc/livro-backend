# SLI, SLO e SLA

## Cinco noves e um banco que tira folga aos domingos

O diretor comercial da confeitaria Doce Prazo, Seu Teodoro, voltou da reunião com a maior rede de bufês da cidade segurando um contrato assinado. A cláusula 7.2 dizia: "A plataforma de encomendas terá disponibilidade de 99,999%". Ele escolheu o número porque cinco noves soavam mais confiáveis que quatro.

A plataforma roda num único PostgreSQL, numa única zona, com 30 minutos de manutenção todo domingo às 2h. Só essa janela soma 26 horas por ano. Cinco noves permitem 5 minutos e 15 segundos por ano. A confeitaria estourou a meta anual no primeiro domingo de janeiro, às 2h05, enquanto todo mundo dormia, inclusive o banco.

O painel do time mostrava "uptime 100%" havia onze meses. Ele media o `GET /health`, que devolve `200` com o banco fora do ar, porque ninguém pensou em perguntar ao banco se ele estava lá.

Ficam três perguntas em cima da mesa, ao lado do bolo de brigadeiro que veio com o contrato. O que se mede quando alguém diz "disponibilidade"? Que número dá para prometer? E em que momento alguém precisa ser acordado às 3h da manhã?

## Três siglas para três coisas diferentes

As definições vêm do livro de SRE do Google (*Site Reliability Engineering*, 2016).

Um **SLI** (*service level indicator*, indicador de nível de serviço) é uma medida quantitativa de algum aspecto do serviço que o usuário percebe. A forma mais útil é uma razão:

```text
SLI = eventos bons / eventos válidos
```

O resultado fica entre 0 e 1, e "mais alto" é sempre melhor. "98,8% das requisições de encomenda terminaram sem erro do servidor em até 400 ms" é um SLI.

Um **SLO** (*service level objective*, objetivo de nível de serviço) é uma meta para um SLI ao longo de uma janela: "o SLI de encomendas fica em 99,9% ou mais nos últimos 28 dias". Indicador, valor-alvo e janela são obrigatórios. Sem a janela, "99,9% de disponibilidade" aceita qualquer interpretação, inclusive a do Seu Teodoro.

Um **SLA** (*service level agreement*, acordo de nível de serviço) é um contrato com consequência: crédito na fatura, multa, rescisão. Sem consequência escrita, o documento é um SLO publicado.

O SLA fica mais frouxo que o SLO interno. Se o time persegue 99,95% e o contrato promete 99,9%, existe uma faixa em que o alarme toca antes de a multa chegar. Quem inverte essa ordem descobre que violou o contrato pelo e-mail do cliente.

> **Armadilha:** no uso corrente, "SLA" virou sinônimo de qualquer meta. A distinção importa porque muda o que acontece na falha: um SLO violado gera uma conversa técnica; um SLA violado gera uma nota de crédito e, às vezes, um advogado.

## Como medir um SLI, ou quem decide o que é uma requisição boa

A razão `bons / válidos` parece simples até alguém precisar escrever as duas funções.

**Válido** define o denominador. Health checks e scrapes de métricas ficam de fora, senão o balanceador que pergunta "você está vivo?" a cada segundo vira o usuário mais fiel do serviço, com 86.400 sucessos por dia.

**Bom** define o numerador e costuma combinar disponibilidade e latência:

- `5xx` é ruim: o erro é do servidor.
- `4xx` em geral é bom: um `404` para um bolo que não existe no catálogo significa que o catálogo funciona.
- `429` pede decisão. Se quem recusa é o limitador do próprio serviço, por falta de capacidade, o usuário ficou sem a encomenda e a requisição conta contra o serviço (o capítulo 28 trata de controle de carga).
- Um `201` que levou 2,3 segundos funcionou. Para quem clicou de novo em "Confirmar encomenda" porque nada aconteceu, falhou (e talvez tenha gerado dois bolos).

Por isso o SLI de latência se escreve como "proporção de requisições abaixo de 400 ms". A razão soma entre instâncias e janelas; percentis não somam (o capítulo 6 mostra por quê).

### Onde medir

O ponto de medição decide quais falhas o SLI enxerga:

| Ponto de medição | Enxerga | Não enxerga |
|---|---|---|
| Logs e métricas da aplicação | Erros e latência dentro do processo | Processo morto, balanceador fora, DNS errado, fila no proxy |
| Balanceador ou API gateway | Tudo que chega ao balanceador, inclusive backend fora | DNS, TLS no cliente, rede do usuário |
| Sonda sintética externa | Caminho completo, de fora para dentro | Variedade real de rotas e de dados; tráfego baixo e fixo |
| Instrumentação no cliente (navegador, app) | Experiência real, inclusive rede móvel | Muito ruído alheio ao serviço (túnel, elevador, operadora) |

Um processo morto não registra a própria morte. Ele para de emitir, e uma razão calculada só com os dados dele continua impecável, porque ninguém reprova com zero requisições. Por isso o SLI de disponibilidade costuma ser medido no balanceador, que registra o `502` quando o backend sumiu.

### Por requisição ou por tempo

O SLI **baseado em requisições** conta eventos. O **baseado em tempo** divide a janela em intervalos (de um ou cinco minutos) e classifica cada um como bom ou ruim, por exemplo "taxa de erro abaixo de 1%". O primeiro pesa a falha pelo número de pessoas afetadas: 10 minutos fora às 19h de sexta, quando todo bufê fecha encomenda, custam muito mais que 10 minutos às 4h. O segundo trata os dois apagões igualmente e responde "quantos minutos o serviço ficou inutilizável?".

## Os noves e quanto cada um permite em minutos

Metas se descrevem em "noves" (99,9% são três), e o tempo permitido de indisponibilidade é `(1 − SLO) × janela`.

| SLO | Por ano (365 dias) | Por 30 dias | Por semana |
|---|---|---|---|
| 99% | 3,65 dias | 7,2 h | 1,68 h |
| 99,5% | 43,8 h | 3,6 h | 50,4 min |
| 99,9% | 8,76 h | 43,2 min | 10,1 min |
| 99,95% | 4,38 h | 21,6 min | 5,04 min |
| 99,99% | 52,6 min | 4,32 min | 60,5 s |
| 99,999% | 5,26 min | 25,9 s | 6,05 s |

Cada nove adicional divide o tempo permitido por 10. Com 99,99% em 30 dias, o serviço tem 4 minutos e 19 segundos para errar; se o alerta leva 5 minutos para disparar, a meta foi perdida antes de o celular vibrar. Com 99,999%, sobram 25,9 segundos, que um rolling update com readiness probe mal configurada consome enquanto alguém ainda digita `kubectl rollout undo`.

Muitos times usam 28 dias móveis em vez de 30: toda janela contém o mesmo número de fins de semana, e o tráfego de uma confeitaria numa terça não se parece com o de um sábado de festa junina.

Dois limites externos restringem o número. O primeiro é a composição: dependências em série multiplicam disponibilidades, e cinco de 99,9% resultam em no máximo 99,5% (o capítulo 26 detalha a conta). A cláusula 7.2 roda sobre uma máquina virtual numa única zona, para a qual nenhum provedor promete cinco noves, então a promessa já nasceu devendo. O segundo é o usuário: o livro de SRE do Google observa que celular, Wi-Fi e operadora falham bem mais que 0,001% do tempo, e quem está no elevador não distingue 99,99% de 99,999%.

## Error budget, ou quanto o serviço tem direito de errar

O complemento do SLO é o **error budget** (orçamento de erro): com SLO de 99,9%, 0,1% dos eventos válidos da janela. Com 12.960.000 requisições esperadas em 30 dias, são 12.960 requisições ruins, um saldo que pode ser contado e acompanhado num gráfico que desce ao longo do mês.

Confiabilidade vira recurso com saldo. Deploy com 0,5% de erro por 20 minutos, manutenção e failover saem da mesma conta, e "dá para migrar na terça às 15h?" ganha resposta numérica em vez de um "acho que sim" nervoso.

O orçamento também trabalha no sentido oposto. Um serviço muito acima do SLO por meses ensina aos clientes uma confiabilidade que ninguém prometeu, e eles passam a depender dela sem retry nem fallback. No dia em que o serviço cai para o valor prometido, ainda dentro do contrato, os clientes quebram.

> **Na vida real:** o livro de SRE do Google conta o caso do Chubby, o serviço interno de locks distribuídos. A instância global ficava tão acima do SLO que outros serviços passaram a tratá-la como infalível. O time passou a garantir que o Chubby cumprisse o SLO sem ultrapassá-lo muito: num trimestre sem falha real suficiente para levar a disponibilidade abaixo da meta, provocava uma interrupção controlada, desligando o serviço de propósito para expor as dependências indevidas. Poucos times têm a chance de derrubar a produção por excesso de qualidade.

## Burn rate, ou a que velocidade o orçamento vai embora

O saldo resolve o relatório mensal. Para decidir quando acordar alguém, falta a derivada. O **burn rate** (taxa de consumo) é a taxa de erro observada dividida pela permitida:

```text
burn rate = taxa de erro observada / (1 − SLO)
```

Com SLO de 99,9%, erro de 0,1% é burn rate 1: o orçamento acaba no último segundo da janela. Burn rate 1.000 (100% de erro) esgota 30 dias de orçamento em 43 minutos e 12 segundos, o tempo de assar um pão de ló.

A fração do orçamento consumida por um período de burn rate constante sai da mesma conta:

```text
fração consumida = burn rate × duração / janela do SLO
```

Uma hora a burn rate 14,4 consome `14,4 × 1 / 720 = 2%` do orçamento de 30 dias.

### Por que o alerta óbvio falha

A primeira ideia é alertar quando a taxa de erro dos últimos 5 minutos passar de 0,1%. Um deploy com 0,2% de erros por 5 minutos dispara a página e consome `2 × 5 / 43.200 ≈ 0,02%` do orçamento. Quem acordou às 3h17 vê o gráfico voltar ao normal sozinho e silencia o alerta para sempre. Três anos depois, ele ainda estará silenciado.

A segunda ideia é olhar as últimas 36 horas. Esse alerta é preciso e lento: um serviço inteiramente fora do ar leva horas para mover a média, e a página chega depois do orçamento do mês e da paciência do cliente.

### Janelas múltiplas e taxas múltiplas

O *SRE Workbook* do Google descreve a solução que virou padrão: burn rate com duas janelas por alerta. A janela longa garante que o problema consumiu uma fração relevante do orçamento; a curta, de 1/12 da longa, garante que ele ainda está acontecendo. Sem ela, um alerta de uma hora fica disparado por até uma hora depois do fim do problema, e o plantão investiga um incidente que já virou passado.

A configuração recomendada para SLO de 30 dias:

| Severidade | Janela longa | Janela curta | Burn rate | Orçamento consumido ao disparar |
|---|---|---|---|---|
| Página | 1 h | 5 min | 14,4 | 2% |
| Página | 6 h | 30 min | 6 | 5% |
| Ticket | 3 dias | 6 h | 1 | 10% |

O alerta só dispara quando as duas janelas passam do limiar. Uma falha total leva a janela de 1 hora a `14,4 × 0,1% = 1,44%` de erro em menos de um minuto. Um vazamento lento a 0,2% nunca acorda ninguém, mas abre um ticket antes de o mês terminar devendo.

### Pouco tráfego, muito drama

Burn rate precisa de amostra. Num endpoint com 10 requisições por hora, um único `500`, causado por alguém que colou um emoji no campo de CEP, vira burn rate 100 e uma página de madrugada. As saídas conhecidas são agrupar serviços pequenos num SLO comum, gerar tráfego sintético, exigir um número mínimo de eventos ruins ou alongar as janelas, sempre trocando falso positivo por atraso de detecção.

## Na prática

Este código aplica as definições a um lote de requisições da Doce Prazo e compara com o "uptime" do painel antigo:

```python
from dataclasses import dataclass


@dataclass(frozen=True)
class Requisicao:
    rota: str
    status: int
    duracao_ms: float


LIMITE_MS = 400
ROTAS_FORA = {"/health", "/metrics"}


def valida(r: Requisicao) -> bool:
    return r.rota not in ROTAS_FORA


def boa(r: Requisicao) -> bool:
    # 4xx é problema do cliente; 429 é o nosso limitador recusando, então conta contra nós
    erro_nosso = r.status >= 500 or r.status == 429
    return not erro_nosso and r.duracao_ms <= LIMITE_MS


def sli(requisicoes: list[Requisicao]) -> tuple[int, int, float]:
    validas = [r for r in requisicoes if valida(r)]
    boas = sum(boa(r) for r in validas)
    return boas, len(validas), boas / len(validas)


amostra = (
    [Requisicao("/encomendas", 201, 120)] * 9_700
    + [Requisicao("/encomendas", 404, 35)] * 180     # bolo que não existe no catálogo
    + [Requisicao("/encomendas", 201, 2_300)] * 70   # gera o PDF do pedido dentro da requisição
    + [Requisicao("/encomendas", 503, 30_000)] * 40  # o timeout de 30 s do gateway de pagamento
    + [Requisicao("/encomendas", 429, 2)] * 10
    + [Requisicao("/health", 200, 1)] * 86_400       # o balanceador perguntando se está tudo bem
)

boas, validas, valor = sli(amostra)
print(f"boas={boas} válidas={validas} SLI={valor:.2%}")
ingenuo = sum(r.status < 500 for r in amostra) / len(amostra)
print(f"'uptime' com /health e só 5xx: {ingenuo:.2%}")
```

```text
boas=9880 válidas=10000 SLI=98.80%
'uptime' com /health e só 5xx: 99.96%
```

As 86.400 respostas do `/health` diluíram as falhas. O SLI correto mostra 120 requisições ruins em 10.000: 40 timeouts, 10 recusas do limitador e 70 sucessos tão lentos que contam como falha. Contra um SLO de 99,9%, o lote gastou o orçamento de 120.000 requisições.

O orçamento ao longo da janela é aritmética. Aqui, os dias 10 e 12 do mês, depois de uma terça em que alguém subiu "só uma linha" na validação de endereços:

```python
SLO = 0.999
JANELA_DIAS = 30


def situacao(dia: int, validas: int, ruins: int) -> None:
    taxa_erro = ruins / validas
    burn_rate = taxa_erro / (1 - SLO)
    # projeção: a janela inteira com o tráfego médio observado até agora
    orcamento = (1 - SLO) * validas / dia * JANELA_DIAS
    consumido = ruins / orcamento
    print(f"dia {dia:>2}: erro {taxa_erro:.3%}  burn rate {burn_rate:.2f}  "
          f"orçamento {orcamento:,.0f}  consumido {consumido:.0%}")


situacao(10, 4_320_000, 3_888)
situacao(12, 5_184_000, 11_664)

for burn, minutos in ((14.4, 60), (6, 360), (1, 4_320)):
    print(f"burn {burn:>4} por {minutos:>5} min consome {burn * minutos / 43_200:.0%}; "
          f"com 100% de erro, dispara em {burn * (1 - SLO) * minutos:.2f} min")
```

```text
dia 10: erro 0.090%  burn rate 0.90  orçamento 12,960  consumido 30%
dia 12: erro 0.225%  burn rate 2.25  orçamento 12,960  consumido 90%
burn 14.4 por    60 min consome 2%; com 100% de erro, dispara em 0.86 min
burn    6 por   360 min consome 5%; com 100% de erro, dispara em 2.16 min
burn    1 por  4320 min consome 10%; com 100% de erro, dispara em 4.32 min
```

Em dez dias, o serviço gastou 30% do orçamento, abaixo dos 33% que o calendário permitiria. Em dois dias de "só uma linha", gastou mais 60%. O burn rate acumulado de 2,25 parece modesto porque a média de 12 dias dilui o estrago de 48 horas; os alertas olham janelas de horas justamente por isso.

Com Prometheus, o SLI de cada janela vira uma *recording rule* (consulta pré-calculada gravada como série nova), e os alertas comparam as janelas com os limiares da tabela:

```yaml
groups:
  - name: slo-encomendas
    rules:
      - record: encomendas:taxa_erro:rate5m
        expr: |
          sum(rate(http_requests_total{job="encomendas", code=~"5..|429"}[5m]))
          /
          sum(rate(http_requests_total{job="encomendas"}[5m]))
      - record: encomendas:taxa_erro:rate1h
        expr: |
          sum(rate(http_requests_total{job="encomendas", code=~"5..|429"}[1h]))
          /
          sum(rate(http_requests_total{job="encomendas"}[1h]))
      # rate30m e rate6h seguem o mesmo molde

      - alert: OrcamentoDeErroQueimandoRapido
        expr: |
          encomendas:taxa_erro:rate1h > (14.4 * 0.001)
          and
          encomendas:taxa_erro:rate5m > (14.4 * 0.001)
        labels:
          severity: page
        annotations:
          summary: "Encomendas consumindo 2% do orçamento de erro por hora"
```

O SLI de latência usa o histograma: `rate` do balde `le="0.4"` dividido pelo `rate` do `_count`. Esse balde precisa existir. Os baldes padrão do cliente Prometheus para Python pulam de 0,25 para 0,5 segundo, então um SLO de 400 ms exige declarar a borda 0,4. A alternativa é descobrir, num postmortem, que o "400 ms" do painel era 500 ms com interpolação (o capítulo 38 trata de histogramas).

## Propriedades e custos das escolhas

Cada escolha na definição de um SLO responde a uma pergunta diferente:

| Escolha | O que garante | O que custa |
|---|---|---|
| SLI por requisição | Falha pesa pelo número de usuários afetados | Pico de tráfego domina; madrugada quase não conta |
| SLI por tempo (intervalos) | Cada minuto pesa igual, independentemente do tráfego | Um intervalo com 2 requisições pesa o mesmo que um com 20.000 |
| Janela móvel (28 ou 30 dias) | Sempre reflete o passado recente; alertas e orçamento contínuos | Uma falha grave pesa no saldo por quatro semanas inteiras |
| Janela de calendário (mês) | Casa com faturamento e contratos | O saldo zera no dia 1; o dia 30 e o dia 1 têm tolerâncias opostas |
| Medição no servidor | Barata, com rótulos ricos (rota, versão) | Não vê processo morto, DNS nem balanceador |
| Medição no cliente | Mede o que o usuário viveu | Ruído de rede alheia; volume e privacidade de dados |

Passar de 99,9% para 99,99% ao mês reduz o tempo permitido de 43 para 4,3 minutos. Detecção, diagnóstico e recuperação precisam caber em poucos minutos, o que costuma significar failover automático, réplicas em mais de uma zona e rollback automatizado. Nenhum humano lê um stack trace, entende a causa e reverte um deploy em 4 minutos às 3h da manhã, por mais café que tenha.

## Armadilhas e casos reais

**A meta de 100%.** Orçamento zero: qualquer deploy, manutenção ou falha de disco é violação. O único jeito de cumprir é não mudar nada, o que também falha, só que mais devagar, no dia em que o certificado expira.

**SLI que mede o servidor errado.** O `/health` da Doce Prazo. Variações: medir só a leitura enquanto a escrita está quebrada, ou medir de dentro da rede, onde o DNS público quebrado não aparece.

**Manutenção planejada fora da conta.** Contratos costumam excluir janelas de manutenção do SLA. O usuário que tentou encomendar um bolo às 2h10 de domingo não leu a exclusão. Um SLI sem a janela mede o contrato; com ela, mede a experiência.

**SLA que mede outra coisa.** O SLA do Amazon S3 Standard (versão de 28/11/2023) calcula a taxa de erro, contando só `InternalError` e `ServiceUnavailable`, em cada intervalo de 5 minutos do ciclo de cobrança; a disponibilidade mensal é 100% menos a média dessas taxas, e intervalos sem requisição contam como 0% de erro. O crédito é de 10% abaixo de 99,9%, 25% abaixo de 99% e 100% abaixo de 95%. Duas consequências saem da definição: uma falha num horário em que sua conta não fez requisições não entra na sua conta, e um crédito de 10% sobre a fatura de armazenamento não paga um dia de encomendas perdidas. O SLA define a indenização, e a disponibilidade do sistema construído em cima dele continua com quem o construiu.

**Alerta por causa em vez de sintoma.** CPU a 90% e réplica com 3 segundos de lag são causas possíveis; a página por burn rate dispara pelo sintoma que o usuário sente. Um time acordado por CPU alta num serviço que responde bem aprende a ignorar páginas, inclusive a próxima, que será a do incidente real.

**Dependência com SLO menor que o seu.** Se o gateway de pagamento promete 99,9% e a encomenda depende dele de forma síncrona, ela herda esse teto. Para prometer mais, a dependência sai do caminho crítico (fila, degradação controlada) ou ganha redundância independente (o capítulo 19 trata dessas técnicas).

Quanto à cláusula 7.2: máquina numa zona, banco com 26 horas de folga por ano e gateway de pagamento com 99,9%. A meta possível com essa arquitetura fica perto de 99,5%, medidos no balanceador, com o SLA um degrau abaixo. O bolo de brigadeiro foi devolvido junto com um aditivo contratual.

## Resumo

- SLI = `bons / válidos`; SLO = meta para o SLI numa janela; SLA = contrato com consequência.
- Health checks ficam fora; `4xx` conta como acerto; `429` do próprio limitador e respostas lentas contam como falha.
- Medir no balanceador enxerga backend morto.
- Tempo permitido = `(1 − SLO) × janela`: 99,9% ao mês são 43,2 minutos.
- Error budget = `1 − SLO`; ficar muito acima do SLO cria dependências que ninguém prometeu.
- Burn rate = taxa de erro / `(1 − SLO)`; alertas com janela longa e curta: 14,4 e 6 para página, 1 para ticket.

## Referências

- Beyer, B. et al. *Site Reliability Engineering*, capítulo 4, "Service Level Objectives". O'Reilly/Google, 2016. <https://sre.google/sre-book/service-level-objectives/>
- Beyer, B. et al. *Site Reliability Engineering*, capítulo 3, "Embracing Risk". <https://sre.google/sre-book/embracing-risk/>
- Beyer, B. et al. *The Site Reliability Workbook*, capítulo 2, "Implementing SLOs". O'Reilly/Google, 2018. <https://sre.google/workbook/implementing-slos/>
- Beyer, B. et al. *The Site Reliability Workbook*, capítulo 5, "Alerting on SLOs". <https://sre.google/workbook/alerting-on-slos/>
- Amazon S3 Service Level Agreement. <https://aws.amazon.com/s3/sla/>
- Prometheus, "Histograms and summaries". <https://prometheus.io/docs/practices/histograms/>
- Prometheus, "Recording rules". <https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/>
- Prometheus Python client. <https://github.com/prometheus/client_python>
