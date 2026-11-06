# Autorização e multitenancy

A analista do Hornero fez o *pen test* mais barato da história da Lastro: zero reais, uma tecla e o tempo de esfriar o café.

Na segunda às 10h40, ela viu na barra de endereço do painel `/painel/cobrancas/18734512` e, por curiosidade, trocou o 2 final por 3. Apareceu um fone de R$ 349,90 vendido pelo Bazar, com nome, CPF e e-mail do comprador. Trocou por 4: uma capinha do Bazar. Ao lado, um botão "Estornar", ativo, laranja, implorando. Ela não clicou. Por educação, e porque o crochê estava no colo.

Às 10h52, ela abriu chamado. O Bazar soube às 11h30 e abriu o seu: "URGENTE!!!! O CONCORRENTE ESTÁ VENDO NOSSAS VENDAS??????". Estava. O painel usava o ID interno `BIGINT` da cobrança, sequencial, e a rota de detalhe, escrita pelo Carlos "para o suporte interno", carregava a cobrança pelo ID e nada mais. Depois virou a tela dos marketplaces, com a mesma consulta e um logotipo novo.

A auditoria da tarde achou mais um. No GraphQL do painel (capítulo 12), a consulta de topo `cobranca(id:)` conferia o marketplace. O campo aninhado `vendedor { cobrancas }` não. A Capinhas Hiper vende no Bazar e no Hornero com o mesmo CNPJ, `UNIQUE` desde o capítulo 1, e o painel do Hornero listava as vendas dela no Bazar, com paginação por cursor. A Lastro tinha construído uma integração entre concorrentes melhor que a de qualquer cliente.

A autenticação do capítulo 30 funcionou: a Lastro sabia, com passkey e MFA, exatamente quem estava vendo o que não devia. Onde mora a pergunta "e ela pode?", e como garantir que nenhuma consulta esquecida faça de novo um marketplace ler o outro?

## Autorização, a pergunta que vem depois do crachá

**Autorização** é a decisão sobre uma tupla: um **sujeito** (usuário, chave, serviço) quer executar uma **ação** sobre um **recurso**, num **contexto** (horário, origem, autenticação recente). Sem regra aplicável, a resposta é negar. *Deny by default* é a única configuração em que esquecer uma regra gera um chamado de "não consigo ver", e não um chamado do Bazar.

A literatura separa quem decide de quem obedece. O **ponto de decisão** (PDP, *policy decision point*) avalia a política; o **ponto de aplicação** (PEP, *policy enforcement point*) é o código que pergunta e barra. Os nomes vêm do XACML, padrão em XML que pouca gente usa e todo mundo cita. A aplicação precisa estar em cada caminho até o dado, e é ali que mora o bug. O painel da Lastro tinha política. Faltava aplicação em duas rotas.

## RBAC, ou como cinco papéis viram quatrocentos

No **RBAC** (*role-based access control*), permissões são atribuídas a papéis, e papéis a usuários (Ferraiolo e Kuhn, 1992; ANSI INCITS 359-2004). A checagem é uma pertinência: algum papel do usuário contém `estorno:criar`? Barata, auditável ("quem pode estornar?" é um `JOIN`) e cabe num token: o `scope` do capítulo 30 é RBAC de pobre.

O RBAC responde sobre tipos de ação, e não sobre objetos. "Suporte pode estornar cobranças do próprio marketplace até R$ 500,00" tem dois atributos do recurso na regra, e o RBAC puro só expressa isso criando papéis: `suporte_bazar_ate_500`, `suporte_hornero_ate_500_exceto_domingo`. É a **explosão de papéis**, que termina com mais papéis que funcionários e o Carlos pedindo `super_suporte` "por segurança".

## ABAC e ReBAC, ou a política que olha o objeto

No **ABAC** (*attribute-based access control*, NIST SP 800-162), a política é uma expressão sobre atributos do sujeito, do recurso, da ação e do ambiente:

```text
permitir estorno:criar se
    sujeito.marketplace_id == recurso.marketplace_id
  e "suporte" em sujeito.papeis
  e recurso.valor <= 50000                    -- centavos
  e ambiente.agora - sujeito.ultimo_fator <= 5 min
```

Expressa qualquer coisa, e cobra por isso: o PDP não decide antes de carregar a cobrança, a política vira um programa com bugs de programa, e "quem pode estornar esta cobrança?" exige avaliar a expressão para todo mundo. Linguagens dedicadas (Rego, do Open Policy Agent, e Cedar, da AWS, são exemplos) tornam a política testável fora da aplicação.

No **ReBAC** (*relationship-based access control*), a permissão deriva de relações: a cobrança pertence ao marketplace, o usuário é membro do marketplace, logo pode ler a cobrança. A referência é o Zanzibar, do Google (USENIX ATC 2019): tuplas `objeto#relação@sujeito`, checagem como alcançabilidade num grafo.

O paper dedica uma seção ao **problema do novo inimigo**: Alice tira o ex da pasta compartilhada e depois põe uma foto nova nela. Se a checagem ler uma réplica onde a remoção ainda não chegou e a foto já, o ex vê a foto. O Google resolveu com o *zookie*, um token que amarra a checagem a um instante pelo menos tão novo quanto a última mudança de permissão: o read-your-writes do capítulo 19 aplicado ao ex, no único paper de sistemas distribuídos com motivação de novela.

O custo do ReBAC é um serviço com estado próprio na frente de toda leitura, tão disponível quanto o caminho mais crítico. E há a pergunta difícil, dos três modelos: "liste o que eu posso ver". Filtrar 9 milhões de cobranças exige traduzir a política num `WHERE`, ou o sistema lê tudo e descarta.

| Modelo | Decide com | Pergunta "quem pode?" | Custo principal |
|---|---|---|---|
| RBAC | papéis do sujeito | barata | explosão de papéis |
| ABAC | atributos de sujeito, recurso, ambiente | cara | política vira programa; precisa do recurso |
| ReBAC | grafo de relações | razoável | serviço com estado e consistência própria |
## Onde a checagem mora

A política pode ser perfeita e ainda vazar, porque a aplicação acontece em camadas, e cada uma enxerga uma parte do problema.

```text
 requisição
     │
     ▼
 borda / gateway ─── autenticado? escopo cobre a rota?    (grosso, sem o objeto)
     │
     ▼
 serviço ───────────  este sujeito, esta ação, este objeto? (fino, com o objeto)
     │
     ▼
 banco ─────────────  só as linhas do tenant da sessão      (rede de segurança)
```

O gateway só decide o que cabe na credencial. O serviço é o único lugar com sujeito e objeto ao mesmo tempo. O banco filtra linhas por tenant mesmo quando o código esquece.

Três regras saem daí. **Listagens filtram na consulta**, nunca depois: buscar 50 e descartar as alheias devolve páginas com 3 itens e um cursor que vaza o resto. **Objeto de outro tenant responde `404`**, igual ao inexistente: um `403` confirma que a cobrança existe, e enumerar é metade do roubo. **O tenant vem da credencial**, nunca da requisição: um `?marketplace_id=` que o cliente consegue mandar é uma sugestão do atacante.

A última regra vale entre serviços. Se o ledger aceita com permissão total tudo que vem de pagamentos, pagamentos vira um **confused deputy**: um intermediário com privilégio que executa, para quem não tem, o que este não poderia fazer sozinho. O termo é de Norm Hardy (1988), sobre um compilador que sobrescreveu o arquivo de faturamento do sistema porque o usuário pediu com jeitinho. A defesa é propagar o sujeito original num formato que o intermediário não consiga forjar.

## IDOR, o ataque que cabe numa tecla

O que a analista fez é **IDOR** (*insecure direct object reference*), que a lista de API da OWASP de 2023 chama de **BOLA** (*broken object level authorization*) e põe em primeiro lugar. A rota recebe um identificador, carrega o objeto e não verifica a relação do sujeito com ele. A URL é um formulário que o usuário pode editar, e o usuário edita.

Trocar o ID sequencial por UUID dificulta a enumeração, e só. Um UUIDv7 tem 74 bits aleatórios, mas IDs vazam em webhooks, logs, links de e-mail e no print que o vendedor 42 mandou para o Bazar. Com um ID alheio em mãos, a rota sem checagem abre do mesmo jeito. UUID é ofuscação; a correção é a checagem.

O ID sequencial ainda conta: cria uma cobrança na segunda, outra na terça, subtrai, e o concorrente sabe o volume diário da Lastro. Na Segunda Guerra, estatísticos aliados estimaram pelos números de série capturados uma produção de 246 tanques alemães por mês, contra 1.400 da inteligência convencional; os registros alemães mostraram 245. ID sequencial é relatório de faturamento com acesso público.

## Isolamento entre tenants

Um **tenant** é um cliente cujos dados e operações precisam ficar isolados dos outros clientes no mesmo sistema. Na Lastro, cada marketplace. Há quatro modelos de isolamento, do mais separado ao mais compartilhado:

| Modelo | Isolamento | Custo por tenant | Migração de schema | Consulta entre tenants |
|---|---|---|---|---|
| Banco por tenant | físico, inclusive recursos | alto (instância, réplicas, conexões) | N vezes | entre bancos |
| Schema por tenant | lógico, mesmo processo | médio (catálogo cresce) | N vezes | `UNION` de schemas |
| Coluna de tenant | só na consulta | ~zero | 1 vez | um `WHERE` |
| Coluna + row-level security | consulta, aplicado pelo banco | ~zero | 1 vez | papel autorizado |

O **banco por tenant** isola até o vizinho barulhento, ao custo de instância, réplicas e pool por cliente e da mesma migração N vezes, com N chances de uma falhar no meio. O **schema por tenant** isola nomes, e nada de CPU ou I/O; depende de `search_path` por sessão, que um pool em modo transaction mistura entre clientes. A **coluna de tenant** é a mais barata e a que vazou na segunda: o isolamento é tão bom quanto a consulta mais desleixada do sistema, e o sistema tem o Carlos.

## Row-level security, o WHERE que o Carlos não consegue esquecer

O **row-level security** (RLS) do PostgreSQL (desde a versão 9.5) acrescenta a cada consulta, dentro do planejador, um predicado definido numa política da tabela. A aplicação esquece o `WHERE`; o banco põe.

```sql
ALTER TABLE cobrancas ENABLE ROW LEVEL SECURITY;
ALTER TABLE cobrancas FORCE ROW LEVEL SECURITY;

CREATE POLICY por_marketplace ON cobrancas
  USING (marketplace_id =
         nullif(current_setting('app.marketplace_id', true), '')::bigint);
```

`USING` filtra as linhas visíveis; `WITH CHECK`, que omitido repete o `USING`, valida o que se grava. Com RLS ligado e nenhuma política, a tabela não mostra nada a ninguém: deny by default de fábrica. A consulta da segunda-feira, com o tenant do Hornero na sessão:

```text
lastro=> BEGIN;
lastro=> SET LOCAL app.marketplace_id = '7';   -- Hornero
lastro=> SELECT count(*) FROM cobrancas WHERE id = 18734513;
 count
-------
     0
```

Os detalhes que separam RLS de teatro:

**Quem escapa.** Superusuários e papéis com `BYPASSRLS` ignoram as políticas; o dono da tabela também, sem `FORCE ROW LEVEL SECURITY`. Aplicação que conecta como dona das tabelas tem RLS só no diagrama.

**Pool em modo transaction.** O PgBouncer (capítulo 4) entrega a sessão do servidor ao próximo cliente, e um `SET` sem `LOCAL` deixa o tenant do Hornero para a transação seguinte, que pode ser do Bazar: o motel do capítulo 4 agora entrega o quarto com a bagagem do hóspede anterior. `SET LOCAL` termina com a transação. Depois disso, `current_setting` devolve string vazia, e não `NULL`; sem o `nullif`, a conversão de `''` para `bigint` derruba a consulta. Fecha sem vazar, ao menos.

**Views** executam com os privilégios do dono, e herdam o desprezo dele pelo RLS; desde o PostgreSQL 15, `security_invoker = true` aplica as políticas de quem consulta. **Restrições** `UNIQUE` e chaves estrangeiras enxergam todas as linhas: uma violação de unicidade revela que outro tenant tem aquele valor, e a defesa é pôr o tenant em toda chave única de negócio.

**Desempenho.** O predicado entra no plano como um `WHERE`: precisa de índice, e a coluna do tenant no índice para o index-only scan sobreviver. Tabelas particionadas aplicam as políticas da mãe quando consultadas por ela; partição acessada direto usa as próprias, que começam vazias.

## Na Lastro: marketplaces, vendedores e quem pode o quê

Os requisitos: nenhum marketplace lê dado de outro, mesmo com consulta esquecida; os 42 marketplaces (41 mais o Tuiuiú) diferem em tamanho por mais de mil vezes; a conciliação lê todos; o vendedor pode pertencer a vários.

**Modelo de tenant.** Coluna `marketplace_id` em toda tabela de dado de cliente, com RLS como segunda camada, em `pg-pagamentos` e em cada shard de `pg-ledger`. Banco por tenant daria 42 primários com três réplicas e 42 migrações por mudança, para um isolamento de recursos que o ledger já tem onde importa (o Tuiuiú tem shard próprio desde o capítulo 29); seria o certo com poucos clientes enormes e exigência contratual de separação física. Schema por tenant traria o custo de migração sem isolar recurso. Os lançamentos herdam o `marketplace_id` da transação, inclusive nas contas da Lastro (liquidante e receita).

**Papéis no banco.**

| Papel | RLS | Usado por |
|---|---|---|
| `dono_schema` | dono das tabelas, `FORCE` ativo | só migrações |
| `app_pagamentos`, `app_ledger` | aplica; sem `BYPASSRLS` | serviços, `SET LOCAL` no início de toda transação |
| `conciliacao` | política própria `USING (true)`, só `SELECT` | conciliação das 6h, relatórios internos |
| `quebra_vidro` | `BYPASSRLS`, temporário | emergência, com aprovação de duas pessoas, 1 hora, auditado |

O fundador perdeu o superusuário que tinha desde `temp-01`, a pendência do capítulo 1, quando o tabelião descobriu que tinha um chefe capaz de desligá-lo. Ganhou o `quebra_vidro`, como todo mundo, e disse que no tempo dele o banco confiava nas pessoas. Confiava, e a planilha do financeiro tem uma aba só para isso.

**Contexto propagado.** O gateway autentica (capítulo 30), descarta cabeçalhos internos vindos de fora e emite um **token de contexto**: JWT ES256 de 60 segundos com `marketplace_id`, sujeito, papéis e instante do último fator. Pagamentos o repassa ao ledger e ao antifraude, que tiram o tenant dele, nunca de um parâmetro. No painel, o tenant vem do emissor OIDC configurado para o marketplace, e não de uma claim: o IdP é do cliente, e com claim um marketplace emitiria para si um token dizendo ser o Bazar, com a Lastro assinando embaixo.

**Política.** RBAC para o tipo de ação, ABAC para o objeto, relações em tabela:

| Papel (usuário do marketplace) | Pode |
|---|---|
| `leitura` | ver cobranças, extratos e vendedores do marketplace |
| `suporte` | + estornar até R$ 500,00 |
| `financeiro` | + estornar sem limite, com fator nos últimos 5 minutos |
| `admin` | + gerir usuários, chaves e inscrições de webhook |

Os papéis vêm dos grupos do IdP do marketplace. Vendedores entram pela relação `afiliacoes (vendedor_id, marketplace_id)` e veem os próprios recebíveis, nunca a cobrança inteira. Um serviço estilo Zanzibar foi descartado: as relações têm dois níveis e cabem em tabelas; ele faria sentido com compartilhamento arbitrário ou hierarquias profundas.

**Aplicação.** A política mora numa biblioteca dos serviços. Rota sem ação declarada responde `403`, e a CI falha se achar uma. Os repositórios só oferecem buscas com tenant, `buscar(marketplace_id, id)`; a versão sem tenant deixou de existir. O DataLoader do GraphQL passou a ter chave `(marketplace_id, vendedor_id)`. Objeto alheio responde `404` RFC 9457, `type` `nao-encontrado`. O painel trocou o ID interno pela UUIDv7 pública: a checagem corrigiu o IDOR, e a troca só fechou a contagem de tanques.

Mais de 20 negações para o mesmo sujeito em 5 minutos dispara alerta, porque enumeração lenta passa por baixo do rate limiting do capítulo 28. O índice do extrato no ledger ganhou `marketplace_id` no `INCLUDE`; sem ele, a soma do trigger de débito perdia o index-only scan (0,6 ms a mais em homologação).

A equipe da Lastro acessa um marketplace por **personificação**: leitura no tenant, vinculada a um chamado, 2 horas, CPF mascarado e um registro que o marketplace vê no painel. O Carlos pediu personificação com escrita, por segurança. Está no backlog, ao lado dos 1.024 baldes.

## Armadilhas e casos reais

> **Na vida real:** em maio de 2019, Brian Krebs noticiou que a First American Financial, seguradora de títulos imobiliários dos Estados Unidos, expunha cerca de 885 milhões de documentos de clientes, de 2003 em diante, com contas bancárias e documentos de identidade. Bastava mudar o número na URL de um documento. Sem login. O IDOR mais caro dos livros não precisou nem do crochê.

Checar na tela e não na API: esconder o botão "Estornar" no React não impede ninguém de mandar o `POST`. Checar o pai e esquecer o filho: `GET /cobrancas/{id}/estornos/{estorno_id}` que carrega o estorno sem conferir se pertence àquela cobrança é IDOR com sobrenome. Tenant fora da chave de cache: `painel:resumo:{dia}` serve o resumo do Bazar ao Hornero (o Carlos tinha criado uma).

Função `SECURITY DEFINER` no caminho: executa com os privilégios do dono, que ignora RLS, e abre a tabela inteira para quem puder chamá-la.

## Resumo

- Autorização decide sobre sujeito, ação, recurso e contexto, negando por padrão; o bug costuma estar no ponto de aplicação.
- RBAC explode quando a regra depende do objeto; ABAC precisa do recurso; ReBAC exige serviço com consistência própria (novo inimigo).
- Borda decide o grosso, serviço checa o objeto, banco filtra o tenant. Listagem filtra na consulta, objeto alheio é `404`, tenant vem da credencial, sujeito propagado contra o confused deputy.
- IDOR/BOLA: UUID não substitui checagem; ID sequencial vaza volume.
- Isolamento por banco, schema, coluna ou coluna com RLS.
- RLS: `FORCE`, `BYPASSRLS`, `SET LOCAL` com pool, `security_invoker`, `UNIQUE` vaza existência, tenant no índice.

## A Lastro agora

Cada marketplace é um tenant tirado da credencial, com `marketplace_id` em toda tabela e RLS em `pg-pagamentos` e nos shards do ledger. Os serviços conectam sem `BYPASSRLS` e fazem `SET LOCAL` do tenant em cada transação; só a conciliação lê tudo, e só lê. Um token de contexto de 60 segundos atravessa os serviços, e os papéis do marketplace vêm do IdP dele. O fundador entrou na fila do `quebra_vidro`, e o tabelião, pela primeira vez desde o capítulo 1, não tem ninguém acima dele com um interruptor.

A analista do Hornero recebeu agradecimento formal e voltou ao crochê. Na quarta, o `admin` de um marketplace novo, autenticado com passkey, autorizado pelo papel certo, no tenant certo, com RLS conferindo cada linha, cadastrou uma inscrição de webhook. A política permitiu, corretamente. Ninguém perguntou para onde apontava a URL `http://169.254.169.254/latest/meta-data/`.

## Referências

- David Ferraiolo, Richard Kuhn, "Role-Based Access Controls", 15th National Computer Security Conference, 1992.
- ANSI INCITS 359-2004, Role Based Access Control.
- NIST SP 800-162, Guide to Attribute Based Access Control (ABAC) Definition and Considerations: https://csrc.nist.gov/pubs/sp/800/162/upd2/final
- Ruoming Pang et al., "Zanzibar: Google's Consistent, Global Authorization System", USENIX ATC 2019: https://www.usenix.org/conference/atc19/presentation/pang
- Norm Hardy, "The Confused Deputy", ACM SIGOPS Operating Systems Review, 1988.
- OWASP API Security Top 10 2023, API1:2023 Broken Object Level Authorization: https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/
- PostgreSQL 16, Row Security Policies: https://www.postgresql.org/docs/16/ddl-rowsecurity.html
- PostgreSQL 16, CREATE VIEW (`security_invoker`): https://www.postgresql.org/docs/16/sql-createview.html
- Open Policy Agent, Rego: https://www.openpolicyagent.org/docs/latest/policy-language/
- Cedar Policy Language: https://docs.cedarpolicy.com/
- Richard Ruggles, Henry Brodie, "An Empirical Approach to Economic Intelligence in World War II", Journal of the American Statistical Association, 1947.
- Brian Krebs, "First American Financial Corp. Leaked Hundreds of Millions of Title Insurance Records", KrebsOnSecurity, 24 maio 2019: https://krebsonsecurity.com/2019/05/first-american-financial-corp-leaked-hundreds-of-millions-of-title-insurance-records/
