# Autorização e multitenancy

## O dentista que somou um

O Dr. Plínio, da clínica Sorriso Pleno, abriu a ficha do paciente 1042 no sistema de agendamento que a clínica assina por R$ 189 ao mês. A URL era `https://app.agendadente.com.br/pacientes/1042`. Por curiosidade (ou por tédio entre duas obturações), ele trocou o final para 1043.

Apareceu a ficha da Dona Rosângela, com nome, telefone, histórico de canal e uma observação clínica sobre o medo dela de motor de alta rotação. Dona Rosângela nunca pisou na Sorriso Pleno. Ela é paciente da Dente de Ouro, a concorrente do outro lado da rua.

O Dr. Plínio testou 1044, 1045 e mais umas trezentas. Depois mandou um e-mail educado ao suporte com o assunto "acho que vocês têm um problema". O suporte respondeu em quatro minutos: "o sistema exige login, então está seguro". E estava mesmo, no sentido estrito de que só usuários logados conseguiam ver todos os pacientes de todas as clínicas.

A situação é hipotética, mas o código por trás dela aparece em toda auditoria:

```python
paciente = await sessao.get(Paciente, paciente_id)
```

A pergunta que este capítulo responde: o que faltou nessa linha, em que camada do sistema essa checagem deveria morar e como garantir que a clínica 7 nunca veja um dado da clínica 8, nem quando alguém esquece o `WHERE`?

## Quem pode fazer o quê com o quê

Autenticação responde "quem é você" (o capítulo 30 trata dela). Autorização responde outra pergunta: este sujeito pode executar esta ação sobre este recurso, neste contexto? São quatro entradas e uma saída booleana:

```text
decidir(sujeito, ação, recurso, contexto) -> permitir | negar
```

O recurso é uma coisa específica (o paciente 1043, e não "pacientes" em geral); o contexto reúne o resto: horário, IP, MFA recente.

A literatura de controle de acesso (o padrão XACML, da OASIS, popularizou os termos) separa dois papéis. O **PEP** (*policy enforcement point*) é o trecho de código que intercepta a ação e aplica a decisão. O **PDP** (*policy decision point*) é quem calcula a decisão. Podem ser a mesma função Python ou dois serviços em continentes diferentes.

Duas regras valem para qualquer modelo. A primeira é negar por padrão: se nenhuma regra permite, a resposta é não. A segunda é decidir sobre o recurso concreto. O sistema do Dr. Plínio checava "usuário autenticado pode ler pacientes" e parava aí, o que é uma regra perfeitamente implementada sobre a pergunta errada.

Os três modelos de mercado diferem em como guardam e calculam essa decisão.

### RBAC: permissões penduradas em papéis

No RBAC (*role-based access control*), formalizado por Ferraiolo e Kuhn em 1992, por Sandhu e colegas em 1996 (RBAC96) e padronizado como ANSI INCITS 359-2004, usuários recebem papéis e papéis recebem permissões. O usuário nunca recebe permissão direta.

```python
PERMISSOES_POR_PAPEL = {
    "recepcionista": {"agenda:ler", "agenda:editar", "paciente:ler"},
    "dentista": {"agenda:ler", "paciente:ler", "prontuario:ler", "prontuario:editar"},
    "gerente": {"agenda:ler", "relatorio:ler", "financeiro:ler"},
}

def pode(papeis: set[str], permissao: str) -> bool:
    return any(permissao in PERMISSOES_POR_PAPEL.get(p, set()) for p in papeis)

print(pode({"recepcionista"}, "prontuario:ler"))
print(pode({"recepcionista", "dentista"}, "prontuario:ler"))
```

```text
False
True
```

A checagem custa uma busca em conjunto, e auditar "quem pode editar prontuário" é uma consulta simples. O padrão também prevê hierarquia de papéis e separação de deveres.

O limite aparece quando a regra depende do recurso. "Dentista pode ler prontuário" é RBAC. "Dentista pode ler prontuário dos pacientes que ele atende, na clínica dele" não cabe em papel nenhum. A tentativa de encaixar resulta na **explosão de papéis**: `dentista_clinica_7`, `dentista_clinica_8_somente_leitura`, `dentista_clinica_7_ferias_cobertura_dr_plinio`. Com 2.000 clínicas e cinco papéis, são 10.000 papéis, e o painel de administração vira um campo de busca com rolagem infinita.

### ABAC: regras sobre atributos

No ABAC (*attribute-based access control*), descrito no NIST SP 800-162 (2014), a decisão é uma função dos atributos do sujeito, do recurso, da ação e do ambiente. Não existe tabela de permissões; existe uma política.

```python
from datetime import time

def pode_ler_prontuario(usuario: dict, prontuario: dict, agora: time) -> bool:
    return (
        usuario["clinica_id"] == prontuario["clinica_id"]
        and "dentista" in usuario["papeis"]
        and (prontuario["sigiloso"] is False or usuario["id"] == prontuario["dentista_id"])
        and time(7) <= agora <= time(21)  # prontuário depois das 21h? vá dormir
    )
```

O RBAC vira um caso particular: "papel" é só mais um atributo. Linguagens de política como Rego (do Open Policy Agent) e Cedar existem para tirar essas regras do código da aplicação, versioná-las e testá-las separadamente.

O custo: o PDP precisa de todos os atributos na hora da decisão, alguns em outro serviço, e responder "quem consegue ler o prontuário 88?" exige avaliar a política para cada usuário do sistema.

### ReBAC: o grafo de quem é o quê de quem

No ReBAC (*relationship-based access control*), a permissão deriva de relações entre objetos. O sistema de referência é o Zanzibar, do Google, descrito num artigo da USENIX ATC 2019. Ele guarda relações como tuplas no formato `objeto#relação@sujeito`:

```text
pasta:radiografias#leitor@grupo:dentistas#membro
grupo:dentistas#membro@usuario:plinio
arquivo:rx-1043.png#pai@pasta:radiografias
```

A primeira tupla diz que os membros do grupo `dentistas` são leitores da pasta. O sujeito pode ser outro conjunto de usuários (um *userset*), e é daí que vem a recursão. Regras de reescrita completam o modelo: "quem é leitor da pasta pai é leitor do arquivo". Uma checagem vira uma busca no grafo:

```python
TUPLAS = {
    ("pasta:radiografias", "leitor", "grupo:dentistas#membro"),
    ("grupo:dentistas", "membro", "usuario:plinio"),
    ("arquivo:rx-1043.png", "pai", "pasta:radiografias"),
}

def tem(objeto: str, relacao: str, sujeito: str, prof: int = 0) -> bool:
    if prof > 10:
        return False  # ciclo ou hierarquia com 11 níveis; nos dois casos, não
    for obj, rel, suj in TUPLAS:
        if (obj, rel) != (objeto, relacao):
            continue
        if suj == sujeito:
            return True
        if "#" in suj:  # userset: membros de outro objeto
            outro, rel_outro = suj.split("#")
            if tem(outro, rel_outro, sujeito, prof + 1):
                return True
    if relacao == "leitor":  # reescrita: leitor da pasta pai lê o arquivo
        for obj, rel, pai in TUPLAS:
            if obj == objeto and rel == "pai" and tem(pai, "leitor", sujeito, prof + 1):
                return True
    return False

print(tem("arquivo:rx-1043.png", "leitor", "usuario:plinio"))
print(tem("arquivo:rx-1043.png", "leitor", "usuario:bia"))
```

```text
True
False
```

O artigo do Zanzibar relata trilhões de listas de acesso, milhões de checagens por segundo, latência p95 abaixo de 10 ms e disponibilidade acima de 99,999% em três anos. Implementações abertas inspiradas nele incluem OpenFGA e SpiceDB.

O artigo também descreve o **problema do novo inimigo**. A Bia é removida da pasta e, logo depois, alguém coloca um arquivo sensível lá dentro. Se a checagem ler uma réplica atrasada, que ainda tem a tupla antiga, a Bia vê o arquivo novo com a permissão velha. O Zanzibar resolve com um token de consistência (o *zookie*) devolvido na escrita do conteúdo: a checagem posterior exige um snapshot pelo menos tão novo quanto o token. É o problema de ler as próprias escritas (capítulo 17), com a diferença de que aqui o erro tem nome, sobrenome e acesso a radiografias.

## Onde a checagem mora

Uma requisição atravessa o gateway, o serviço e o banco. Cada camada sabe coisas diferentes, e por isso cada uma consegue checar coisas diferentes.

O **gateway** sabe se o token é válido, quais escopos ele carrega e qual rota foi chamada; recusa `DELETE /clinicas/7` de quem não tem escopo `admin`. De quem é o paciente 1043 ele não sabe, porque isso está numa tabela que ele nunca viu.

O **serviço** dono dos dados é o único lugar que tem o recurso em mãos. A checagem por objeto mora nele, idealmente dentro da própria consulta.

O **banco** pode ser a última barreira, com row-level security, que aparece mais adiante.

### IDOR, ou a falha que cabe numa linha

**IDOR** (*insecure direct object reference*) é o nome do defeito do Dr. Plínio: o servidor aceita um identificador vindo do cliente e devolve o objeto sem verificar se aquele sujeito tem direito a ele. A OWASP chama a mesma coisa de BOLA (*broken object level authorization*) e a colocou em primeiro lugar no API Security Top 10 de 2019 e de novo no de 2023. O capítulo 32 percorre a lista inteira.

O código vulnerável, em FastAPI com SQLAlchemy 2.x assíncrono:

```python
@app.get("/pacientes/{paciente_id}")
async def ler_paciente(
    paciente_id: int,
    usuario: Usuario = Depends(usuario_atual),     # autenticou, ótimo
    sessao: AsyncSession = Depends(obter_sessao),
):
    paciente = await sessao.get(Paciente, paciente_id)  # autorizou? ninguém perguntou
    if paciente is None:
        raise HTTPException(status_code=404)
    return paciente
```

A correção põe a regra de acesso na própria consulta:

```python
    consulta = select(Paciente).where(
        Paciente.id == paciente_id,
        Paciente.clinica_id == usuario.clinica_id,
    )
    paciente = (await sessao.execute(consulta)).scalar_one_or_none()
    if paciente is None:
        raise HTTPException(status_code=404)  # inexistente e alheio: mesma resposta
```

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $TOKEN_PLINIO" https://api.agendadente.com.br/pacientes/1043
```

```text
404
```

O 404 para objeto alheio é deliberado. Um 403 confirmaria que o paciente 1043 existe, e um atacante que recebe 403 para uns IDs e 404 para outros acabou de ganhar um contador de pacientes da concorrência.

Em listagens, filtrar depois de carregar também quebra a paginação: a página pede 20 linhas, o código descarta as 17 alheias e o usuário recebe 3 itens e um cursor para "mais".

Três variações do mesmo defeito escapam de quem só testa o `GET`:

1. **Referências na escrita.** `POST /consultas` com `{"paciente_id": 1043}` cria uma consulta da Sorriso Pleno para a paciente da Dente de Ouro. Todo ID recebido no corpo precisa da mesma checagem que o ID da URL.
2. **Campos que o cliente não deveria controlar.** Um `PATCH /usuarios/me` que aceita o modelo inteiro deixa o usuário mandar `{"clinica_id": 8}` e se mudar de clínica (a OWASP chama isso de *mass assignment*). Um esquema Pydantic de entrada sem os campos protegidos resolve.
3. **IDs imprevisíveis.** Trocar o inteiro por UUIDv4 dificulta adivinhar, e só isso. IDs vazam em logs, e-mails, links compartilhados e no histórico do navegador. Se a checagem não existe, o UUID só aumenta o tempo de digitação do atacante.

## Multitenancy, ou quantos clientes cabem num banco

O sistema do Dr. Plínio é **multitenant**: uma única instalação serve muitos clientes (os *tenants*, aqui as clínicas), e os dados de um nunca podem aparecer para outro. Entre clínicas, um IDOR vira contrato rescindido e, com dado de saúde, assunto para a LGPD.

Existem quatro modelos de isolamento, do mais separado ao mais compartilhado. A documentação de SaaS da AWS usa os nomes *silo* (tudo separado), *pool* (tudo compartilhado) e *bridge* (misturas).

**Banco por tenant.** Cada clínica tem o próprio banco, às vezes a própria instância. A aplicação resolve o tenant (pelo subdomínio ou pelo token) e escolhe a string de conexão. Esquecer um `WHERE` vaza dados da própria clínica para a própria clínica, o que é inofensivo. O custo: cada banco tem processos, memória e pool próprios (o capítulo 11 mostra quanto custa uma conexão no PostgreSQL), e uma migração vira um laço sobre 2.000 bancos, com o banco 1.377 falhando às 3h por um motivo que só ele tem.

**Schema por tenant.** Um banco, um schema PostgreSQL por clínica (`clinica_7.pacientes`, `clinica_8.pacientes`). A aplicação ajusta o `search_path` a cada transação, e o isolamento depende dele. Com 2.000 schemas de 60 tabelas, o catálogo tem 120.000 tabelas fora os índices, e o que percorre o catálogo (`pg_dump`, autovacuum, migrações) fica proporcionalmente mais lento.

**Coluna de tenant.** Todas as clínicas nas mesmas tabelas, com `clinica_id` em cada linha. É o modelo mais barato por tenant e o único em que uma consulta esquecida vaza dados de todo mundo de uma vez. A disciplina fica na aplicação: toda consulta filtra por `clinica_id`.

**Coluna de tenant com row-level security.** O mesmo modelo, com o banco aplicando o filtro sozinho.

### Row-level security no PostgreSQL

A row-level security (RLS), disponível desde o PostgreSQL 9.5, anexa uma política a cada tabela. O planner injeta a expressão da política em toda consulta, como um `WHERE` que o desenvolvedor não tem como esquecer.

```sql
CREATE TABLE pacientes (
    clinica_id bigint NOT NULL,
    id bigint GENERATED ALWAYS AS IDENTITY,
    nome text NOT NULL,
    PRIMARY KEY (clinica_id, id)
);

ALTER TABLE pacientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE pacientes FORCE ROW LEVEL SECURITY;

CREATE POLICY isolamento_clinica ON pacientes
    USING (clinica_id = NULLIF(current_setting('app.clinica_id', true), '')::bigint);
```

Cada linha ali tem um motivo:

- `USING` filtra as linhas visíveis em `SELECT`, `UPDATE` e `DELETE`. Numa política sem `WITH CHECK` que vale para todos os comandos, o PostgreSQL usa a mesma expressão para validar as linhas gravadas em `INSERT` e `UPDATE`.
- `FORCE` aplica a política também ao dono da tabela, que de outro modo a ignora. Superusuários e roles com `BYPASSRLS` ignoram sempre. Se a aplicação conecta com o usuário que criou as tabelas, sem `FORCE`, a RLS existe só na documentação interna.
- `current_setting('app.clinica_id', true)` lê uma variável de configuração customizada; o `true` faz devolver `NULL` em vez de erro quando ela nunca foi definida. O `NULLIF` cobre um detalhe que pega muita gente: depois do primeiro `SET LOCAL` na sessão, a variável continua existindo com valor `''` ao fim da transação, e `''::bigint` dá erro. Com `NULL`, a comparação nunca é verdadeira e a consulta devolve zero linhas.

Sem tenant definido, nada aparece. Com tenant, só o dele. Gravar para outro é recusado:

```text
app=> SELECT count(*) FROM pacientes;
 count
-------
     0
(1 row)

app=> BEGIN;
app=*> SELECT set_config('app.clinica_id', '7', true);
 set_config
------------
 7
(1 row)

app=*> SELECT clinica_id, id, nome FROM pacientes WHERE id IN (1042, 1043);
 clinica_id |  id  |       nome
------------+------+------------------
          7 | 1042 | Valdir Nogueira
(1 row)

app=*> INSERT INTO pacientes (clinica_id, nome) VALUES (8, 'Paciente Infiltrado');
ERROR:  new row violates row-level security policy for table "pacientes"
```

O 1043 sumiu sem que a consulta mencionasse clínica nenhuma. O terceiro parâmetro de `set_config` igual a `true` equivale a `SET LOCAL`: o valor morre no fim da transação. Isso importa com pool de conexões. Um `SET` de sessão sobrevive à devolução da conexão ao pool, e a próxima requisição, de outra clínica, herda o tenant anterior. Com PgBouncer em modo *transaction* (capítulo 11), a próxima transação nem roda no mesmo processo do servidor, e o `SET LOCAL` é a única forma que funciona.

Na aplicação, o tenant entra no início de cada transação:

```python
async def obter_sessao(usuario: Usuario = Depends(usuario_atual)):
    async with fabrica_de_sessoes() as sessao, sessao.begin():
        await sessao.execute(
            text("SELECT set_config('app.clinica_id', :c, true)"),
            {"c": str(usuario.clinica_id)},  # SET não aceita parâmetro; set_config aceita
        )
        yield sessao
```

A chave primária `(clinica_id, id)` também tem função. Ela permite chaves estrangeiras compostas:

```sql
CREATE TABLE consultas (
    clinica_id bigint NOT NULL,
    id bigint GENERATED ALWAYS AS IDENTITY,
    paciente_id bigint NOT NULL,
    inicio timestamptz NOT NULL,
    PRIMARY KEY (clinica_id, id),
    FOREIGN KEY (clinica_id, paciente_id) REFERENCES pacientes (clinica_id, id)
);
```

Com isso, uma consulta da clínica 7 apontando para um paciente da clínica 8 viola a FK, e o banco recusa a referência cruzada da seção anterior sem depender de nenhuma checagem na aplicação. E o índice começando por `clinica_id` serve à política, que entra em toda consulta: sem ele, cada `SELECT` filtra o tenant numa varredura da tabela inteira.

## Propriedades e custos

Entre os modelos de decisão:

| | RBAC | ABAC | ReBAC |
|---|---|---|---|
| Unidade de regra | papel → permissão | expressão sobre atributos | tupla de relação + reescrita |
| Regra por objeto | não expressa | expressa | expressa |
| Custo da checagem | busca em conjunto | avaliar a política com os atributos carregados | busca no grafo, profundidade variável |
| "Quem acessa X?" | consulta direta | avaliar a política para cada sujeito | percorrer o grafo ao contrário |
| Dados necessários | papéis do usuário | todos os atributos envolvidos | tuplas sincronizadas com o sistema de origem |
| Onde dói | explosão de papéis | auditoria e atributos remotos | consistência das tuplas (novo inimigo) |

Sistemas reais costumam combinar os três.

Entre os modelos de isolamento:

| | Banco por tenant | Schema por tenant | Coluna | Coluna + RLS |
|---|---|---|---|---|
| Esquecer o filtro | vaza nada | vaza se o `search_path` errar | vaza tudo | política barra |
| Custo marginal por tenant | alto (instância ou banco, pool) | médio (objetos no catálogo) | ~zero | ~zero |
| Migração | N execuções | N execuções | 1 | 1 |
| Vizinho barulhento | isolado por instância | compartilha CPU, I/O e locks | compartilha tudo | compartilha tudo |
| Backup/restauração de um tenant | trivial | `pg_dump -n` | exportação filtrada | exportação filtrada |
| Residência de dados por país | instância na região | difícil | difícil | difícil |
| Relatório entre tenants | consulta federada | `UNION` de N schemas | `GROUP BY` | role com `BYPASSRLS` |

O vizinho barulhento (*noisy neighbor*) é o tenant cujo relatório de fim de mês consome o I/O do banco compartilhado e deixa a agenda das outras 1.999 clínicas lenta. Com banco por tenant, ele só deixa lenta a própria agenda. Por isso o modelo híbrido aparece com frequência: os tenants pequenos ficam no banco compartilhado, e o que paga contrato corporativo, exige residência de dados ou gera 40% da carga ganha banco próprio. O roteamento passa a consultar um diretório "tenant → banco", com o mesmo desenho do diretório de shards do capítulo 14.

## Armadilhas e casos reais

> **Armadilha:** o job em segundo plano. A requisição HTTP define o tenant no middleware, e a RLS funciona. O worker que consome a fila de lembretes por SMS roda fora desse middleware, conecta com uma role que tem `BYPASSRLS` "porque estava dando zero linhas" e envia o lembrete da Dona Rosângela para o celular do Dr. Plínio. Toda mensagem de fila precisa carregar o tenant, e o worker precisa defini-lo antes de tocar no banco.

Outros vazamentos entre tenants que não passam pelo `WHERE`:

- **Cache sem tenant na chave.** `cache.get(f"paciente:{id}")` com IDs que só são únicos dentro da clínica entrega o paciente 12 da clínica 7 para a clínica 8. A chave inclui o tenant (capítulo 16).
- **Busca e analytics.** O índice de busca textual e o data warehouse são cópias dos dados, sem a RLS do banco de origem. O filtro por tenant precisa ser refeito lá.
- **Mensagens de erro.** `violates unique constraint "pacientes_cpf_key"` ao cadastrar um CPF conta à clínica 7 que aquele CPF já é paciente de alguém no sistema. A unicidade precisa ser `(clinica_id, cpf)`.
- **Role de manutenção.** Quem roda o script de correção como superusuário roda sem RLS. O `UPDATE` sem `WHERE` vira, nessa role, um `UPDATE` sem `WHERE` em todas as clínicas.

> **Na vida real:** em maio de 2019, o jornalista Brian Krebs revelou que o site da First American Financial, empresa americana de seguro de títulos imobiliários, expunha cerca de 885 milhões de documentos, alguns de 2003, com dados bancários, números de Seguro Social e extratos. Os documentos eram servidos por URLs com um número sequencial e sem nenhuma checagem de acesso: quem recebia o link do próprio documento podia trocar o número e ler o de outra pessoa. O mesmo defeito do Dr. Plínio, sem nem o login na frente.

> **Na vida real:** em agosto de 2021, a empresa de segurança Wiz divulgou a ChaosDB, uma falha no Azure Cosmos DB. Um recurso de notebooks Jupyter integrado ao serviço permitia obter as chaves primárias de bancos de outros clientes, com leitura e escrita completas. A Microsoft desativou o recurso e notificou os clientes afetados. Todo o isolamento entre tenants dependia da camada que errou.

> **Dica:** um teste barato pega a maior parte dos IDORs: dois tenants na fixture, autenticação como o primeiro e cada rota de `app.routes` chamada com IDs do segundo. Toda resposta deve ser 404, e nenhuma listagem pode trazer item alheio.

## Resumo

- Autorização decide `(sujeito, ação, recurso, contexto) → permitir | negar`, nega por padrão e decide sobre o objeto concreto.
- RBAC: barato de checar e auditar, sem regra por objeto. ABAC: expressa quase tudo, audita mal. ReBAC (Zanzibar): relações e hierarquias, exige tuplas consistentes.
- Gateway checa token, escopo e rota; a checagem por objeto mora no serviço dono dos dados, na própria consulta.
- IDOR: ID vindo do cliente sem checagem de posse, na URL, no corpo ou na listagem. Objeto alheio responde 404; UUID não corrige.
- Isolamento entre tenants vai do banco por tenant à coluna com RLS, trocando isolamento por custo por tenant e migrações.
- RLS: `ENABLE` + `FORCE`, `NULLIF(current_setting(..., true), '')`, `set_config(..., true)` por transação, FK composta com o tenant.
- Cache, busca, workers e roles com `BYPASSRLS` vazam por fora do `WHERE`.

## Referências

- Ferraiolo, D.; Kuhn, R. "Role-Based Access Controls", 15th National Computer Security Conference, 1992. NIST, projeto RBAC: <https://csrc.nist.gov/projects/role-based-access-control>
- Hu, V. et al. NIST SP 800-162, "Guide to Attribute Based Access Control (ABAC) Definition and Considerations", 2014: <https://doi.org/10.6028/NIST.SP.800-162>
- Pang, R. et al. "Zanzibar: Google's Consistent, Global Authorization System", USENIX ATC 2019: <https://www.usenix.org/conference/atc19/presentation/pang>
- OWASP API Security Top 10 2023, API1: Broken Object Level Authorization: <https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/>
- OWASP Authorization Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html>
- PostgreSQL, "Row Security Policies": <https://www.postgresql.org/docs/current/ddl-rowsecurity.html>
- PostgreSQL, `CREATE POLICY`: <https://www.postgresql.org/docs/current/sql-createpolicy.html>
- Open Policy Agent: <https://www.openpolicyagent.org/>; Cedar: <https://www.cedarpolicy.com/>; OpenFGA: <https://openfga.dev/>
- Krebs, B. "First American Financial Corp. Leaked Hundreds of Millions of Title Insurance Records", maio de 2019: <https://krebsonsecurity.com/2019/05/first-american-financial-corp-leaked-hundreds-of-millions-of-title-insurance-records/>
- Wiz, "ChaosDB: How we hacked thousands of Azure customers' databases", 2021: <https://www.wiz.io/blog/chaosdb-how-we-hacked-thousands-of-azure-customers-databases>
