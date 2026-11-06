# Resumo 33 — Criptografia aplicada e segredos

## A Lastro ao fim do capítulo
- incidente: `logger.debug(corpo)` no `conector-adquirente` desde BF → 318 mil autorizações, 204 mil cartões (PAN, validade, nome; CVV cortado por sorte) em bucket lido por todas as máquinas; escopo PCI DSS ≈ Lastro inteira, temp-01 incluído; limpeza: versões antigas do bucket versionado, índice coletor, backup semanal; resposta via adquirente
- requisito novo (contrato Tuiuiú): cartão salvo (1 clique) + cartões sobrevivem a troca de adquirente
- decisão: cofre próprio (descartados repassar sem guardar, token do adquirente, cofre terceiro +20–40 ms na folga 120 ms a 360 aut./s)
- iframe `cofre.lastro.com.br`, entrada/TLS próprios → token `tok_` + 128 bits aleatórios; gateway, pagamentos, broker, logs, temp-01 só veem token
- segmento de dados de cartão: entrada do cofre, cofre ×3, `pg-cofre`, `conector-adquirente` (máquinas próprias; detokeniza por autorização, +2 ms); rede → cap. 36
- `pg-cofre`: PAN+validade AES-256-GCM, token no AAD, DEK cifrada, BIN, 4 últimos, `marketplace_id` RLS; DEK por processo por hora (~1,3 mi cifragens), DEK em claro 5 min memória; KEK no KMS, rotação anual
- CVV: Redis exclusivo do cofre sem persistência, cifrado, 10 min, apagado na autorização
- HMAC PAN: impressão (cartão já salvo) + identificador antifraude (cap. 25), chaves separadas; antifraude rotação anual, 24 h em paralelo
- webhooks: `Lastro-Assinatura: t=...,v1=<hex>`, HMAC-SHA256 `t.corpo bruto`, segredo por inscrição `lastro_whsec_`, 5 min, 2 `v1` na rotação
- senhas painel: Argon2id m 64 MiB, t 3, p 4, ~50 ms, semáforo 4/processo
- segredos: gerenciador (identidade da máquina), senhas bancos pares A/B, 30 dias; `/root/senhas.txt` fundador (adquirente, DNS, chave nuvem 2019) rotacionado
- logs: mascaramento + detector Luhn + BIN (cap. 38)
- próximo: Carlos faz 1º contêiner (conector) com shell que não repassa SIGTERM → `docker stop` SIGKILL em 31 autorizações; painel OOM sem log (3 workers × 4 Argon2id × 64 MiB > 512 MiB) → cap. 34

## Conceitos aprofundados aqui
- hash senha: sal, custo, memória; bcrypt 72 bytes; Argon2id RFC 9106, OWASP 19 MiB/2/1; pimenta; rehash no login
- ECB pinguim; CTR maleável; AEAD, AES-GCM, AAD, nonce 96 bits, 2^32, ChaCha20-Poly1305
- assimétrica: ECDH, assinatura, ECDSA `k` repetido, Ed25519
- HMAC RFC 2104, length extension, `compare_digest`; SHA-256(PAN) reversível (10^5)
- KMS/HSM, envelope DEK/KEK, crypto-shredding
- segredos: env `/proc/<pid>/environ`, gerenciador, rotação A/B, dinâmicos
- tokenização × cifra, FPE; PCI: SAD proibido pós-autorização, BIN+4

## Casos reais usados
- Adobe 2013 (3DES ECB, dicas); PS3 fail0verflow 27C3 2010; Flickr 2009 (Duong/Rizzo); Stripe formato assinatura

## Piadas recorrentes
- temp-01 passou 1ª auditoria por ausência; fundador mandou foto do monitor; `shred` como missa de sétimo dia
- vendedor 42 achou próprio cartão (comprou capinha de si mesmo)
- financeiro: planilha tokeniza ("cliente do final 4421")
- consultoria Java: 8 h por HMAC com acento
- Carlos: sobremesa do sal e pimenta
