# Resumo 33 — Criptografia aplicada e segredos

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- hash de senha: salt 16 bytes + fator de trabalho; GPU RTX 4090 >160 bi MD5/s, >20 bi SHA-256/s
- bcrypt custo 2^n, `$2b$12$`, corta em 72 bytes; Argon2id RFC 9106 m/t/p, memória contra GPU; argon2-cffi padrão m=65536 t=3 p=4; OWASP mínimos (19 MiB t=2 p=1; bcrypt 10; PBKDF2 600 mil FIPS); check_needs_rehash; embrulhar MD5 antigo
- ECB revela blocos iguais; CBC sem MAC → padding oracle (Vaudenay 2002)
- AEAD RFC 5116: AES-GCM (nonce 96 bits, tag 128, GHASH), ChaCha20-Poly1305; nonce repetido → XOR textos + forja (Joux 2006); 2³² cifrações por chave aleatória (SP 800-38D); AAD amarra contexto
- HMAC RFC 2104 vs extensão de comprimento; webhook: bytes crus + timestamp 300 s + compare_digest
- índice cego HMAC, chave separada, CPF 10⁹ valores
- assinatura vs HMAC (terceiros verificam sem assinar); Ed25519 32/64 bytes determinística; ECDSA nonce repetido vaza chave; ML-KEM/ML-DSA FIPS 203/204
- envelope encryption: KEK no KMS/HSM, DEK local, auditoria, rotação barata, apagamento criptográfico; 4 KB AWS KMS; cache de DEK
- vazamento: git, camadas Docker, /proc/pid/environ, logs, Secret base64 sem encryption at rest
- rotação: duas versões válidas; azul/verde, kid/JWKS, lista de segredos HMAC
- `random` Mersenne Twister 624 saídas → `secrets`

## Termos e traduções adotados
- blind index → índice cego; associated data → dados associados (AAD)
- envelope encryption, KEK, DEK, nonce, tag, hazmat, lease em inglês
- length extension → extensão de comprimento

## Casos reais e exemplos usados (não repetir)
- hipotético: Fala Fácil, terça 9h14, `backup_final_COMPLETO.sql.gz`, 212 mil alunos, chave `fala-facil-2017!` (16 chars) em 6 lugares, `#geral`
- AESGCM CPF aluno 7→8 InvalidTag; Ed25519 recibo R$ 0,01
- Adobe 2013 3DES-ECB dicas; Uber 2016 credenciais GitHub 57 mi; Okta 2024 bcrypt 72 bytes; Flickr 2009 Duong/Rizzo; PS3 fail0verflow 2010
