# Escalabilidade e capacidade

Na terça às 15h12, o Carlos ligou o *autoscaling* do ambiente de homologação com máximo de 64 processos, "por segurança", e às 15h19 a Lastro aprendeu que segurança, no vocabulário do Carlos, é uma unidade de medida de incidente.

O contrato era com o Tuiuiú, marketplace de um grupo de varejo, dez vezes maior que o Bazar, migração em quatro meses. O gerente apresentou o plano de capacidade num slide: tudo vezes dez, inclusive o PostgreSQL. O fundador sugeriu "a maior máquina que tiver", com a convicção de quem foi ignorado no capítulo 24. O Carlos quis provar com um teste de carga no volume do Tuiuiú.

O autoscaling funcionou lindamente. Subiu 64 processos de pagamentos, cada um com a sua conexão HTTP/2 para a homologação do adquirente. Só que a allowlist do adquirente aceita dois IPs (capítulo 27), o segundo ainda é o do `temp-01`, e homologação sai pelo mesmo proxy de produção, com o mesmo `203.0.113.10`. O adquirente limita 20 conexões por origem (capítulo 9), viu 73, classificou como abuso e bloqueou o IP por 15 minutos. Produção foi junto, de carona.

Foram 2.730 autorizações de cartão devolvidas com `503` e `adquirente-indisponivel`, nenhum comprador cobrado (falha de conexão é certeza de não envio, capítulo 15). O Bazar abriu chamado às 15h22: "URGENTE!!!! vocês estão escalando ou caindo?". As duas coisas, Bazar. Em paralelo, que é o jeito escalável.

Quanto um cliente dez vezes maior exige de cada recurso, quais partes crescem com mais máquinas, quais não crescem com nenhuma, e como fazer as máquinas aparecerem sozinhas sem atropelar um limite que ninguém tinha olhado?

## Multiplicar tudo por dez, ou a arte de errar a conta com confiança

Estimativa de capacidade é aritmética de ordem de grandeza: transformar um número de negócio no consumo de cada recurso (CPU, conexões, escritas, armazenamento, banda) com erro de até 2× ou 3×, curta o bastante para caber num guardanapo e certa o bastante para dizer se o plano é uma máquina ou cinquenta.

As conversões que fazem quase todo o trabalho:

```text
1 dia                  = 86.400 s ≈ 10^5 s
1 ano                  ≈ 3,15 × 10^7 s
1 req/s constante      ≈ 86 mil/dia ≈ 2,6 milhões/mês
1 milhão/dia           ≈ 12/s de média
1 KB × 1.000/s         = 1 MB/s = 8 Mbit/s
concorrência           = taxa × tempo de permanência   (Little: L = λW)
```

A média diária não dimensiona nada. O **fator de pico** (pico dividido pela média) se mede no histórico do próprio tráfego, e é ele que multiplica tudo. Sistema dimensionado pela média cai todo dia no mesmo horário, com uma pontualidade que o resto da empresa nunca conseguiu.

O método é uma cadeia: negócio → taxa de pico por operação → custo medido por operação (ms de CPU, linhas, bytes) → limite de cada recurso, com a folga da teoria de filas (acima de ~70% a latência explode, capítulo 14).

O defeito do slide é supor que todo recurso cresce linearmente. A CPU dos serviços sem estado cresce. Alguns recursos nem crescem, porque são o limite fixo de alguém que não estava na reunião: as 20 conexões do adquirente, os dois IPs da allowlist, as 12 partições de um tópico. O gerente multiplicou por dez até o adquirente, que pelo visto vinha com volume ilimitado incluso no plano.

> **Na vida real:** no lançamento do Pokémon GO, em julho de 2016, o tráfego chegou a 50 vezes a meta que a Niantic tinha planejado com o Google Cloud e a 10 vezes a estimativa de pior caso, segundo o próprio Google. O pior caso tinha um pior caso.

## Vertical, horizontal e o pedágio que cada máquina nova cobra

Escalar **verticalmente** é trocar a máquina por uma maior. O código e a consistência não mudam. Os limites: o catálogo tem uma maior máquina, o preço por núcleo sobe perto do topo, a troca exige reiniciar, e continua havendo um único domínio de falha. O fundador, que acredita em máquina maior com a fé que outros reservam para santo, está certo até o dia em que o catálogo acaba.

Escalar **horizontalmente** é pôr máquinas iguais atrás de um balanceador (capítulo 27). Sem teto, e perder uma réplica de vinte custa 5%. Em troca, qualquer réplica precisa atender qualquer requisição, e a coordenação cresce com o número de réplicas.

Esse custo tem modelo. A **Lei Universal de Escalabilidade** (USL), de Neil Gunther, dá a capacidade relativa com N nós:

```text
C(N) = N / (1 + α(N − 1) + βN(N − 1))

α = contenção   (fração serializada: lock, recurso único, fila comum)
β = coerência   (custo de os nós ficarem de acordo entre si, par a par)
```

Com β = 0, é a Lei de Amdahl do capítulo 14: teto em 1/α. Com β > 0, a curva passa por um máximo em `N* = √((1 − α)/β)` e depois **desce**, porque a coerência cresce com N² e a capacidade com N. É a escalabilidade retrógrada, que explica por que uma reunião de 30 pessoas decide menos que uma de quatro.

Com α = 0,05 e β = 0,001, dez nós entregam 6,5 vezes um nó, 31 nós (o máximo) 9,0 vezes, e cem nós 6,3 vezes: noventa máquinas a mais para ficar pior que com dez, e o consultor cobra por máquina. Os coeficientes saem do ajuste a testes de carga com 1, 2, 4 e 8 nós. Serviço sem estado tem α e β perto de zero; o α mora no que as réplicas compartilham: banco, parceiro, lock.

## Stateless, ou onde você escondeu o corpo

Um serviço é *stateless* (sem estado) quando nenhum dado que importa para a próxima requisição vive só dentro do processo: matar uma réplica perde, no máximo, o que estava em andamento nela (é o fator VI do Twelve-Factor App). Na prática, é uma auditoria:

| O que o processo guarda | Pode morrer junto? |
|---|---|
| Estado da requisição | Sim; o cliente repete com chave de idempotência |
| Cache local (tarifas, cap. 22) | Sim, se reconstruível na partida |
| Sessão de usuário em memória | Não; vai para banco, Redis ou token assinado (cap. 30) |
| Conexão longa (SSE, `LISTEN`) | Sim, se o cliente reconecta e retoma |
| Trabalho em andamento | Só com lease ou resolução que retome |
| Limite local (bulkhead, pool, conexão HTTP/2) | Sim, mas o total muda com N |
| Papel único (job com lease, cap. 20) | Não escala horizontalmente |
| Arquivo em disco local | Não; vai para armazenamento de objetos |

A linha traiçoeira é a do limite local: limite por processo vezes N cresce sozinho, e o recurso do outro lado não. 64 processos × 1 conexão = 64 conexões para quem aceita 20. Ninguém mudou uma linha de código. Mudou N, e N não passa por revisão de PR.

E todo sistema tem uma máquina que só existe no singular. Na Lastro é o `temp-01`, que não tem imagem nem script de criação: ele é a imagem. Se morrer, a Lastro escala para zero, com a elegância de um autoscaling que só sabe descer.

## Autoscaling, um laço de controle com atraso

Autoscaling é um laço de controle: mede, compara com uma meta, calcula quantas réplicas deveriam existir, cria ou destrói, espera e mede de novo. O Horizontal Pod Autoscaler do Kubernetes (capítulo 35) usa a regra proporcional que a maioria dos autoscalers segue:

```text
réplicas_desejadas = ceil(réplicas_atuais × métrica_atual / métrica_alvo)

6 réplicas, CPU média 63%, alvo 35%   →   ceil(6 × 63 / 35) = ceil(10,8) = 11
```

O HPA ignora desvios de até 10% e, por padrão, só reduz olhando a maior recomendação dos últimos 300 s.

### Qual métrica

A métrica precisa subir antes da latência e cair quando se acrescenta réplica: CPU para serviço limitado por CPU; concorrência em andamento ou lag do event loop para quem espera rede (capítulo 13); backlog ou idade da mensagem mais antiga para consumidores (capítulo 17). Latência p99 sozinha é a pior escolha: sobe também quando o lento é o banco ou o parceiro, e o laço responde do único jeito que conhece:

```text
Banco:        Tô lento.
Autoscaler:   Entendido. Mandando mais 40 clientes pra você.
Banco:        Tô MAIS lento.
Autoscaler:   Entendido. Mandando mais 80.
```

Consumidores de log têm um teto que métrica nenhuma fura: num consumer group, cada partição é lida por um único consumidor (capítulo 17). Com 12 partições, o 13º consumidor fica parado, recebendo salário, igual ao cargo de vice-presidente de inovação.

### Histerese

Laço com atraso e sem histerese oscila: sobe réplicas, a CPU cai, remove, a CPU sobe, sobe de novo. É o *flapping*. A **histerese** separa os gatilhos: subir quando a métrica passa do alvo por alguns minutos; descer só bem abaixo dele, por bem mais tempo, um passo por vez, com intervalo de espera (*cooldown*) após cada ação. Réplica a mais custa dinheiro; réplica a menos custa cliente.

### Tempo de reação

O autoscaling reage ao que já aconteceu. A soma dos atrasos do laço é o tempo em que a carga nova bate só nas réplicas antigas:

```text
t = 0      pico começa
+60 s      fecha a janela da métrica (média do último minuto)
+120 s     segunda medição confirma (não reage a ruído)
+125 s     decisão; pedido de máquinas novas
+215 s     máquina liga a partir da imagem (~90 s)
+245 s     processos sobem, carregam tarifas, abrem conexões
+255 s     /pronto responde; registro e proxies atualizam a lista
≈ 4 min    capacidade nova recebe tráfego
```

Nesses quatro minutos, quem segura a carga é a folga das réplicas existentes. Daí a regra: o alvo deixa folga para o maior crescimento possível dentro do tempo de reação. Se a carga pode dobrar em quatro minutos e o máximo tolerável é 70%, o alvo é 35%. Pico mais rápido fica com o controle de carga do capítulo 28 e com o **escalonamento agendado**, que sobe réplicas antes do pico com hora marcada.

O máximo do grupo sai do recurso mais escasso que cada réplica consome: conexões do banco ou do parceiro, partições do log. O de 64 do Carlos saiu de "por segurança", a mesma fonte dos 1.024 baldes do capítulo 4. E a réplica que vai morrer sai do balanceador e termina o que está em andamento (drenagem, capítulo 27); senão, devolve a pergunta do capítulo 15, agora automatizada.

## A conta do Tuiuiú

Primeira correção do slide: o Bazar é metade do pico da Lastro. Dez Bazares são cinco Lastros, e a Lastro com o Tuiuiú é seis vezes a de hoje. O gerente errou para mais, o erro que só custa dinheiro. O do Carlos custou o adquirente. O pico de referência do capítulo 14 (2,87 s de CPU por segundo) vezes seis:

| Recurso | Pico com Tuiuiú | Limite que importa | Cresce com réplicas? |
|---|---|---|---|
| CPU de pagamentos | 17,2 s/s | ρ ≤ 0,7 no 2× do pico | Sim |
| Autorizações em andamento | 324 (648 no 2×) | adquirente: 20 conexões | Não |
| Lançamentos no ledger | ~4.800/s | primário: ~7.000/s medidos | Não |
| Créditos na comissão do Tuiuiú | ~2.000/s | 16 baldes: ~4.500/s | Não |
| Eventos de cobrança | 3.000/s | 12 partições | Até 12 consumidores |
| Webhooks ao Tuiuiú | ~2.500/s | bulkhead 10 por endpoint | Não |

A primeira linha é a única que obedece ao slide: pela regra do capítulo 14, pagamentos precisa de `2 × 17,2 / 0,7 ≈ 50` workers, contra 9. CPU de serviço sem estado escala com α perto de zero, e é aí que entra o autoscaling. As outras linhas são o que o slide não viu.

**Adquirente.** Uma conexão por processo seriam 50 conexões contra 20: o incidente de terça, versão produção. A Lastro desacopla: as chamadas ao adquirente vão para um serviço novo, `conector-adquirente`, com 10 processos fixos (5 em `api-01`, 5 em `api-02`), uma conexão e 100 streams cada: 1.000 streams para 648 autorizações em andamento, 10 conexões mais 2 de homologação. Breaker, bulkhead e deadline (capítulo 15) mudam junto. Custa ~1 ms de salto interno, pago com a folga de 120 ms do orçamento. Negociar um limite maior seria a escolha certa com número de processos estável; com autoscaling, manteria a amarra entre N e o parceiro.

**Ledger.** O gatilho do capítulo 24 era escrita no primário acima de 50% da capacidade medida. O teste em `pg-ledger-1` mediu ~7.000 lançamentos/s até o p99 do COMMIT síncrono passar de 10 ms; 4.800 é 69%. Disparou. O Tuiuiú ganha shard próprio pelo diretório, e o shard 0 fica com ~800/s. O do Tuiuiú, ~4.000/s, nasce com o dobro de núcleos e mediu ~11.000/s (36%): 1,6 vez a menor, não 2, porque flush do WAL e espera pela réplica síncrona são o α da USL, e núcleo nenhum acelera fibra entre zonas. A comissão dele, ~4.000 créditos/s no dobro do pico contra ~4.500/s de teto, passa de 16 para 32 baldes. O Carlos queria 1.024. Continua não ganhando.

**Partições.** Com 12 partições, o consumidor do ledger teria 5 ms por evento no dobro do pico, e a posse de balde sozinha gasta ~3,5. O tópico vai para 48. Acrescentar partição muda `murmur2 mod N` das chaves existentes e pode desordenar eventos da mesma cobrança, mas o único produtor é o relay do CDC (capítulo 18): pausa o relay, a outbox acumula, o lag zera, acrescentam-se as partições, retoma. A outbox, que nasceu para não perder evento, agora segura a fila enquanto a Lastro faz obra.

**Webhooks.** Dois entregadores com bulkhead de 10 por endpoint dão 20 entregas simultâneas; com o endpoint do Tuiuiú em ~150 ms, Little dá `20 / 0,15 ≈ 133`/s, contra 2.500/s. Uma hora de Black Friday deixaria 8,5 milhões de webhooks na fila, e o Tuiuiú descobriria os pagamentos da sexta na terça. A concorrência passa a ser por inscrição, por Little com folga de 2×: `2.500 × 0,15 × 2 = 750`, arredondado para 800. A banda dá ~72 Mbit/s. O gargalo era uma constante 10 num arquivo de configuração.

**Armazenamento.** O ledger vai de 1,5 para 9 milhões de lançamentos por dia, a ~170 bytes cada com índices (o mês corrente ocupa ~7,5 GB para ~45 milhões de linhas):

```text
9 × 10^6 lançamentos/dia × 170 B  ≈ 1,5 GB/dia
                                  ≈ 46 GB/mês ≈ 560 GB/ano
10 anos de retenção (cap. 23)     ≈ 5,6 TB e ~33 bilhões de lançamentos
× 4 cópias (primário, 2 standbys, réplica de relatórios)
```

Tudo online seriam mais de 22 TB de disco de banco. A Lastro mantém 24 meses online (~1,1 TB por cópia) e manda o resto, por `DETACH`, para o arquivo do capítulo 24; `eventos_cobranca` (~270 GB/ano) passa a ser particionada por mês. O tabelião vai carimbar 33 bilhões de partidas dobradas e já pediu um estagiário.

## O autoscaling da Lastro

Nem todo serviço escala, e a tabela diz por quê:

| Serviço | Métrica de escala | Réplicas | O máximo vem de |
|---|---|---|---|
| pagamentos | CPU por worker, alvo 35% | 12–60 | conexões `LISTEN` |
| antifraude | CPU, alvo 35% | 6–30 | conexões do `redis-sinais` |
| entregador de webhooks | idade da entrega mais antiga, alvo 5 s | 2–20 | concorrência por endpoint |
| ledger (consumidor) | lag por partição | 6–48 | 48 partições |
| conector-adquirente | não escala | 10 | 20 conexões do adquirente |
| repasses | não escala | lease | papel único (cap. 20) |
| relatórios | não escala | fixo | memória (cap. 28) |

O máximo de pagamentos é uma conta: cada processo mantém uma conexão `LISTEN` direto no `pg-pagamentos` (capítulo 12), fora do PgBouncer (capítulo 26), e 60 mais as 18 do PgBouncer dão 78, abaixo das 100 de `max_connections`. O alvo de 35% sai do tempo de reação medido, 4 min 20 s; crescimento acima de 2× nesse intervalo fica com o descarte do capítulo 28, que já sabe sacrificar relatórios antes de autorizações.

Pagamentos sobe 50% das máquinas com CPU acima de 35% por 2 minutos ou lag do event loop acima de 50 ms por 1 minuto. Desce uma máquina a cada 5 minutos com CPU abaixo de 20% por 15 minutos: ela sai do registro, espera 15 s (deadline de 8 s com margem), fecha os SSE com `retry` para o checkout reconectar em outra réplica com `Last-Event-ID`, e desliga. O contrato do Tuiuiú obriga aviso de campanha com 48 h, e uma hora antes o mínimo sobe para 50.

Até o Kubernetes do capítulo 35, a execução usa grupos de máquinas com autoscaling do provedor (o Auto Scaling group da AWS e o managed instance group do Google Cloud são exemplos), imagem imutável, 3 workers por máquina de 4 vCPU. A lista estática do capítulo 27 dá lugar a um registro de serviços: a máquina entra quando `/pronto` responde, sai ao drenar, e proxies e gateways releem a lista a cada 5 s. De 12 workers de madrugada a 50 na Black Friday, o laço se paga; carga estável se dimensiona fixa.

`temp-01`, `api-01` e `api-02` continuam fixos. A homologação ganhou 2 conexões no conector e máximo de 6 processos, numa conta que cabe num post-it, colado no monitor do Carlos.

## Armadilhas e casos reais

> **Armadilha:** homologação que compartilha IP de saída, cota de parceiro, banco ou broker com produção é produção com outro nome e menos alarme. O teste do Carlos foi perfeito, inclusive em derrubar produção.

Partida a frio com estouro de manada: vinte máquinas novas carregam cache juntas, o stampede do capítulo 22 disparado pelo autoscaler.

Descer sem drenar. Cada descida vira uma pequena queda programada, que aparece no p99 como o mistério de toda hora cheia (o sinal de encerramento no processo é tema do capítulo 34).

Fator de pico emprestado. O do Tuiuiú vem de 12 meses de dados dele; o do slide veio da intuição do gerente, que também acha que o 49º consumidor de um tópico com 48 partições "ajuda em alguma coisa".

## Resumo

- Estimativa: negócio → taxa de pico → custo por operação → limite; pelo pico; limite fixo de terceiro não multiplica.
- Vertical: teto de catálogo, um domínio de falha. Horizontal: exige serviço sem estado e paga coordenação (USL).
- Stateless é auditoria do que o processo guarda; limite por processo vezes N cresce sozinho.
- Autoscaling: laço com atraso; métrica de saturação, histerese, alvo com folga para o tempo de reação, agenda, máximo do recurso mais escasso, descida com drenagem.

## A Lastro agora

A Lastro tem a conta do Tuiuiú: seis vezes o pico, 50 workers, shard próprio do ledger em máquina dobrada, 32 baldes, 48 partições, webhooks por Little, 24 meses online. Pagamentos, antifraude e entregador escalam sozinhos com alvo de 35%; o `conector-adquirente` fica em 10 processos fixos, e o adquirente voltou a atender o IP da Lastro. O fundador ganhou a máquina maior que pediu, para um shard só, e chamou isso de vitória.

Enquanto isso, a consultoria Java do Bazar publicou um repositório de exemplo para "ajudar a comunidade de integradores da Lastro". Está tudo lá: retry com full jitter, `Idempotency-Key` fora do laço (finalmente) e, no `application.properties`, a chave de API de produção do Bazar, com 40 horas de consultoria e nenhuma de revisão.

## Referências

- Neil J. Gunther, *Guerrilla Capacity Planning*, Springer, 2007 (Lei Universal de Escalabilidade).
- Kubernetes, Horizontal Pod Autoscaling: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- The Twelve-Factor App, VI. Processes: https://12factor.net/processes
- Apache Kafka, Modifying topics (efeito de acrescentar partições): https://kafka.apache.org/documentation/#basic_ops_modify_topic
- Google Cloud Blog, "Bringing Pokémon GO to life on Google Cloud" (2016): https://cloud.google.com/blog/products/gcp/bringing-pokemon-go-to-life-on-google-cloud
