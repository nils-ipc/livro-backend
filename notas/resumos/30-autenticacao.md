# Resumo 30 — Autenticação

## A Lastro ao fim do capítulo
- incidente: chave API produção Bazar (estática, ao portador, sem escopo/prazo, única) publicada quinta 18h no repositório exemplo da consultoria Java; sábado 3h41 ladrão listou 2 anos de cobranças, 3h44 inscrição webhook p/ servidor dele (nome + CPF comprador), 3h52 trocou chave Pix repasse de 18 vendedores + saques; limite chave Pix < 24 h (cap. 3) = R$ 500,00/dia → saíram R$ 9.000,00 de R$ 212.400,00; rate limit cap. 28 não viu; URGENTE 9h12; vendedor 42 entre os 18; Carlos regenerou chave 9h30 → Bazar 1h50 sem cobranças (14 servidores), consultoria faturou 6 h
- `/v1`: chave formato `lastro_live_` + 256 bits base62 + `_` + CRC32 → varredura de segredos (GitHub secret scanning ex.); aviso = revogação automática + e-mail; guardada SHA-256 (alta entropia), mostrada 1×; 2 ativas por marketplace + último uso (rotação sem queda); escopos: padrão sem `repasses:escrita`/`webhooks:escrita`, chave separada, IP opcional, e-mail ao marketplace e vendedor; gateway hash ~200 chaves em memória, revogação por notificação em segundos
- `/v2`: OAuth client credentials `auth.lastro.com.br/token`, `private_key_jwt` (RFC 7523) ou mTLS (RFC 8705); access token JWT ES256, `aud` API, escopos, 10 min, validado no gateway via JWKS; emergência: cliente desativado + `sub` em lista até último `exp`
- Tuiuiú: `/v2` + mTLS + token amarrado ao certificado (contrato)
- checkout: JWT `aud` checkout, leitura de 1 cobrança, `exp` = expiração QR
- painel vendedores: sessão servidor Redis, `__Host-sessao` HttpOnly Secure SameSite=Lax, ociosa 30 min, absoluta 12 h; passkey principal, TOTP alternativa, 2º fator obrigatório, sem SMS; reautenticação ≤ 5 min p/ trocar chave Pix ou saque > R$ 1.000,00; troca senha/chave Pix/fator apaga sessões; senha Argon2id → cap. 33
- painel marketplaces: OIDC com IdP do marketplace (exigência Tuiuiú), `amr` com MFA
- próximo: analista Hornero troca 1 caractere do ID na URL do painel e vê cobrança do Bazar (cap. 31)

## Conceitos aprofundados aqui
- autenticação × autorização; fatores; ao portador × prova de posse (mTLS, DPoP, WebAuthn)
- sessão cookie: ID ≥ 128 bits, HttpOnly/Secure/SameSite/`__Host-`, CSRF, revogação DELETE
- opaco/introspecção (RFC 7662); JWT/JWS estrutura, claims, HS256 × ES256/EdDSA/RS256, payload legível; revogação: prazo curto, refresh rotativo com detecção de reuso, lista `jti`/`sub`
- OAuth 2.0 papéis, fluxos, implícito/senha descontinuados (RFC 9700), PKCE S256, autenticação cliente; OIDC ID token, `nonce`, `amr`, discovery
- TOTP, SMS SIM swap, fadiga push; passkeys WebAuthn/FIDO2, origem assinada

## Casos reais usados
- McLean 2015 `alg: none` e confusão HS256/RS256; Uber set/2022 fadiga MFA; Toyota T-Connect out/2022 (2017–2022, 296.019 e-mails); NDSS 2019 "How Bad Can It Git?" (>100 mil repositórios)

## Piadas recorrentes
- ladrão mais educado que o Bazar (Idempotency-Key, jitter)
- vendedor 42 vítima "dessa vez nem eu"; mesma senha no fórum de capinhas
- consultoria: 6 h + 12 h para "aprender duas chaves"
- Carlos: DELETE certo, pediu 2 aprovadores
- JWT 30 dias = "estabilidade de servidor público"; alg none "réu escolhe o juiz"
