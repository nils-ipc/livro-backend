# Contratos de API

## "É só um campo", ou como um JSON educado derrubou um marketplace inteiro

A mensagem de erro tinha 214 caracteres, um colchete sobrando e a assinatura inconfundível do Java:

```text
com.fasterxml.jackson.databind.exc.UnrecognizedPropertyException:
Unrecognized field "parcelas_detalhe" (class br.com.bazar.pagamentos.Cobranca),
not marked as ignorable (9 known properties: "id", "valor", "estado", ...])
```

Terça, 11h02. O gerente de produto pôs na resposta da cobrança um campo novo, `parcelas_detalhe`. "É só um campo, quem não usa ignora." O Bazar Bem-te-vi não ignora. A integração dele foi escrita por uma consultoria em Java, com Jackson, cujo padrão (`FAIL_ON_UNKNOWN_PROPERTIES = true`) trata campo desconhecido como invasão de domicílio.

Todo `GET /v1/cobrancas/{id}` e todo webhook virou exceção no Bazar. O endpoint de webhooks dele respondia `500`, e a Lastro, que ainda manda webhook uma vez só (capítulo 4), seguia a vida. Às 11h32, o job do Bazar que cancela pedido sem pagamento confirmado em 30 minutos fez o trabalho dele com zelo: 312 compradores pagaram o Pix e receberam "pedido cancelado". "URGENTE!!!!" às 11h41, rollback às 13h40, e o financeiro passou a tarde devolvendo Pix de gente que só queria uma capinha.

Na reunião, o gerente culpou o Bazar e o Bazar culpou a Lastro. Os dois têm razão, por isso a reunião durou duas horas. A pergunta: o que é o contrato de uma API, que mudanças ele permite sem perguntar a ninguém, e como uma mudança que quebra chega ao mundo sem cancelar 312 pedidos?

## O contrato é tudo o que o cliente consegue ver, inclusive o que você nunca prometeu

O **contrato** de uma API é o conjunto de comportamentos observáveis dos quais um cliente pode depender: caminhos, métodos, campos e tipos, obrigatoriedade, `null`, valores de enum, status, formato dos erros, cabeçalhos, ordem das listas e a semântica de tudo (`valor` em centavos, `criado_em` em UTC).

A documentação é só a parte escrita. Hyrum Wright, engenheiro do Google, registrou a observação conhecida como **Lei de Hyrum**: com usuários suficientes, todo comportamento observável do sistema terá alguém dependendo dele, prometido ou não. A ordem das chaves no JSON, o texto do erro, o ID ter sempre 36 caracteres. Em algum lugar existe um `if` em cima disso, escrito por alguém que já tem o template do chamado pronto.

Uma mudança é **compatível com versões anteriores** (*backward compatible*) quando todo cliente escrito para o contrato antigo continua funcionando com o servidor novo. A regra vem da teoria de tipos: a resposta nova pode ser um **subtipo** da antiga (tudo o que tinha, e mais), e a requisição nova pode aceitar um **supertipo** (tudo o que aceitava, e mais). É a variância que o mypy cobra na sobrescrita de método: retorno covariante, parâmetro contravariante. Quem inverte viola Liskov e ganha uma noite de plantão de brinde.

| Mudança | Na resposta | Na requisição |
|---------|-------------|---------------|
| Adicionar campo | Compatível se o cliente tolera campo desconhecido | Compatível se opcional |
| Remover ou renomear campo | Quebra | Quebra se o servidor passar a recusá-lo |
| Mudar tipo (`int` → `string`) | Quebra | Quebra |
| Campo opcional vira obrigatório | Compatível (sempre presente) | Quebra |
| Campo passa a admitir `null` | Quebra | Compatível |
| Novo valor de enum | Quebra quem trata enum como fechado | Compatível |
| Validação mais rígida | n/a | Quebra |
| Validação mais frouxa | n/a | Compatível |
| Mudar significado (`valor` em reais) | Quebra sem erro nenhum | Quebra sem erro nenhum |

A última linha é a pior. Trocar centavos por reais mantém o schema intacto, passa em todo validador, e o vendedor recebe R$ 0,87 por uma venda de R$ 87,01, com documentação impecável e um advogado novo.

A primeira linha tem um asterisco: adicionar campo só é compatível com um **leitor tolerante** (*tolerant reader*, nome de Martin Fowler para o padrão), que lê o que precisa e ignora o resto. O HTTP faz isso com cabeçalhos desconhecidos (RFC 9110); Protocol Buffers, por projeto. O Jackson padrão faz o oposto, e o Bazar aprendeu a diferença em 312 e-mails:

```text
Gerente:  É só um campo. Quem não usa, ignora.
Jackson:  Unrecognized field "parcelas_detalhe".
Gerente:  Então ignora.
Jackson:  not marked as ignorable.
Gerente:  Marca, ué.
Jackson:  Quem marca é o Bazar. O Bazar terceirizou.
Bazar:    (cancela 312 pedidos, abre chamado "URGENTE!!!!")
```

O ancestral é o princípio da robustez de Jon Postel (RFC 761, 1980): conservador no que envia, liberal no que aceita. A RFC 9413 (2023) registra o efeito colateral, emissores tortos para sempre porque ninguém reclama, e propõe a versão estreita: ignore o que o contrato manda ignorar e recuse o resto em voz alta.

Enums merecem velório próprio. Um `match estado:` com `pendente`, `paga` e `cancelada`, sem caso padrão, explode no dia em que nasce `contestada`. O contrato precisa dizer se o enum é aberto (valores novos podem aparecer, e desconhecido é tratado como desconhecido) ou fechado. E `null` contra ausente: `{"desconto": null}` e `{}` são diferentes em JSON, metade dos desserializadores acha que são iguais, e as duas metades integram com a Lastro.

## Versionar é escolher onde mora a mentira

Mudança que quebra precisa conviver com a antiga. **Versionar** é dar nome a cada contrato e deixar o cliente escolher qual recebe. O nome pode morar em quatro lugares, e cada um mente para um componente diferente.

| Estratégia | Exemplo | Roteamento no proxy | Cache HTTP | Visível em log | Granularidade |
|------------|---------|---------------------|------------|----------------|---------------|
| Caminho | `/v1/cobrancas` | Por prefixo, trivial | Sem cuidado extra (URL diferente) | Sim | API inteira |
| Cabeçalho próprio | `Lastro-Versao: 2026-11-01` | Precisa ler cabeçalho | Exige `Vary` | Só se logar o cabeçalho | Por requisição |
| Media type | `Accept: application/vnd.lastro.v2+json` | Precisa ler cabeçalho | Exige `Vary: Accept` | Só se logar | Por recurso |
| Parâmetro | `?versao=2` | Por query | URL diferente | Sim | Por requisição |

O caminho aparece em todo log, roteia por prefixo e separa o cache sozinho, ao custo de granularidade: `/v2` é uma API inteira nova por causa de um campo. O media type é o mais fiel ao HTTP (mesmo recurso, outra representação) e o mais traiçoeiro: um CDN sem `Vary: Accept` serve a versão 2 a quem pediu a 1, e quem esqueceu o `Vary` uma vez nunca mais esquece, porque o incidente ganha o nome dele.

A Stripe documentou em 2017 uma quinta via: **versões por data, fixadas por conta**. Cada conta fica presa à versão do dia em que integrou, e pode sobrescrever por requisição com o cabeçalho `Stripe-Version`. O código produz a resposta mais nova, e uma cadeia de transformações a reescreve para trás até a data do cliente. Caro de construir, barato por mudança.

Versão velha precisa de atestado de óbito. `Deprecation` (RFC 9745) diz desde quando o recurso está obsoleto; `Sunset` (RFC 8594), quando deixa de responder; um `Link` com `rel="deprecation"` aponta a migração.

```http
HTTP/1.1 200 OK
Deprecation: @1793491200
Sunset: Mon, 01 Nov 2027 00:00:00 GMT
Link: <https://docs.lastro.com.br/migracao-v2>; rel="deprecation"
```

O `Deprecation` usa a data estruturada da RFC 9651 (segundos Unix; essa é 1º de novembro de 2026); o `Sunset`, a data HTTP clássica. Duas RFCs, dois formatos de data, mesmo velório. Ninguém lê nenhum dos dois: a versão morre no dia marcado, alguém liga desesperado, a data é adiada três meses, e o ciclo se repete até a versão velha ficar mais antiga que `temp-01` e pedir aposentadoria por tempo de serviço.

## Paginação e filtros, o contrato escrito nas entrelinhas

O mecanismo do cursor está no capítulo 6; aqui interessa o que ele promete. Um contrato de paginação define a ordem (estável e total, com desempate, como `(criado_em, id)`), o limite (padrão e máximo; quem aceita `limite=1000000` acabou de publicar um endpoint de exportação de banco) e a opacidade do cursor.

O cursor da Lastro é um base64 de `(criado_em, id)`, e a Lei de Hyrum garante que algum cliente vai decodificar e montar cursores à mão. O contrato diz "string opaca", e o servidor assina o cursor para que o artesanato dê `400`. Opaco no papel e legível no fio é cantada de bar.

Filtros sofrem da mesma doença. `criado_em_ate` é inclusivo? Em que fuso? Sem resposta escrita, `2026-11-03T00:00:00` significa meia-noite UTC no servidor e meia-noite em Brasília no Bazar, e o extrato do dia some com três horas de vendas. E o filtro com typo: `?estdo=paga`, num servidor tolerante, é ignorado e devolve todas as cobranças, e o cliente informa ao vendedor um faturamento de ficção científica. Leitor tolerante é virtude no cliente lendo respostas; no servidor recebendo consultas financeiras, é cumplicidade.

## Erros com formato: RFC 9457, o fim do `{"erro": "deu ruim"}`

Toda API inventa seu formato de erro, e o cliente coleciona parsers como quem coleciona traumas. Algumas devolvem `200 OK` com `{"sucesso": false}`, o primo HTTP do log `Erro: sucesso`. A RFC 9457 (2023, substitui a RFC 7807) padroniza o **problem details**: um objeto JSON com media type `application/problem+json` e cinco membros definidos.

```json
{
  "type": "https://docs.lastro.com.br/erros/split-invalido",
  "title": "Split não fecha 100% do valor",
  "status": 422,
  "detail": "Os recebedores somam 10300 basis points; o máximo é 10000.",
  "instance": "/v1/cobrancas/requisicoes/0190d5f2-41aa-7b3e-8c11-2f6a9e0b7d54",
  "recebedores_excedentes": ["vend_7310"]
}
```

`type` é uma URI que identifica o tipo de problema, e é por ele que o cliente decide o que fazer; ausente, vale `about:blank` ("nada além do status"). `title` é um resumo fixo por tipo. `status` repete o código HTTP e precisa bater com ele. `detail` explica esta ocorrência, para humanos; `instance` a identifica. Membros extras são extensões, e quem não as conhece as ignora.

O cliente nunca faz parsing do `detail`. É texto para gente, e texto para gente muda quando o redator acorda inspirado. Regex em cima de `detail` transforma uma frase em API, e frase não tem versionamento, só revisor.

## OpenAPI e testes de contrato, ou o contrato com firma reconhecida

Contrato que mora na cabeça do gerente muda quando o gerente almoça. A **OpenAPI** (a 3.1 é alinhada ao JSON Schema 2020-12) descreve a API em YAML ou JSON: caminhos, parâmetros, schemas, respostas por status. O FastAPI gera o documento a partir dos modelos Pydantic: o contrato publicado é exatamente o código, e qualquer refatoração inocente de modelo altera o contrato sem ninguém perceber até o "URGENTE!!!!".

Versionado no repositório, o documento vira diff, e comparadores (o oasdiff é um exemplo) classificam cada diferença pela tabela de compatibilidade. A CI recusa o merge que quebra. O diff vê o schema e é cego para o comportamento.

Para o comportamento existem os **testes de contrato dirigidos pelo consumidor** (*consumer-driven contract testing*; o Pact é o exemplo mais conhecido). Cada consumidor registra num teste as interações de que depende ("este `GET` devolve `200` com `estado` string"), publica o contrato num repositório central (o *broker*), e o provedor verifica todos os contratos contra o próprio código antes de subir. O provedor descobre quais campos cada um usa e remove o resto sem medo. O custo é o consumidor escrever os testes: entre serviços da mesma empresa, funciona; com a consultoria Java do Bazar, leve lanche e um padre.

## As regras da Lastro, por escrito e com testemunha

O requisito: a API é integrada por equipes externas, com stacks desconhecidas e o ritmo de deploy de quem sobe versão quando o estagiário volta das férias. Mudança aditiva sai sem coordenação; mudança que quebra pede meses de convivência.

**Compatibilidade**, no guia de integração e no contrato comercial: o cliente ignora campos desconhecidos em respostas e webhooks (no Jackson, `FAIL_ON_UNKNOWN_PROPERTIES = false`); enums de resposta (`estado`, `metodo`, `tipo` de evento) são abertos; ausente e `null` significam "sem valor". Sem versão nova, a Lastro pode adicionar campo em resposta, campo opcional em requisição, valor de enum e endpoint, e afrouxar validação, sempre com 30 dias de changelog. O resto quebra.

**Versionamento**: major no caminho (`/v1`), sem versões menores. O requisito é operacional: proxy reverso em duas máquinas (capítulo 10), cache com `ETag` (capítulo 9), logs que já mostram o caminho. O prefixo roteia sem ler cabeçalho, dispensa `Vary` e aparece em qualquer `grep`. A granularidade grossa (toda quebra vira `/v2` inteira) é paga quebrando quase nunca. A `/v1` convive com a sucessora por 12 meses, com `Deprecation` e `Sunset`. Com centenas de marketplaces e quebras trimestrais, versões por data no estilo da Stripe pagariam a cadeia de transformações; com dois clientes, seriam um framework para servir duas pessoas e um consultor.

**Erros**: RFC 9457 em todo `4xx` e `5xx`, um `type` por regra (`saldo-insuficiente`, `split-invalido`, `estado-invalido`), lista aberta como qualquer enum. Validação de corpo devolve a extensão `erros` com o JSON Pointer (RFC 6901) de cada campo. Recusa do emissor segue `201` com estado `recusada` (capítulo 9).

**Listagens**: cursor assinado, `limite` padrão 50 e máximo 200, ordem `(criado_em, id)`, filtros semiabertos `[de, ate)` em RFC 3339 com fuso obrigatório, parâmetro desconhecido devolve `400` com `type` `parametro-desconhecido`.

**Testes**: o OpenAPI gerado é commitado e a CI bloqueia diff incompatível com o da `main`. E o sandbox injeta em toda resposta e todo webhook um campo `_sandbox_campo_novo` com valor aleatório. O campo-isca só existe para quebrar no sandbox a integração que quebraria em produção. O Bazar teria descoberto o Jackson numa terça qualquer, sem o financeiro chorando no estorno.

**Webhooks**, cujo contrato até hoje era "um POST com um JSON e fé":

```json
{
  "id": "evt_0190d61a-9c03-7f12-a4e8-6b1d0c2e9f77",
  "tipo": "cobranca.paga",
  "versao_api": "v1",
  "criado_em": "2026-11-03T14:22:07.481Z",
  "dados": {
    "id": "0190c3a1-7e2b-7c41-9d0f-5b2a8e6f1c33",
    "estado": "paga",
    "valor": 259800,
    "versao": 4
  }
}
```

Envelope fixo; `dados` carrega a cobrança inteira, na representação do `GET` da versão em `versao_api`.

| Cláusula | Por quê |
|----------|---------|
| `id` único por evento | O cliente deduplica: a entrega será "pelo menos uma vez" (capítulos 16 e 17) |
| `dados.versao` (a coluna do `ETag`) | Evento com `versao` menor que a já processada é velho e vai para o lixo |
| Sem garantia de ordem | `cobranca.estornada` pode chegar antes de `cobranca.paga`; o `versao` desempata |
| Cabeçalho de assinatura criptográfica | Nome reservado; o algoritmo é do capítulo 33 |
| Inscrição por tipo de evento | Tipo novo só chega a quem se inscreveu nele |
| Resposta `2xx` em até 10 s | Qualquer outra coisa é falha de entrega |

A inscrição por tipo desarma o enum mais perigoso da API: se `cobranca.contestada` chegasse a todo mundo, cada `match tipo:` sem caso padrão viraria `500`. E o `parcelas_detalhe` volta em 30 dias, pelo changelog e pelo sandbox. A consultoria do Bazar trocou uma linha de configuração e cobrou 40 horas.

## Armadilhas e casos reais

> **Armadilha:** o `ETag` da Lastro vem de `cobrancas.versao`, que muda quando a cobrança muda. Com `parcelas_detalhe`, a cobrança ficou igual e a representação mudou. O Hornero, que faz polling com `If-None-Match` (capítulo 9), recebeu `304` e seguiu com a representação velha, sem o campo. O `ETag` identifica a representação, então agora combina `versao` com o identificador do schema de resposta. O Hornero foi o único cliente poupado do incidente, e graças a um bug.

> **Na vida real:** em 2010, o Twitter passou a gerar IDs de tweet de 64 bits com o Snowflake. Acima de 2^53, o `JSON.parse` do JavaScript arredonda o inteiro (capítulo 1) e o cliente lê um ID que não existe. A correção foi aditiva: um campo `id_str`, o mesmo número como string, ao lado do `id`, que nunca pôde sair. Dois IDs por tweet, para sempre, porque remover o errado quebraria quem se acostumou com ele.

**Schema de resposta fechado.** `additionalProperties: false` num schema de resposta faz geradores de cliente produzirem modelos que recusam campo novo. Uma linha de YAML distribuiria o Jackson estrito a todos os clientes, em todas as linguagens, com a assinatura da Lastro. Os schemas publicados declaram `true`.

**A Lei de Hyrum dentro de casa.** Na semana seguinte, o Carlos corrigiu um typo no `detail` de saldo insuficiente: "saldo insuficinte" virou "saldo insuficiente". O Hornero tinha uma regex procurando "insuficinte", e por quatro horas todo saque recusado virou "erro desconhecido" no painel dele. O Carlos derrubou produção acertando a ortografia, feito inédito numa carreira dedicada a derrubar produção errando. O `type` `saldo-insuficiente` estava lá o tempo todo, sem typo, esperando alguém ler.

**Mudança semântica.** Trocar a captura padrão de automática para manual não altera um byte do OpenAPI. Só o teste dirigido pelo consumidor pega; para o diff, está tudo lindo enquanto o dinheiro apodrece em autorização.

## Resumo

- Contrato é todo comportamento observável; pela Lei de Hyrum, alguém depende até do que nunca foi prometido.
- Compatibilidade segue variância: resposta pode crescer, requisição pode aceitar mais. Remover, renomear, mudar tipo, endurecer validação e mudar significado quebram.
- Campo novo exige leitor tolerante; enum precisa ser declarado aberto ou fechado; `null` e ausente precisam de regra.
- Versão no caminho, cabeçalho, media type ou data por conta: cada uma paga em cache, roteamento, visibilidade ou manutenção. `Deprecation` (RFC 9745) e `Sunset` (RFC 8594) assinam o atestado de óbito.
- Paginação promete ordem estável, limite máximo e cursor opaco; filtro define intervalo e fuso, e filtro desconhecido é erro.
- Problem details (RFC 9457): o cliente decide pelo `type`, nunca pelo `detail`.
- Diff de OpenAPI na CI protege o schema; testes dirigidos pelo consumidor protegem o comportamento.
- `ETag` identifica a representação e muda quando o schema muda.

## A Lastro agora

Regras de compatibilidade publicadas: cliente ignora campo desconhecido, enums abertos, mudança aditiva com 30 dias de changelog e estágio no sandbox com o campo-isca. Versão no caminho, 12 meses de convivência. Erros na RFC 9457; cursor assinado; OpenAPI com diff na CI. Webhooks com envelope, `id` para deduplicar, `versao` para descartar evento velho, inscrição por tipo e prazo de 10 segundos. O `ETag` inclui o schema.

O gerente leu as regras e voltou com três pedidos: GraphQL para o painel dos marketplaces, "porque é só uma consulta"; o checkout sabendo em tempo real que o Pix foi pago, sem polling de 2 segundos; e o novo fornecedor de antifraude, que só fala gRPC. Nenhum dos três é JSON sobre `GET`, e o gerente jura que todos são aditivos. É só um campo. É sempre só um campo.

## Referências

- RFC 9457, Problem Details for HTTP APIs: https://www.rfc-editor.org/rfc/rfc9457
- RFC 7807, Problem Details for HTTP APIs (substituída): https://www.rfc-editor.org/rfc/rfc7807
- RFC 9110, HTTP Semantics: https://www.rfc-editor.org/rfc/rfc9110
- RFC 8594, The Sunset HTTP Header Field: https://www.rfc-editor.org/rfc/rfc8594
- RFC 9745, The Deprecation HTTP Response Header Field: https://www.rfc-editor.org/rfc/rfc9745
- RFC 9651, Structured Field Values for HTTP: https://www.rfc-editor.org/rfc/rfc9651
- RFC 9413, Maintaining Robust Protocols: https://www.rfc-editor.org/rfc/rfc9413
- RFC 761 (princípio da robustez): https://www.rfc-editor.org/rfc/rfc761
- RFC 3339, Date and Time on the Internet: https://www.rfc-editor.org/rfc/rfc3339
- RFC 6901, JSON Pointer: https://www.rfc-editor.org/rfc/rfc6901
- OpenAPI Specification: https://spec.openapis.org/oas/latest.html
- JSON Schema 2020-12: https://json-schema.org/draft/2020-12
- Pact, documentação: https://docs.pact.io/
- Hyrum's Law: https://www.hyrumslaw.com/
- Martin Fowler, Tolerant Reader: https://martinfowler.com/bliki/TolerantReader.html
- Stripe, APIs as infrastructure: future-proofing Stripe with versioning (2017): https://stripe.com/blog/api-versioning
- Jackson databind, Deserialization Features: https://github.com/FasterXML/jackson-databind/wiki/Deserialization-Features
