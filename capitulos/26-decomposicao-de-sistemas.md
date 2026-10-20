# Decomposição de sistemas

## Catorze serviços, quatro pessoas e um avatar

Numa segunda-feira de manhã, a loja de discos de vinil parou de vender porque o serviço que entrega a fotinho redonda do usuário, com 48 por 48 pixels, estava fora do ar. Ninguém conseguia fechar a compra de um LP de 1977. O checkout chamava o `servico-de-avatares` para montar o cabeçalho da página de confirmação, o `servico-de-avatares` tinha travado num deploy, e o checkout, coerente com o que foi programado, devolvia `500`.

A loja é hipotética, e a história é comum. Quatro pessoas cuidam do backend. Depois de uma palestra muito convincente, o sistema foi dividido em catorze microsserviços: três serviços e meio por pessoa, e o meio serviço é o `servico-de-avatares`, que ninguém assume. O checkout faz nove chamadas de rede em série. Cada serviço mostra 99,9% de disponibilidade no painel, todos verdes, e a loja passa umas sete horas por mês sem vender.

Ninguém errou uma linha de código; o erro foi o corte. Onde se corta um sistema, e quanto custa cada corte em milissegundos, em indisponibilidade e em consistência?

## O que exatamente se está dividindo

"Monólito" e "microsserviço" misturam três coisas que vale separar, porque cada uma pode ser dividida de forma independente:

- **unidade de código**: pacotes, módulos e as regras de quem importa quem;
- **unidade de deploy**: o artefato que sobe junto, como uma imagem de contêiner, e que roda como um processo;
- **unidade de dados**: o conjunto de tabelas que só um pedaço do código escreve.

Um **monólito** é uma unidade de deploy: o código vai junto, roda no mesmo processo (em réplicas idênticas) e costuma usar um banco só. Nada obriga o código a virar bagunça, e nada impede: qualquer arquivo pode importar qualquer outro, e em algum momento um deles importa.

Um **monólito modular** mantém um deploy só, mas divide o código em módulos que expõem uma interface pública, escondem o resto e são donos das próprias tabelas. A fronteira é verificada por ferramenta no CI, e não pela boa vontade de quem está com pressa na sexta-feira.

**Microsserviços** dividem as três unidades: deploy, processo e dados próprios, com comunicação pela rede (HTTP, gRPC ou mensageria). Lewis e Fowler (2014) descrevem o estilo como serviços implantáveis de forma independente, organizados em torno de capacidades de negócio.

Os custos aparecem em lugares diferentes. Dividir o código custa disciplina; o deploy, rede; os dados, transações. Dá para pagar só o primeiro.

## Acoplamento e coesão, com régua

Os termos vêm de Stevens, Myers e Constantine (1974). **Acoplamento** é quanto do outro módulo você precisa conhecer para usar, alterar ou testar este. **Coesão** é o grau em que o conteúdo de um módulo pertence à mesma responsabilidade. O corte busca acoplamento baixo entre módulos e coesão alta dentro deles. Os níveis de acoplamento, do pior ao melhor, em termos de backend atual:

| Nível | O que é | Exemplo |
|-------|---------|---------|
| Conteúdo | Um módulo mexe no interior do outro | `pedidos` faz `UPDATE` direto na tabela de `estoque` |
| Comum | Os dois dependem de estado global compartilhado | Os dois leem e escrevem a mesma tabela `configuracoes` |
| Controle | Um passa uma flag que dirige a lógica do outro | `calcular(pedido, modo="black_friday_sem_frete")` |
| Carimbo | Passa uma estrutura inteira quando precisa de dois campos | Enviar o objeto `Cliente` completo para calcular frete por CEP |
| Dados | Passa só os valores necessários | `calcular_frete(cep, peso_gramas)` |

Parnas (1972) deu o critério de corte: cada módulo esconde uma decisão de projeto que provavelmente vai mudar, como o formato da tabela de estoque. Se três módulos conhecem esse formato, o segredo virou fofoca.

Coesão tem uma medida operacional: coisas que mudam juntas pertencem ao mesmo módulo. Se toda alteração em pedidos exige alteração em pagamentos, os dois são um módulo só que mora em dois endereços.

### Os acoplamentos que só existem em sistemas distribuídos

Quando o corte passa pela rede, surgem acoplamentos novos:

- **Temporal**: A só funciona se B estiver no ar no mesmo instante. Toda chamada síncrona cria esse acoplamento.
- **De deploy**: uma mudança exige subir A e B juntos ou numa ordem específica. Se acontece sempre, são um serviço com dois pipelines.
- **De schema**: A lê a tabela de B, e toda migração em B precisa da bênção de A.
- **Semântico**: A depende de um significado que B nunca documentou, como "status 3 quer dizer pago, exceto às quintas" (o capítulo 25 trata de contratos).

Com todos esses acoplamentos e deploys separados, o resultado é um **monólito distribuído**: o custo de rede dos microsserviços sem a independência que o justificaria. A loja de vinil tem um. Os catorze serviços sobem juntos, numa ordem que está escrita num arquivo `ORDEM_DO_DEPLOY.txt`, com o aviso "NÃO MUDAR A ORDEM (ver incidente de março)".

## O preço de trocar uma chamada de função por um pacote

Uma chamada de função no CPython custa dezenas de nanossegundos. Uma chamada a outro serviço serializa os argumentos, pega uma conexão do pool, atravessa a pilha TCP e a rede, desserializa, executa e faz tudo de volta. Um ida e volta dentro do mesmo data center fica em torno de 500 µs (Jeff Dean, 2009; ver capítulo 6). Entre zonas de disponibilidade, os provedores documentam latência de um dígito de milissegundo, e costumam cobrar pelo tráfego.

A medição abaixo, numa máquina de referência, compara as duas coisas com o mesmo cálculo. O "serviço" roda no mesmo host, o melhor caso possível: sem cabo, sem switch, sem TLS.

```python
import timeit
import httpx

def calcular_frete(cep: str, peso_gramas: int) -> int:
    return 1200 + peso_gramas // 100  # centavos; a tabela real é pior

cliente = httpx.Client(base_url="http://127.0.0.1:8001")

def frete_remoto() -> int:
    r = cliente.get("/frete", params={"cep": "01310-100", "peso_gramas": 180})
    return r.json()["centavos"]

n = 2_000
local = timeit.timeit(lambda: calcular_frete("01310-100", 180), number=n) / n
remoto = timeit.timeit(frete_remoto, number=n) / n
print(f"função:      {local * 1e9:8.0f} ns")
print(f"HTTP local:  {remoto * 1e9:8.0f} ns  ({remoto / local:,.0f}x)")
```

```text
função:            88 ns
HTTP local:    412530 ns  (4,688x)
```

A vírgula no `4,688x` é o separador de milhar do formato `:,` do Python: quase cinco mil vezes, com conexão reaproveitada e servidor ocioso. Em produção entram TLS, proxy e fila.

Meio milissegundo parece pouco até entrar num laço. Uma listagem de 50 pedidos que chama o serviço de clientes por pedido, a 2 ms cada, gasta 100 ms de rede no que era um `JOIN`. É o N+1 do capítulo 9, agora com passaporte.

A rede também falha de jeitos que uma função não falha. Uma chamada remota tem um terceiro resultado, "não sei": o timeout dispara e a operação pode ou não ter acontecido do outro lado. Cada aresta nova no grafo de serviços traz timeouts, retries, idempotência e circuit breakers (capítulos 19 e 20). As falácias da computação distribuída, atribuídas a Peter Deutsch e colegas da Sun, começam com "a rede é confiável" e "a latência é zero". A loja de vinil acreditou nas duas.

## Disponibilidade em série, ou a multiplicação que ninguém pediu

Se uma requisição só tem sucesso quando todos os serviços do caminho respondem, e as falhas são independentes, a disponibilidade do caminho é o produto das disponibilidades:

```text
A_total = A_1 × A_2 × ... × A_N
```

Com cada serviço a 99,9%, num mês de 30 dias (720 horas):

| Serviços em série | Disponibilidade composta | Indisponibilidade por mês |
|-------------------|--------------------------|---------------------------|
| 1 | 99,90% | 43 min |
| 5 | 99,50% | 3,6 h |
| 9 | 99,10% | 6,5 h |
| 14 | 98,61% | 10,0 h |
| 20 | 98,02% | 14,3 h |

As nove chamadas do checkout explicam as quase sete horas mensais sem vendas com todos os painéis verdes. Cada serviço cumpre a meta dele; o cliente, que só quer um disco, vive na multiplicação. Latências em série se somam, e as caudas também pioram: com 1% de chance de cauda por serviço, a chance de pelo menos um dos nove cair nela é `1 − 0,99⁹ ≈ 8,6%` (capítulo 6).

Redundância trabalha no sentido oposto. Componentes em paralelo, em que basta um responder, falham só quando todos falham:

```text
A_paralelo = 1 − (1 − A)^N
```

Duas réplicas de 99% dão 99,99%. Três dão 99,9999%. É essa conta que faz alguém rodar três réplicas de tudo e dormir tranquilo.

> **Armadilha:** as duas fórmulas supõem falhas independentes, e falhas reais raramente são. As réplicas usam a mesma imagem com o mesmo bug, o mesmo banco, a mesma zona e o mesmo deploy de sexta-feira. Para réplicas, a correlação torna a conta otimista: três réplicas com o mesmo erro de configuração caem juntas, com uma sincronia invejável. Para a série, a correlação torna a conta pessimista, porque serviços que caem juntos não somam indisponibilidade.

O que tira um serviço da multiplicação é remover o acoplamento temporal:

1. **Tirar a chamada do caminho crítico.** Se o avatar falhar, a página mostra uma silhueta cinza (degradação controlada, capítulo 19).
2. **Trocar a chamada síncrona por evento.** O checkout grava o pedido e publica `PedidoCriado`; e-mail e nota fiscal consomem quando puderem. O checkout passa a depender só do broker, e o serviço de e-mail pode tirar a tarde de folga sem custar uma venda (capítulos 21 e 22).
3. **Copiar o dado necessário.** O checkout mantém uma cópia local do catálogo, atualizada por eventos, e paga em consistência: a cópia pode estar segundos atrasada.

## Um banco por serviço, e o JOIN que foi embora

A regra "um banco por serviço" diz que só o serviço dono escreve e lê as próprias tabelas; os outros pedem pela API ou recebem eventos. A regra trata de posse lógica, e não exige servidores separados. Pode ser o mesmo cluster PostgreSQL com um schema e um usuário por serviço, e as permissões garantem a fronteira:

```sql
CREATE SCHEMA estoque;
CREATE ROLE svc_estoque LOGIN;
GRANT USAGE, CREATE ON SCHEMA estoque TO svc_estoque;

-- svc_pedidos não recebe nada em estoque: a fronteira vira erro
SET ROLE svc_pedidos;
SELECT quantidade FROM estoque.itens WHERE sku = 'LP-1977-RUMOURS';
```

```text
ERROR:  permission denied for schema estoque
```

O motivo é o acoplamento de conteúdo. Se dois serviços leem a mesma tabela, o schema dela virou contrato público, sem versionamento e sem dono para avisar antes de renomear a coluna. O capítulo 12 mostra quanto custa coordenar uma migração com um time só; com dois, some a agenda.

O mesmo servidor traz o vizinho barulhento: o relatório pesado de um serviço disputa CPU, I/O e conexões com o checkout de outro. Servidores separados resolvem e cobram em operação (backups, upgrades, monitoramento, tudo vezes N).

Separar os dados remove três coisas que o banco fazia de graça:

- **O `JOIN`**, que vira composição na aplicação (buscar clientes em lote) ou modelo de leitura alimentado por eventos (CQRS, capítulo 23).
- **A chave estrangeira.** O banco de pedidos ignora se o `cliente_id = 8812` existe. Pedidos órfãos são descobertos por um job de reconciliação, ou pelo suporte.
- **A transação.** "Reservar estoque e criar pedido" vira saga ou outbox (capítulo 22). Duas tabelas que precisam mudar atomicamente em quase todo fluxo indicam fronteira no lugar errado.

## Na prática

### Medindo coesão pelo histórico do git

O histórico de commits registra quais módulos mudam juntos. O script abaixo conta quantos commits tocaram cada par de módulos de `loja/<modulo>/`:

```python
import subprocess
from collections import Counter
from itertools import combinations

log = subprocess.run(
    ["git", "log", "--since=2025-10-01", "--name-only", "--format=@@"],
    capture_output=True, text=True, check=True,
).stdout

pares = Counter()
for commit in log.split("@@")[1:]:
    modulos = {
        caminho.split("/")[1]
        for caminho in commit.split()
        if caminho.startswith("loja/") and caminho.count("/") >= 2
    }
    pares.update(combinations(sorted(modulos), 2))

for (a, b), n in pares.most_common(4):
    print(f"{a:<11} + {b:<11} {n:>3} commits")
```

```text
pagamentos  + pedidos      61 commits
estoque     + pedidos      44 commits
busca       + catalogo     38 commits
estoque     + pagamentos    9 commits
```

Pedidos e pagamentos mudaram juntos 61 vezes no ano. Como serviços separados, cada uma dessas mudanças vira dois pull requests, dois deploys coordenados e uma janela de versões incompatíveis convivendo. O par `estoque + pagamentos`, com 9 commits, é o candidato a fronteira. Commits gigantes ("refatoração geral", 340 arquivos) inflam todos os pares e convém descartá-los.

### Verificando a fronteira no CI

O import-linter verifica contratos de importação em Python. Este proíbe pedidos de importar as entranhas do estoque, deixando livre a interface pública `loja.estoque.api`:

```toml
[tool.importlinter]
root_package = "loja"

[[tool.importlinter.contracts]]
name = "Pedidos só fala com estoque pela API"
type = "forbidden"
source_modules = ["loja.pedidos"]
forbidden_modules = ["loja.estoque.models", "loja.estoque.repositorio"]
```

```text
$ lint-imports
...
Contracts: 0 kept, 1 broken.

----------------
Broken contracts
----------------

Pedidos só fala com estoque pela API
------------------------------------

loja.pedidos is not allowed to import loja.estoque.models:

-   loja.pedidos.checkout -> loja.estoque.models (l.7)
```

Alguém, na linha 7 do checkout, achou mais rápido importar o model do estoque direto. Era mesmo mais rápido, por uns quatro minutos. O CI falha e a fronteira fica onde estava, sem precisar de rede. O Shopify descreveu esse caminho para o próprio monólito em Ruby e publicou a ferramenta equivalente, o Packwerk.

## Propriedades e custos

| Propriedade | Monólito | Monólito modular | Microsserviços |
|-------------|----------|------------------|----------------|
| Chamada entre partes | Função, ~100 ns | Função, ~100 ns | Rede, ~0,5 a 5 ms, pode falhar com "não sei" |
| Transação entre partes | `BEGIN ... COMMIT` | `BEGIN ... COMMIT` (mesmo banco) | Saga, outbox, consistência eventual |
| Disponibilidade do fluxo | Uma unidade | Uma unidade | Produto das dependências síncronas |
| Deploy | Tudo junto | Tudo junto | Por serviço, se não houver acoplamento de deploy |
| Escala | Réplicas do sistema inteiro | Réplicas do sistema inteiro | Por serviço |
| Isolamento de falha | Um vazamento de memória derruba tudo | Idem | Contido, se houver timeouts e bulkheads |
| Fronteira entre partes | Convenção | Verificada no CI | Imposta pela rede |
| Operação | 1 pipeline | 1 pipeline | N pipelines, tracing distribuído obrigatório |

Escala por serviço importa quando as partes têm perfis de recurso muito diferentes, como um redimensionador de imagens de 40 núcleos ao lado de uma API de 2. Deploy independente importa quando o histórico mostra que as partes mudam separadas. Isolamento de falha só existe com os mecanismos do capítulo 19; sem eles, um serviço lento contamina os chamadores pelos workers presos.

Um módulo com fronteira verificada, dados próprios e interface pública pode ser extraído depois, trocando a implementação da interface por um cliente HTTP. O padrão *strangler fig* (Fowler, 2004) descreve essa extração gradual: um proxy desvia rota por rota para o sistema novo até o antigo ficar sem tráfego e sem amigos.

## Lei de Conway, a observação

Melvin Conway escreveu em 1968, na revista Datamation, que organizações que projetam sistemas produzem projetos que copiam as próprias estruturas de comunicação. O nome "lei" veio depois, com Fred Brooks em *The Mythical Man-Month*. O mecanismo: uma interface entre dois módulos exige que os autores dos dois lados combinem o formato, e quem não conversa produz interfaces rígidas e mínimas.

Há evidência medida. MacCormack, Rusnak e Baldwin (2012) compararam produtos com a mesma função, feitos por organizações fortemente acopladas e por comunidades distribuídas de código aberto, e encontraram arquiteturas mais modulares nos segundos. Nagappan, Murphy e Basili (2008) mostraram, no Windows Vista, que métricas da estrutura organizacional previam os binários com mais defeitos melhor que métricas de código. São correlações em amostras específicas, sem status de lei da física: um time único pode construir um sistema modular, se a fronteira for verificada por ferramenta.

Para decomposição, a consequência é técnica. Um serviço mantido por várias equipes acumula acoplamento de deploy entre elas. Vários serviços mantidos por uma pessoa somam o custo operacional de todos sem ganho de autonomia, porque essa pessoa já conversa muito bem consigo mesma. A loja de vinil, com três serviços e meio por cabeça, está no segundo caso.

## Armadilhas e casos reais

> **Na vida real:** em 2023, a equipe do Prime Video publicou que a ferramenta de monitoramento de qualidade de streams foi refeita como um processo único. A versão original era orquestrada por AWS Step Functions, com componentes trocando quadros de vídeo pelo Amazon S3. Juntar tudo num processo que passa os dados em memória reduziu o custo de infraestrutura em 90%: a conta do pedágio de rede, com fatura.

> **Na vida real:** a Segment descreveu em 2018 por que voltou de mais de 140 microsserviços, um por destino de integração, para um serviço só. As bibliotecas compartilhadas tinham versões diferentes em cada serviço, e cada atualização exigia testar e implantar dezenas deles. Depois da consolidação, uma mudança na biblioteca comum passou a valer para todos os destinos num deploy só.

**Cortar por camada técnica.** Com "serviço de banco", "serviço de validação" e "serviço de regras", toda funcionalidade atravessa todos eles: acoplamento de deploy máximo, com latência de bônus. O corte por capacidade de negócio tende a acompanhar o que muda junto; em DDD, isso se chama *bounded context* (Evans, 2003).

**Nanosserviços.** Um serviço que formata CEP trabalha microssegundos e cobra meio milissegundo de pedágio.

**Biblioteca compartilhada com regra de negócio.** Um pacote `comum` com os models de todo mundo recria o acoplamento de schema por outro caminho. Mudou um campo, sobem catorze serviços.

**Extrair antes de entender a fronteira.** Dentro de um monólito, uma fronteira errada se corrige com um pull request. Entre serviços, com migração de dados, versionamento de API e meses de convivência entre versões. O `servico-de-avatares`, aliás, foi corrigido de um jeito mais barato: virou uma função de 11 linhas dentro do serviço de usuários, e a silhueta cinza nunca mais apareceu no checkout.

## Resumo

- Três unidades independentes: código (custa disciplina), deploy (custa rede), dados (custa transações).
- Monólito modular: um deploy, módulos com interface pública e tabelas próprias, fronteira verificada no CI.
- Acoplamento vai de conteúdo a dados; a rede acrescenta o temporal, o de deploy, o de schema e o semântico. Todos juntos formam um monólito distribuído.
- Coesão: o que muda junto fica junto, e o git mede isso.
- Chamada de rede: milhares de vezes uma chamada de função, mais o resultado "não sei".
- Série multiplica (nove a 99,9% dão 99,1%, 6,5 h por mês); paralelo usa `1 − (1 − A)^N`; ambas supõem independência.
- Eventos, degradação e cópias locais tiram dependências do caminho crítico.
- Um banco por serviço é posse lógica e custa `JOIN`, chave estrangeira e transação.
- Lei de Conway: observação empírica, com evidência em estudos específicos.

## Referências

- Conway, M. "How Do Committees Invent?". Datamation, abril de 1968. <https://www.melconway.com/Home/Committees_Paper.html>
- Parnas, D. L. "On the Criteria To Be Used in Decomposing Systems into Modules". Communications of the ACM, 15(12), 1972. <https://dl.acm.org/doi/10.1145/361598.361623>
- Stevens, W. P.; Myers, G. J.; Constantine, L. L. "Structured Design". IBM Systems Journal, 13(2), 1974.
- MacCormack, A.; Rusnak, J.; Baldwin, C. "Exploring the Duality between Product and Organizational Architectures: A Test of the Mirroring Hypothesis". Research Policy, 41(8), 2012.
- Nagappan, N.; Murphy, B.; Basili, V. "The Influence of Organizational Structure on Software Quality: An Empirical Case Study". ICSE 2008.
- Lewis, J.; Fowler, M. "Microservices", 2014. <https://martinfowler.com/articles/microservices.html>
- Fowler, M. "StranglerFigApplication". <https://martinfowler.com/bliki/StranglerFigApplication.html>
- Evans, E. *Domain-Driven Design*. Addison-Wesley, 2003.
- Dean, J. "Designs, Lessons and Advice from Building Large Distributed Systems". LADIS 2009.
- Documentação do import-linter. <https://import-linter.readthedocs.io/>
- Shopify Engineering. "Deconstructing the Monolith: Designing Software that Maximizes Developer Productivity", 2019. <https://shopify.engineering/deconstructing-monolith-designing-software-maximizes-developer-productivity>
- Prime Video Tech. "Scaling up the Prime Video audio/video monitoring service and reducing costs by 90%", 2023. <https://www.primevideotech.com/video-streaming/scaling-up-the-prime-video-audio-video-monitoring-service-and-reducing-costs-by-90>
- Noonan, A. "Goodbye Microservices: From 100s of problem children to 1 superstar". Segment, 2018. <https://segment.com/blog/goodbye-microservices/>
