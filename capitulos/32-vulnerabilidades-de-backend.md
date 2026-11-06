# Vulnerabilidades de backend

O marketplace mais novo da Lastro passou na análise comercial porque o CNPJ existia, e ficou 14 minutos como cliente antes de virar o atacante mais bem-sucedido da história da empresa.

Na quarta às 14h05, o `admin` da Pechincha Relâmpago, autenticado com passkey e autorizado pelo papel certo no tenant certo (capítulo 31), cadastrou uma inscrição de webhook com a URL `http://169.254.169.254/latest/meta-data/iam/security-credentials/`. Às 14h06, apertou "Testar endpoint", um botão que o Carlos fez no ano passado para reduzir chamados: ele faz um `GET` na URL a partir do servidor e mostra no painel o status e os primeiros 2 KB da resposta. A resposta foi uma linha, `lastro-maquina`, o nome do papel de nuvem das máquinas. Às 14h07, o admin cadastrou a mesma URL com `lastro-maquina` no fim, testou de novo e recebeu no painel, com formatação bonita, um JSON com chave de acesso, segredo e token de sessão.

O endereço `169.254.169.254` é o serviço de metadados da instância, que no exemplo da AWS (o Google Cloud e o Azure usam o mesmo IP) entrega às máquinas as credenciais temporárias do papel delas. Ele só responde a quem está dentro da máquina. O botão do Carlos estava dentro da máquina.

As máquinas do grupo de autoscaling usam a mesma imagem e o mesmo papel, porque "`temp-01` é a imagem" (capítulo 29), e o papel podia ler o bucket dos relatórios exportados, porque o serviço de relatórios precisava. Às 14h19, de um IP fora da nuvem, as credenciais listaram o bucket e baixaram 3 relatórios mensais de 2 marketplaces, com CPF dos compradores. Às 14h31, o detector de anomalias do provedor alertou que credenciais de máquina estavam sendo usadas de fora da nuvem. Às 14h40, o Carlos invalidou as sessões emitidas antes daquele minuto e desativou o botão, que ele defendeu como "a feature mais usada do painel". Era, por uma margem de 2 KB.

A autenticação e a autorização funcionaram. O ataque entrou por uma funcionalidade legítima, usada por um cliente legítimo, do jeito que ela foi construída. Quantas outras portas assim o backend da Lastro tem, e como achar todas antes da próxima Pechincha?

## As listas da OWASP, ou o ranking anual das mesmas dez formas de apanhar

A OWASP (Open Worldwide Application Security Project) publica duas listas que servem de mapa. O **OWASP Top 10** classifica riscos de aplicações web a partir de dados de testes; a edição de 2025 tem, em ordem, controle de acesso quebrado, configuração insegura, cadeia de suprimentos de software, falhas criptográficas, injeção, design inseguro, autenticação, integridade de software e dados, log e alerta, e tratamento de condições excepcionais. O SSRF, categoria própria em 2021, foi absorvido pelo primeiro item: servidor que acessa o que o usuário não poderia é controle de acesso quebrado com intermediário.

O **OWASP API Security Top 10** (2023) olha só para APIs, e a lista muda de cara:

| API 2023 | Risco | Onde este livro trata |
|---|---|---|
| API1 | autorização por objeto (BOLA) | capítulo 31 |
| API2 | autenticação quebrada | capítulo 30 |
| API3 | autorização por propriedade (BOPLA) | aqui |
| API4 | consumo irrestrito de recursos | capítulo 28 e aqui |
| API5 | autorização por função (BFLA) | aqui |
| API6 | acesso irrestrito a fluxos de negócio sensíveis | capítulos 3 e 30 (limites de saque) |
| API7 | SSRF | aqui |
| API8 | configuração insegura | aqui |
| API9 | inventário de APIs desatualizado | capítulo 11 |
| API10 | consumo inseguro de APIs de terceiros | aqui |

As listas mudam de ordem a cada edição e o conteúdo mal mexe, porque os erros são os mesmos desde que o primeiro estagiário concatenou uma string num SQL.

## SSRF, o servidor que faz o que o atacante pede

**SSRF** (*server-side request forgery*) acontece quando o servidor faz uma requisição para um destino controlado pelo usuário. O atacante não alcança a rede interna; o servidor alcança, e o atacante empresta o servidor. Toda funcionalidade que recebe URL é candidata: webhook, importação por link, preview de imagem, "testar conexão".

Os alvos de sempre:

- o serviço de metadados da nuvem, que entrega credenciais;
- `localhost`, onde moram painéis de administração, a porta de métricas e o Redis sem senha que "só escuta local";
- serviços internos sem autenticação, protegidos pela crença de que ninguém de fora chega neles;
- outros esquemas: `file:///etc/passwd`, `gopher://`, conforme a biblioteca.

Validar a URL por texto falha de quatro jeitos. **Codificações alternativas**: `http://2852039166/` é `169.254.169.254` em decimal, e `http://[::ffff:169.254.169.254]/` é o mesmo IPv4 embrulhado em IPv6. **Redirecionamentos**: a URL validada responde `302` para o metadado, e a biblioteca segue (o `requests` segue por padrão; o `httpx`, não). **DNS rebinding**: o nome resolve para um IP público na validação e, com TTL zero, para `127.0.0.1` na conexão, segundos depois. **Nome que aponta para dentro**: `meta.atacante.com` com registro A `169.254.169.254`, sem truque nenhum.

A defesa que fecha os quatro trabalha com o endereço, e não com o texto: resolver o nome, rejeitar qualquer endereço fora do espaço global (RFC 1918, loopback, link-local `169.254.0.0/16` e `fe80::/10`, CGNAT `100.64.0.0/10`, IPv6 ULA `fc00::/7`, IPv4 mapeado em IPv6 depois de desembrulhado), **conectar no IP validado** em vez de resolver de novo, mandar o nome original no `Host` e no SNI, e não seguir redirecionamento. O módulo `ipaddress` do Python faz a classificação; o resto é disciplina.

Na rede, a defesa é a segunda camada: o processo que faz requisições para URLs de terceiros roda num lugar de onde a rede interna e o metadado não são alcançáveis. No metadado, a versão 2 do serviço da AWS (IMDSv2, de 2019) exige um token obtido por `PUT` com cabeçalho próprio e permite limitar o TTL do pacote de resposta a um salto, o que derruba a maioria dos SSRF simples, que só controlam a URL de um `GET`. O Google Cloud exige o cabeçalho `Metadata-Flavor: Google` com o mesmo objetivo.

E a regra que o botão do Carlos violou com entusiasmo: a resposta de uma requisição feita a mando do usuário não volta para o usuário. SSRF sem resposta visível (*blind*) ainda permite varrer portas e disparar ações, mas não lê credencial em JSON formatado.

## Injeção, a mais velha da casa

**Injeção** é dado do usuário interpretado como código por algum interpretador: SQL, shell, template, LDAP, cabeçalho HTTP. O mecanismo é sempre a concatenação.

```python
# vulnerável: o valor vira parte do SQL
cur.execute(f"SELECT id FROM vendedores WHERE nome = '{nome}'")
# nome = "x' OR '1'='1"  →  devolve todos os vendedores

# parametrizado: o valor viaja separado do texto da consulta
cur.execute("SELECT id FROM vendedores WHERE nome = %s", (nome,))
```

Com psycopg 3, a consulta parametrizada usa o protocolo estendido do PostgreSQL: texto e valores viajam em campos separados, e o servidor nunca analisa o valor como SQL. Nome de coluna e direção de ordenação (`?ordem=valor desc`) não são parametrizáveis: vão por lista de permitidos ou por `psycopg.sql.Identifier`. ORMs protegem até alguém usar `text()` com f-string "só desta vez", que é a frase que antecede todo incidente de injeção desde 1998.

As outras injeções seguem o mesmo padrão. `subprocess.run(f"convert {arquivo}", shell=True)` entrega o shell para quem nomeou o arquivo `x; rm -rf /`; a lista de argumentos sem `shell=True` resolve. Template montado com entrada do usuário no Jinja2 executa Python (SSTI). E existe a injeção que atravessa sistemas: um campo que começa com `=`, exportado para CSV e aberto numa planilha, vira fórmula. A planilha do financeiro, a fonte da verdade desde o capítulo 1, também é um interpretador.

## Deserialização insegura, ou o pickle que executa

Deserializar é reconstruir objetos a partir de bytes. Formatos que reconstroem objetos arbitrários executam código durante a reconstrução. O `pickle` do Python é o exemplo canônico, e a documentação dele avisa no topo, em caixa de alerta, que o módulo é inseguro contra dados maliciosos:

```python
import os, pickle

class Presente:
    def __reduce__(self):
        return (os.system, ("id",))

carga = pickle.dumps(Presente())   # o atacante manda isto
pickle.loads(carga)                # o servidor abre o presente
```

```text
uid=1000(app) gid=1000(app) groups=1000(app)
```

O `__reduce__` diz ao `pickle` qual chamável usar para reconstruir o objeto, e `pickle.loads` chama. Validação depois chega ao velório: o código já rodou. O mesmo vale para `yaml.load` com o carregador completo do PyYAML (o seguro é `yaml.safe_load`) e para `jsonpickle`. Assinar o pickle com HMAC só troca o problema de lugar: quem tiver a chave executa código em todos os consumidores.

Dado que atravessa fronteira de confiança vai em formato de dados (JSON, Protocol Buffers) e é validado contra um schema na entrada. O Pydantic, que o FastAPI já usa, faz isso por padrão nas requisições; o perigo mora nos lugares que ninguém chama de entrada: mensagens do broker, cache no Redis, arquivos de parceiros, colunas `jsonb`.

## Autorização por propriedade e por função

O capítulo 31 fechou a autorização por objeto. A OWASP separa mais duas.

**BOPLA** (*broken object property level authorization*) junta dois erros. **Atribuição em massa** (*mass assignment*): o endpoint aceita o objeto inteiro e grava todo campo que vier, inclusive os que o cliente não deveria mexer. **Exposição excessiva**: a resposta serializa o objeto inteiro e confia que o front-end esconda o resto. A defesa é ter modelos diferentes para entrada e saída, com listas explícitas de campos: o modelo de entrada do Pydantic com `extra="forbid"` recusa o campo inesperado, e o `response_model` do FastAPI corta o que não estiver declarado na saída.

É o endpoint que devolve o vendedor com o hash da senha "porque o React só mostra o nome". O React mostra só o nome. O `curl` mostra tudo, e o `curl` não tem gerente de produto.

**BFLA** (*broken function level authorization*) é a rota administrativa sem checagem de papel, achada porque o caminho é previsível (`/admin`) ou porque está no OpenAPI público, documentada com exemplo e botão "Try it out".

## Dependências, o código que você não escreveu e que roda com seus privilégios

Um serviço FastAPI típico tem dezenas de dependências diretas e mais de cem transitivas, todas com as permissões do processo. O risco vem por três caminhos. **Vulnerabilidade conhecida**: o PyPA Advisory Database (consultado pelo `pip-audit`) lista o CVE, e o serviço segue com a versão afetada porque "está funcionando". **Pacote malicioso**: nome parecido com um popular (*typosquatting*) ou mantenedor comprometido. **Confusão de dependência**: um pacote interno `lastro-utils` sem índice privado bem configurado, e alguém publica `lastro-utils` versão 99 no PyPI; o instalador escolhe a versão mais alta.

As defesas são mecânicas. Lock com versões exatas e hashes (`pip install --require-hashes`, ou o lock do uv ou do Poetry): a build instala os bytes revisados, e pacote trocado no índice falha na verificação. Índice privado como fonte única. Auditoria de CVEs que falha a build. Um SBOM (lista de componentes) por imagem, para responder em minutos "onde usamos a biblioteca X?" quando sair o próximo CVE com logotipo.

## Na Lastro: a superfície de ataque revisada

A revisão percorreu, contra as duas listas, cada ponto por onde dado externo entra ou a Lastro sai. O requisito: nenhum dado controlado por cliente, comprador ou parceiro alcança credencial, rede interna ou interpretador sem uma checagem que independa da boa vontade de quem mandou.

### Webhooks, a porta que a Pechincha abriu

```text
 cadastro da inscrição          entrega (cada tentativa)
 ─────────────────────          ───────────────────────────────────────
 https, porta 443               resolve DNS ──► todos os IPs globais?
 nome, nunca IP literal              │ não ─► falha "destino-proibido"
 resolve e valida (aviso)            ▼ sim
                                conecta no IP validado (Host + SNI = nome)
                                sem redirecionamento (3xx = falha)
                                guarda só status, latência, classe de erro
                                     │
                         nós de saída de webhooks (sub-rede própria)
                         firewall: nega 10/8, 172.16/12, 192.168/16,
                                   169.254/16, 100.64/10; IP de saída próprio
```

A validação no cadastro dá erro amigável; a que protege é a da entrega, porque o DNS muda depois. O "Testar endpoint" voltou como um evento `webhook.teste` por `POST`, pelo caminho das entregas, mostrando só status e latência. A resposta, o marketplace lê no log do próprio servidor, onde ela sempre deveria estar.

Os entregadores foram para **nós de saída** dedicados, numa sub-rede sem rota para a rede interna nem para o metadado, com IP de saída próprio, separado do `203.0.113.10` liberado pelo adquirente e pelo banco (capítulos 27 e 29): uma inscrição maliciosa que faça um destino bloquear a Lastro bloqueia os webhooks, e não as autorizações. O desenho das sub-redes é do capítulo 36.

Todas as máquinas passaram a exigir token no metadado, com limite de um salto, e cada grupo de máquinas ganhou papel próprio e mínimo: o dos entregadores não lê bucket nenhum. O fundador perguntou por que a máquina precisava de papel, se no tempo dele a chave ficava num arquivo. O arquivo está no `temp-01`, e o capítulo 33 vai visitá-lo.

### O resto da superfície

| Entrada ou saída | Risco (lista) | Decisão |
|---|---|---|
| API pública e GraphQL | BOPLA (API3) | modelos de entrada `extra="forbid"`, saída por `response_model`; achado: `PATCH` de vendedor no painel aceitava `tarifa_pix` porque reusava o modelo inteiro |
| Rotas internas e de operação | BFLA (API5) | prefixo `/interno` só no proxy local, nunca no gateway; ausente do OpenAPI público |
| Ordenação e filtros | injeção (A05) | colunas por lista de permitidos; CI recusa f-string dentro de `execute` e de `text()` |
| Eventos do broker, Redis, `jsonb` | deserialização (A08) | só JSON com schema Pydantic na leitura; `pickle` proibido por regra de lint; achado: cache do painel no Redis usava `pickle` |
| Arquivos da conciliação, respostas de parceiros | consumo inseguro (API10) | resposta do adquirente validada por schema e tamanho máximo; CSV lido como texto, sem avaliação |
| Exportação para planilha | injeção de fórmula | célula que começa com `=`, `+`, `-`, `@`, tab ou CR ganha um apóstrofo na frente |
| Corpo de requisição, upload, XML | consumo de recursos (API4) | corpo até 1 MB no gateway; XML de parceiro só com parser sem entidades externas (`defusedxml`) |
| Dependências | cadeia de suprimentos (A03) | lock com hashes, índice privado único, `pip-audit` na CI, SBOM por imagem |
| Erros | configuração (A02), exceções (A10) | RFC 9457 sem stack trace nem SQL; erro em checagem de segurança nega (fail closed) |

O achado da planilha: um vendedor com o nome `=HYPERLINK("http://...","Clique aqui")` aparecia no relatório de repasses que o financeiro exporta toda segunda. Era o vendedor 42, testando "se o sistema aceitava fórmula" com a desenvoltura de quem já sacou dinheiro de cinco abas. Aceitava.

O último item da tabela pegou um clássico do capítulo 20: um `except: pass` do Carlos em volta da verificação de assinatura das notificações do banco parceiro. Assinatura inválida levantava exceção, a exceção era engolida, e a notificação seguia. Fail open, com data de 2024 e comentário `# temporario`.

## Armadilhas e casos reais

> **Na vida real:** em julho de 2019, o Capital One anunciou o vazamento de dados de cerca de 100 milhões de pessoas nos Estados Unidos e 6 milhões no Canadá. Um firewall de aplicação mal configurado, rodando numa máquina da AWS, permitiu um SSRF até o serviço de metadados, que entregou as credenciais do papel da máquina; o papel lia os buckets onde os dados estavam. O roteiro da Pechincha, com seis zeros a mais. A AWS lançou o IMDSv2 em novembro do mesmo ano.

> **Na vida real:** em 2017, a Equifax expôs dados de cerca de 147 milhões de pessoas por uma vulnerabilidade do Apache Struts (CVE-2017-5638) cuja correção tinha sido publicada em março; a invasão começou em maio. A dependência estava no inventário de risco de todo mundo, menos no dela.

Em 2021, Alex Birsan publicou em índices públicos pacotes com os nomes de dependências internas de grandes empresas (Apple, Microsoft e PayPal entre elas) e conseguiu execução de código nas redes delas, recebendo recompensas de bug bounty em vez de processos. Em março de 2024, um mantenedor do xz-utils, depois de dois anos de contribuições, inseriu um backdoor no código de release que atingia o `sshd` em algumas distribuições Linux (CVE-2024-3094). Foi descoberto por um engenheiro que estranhou meio segundo a mais no login. Lock com hashes não pega mantenedor malicioso; só garante que todo mundo instale o mesmo veneno, de forma reproduzível.

Bloquear o metadado por string (`169.254.169.254`) e esquecer o decimal, o IPv6 e o DNS do atacante: a lista para o único atacante que não precisava ser parado.

## Resumo

- OWASP Top 10 (2025) e API Security Top 10 (2023) como lista de verificação; SSRF agora em controle de acesso.
- SSRF: validar o endereço resolvido e conectar nele, sem redirecionamento; saída isolada; metadado com token; resposta não volta ao usuário.
- Injeção: parâmetros, identificadores por lista, argumentos sem shell; CSV vira fórmula.
- Deserialização: `pickle` e `yaml.load` executam código; JSON com schema na fronteira.
- BOPLA e BFLA: modelos explícitos de entrada e saída; rotas internas fora da borda.
- Dependências: lock com hashes, índice privado, auditoria na CI, SBOM.

## A Lastro agora

Webhooks saem de nós dedicados, sem rota para dentro, conectando só em IPs globais validados na hora da entrega, sem seguir redirecionamento e sem devolver a resposta a ninguém. Cada grupo de máquinas tem papel próprio e mínimo, o metadado exige token, e a CI recusa f-string em SQL, `pickle` e dependência sem hash. O financeiro abriu a planilha de repasses e viu, pela primeira vez, uma fórmula no nome do vendedor 42 aparecer como texto. Ficou desconfiado mesmo assim.

Para descobrir por onde as credenciais da Pechincha tinham passado, o Carlos fez uma busca nos logs de todos os serviços por trechos do token roubado. Não achou o token. Achou, no log do `conector-adquirente`, uma linha de depuração esquecida desde a Black Friday com o corpo inteiro da requisição de autorização. Dezesseis dígitos, validade e nome do titular, repetidos algumas centenas de milhares de vezes, em texto puro, num bucket que o papel antigo de todas as máquinas conseguia ler.

## Referências

- OWASP Top 10:2025: https://top10.owasp.org/2025/
- OWASP API Security Top 10 2023: https://owasp.org/API-Security/editions/2023/en/0x11-t10/
- OWASP, Server Side Request Forgery Prevention Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html
- OWASP, CSV Injection: https://owasp.org/www-community/attacks/CSV_Injection
- AWS, "Add defense in depth against open firewalls, reverse proxies, and SSRF vulnerabilities with enhancements to the EC2 Instance Metadata Service", novembro 2019: https://aws.amazon.com/blogs/security/defense-in-depth-open-firewalls-reverse-proxies-ssrf-vulnerabilities-ec2-instance-metadata-service/
- Google Cloud, About VM metadata: https://cloud.google.com/compute/docs/metadata/overview
- Python, `pickle` (aviso de segurança): https://docs.python.org/3/library/pickle.html
- Python, `ipaddress`: https://docs.python.org/3/library/ipaddress.html
- Psycopg 3, Passing parameters to SQL queries: https://www.psycopg.org/psycopg3/docs/basic/params.html
- pip, Secure installs (hash-checking mode): https://pip.pypa.io/en/stable/topics/secure-installs/
- pip-audit: https://github.com/pypa/pip-audit
- Capital One, "Information on the Capital One Cyber Incident", 2019: https://www.capitalone.com/digital/facts2019/
- U.S. Government Accountability Office, "Data Protection: Actions Taken by Equifax and Federal Agencies in Response to the 2017 Breach", GAO-18-559, 2018: https://www.gao.gov/products/gao-18-559
- Alex Birsan, "Dependency Confusion: How I Hacked Into Apple, Microsoft and Dozens of Other Companies", 2021: https://medium.com/@alex.birsan/dependency-confusion-4a5d60fec610
- NVD, CVE-2024-3094 (xz-utils): https://nvd.nist.gov/vuln/detail/CVE-2024-3094
