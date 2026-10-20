# Resumo 03 — TLS e certificados

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- TLS 1.3 RFC 8446; 1.0/1.1 aposentados RFC 8996
- handshake 1 RTT: ClientHello (key_share, SNI, ALPN), ServerHello, Certificate, CertificateVerify (assina transcrição), Finished (HMAC); HelloRetryRequest +1 RTT; session resumption/PSK
- ECDHE X25519, HKDF, forward secrecy; RSA key exchange removido; 3 suites AEAD usuais; híbrido X25519MLKEM768 (FIPS 203)
- X.509 RFC 5280: SAN (CN ignorado), curinga 1 nível, cadeia leaf→intermediária→raiz; trust store sistema vs certifi
- intermediária ausente: navegador OK (AIA), Python/curl falham
- CT RFC 6962, CAA RFC 8659, revogação soft-fail; LE sem OCSP 2025
- SC-081: 200 dias (15/03/2026), 100 (2027), 47 (2029)
- SNI RFC 6066, ECH
- terminação/reencriptação/passthrough; X-Forwarded-Proto só do proxy; Uvicorn --proxy-headers
- ACME RFC 8555: HTTP-01, DNS-01 (curinga), TLS-ALPN-01; LE 90 dias, renova 1/3; sem e-mails desde jun/2025
- mTLS: CertificateRequest, CA interna, SPIFFE, X-Forwarded-Client-Cert; erro TLSV13_ALERT_CERTIFICATE_REQUIRED na 1ª leitura

## Termos e traduções adotados
- trust store, leaf, forward secrecy, pinning em inglês
- termination → terminação TLS

## Casos reais e exemplos usados (não repetir)
- hipotético: certificado expirado sábado 3h12, planilha `certificados_FINAL_v3.xlsx`
- monitor Python de expiração; `verify=False` TODO 2019; crash loop esgota limite LE
- Ericsson SGSN-MME 6/12/2018 (O2, SoftBank)
- DST Root CA X3 30/09/2021
