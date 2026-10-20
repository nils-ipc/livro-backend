# Kubernetes

## Sábado, 22h14, e ninguém canta

Dona Glória estava no palco do Microfone de Ouro, unidade Tatuapé, com o microfone na mão e a introdução de "Evidências" na cabeça. Ela tinha esperado 47 minutos. A tela do bar mostrava um círculo girando. Nas outras 22 unidades da rede, o mesmo círculo girava diante de outras pessoas, todas também prontas para cantar "Evidências".

O aplicativo da fila de músicas rodava num cluster Kubernetes com seis réplicas da API `fila-de-musicas`. Às 22h09, o disco do PostgreSQL ficou lento por causa de um vizinho de hospedagem barulhento. As consultas passaram de 4 ms para 1,3 segundo. Isso deixaria a fila lenta. O que a deixou morta foi uma linha escrita por alguém que já saiu da empresa:

```yaml
livenessProbe:
  httpGet:
    path: /health   # faz SELECT 1 no banco, "para garantir"
    port: 8000
```

O `/health` passou a demorar mais que o timeout padrão da probe (1 segundo). Depois de três falhas seguidas, o Kubernetes concluiu que os seis contêineres estavam quebrados e reiniciou todos. Cada contêiner novo abriu seu pool de conexões ao mesmo tempo, o banco ficou ainda mais lento, as probes falharam de novo e, às 22h14, as seis réplicas estavam em `CrashLoopBackOff`. O banco se recuperou às 22h20. A API só voltou às 22h31, porque o Kubernetes, a essa altura, esperava cinco minutos entre uma tentativa e outra. O sistema inteiro funcionou exatamente como foi configurado.

Quem matou os pods, por que essa entidade achou que estava ajudando, e o que precisaria estar escrito naquele YAML para Dona Glória cantar às 22h10?

## O mecanismo

### Um banco de dados com opiniões

Kubernetes é uma API que guarda objetos declarativos e um conjunto de programas que tentam tornar o mundo igual a eles. O resto deriva disso.

O *control plane* tem quatro peças:

- **kube-apiserver**: o único componente que fala com o armazenamento. Autentica, autoriza, valida e grava. Todo o resto, inclusive o `kubectl`, fala com ele.
- **etcd**: armazenamento chave-valor replicado com Raft (capítulo 18). Perder o etcd sem backup equivale a perder o cluster, mesmo com todos os contêineres ainda rodando.
- **kube-scheduler**: escolhe um nó para cada pod sem nó.
- **kube-controller-manager**: hospeda dezenas de *controllers* (de Deployment, de ReplicaSet, de EndpointSlice e outros).

Cada objeto tem duas partes principais. O `spec` diz o que você quer; o `status` diz o que alguém observou. Um *controller* é um laço que lê os dois e age para aproximar um do outro. Esse laço se chama *reconciliação*, e ele é *level-triggered*: o controller reage ao estado atual, e não a uma sequência de eventos. Se uma notificação se perder, a próxima leitura do estado corrige o rumo. O controller do ReplicaSet que acorda e vê 4 pods onde o `spec` pede 6 cria 2, sem precisar saber se os outros 2 morreram de OOM, de deploy ou de tédio.

Os componentes não consultam a API em laço. Fazem *list* uma vez e depois *watch*: uma conexão HTTP longa pela qual o API server envia cada mudança (`ADDED`, `MODIFIED`, `DELETED`) com um `resourceVersion` crescente. Se a conexão cair, o cliente retoma do último `resourceVersion` visto. Milhares de watches são o normal de um cluster saudável; milhares de *list* completos ao mesmo tempo são o jeito de um cluster grande conhecer o próprio limite.

### O nó, onde o trabalho braçal acontece

Cada nó (*worker node*) roda três coisas:

- **kubelet**: faz watch dos pods atribuídos ao seu nó e pede ao *container runtime* que os crie, pela interface CRI. Também executa as probes e informa o `status` de volta ao API server.
- **container runtime**: containerd ou CRI-O, que por baixo chama o runc (o capítulo 34 descreve namespaces, cgroups e essa pilha).
- **kube-proxy**: faz watch de Services e EndpointSlices e programa regras de rede no kernel do nó. Alguns plugins de rede substituem o kube-proxy por programas eBPF.

O caminho de um pod novo: o API server grava o objeto com `spec.nodeName` vazio; o scheduler filtra os nós que comportam os *requests* do pod, pontua os que sobraram e grava o vencedor; o kubelet daquele nó vê um pod com o seu nome e o cria. Ninguém manda ordem para ninguém, o que torna o sistema tolerante a quedas e muito difícil de depurar às 22h14 de um sábado.

Por isso o *data plane* (contêineres rodando, regras de rede já programadas) continua funcionando com o control plane fora do ar. O que para é a mudança: pods que morrem não voltam e deploys não andam.

### Pods

O pod é a menor unidade que o Kubernetes agenda: um ou mais contêineres que compartilham o namespace de rede (portanto o mesmo IP e o mesmo `localhost`) e podem compartilhar volumes. O runtime cria primeiro um contêiner mínimo, o *pause*, que só segura o namespace de rede; os contêineres da aplicação entram nele.

Todo pod recebe um IP próprio, roteável de qualquer outro pod sem NAT (quem implementa é o plugin de rede, via CNI). O IP morre com o pod. O Kubernetes nunca "conserta" um pod: cria outro, com outro nome e outro IP. Guardar o IP de um pod numa variável de ambiente é um jeito criativo de garantir um incidente futuro.

### Deployments e ReplicaSets

Um **ReplicaSet** mantém N cópias de um *template* de pod, identificadas por um seletor de rótulos. Um **Deployment** gerencia ReplicaSets: cada versão do template gera um ReplicaSet com o rótulo `pod-template-hash`. Daí os nomes como `fila-de-musicas-7d9f8b6c5d-2xkqp`: Deployment, hash do template, sufixo aleatório.

Mudar qualquer campo do template cria um ReplicaSet novo. O *rolling update* é o controller do Deployment aumentando o novo e diminuindo o antigo, em passos limitados por dois parâmetros:

- `maxSurge`: quantos pods acima de `replicas` podem existir durante a troca (padrão 25%, arredondado para cima).
- `maxUnavailable`: quantos pods abaixo de `replicas` podem estar indisponíveis (padrão 25%, arredondado para baixo).

Com 6 réplicas e os padrões, o Deployment pode chegar a 8 pods e não cai abaixo de 5 prontos. Os ReplicaSets antigos ficam guardados com zero réplicas, e o `kubectl rollout undo` só aumenta um deles de novo. Se o rollout não progredir por `progressDeadlineSeconds` (padrão 600 s), o Deployment ganha a condição `Progressing=False`. Ele não desfaz nada sozinho: só registra, com toda a calma, que as coisas vão mal.

### Services, ou como achar algo que troca de IP toda hora

Um **Service** dá nome e IP estáveis a um conjunto de pods escolhido por seletor de rótulos. Um controller grava objetos **EndpointSlice** com os IPs desses pods e uma condição `ready` para cada um.

O tipo padrão, `ClusterIP`, recebe um IP virtual que nenhuma interface tem e no qual ninguém escuta. No modo iptables (ou nftables), o kube-proxy cria em cada nó regras de DNAT: um pacote destinado a `ClusterIP:porta` tem o destino reescrito para o IP de um pod pronto, sorteado. A decisão acontece por conexão, na camada 4, o que significa que uma conexão HTTP/2 ou gRPC de longa duração fica presa ao mesmo pod (o capítulo 27 trata de balanceamento L4 e L7).

Os outros tipos se empilham sobre esse: `NodePort` abre a mesma porta (faixa 30000–32767) em todos os nós, e `LoadBalancer` pede ao provedor de nuvem um balanceador que encaminha para essas portas. O DNS do cluster (normalmente CoreDNS) publica cada Service como `nome.namespace.svc.cluster.local`.

### Ingress e Gateway API

Roteamento HTTP por host e caminho e terminação TLS ficam com o **Ingress**, um objeto que descreve regras ("`fila.exemplo.com/api` vai para o Service `fila-de-musicas`"). Sozinho, ele não faz nada: um *ingress controller* (nginx, HAProxy, Envoy e outros) faz watch desses objetos e se reconfigura. Sem controller, você tem um YAML muito bem formatado e nenhum tráfego.

O Ingress padroniza pouco: timeouts e reescritas viram anotações específicas de cada controller. A **Gateway API** (v1.0 em outubro de 2023) separa infraestrutura (`Gateway`) de rotas (`HTTPRoute`, `GRPCRoute`) e põe no schema o que antes era anotação, como divisão de tráfego por peso.

### ConfigMaps e Secrets

Um **ConfigMap** guarda pares chave-valor de configuração (até 1 MiB). Um **Secret** tem o mesmo formato, com valores em base64, que é codificação e fica legível no etcd sem *encryption at rest* configurada no API server (capítulo 33). Quem pode criar pods num namespace lê os Secrets dele montando-os num pod, mesmo sem permissão de `get` sobre Secrets.

Os dois chegam ao contêiner de duas formas:

- Como **variáveis de ambiente**: lidas uma vez, na criação do contêiner. Mudar o ConfigMap não muda nada nos pods existentes.
- Como **arquivos num volume**: o kubelet atualiza os arquivos depois de uma mudança, com atraso que pode passar de um minuto (período de sincronização mais cache). Montagens com `subPath` nunca são atualizadas.

Em nenhum dos casos a aplicação é avisada; o arquivo muda e ela segue feliz com o valor de ontem. Por isso é comum gerar o nome do ConfigMap com um hash do conteúdo (`fila-config-8g7k2m4t`): mudar o conteúdo muda o nome, o nome está no template do pod, e mudar o template dispara um rolling update.

### Requests e limits

Cada contêiner declara *requests* e *limits* de CPU e memória. Os dois servem a máquinas diferentes:

- O **scheduler** só olha *requests*. Um nó comporta o pod se a soma dos requests já alocados mais o novo cabe no *allocatable* do nó. O uso real não entra na conta.
- O **kernel** só olha *limits*, pelos cgroups. Memória acima do limit dispara o OOM killer (status `OOMKilled`, código de saída 137). CPU acima do limit gera *throttling*: o processo espera o próximo período de 100 ms (o capítulo 34 descreve `cpu.max` e `memory.max`).

O request de CPU também vira peso (`cpu.weight`) na disputa por CPU e é a base do HorizontalPodAutoscaler, que mede utilização em relação a ele (o capítulo 29 trata do HPA). O request de memória não reserva memória física nenhuma; ele só entra na aritmética do scheduler.

Da combinação sai a classe de QoS do pod:

| Classe | Condição | Despejo sob pressão de memória do nó |
|---|---|---|
| Guaranteed | todo contêiner com request = limit, para CPU e memória | por último |
| Burstable | pelo menos um request ou limit, sem ser Guaranteed | pods acima do request antes |
| BestEffort | nenhum request nem limit | primeiro |

Sem memória no nó, o kubelet despeja (*evicts*) primeiro os pods que mais passaram do próprio request. Um pod sem request de memória está sempre acima do próprio request, o que faz dele o primeiro voluntário a sair.

### Probes, ou três perguntas diferentes

O kubelet faz três perguntas a cada contêiner, cada uma com sua consequência:

- **startupProbe**: "já terminou de subir?" Enquanto não passa, as outras probes não rodam. Se falhar `failureThreshold` vezes, o contêiner é reiniciado.
- **livenessProbe**: "este processo está irrecuperável?" Falhou `failureThreshold` vezes seguidas, o kubelet mata o contêiner e o reinicia.
- **readinessProbe**: "pode receber tráfego agora?" Falhou, o pod é marcado `ready=false` e sai dos EndpointSlices. Nada é reiniciado. Passou de novo, ele volta.

Padrões: `periodSeconds` 10, `timeoutSeconds` 1, `failureThreshold` 3. Uma probe que depende de algo fora do processo herda a latência desse algo, com orçamento padrão de um segundo.

Reinícios seguidos entram em *backoff* exponencial: 10 s, 20 s, 40 s, até o teto de 5 minutos, e o status mostra `CrashLoopBackOff`. O contador zera depois de 10 minutos de execução sem falhas. Foi esse teto que fez a fila de Dona Glória voltar onze minutos depois do banco.

Quem matou os pods de Dona Glória foi o kubelet de cada nó, cumprindo a livenessProbe ao pé da letra: a probe dizia que o processo estava irrecuperável, e o processo estava vivo, esperando um banco lento. A pergunta que o `/health` respondia ("o banco está rápido?") caberia, no máximo, à readinessProbe, e mesmo ali tem custo: se todas as réplicas dependem do mesmo banco, todas ficam `ready=false` juntas, e lentidão vira erro de conexão.

### Rolling update e a morte de um pod

Remover um pod dispara dois caminhos em paralelo, e nenhum espera o outro:

```text
API server: pod marcado com deletionTimestamp
  ├─ kubelet do nó:   preStop → SIGTERM → espera até terminationGracePeriodSeconds (30 s) → SIGKILL
  └─ controller:      tira o pod do EndpointSlice (ready=false, terminating=true)
                        └─ kube-proxy de CADA nó: watch → reescreve regras de DNAT
```

O segundo caminho tem mais saltos. É comum o contêiner encerrar antes de todos os nós pararem de mandar conexões para ele, e as últimas requisições encontram um `connection refused`. A correção usual é um `preStop` que espera alguns segundos antes do SIGTERM (ação `sleep` nativa desde a versão 1.30). Depois do SIGTERM, a aplicação termina as requisições em andamento e sai (o capítulo 34 trata de sinais e PID 1).

## Na prática

Este é o Deployment que teria deixado Dona Glória cantar:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fila-de-musicas
  namespace: karaoke
spec:
  replicas: 6
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: fila-de-musicas
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0          # nunca menos de 6 prontos durante o deploy
  template:
    metadata:
      labels:
        app: fila-de-musicas
    spec:
      terminationGracePeriodSeconds: 30
      containers:
        - name: api
          image: registro.exemplo.com/karaoke/fila-de-musicas:2.7.1
          ports:
            - containerPort: 8000
          envFrom:
            - configMapRef:
                name: fila-config-8g7k2m4t   # nome com hash do conteúdo
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: fila-banco
                  key: url
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              memory: 256Mi          # sem limit de CPU: sem throttling, classe Burstable
          startupProbe:
            httpGet: { path: /livez, port: 8000 }
            periodSeconds: 2
            failureThreshold: 30     # até 60 s para subir
          livenessProbe:
            httpGet: { path: /livez, port: 8000 }   # não toca no banco
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /readyz, port: 8000 }  # só estado local
            periodSeconds: 5
            failureThreshold: 2
          lifecycle:
            preStop:
              sleep:
                seconds: 5           # tempo para os kube-proxy esquecerem este pod
```

O `/livez` responde se o event loop responde; o `/readyz`, se a inicialização terminou e não chegou SIGTERM. Nenhum dos dois consulta o banco.

Na noite do incidente, com a configuração antiga, era isto que o `kubectl` mostrava:

```bash
$ kubectl get pods -n karaoke -l app=fila-de-musicas
```

```text
NAME                               READY   STATUS             RESTARTS        AGE
fila-de-musicas-7d9f8b6c5d-2xkqp   0/1     CrashLoopBackOff   7 (2m11s ago)   41m
fila-de-musicas-7d9f8b6c5d-9mjvh   0/1     CrashLoopBackOff   7 (2m40s ago)   41m
fila-de-musicas-7d9f8b6c5d-bq4ns   0/1     Running            8 (4s ago)      41m
fila-de-musicas-7d9f8b6c5d-hn5rg   0/1     CrashLoopBackOff   7 (1m58s ago)   41m
fila-de-musicas-7d9f8b6c5d-x7wzt   0/1     CrashLoopBackOff   6 (3m02s ago)   41m
fila-de-musicas-7d9f8b6c5d-zt8lc   0/1     CrashLoopBackOff   7 (2m29s ago)   41m
```

E os eventos de um dos pods contavam a história inteira em três linhas:

```bash
$ kubectl describe pod fila-de-musicas-7d9f8b6c5d-2xkqp -n karaoke
```

```text
Events:
  Type     Reason     Age                From     Message
  ----     ------     ----               ----     -------
  Warning  Unhealthy  3m (x21 over 41m)  kubelet  Liveness probe failed: Get "http://10.244.3.17:8000/health": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
  Normal   Killing    3m (x7 over 41m)   kubelet  Container api failed liveness probe, will be restarted
  Warning  BackOff    1m (x19 over 30m)  kubelet  Back-off restarting failed container api in pod fila-de-musicas-7d9f8b6c5d-2xkqp_karaoke
```

`Client.Timeout exceeded while awaiting headers` é o kubelet dizendo que esperou o segundo inteiro. `Killing` é ele cumprindo a ameaça.

O watch que os controllers usam aparece no cliente Python oficial. Este trecho, dentro do cluster, imprime cada mudança nos pods da fila durante um rolling update:

```python
from kubernetes import client, config, watch

config.load_incluster_config()  # usa o token da ServiceAccount montado no pod
v1 = client.CoreV1Api()

for evento in watch.Watch().stream(
    v1.list_namespaced_pod,
    namespace="karaoke",
    label_selector="app=fila-de-musicas",
    timeout_seconds=120,
):
    pod = evento["object"]
    pronto = any(c.type == "Ready" and c.status == "True"
                 for c in (pod.status.conditions or []))
    print(evento["type"], pod.metadata.name, pod.status.phase,
          "pronto" if pronto else "-", pod.metadata.resource_version)
```

```text
ADDED fila-de-musicas-7d9f8b6c5d-2xkqp Running pronto 9184401
ADDED fila-de-musicas-7d9f8b6c5d-9mjvh Running pronto 9184377
...
ADDED fila-de-musicas-5c8b7f9d4b-kq2xz Pending - 9201153
MODIFIED fila-de-musicas-5c8b7f9d4b-kq2xz Running - 9201170
MODIFIED fila-de-musicas-5c8b7f9d4b-kq2xz Running pronto 9201242
MODIFIED fila-de-musicas-7d9f8b6c5d-2xkqp Running - 9201248
DELETED fila-de-musicas-7d9f8b6c5d-2xkqp Succeeded - 9201391
```

A sequência mostra `maxSurge: 1` e `maxUnavailable: 0` em ação: o pod novo (`5c8b7f9d4b`, outro hash de template) nasce, fica pronto, e só então um antigo começa a morrer.

## Propriedades e custos

Errar a pergunta de uma probe custa caro:

| Probe | Ação na falha | O que ela pode checar | Custo de checar dependência externa |
|---|---|---|---|
| startup | reinicia após o limite | inicialização local terminou | reinício em laço quando a dependência demora |
| liveness | reinicia o contêiner | processo responde, sem travamento | reinício em massa de pods saudáveis |
| readiness | tira do Service | pronto para atender, sem drenagem | todas as réplicas fora juntas, Service sem endpoints |

Para os limits, as decisões têm efeitos que dá para medir:

| Escolha | Garante | Custa |
|---|---|---|
| request = limit (Guaranteed) | memória previsível, último a ser despejado | capacidade ociosa paga; pico acima do limit vira OOM |
| limit de memória > request | aproveita memória livre do nó | overcommit; despejo sob pressão |
| limit de CPU | um pod não monopoliza núcleos | throttling no p99 mesmo com o nó ocioso |
| sem limit de CPU | usa sobra do nó; peso proporcional ao request | latência varia com os vizinhos |
| sem requests | agendamento em qualquer lugar | BestEffort, HPA sem base, primeiro despejo |

O cluster tem custos fora do YAML: o control plane (gerenciado, como no Amazon EKS ou no Google GKE, ou operado por você), três versões menores por ano para acompanhar, o plugin de rede e o ingress controller. Para seis réplicas de uma API, é muita máquina para cuidar de pouca música; para quarenta serviços, o custo se dilui.

## Armadilhas e casos reais

> **Armadilha:** livenessProbe que consulta o banco, o Redis ou outro serviço. Quando a dependência fica lenta, o kubelet reinicia contêineres saudáveis, que reconectam todos juntos e pioram a dependência. Foi o sábado de Dona Glória, que, segundo testemunhas, cantou "Evidências" às 22h33 com uma emoção acumulada de 66 minutos.

> **Armadilha:** ConfigMap de nome fixo lido em variável de ambiente. Alguém muda o ConfigMap, nada acontece, alguém reinicia três dos seis pods "para testar", e o cluster passa a tarde rodando duas configurações.

> **Armadilha:** sem `preStop`, uma fração pequena das requisições recebe `connection refused` ou 502 em todo deploy. O gráfico de erros fica com o formato exato do calendário de deploys.

> **Na vida real:** no Pi Day de 2023 (14 de março), o Reddit ficou fora do ar por 314 minutos depois de atualizar um cluster do Kubernetes 1.23 para o 1.24. A versão 1.24 deixou de aplicar o rótulo `node-role.kubernetes.io/master` aos nós do control plane, substituído por `node-role.kubernetes.io/control-plane`. A configuração dos *route reflectors* do Calico (o plugin de rede) selecionava nós pelo rótulo antigo, passou a selecionar nenhum, e a rede entre pods parou. Um seletor que não casa com nada é válido e não emite um único aviso.

> **Na vida real:** em 11 de dezembro de 2024, a OpenAI implantou um serviço de telemetria novo em todos os clusters. Em cada nó, ele fazia operações caras na API do Kubernetes, com custo proporcional ao tamanho do cluster, e os API servers dos clusters grandes ficaram sobrecarregados. Os contêineres seguiam vivos, mas a descoberta de serviços por DNS dependia do control plane; quando os caches expiraram, os serviços deixaram de se encontrar. Foram cerca de quatro horas, porque a correção precisava justamente do API server sobrecarregado.

## Resumo

- Kubernetes é uma API declarativa (API server + etcd) e controllers que reconciliam `spec` e `status` por watch. Sem control plane, o que já roda continua; mudanças param.
- Pod: contêineres com rede compartilhada e IP próprio, descartável. Deployment cria um ReplicaSet por versão do template; o rolling update respeita `maxSurge` e `maxUnavailable`.
- Service: IP virtual traduzido por DNAT em cada nó, por conexão. Ingress precisa de controller.
- Secret é base64, em claro no etcd sem encryption at rest. ConfigMap em variável de ambiente nunca se atualiza.
- Scheduler olha requests; kernel olha limits; a combinação define QoS e ordem de despejo.
- Liveness reinicia, readiness tira do tráfego, startup protege a subida. Liveness não consulta dependências.
- Encerramento do pod e remoção do Service correm em paralelo: `preStop` com espera.

## Referências

- Documentação do Kubernetes, componentes do cluster: https://kubernetes.io/docs/concepts/overview/components/
- Documentação do Kubernetes, Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- Documentação do Kubernetes, Services: https://kubernetes.io/docs/concepts/services-networking/service/
- Documentação do Kubernetes, ciclo de vida do pod: https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Documentação do Kubernetes, probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Documentação do Kubernetes, requests e limits: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Documentação do Kubernetes, Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
- Gateway API: https://gateway-api.sigs.k8s.io/
- Burns, Grant, Oppenheimer, Brewer, Wilkes, "Borg, Omega, and Kubernetes", ACM Queue, 2016: https://queue.acm.org/detail.cfm?id=2898444
- Reddit Engineering, "You Broke Reddit: The Pi-Day Outage", 2023: https://www.reddit.com/r/RedditEng/
- OpenAI, relatório do incidente de 11 de dezembro de 2024: https://status.openai.com/
