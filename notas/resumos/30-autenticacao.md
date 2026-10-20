# Resumo 30 — Autenticação

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- autenticação = quem; autorização → cap. 31; hash de senha → cap. 33
- 2 fases: prova de identidade + credencial derivada
- sessão: id ≥128 bits `secrets`, armazenamento compartilhado, logout imediato, ~0,2 ms Redis
- cookie RFC 6265: HttpOnly, Secure, SameSite=Lax (CSRF), prefixo `__Host-`
- bearer RFC 6750; opaco + introspection RFC 7662; JWT RFC 7519/JWS 7515/JWK 7517, BCP RFC 8725
- claims iss/sub/aud/iat/exp/jti; HS256 vs RS256/ES256, JWKS, kid; base64url legível
- PyJWT `algorithms` fixo; `alg: none` → InvalidAlgorithmError
- revogação: vida curta 5–15 min + refresh, lista `jti` com TTL, geração por usuário; rotação de refresh + revoga família (RFC 9700)
- OAuth 2.0 RFC 6749: authorization code + PKCE RFC 7636 (S256, verificador 43–128), state, redirect_uri exato; client credentials; device RFC 8628; implícito e password desaconselhados, fora OAuth 2.1
- OIDC: ID token para cliente (aud = client_id), nonce, discovery; identidade = (iss, sub)
- MFA: TOTP RFC 6238 (HMAC-SHA1, 30 s), SMS restrito NIST 800-63B; TOTP/SMS/push phishable
- passkeys WebAuthn: par por site, clientDataJSON origin/challenge, rpId, resistentes a phishing; BFF

## Termos e traduções adotados
- payload → carga; bearer → portador; refresh token, access token, ID token, introspection, MFA fatigue, number matching, BFF em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: plataforma de violão, Gilberto saiu em março, JWT 365 dias, "Asa Branca parte 14", sub u-1984
- vetores RFC 7636 (E9Melhoa…) e RFC 6238 (287082)
- McLean 2015 (none, RS256/HS256); CVE-2022-21449 Psychic Signatures; Uber set/2022 MFA fatigue; Storm-0558 jul/2023; nOAuth Descope 2023
