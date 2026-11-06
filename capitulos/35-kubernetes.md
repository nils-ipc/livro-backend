# Kubernetes

O orquestrador do Carlos tinha 41 linhas de bash, um `sleep 5` e o temperamento de um segurança de boate que expulsa o cliente por ter piscado devagar.

Sexta, 20h14, abertura da "Semana da Capinha" do Bazar. Um contêiner de pagamentos passou de 1 s de lag no event loop e o laço mandou `docker restart`, que dá 10 s de prazo contra os 15 s de drenagem do capítulo 34. O processo morreu no meio de 37 autorizações, a carga foi para os outros 23, e o lag deles passou de 1 s. Em quatro minutos o laço reiniciou 22 dos 24, inclusive um que ainda subia, por não responder enquanto subia: 640 autorizações em `processando` (resolvidas pelo processo do capítulo 15) e seis minutos de `503` no Pix. O Bazar abriu chamado às 20h19: "URGENTE!!!! VOCÊS DESLIGARAM DE PROPÓSITO???". Foi de propósito só no sentido de que alguém escreveu um programa para fazer exatamente isso.

A ideia do laço estava certa; o resto, não. Quem decide onde cada um dos 90 contêineres roda, quem o reinicia, quem o tira do balanceamento e quem troca a versão sem derrubar autorização?

## O control plane, ou um banco de dados cercado de laços infinitos

O Kubernetes é um banco de estado desejado cercado de programas em `while True` comparando o desejado com o real. O laço do Carlos era um controlador. Só que sem estado desejado, sem histerese e com licença para matar.

O **control plane** guarda o estado e decide; os **nós** rodam os contêineres:

```text
             control plane
 +-------------------------------------------+
 | kube-apiserver <---> etcd (Raft, 3 ou 5)  |
 |   ^      ^                                 |
 |   |      +-- kube-scheduler                |
 |   +--------- kube-controller-manager       |
 +---|---------------------------------------+
     | watch
 +---v-------------+   +-----------------+
 | nó: kubelet     |   | nó: kubelet     |
 |     containerd  |   |     containerd  |
 |     kube-proxy  |   |     kube-proxy  |
 +-----------------+   +-----------------+
```

O **kube-apiserver** é uma API REST sobre objetos (Pod, Deployment, Service) e o único componente que fala com o **etcd**, um chave-valor replicado com o Raft do capítulo 20: 3 membros sobrevivem à perda de 1; 5, à perda de 2. Sem maioria, o cluster continua rodando o que já rodava e para de aceitar mudança. Vivo e catatônico.

Todo o resto conversa com o apiserver por **watch**: uma requisição longa que recebe cada alteração de um tipo de objeto, retomável por `resourceVersion`. O **kube-scheduler** vê pods sem nó, filtra os nós que cabem, dá nota aos que sobraram e grava o vencedor no pod. O **kube-controller-manager** roda dezenas de controladores (o de ReplicaSet cria ou apaga pods até bater o número). O **kubelet** de cada nó pede ao runtime (containerd ou CRI-O) os pods atribuídos a ele, com os namespaces e cgroups do capítulo 34.

Ninguém manda ordem para ninguém. Cada um observa, compara com o desejado e age; se morre e volta, relê tudo e continua. Isso é **reconciliação**: o script de deploy executa passos uma vez e reza; o controlador repete até o mundo concordar com ele, com a paciência de quem nunca teve plantão.

## Pods, ou o menor imóvel que o Kubernetes aluga

O Kubernetes agenda **pods**: um ou mais contêineres que dividem o namespace de rede (mesmo IP, mesmo `localhost`), podem dividir volumes e caem juntos no mesmo nó.

O modelo de rede tem uma regra: **todo pod tem um IP próprio e alcança todo outro pod sem NAT**, cumprida pelo plugin de rede (CNI). O IP é efêmero, e o pod também: morre, o controlador cria outro com nome e IP novos, e ninguém faz velório. Guardou o IP do pod num arquivo de configuração? Reinventou o `ANTIFRAUDE_HOSTS` do capítulo 27, agora com rotatividade de minutos.

O *sidecar* nativo (`initContainer` com `restartPolicy: Always`, estável desde a 1.33) sobe antes dos contêineres principais e morre depois deles.

## Deployments e rolling update, ou trocar o pneu com o carro andando e 37 autorizações no banco de trás

Um **Deployment** declara o modelo do pod (imagem por digest, capítulo 34) e o número de réplicas. Ele cria um **ReplicaSet** por versão do modelo, que mantém aquele número de pods vivos, achando-os por *labels* (pares chave-valor consultados por seletores). O Kubernetes amarra objetos assim, sem chave estrangeira; dois Deployments com o mesmo seletor apagam os pods um do outro para sempre, com zelo.

Mudar a imagem cria um ReplicaSet novo, e o **rolling update** troca os pods em lotes, limitado por `maxSurge` (pods acima do desejado, padrão 25%) e `maxUnavailable` (pods abaixo dele, padrão 25%). Com 40 réplicas e os padrões, 10 pods caem de cara: 25% a menos de capacidade, notado só no deploy do pico. O pod novo só conta como disponível depois de passar na readiness, e `kubectl rollout undo` reescala o ReplicaSet anterior.

A parte que mata autorização é o encerramento. Quando o pod é apagado, duas coisas começam **ao mesmo tempo**, sem esperar uma pela outra:

```text
pod marcado Terminating
 |-- kubelet: roda preStop, depois manda SIGTERM, espera até
 |            terminationGracePeriodSeconds (30 s), depois SIGKILL
 '-- controlador de endpoints: tira o pod do Service
       '-- kube-proxy de cada nó atualiza regras... quando der
```

O processo recebe `SIGTERM` e fecha o socket, e por um ou dois segundos outros nós ainda mandam conexões para ele, porque o kube-proxy de lá não leu a mudança: conexão recusada no meio do deploy, culpa de ninguém, sintoma de todos. O remédio é um `preStop` que só espera alguns segundos antes do `SIGTERM`. E o prazo conta desde o início do `preStop`: um `preStop` de 5 s come 5 s da drenagem.

## Services e Ingress, ou um IP que não pertence a ninguém

O **Service** dá endereço estável a pods que trocam de IP: o ClusterIP, um IP virtual sem interface, por quem ninguém responde ARP, que existe só como regra de NAT.

Um controlador mantém **EndpointSlices** com os IPs dos pods que casam com o seletor do Service **e estão prontos**. O kube-proxy de cada nó os lê e escreve regras no kernel (iptables, IPVS ou nftables) que trocam o ClusterIP por um pod sorteado; o CoreDNS resolve `pagamentos.lastro.svc.cluster.local` para o ClusterIP. É camada 4 (capítulo 27), decidida **por conexão**: uma conexão HTTP/2 que dura a vida do processo fica a vida inteira no mesmo pod, como o capítulo 12 mostrou com gRPC. O Service distribui conexões com justiça perfeita; as requisições dentro delas, ele nem vê. O tipo `LoadBalancer` pede ao provedor um balanceador externo.

Para HTTP, o **Ingress** (e a sucessora, a **Gateway API**, v1.0 em outubro de 2023) declara rotas por host e caminho, aplicadas por um controller; sem controller, é YAML decorativo.

## Secrets, ou base64 com crachá de criptografia

**ConfigMap** guarda configuração; **Secret** guarda segredo. A diferença entre os dois é menor do que o nome sugere:

```bash
$ kubectl get secret adquirente -o jsonpath='{.data.senha}' | base64 -d
s3nh4-qu3-0-c4rl0s-c0l0u-n0-ch4t
```

O valor fica em base64 e, por padrão, **em claro no etcd**. Cifrar em repouso exige configurar o apiserver com um provedor de cifra, de preferência o de KMS (o envelope encryption do capítulo 33). Mesmo cifrado, quem pode criar pod num namespace monta qualquer Secret dele e lê pelo pod. RBAC que nega `get secrets` e permite `create pods` é porta trancada com a chave no tapete. Como variável de ambiente, ainda caem no `/proc/<pid>/environ` do capítulo 33 e só mudam quando o contêiner é recriado, com a teimosia do worker convicto do capítulo 22.

## Requests, limits e a ordem de quem morre primeiro

Cada contêiner declara **requests** e **limits** de CPU e memória:

| Campo | Quem usa | Vira no cgroup (cap. 34) |
|---|---|---|
| request de CPU | scheduler (soma por nó) | `cpu.weight` (fatia sob disputa) |
| limit de CPU | kernel | `cpu.max` (throttling) |
| request de memória | scheduler, despejo | nada que limite |
| limit de memória | kernel | `memory.max` (OOM killer) |

O scheduler só soma requests: um nó de 7,5 núcleos alocáveis aceita pods até a soma chegar lá, mesmo com todos dormindo, e recusa o seguinte com a CPU real a 3%. Request baixo lota o nó de pods que depois disputam CPU; request alto paga máquina para guardar ar.

As combinações definem a **classe de QoS**: *Guaranteed* (request igual a limit em CPU e memória, em todos os contêineres), *Burstable* (algum valor declarado) e *BestEffort* (nada). Sem memória no nó, o kubelet despeja primeiro quem mais passou do request, começando pelos BestEffort. Pod sem request é o primeiro jogado do barco, e com razão: nunca disse quanto pesava. CPU além do limit deixa lento; memória além do limit mata, e por isso memória com request igual a limit reserva exatamente o que o kernel vai cobrar.

## Probes, ou o médico com licença para matar

O kubelet faz três tipos de exame, por HTTP, TCP, gRPC ou comando:

- **startup**: enquanto não passa, as outras duas nem começam; para processo que demora a subir;
- **readiness**: falhou, o pod sai dos EndpointSlices e para de receber tráfego; passou, volta;
- **liveness**: falhou, o kubelet **mata o contêiner** e o recria, com espera crescente entre reinícios (10 s, 20 s, 40 s… até 5 min: o `CrashLoopBackOff`).

Os padrões são `periodSeconds: 10`, `timeoutSeconds: 1`, `failureThreshold: 3`. Leia o segundo de novo. Um segundo de timeout numa liveness é o orquestrador do Carlos com suporte oficial e documentação em 15 idiomas. Em homologação, sob a carga da Semana da Capinha:

```text
Warning  Unhealthy  kubelet  Liveness probe failed: Get "http://10.42.3.17:8000/saude":
                             context deadline exceeded (Client.Timeout exceeded while awaiting headers)
Normal   Killing    kubelet  Container pagamentos failed liveness probe, will be restarted
```

A regra: **readiness responde "devo receber tráfego agora?" e liveness responde "este processo está irrecuperável?"**. Readiness pode ser sensível, porque o castigo é reversível. Liveness só pode falhar quando reiniciar resolve (deadlock, laço travado), e reiniciar não resolve carga alta, banco lento nem parceiro fora. Liveness que consulta o banco mata todos os pods quando o banco engasga; eles voltam, consultam o banco engasgado e morrem de novo. O health check que mata paciente, família e médico (capítulo 27), agora em todos os nós.

E o Service não tem o **modo pânico** do proxy do capítulo 27: readiness falhando em todos os pods deixa o Service sem endpoint, recusando tudo. Se ninguém está pronto, ninguém trabalha, inclusive os que estavam só cansados.

## HPA, ou o autoscaler do capítulo 29 com outro crachá

O **HorizontalPodAutoscaler** aplica a regra proporcional do capítulo 29 (`ceil(réplicas × atual/alvo)`, tolerância de 10%, 300 s de estabilização para descer) a cada 15 s, com uma pegadinha: a CPU é medida **em relação ao request**. Request de 1 núcleo com alvo de 35% são 0,35 núcleo por pod. O campo `behavior` define políticas separadas de subida e descida.

O HPA cria pods, não máquinas. Pod sem nó fica `Pending`, e um *autoscaler de nós* (Cluster Autoscaler e Karpenter são exemplos) pede máquinas ao provedor, que levam minutos. Para ter capacidade ligada, roda-se um Deployment de pods de enchimento com prioridade negativa: o pod de verdade chega, o scheduler expulsa (*preempção*) o de enchimento, que fica pendente e puxa um nó novo. Em inglês, *balloon pods*. Na Lastro, por razões óbvias, pods de lastro. A empresa levou 35 capítulos para ter lastro, e ele é feito de pod vazio.

## Na Lastro: o cluster

O Kubernetes substitui o laço do Carlos, os scripts de deploy e a lista do proxy local, pelos requisitos do capítulo 34: reação do autoscaling, limites por serviço, deploy sem perder autorização. Custa um sistema distribuído a mais para atualizar (três versões menores por ano, ~14 meses de suporte cada). Com máquinas fixas, os scripts aguentariam; com autoscaling em três zonas, a Lastro estava escrevendo um Kubernetes em bash, e mal.

O desenho:

| Item | Decisão | Requisito |
|---|---|---|
| Control plane | gerenciado (EKS, GKE e AKS são exemplos) | etcd sem plantão da Lastro |
| Nós | 8 vCPU, 16 GiB, zonas A, B e C, 9 a 36 nós | perder uma zona tira ≤ 1/3 (espalhamento por zona) |
| Drenagem de nó | PodDisruptionBudget `maxUnavailable: 10%` | atualizar nó sem afundar a autorização |
| Segmento de cartão | **cluster separado** | escopo PCI (capítulo 33) |
| Bancos, Redis, broker | **fora do cluster** | ver abaixo |

Namespace do Kubernetes separa nomes, e não kernel nem control plane. Com nós dedicados (*taints*) e NetworkPolicy, o apiserver que agenda o cofre agendaria também o relatório de risco e entraria no escopo do PCI DSS, levando junto quem administra o cluster. Um cluster a mais custa um control plane gerenciado; o compartilhado custava a auditoria olhar para tudo de novo.

Pagamentos fica assim, por pod:

| Campo | Valor | Por quê |
|---|---|---|
| CPU request / limit | 1 / 2 núcleos | GIL usa ~1 núcleo; threads em C (cap. 34) |
| memória request = limit | 320 MiB | pico medido 180 MiB (cap. 34) |
| HPA | 12–60, alvo 35% do request ou lag > 50 ms | ρ ≤ 0,7 no 2× pico; teto do banco (cap. 29) |
| `behavior` | +50%/min; −3 pods/5 min após 15 min | regras do cap. 29 |
| rolling update | `maxSurge: 20%`, `maxUnavailable: 0` | capacidade nunca cai |
| encerramento | `preStop` `sleep` 5 s; prazo 25 s | propagação + 20 s do cap. 34 |

O `preStop` usa a ação `sleep` nativa, e não `sh -c "sleep 5"`: o conector é distroless, sem shell, e o `preStop` sem binário falha direto no `SIGTERM` que existia para adiar.

As probes:

```yaml
startupProbe:
  httpGet: {path: /vivo, port: 8000}
  periodSeconds: 2
  failureThreshold: 30     # até 60 s para segredos e tarifas
readinessProbe:
  httpGet: {path: /pronto, port: 8000}
  periodSeconds: 2
  failureThreshold: 2      # o /pronto local do capítulo 27
livenessProbe:
  httpGet: {path: /vivo, port: 8000}
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 6      # 60 s seguidos sem resposta
```

O `/vivo` não consulta nada e responde do próprio event loop: com lag de 1 s, responde em 1 s, dentro dos 5 s; com o loop travado, falha seis vezes e o kubelet reinicia, a única situação em que reiniciar ajuda. A readiness segue o `/pronto` do capítulo 27 (tarifas, drenagem, lag < 50 ms). Ficar lento tira de circulação; travar mata. O laço do Carlos matava por lentidão.

Entre serviços, o ClusterIP não basta: gRPC ao antifraude e a API do ledger usam HTTP/2 de longa duração, e a Lastro depende de P2C, ejeção e modo pânico (capítulo 27). O proxy local vira **service mesh** com sidecar por pod (Istio e Linkerd são exemplos), alimentado pelos EndpointSlices, com mTLS por identidade de ServiceAccount, que o segmento de cartão usa para aceitar só o pagamentos. Custo medido: ~50 MiB por pod e +0,4 ms por salto, tirados da folga de 120 ms (capítulo 14). O sidecar é nativo: a drenagem de 15 s acontece com o proxy vivo.

Segredos continuam no gerenciador do capítulo 33: o pod troca o token da ServiceAccount, projetado pelo kubelet, por credencial do provedor (identidade de carga de trabalho). O papel por grupo de máquinas do capítulo 32 vira papel por ServiceAccount, e uma NetworkPolicy bloqueia `169.254.169.254` em todos os pods. O botão "Testar endpoint" foi enterrado; a NetworkPolicy é a lápide.

O ledger fica fora do cluster. PostgreSQL no Kubernetes existe (StatefulSet, volumes persistentes e um operador, o CloudNativePG é um exemplo), mas o ledger já tem Patroni, réplica síncrona e fencing (capítulo 23) para a exigência de nenhum lançamento confirmado perdido. Dentro do cluster, cada atualização de nó drenaria um pod de banco com failover de 30 a 40 s. Com dezenas de bancos pequenos e um time dono do operador, a conta muda. Redis e broker, gerenciados, também ficam fora.

O `repasse_final_v2_agora_vai.py` virou Deployment de 2 réplicas, nome mantido. O Kubernetes tem objeto de eleição de líder (Lease, em `coordination.k8s.io`), mas o lease do capítulo 20 continua no PostgreSQL: o Lease diria quem é o líder; só o banco, na transação que debita, pode recusar o débito do ex-líder.

## Armadilhas e casos reais

> **Na vida real:** no Pi Day de 2023, o Reddit ficou 314 minutos fora após atualizar um cluster da 1.23 para a 1.24, que removeu o label `node-role.kubernetes.io/master` (agora `control-plane`). Os *route reflectors* do Calico selecionavam nós pelo label antigo, e a rede dos pods parou. O mercado aposentou "master" por bons motivos, e o "master" se vingou em produção.

> **Armadilha:** o `resolv.conf` do pod vem com `ndots:5`. Um nome com menos de cinco pontos, como `api.adquirente.com.br`, é testado antes com cada domínio de busca do cluster, cada tentativa voltando `NXDOMAIN`. O conector fazia isso a cada conexão nova. Nome com ponto final (`api.adquirente.com.br.`) ou `dnsConfig` resolve; o CoreDNS mandou flores.

> **Armadilha:** liveness com `initialDelaySeconds` no lugar de startup probe mata, num dia lento, o processo antes de ele terminar de subir. O orquestrador do Carlos fazia isso de graça.

## Resumo

- Estado desejado no etcd, servido pelo apiserver; controladores reconciliam por watch.
- Pod: contêineres que dividem rede e nó, com IP efêmero.
- Rolling update limitado por `maxSurge` e `maxUnavailable`; no encerramento, `preStop` cobre a corrida com o Service.
- Service: IP virtual, só pods prontos, L4 por conexão.
- Secret é base64; criar pod é ler Secret.
- Requests agendam, limits viram cgroup, QoS decide o despejo.
- Readiness tira do tráfego; liveness mata, e só deve falhar quando reiniciar resolve.
- HPA mede CPU em relação ao request; nós vêm de outro autoscaler.

## A Lastro agora

Os serviços stateless da Lastro rodam num cluster gerenciado em três zonas, de 9 a 36 nós, e o segmento de cartão tem cluster próprio. Pagamentos tem 1 núcleo de request, 320 MiB garantidos, HPA de 12 a 60, rolling update sem perder capacidade e encerramento de 25 s. A readiness tira o lento do tráfego; a liveness só mata quem passou 60 s mudo. Mesh no lugar do proxy local, segredos por ServiceAccount, bancos, Redis e broker fora. O laço do Carlos foi apagado com honras e substituído por dezenas de controladores que fazem a mesma coisa, só que olhando antes.

Fora do cluster ficou o de sempre: o proxy de saída com o IP `203.0.113.10` em api-01 e api-02, e o `temp-01`, com o IP que a integração antiga do Bazar ainda usa e um kernel que não roda contêiner nem a pau. Aí o auditor do PCI DSS olhou o diagrama, apontou uma máquina sem dono na mesma rede privada do cofre e perguntou o que era. O fundador respondeu "é provisório". O auditor anotou a data de criação: seis anos atrás.

## Referências

- Kubernetes. *Cluster Architecture*. https://kubernetes.io/docs/concepts/architecture/
- Kubernetes. *Pod Lifecycle*. https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Kubernetes. *Configure Liveness, Readiness and Startup Probes*. https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes. *Deployments*. https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Kubernetes. *Sidecar Containers*. https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- Kubernetes. *Service*. https://kubernetes.io/docs/concepts/services-networking/service/
- Kubernetes Gateway API. https://gateway-api.sigs.k8s.io/
- Kubernetes. *Good practices for Kubernetes Secrets*. https://kubernetes.io/docs/concepts/security/secrets-good-practices/
- Kubernetes. *Resource Management for Pods and Containers*. https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes. *Horizontal Pod Autoscaling*. https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Kubernetes. *Releases*. https://kubernetes.io/releases/
- Reddit Engineering. *You Broke Reddit: The Pi-Day Outage* (março de 2023), em r/RedditEng. https://www.reddit.com/r/RedditEng/
