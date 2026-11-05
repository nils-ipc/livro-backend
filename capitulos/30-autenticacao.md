# Autenticação

No sábado às 3h41, a Lastro recebeu a requisição mais educada da sua história, com chave de API válida, `Idempotency-Key` gerada fora do laço e retry com full jitter, e ela vinha de um ladrão.

A chave era a do Bazar, publicada na quinta às 18h no repositório de exemplo da consultoria Java. Em 33 horas, alguém achou a chave e leu a documentação da Lastro com mais atenção que a própria consultoria. Às 3h41, listou dois anos de cobranças. Às 3h44, cadastrou uma inscrição de webhook apontando para um servidor dele, que passou a receber cada cobrança nova com nome e CPF do comprador. Às 3h52, trocou a chave Pix de repasse de 18 vendedores e pediu um saque para cada um.

O limite do gerente para chave Pix cadastrada há menos de 24 h (capítulo 3), R$ 500,00 por dia, segurou o resto: saíram R$ 9.000,00 de R$ 212.400,00 pedidos. O rate limiting do capítulo 28 não viu nada, porque o ladrão respeitou os limites do Bazar com uma disciplina que o Bazar nunca teve. O Bazar abriu chamado às 9h12: "URGENTE!!!! vendedores dizendo que a chave Pix mudou sozinha". O vendedor 42 estava entre os 18 e jurou que dessa vez nem ele sabia.

Às 9h30, o Carlos gerou uma chave nova para o Bazar. A antiga parou na hora, e a integração do Bazar também: a chave estava em 14 servidores que só a consultoria sabia mexer. Foram 1h50 sem cobranças do Bazar, faturadas pela consultoria em 6 horas.

A Lastro autenticava cada requisição. Por que isso não protegeu nada, e o que muda quando a credencial vaza, como toda credencial um dia vaza?

## Quem é você, e por que o servidor acredita

**Autenticação** é estabelecer quem fez a requisição; **autorização**, o que esse alguém pode fazer, é o capítulo 31. A autenticação se apoia em fatores: algo que você sabe (senha), algo que você tem (chave privada, celular) e algo que você é (biometria, que no WebAuthn só destrava uma chave local e nunca sai do aparelho).

A distinção que mais pesa no backend é sobre a credencial que viaja. Uma credencial **ao portador** (*bearer*) autentica quem a apresenta: chave de API, cookie de sessão, access token comum. Quem copia, vira você. Uma credencial com **prova de posse** obriga o cliente a provar, a cada uso, que tem uma chave privada que nunca trafega: mTLS (capítulo 10), DPoP (RFC 9449), WebAuthn. Copiar o que passou no fio não serve para nada.

A chave do Bazar era ao portador, sem prazo, sem escopo e única. Quem leu o GitHub virou o Bazar, com todos os direitos, inclusive o de derrubar o Bazar.

## Sessão com cookie, a tecnologia que ninguém acha moderna e quase todo mundo deveria usar

No login, o servidor gera um identificador aleatório de pelo menos 128 bits, guarda no banco ou no Redis a linha `(sessao_id, usuario, criada_em, ultimo_uso)` e devolve o identificador num cookie. Cada requisição traz o cookie, o servidor busca a linha, e o usuário está autenticado.

Os atributos do cookie fazem metade da segurança. `HttpOnly` esconde o cookie do JavaScript, e um XSS não consegue lê-lo. `Secure` só manda por HTTPS. `SameSite=Lax` ou `Strict` impede o navegador de mandá-lo em requisições disparadas por outro site, a defesa principal contra CSRF. O prefixo `__Host-` obriga `Secure`, `Path=/` e nenhum `Domain`, e um subdomínio comprometido não consegue sobrescrevê-lo.

Revogar é apagar a linha. Logout, troca de senha, "sair de todos os aparelhos": um `DELETE`, a única vez na carreira em que um `DELETE` em produção é a coisa certa, e mesmo assim o Carlos pediu dois aprovadores. O custo é uma consulta por requisição, que um Redis responde em menos de um milissegundo.

## Tokens opacos e JWT, ou onde mora a verdade

Um **token opaco** é uma string aleatória sem significado, como o ID de sessão, que o servidor consulta numa tabela ou num endpoint de introspecção (RFC 7662). Revogação imediata; uma consulta por uso.

Um **JWT** (RFC 7519) carrega os dados dentro dele, assinado. São três partes em base64url separadas por ponto: cabeçalho, payload e assinatura (JWS, RFC 7515). Decodificado:

```text
cabeçalho   {"alg":"ES256","typ":"JWT","kid":"2026-11"}
payload     {"iss":"https://auth.lastro.com.br","sub":"mkt_tuiuiu",
             "aud":"https://api.lastro.com.br","scope":"cobrancas:escrita",
             "iat":1793000000,"exp":1793000600,"jti":"tok_01JC8..."}
assinatura  ECDSA P-256 sobre base64url(cabeçalho) + "." + base64url(payload)
```

Quem valida confere a assinatura com a chave pública do emissor (publicada num JWKS, escolhida pelo `kid`) e checa `exp`, `nbf`, `iss` e `aud` sem consultar ninguém. Esse é o ganho: validação local, sem estado, em qualquer réplica. O payload é só codificado, não cifrado: qualquer um lê. JWT guarda identidade e permissões, nunca segredo, e quem põe CPF no payload publica CPF com assinatura digital.

O `alg` decide o modelo de chave. HS256 é HMAC com segredo compartilhado: quem valida também consegue emitir, então serve só quando emissor e validador são o mesmo sistema. ES256, EdDSA e RS256 são assinaturas assimétricas: o validador tem só a chave pública e não forja nada.

O preço da validação local é a revogação. Um JWT assinado vale até o `exp`, e o servidor que não consulta nada não tem como saber que ele foi roubado. As saídas: prazo curto (5 a 15 minutos) com um **refresh token** opaco, guardado no servidor, que renova o access token e pode ser revogado; rotação do refresh token a cada uso, com detecção de reuso (se o antigo aparecer de novo, alguém copiou, e a família inteira é revogada); e, para emergência, uma lista de `jti` ou de `sub` bloqueados, consultada pelo validador. A lista reintroduz estado, só que pequeno e só para os condenados. JWT de 30 dias sem lista é a credencial que o próprio dono não consegue cassar, a estabilidade de servidor público em formato base64.

## OAuth 2.0 e OpenID Connect

O **OAuth 2.0** (RFC 6749) é um protocolo de delegação: um **cliente** obtém de um **servidor de autorização** um access token para chamar um **servidor de recursos**, em nome de um **dono do recurso** ou de si mesmo. Ele define como o token é obtido, e quase nada do formato do token. Os fluxos atuais, consolidados na RFC 9700 (o BCP de segurança do OAuth, de janeiro de 2025):

- **Authorization code com PKCE:** para usuário num navegador ou app. O usuário se autentica no servidor de autorização, que devolve ao cliente um código de uso único, trocado por tokens num canal direto.
- **Client credentials:** máquina falando com máquina, sem usuário. O cliente se autentica no endpoint de token e recebe um access token.
- **Device authorization** (RFC 8628): aparelho sem teclado; o usuário aprova em outro.

O fluxo implícito (token na URL de retorno) e o de senha (cliente recebe a senha do usuário) estão descontinuados pela RFC 9700: o primeiro vaza token em histórico e log; o segundo treina o usuário a digitar a senha em qualquer formulário que peça com educação.

O **PKCE** (RFC 7636) amarra o código a quem o pediu:

```text
code_verifier   = 43 a 128 caracteres aleatórios, fica no cliente
code_challenge  = BASE64URL(SHA-256(code_verifier)), vai no pedido de autorização
troca do código = código + code_verifier; o servidor recalcula o hash e compara
```

Quem intercepta o código no redirecionamento não tem o `code_verifier` e não troca nada. A RFC 9700 exige PKCE de clientes públicos e o recomenda também aos que têm segredo.

No client credentials, o cliente pode se autenticar com segredo compartilhado (`client_secret`, ao portador), com um JWT assinado pela própria chave privada (`private_key_jwt`, RFC 7523) ou com certificado (mTLS, RFC 8705). A RFC 8705 ainda permite amarrar o access token ao certificado: o servidor de recursos recusa o token se a conexão não vier com o mesmo certificado. Token roubado sem a chave privada vira papel de parede.

O **OpenID Connect** (OIDC) é uma camada de autenticação sobre o OAuth. O OAuth diz "este cliente pode ler as cobranças"; o OIDC diz "quem está no navegador é a Maria, autenticada às 9h02 com MFA". Ele acrescenta o **ID token**, um JWT para o cliente (`aud` = cliente) com `sub`, `auth_time`, `amr` e `nonce` (contra replay), e a descoberta em `/.well-known/openid-configuration`. Access token vai para a API; ID token fica com o cliente. Inverter os dois é a confusão mais popular da área e já rendeu login com o token de outro aplicativo.

## MFA e passkeys, ou como parar de confiar na memória humana

Senha é um segredo que o usuário escolhe mal, repete em vinte sites e digita em qualquer página parecida com a certa. O armazenamento correto (Argon2id) é do capítulo 33. O resto do problema se resolve com um segundo fator.

**TOTP** (RFC 6238) gera o código com `HMAC(segredo, ⌊tempo / 30 s⌋)` truncado em 6 dígitos, a partir de um segredo compartilhado no QR code do cadastro. Funciona sem rede e tem um defeito estrutural: uma página falsa pede o código e o repassa ao site legítimo em segundos. **SMS** soma a isso a troca fraudulenta de chip (*SIM swap*). **Push** soma a fadiga: mande quarenta notificações às 2h e alguém aprova uma só para dormir.

As **passkeys** são credenciais WebAuthn (W3C) com FIDO2: no cadastro, o autenticador (celular, notebook, chave física) gera um par de chaves para aquele site, guarda a privada e entrega a pública ao servidor, que a armazena com o ID da credencial. No login, o servidor manda um desafio aleatório; o autenticador, depois de verificar o usuário (biometria ou PIN, local), assina o desafio junto com a **origem** que o navegador informa. O servidor confere assinatura, desafio e origem.

A origem é o ponto. O navegador escreve a origem real nos dados assinados, e a credencial de `lastro.com.br` não assina nada para `lastro-login.com.br`. O phishing deixa de funcionar por construção, sem depender de o usuário ler a barra de endereço às 23h. O servidor não guarda segredo nenhum: quem rouba a tabela de chaves públicas leva uma coleção de cadeados, sem nenhuma chave.

## As credenciais dos marketplaces

As opções para máquina falando com a API:

| Credencial | Revogação | Se vazar | Custo |
|---|---|---|---|
| Chave de API estática | Consulta por requisição | Vale até alguém notar | Mínimo |
| Client credentials + `client_secret` | Token curto; segredo revogável | Ladrão emite tokens até a revogação | Endpoint de token |
| Client credentials + `private_key_jwt` | Idem; chave pública removível | Nada trafega para ser copiado | Cliente assina JWT |
| mTLS com token amarrado (RFC 8705) | Certificado e token | Token inútil sem a chave | Operar certificados |

A Lastro fica com duas, por versão da API, porque o `/v1` não pode quebrar clientes (capítulo 11).

No **`/v1`**, a chave continua e muda de natureza. O formato passa a ser reconhecível por máquina:

```text
lastro_live_  +  43 caracteres base62 (256 bits aleatórios)  +  _  +  CRC32 em base62
└─ prefixo ─┘                                                       └─ checksum ─┘
```

O prefixo e o checksum servem aos programas de varredura de segredos (o *secret scanning* do GitHub é um exemplo): a Lastro cadastra o padrão, e uma chave publicada gera aviso em minutos, com a confirmação local pelo checksum filtrando falso positivo. Aviso de chave `live` revoga automaticamente e manda e-mail ao marketplace. Revogar derruba a integração, mas a chave pública já é do ladrão, e 33 horas foi quanto o Bazar demorou sem aviso.

A chave é mostrada uma vez e guardada só como SHA-256. Para 256 bits aleatórios, um hash rápido basta: não há dicionário para atacar, e o Argon2 do capítulo 33 serve para segredo de baixa entropia, como senha. Cada marketplace pode ter **duas chaves ativas**, com data de último uso: gera a nova, troca nos servidores, revoga a antiga quando o último uso dela parar. A rotação de sábado teria sido sem queda.

Cada chave tem **escopos**. A padrão não inclui `repasses:escrita` nem `webhooks:escrita`, as duas operações que o ladrão usou; trocar chave Pix de repasse e cadastrar inscrição de webhook exigem uma chave separada, que pode ser restrita a IPs de origem, e geram e-mail ao marketplace e ao vendedor afetado. O gateway, que já identificava o marketplace pela credencial (capítulo 28), mantém em memória o hash das ~200 chaves ativas e recebe revogações por notificação: chave revogada morre nos gateways em segundos.

No **`/v2`**, a credencial é OAuth client credentials em `auth.lastro.com.br/token`, com `private_key_jwt` ou mTLS, e nenhum segredo compartilhado. O access token é o JWT acima: ES256, `aud` da API, escopos, 10 minutos. O gateway valida localmente pelo JWKS, sem consulta por requisição, o que pesa a 6.840 requisições por segundo com o Tuiuiú (capítulo 29). Revogação de emergência: o cliente desativado não obtém token novo, e o `sub` entra numa lista no gateway até o último `exp`. O Tuiuiú entra direto no `/v2` com mTLS e tokens amarrados ao certificado, porque o contrato dele exige credencial que não possa ser copiada de um repositório. O `/v2` com chave estática seria a escolha certa só para clientes sem capacidade de assinar um JWT, e ainda não apareceu nenhum.

O token curto do checkout (capítulo 9) vira um JWT com `aud` do checkout, escopo de leitura de uma única cobrança e `exp` igual à expiração do QR code. Vazou? Mostra o status de um Pix por meia hora.

## O painel dos vendedores

O painel usava e-mail, senha e um cookie de sessão sem prazo. O vendedor 42 tinha a mesma senha no painel e no fórum de capinhas.

A sessão continua no servidor, em Redis, com cookie `__Host-sessao`, `HttpOnly`, `Secure`, `SameSite=Lax`, ociosidade de 30 minutos e prazo absoluto de 12 horas. JWT no `localStorage` foi descartado: qualquer XSS o lê, e revogar exigiria a lista de bloqueio, que é uma sessão no servidor com passos extras. Login com **passkey** como opção principal, TOTP como alternativa, e segundo fator obrigatório. SMS não entra.

As operações que movem dinheiro pedem **reautenticação recente**: trocar chave Pix de repasse ou sacar acima de R$ 1.000,00 exige passkey ou TOTP nos últimos 5 minutos, mesmo com sessão válida. Troca de senha, de chave Pix ou de fator apaga todas as sessões do vendedor. Os usuários dos marketplaces entram no painel deles por OIDC com o provedor de identidade do próprio marketplace, exigência do Tuiuiú, e o `amr` do ID token tem que mostrar MFA.

## Armadilhas e casos reais

> **Na vida real:** em 2015, Tim McLean mostrou que várias bibliotecas de JWT aceitavam `"alg": "none"` (token sem assinatura) e que outras, configuradas com chave pública RSA, aceitavam um token HS256 assinado usando essa chave pública como segredo HMAC. A biblioteca deixava o token escolher o algoritmo pelo qual seria validado: o réu escolhia o juiz. A defesa é fixar o algoritmo esperado na validação.

Não validar `aud`. Um token emitido para o serviço de relatórios, aceito pelo de pagamentos, transforma uma credencial de leitura em credencial de tudo. Todo validador confere `iss`, `aud`, `exp` e o algoritmo.

Comparar segredo com `==`. A comparação de strings para no primeiro byte diferente e vaza o prefixo pelo tempo de resposta. `hmac.compare_digest` compara em tempo constante; comparar hashes também resolve.

Logar o cabeçalho `Authorization`. O log vira um repositório público com controle de acesso pior que o GitHub (capítulo 38).

Fadiga de MFA. Em setembro de 2022, a Uber relatou que o invasor obteve a senha de um terceirizado e mandou pedidos de aprovação repetidos até um ser aceito. Push sem número para conferir é um botão "deixa entrar" com vibração.

Segredo em repositório. Em outubro de 2022, a Toyota informou que um terceirizado tinha publicado no GitHub, em dezembro de 2017, código com uma chave de acesso a um servidor de dados do T-Connect, exposta por quase cinco anos, com até 296.019 e-mails de clientes. O estudo "How Bad Can It Git?" (NDSS 2019) achou segredos vazando em mais de 100 mil repositórios públicos, com milhares de segredos novos por dia. A defesa que escala é a credencial que avisa quando vaza, e a que não vale nada fora da máquina dona.

## Resumo

- Autenticação estabelece quem; autorização, o que pode (cap. 31). Credencial ao portador vale para quem a copia; prova de posse exige chave privada que não trafega.
- Sessão no servidor: ID aleatório, cookie `HttpOnly`, `Secure`, `SameSite`, `__Host-`; revogação imediata.
- JWT: assinado, legível, validado localmente; `alg` fixo, `aud`, `exp`; revogação por prazo curto, refresh token rotativo e lista de bloqueio.
- OAuth 2.0: authorization code com PKCE, client credentials, device; implícito e senha descontinuados (RFC 9700). `private_key_jwt` e mTLS dispensam segredo compartilhado. OIDC acrescenta o ID token.
- TOTP e SMS são phishable; passkeys (WebAuthn) assinam a origem e resistem a phishing.
- Chave de API: prefixo e checksum para varredura, hash, duas ativas para rotação, escopos.

## A Lastro agora

O `/v1` tem chaves `lastro_live_` com checksum, cadastradas em varredura de segredos, guardadas como hash, duas por marketplace e com escopos que separam repasses e webhooks; o `/v2` usa client credentials com `private_key_jwt` ou mTLS e JWT de 10 minutos validado no gateway, e o Tuiuiú entra assim. O painel tem sessão no servidor, passkey ou TOTP obrigatórios e reautenticação para mover dinheiro. O Bazar ganhou a segunda chave e, pela primeira vez, trocou uma sem abrir chamado. A consultoria cobrou 12 horas para aprender a usar duas chaves.

Na segunda, a analista do Hornero, devidamente autenticada com passkey e MFA, abriu uma cobrança no painel, trocou um caractere do ID na URL por curiosidade e viu uma cobrança do Bazar, com o nome do comprador. A Lastro agora sabe exatamente quem ela é. Só não perguntou o que ela pode ver.

## Referências

- RFC 6749, The OAuth 2.0 Authorization Framework: https://www.rfc-editor.org/rfc/rfc6749
- RFC 9700, Best Current Practice for OAuth 2.0 Security: https://www.rfc-editor.org/rfc/rfc9700
- RFC 7636, Proof Key for Code Exchange (PKCE): https://www.rfc-editor.org/rfc/rfc7636
- RFC 7519, JSON Web Token: https://www.rfc-editor.org/rfc/rfc7519
- RFC 7515, JSON Web Signature: https://www.rfc-editor.org/rfc/rfc7515
- RFC 7523, JWT Profile for OAuth 2.0 Client Authentication: https://www.rfc-editor.org/rfc/rfc7523
- RFC 8705, OAuth 2.0 Mutual-TLS Client Authentication and Certificate-Bound Access Tokens: https://www.rfc-editor.org/rfc/rfc8705
- RFC 9449, OAuth 2.0 Demonstrating Proof of Possession (DPoP): https://www.rfc-editor.org/rfc/rfc9449
- RFC 7662, OAuth 2.0 Token Introspection: https://www.rfc-editor.org/rfc/rfc7662
- RFC 8628, OAuth 2.0 Device Authorization Grant: https://www.rfc-editor.org/rfc/rfc8628
- RFC 6238, TOTP: https://www.rfc-editor.org/rfc/rfc6238
- OpenID Connect Core 1.0: https://openid.net/specs/openid-connect-core-1_0.html
- W3C, Web Authentication Level 3: https://www.w3.org/TR/webauthn-3/
- GitHub Docs, Secret scanning partner program: https://docs.github.com/en/code-security/secret-scanning/secret-scanning-partnership-program/secret-scanning-partner-program
- Michael Meli, Matthew R. McNiece, Bradley Reaves, "How Bad Can It Git? Characterizing Secret Leakage in Public GitHub Repositories", NDSS 2019.
- Tim McLean, "Critical vulnerabilities in JSON Web Token libraries", Auth0, 2015.
