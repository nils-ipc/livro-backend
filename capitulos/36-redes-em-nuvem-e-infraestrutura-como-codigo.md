# Redes em nuvem e infraestrutura como código

O auditor do PCI DSS abriu uma sessão SSH no `temp-01` com a chave do fundador, num café, pela internet, e digitou um comando só:

```text
temp-01$ nc -vz 10.0.7.41 5432
Connection to 10.0.7.41 5432 port [tcp/postgresql] succeeded!
```

O `10.0.7.41` é o `pg-cofre`, onde moram os cartões cifrados do capítulo 33. O `temp-01` é a máquina de seis anos, kernel sem cgroups v2, porta 22 aberta para a internet desde que o fundador quis "acessar de casa". Entre os dois, nada. O cofre tinha cluster próprio, KMS, AAD e rotação anual, e estava a um `nc` da máquina mais velha e menos vigiada da empresa. Fechadura de cofre suíço, parede de drywall.

O relatório saiu com uma frase sublinhada: "ambiente sem segmentação de rede; escopo do PCI DSS = rede inteira". Pior foi o inventário. A rede foi criada pelo fundador no console e cresceu por cliques: 11 sub-redes, todas com rota para a internet, 31 grupos de firewall com 214 regras, e um grupo `default` com todas as máquinas, liberando todo tráfego entre elas. Quem criou a regra 147? Ninguém sabe. Ela libera a porta 6379 para `0.0.0.0/0` e tem a descrição "teste".

Qual o jeito de dividir a rede para o cofre ficar inalcançável de tudo que não precisa dele? E de provar, daqui a um ano, que ela continua dividida?

## Regiões, zonas e a rede virtual, ou o datacenter que você aluga em fatias

O provedor organiza a infraestrutura em **regiões** (datacenters numa área geográfica, como São Paulo) e, dentro delas, **zonas de disponibilidade**: datacenters com energia, refrigeração e rede independentes, a 1–2 ms um do outro. As zonas A, B e C do capítulo 23 são isso. Zona é domínio de falha; região é domínio de falha maior, assunto do capítulo 40.

A **rede virtual** (VPC na AWS e no Google Cloud, VNet no Azure) é uma rede privada definida por software numa região: você escolhe um CIDR da RFC 1918 (capítulo 8), como `10.20.0.0/16`, e ganha 65.536 endereços que só existem para você. O pacote entre duas máquinas suas é encapsulado pelo hipervisor, e a rede do provedor descarta pacote cujo remetente não seja o IP atribuído àquela interface. Falsificar IP de origem na VPC tem a eficácia de falsificar firma na frente do tabelião.

As **sub-redes** são fatias do CIDR; na AWS e no Azure, cada uma vive numa zona; no Google Cloud, são regionais. O provedor reserva endereços de cada sub-rede (cinco, na AWS), e quem deu uma `/28` aos nós do Kubernetes descobriu que 11 endereços acabam antes do almoço.

## Tabelas de rota, ou onde "pública" e "privada" são decididas

O que faz uma sub-rede pública ou privada é a **tabela de rotas** associada a ela, e nada mais: nem nome, nem etiqueta, nem fé. Cada tabela tem rotas `destino → alvo`, e o pacote segue a rota de **prefixo mais longo** que casa com o destino:

```text
tabela "publica"                      tabela "privada-a"
10.20.0.0/16  -> local                10.20.0.0/16  -> local
0.0.0.0/0     -> gateway-internet     0.0.0.0/0     -> nat-a
```

A rota `local` cobre a rede inteira, é criada pelo provedor e, na AWS, não pode ser removida: **toda sub-rede alcança toda sub-rede da mesma VPC**, e o isolamento interno fica por conta dos firewalls. A sub-rede **pública** tem rota padrão para o *gateway de internet*, que faz NAT um para um entre o IP privado da máquina e o IP público dela. A **privada** não tem: uma máquina lá com IP público continua inalcançável, porque a resposta para a internet não casa com rota nenhuma e é descartada. IP público pago, usado zero vezes, que é o tipo de eficiência que o fundador chama de "reserva estratégica".

Para a privada falar com o mundo, entra o **gateway NAT**: fica numa sub-rede pública, tem IP público fixo, reescreve a origem dos pacotes que saem (SNAT, capítulo 8) e só deixa entrar respostas de conexões abertas de dentro. O IP de saída é o do NAT, por mais máquinas que o autoscaling crie, e é ele que vai na allowlist do parceiro. E o NAT vive numa zona: se ela cai, as sub-redes que apontam para ele perdem a internet. Um NAT por zona dá resiliência e um IP por zona; um NAT só dá um IP e um ponto único de falha.

Cada conexão gasta uma porta de origem do IP do NAT, então há teto: na AWS, cerca de 55 mil conexões simultâneas por destino único para cada IP. Abrir conexão nova por requisição, o pecado do capítulo 8, agora tem limite e mensagem de erro.

Tráfego para serviços do provedor (armazenamento de objetos, KMS, gerenciador de segredos) dispensa NAT e internet: **endpoints privados** (PrivateLink na AWS e Private Service Connect no Google Cloud são exemplos) põem uma interface do serviço na sua sub-rede. O cofre fala com o KMS sem rota para a internet, e o auditor gosta disso quase tanto quanto gosta de dizer não.

## Firewalls com estado e sem estado, ou a diferença entre ter memória e ter regulamento

O **firewall com estado** (o *security group* da AWS, o *network security group* do Azure, as regras de firewall da VPC do Google Cloud) fica na interface de cada máquina e mantém uma tabela de conexões (*connection tracking*): liberou a entrada na 443, a resposta sai sozinha. No modelo da AWS, as regras são só de permissão, e a origem pode ser outro grupo: "aceita 5432 de quem estiver no grupo `nos-app`". A regra acompanha as máquinas que entram e saem do grupo, sem lista de IPs. É o que o `ANTIFRAUDE_HOSTS` do Carlos queria ser quando crescesse.

O **firewall sem estado** (a *network ACL* da AWS) fica na fronteira da sub-rede e avalia cada pacote isolado, em ordem numérica, com regras de permitir **e** negar. Sem memória, exige regra para a volta: a resposta da 443 sai para a porta efêmera do cliente, entre 1024 e 65535 (no Linux, 32768 a 60999, capítulo 8). Liberou a 443 e esqueceu as efêmeras? Construiu um servidor que escuta tudo e não consegue responder nada. O servidor perfeito para reunião de diretoria.

| | Com estado | Sem estado |
|---|---|---|
| Onde | interface de cada máquina | fronteira da sub-rede |
| Resposta | volta sozinha | precisa de regra explícita |
| Regras | só permitir (AWS) | permitir e negar, em ordem |
| Origem por grupo | sim | só CIDR |
| Serve para | política por papel | barreira grossa, negar faixas |

Os dois se somam: o pacote passa pela ACL da sub-rede e pelo grupo da interface. Um erro em um deles não abre a porta sozinho. Defesa em profundidade, sem precisar de palestra.

## Infraestrutura como código, ou o fim do "quem clicou nisso?"

Nenhum firewall resolve o outro problema do auditor: ninguém sabia o que existia, nem por quê. Infraestrutura criada no console é estado sem histórico. **Infraestrutura como código** descreve os recursos em arquivos versionados, revisados em pull request e aplicados por uma ferramenta. O Terraform é a referência (sob licença BSL desde agosto de 2023; o OpenTofu é o fork aberto, na Linux Foundation, com a mesma linguagem).

O Terraform é **declarativo**: o código, em HCL, diz que recursos devem existir, e a ferramenta calcula as chamadas de API. *Providers* traduzem recursos para a API de cada provedor. Referências entre recursos formam um grafo: a sub-rede referencia a VPC, que é criada antes e destruída depois; o que não depende entre si sai em paralelo.

O coração do mecanismo é o **estado**: um arquivo JSON que liga cada endereço do código (`module.rede.aws_subnet.app["a"]`) ao ID real do recurso no provedor, com os atributos da última leitura. Três consequências:

- **o Terraform só gerencia o que está no estado**. Um recurso criado no console é invisível para ele até ser importado (blocos `import`, desde a 1.5);
- **o estado guarda atributos em claro**, inclusive senhas geradas e chaves. Arquivo de estado em repositório git é vazamento com controle de versão, o mesmo crime do `.env` apagado na camada do capítulo 34;
- **o estado precisa de trava**: dois `apply` simultâneos corrompem o arquivo, e o backend remoto (armazenamento de objetos com versionamento, cifra e trava) os serializa. É o `SELECT ... FOR UPDATE` da infraestrutura.

O ciclo é **plan** e **apply**. O `plan` lê o estado, consulta o provedor (*refresh*), compara com o código e mostra o diff; o `apply` executa aquele plano. Uma das linhas do plano merece medo:

```text
  # module.rede.aws_subnet.dados["a"] must be replaced
-/+ resource "aws_subnet" "dados" {
      ~ cidr_block = "10.20.32.0/24" -> "10.20.32.0/23" # forces replacement
        id         = "subnet-0a1b2c3d4e5f60718"
    }

Plan: 1 to add, 0 to change, 1 to destroy.
```

`forces replacement` quer dizer que o atributo não muda no lugar: o Terraform destrói e recria. Numa sub-rede com três bancos dentro, quem não lê o `plan` descobre no `apply`, na frente do canal inteiro. `lifecycle { prevent_destroy = true }` faz o Terraform recusar qualquer plano que destrua o recurso.

**Drift** é a diferença entre estado e realidade causada por mudança fora do Terraform. O `plan` a detecta nos recursos que gerencia, e `terraform plan -detailed-exitcode` sai com código 2 quando há diferença, o que permite um job agendado que alarma. O próximo `apply` desfaz o drift, porque o código é a fonte da verdade. Quem abriu porta pelo console à meia-noite a vê fechada pelo pipeline às 9h, e aprende infraestrutura declarativa do jeito que se aprende `git push --force`.

**Módulos** são diretórios com variáveis e saídas, reaproveitados: um módulo `zona` cria sub-redes, rotas e NAT de uma zona, e três chamadas criam três zonas. Para repetir recursos, `for_each` com chaves estáveis (`"a"`, `"b"`, `"c"`) evita o problema do `count`: remover o primeiro item renumera os outros, e o Terraform planeja recriar todos, um dominó em que cada peça é uma sub-rede de produção.

## Na Lastro: a rede refeita, e o enterro

A rede nova nasceu em Terraform, numa VPC nova (`10.20.0.0/16`), porque refazer a antiga no lugar seria `forces replacement` em cascata em sub-redes com bancos dentro. O CIDR não se sobrepõe ao antigo `10.0.0.0/16`, o que permitiu ligar as duas por *peering* na migração: com CIDRs sobrepostos, o roteador não tem como saber em qual das duas redes mora o `10.0.1.10`.

O segmento de cartão ficou numa **VPC separada** (`10.30.0.0/20`), sem peering com a principal. O único caminho entre elas é um endpoint privado: pagamentos chega na entrada do cofre por uma interface na própria sub-rede, só na 443, e o cofre não tem rota nenhuma para a rede principal. O requisito é o escopo do PCI DSS: o que não tem caminho de rede até o ambiente de dados de cartão sai do escopo, e "não tem caminho" se prova com tabela de rotas, coisa que um auditor lê em minutos.

```text
                     internet
                        |
   VPC principal 10.20.0.0/16 (zonas A, B, C)
   +------------------------------------------------+
   | publica /24 x3: balanceador 203.0.113.50,      |
   |                 NAT app (1/zona)               |
   | app /19 x3:     nós do cluster principal       |
   | saida /24 x3:   entregadores de webhook, NAT   |
   |                 próprio 203.0.113.30           |
   | dados /24 x3:   pg-ledger, pg-pagamentos,      |
   |                 Redis, PgBouncer               |
   +---------------------|--------------------------+
                         | endpoint privado, só 443
   VPC cde 10.30.0.0/20 (zonas A, B)
   +---------------------v--------------------------+
   | cofre, pg-cofre, conector, Redis do cofre      |
   | NAT a: 203.0.113.10   NAT b: 203.0.113.11      |
   +------------------------------------------------+
```

Os IPs de saída resolveram uma charada que vinha do capítulo 27. O adquirente aceita no máximo dois IPs na allowlist, e quem fala com ele agora é só o conector, dentro do segmento. Por isso o segmento tem duas zonas, A e B, com um NAT em cada: o `203.0.113.10`, transferido do proxy de saída de api-01 (é um IP reservado transferível, capítulo 8), e o `203.0.113.11`, novo, no lugar que era do `temp-01` na allowlist. Três zonas pediriam três IPs; o contrato do adquirente permite dois, e o cofre ficou com três réplicas em duas zonas. Perder uma zona deixa o segmento com metade da capacidade e o mesmo IP de saída da outra metade.

O banco do Pix recebe chamadas de pagamentos e repasses, da rede principal. Os três NATs da rede de aplicação ganharam IPs novos, o formulário do banco (dez dias úteis, firma reconhecida) foi enviado antes de tudo, e só depois da confirmação o tráfego mudou de caminho e o forward proxy de api-01 e api-02 foi desligado. Na sub-rede de saída dos webhooks (capítulo 32), a rota `local`, que não sai, mostrou o limite: o "sem rota interna" virou uma ACL sem estado que **nega** `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` e `169.254.0.0/16` e permite só 443 para fora e efêmeras de volta. Negar faixas inteiras é o que o grupo com estado, só de permissão, não faz.

Os firewalls com estado seguem um grupo por papel, com origem por grupo:

| Destino | Porta | Origem permitida |
|---|---|---|
| nós do cluster (gateways) | 8443 | grupo do balanceador |
| PgBouncer do ledger e de pagamentos | 6432 | grupo dos nós do cluster |
| PostgreSQL | 5432 | grupo do PgBouncer, grupo de replicação |
| Redis de cache | 6379 | grupo dos nós do cluster |
| entrada do cofre (endpoint) | 443 | grupo dos nós de pagamentos |

São 47 regras no lugar de 214, e cada uma tem um motivo escrito no pull request que a criou. Ninguém tem porta 22 aberta: o acesso a máquinas é pela sessão gerenciada do provedor, autenticada pela identidade do capítulo 30 e gravada. O grupo `default` ficou vazio, sem regra nenhuma, e um teste na CI recusa qualquer recurso que o use.

O Terraform tem um estado por camada (`rede`, `cde`, `dados`, `clusters`, `dns`), cada um com backend e trava, para que um erro no plano do DNS não alcance um banco. A rede antiga foi importada antes de desmontada, para a demolição também ter `plan`. O pipeline faz `plan` em todo pull request e `apply` só da `main`, com aprovação; humanos têm console somente leitura, com a quebra de vidro do capítulo 31. Os IPs reservados do adquirente e do banco têm `prevent_destroy`, porque perder um deles custa dez dias úteis e um formulário com firma.

Na primeira semana, o job noturno de drift alarmou às 3h: uma regra liberando 5432 para o IP de casa do Carlos, criada pelo console às 23h40 com a descrição "temporária, debug". O `apply` das 9h a removeu. O Carlos abriu um pull request com a mesma regra, a revisão perguntou o motivo, e o motivo era um `SELECT` que a réplica de relatórios responderia sem regra nenhuma.

E chegou o dia do `temp-01`. O tráfego dele foi medido por 30 dias: a integração antiga do Bazar, que resolvia DNS uma vez na vida e guardava o IP efêmero `198.51.100.7`, era a última cliente. A consultoria Java do Bazar reiniciou o servidor (quatro horas faturadas), o tráfego zerou e ficou zerado por 14 dias. Então tiraram um snapshot do disco, por via das dúvidas, e o `temp-01` foi parado. Parar uma máquina com IP efêmero devolve o IP ao provedor, sem volta: a decisão era irreversível no instante do clique, e foi tomada assim mesmo. Trinta dias depois, sem nenhum chamado, a máquina foi destruída. Uptime final: seis anos, dois meses e onze dias.

## Armadilhas e casos reais

> **Na vida real:** em junho de 2014, a Code Spaces, empresa de hospedagem de código, teve o console da conta de nuvem invadido. O invasor exigiu resgate e, quando a empresa tentou retomar o controle, apagou máquinas, buckets, snapshots e backups, todos na mesma conta. A empresa anunciou o encerramento das operações dias depois. Credencial de console com poder de apagar tudo, inclusive o backup, é um único ponto de falha com senha.

> **Armadilha:** um NAT só, numa zona, para a rede inteira. Funciona até a zona cair, e aí as outras duas zonas, saudáveis, perdem o adquirente junto. O tráfego entre zonas até o NAT também é cobrado à parte pela maioria dos provedores; a conta chega antes do incidente.

> **Armadilha:** `apply` com estado local. O notebook vai para a manutenção e a produção vira órfã: os recursos existem, nenhuma ferramenta sabe que são dela. Adoção por `import`, um por um, com papelada.

> **Armadilha:** confiar no `plan` sem ler o `forces replacement`. Renomear um recurso no código também planeja destruir e recriar; o bloco `moved` diz ao Terraform que é o mesmo objeto com endereço novo. Sem ele, refatorar o código é demolir a produção.

## Resumo

- Região reúne zonas de disponibilidade, domínios de falha independentes a 1–2 ms um do outro.
- A rede virtual é um CIDR privado; sub-redes são fatias dele, por zona na maioria dos provedores.
- Pública ou privada é a tabela de rotas: rota padrão para o gateway de internet ou para um NAT.
- A rota local liga toda a VPC; isolamento interno é firewall, e isolamento forte é outra rede.
- NAT dá IP de saída fixo e só deixa entrar respostas; vive numa zona e tem limite de portas.
- Firewall com estado devolve a resposta e aceita grupos como origem; sem estado avalia pacote a pacote e permite negar.
- Terraform: código declarativo, estado com trava e segredos, plan antes de apply, drift detectado e desfeito.
- `forces replacement`, `count` renumerado e renomeação sem `moved` destroem recursos.

## A Lastro agora

A Lastro tem duas redes em Terraform: a principal, em três zonas, com sub-redes públicas, de aplicação, de saída e de dados, e a do segmento de cartão, em duas zonas, ligada à principal só por um endpoint privado na 443. O adquirente vê os IPs `203.0.113.10` e `203.0.113.11`, ambos de NATs do segmento; o banco vê os NATs da rede de aplicação; os webhooks saem pelo `203.0.113.30`, por uma sub-rede que nega a rede interna. São 47 regras com motivo, nenhuma porta 22, drift verificado toda noite e console somente leitura. O auditor refez o `nc` do `temp-01` e não conseguiu, porque o `temp-01` não existe mais. O financeiro fez um minuto de silêncio, e a planilha ganhou uma aba "in memoriam".

Com a infraestrutura inteira em código revisado, o gerente de produto concluiu que qualquer mudança agora é segura, desde que passe pela CI. Na terça seguinte, uma mudança no cálculo da tarifa passou pela CI, por dois aprovadores e pelo deploy, foi para todas as réplicas de pagamentos de uma vez e passou uma hora cobrando um centavo a mais em cada cobrança. A CI estava verde. O financeiro, não.

## Referências

- RFC 1918: *Address Allocation for Private Internets*. https://www.rfc-editor.org/rfc/rfc1918
- AWS. *How Amazon VPC works* (sub-redes, tabelas de rotas, gateways). https://docs.aws.amazon.com/vpc/latest/userguide/how-it-works.html
- AWS. *NAT gateways*. https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html
- AWS. *Compare security groups and network ACLs*. https://docs.aws.amazon.com/vpc/latest/userguide/infrastructure-security.html
- Google Cloud. *VPC networks*. https://cloud.google.com/vpc/docs/vpc
- HashiCorp. *Terraform Language Documentation* (state, plan, `import`, `moved`, `lifecycle`). https://developer.hashicorp.com/terraform/language
- HashiCorp. *Sensitive data in state*. https://developer.hashicorp.com/terraform/language/state/sensitive-data
- OpenTofu. https://opentofu.org/
- PCI Security Standards Council. *Guidance for PCI DSS Scoping and Network Segmentation*. https://www.pcisecuritystandards.org/
