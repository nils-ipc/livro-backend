# Redes em nuvem e infraestrutura como código

## A rede que ninguém escreveu

A auditoria do Roque Rápido, uma plataforma de aulas de xadrez online, chega numa quinta-feira à tarde pedindo dois documentos "bem simples": o desenho da rede de produção e o plano para recriá-la em outra região. A equipe abre o console do provedor de nuvem e encontra três redes virtuais (`prod`, `prod-nova` e `prod-nova-2-usar-essa`), 41 regras de firewall e uma rota apontando para um recurso que ninguém reconhece.

Uma das regras se chama `libera-geral-so-hoje`. Foi criada em 14 de março de 2021 e abre a porta 5432 do PostgreSQL para `0.0.0.0/0`, a internet inteira. O "só hoje" já dura mais de cinco anos. Ninguém sabe se algum sistema depende dela, e apagá-la para descobrir seria um teste em produção com a produção como cobaia. Para completar a tarde, o financeiro pergunta por que a linha "processamento de dados no NAT" custa mais que todos os servidores juntos.

Tudo foi criado com cliques, ao longo de anos, e o único registro é a própria nuvem. Como uma rede em nuvem decide se um pacote vai de A para B, e como descrever essa rede num formato que se possa revisar, comparar com a realidade e recriar numa terça-feira qualquer?

## A rede virtual por dentro

### Um bloco de endereços e nenhum cabo

Uma **rede virtual** (VPC na AWS e no Google Cloud, VNet no Azure) é um espaço de endereços IP isolado, definido por software. O hipervisor de cada servidor físico encapsula os pacotes das suas máquinas e os entrega ao hipervisor de destino, aplicando no caminho as rotas e os firewalls que você configurou (o Google descreveu a própria implementação, o Andromeda, no NSDI 2018). O roteador da sua rede é uma função espalhada por milhares de máquinas que você nunca vai ver.

A rede nasce com um bloco CIDR, normalmente da RFC 1918 (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16); o capítulo 1 trata de CIDR. A escolha parece burocrática e é a mais difícil de desfazer: redes com blocos sobrepostos não se conectam por *peering* nem por VPN sem malabarismo de NAT. Existe um número espantoso de empresas com `10.0.0.0/16` esperando o dia de conversar com outra empresa que também tem `10.0.0.0/16`. Esse dia costuma se chamar "aquisição".

### Sub-redes, zonas e regiões

Uma **região** é uma área geográfica com várias **zonas de disponibilidade**. Cada zona é um ou mais data centers com energia, refrigeração e rede independentes, ligada às outras com latência na casa de um a dois milissegundos. A AWS documenta que as zonas de uma região ficam a menos de 100 km umas das outras: longe o bastante para que uma enchente ou uma retroescavadeira não derrube duas, perto o bastante para replicação síncrona de banco. Entre regiões, como São Paulo e Virgínia do Norte, a fibra impõe dezenas de milissegundos a cada commit síncrono (o capítulo 13 trata de replicação).

Uma **sub-rede** é uma fatia do bloco. Na AWS, cada sub-rede pertence a uma única zona; no Google Cloud e no Azure, é regional. O provedor reserva endereços em cada uma: cinco na AWS e no Azure, quatro no Google Cloud. Um `/28` na AWS tem 16 endereços e 11 usáveis, o que basta até o autoscaling resolver criar a décima segunda máquina.

O plano de endereçamento do Roque Rápido, com o módulo `ipaddress`:

```python
import ipaddress

rede = ipaddress.ip_network("10.20.0.0/16")
blocos = rede.subnets(new_prefix=20)
zonas = ["sa-east-1a", "sa-east-1b", "sa-east-1c"]

for tipo in ["publica", "privada"]:
    for zona in zonas:
        sub = next(blocos)
        print(f"{tipo:<8} {zona}  {str(sub):<14} {sub.num_addresses - 5} IPs usáveis")
```

```text
publica  sa-east-1a  10.20.0.0/20   4091 IPs usáveis
publica  sa-east-1b  10.20.16.0/20  4091 IPs usáveis
publica  sa-east-1c  10.20.32.0/20  4091 IPs usáveis
privada  sa-east-1a  10.20.48.0/20  4091 IPs usáveis
privada  sa-east-1b  10.20.64.0/20  4091 IPs usáveis
privada  sa-east-1c  10.20.80.0/20  4091 IPs usáveis
```

Dez dos 16 blocos `/20` sobram de propósito: aumentar uma sub-rede depois exige recriá-la.

Na AWS, o nome `sa-east-1a` é embaralhado por conta; o nome estável é o **AZ ID** (`sae1-az1`). Duas contas que "puseram tudo na mesma zona para economizar" podem estar em zonas diferentes, pagando a transferência que queriam evitar.

## Tabelas de rota, ou quem decide para onde o pacote vai

Cada sub-rede está associada a uma **tabela de rotas**: pares (destino CIDR, alvo). A rede escolhe, entre as rotas que contêm o destino, a de prefixo mais longo (*longest prefix match*, o algoritmo de qualquer roteador IP). Toda tabela tem uma rota `local` para o bloco da própria rede, que não pode ser removida e faz as sub-redes conversarem entre si:

```python
import ipaddress

ROTAS = {
    "10.20.0.0/16": "local",
    "10.30.0.0/16": "peering-financeiro",
    "10.30.8.0/24": "vpn-escritorio",
    "0.0.0.0/0": "nat-sa-east-1a",
}

def proximo_salto(destino: str) -> str:
    ip = ipaddress.ip_address(destino)
    candidatas = [ipaddress.ip_network(r) for r in ROTAS if ip in ipaddress.ip_network(r)]
    vencedora = max(candidatas, key=lambda rede: rede.prefixlen)
    return ROTAS[str(vencedora)]

for destino in ["10.20.7.9", "10.30.8.15", "10.30.200.1", "203.0.113.50"]:
    print(f"{destino:<14} -> {proximo_salto(destino)}")
```

```text
10.20.7.9      -> local
10.30.8.15     -> vpn-escritorio
10.30.200.1    -> peering-financeiro
203.0.113.50   -> nat-sa-east-1a
```

O `/24` vence o `/16`, e o `0.0.0.0/0` casa com tudo e perde para todas: é o destino de quem não tem para onde ir.

### Pública e privada são propriedades da tabela de rotas

Uma **sub-rede pública** tem `0.0.0.0/0` apontando para um **internet gateway**; uma **sub-rede privada** não tem. O nome não tem efeito, e já houve muita sub-rede chamada `privada` roteando alegremente para a internet. A máquina pública também precisa de um IP público; na AWS, o internet gateway faz NAT de um para um, e a interface da máquina só conhece o endereço privado, uma forma bastante zen de existir.

### NAT, a porta só de saída

Máquinas privadas saem para a internet por um **NAT gateway** numa sub-rede pública, que troca IP e porta de origem pelo IP público dele e guarda o mapeamento para a resposta. Conexões iniciadas de fora não têm mapeamento e morrem na porta. Consequências mensuráveis:

1. O NAT é por zona. Com um único NAT na zona `a`, a queda dessa zona tira a saída das outras duas, perfeitamente saudáveis. Um NAT e uma tabela de rotas por zona mantêm as falhas independentes.
2. O mapeamento usa portas. O NAT gateway da AWS suporta até 55.000 conexões simultâneas por destino único (IP, porta e protocolo); acima disso, erros de alocação de porta (o capítulo 1 trata de portas efêmeras).
3. O mapeamento expira. No NAT gateway da AWS, conexões TCP ociosas por 350 segundos são esquecidas, e a conexão do pool que dormiu seis minutos acorda morta.

E há a fatura: NAT gerenciado cobra por hora e por gigabyte processado. O backup noturno do Roque Rápido, 900 GB para o armazenamento de objetos do mesmo provedor, pagava pedágio para sair da rede e entrar no mesmo provedor do outro lado da rua. **Endpoints privados** (gateway endpoints e PrivateLink na AWS, Private Service Connect no Google Cloud) põem uma rota para o serviço do provedor dentro da rede, sem NAT. Era a resposta ao financeiro.

## Firewalls com estado e sem estado

O caminho de um pacote entre duas máquinas em sub-redes diferentes passa por dois tipos de filtro na AWS:

```text
máquina A -> [security group de A: saída] -> [ACL da sub-rede A: saída]
          -> [ACL da sub-rede B: entrada] -> [security group de B: entrada] -> máquina B
```

Um **firewall com estado** (*stateful*) mantém uma tabela de conexões rastreadas: permitida a conexão num sentido, as respostas passam sozinhas. Os **security groups** da AWS, as regras de firewall do Google Cloud e os NSGs do Azure são com estado.

Um **firewall sem estado** (*stateless*) avalia cada pacote sem memória, e a resposta precisa de regra própria. As **network ACLs** da AWS são assim. E a resposta do PostgreSQL volta para a porta efêmera do cliente (32768–60999 no Linux padrão, 1024–65535 se passou por NAT gateway), por isso a AWS sugere liberar 1024–65535 na saída. Uma ACL escrita com a lógica de um firewall com estado produz este diálogo:

```text
API:        SYN para 10.20.50.4:5432
ACL entrada: Porta 5432 vinda da sub-rede pública. Pode passar.
Banco:      SYN-ACK para 10.20.3.17:41873
ACL saída:  Porta 41873? Não conheço. Negado.
API:        (espera 1 s, retransmite o SYN, espera 2 s, retransmite...)
API:        psycopg.OperationalError: connection timeout expired
```

O banco respondeu tudo. A resposta morreu na saída da sub-rede, e o erro manda a investigação procurar um banco fora do ar durante quarenta minutos.

Security groups só têm regras de permissão, sem ordem. ACLs têm regras numeradas de permissão e de negação, e a primeira que casa decide. As regras do Google Cloud e os NSGs do Azure são com estado e ainda assim aceitam negação e prioridade: estado e ordem são propriedades independentes.

A propriedade mais útil dos security groups é aceitar outro security group como origem. A regra "PostgreSQL a partir do grupo `api`" vale para qualquer máquina com o grupo `api`, inclusive as que o autoscaling vai criar daqui a dez minutos. A regra passa a falar de identidade, e não de endereço. A `libera-geral-so-hoje` também fala de identidade: a de "qualquer ser humano ou robô com acesso à internet".

> **Armadilha:** a AWS documenta que conexões rastreadas por um security group continuam depois da remoção da regra que as permitiu. Quem remove a regra que deixava um invasor entrar e vê a conexão dele seguir firme precisa de uma ACL de negação, avaliada pacote a pacote.

## Infraestrutura como código com Terraform

**Infraestrutura como código** é descrever a infraestrutura em arquivos versionados e deixar uma ferramenta criar e alterar os recursos a partir deles. O Terraform, da HashiCorp, usa a Business Source License desde a versão 1.6 (2023); o OpenTofu, da Linux Foundation, é um fork de código aberto com a mesma linguagem e o mesmo modelo de estado. Esta seção vale para os dois.

### Configuração declarativa

A configuração, em HCL, declara o resultado desejado, e os *providers* traduzem cada recurso em chamadas à API do provedor (no Google Cloud, os equivalentes são `google_compute_network` e `google_compute_subnetwork`):

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {
    bucket       = "roque-rapido-tfstate"
    key          = "rede/producao.tfstate"
    region       = "sa-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  zonas = { "sa-east-1a" = 0, "sa-east-1b" = 1, "sa-east-1c" = 2 }
}

resource "aws_vpc" "principal" {
  cidr_block = "10.20.0.0/16"
}

resource "aws_subnet" "publica" {
  for_each          = local.zonas
  vpc_id            = aws_vpc.principal.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(aws_vpc.principal.cidr_block, 4, each.value)
}

resource "aws_subnet" "privada" {
  for_each          = local.zonas
  vpc_id            = aws_vpc.principal.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(aws_vpc.principal.cidr_block, 4, each.value + 3)
}

resource "aws_eip" "nat" {
  for_each = local.zonas
  domain   = "vpc"
}

resource "aws_nat_gateway" "por_zona" {
  for_each      = local.zonas
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.publica[each.key].id
}

resource "aws_route_table" "privada" {
  for_each = local.zonas
  vpc_id   = aws_vpc.principal.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.por_zona[each.key].id
  }
}

resource "aws_route_table_association" "privada" {
  for_each       = local.zonas
  subnet_id      = aws_subnet.privada[each.key].id
  route_table_id = aws_route_table.privada[each.key].id
}

resource "aws_security_group" "api" {
  name   = "api"
  vpc_id = aws_vpc.principal.id
}

resource "aws_security_group" "banco" {
  name   = "banco"
  vpc_id = aws_vpc.principal.id

  ingress {
    description     = "PostgreSQL apenas a partir da API"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.api.id]
  }
}
```

O `cidrsubnet` produz os mesmos `/20` do script Python (a rota pública para o internet gateway ficou de fora para caber na página). Cada referência, como `aws_vpc.principal.id`, é uma aresta num grafo de dependências; o Terraform ordena o grafo e cria em paralelo o que é independente (10 operações por padrão). A rede vem antes das sub-redes e o IP antes do NAT, sem que ninguém tenha escrito a ordem.

### Estado, o arquivo que sabe quem é quem

A configuração diz `aws_vpc.principal`; a API só conhece `vpc-0a1b2c3d4e5f60718`. O **estado** é o JSON que liga um ao outro e guarda os atributos da última operação:

```json
{
  "version": 4,
  "terraform_version": "1.13.0",
  "serial": 212,
  "lineage": "3f6c2a1e-9b7d-4c58-a0e2-7d1f4b8c9e05",
  "resources": [
    {
      "mode": "managed",
      "type": "aws_vpc",
      "name": "principal",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        { "attributes": { "id": "vpc-0a1b2c3d4e5f60718", "cidr_block": "10.20.0.0/16" } }
      ]
    }
  ]
}
```

Sem o estado, o Terraform não sabe que aquela rede é dele, e o próximo `apply` cria uma segunda. Perder o estado transforma a infraestrutura em 140 recursos órfãos.

O estado guarda atributos em texto claro, inclusive senhas geradas (a documentação avisa), e por isso fica fora do git, num *backend* remoto com criptografia e versionamento. Duas execuções simultâneas se atropelariam, então o backend tem **lock**: desde a versão 1.10, o backend S3 trava com um arquivo no próprio bucket (`use_lockfile`). A segunda execução recebe `Error acquiring the state lock` com o nome de quem segura o lock, o que resolve o mistério de quem está mexendo na rede às 23h de um sábado. O `serial` e o `lineage` impedem que uma cópia antiga sobrescreva uma nova.

### Plan e apply

O `terraform plan` lê o estado, consulta a API para atualizar cada recurso (*refresh*) e compara com a configuração. As ações: `+` cria, `-` destrói, `~` altera no lugar e `-/+` destrói e recria, quando o atributo alterado não pode mudar num recurso existente. Uma mudança de um caractere no Roque Rápido, de `cidrsubnet(..., 4, ...)` para `cidrsubnet(..., 3, ...)`, "só para as sub-redes ficarem maiores":

```text
  # aws_subnet.privada["sa-east-1a"] must be replaced
-/+ resource "aws_subnet" "privada" {
      ~ cidr_block = "10.20.48.0/20" -> "10.20.96.0/19" # forces replacement
      ~ id         = "subnet-0f1e2d3c4b5a69788" -> (known after apply)
        # (14 unchanged attributes hidden)
    }

  (... mais 5 sub-redes no mesmo estado de espírito ...)

Plan: 6 to add, 0 to change, 6 to destroy.
```

Um número mudou e as seis sub-redes seriam recriadas. O provedor se recusa a apagar sub-rede com interfaces em uso, e o `apply` fica tentando até estourar o timeout, que é a melhor maneira possível de esse plano falhar.

O plano salvo (`terraform plan -out=tfplan`) é aplicado exatamente como revisado (`terraform apply tfplan`); se o estado mudou nesse meio-tempo, o Terraform recusa com `Saved plan is stale`. O JSON do plano (`terraform show -json tfplan`) permite checagem automática. Um guarda que barra destruições, aplicado a outro plano, que mexe em duas sub-redes e remove um NAT antigo:

```python
import json
import sys

with open(sys.argv[1]) as arquivo:  # saída de: terraform show -json tfplan
    plano = json.load(arquivo)

perigosos = [
    (rc["address"], rc["change"]["actions"])
    for rc in plano["resource_changes"]
    if "delete" in rc["change"]["actions"]
]
for endereco, acoes in perigosos:
    print(f"{'+'.join(acoes):>14}  {endereco}")
if perigosos:
    sys.exit("Plano destrói recursos. Alguém precisa ler isto com calma.")
```

```text
 delete+create  aws_subnet.privada["sa-east-1a"]
 delete+create  aws_subnet.privada["sa-east-1b"]
        delete  aws_nat_gateway.antigo
Plano destrói recursos. Alguém precisa ler isto com calma.
```

Substituições aparecem como `["delete", "create"]` (ou o inverso, com `create_before_destroy`). Para recursos que não podem morrer, `lifecycle { prevent_destroy = true }` faz o próprio `plan` falhar.

### Drift, quando a realidade muda sem avisar

**Drift** é a diferença entre o estado e a infraestrutura real, causada por mudanças feitas fora do Terraform. Durante um incidente às 2h, alguém recria a `libera-geral-so-hoje` pelo console "para testar uma coisa". No dia seguinte:

```text
Note: Objects have changed outside of Terraform

  # aws_security_group.banco has changed
  ~ resource "aws_security_group" "banco" {
      ~ ingress = [
          + {
              + cidr_blocks = ["0.0.0.0/0"]
              + description = "libera-geral-so-hoje"
              + from_port   = 5432
              + to_port     = 5432
              + protocol    = "tcp"
            },
            # (1 unchanged element hidden)
        ]
    }

  # aws_security_group.banco will be updated in-place
```

A configuração diz que o grupo tem uma regra só, e o próximo `apply` remove a intrusa. Com `-detailed-exitcode`, o plan devolve 2 quando há mudanças, e um job noturno que alerta nesse código descobre o drift em horas, e não na próxima auditoria.

O drift só é visível para o que está no estado. Aqui as regras são blocos `ingress` dentro do grupo, e o Terraform gerencia o conjunto inteiro. Com regras em recursos separados (`aws_vpc_security_group_ingress_rule`), a regra clicada seria um recurso desconhecido, e o plan diria `No changes` com toda a tranquilidade. O bloco `import` (1.5 em diante) traz recursos existentes para o estado, e é assim que as 41 regras do Roque Rápido viram código, cada uma num pull request que pergunta "alguém sabe para que serve isso?". Atributos alterados legitimamente por outro sistema ficam em `lifecycle { ignore_changes = [...] }`.

### Módulos

Um **módulo** é um diretório de configuração com variáveis e saídas, chamado por outra configuração. A relação com uma função é direta: variáveis são parâmetros e `output` é o retorno.

```hcl
module "rede_producao" {
  source = "git::https://git.exemplo.com/infra/modulos.git//rede?ref=v2.3.0"

  nome   = "producao"
  cidr   = "10.20.0.0/16"
  zonas  = ["sa-east-1a", "sa-east-1b", "sa-east-1c"]
}

module "rede_recuperacao" {
  source = "git::https://git.exemplo.com/infra/modulos.git//rede?ref=v2.3.0"

  nome   = "recuperacao"
  cidr   = "10.21.0.0/16"
  zonas  = ["us-east-1a", "us-east-1b", "us-east-1c"]
}
```

O documento da auditoria sai daqui: a rede de recuperação é a mesma função com outros argumentos, num bloco sem sobreposição. O `?ref=v2.3.0` fixa a versão como um lockfile fixa uma dependência Python; sem ele, cada `terraform init` pega o que estiver na branch principal naquele dia. Renomear um recurso muda o endereço dele no estado, e o Terraform entende "destruir o antigo, criar o novo"; o bloco `moved` (1.1 em diante) transforma a refatoração numa operação só de estado.

## Propriedades e custos

| Propriedade | Firewall com estado (security group) | Firewall sem estado (ACL de sub-rede) |
|---|---|---|
| Tráfego de resposta | Permitido automaticamente | Precisa de regra para portas efêmeras |
| Granularidade | Interface de rede | Sub-rede inteira |
| Regras | Só permissão (AWS), sem ordem | Permissão e negação, ordem numérica |
| Origem por identidade | Sim (outro grupo) | Não, só CIDR |
| Remoção de regra | Conexões rastreadas podem continuar | Vale no próximo pacote |

A ACL pesa quando é preciso negar uma faixa de IPs para a sub-rede inteira e cortar conexões na hora, de preferência sem esquecer as portas efêmeras outra vez.

| Desenho de saída | Disponibilidade com falha de zona | Custo fixo | Tráfego entre zonas |
|---|---|---|---|
| Um NAT para todas as zonas | Zonas saudáveis perdem a saída | 1 NAT | Pago pelas outras zonas |
| Um NAT por zona | Só a zona com falha perde a saída | N NATs | Nenhum |
| Endpoint privado | Independe do NAT | Conforme o tipo | Nenhum |

No Terraform, um estado único para tudo deixa cada plan lento (o refresh consulta todos os recursos) e cada `apply` com raio de impacto máximo. Estados por camada e por ambiente reduzem os dois, ao custo de passar valores entre eles (`terraform_remote_state` ou `data`), um acoplamento que se versiona como contrato. O estado único tem a vantagem de que um único erro de digitação alcança tudo.

## Armadilhas e casos reais

> **Armadilha:** `count` indexa por posição. Com a lista `["a", "b", "c"]`, remover `"a"` desloca `"b"` para o índice 0 e `"c"` para o 1, e o plan propõe recriar duas sub-redes que ninguém pediu para mexer. `for_each` indexa pela chave, e só o item removido sai.

> **Armadilha:** o `terraform.tfstate` local vai para o git no primeiro commit de quem esqueceu o `.gitignore`, com as senhas do banco em texto claro. Apagar no commit seguinte não apaga do histórico; a correção é rotacionar os segredos (capítulo 33).

> **Armadilha:** `Plan: 0 to add, 0 to change, 47 to destroy.` aparece com o workspace ou o arquivo de variáveis errado. Ler a última linha do plan antes do `apply` custa três segundos.

> **Na vida real:** em 28 de fevereiro de 2017, o S3 da AWS em us-east-1 ficou indisponível por cerca de quatro horas. Segundo o relatório da AWS, um comando de um procedimento estabelecido, que deveria remover poucos servidores, recebeu um parâmetro digitado errado e removeu um conjunto muito maior, incluindo servidores de dois subsistemas de que o resto dependia. A ferramenta passou a remover capacidade mais devagar e a recusar remoções abaixo de um mínimo, o mesmo princípio do `prevent_destroy`: a ferramenta conhece o limite seguro, e o operador às 9h37 de uma terça não precisa lembrar dele.

> **Na vida real:** em 7 de dezembro de 2021, uma atividade automatizada de aumento de capacidade em us-east-1 provocou um pico de conexões que congestionou os dispositivos entre a rede interna da AWS e a rede principal, degradando vários serviços por horas, inclusive o próprio monitoramento interno. Zonas protegem contra falha de data center; componentes regionais compartilhados falham juntos, e é para isso que existe a rede de recuperação em outra região.

## Resumo

- Rede virtual: bloco CIDR isolado, implementado no hipervisor, escolhido sem sobreposição com as redes vizinhas.
- Zonas de disponibilidade são data centers independentes a um ou dois milissegundos entre si; na AWS a sub-rede é zonal e o AZ ID é o nome estável.
- Rotas pelo prefixo mais longo. Pública tem `0.0.0.0/0` para o internet gateway; privada sai por NAT, que é por zona, tem limite de portas e esquece conexões ociosas. Endpoints privados tiram o NAT do caminho e da fatura.
- Com estado, a resposta passa sozinha; sem estado, precisa de regra para portas efêmeras. Security groups aceitam outro grupo como origem.
- Terraform: estado liga endereço a ID real, é sensível, remoto e com lock. `plan` salvo é aplicado como revisado, e o JSON permite barrar destruições.
- Drift só aparece para o que está no estado; `import`, `-detailed-exitcode`, `for_each`, `moved` e módulos com versão fixada completam o kit.

## Referências

- RFC 1918, Address Allocation for Private Internets: https://www.rfc-editor.org/rfc/rfc1918
- RFC 4632, Classless Inter-domain Routing (CIDR): https://www.rfc-editor.org/rfc/rfc4632
- Dalton et al., "Andromeda: Performance, Isolation, and Velocity at Scale in Cloud Network Virtualization", NSDI 2018: https://www.usenix.org/conference/nsdi18/presentation/dalton
- AWS, Amazon VPC User Guide: https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html
- AWS, NAT gateways: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html
- AWS, Security groups: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html
- AWS, Network ACLs: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
- AWS, Security group connection tracking: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/security-group-connection-tracking.html
- AWS, Availability Zone IDs: https://docs.aws.amazon.com/ram/latest/userguide/working-with-az-ids.html
- Google Cloud, VPC networks: https://cloud.google.com/vpc/docs/vpc
- Terraform, State: https://developer.hashicorp.com/terraform/language/state
- Terraform, Sensitive data in state: https://developer.hashicorp.com/terraform/language/state/sensitive-data
- Terraform, S3 backend: https://developer.hashicorp.com/terraform/language/backend/s3
- Terraform, `terraform plan`: https://developer.hashicorp.com/terraform/cli/commands/plan
- Terraform, Refactoring with `moved` blocks: https://developer.hashicorp.com/terraform/language/modules/develop/refactoring
- Terraform, `import` block: https://developer.hashicorp.com/terraform/language/import
- OpenTofu: https://opentofu.org/
- AWS, Summary of the Amazon S3 Service Disruption in the Northern Virginia (US-EAST-1) Region (2017): https://aws.amazon.com/message/41926/
- AWS, Summary of the AWS Service Event in the Northern Virginia (US-EAST-1) Region (dezembro de 2021): https://aws.amazon.com/message/12721/
