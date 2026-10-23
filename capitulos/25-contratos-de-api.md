# Contratos de API

## Uma palavra a mais no Dia das Mães

"Abri o app para ver onde está o buquê da minha mãe e a tela ficou branca." É a primeira mensagem do Dia das Mães no canal de suporte da Pétala Express (uma floricultura on-line hipotética), e chega às 7h02 da manhã de domingo. Às 7h15 são 300 mensagens. Às 8h, 4.200. O backend está saudável, a latência está ótima, o banco nunca esteve tão tranquilo. Só não tem ninguém conseguindo usá-lo.

A causa foi um deploy de quinta-feira, 18h30, descrito no pull request como "só adiciona um status". O Válter, dono do serviço de pedidos, acrescentou o valor `"agendado"` ao campo `status` da resposta de `GET /pedidos/{id}`, para entregas marcadas com hora certa. Ele não removeu nada, não renomeou nada e não mudou nenhum tipo. Acrescentou uma palavra.

O app 3.2.1, lançado em 2022 e ainda instalado em 31% dos celulares (ninguém atualiza app de floricultura entre um Dia das Mães e o seguinte), tratava o status assim:

```typescript
switch (pedido.status) {
  case "preparando": return <Preparando />;
  case "a_caminho":  return <ACaminho />;
  case "entregue":   return <Entregue />;
  default: throw new Error(`status desconhecido: ${pedido.status}`);
}
```

Código correto, exaustivo, revisado por duas pessoas. E o `throw` foi justamente o que derrubou a tela, porque às 7h da manhã de domingo todos os buquês com hora marcada estavam `"agendado"`.

Se acrescentar um valor derruba um cliente, o que é seguro mudar numa API? E como descobrir isso na quinta-feira, antes do deploy, em vez de no domingo, pelo suporte?

## O contrato que ninguém assinou e todo mundo cumpre

O **contrato** de uma API é o conjunto de promessas que o cliente usa para escrever código: rotas, formato dos corpos, tipos, códigos de status, cabeçalhos, semântica. Parte disso está escrita (num documento OpenAPI, por exemplo). Outra parte o cliente deduziu olhando as respostas, e é aí que a vida fica interessante.

Hyrum Wright, engenheiro do Google, registrou a observação conhecida como **Lei de Hyrum**: com usuários suficientes, não importa o que o contrato promete, todo comportamento observável vai ter alguém dependendo dele. A ordem de uma lista sem ordenação documentada. O texto exato de uma mensagem de erro. O endpoint que responde em 80 ms (alguém pôs um timeout de 100 ms).

Por isso **compatibilidade retroativa** (*backward compatibility*) tem uma definição operacional: a mudança é compatível se todo cliente que funcionava antes continua funcionando depois, sem alterar uma linha. Os clientes reais, inclusive o app 3.2.1, e não o documento.

### Variância, ou o que pode crescer e o que pode encolher

A regra para decidir se uma mudança de formato quebra vem do sistema de tipos do TypeScript. Uma função `f: A → B` pode ser trocada por `g: A' → B'` sem quebrar quem a chama se `g` aceita pelo menos tudo que `f` aceitava (parâmetro **contravariante**) e devolve no máximo o que `f` devolvia (retorno **covariante**). É o que o `strictFunctionTypes` verifica.

Um endpoint é uma função remota: a requisição é o parâmetro, a resposta é o retorno. Na requisição, o servidor pode passar a aceitar mais (campo opcional novo, limite de tamanho maior). Na resposta, pode passar a devolver menos variedade (um campo que podia ser `null` e agora nunca é).

O inverso quebra. Um campo obrigatório novo na requisição quebra todo cliente que não o envia. E um valor novo num enum de resposta alarga o conjunto de retorno, que é exatamente o caso do `"agendado"`. Em teoria de tipos isso se chama violar a covariância do retorno; no suporte, chama-se 4.200 mensagens.

| Mudança | Na requisição | Na resposta |
|---|---|---|
| Campo novo opcional | Compatível | Compatível se o cliente ignora campos desconhecidos |
| Campo novo obrigatório | Quebra | Compatível (mesma ressalva) |
| Remover ou renomear campo | Quebra | Quebra |
| Mudar tipo (`integer` → `string`) | Quebra | Quebra |
| Valor novo em enum | Compatível | Quebra tratamento exaustivo |
| Afrouxar validação ou aceitar `null` | Compatível | Quebra |
| Apertar validação | Quebra | Compatível |

A ressalva do campo novo na resposta existe porque a subtipagem por largura (objeto com mais campos é subtipo do objeto com menos) só vale se o cliente ignora o que não conhece.

### O leitor tolerante

Um cliente que ignora campos desconhecidos e tem um caminho para valores desconhecidos segue o padrão chamado **leitor tolerante** (*tolerant reader*). No Python, o Pydantic já vem assim: o padrão é `extra="ignore"`. Quem configura `extra="forbid"` no lado cliente transformou cada campo novo do servidor num incidente:

```python
from pydantic import BaseModel, ConfigDict, ValidationError

class PedidoTolerante(BaseModel):
    id: int
    status: str  # extra="ignore" é o padrão

class PedidoRigido(BaseModel):
    model_config = ConfigDict(extra="forbid")  # "segurança", segundo o commit
    id: int
    status: str

dados = {"id": 5120, "status": "entregue", "foto_entrega_url": "https://cdn.example/5120.jpg"}
print(PedidoTolerante.model_validate(dados))
try:
    PedidoRigido.model_validate(dados)
except ValidationError as erro:
    print(erro)
```

```text
id=5120 status='entregue'
1 validation error for PedidoRigido
foto_entrega_url
  Extra inputs are not permitted [type=extra_forbidden, input_value='https://cdn.example/5120.jpg', input_type=str]
    For further information visit https://errors.pydantic.dev/2.9/v/extra_forbidden
```

Enums são mais traiçoeiros, porque a biblioteca padrão é rígida por padrão. O `Enum` do Python levanta exceção para valor desconhecido, e o método `_missing_` permite um valor de reserva:

```python
from enum import StrEnum

class StatusEntrega(StrEnum):
    PREPARANDO = "preparando"
    A_CAMINHO = "a_caminho"
    ENTREGUE = "entregue"
    DESCONHECIDO = "desconhecido"

    @classmethod
    def _missing_(cls, valor):
        return cls.DESCONHECIDO  # mostra "acompanhe pelo e-mail" em vez de tela branca

print(StatusEntrega("agendado"))
```

```text
desconhecido
```

Sem o `_missing_`, a saída seria `ValueError: 'agendado' is not a valid StatusEntrega`, a versão Python do domingo da Pétala Express. As diretrizes de API da Zalando marcam no próprio contrato os enums que podem crescer, com a extensão `x-extensible-enum` do OpenAPI.

A **Lei de Postel** (RFC 761, de 1980) diz "seja conservador no que envia e liberal no que aceita". A RFC 9413, de 2023, registra o outro lado: tolerância demais faz implementações dependerem de desvios nunca especificados, que viram contrato à força (a Lei de Hyrum com sotaque de IETF). A divisão usual é tolerância do cliente com o que é **novo** e rigor do servidor com o que é **inválido**.

### Mudanças que o schema não vê

As quebras mais caras passam por qualquer validador, porque o formato continua idêntico. O campo `prazo` passa de segundos para milissegundos, continua `integer`, e os prazos ficam mil vezes maiores sem ninguém reclamar por uma semana. O tamanho padrão da página cai de 50 para 20, e o cliente que nunca enviou `limite` acha que os pedidos sumiram. Um `POST` que respondia `201` passa a responder `202` e processar depois. Nenhum diff de schema mostra isso: são mudanças de **semântica**, e só testes de comportamento as pegam.

## Versionamento

Quando a mudança incompatível é inevitável, o contrato antigo continua funcionando enquanto o novo existe. Versionar é dar nome a cada contrato e deixar o cliente escolher. Só mudança incompatível pede versão nova; o resto entra na atual sem cerimônia.

| Estratégia | Exemplo | Cache HTTP | Custo principal |
|---|---|---|---|
| Caminho | `/v2/pedidos` | A URL já é a chave | Mesmo recurso com várias URIs; a API inteira muda de versão junta |
| Cabeçalho próprio | `Api-Version: 2` | Exige `Vary` | Requisição sem cabeçalho precisa de um padrão, e o padrão vira contrato |
| Tipo de mídia | `Accept: application/vnd.petala.v2+json` | Exige `Vary: Accept` | Roteamento por cabeçalho; `406` para versão inexistente |
| Data fixada por conta | `Stripe-Version: 2024-06-20` | Exige `Vary` | Cadeia de transformações que só cresce |
| Sem versão | GraphQL com `@deprecated` | Não se aplica | Campos obsoletos se acumulam |

O problema do padrão é concreto. O app 3.2.1 nunca enviou `Api-Version`, porque em 2022 o cabeçalho não existia. Se o padrão for "a mais recente", cada versão nova quebra o 3.2.1. Se for "a primeira", você mantém a v1 enquanto houver um 3.2.1 vivo, o que, pela taxa de atualização de apps de floricultura, significa até a morte térmica do universo.

A Stripe documentou a variante por data (Brandur Leach, 2017): cada conta fica fixada na versão vigente na sua primeira requisição. O código principal só conhece a versão mais nova, e cada mudança incompatível traz um módulo que converte a resposta nova no formato anterior. A resposta de uma conta antiga atravessa os módulos em ordem inversa até chegar ao formato que ela conhece.

A versão velha também precisa de um caminho para morrer. `Deprecation` (RFC 9745) informa desde quando o recurso é obsoleto, no formato de data dos campos estruturados; `Sunset` (RFC 8594) informa a partir de quando ele pode parar de responder:

```http
HTTP/1.1 200 OK
Content-Type: application/json
Deprecation: @1782864000
Sunset: Thu, 31 Dec 2026 23:59:59 GMT
Link: <https://api.petala.example/docs/migracao-v2>; rel="deprecation"
```

`@1782864000` é 1º de julho de 2026, 00h00 UTC. Cliente nenhum lê cabeçalho por vontade própria, então o dado precisa virar métrica no servidor: requisições por versão e por cliente. Desligar a v1 quando ela ainda recebe 9% do tráfego é o `"agendado"` de novo, só que agendado.

## Paginação e filtros também são contrato

A mecânica da paginação no banco (por que `OFFSET` fica lento, como o cursor usa o índice) está no capítulo 9; aqui interessa o que o cliente pode supor.

Na paginação por **offset** (`?pagina=3&limite=50`), o contrato é posicional. Se um pedido novo entra no topo enquanto o cliente está na página 2, tudo anda uma posição, e o último item da página 2 reaparece no início da página 3. Uma exclusão faz o contrário: um item pula de página e ninguém o vê. Tudo isso com cada consulta individual perfeitamente correta.

Na paginação por **cursor**, o servidor devolve um token que codifica onde a página parou (o par `(criado_em, id)` do último item, por exemplo), e a próxima começa estritamente depois dele. O contrato que acompanha:

- O cursor é **opaco**. Se o cliente decodifica o base64 e encontra um `id` lá dentro, alguém vai montar cursores à mão (Lei de Hyrum, terceira aparição). Uma assinatura HMAC impede a montagem.
- A ordenação é total. Só `criado_em`, com dois pedidos no mesmo microssegundo, deixa o banco livre para alterná-los entre consultas; o desempate por `id` faz parte da ordenação.
- O fim é explícito: sem campo `proximo` (ou sem `rel="next"` no cabeçalho `Link`, da RFC 8288), acabou. O app 3.2.1, claro, pede páginas até receber uma lista vazia.
- O `limite` tem teto. Sem teto, alguém pede `?limite=1000000` e o servidor monta um JSON de 900 MB com a dedicação de quem não foi avisado.

O **total de itens** custa caro: `SELECT count(*)` no PostgreSQL visita cada linha que casa com o filtro, porque o MVCC exige checar a visibilidade de cada uma. Em 40 milhões de pedidos são segundos por requisição para desenhar "página 1 de 800.000". Por isso o total costuma ser omitido, opcional (`?incluir_total=true`) ou uma estimativa declarada.

Cada filtro aceito promete que aquela consulta roda em tempo razoável, o que em geral exige um índice (capítulo 8). Daí a lista explícita (`status`, `criado_desde`), com formatos fixos: datas em RFC 3339 com fuso (`2026-05-10T07:02:00-03:00`), múltiplos valores repetindo o parâmetro ou separados por vírgula, um dos dois, para sempre.

E parâmetro desconhecido? Ignorado em silêncio, um script que chama `GET /pedidos?stauts=pendente` para cancelar os pendentes recebe todos os pedidos e cancela todos. Um `400` citando o parâmetro estranho elimina essa classe de erro, ao custo de o servidor precisar conhecer cada parâmetro novo antes dos clientes.

## Erros com formato

Uma API comum acumula, com os anos, `{"error": "..."}`, `{"message": "..."}`, `{"erro": {"codigo": 17}}` e uma página HTML do proxy dizendo `502 Bad Gateway`, às vezes no mesmo endpoint.

A RFC 9457 (de 2023, substitui a RFC 7807) define o *problem details*, com tipo de mídia `application/problem+json`. O membro `type` é uma URI que identifica o tipo de problema, e é nele que o código do cliente decide o que fazer (ausente, vale `"about:blank"`: nada além do status). `title` resume o tipo e não muda entre ocorrências. `status` repete o código HTTP, que precisa ser o mesmo da resposta. `detail` explica esta ocorrência para humanos, e o cliente não deve fazer parsing dele. `instance` identifica a ocorrência.

Membros extras são permitidos, e o cliente que não os conhece deve ignorá-los: a RFC embute o leitor tolerante. O FastAPI responde validação com `422` e `{"detail": [...]}`; um handler converte:

```python
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

app = FastAPI()
PROBLEMAS = "https://api.petala.example/problemas"

class NovoPedido(BaseModel):
    produto_id: str
    quantidade: int = Field(gt=0)  # meio buquê não existe, apesar dos pedidos

@app.exception_handler(RequestValidationError)
async def validacao_como_problema(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=422,
        media_type="application/problem+json",
        content={
            "type": f"{PROBLEMAS}/validacao",
            "title": "A requisição tem campos inválidos",
            "status": 422,
            "instance": request.url.path,
            "erros": [
                {"campo": ".".join(map(str, e["loc"][1:])), "mensagem": e["msg"]}
                for e in exc.errors()
            ],
        },
    )

@app.post("/pedidos", status_code=201)
async def criar_pedido(pedido: NovoPedido):
    return {"id": "ped_5120", **pedido.model_dump()}
```

```bash
curl -s -X POST https://api.petala.example/pedidos \
  -H 'Content-Type: application/json' \
  -d '{"produto_id": "buque-rosas-12", "quantidade": 0}'
```

```json
{"type":"https://api.petala.example/problemas/validacao","title":"A requisição tem campos inválidos","status":422,"instance":"/pedidos","erros":[{"campo":"quantidade","mensagem":"Input should be greater than 0"}]}
```

O campo `erros` é uma extensão própria (a RFC 9457 mostra uma parecida para vários erros de validação). O `type` é estável e documentado; o texto de `mensagem` vem do Pydantic e pode mudar numa atualização da biblioteca, então nenhum cliente deveria comparar strings com ele (e algum vai, porque Hyrum). Trocar o status ou o `type` de um erro é tão incompatível quanto remover um campo.

## OpenAPI e testes de contrato

A OpenAPI Specification descreve uma API HTTP num documento JSON ou YAML: caminhos, parâmetros, corpos, respostas por status, esquemas de segurança e schemas dos dados (alinhados ao JSON Schema 2020-12 desde a versão 3.1). O FastAPI gera o documento a partir das anotações de tipo, em `/openapi.json`.

No **code-first**, o documento sai do código e nunca diverge da implementação; em compensação, renomear um atributo Pydantic numa refatoração inocente renomeia o campo no JSON sem ninguém perceber. No **design-first**, o documento vem antes e é revisado como contrato, mas pode divergir do código se nada verificar os dois juntos. Nos dois casos, o documento versionado no repositório alimenta as verificações automáticas.

### Diff de contrato no CI

Com a versão anterior e a nova do documento, um programa aplica as regras de variância. Uma versão de brinquedo, só para propriedades de objetos:

```python
def quebras(antigo: dict, novo: dict, direcao: str, caminho: str = "$") -> list[str]:
    """direcao: 'requisicao' (pode alargar) ou 'resposta' (pode estreitar)."""
    problemas = []
    props_novo = novo.get("properties", {})
    for nome, esq_antigo in antigo.get("properties", {}).items():
        local = f"{caminho}.{nome}"
        if nome not in props_novo:
            if direcao == "resposta":
                problemas.append(f"{local}: removido da resposta")
            continue
        esq_novo = props_novo[nome]
        if esq_antigo.get("type") != esq_novo.get("type"):
            problemas.append(f"{local}: tipo {esq_antigo.get('type')} -> {esq_novo.get('type')}")
        enum_a, enum_n = set(esq_antigo.get("enum", [])), set(esq_novo.get("enum", []))
        if direcao == "resposta" and enum_n - enum_a:
            problemas.append(f"{local}: valores novos no enum {sorted(enum_n - enum_a)}")
        if direcao == "requisicao" and enum_a - enum_n:
            problemas.append(f"{local}: valores deixaram de ser aceitos {sorted(enum_a - enum_n)}")
        problemas += quebras(esq_antigo, esq_novo, direcao, local)
    obrig_a, obrig_n = set(antigo.get("required", [])), set(novo.get("required", []))
    if direcao == "requisicao":
        problemas += [f"{caminho}.{n}: passou a ser obrigatório" for n in sorted(obrig_n - obrig_a)]
    else:
        problemas += [f"{caminho}.{n}: pode faltar na resposta" for n in sorted(obrig_a - obrig_n)]
    return problemas


v1 = {"type": "object", "required": ["id", "status"], "properties": {
    "id": {"type": "integer"},
    "status": {"type": "string", "enum": ["preparando", "a_caminho", "entregue"]},
    "cartao": {"type": "string"},
}}
v2 = {"type": "object", "required": ["id", "status"], "properties": {
    "id": {"type": "string"},
    "status": {"type": "string", "enum": ["preparando", "a_caminho", "entregue", "agendado"]},
    "cartao_mensagem": {"type": "string"},  # "só deixei o nome mais claro"
}}

for problema in quebras(v1, v2, "resposta"):
    print(problema)
```

```text
$.id: tipo integer -> string
$.status: valores novos no enum ['agendado']
$.cartao: removido da resposta
```

A renomeação aparece pelo que é para o cliente: um campo sumiu. O oasdiff faz isso sobre documentos OpenAPI inteiros, com centenas de regras, e falha o pipeline. Na quinta-feira, ele teria impresso a segunda linha, e o domingo teria sido só um domingo.

Para verificar se a implementação cumpre o documento, o Schemathesis lê o OpenAPI, gera requisições com a biblioteca Hypothesis (testes baseados em propriedades) e confere se as respostas batem com os schemas e se nenhuma é `500`. Um nome com 40 mil caracteres costuma derrubar o endpoint que todos juravam estar validado.

### Contratos dirigidos pelo consumidor

O diff não sabe quais campos os clientes usam. Os **contratos dirigidos pelo consumidor** (*consumer-driven contracts*, Ian Robinson, 2006) invertem a fonte: cada consumidor publica o que espera, e o CI do provedor verifica tudo antes do deploy. No Pact, a ferramenta mais conhecida, o teste do consumidor grava as interações contra um mock, o provedor as reproduz contra a implementação real e o Pact Broker responde se uma versão pode ir para produção. A ideia cabe num teste pequeno. O time do app publica o que usa:

```json
{
  "GET /pedidos/5120": {
    "status": 200,
    "campos": {"id": "string", "status": "string", "previsao_entrega": "string"}
  }
}
```

E o provedor verifica:

```python
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from petala.app import app  # com banco de teste contendo o pedido 5120

cliente = TestClient(app)
CONTRATOS = json.loads(Path("contratos/app-mobile.json").read_text())
TIPOS = {"string": str, "integer": int, "boolean": bool}

@pytest.mark.parametrize("rota,esperado", CONTRATOS.items())
def test_contrato_app_mobile(rota, esperado):
    metodo, caminho = rota.split(" ", 1)
    resposta = cliente.request(metodo, caminho)
    assert resposta.status_code == esperado["status"]
    corpo = resposta.json()
    for campo, tipo in esperado["campos"].items():
        assert campo in corpo, f"o app usa '{campo}' e ele sumiu"
        assert isinstance(corpo[campo], TIPOS[tipo]), f"'{campo}' mudou de tipo"
```

```text
FAILED tests/test_contratos.py::test_contrato_app_mobile[GET /pedidos/5120-esperado0] - AssertionError: o app usa 'previsao_entrega' e ele sumiu
```

O Pact formaliza o que este teste improvisa: estados do provedor ("dado que o pedido 5120 existe"), comparação por tipo e o registro de qual versão do consumidor está em produção.

## Propriedades e custos

| Verificação | O que pega | O que não pega | Exige |
|---|---|---|---|
| Diff de OpenAPI | Quebras de formato entre versões | Semântica; alarme por campo que ninguém usa | Documento versionado e fiel |
| Provedor contra o OpenAPI | Código divergindo do documento; `500` com entrada estranha | Quebra documentada direitinho | Documento completo |
| Dirigido pelo consumidor | Campo usado por consumidor conhecido | Consumidor sem contrato publicado | Consumidores cooperando |
| Métrica de uso por versão | Quem ainda usa o que vai sair | Nada antes do deploy | Instrumentação |

Contratos dirigidos pelo consumidor exigem consumidores conhecidos, o que descreve serviços internos. Numa API pública sobram o diff, as regras de variância e os cabeçalhos de obsolescência. E o custo do versionamento cresce com as versões vivas, cada uma com seu código, testes e correções de segurança: uma versão maior por trimestre, sem desligar nenhuma, dá 24 APIs em seis anos, e a número 1 continua a mais usada, por causa de um certo app de floricultura.

## Armadilhas e casos reais

> **Na vida real:** a API do Twitter devolvia IDs como números JSON de 64 bits. O `Number` do JavaScript é um double IEEE 754, exato só até 2^53 − 1 (9.007.199.254.740.991). Quando os IDs passaram disso, clientes JavaScript passaram a arredondá-los em silêncio, e a API ganhou o campo `id_str`, o mesmo ID como string.

```bash
node -e 'console.log(JSON.parse("{\"id\": 1234567890123456789}").id)'
```

```text
1234567890123456800
```

O ID chegou com 11 a mais, e o JavaScript não viu motivo para comentar. Por isso IDs de 64 bits costumam viajar como string, e dinheiro como inteiro em centavos ou string decimal.

> **Armadilha:** geradores de cliente a partir do OpenAPI costumam transformar `enum` em tipo fechado com parsing estrito. Cada valor novo vira o domingo da Pétala Express em todas as linguagens ao mesmo tempo.

> **Armadilha:** sem o `openapi.json` no repositório, não existe versão anterior para comparar, e o diff do CI compara o contrato com ele mesmo, com 100% de aprovação.

> **Armadilha:** apps móveis e SDKs vivem anos sem atualização. Um app no celular segue a agenda do dono do celular, e o contrato com o 3.2.1 vale enquanto houver tráfego dele nas métricas, diga o calendário de suporte o que disser.

## Resumo

- Contrato = tudo que o cliente usa, inclusive (Lei de Hyrum) qualquer comportamento observável.
- Compatível = todo cliente que funcionava continua funcionando sem mudar código.
- Variância: requisição pode aceitar mais, resposta pode devolver menos variedade. Enum novo na resposta, obrigatório novo na requisição, renomeação e troca de tipo quebram.
- Leitor tolerante: ignorar campos desconhecidos, ter caminho para valor de enum desconhecido.
- Mudanças semânticas não aparecem em diff de schema.
- Versão nova só para quebra; `Deprecation` e `Sunset` anunciam o fim, a métrica de uso decide quando.
- Paginação: cursor opaco, ordenação total, fim explícito, teto no `limite`.
- Erros em `application/problem+json`, com `type` estável.
- OpenAPI no repositório, diff no CI, contratos dirigidos pelo consumidor quando os consumidores são conhecidos.
- O app 3.2.1 continua instalado.

## Referências

- RFC 9457, *Problem Details for HTTP APIs*: <https://www.rfc-editor.org/rfc/rfc9457>
- RFC 9110, *HTTP Semantics*: <https://www.rfc-editor.org/rfc/rfc9110>
- RFC 8594, *The Sunset HTTP Header Field*: <https://www.rfc-editor.org/rfc/rfc8594>
- RFC 9745, *The Deprecation HTTP Response Header Field*: <https://www.rfc-editor.org/rfc/rfc9745>
- RFC 9651, *Structured Field Values for HTTP*: <https://www.rfc-editor.org/rfc/rfc9651>
- RFC 8288, *Web Linking*: <https://www.rfc-editor.org/rfc/rfc8288>
- RFC 3339, *Date and Time on the Internet: Timestamps*: <https://www.rfc-editor.org/rfc/rfc3339>
- RFC 9413, *Maintaining Robust Protocols*: <https://www.rfc-editor.org/rfc/rfc9413>
- OpenAPI Specification: <https://spec.openapis.org/oas/latest.html>
- Hyrum Wright, *Hyrum's Law*: <https://www.hyrumslaw.com/>
- Brandur Leach, *APIs as infrastructure: future-proofing Stripe with versioning* (2017): <https://stripe.com/blog/api-versioning>
- Ian Robinson, *Consumer-Driven Contracts: A Service Evolution Pattern* (2006): <https://martinfowler.com/articles/consumerDrivenContracts.html>
- Martin Fowler, *TolerantReader*: <https://martinfowler.com/bliki/TolerantReader.html>
- Zalando RESTful API Guidelines: <https://opensource.zalando.com/restful-api-guidelines/>
- Pact, documentação: <https://docs.pact.io/>
- Schemathesis, documentação: <https://schemathesis.readthedocs.io/>
- oasdiff: <https://github.com/oasdiff/oasdiff>
- Pydantic, configuração `extra`: <https://docs.pydantic.dev/latest/api/config/>
- Python, `enum` e `_missing_`: <https://docs.python.org/3/library/enum.html>
- Twitter (X) Developer Platform, *Twitter IDs*: <https://developer.x.com/en/docs/twitter-ids>
