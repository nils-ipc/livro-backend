# Resumo 10 — TLS e certificados

## A Lastro ao fim do capítulo
- incidente domingo 03h12 (06h12 GMT): cert 1 ano comprado à mão pelo fundador (sábado, CA comercial), Uvicorn `--ssl-certfile`; Carlos copiou cert + chave p/ api-01 → ambas caem juntas; 2h35 fora, 214 cobranças não criadas, 61 Pix sem notificação (banco desistiu após 3 tentativas), financeiro conciliou à mão; Carlos 05h47 Let's Encrypt manual copiado de novo
- proxy reverso por máquina (nginx/Caddy exemplos) :443 → Uvicorn `127.0.0.1:8000`; `X-Forwarded-*` só de 127.0.0.1; TLS 1.3 + 1.2 (só ECDHE/AEAD, 1 marketplace em 1.2); 1.0/1.1 off; `h2` p/ marketplaces via ALPN
- ACME DNS-01 (HTTP-01 não alcança temp-01), chave própria por máquina, ECDSA P-256, 90 dias, renova aos 60; `_acme-challenge` CNAME → zona `desafios-acme.lastro.com.br` (credencial só ali); CAA letsencrypt.org + pki.goog + iodef
- verificador externo diário do cert servido nos 2 IPs, alerta < 21 dias; monitor CT p/ `lastro.com.br`
- mTLS banco parceiro (exigência por ofício, 60 dias): cert cliente CA privada do banco, 1 ano, 1 por máquina (api-01; temp-01 p/ repasse job), chave `0600`, renovação manual, alertas 60/30/14, sobreposição
- notificações Pix → `webhooks-pix.lastro.com.br` (SNI, mesmo IP, SAN do cert api-01), exige cert cliente CA do banco; proxy repassa subject e apaga cabeçalho externo
- balanceador gerenciado → cap. 27; mTLS marketplaces → cap. 30; KMS → cap. 33
- próximo: gerente adiciona `parcelas_detalhe` ("é só um campo"); desserializador estrito do Bazar quebra (cap. 11)

## Conceitos aprofundados aqui
- TLS: confidencialidade, integridade, autenticação; AEAD, 5 suites 1.3
- handshake 1.3, ECDHE, HelloRetryRequest, CertificateVerify, Finished, forward secrecy, 0-RTT replay
- X.509: SAN, validade UTC, basicConstraints, EKU; curinga 1 nível
- cadeia, trust store, intermediária enviada; CA/B 200/100/47 dias (2026/27/29)
- CRL, OCSP soft-fail; CT; CAA
- SNI, ALPN; 4 arranjos de terminação; X-Forwarded
- ACME: HTTP-01, DNS-01, TLS-ALPN-01, ARI
- mTLS

## Casos reais usados
- Ericsson SGSN-MME 6/12/2018 (O2 ~30 mi, 11 países); DST Root CA X3 30/9/2021 (OpenSSL 1.0.x); Let's Encrypt fim OCSP ago/2025

## Piadas recorrentes
- fundador: "no meu tempo durava três anos"; cert antigo em pendrive "backup"
- Carlos: `verify=False` no script de reenvio, "em revisão, com o Carlos dentro"
- financeiro "calma de quem já não sente nada"; fintech sem saber = cofrinho
- vendedor 42 ofendido por não ser consultado sobre 0-RTT
