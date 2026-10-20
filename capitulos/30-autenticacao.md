# Autenticação

## O professor que saiu em março e continua dando aula

Numa segunda-feira de agosto, a plataforma de aulas de violão on-line amanheceu com uma aula nova publicada: "Asa Branca para iniciantes, parte 14". O autor era o Gilberto. O Gilberto saiu da empresa em março, com festa de despedida, bolo e um cartão assinado por todo mundo.

A equipe conferiu o banco. A conta do Gilberto tinha sido apagada no dia da saída. O botão "Sair" tinha sido clicado. Mesmo assim, a API aceitava as requisições dele com toda a cortesia, porque cada uma trazia um JWT perfeitamente assinado, com `"papel": "professor"` e validade de um ano. Alguém tinha configurado assim em 2024, com o comentário `# 365 dias pra ninguém reclamar de login`. Ninguém reclamou. O Gilberto, em especial, estava muito satisfeito.

O "Sair" apagava o token do `localStorage` do navegador. O servidor nunca soube que o Gilberto saiu, porque o servidor, nesse desenho, não guarda nada sobre ninguém: ele confere uma assinatura e acredita.

A pergunta deste capítulo é essa: como o servidor sabe quem está do outro lado de uma requisição, e como ele deixa de saber quando precisa?

## O mecanismo

### Provar uma vez, lembrar o resto do tempo

*Autenticação* é verificar quem fez a requisição. *Autorização* é decidir o que essa identidade pode fazer, e fica para o capítulo 31. As duas costumam morar na mesma função de 40 linhas chamada `verifica_usuario`, o que explica muita coisa.

HTTP não tem estado, então a autenticação acontece em duas fases. Na primeira, o usuário prova a identidade uma vez (senha, código, passkey). Na segunda, o servidor entrega uma **credencial derivada**, que o cliente apresenta em toda requisição seguinte. Quase todo o capítulo trata dela: onde fica, o que carrega e como morre. O hash da senha é tema do capítulo 33.

### Sessão com cookie, ou o servidor que tem memória

No modelo clássico, depois do login o servidor gera um identificador aleatório, grava num armazenamento (`sessao:<id> → {usuario: 1984, criada_em: ...}`) e devolve o identificador num cookie. O navegador reenvia o cookie em toda requisição para aquele domínio, sem uma linha de JavaScript. O servidor procura o identificador, acha a sessão e sabe quem é.

O identificador precisa ser imprevisível: 128 bits ou mais vindos de um gerador criptográfico (`secrets` em Python, nunca `random`). Com 128 bits, adivinhar uma sessão válida entre um milhão de sessões ativas exige, em média, 2^108 tentativas. O rate limiter agradece a confiança.

Os atributos do cookie (RFC 6265) fazem metade do trabalho de segurança:

- `HttpOnly`: o JavaScript da página não lê o cookie. Um XSS ainda consegue fazer requisições com ele, mas não consegue copiá-lo para outro lugar.
- `Secure`: só viaja em HTTPS.
- `SameSite=Lax`: o navegador só envia o cookie em requisições vindas de outro site se forem navegação de nível superior com método seguro (clicar num link). Isso fecha a maior parte do CSRF, em que um site malicioso dispara um `POST` para a sua API e o navegador anexa o cookie da vítima, prestativo como sempre.
- O prefixo `__Host-` obriga `Secure` e `Path=/` e proíbe `Domain`, o que impede um subdomínio esquecido (o `promo-2019.exemplo.com`) de sobrescrever o cookie.

A grande propriedade da sessão é que **logout funciona**. Apagar a chave mata a sessão na requisição seguinte, em qualquer réplica. Com sessão, o `DELETE` de março teria encerrado a carreira docente do Gilberto no mesmo segundo. O custo é uma consulta por requisição (perto de 0,2 ms num Redis na mesma rede) e um armazenamento compartilhado entre as réplicas (capítulo 29).

### Tokens opacos e JWT

Fora do navegador, a credencial costuma viajar no cabeçalho `Authorization: Bearer <token>` (RFC 6750). *Bearer* quer dizer "portador": quem apresenta o token é tratado como dono dele, sem nenhuma outra prova. Um token vazado num log vale tanto quanto o original.

O **token opaco** é uma sessão com outro nome: um valor aleatório que o servidor resolve consultando um armazenamento ou o endpoint de *introspection* do emissor (RFC 7662). O **token autocontido** carrega os dados assinados, e qualquer serviço com a chave pública valida sem consultar ninguém. O formato dominante é o JWT.

### Anatomia de um JWT

Um JWT (RFC 7519) no formato JWS (RFC 7515) tem três partes em base64url separadas por ponto: cabeçalho, carga (*payload*) e assinatura. Base64url é codificação, e codificação qualquer pessoa desfaz. O token do Gilberto, aberto com a biblioteca padrão:

```python
import base64
import json

def decodificar_segmento(segmento: str) -> dict:
    preenchimento = "=" * (-len(segmento) % 4)
    return json.loads(base64.urlsafe_b64decode(segmento + preenchimento))

cabecalho, carga, assinatura = token_do_gilberto.split(".")
print(decodificar_segmento(cabecalho))
print(decodificar_segmento(carga))
```

```text
{'alg': 'RS256', 'typ': 'JWT', 'kid': '2026-03'}
{'iss': 'https://auth.violao.example', 'sub': 'u-1984', 'aud': 'api-aulas', 'iat': 1772539200, 'exp': 1804075200, 'papel': 'professor'}
```

As *claims* registradas têm significado definido: `iss` é o emissor, `sub` o sujeito (o usuário), `aud` a audiência (a API que deve aceitar o token), `iat` o momento da emissão e `exp` o fim da validade, em segundos Unix. Aqui, `iat` é 3 de março de 2026, 12h UTC, e `exp` é 3 de março de 2027. O Gilberto tem aula garantida até o Carnaval.

A assinatura cobre `base64url(cabeçalho) + "." + base64url(carga)`. Com `HS256` é um HMAC-SHA256 com segredo compartilhado: quem valida também consegue emitir. Com `RS256` (RSA) ou `ES256` (ECDSA P-256), o emissor assina com a chave privada e as APIs validam com a pública, publicada num JWKS (RFC 7517). O `kid` diz qual chave do conjunto usar, o que permite rotacionar chaves.

A validação confere o algoritmo contra uma lista fixa, a assinatura, `exp`, `iss` e `aud`. Com PyJWT:

```python
import os
import jwt

CHAVE_PUBLICA = os.environ["JWT_CHAVE_PUBLICA_PEM"]

def validar(token: str) -> dict:
    return jwt.decode(
        token,
        CHAVE_PUBLICA,
        algorithms=["RS256"],      # lista fixa; o "alg" do token não decide nada
        audience="api-aulas",
        issuer="https://auth.violao.example",
        leeway=30,                 # tolerância de relógio, em segundos
    )

print(validar(token_do_gilberto)["papel"])
```

```text
professor
```

A conta foi apagada, a festa aconteceu, o bolo acabou, e a resposta continua `professor`. A validação local fez exatamente o que promete: provou que o emissor assinou aquilo. Ela nada diz sobre o que aconteceu depois da assinatura.

O `algorithms` fixo existe por causa de uma falha histórica. O cabeçalho do token é controlado por quem envia, e o RFC 7519 define o algoritmo `none` (token sem assinatura). Bibliotecas que obedeciam ao `alg` do próprio token aceitavam isto:

```python
forjado = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0." + carga_com_papel_admin + "."
validar(forjado)
```

```text
jwt.exceptions.InvalidAlgorithmError: The specified alg value is not allowed
```

O primeiro segmento é `{"alg":"none","typ":"JWT"}` em base64url, com assinatura vazia. A PyJWT recusa porque `none` está fora da lista. O RFC 8725 (boas práticas de JWT) existe em boa parte para conter esse tipo de criatividade.

### Expiração e revogação, ou como fazer um token morrer antes da hora

Um JWT válido continua válido até `exp`, e nenhum mecanismo do formato muda isso. Revogar exige estado, e as opções são formas diferentes de reintroduzir o estado que o JWT prometia eliminar:

1. **Vida curta + refresh token.** O *access token* dura de 5 a 15 minutos, e o cliente troca um *refresh token* (opaco, guardado pelo emissor) por outro. Revogar o refresh token encerra o acesso em no máximo um `exp`. Com 10 minutos, o Gilberto teria dado aula até as 12h10 do dia da saída.
2. **Lista de negação por `jti`.** Os identificadores (`jti`) dos tokens revogados vão para o Redis com TTL igual ao tempo restante até `exp`. A lista é pequena, mas toda validação consulta a rede.
3. **Geração por usuário.** O token carrega `"ger": 7`, e o banco guarda a geração atual. "Sair de todos os dispositivos" incrementa para 8 e mata todo token antigo. Uma leitura por requisição, de novo.

As opções 2 e 3 transformam o JWT numa sessão com assinatura. Funciona, e pelo menos o custo fica visível em vez de escondido num comentário de 2024.

Refresh tokens vivem muito. O RFC 9700 (segurança do OAuth 2.0, 2025) exige que, em clientes públicos, eles sejam presos ao remetente ou rotacionados. Na **rotação**, cada uso devolve um refresh token novo e invalida o anterior. Se o antigo reaparecer, alguém tem uma cópia, e o servidor revoga a família inteira: o cliente legítimo e o atacante perdem a sessão juntos.

### OAuth 2.0, ou como deixar um app agir por você sem entregar a senha

O OAuth 2.0 (RFC 6749) resolve **delegação**: o usuário autoriza um cliente (o app) a acessar uma API em nome dele, sem que o cliente veja a senha. Quem autentica e emite tokens é o servidor de autorização; a API é o servidor de recursos.

O fluxo atual para apps com usuário é o **authorization code com PKCE**:

```text
1. Cliente  -> navegador: vá para /authorize?response_type=code&client_id=app-violao
                          &redirect_uri=https://app.violao.example/callback
                          &scope=openid%20aulas.escrever&state=Xk2...
                          &code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
                          &code_challenge_method=S256
2. Usuário  -> servidor de autorização: login, consentimento
3. Servidor -> navegador: 302 para /callback?code=SplxlOB...&state=Xk2...
4. Cliente  -> POST /token: grant_type=authorization_code, code, code_verifier
5. Servidor -> cliente: access_token, refresh_token, id_token
```

O `code` viaja pelo navegador, exposto a histórico e logs, então dura segundos, é de uso único e só vira token no passo 4. O `state` amarra a resposta à requisição que o cliente iniciou e fecha o CSRF no callback. O `redirect_uri` precisa bater por comparação exata de string com o cadastrado. Comparações "flexíveis" já entregaram códigos a domínios de atacantes mais vezes do que dá para contar com conforto.

### PKCE, o segredo de uso único

Um app móvel ou uma SPA é um **cliente público**: não consegue guardar segredo, porque qualquer pessoa extrai o binário ou abre as ferramentas do navegador. Sem segredo, quem interceptar o `code` no passo 3 troca por um token. O PKCE (RFC 7636) cria um segredo por login:

```python
import base64
import hashlib

verificador = "dBjftJeZ4CVP-mJ92K1fESYJiChE4ubSTeL3ufMZ-Ys"  # vetor de teste do RFC 7636
desafio = base64.urlsafe_b64encode(
    hashlib.sha256(verificador.encode()).digest()
).rstrip(b"=").decode()
print(desafio)
```

```text
E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
```

Em produção, o verificador sai de `secrets.token_urlsafe(32)` (43 caracteres, o mínimo do RFC). O desafio vai no passo 1, o verificador no passo 4, e o servidor recalcula e compara. Quem roubou o `code` não tem o verificador, e o SHA-256 não anda para trás. O RFC 9700 recomenda PKCE para todos os clientes, inclusive os confidenciais.

Outros fluxos em uso: **client credentials**, para serviço chamando serviço sem usuário, e **device authorization** (RFC 8628), para a smart TV que mostra "acesse exemplo.com/ativar e digite WDJB-MJHT". O fluxo **implícito** (token direto na URL de retorno) e o **resource owner password** (o app recebe a senha do usuário, o que anula o propósito do OAuth inteiro) estão desaconselhados pelo RFC 9700 e fora do rascunho do OAuth 2.1.

### OpenID Connect, a parte que diz quem é a pessoa

O OAuth 2.0 nunca definiu como o cliente descobre quem fez login. O OpenID Connect (OIDC Core 1.0) acrescenta isso: com o escopo `openid`, o passo 5 devolve também um **ID token**, um JWT com `iss`, `sub`, `aud` igual ao `client_id`, `exp`, `nonce` e, se pedido, `email`. Acrescenta também a descoberta em `/.well-known/openid-configuration`.

O ID token é para o cliente ler; a `aud` dele é o app. O access token é para a API. Uma API que aceita ID token como credencial aceita qualquer token que qualquer app tenha recebido daquele provedor, o que amplia bastante o corpo docente.

A identidade estável é o par `(iss, sub)`. O `email` muda, pode chegar sem verificação e, em alguns provedores, é editável.

### MFA, ou o segundo fator e seus defeitos

MFA combina fatores de categorias diferentes: algo que você sabe (senha), tem (celular, chave de segurança) ou é (biometria). Duas senhas são um fator só, digitado duas vezes.

O TOTP (RFC 6238) é o código de seis dígitos do app autenticador: servidor e app compartilham um segredo, cadastrado pelo QR code, e calculam um HMAC sobre o número da janela de 30 segundos:

```python
import hashlib
import hmac
import struct

def totp(segredo: bytes, instante: int, digitos: int = 6, passo: int = 30) -> str:
    contador = struct.pack(">Q", instante // passo)
    mac = hmac.new(segredo, contador, hashlib.sha1).digest()
    deslocamento = mac[-1] & 0x0F
    numero = struct.unpack(">I", mac[deslocamento:deslocamento + 4])[0] & 0x7FFFFFFF
    return str(numero % 10**digitos).zfill(digitos)

# Segredo e instante do vetor de teste do RFC 6238 (o RFC dá 94287082 com 8 dígitos)
print(totp(b"12345678901234567890", 59))
```

```text
287082
```

O servidor guarda o segredo em forma recuperável (cifrado), já que precisa recalcular o HMAC, e registra a última janela aceita para impedir reuso. O SMS herda os defeitos da rede telefônica, como o SIM swap, em que alguém convence a operadora a transferir o número; o NIST SP 800-63B o classifica como autenticador restrito.

O defeito que TOTP, SMS e notificação push compartilham: **todos são phishable**. Um site falso que faz proxy em tempo real repassa a senha e o código ao site legítimo em menos de 30 segundos. O usuário digitou tudo certinho, no site errado.

### Passkeys, ou a credencial que confere o endereço

Passkeys são credenciais WebAuthn (W3C) com FIDO2. No cadastro, o autenticador (o celular, o computador, uma chave USB) gera um par de chaves exclusivo para aquele site. A chave pública vai para o servidor, junto com um ID de credencial. A privada fica no autenticador, num chip seguro ou sincronizada cifrada pelo gerenciador de senhas do sistema.

No login, o servidor manda um desafio aleatório. O navegador monta o `clientDataJSON`:

```json
{
  "type": "webauthn.get",
  "challenge": "q3V0aG9yLWdpbGJlcnRvLW5hby1lc3RhLWFxdWk",
  "origin": "https://app.violao.example",
  "crossOrigin": false
}
```

O autenticador assina o hash desse JSON mais os `authenticatorData` (hash do `rpId`, o domínio, e flags de presença e verificação do usuário). O servidor confere a assinatura, o desafio, a `origin` e o `rpId`.

A `origin` é preenchida pelo navegador, e a página nunca consegue alterá-la. Em `violao-login.example`, o navegador nem oferece a passkey de `app.violao.example`. Isso torna a passkey resistente a phishing por construção. E um vazamento do banco entrega ao atacante só chaves públicas, que servem para conferir assinaturas e para mais nada.

## Propriedades e custos

| | Sessão com cookie | Token opaco (bearer) | JWT de vida curta | JWT de vida longa |
|---|---|---|---|---|
| Validação | consulta ao armazenamento | consulta ou introspection | local, só criptografia | local, só criptografia |
| Custo por requisição | ~0,2 ms (Redis na mesma rede) | ~0,2 ms a vários ms | dezenas de µs (verificação RS256) | dezenas de µs |
| Revogação | imediata | imediata | até `exp` (minutos) | até `exp` (o caso Gilberto) |
| Tamanho | ~32 a 50 bytes | ~32 a 50 bytes | centenas de bytes a ~1 KB | idem |
| Exposição a CSRF | sim, mitigada por `SameSite` | não, se vier em cabeçalho | idem | idem |
| Estado no servidor | sim | sim | só o refresh | nenhum, e por isso o Gilberto continua dando aula |

A validação local pesa quando muitos serviços validam o mesmo token e uma consulta central em cada salto somaria latência e um ponto de falha. A revogação imediata pesa quando sair da empresa ou bloquear uma conta invadida precisa valer agora. O tamanho pesa porque o token viaja em toda requisição: 900 bytes em 2.000 requisições por segundo somam 1,8 MB/s só de cabeçalho.

Num app web com backend próprio, o *backend for frontend* (BFF) faz o fluxo OAuth, guarda os tokens e entrega ao navegador só um cookie de sessão `HttpOnly`. O JavaScript nunca toca num token, ao custo de mais um componente com estado.

Entre os segundos fatores, só a passkey resiste a phishing em tempo real. O custo é a recuperação de conta: quem perde todos os dispositivos precisa de outro caminho (e-mail, suporte, código de recuperação), e o atacante vai direto nele.

## Armadilhas e casos reais

> **Armadilha:** guardar access token em `localStorage`. Qualquer XSS lê o valor e o envia para outro servidor, onde ele continua válido até `exp`. Num cookie `HttpOnly`, o XSS ainda age em nome do usuário enquanto a aba estiver aberta, mas não leva a credencial para casa.

> **Armadilha:** identificar o usuário pelo `email` do ID token. Em 2023, a Descope publicou a falha que chamou de "nOAuth": no Microsoft Entra ID (então Azure AD), o atributo `email` podia ser editado pelo administrador do próprio tenant e não era verificado, e apps que faziam login pelo e-mail permitiam assumir a conta de outra pessoa. A chave estável é `(iss, sub)`.

> **Na vida real:** em 2015, Tim McLean publicou duas falhas em várias bibliotecas de JWT: aceitar `alg: none` e a confusão de algoritmos. Na segunda, a API esperava `RS256`, mas se o token dissesse `HS256`, a biblioteca usava a chave pública como segredo de HMAC. O atacante assinava o que quisesse com uma chave publicada para o mundo inteiro ler. A correção é a lista fixa de algoritmos do `validar` acima.

> **Na vida real:** em abril de 2022, Neil Madden publicou a CVE-2022-21449 ("Psychic Signatures") no Java 15 a 18: a verificação ECDSA aceitava assinatura com `r = 0` e `s = 0` para qualquer mensagem e qualquer chave. Um JWT `ES256` com assinatura toda de zeros passava. A matemática do ECDSA proíbe esses valores; o código esqueceu de perguntar.

> **Na vida real:** em setembro de 2022, a Uber relatou uma invasão em que o atacante, com a senha de um prestador de serviço, disparou notificações de MFA por push até uma ser aprovada (*MFA fatigue*). A mitigação é o *number matching*: o app exige o número exibido na tela de login, e aprovar sem olhar deixa de funcionar.

> **Na vida real:** em julho de 2023, a Microsoft divulgou que o grupo que ela chamou de Storm-0558 obteve uma chave de assinatura de contas pessoais (MSA) e forjou tokens que o Exchange Online aceitou para contas corporativas de cerca de 25 organizações, por uma falha na validação. A assinatura era legítima; o erro estava em qual chave podia assinar para qual audiência.

## Resumo

- Sessão com cookie guarda estado no servidor e revoga na hora; `HttpOnly`, `Secure`, `SameSite` e `__Host-` fazem boa parte da segurança.
- Bearer token vale para quem o apresenta. JWT é base64url assinado, legível por todos, validado localmente com lista fixa de algoritmos, e só morre em `exp`.
- Revogar JWT exige estado: vida curta + refresh rotacionado, lista de `jti` ou geração por usuário.
- OAuth 2.0 é delegação: authorization code com PKCE, `state` e `redirect_uri` exato (RFC 9700).
- OIDC acrescenta o ID token, que é para o cliente. Identidade estável é `(iss, sub)`.
- TOTP, SMS e push são phishable; passkeys assinam a origem e resistem a phishing por construção.
- O Gilberto só parou de dar aula quando a chave de assinatura foi rotacionada, derrubando junto o login de todos os outros usuários.

## Referências

- RFC 6265, HTTP State Management Mechanism: <https://www.rfc-editor.org/rfc/rfc6265>
- RFC 6749, The OAuth 2.0 Authorization Framework: <https://www.rfc-editor.org/rfc/rfc6749>
- RFC 6750, OAuth 2.0 Bearer Token Usage: <https://www.rfc-editor.org/rfc/rfc6750>
- RFC 7515, JSON Web Signature: <https://www.rfc-editor.org/rfc/rfc7515>
- RFC 7517, JSON Web Key: <https://www.rfc-editor.org/rfc/rfc7517>
- RFC 7519, JSON Web Token: <https://www.rfc-editor.org/rfc/rfc7519>
- RFC 7636, Proof Key for Code Exchange (PKCE): <https://www.rfc-editor.org/rfc/rfc7636>
- RFC 7662, OAuth 2.0 Token Introspection: <https://www.rfc-editor.org/rfc/rfc7662>
- RFC 8628, OAuth 2.0 Device Authorization Grant: <https://www.rfc-editor.org/rfc/rfc8628>
- RFC 8725, JSON Web Token Best Current Practices: <https://www.rfc-editor.org/rfc/rfc8725>
- RFC 9700, Best Current Practice for OAuth 2.0 Security: <https://www.rfc-editor.org/rfc/rfc9700>
- RFC 6238, TOTP: Time-Based One-Time Password Algorithm: <https://www.rfc-editor.org/rfc/rfc6238>
- OpenID Connect Core 1.0: <https://openid.net/specs/openid-connect-core-1_0.html>
- W3C, Web Authentication Level 2: <https://www.w3.org/TR/webauthn-2/>
- NIST SP 800-63B, Digital Identity Guidelines, Authentication: <https://pages.nist.gov/800-63-3/sp800-63b.html>
- OWASP Session Management Cheat Sheet: <https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html>
- PyJWT, documentação: <https://pyjwt.readthedocs.io/>
- Tim McLean, Critical vulnerabilities in JSON Web Token libraries (2015): <https://auth0.com/blog/critical-vulnerabilities-in-json-web-token-libraries/>
- Neil Madden, Psychic Signatures in Java (2022): <https://neilmadden.blog/2022/04/19/psychic-signatures-in-java/>
- Uber, Security update (2022): <https://www.uber.com/newsroom/security-update/>
- Microsoft, Microsoft mitigates China-based threat actor Storm-0558 targeting of customer email (2023): <https://msrc.microsoft.com/blog/2023/07/microsoft-mitigates-china-based-threat-actor-storm-0558-targeting-of-customer-email/>
