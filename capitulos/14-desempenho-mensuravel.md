# Desempenho mensurável

## A média do Carlos

O Carlos entrou na reunião com o Bazar levando um slide com um número só, em fonte 96: "0,9 s", a média da autorização. O Bazar levou um contrato. Cláusula 7.2: na Black Friday, o p99 da autorização fica abaixo de 1,5 segundo no pico projetado, com capacidade comprovada para o dobro do pico. Multa por hora fora.

Ninguém na Lastro sabia o p99. O fundador perguntou se p99 era o modelo novo de celular. O Carlos garantiu que tinha feito um teste de carga: 50 usuários virtuais, dez minutos, "aguenta 55 autorizações por segundo com p99 de 1,1 segundo". A projeção do Bazar para o pico é de 60. Faltavam 5, e o Carlos achou que era arredondamento.

O log do proxy discordou:

```text
autorizações:  21.418     média:  0,93 s
p50:  0,87 s    p90:  1,04 s    p99:  1,31 s    p99,9:  2,9 s
```

A média estava certa. O p99 estava dentro, por 190 ms. E o teste de carga do Carlos tinha medido, com toda a precisão do mundo, o limite do próprio teste. Como transformar "rápido" num número que cabe num contrato, e como provar, antes de novembro, que a Lastro cumpre esse número no dobro do pico?

## Latência, throughput e por que a média mente na cara dura

**Latência** é o tempo de uma operação entre dois pontos que você precisa nomear: do cliente ao cliente inclui rede e fila no kernel; do proxy ao proxy, não. **Throughput** (vazão) é quantas operações terminam por unidade de tempo. Um lote noturno tem vazão alta e latência horrível; o worker do capítulo 13 tinha latência boa e vazão de um pedido por vez.

Latência é **tempo de serviço** mais **tempo de espera** na fila de algum recurso (CPU, conexão, lock, o adquirente). O serviço é estável. A espera depende de quem chegou antes, e é ela que estraga a sua noite.

Distribuição de latência tem cauda longa: quase tudo rápido, uns poucos muito lentos (uma pausa, um retry, uma fila momentânea). A média esconde a cauda. Cem requisições de 100 ms e uma de 10 segundos dão média de 198 ms, um número que nenhuma requisição teve. A média é a única estatística capaz de descrever com exatidão um paciente com um pé no forno e o outro no freezer: 36,5 °C, estável, pode dar alta.

Um **percentil** p é o valor abaixo do qual estão p% das medidas. O p50 é a mediana: metade das requisições foi mais rápida. O p99 é o valor que só 1% ultrapassa. O p99,9, 1 em mil. Em 21.418 autorizações por hora, o 1% acima do p99 são 214 compradores por hora olhando a tela girar. Num cliente que faz 50 chamadas por página, a chance de pelo menos uma passar do p99 é 1 − 0,99^50 ≈ 39%. O seu p99 é a experiência típica de quem usa muito o sistema. O p99,9 é a dos seus melhores clientes, que são os que mais reclamam, com razão e com URGENTE!!!!.

> **Na vida real:** em "The Tail at Scale" (2013), Jeffrey Dean e Luiz André Barroso mostram o efeito em sistemas com fan-out: um servidor com p99 de 1 segundo, consultado em paralelo com outros 99 iguais por cada requisição, faz 63% das requisições do usuário passarem de 1 segundo. A cauda de um vira o corpo de todos.

Percentil não se soma nem se tira média: na média dos p99 de seis processos, o processo doente que carrega a cauda é diluído pelos cinco saudáveis. O que se agrega são **histogramas**: cada processo conta requisições por faixa (0–50 ms, 50–100 ms, ...), os contadores se somam, e o percentil sai do histograma somado, com o erro da largura da faixa. É o que fazem o HdrHistogram e os histogramas do Prometheus (capítulo 38). Média de percentil tem cara de estatística e alma de horóscopo.

## A Lei de Little, ou a equação que entrega o teste do Carlos

Para qualquer sistema estável (o que entra é o que sai, em média, no período):

```text
L = λ × W
L: itens dentro do sistema, em média
λ: taxa de chegada (= vazão, no estado estável)
W: tempo médio de cada item lá dentro
```

John Little provou em 1961 que isso vale sem hipótese sobre a distribuição das chegadas ou do serviço, nem sobre a ordem de atendimento: requisições num servidor, conexões num pool, streams no adquirente.

No teste do Carlos, o gerador usava 50 usuários num **modelo fechado**: cada um manda, espera a resposta e só então manda a próxima. Logo L ≤ 50 e, com W = 0,9 s, λ ≤ 50 / 0,9 = 55,6 por segundo, com qualquer servidor do universo. O "aguenta 55" era a Lei de Little medindo o gerador. O servidor nem foi apresentado à Black Friday.

A mesma lei dimensiona recursos: no pico, 60 × 0,9 = 54 autorizações em andamento no adquirente. É a primeira conta de qualquer dimensionamento e a última defesa contra um relatório de teste de carga.

## Utilização e filas, ou por que 90% de CPU é uma emergência

**Utilização** (ρ) é a fração do tempo em que um recurso está ocupado: taxa de chegada vezes tempo de serviço, dividido pelo número de servidores. Um núcleo que recebe 200 requisições por segundo de 3 ms está 60% ocupado.

A intuição diz que um recurso a 90% ainda tem 10% de folga. A teoria de filas diz que ele está a um espirro do colapso. No modelo M/M/1 (chegadas de Poisson, serviço exponencial, um servidor), o tempo médio no sistema é:

```text
W = S / (1 − ρ)        S: tempo de serviço médio
```

| ρ | W, em múltiplos de S |
|---|----------------------|
| 0,5 | 2 |
| 0,7 | 3,3 |
| 0,8 | 5 |
| 0,9 | 10 |
| 0,95 | 20 |
| 0,99 | 100 |

De 50% para 90%, a vazão cresce 80% e a latência média, 400%. De 90% para 99%, a vazão cresce 10% e a latência, dez vezes. É uma hipérbole com a assíntota em ρ = 1, e o seu sistema sobe por ela de olhos fechados. No M/M/1, o tempo no sistema é exponencial, e o p99 fica em ln(100) ≈ 4,6 vezes a média: com ρ = 0,9, o p99 é 46 vezes o tempo de serviço.

Sistemas reais têm várias filas e distribuições piores. A aproximação de Kingman, para filas G/G/1, mostra o outro ingrediente: a espera é proporcional a ρ / (1 − ρ) e à variabilidade das chegadas e do serviço (a média dos quadrados dos coeficientes de variação). Serviço irregular piora a fila na mesma utilização. Num event loop, uma consulta GraphQL de 15 ms de CPU entre GETs de 1,5 ms é exatamente essa variabilidade: todo mundo atrás dela espera.

Recurso de que a latência depende se dimensiona bem abaixo de ρ = 1 no pico, e o teste de carga acha o joelho. Banco "a 95% para não desperdiçar" economiza um servidor e paga em latência com juros de agiota.

## A Lei de Amdahl, ou otimizar o que não importa com muita competência

Gene Amdahl, em 1967, sobre acelerar uma parte de um trabalho:

```text
aceleração = 1 / ((1 − p) + p / s)
p: fração do tempo que pode ser acelerada
s: quanto essa fração fica mais rápida
```

Com s infinito, a aceleração máxima é 1 / (1 − p). Se 95% de um job paraleliza, nem infinitos núcleos o fazem mais de 20 vezes mais rápido: os 5% seriais viram o job inteiro.

A lei vale para latência também. Da autorização de 0,9 s, o código da Lastro (validar, gravar, serializar) gasta uns 50 ms; o resto é Vigia e adquirente. p ≈ 0,056: deixar esse trecho infinitamente rápido dá 1 / 0,944 ≈ 1,06. Seis por cento. O Carlos tinha aberto um épico "migrar autorização para Rust". Amdahl fechou o épico quase seis décadas antes de ele ser aberto.

## Números de latência para fazer conta de cabeça

A lista popularizada por Jeff Dean ("Numbers Everyone Should Know", 2009, atualizada por terceiros desde então) dá ordens de grandeza aproximadas, que variam com o hardware e servem para comparar, nunca para citar em contrato:

| Operação | Ordem de grandeza |
|----------|-------------------|
| Referência ao cache L1 | ~1 ns |
| Acesso à memória principal | ~100 ns |
| Leitura aleatória em SSD | dezenas a centenas de µs |
| Ida e volta na mesma zona de um datacenter | ~0,5 ms |
| Consulta simples ao PostgreSQL da Lastro, rede inclusa (capítulo 6) | ~1 ms |
| Ida e volta São Paulo–Virgínia (capítulo 8) | ~100 ms |
| Autorização no adquirente | ~800 ms |

De cima para baixo, nove ordens de grandeza: oito milhões de acessos à memória cabem numa autorização. Discutir se um dicionário Python é mais rápido que uma dataclass no caminho da autorização é discutir o troco da passagem de um voo que atrasou seis horas.

## Teste de carga, ou como o gerador mente para você

No **modelo fechado**, um número fixo de usuários manda, espera a resposta (e um tempo de pensar, se houver) e manda de novo. Servidor lento, usuários mandam menos: a carga se ajusta à capacidade e a fila nunca cresce de verdade. Serve para população limitada que espera, como 40 atendentes usando um sistema interno.

No **modelo aberto**, as requisições chegam a uma taxa definida, independente das respostas. Servidor lento, a fila cresce. É o comportamento de milhares de compradores independentes, e a Black Friday é um modelo aberto com o agravante de que o comprador, quando demora, clica de novo.

O modelo fechado ainda carrega a **coordinated omission**, nome dado por Gil Tene: o gerador espera a resposta antes de mandar a próxima e, sem querer, combina com o servidor de não medir justamente as requisições que teriam sofrido a lentidão. No teste do Carlos, o simulador do adquirente (escrito em Java, por motivos de herança) parou 12 segundos numa pausa de coleta de lixo. Veja a conta:

| | Modelo fechado (50 usuários) | Modelo aberto (55/s) |
|---|---|---|
| Requisições em 10 min | ~33.000 | 33.000 |
| Afetadas pela pausa de 12 s | 50 (uma por usuário) | ~660 (as que chegaram durante a pausa) |
| Fração afetada | 0,15% | 2% |
| p99 medido | 1,1 s | ~6,9 s |

No fechado, os 50 usuários ficaram parados juntos esperando, e cada um registrou uma requisição lenta. As 610 requisições que deveriam ter saído nesses 12 segundos simplesmente não existiram. Um comprador de verdade teria existido, e teria esperado. O p99 do Carlos tinha omitido 660 pessoas, coordenadamente, como uma ata de reunião de condomínio.

A correção: carga em modelo aberto, a taxa constante, com cada latência medida a partir do instante em que a requisição *deveria* ter saído. O wrk2 faz isso por padrão; o k6 tem executores de taxa de chegada (`constant-arrival-rate`); o Gatling tem injeção aberta.

O resto do teste também precisa ser honesto: hardware e volume de dados de produção (um ledger de 1.000 linhas cabe em cache e mente sobre índice), a mistura de requisições do pico, duração maior que os ciclos que atrapalham (autovacuum, coleta de lixo), aquecimento descartado e o gerador monitorado, porque gerador a 100% de CPU mede a si mesmo.

## Na Lastro

**O número.** A latência da autorização passa a ser medida no proxy, do recebimento da requisição ao último byte da resposta, num histograma por processo, agregado a cada minuto. Cada etapa (Vigia, adquirente, as duas transações) ganha o seu histograma. A definição formal como SLI e a meta como SLO ficam para o capítulo 39; o contrato de 1,5 s já usa esta medida.

**O orçamento.** O p99 de 1,5 s é dividido entre as etapas:

| Etapa | p99 medido | Orçamento |
|-------|-----------|-----------|
| Proxy, TLS, fila do event loop | 4 ms | 20 ms |
| Validação e primeira transação | 9 ms | 20 ms |
| Vigia (timeout de 120 ms, capítulo 12) | 58 ms | 120 ms |
| Adquirente | 1.180 ms | 1.200 ms |
| Segunda transação e resposta | 7 ms | 20 ms |
| Folga | | 120 ms |
| **Total** | | **1.500 ms** |

Somar p99 de etapas não dá o p99 da soma. Com etapas independentes, a soma costuma ficar acima do p99 real, porque raramente todas estão no pior ao mesmo tempo, mas sem garantia; o teste de carga confere. O que a tabela mostra: 80% do orçamento é do adquirente, e a Lastro controla 60 ms. Amdahl avisou.

**A projeção.** O pico da Black Friday, somando Bazar e Hornero: 60 autorizações de cartão, 140 cobranças Pix, 900 GETs e 40 consultas GraphQL por segundo. CPU medida por requisição: 6, 4, 1,5 e 15 ms. Demanda: 0,36 + 0,56 + 1,35 + 0,60 = 2,87 segundos de CPU por segundo. Com 6 workers (um núcleo cada), ρ = 0,48 no pico e 0,96 no dobro do pico. A cláusula do dobro mata o arranjo atual: a 0,96, a fila do event loop sozinha come a folga.

A Lastro acrescenta `api-02`, igual a `api-01`: 4 vCPUs, 3 workers, proxy TLS, certificado próprio por ACME (capítulo 10). Com 9 workers, ρ = 0,32 no pico e 0,64 no dobro. A regra adotada: ρ de CPU por worker até 0,7 no dobro do pico. O resto das contas, por Little:

- **Pool do banco:** 9 processos × 3 = 27 conexões, acima do teto útil de 17 a 20 (capítulo 4). O `pool_size` cai para 2: 18. A demanda no pico é de 3,2 conexões ocupadas no total (soma de taxa × tempo de posse de cada transação), 6,4 no dobro: cabe.
- **Adquirente:** 54 autorizações em andamento no pico, 108 no dobro; 9 conexões HTTP/2 × 100 streams = 900, e 9 das 20 conexões contratadas.
- **Contas quentes:** a comissão do Bazar recebe 200 créditos por segundo no pico; 16 baldes com posse de 2 ms (capítulo 4) dão teto de 8.000.

Mais uma máquina, e não máquinas maiores: núcleos extras só ajudam com mais workers, e a conta do pool é a mesma; a terceira máquina ainda dá isolamento de falha (perdida uma, 6 workers aguentam o pico a ρ = 0,48, não o dobro). Máquinas de 8 vCPUs seriam a escolha se o custo fosse por máquina; autoscaling fica para o capítulo 29.

**O teste.** Modelo aberto, taxa constante, latência do instante planejado, mistura da projeção, volume do ledger copiado. Vigia e adquirente viram simuladores que sorteiam a latência dos histogramas reais de produção, porque a sandbox do adquirente responde em 40 ms e faria qualquer número da Lastro parecer gênio. O coletor de lixo do simulador agora é monitorado. Três patamares de 30 minutos:

| Carga | 6 workers (p99 autorização) | 9 workers (p99 autorização) |
|-------|-----------------------------|-----------------------------|
| 1× (60/s) | 1,33 s | 1,32 s |
| 1,5× | 1,41 s | 1,33 s |
| 2× (120/s) | 2,7 s | 1,36 s |

Com 6 workers, o dobro estoura o contrato por 1,2 segundo; com 9, sobra folga. A hipérbole apareceu onde a conta disse, e a equipe sentiu algo próximo de fé.

## Armadilhas e casos reais

> **Armadilha:** dashboard com média de p99 por host. O processo doente vira um sexto de um número e some. Agregue histogramas, ou mostre o pior host.

> **Armadilha:** medir só dentro da aplicação. O cronômetro do FastAPI começa quando o event loop pega a requisição; o tempo na fila do `accept` do kernel e no proxy fica de fora, e é exatamente onde a fila mora quando o loop está ocupado. Medir no ponto mais externo que você controla.

> **Armadilha:** a sandbox do parceiro como alvo do teste. Responde rápido, sem cauda, e às vezes com um limite que vira o seu gargalo. Ou o parceiro liga perguntando por que você mandou 216 mil autorizações numa terça.

> **Na vida real:** o wrk2, de Gil Tene, nasceu de um fork do wrk para gerar carga a taxa constante e corrigir a coordinated omission; o README compara a cauda medida pelos dois geradores contra o mesmo servidor, e a diferença chega a ordens de grandeza. Medir mal produz números melhores, e por isso tanta gente mede mal.

## Resumo

- Latência é serviço mais espera, entre pontos nomeados; vazão é conclusões por tempo.
- Média esconde a cauda; percentis a mostram e se agregam por histograma.
- Little: `L = λ × W`. Filas: `W = S / (1 − ρ)`, explosão perto de ρ = 1.
- Amdahl: acelerar a parte p limita o ganho a `1 / (1 − p)`.
- Teste de carga em modelo aberto, latência do instante planejado, sem coordinated omission.

## A Lastro agora

A autorização tem um número: p99 de 1,31 s, medido no proxy, com histograma por etapa e orçamento de 1,5 s em que o adquirente fica com 1,2. Entrou `api-02` (4 vCPUs, 3 workers), totalizando 9 workers; o pool caiu para 2 conexões por processo (18); a regra é ρ de CPU até 0,7 no dobro do pico. O teste de carga em modelo aberto, com simuladores alimentados pelos histogramas reais, sustentou 120 autorizações por segundo com p99 de 1,36 s. O Carlos refez o slide: agora são três números em fonte 72, e um deles tem vírgula.

Toda a folga, porém, depende de o adquirente manter o p99 de 1,18 s na Black Friday dele também. Na sexta, às 21h40, o p99 do adquirente foi para 4 segundos, e alguém configurou um timeout de 1,3 segundo para proteger o contrato. O timeout disparou 3.000 vezes em dez minutos, a Lastro respondeu "recusada" para todas, e o financeiro descobriu no arquivo do dia seguinte que 412 delas tinham sido aprovadas. O cronômetro funcionou. O dinheiro não leu o contrato.

## Referências

- John D. C. Little, "A Proof for the Queuing Formula: L = λW", *Operations Research* 9(3), 1961.
- Gene Amdahl, "Validity of the single processor approach to achieving large scale computing capabilities", AFIPS Spring Joint Computer Conference, 1967.
- J. F. C. Kingman, "The single server queue in heavy traffic", *Mathematical Proceedings of the Cambridge Philosophical Society* 57(4), 1961.
- Jeffrey Dean e Luiz André Barroso, "The Tail at Scale", *Communications of the ACM* 56(2), 2013. <https://cacm.acm.org/research/the-tail-at-scale/>
- Jeff Dean, "Designs, Lessons and Advice from Building Large Distributed Systems", LADIS 2009 (lista "Numbers Everyone Should Know").
- Gil Tene, wrk2 (README sobre coordinated omission). <https://github.com/giltene/wrk2>
- HdrHistogram. <https://hdrhistogram.github.io/HdrHistogram/>
- Grafana k6, "Open and closed models". <https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/open-vs-closed/>
- Bianca Schroeder, Adam Wierman e Mor Harchol-Balter, "Open Versus Closed: A Cautionary Tale", NSDI 2006.
