# Criptografia aplicada e segredos

## Vocês sabem que isso está público?

Ninguém na Fala Fácil, uma escola de idiomas online (hipotética), sabia quem tinha criado aquele bucket, nem que dentro dele morava o arquivo `backup_final_COMPLETO.sql.gz`. A escola descobriu numa terça-feira, às 9h14, por um e-mail com o link e o assunto mais curto e mais assustador da história da empresa: "vocês sabem que isso está público?".

O dump tinha 212 mil alunos. A coluna `senha` guardava MD5 sem salt. A coluna `cpf_cifrado` usava AES em modo ECB com a chave `fala-facil-2017!`, escolhida em 2017 por um critério técnico irrepreensível: tem exatamente 16 caracteres, o tamanho de uma chave AES-128. Ela morava em `settings.py`, linha 42, e numa mensagem fixada no `#geral` desde 2018, "para facilitar o onboarding".

Às 9h40, alguém comentou que pelo menos os CPFs estavam criptografados. Às 9h41, alguém notou que o repositório tinha ido junto.

A pergunta deste capítulo: se cada dado da Fala Fácil tivesse sido protegido pela primitiva certa, com a chave guardada no lugar certo, o que teria sobrevivido àquele link?

## Senhas, ou a arte de ser lento de propósito

Uma senha nunca precisa ser decifrada. O servidor só precisa saber se a senha digitada agora é a cadastrada antes, e para isso basta um hash, uma função de mão única.

O problema do MD5 e do SHA-256 nessa tarefa é a velocidade. Benchmarks públicos do hashcat numa única GPU de consumo (RTX 4090) passam de 160 bilhões de MD5 e de 20 bilhões de SHA-256 por segundo. O atacante não reverte nada: calcula o hash de cada candidata e compara. Com dicionários de senhas vazadas e regras de mutação (`Fala@2024`, `Fala@2025`), a maior parte de uma base real cai em horas. Sem salt, pior: o MD5 de `123456` é `e10adc3949ba59abbe56e057f20f883e` em qualquer sistema do planeta, e todos os alunos com essa senha caem juntos, numa matrícula coletiva.

### Salt e fator de trabalho

Um algoritmo de hash de senha acrescenta duas coisas. O **salt** é um valor aleatório por senha (16 bytes é o usual), guardado em claro junto com o hash: senhas iguais passam a ter hashes diferentes, e tabelas pré-calculadas deixam de servir. O **fator de trabalho** deixa cada cálculo caro de propósito. Se o login leva 50 ms em vez de 50 ns, o usuário nem percebe, e o atacante passa de bilhões de tentativas por segundo para algumas dezenas por núcleo.

O **bcrypt** (1999) tem custo exponencial: custo 12 significa 2¹² iterações do agendamento de chaves do Blowfish, e cada +1 dobra o tempo. O formato é `$2b$12$` seguido de 22 caracteres de salt e 31 de hash. Ele só olha os primeiros 72 bytes da entrada; o resto é ignorado em silêncio, e isso já virou incidente (veja "Armadilhas").

O **Argon2id** (RFC 9106, vencedor da Password Hashing Competition de 2015) acrescenta custo de **memória**: cada cálculo preenche, digamos, 64 MiB e lê esse bloco em ordem dependente dos dados. A GPU tem milhares de núcleos, mas não 64 MiB de memória rápida para cada um: paralelizar 10 mil tentativas passa a exigir 640 GB de RAM. Os parâmetros são `m` (memória em KiB), `t` (passadas) e `p` (paralelismo). A OWASP lista como mínimo Argon2id com 19 MiB, `t=2`, `p=1`; bcrypt com custo 10; e PBKDF2-HMAC-SHA256 com 600 mil iterações quando a exigência for FIPS 140.

### Na prática

A biblioteca `argon2-cffi` usa por padrão o perfil de baixa memória da RFC 9106 (`m=65536`, `t=3`, `p=4`):

```python
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

ph = PasswordHasher()  # Argon2id, 64 MiB, t=3, p=4

hash_ana = ph.hash("correto-cavalo-bateria-grampo")
hash_bia = ph.hash("correto-cavalo-bateria-grampo")  # mesma senha, por coincidência cósmica

print(hash_ana)
print(hash_ana == hash_bia)
print(ph.verify(hash_ana, "correto-cavalo-bateria-grampo"))

try:
    ph.verify(hash_ana, "fala-facil-2017!")
except VerifyMismatchError:
    print("senha errada (e que senha, hein)")

print(ph.check_needs_rehash(hash_ana))
```

```text
$argon2id$v=19$m=65536,t=3,p=4$8wJpQm2NcBqFz7vYtXh1aQ$Xk3c9Lr0PqZ1vTn8YwB2sJ6hGfD4eM5aKuR7oNiCtVg
False
True
senha errada (e que senha, hein)
False
```

O hash carrega algoritmo, versão, parâmetros e salt. No login bem-sucedido, com a senha em claro na mão, `check_needs_rehash` compara os parâmetros gravados com os atuais e permite gravar um hash novo. Para tirar uma base do MD5 sem esperar cada aluno logar, aplica-se Argon2 sobre o MD5 antigo e marca-se a linha como "embrulhada".

> **Armadilha:** 64 MiB vezes 200 logins simultâneos dá 12,5 GiB de RAM, e o login vira o endpoint preferido de quem quer derrubar o serviço. Limite de concorrência e rate limiting (capítulo 28) fazem parte da configuração do hash.

## Criptografia simétrica com autenticação embutida

O CPF precisa voltar: a nota fiscal exige o número real. Para isso existe a criptografia simétrica, em que a mesma chave cifra e decifra.

O **AES** transforma exatamente 16 bytes em 16 bytes, com chave de 128, 192 ou 256 bits. Para mais de um bloco entra um **modo de operação**, e foi ali que a Fala Fácil tropeçou. O **ECB** cifra cada bloco de forma independente, então blocos iguais geram cifrados iguais: todos os CPFs que começam com `123.456.789-` compartilhavam o primeiro bloco, e o dump mostrava quem tinha o mesmo prefixo sem decifrar nada. O **CBC** esconde a repetição, mas sem autenticação: o ataque de padding oracle (Vaudenay, 2002) mostrou que um servidor que distingue "padding inválido" de "dado inválido" decifra a mensagem inteira para o atacante, um byte por vez, com a maior boa vontade.

### AEAD

Os modos atuais são **AEAD** (*authenticated encryption with associated data*, RFC 5116): confidencialidade e integridade juntas. Os mais usados são o **AES-GCM** e o **ChaCha20-Poly1305** (RFC 8439). O AES-GCM recebe chave, um **nonce** de 96 bits, o texto em claro e **dados associados** opcionais (AAD). Cifra em modo contador, fazendo XOR do texto com `AES(chave, nonce || contador)`, e calcula uma **tag** de 128 bits com GHASH, um polinômio sobre GF(2¹²⁸), sobre o texto cifrado e os dados associados. Se um único bit mudou, a decifração falha inteira e nenhum byte é devolvido.

O nonce precisa ser único para cada cifração com a mesma chave, sem exceção. Repetido, ele gera o mesmo fluxo de chave, e o XOR dos dois cifrados vira o XOR dos dois textos em claro. Pior: o atacante recupera a chave de autenticação do GHASH e passa a forjar mensagens válidas (o "ataque proibido", Joux, 2006). Com nonces aleatórios, a NIST SP 800-38D limita a chave a 2³² cifrações. Quatro bilhões parece muito até o job noturno que recifra a tabela inteira de eventos.

Os **dados associados** são autenticados sem ser cifrados e amarram o cifrado ao contexto. Sem AAD, quem escreve no banco copia o `cpf_cifrado` do aluno 7 para a linha do aluno 8, e a decifração funciona. Com o ID do aluno como AAD, a cópia falha:

```python
import os
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

chave = bytes.fromhex(os.environ["CHAVE_CPF_HEX"])  # 32 bytes; nada de "fala-facil-2017!"
aead = AESGCM(chave)

def cifrar_cpf(aluno_id: int, cpf: str) -> bytes:
    nonce = os.urandom(12)
    aad = f"aluno:{aluno_id}:cpf".encode()
    return nonce + aead.encrypt(nonce, cpf.encode(), aad)

def decifrar_cpf(aluno_id: int, blob: bytes) -> str:
    aad = f"aluno:{aluno_id}:cpf".encode()
    return aead.decrypt(blob[:12], blob[12:], aad).decode()

blob = cifrar_cpf(7, "123.456.789-09")
print(len(blob))                  # 12 de nonce + 14 do CPF + 16 de tag
print(decifrar_cpf(7, blob))

try:
    decifrar_cpf(8, blob)         # CPF do aluno 7 colado na linha do aluno 8
except InvalidTag:
    print("InvalidTag: esse CPF tem dono, e não é você")
```

```text
42
123.456.789-09
InvalidTag: esse CPF tem dono, e não é você
```

Repare que a API não pede modo, padding nem tamanho de tag. A biblioteca `cryptography` coloca essas primitivas no módulo `hazmat` (*hazardous materials*), e o nome do módulo é a documentação mais honesta da área.

## HMAC, ou como provar que a mensagem saiu de você

Às vezes o dado pode ficar visível, desde que ninguém o altere: um webhook, um cursor de paginação, um link de descadastro. A ferramenta é o **MAC** (*message authentication code*), uma tag que só quem tem a chave secreta consegue produzir.

A construção ingênua, `SHA-256(chave || mensagem)`, é quebrada. No SHA-256 (construção Merkle-Damgård), o hash final é o estado interno depois do último bloco, e quem o conhece continua a computação e obtém o hash de `chave || mensagem || padding || extra` sem ver a chave. Com esse **ataque de extensão de comprimento**, Thai Duong e Juliano Rizzo forjaram em 2009 chamadas assinadas na API do Flickr.

O **HMAC** (RFC 2104) fecha essa porta aplicando o hash duas vezes, com a chave misturada a duas constantes:

```text
HMAC(K, m) = H((K ⊕ opad) || H((K ⊕ ipad) || m))
```

O hash externo esconde o estado do interno, e a extensão para de funcionar. O HMAC-SHA256 assina webhooks, cookies de sessão de vários frameworks e o JWT HS256. Na verificação de um webhook, três detalhes costumam faltar: calcular sobre os bytes exatos do corpo, incluir um timestamp contra reenvio e comparar em tempo constante:

```python
import hashlib
import hmac
import os
import time

SEGREDO = os.environ["WEBHOOK_SEGREDO"].encode()
TOLERANCIA_S = 300

def webhook_valido(corpo: bytes, timestamp: str, assinatura_hex: str) -> bool:
    if abs(time.time() - int(timestamp)) > TOLERANCIA_S:
        return False  # replay de ontem; não, obrigado
    esperado = hmac.new(SEGREDO, timestamp.encode() + b"." + corpo, hashlib.sha256)
    return hmac.compare_digest(esperado.hexdigest(), assinatura_hex)
```

O `==` para no primeiro caractere diferente, e um atacante paciente, medindo tempos, descobre a assinatura caractere por caractere. `hmac.compare_digest` leva sempre o mesmo tempo e transforma essa paciência em hobby.

Com nonce aleatório, o mesmo CPF cifrado duas vezes gera blobs diferentes, o que inviabiliza `WHERE cpf = ...`. A saída usual é o **índice cego** (*blind index*): uma coluna com `HMAC-SHA256(chave_indice, cpf)`, indexada normalmente. Ele vaza igualdade, e a chave do índice precisa ser outra: o CPF tem 9 dígitos livres, então existem só 10⁹ valores, e com a chave em mãos uma GPU testa todos em segundos.

## Criptografia assimétrica e assinaturas

A criptografia assimétrica separa a chave em duas: a **privada**, que fica com o dono, e a **pública**, que pode ir para um outdoor. No backend ela aparece na troca de chaves (X25519 deriva um segredo comum entre dois lados, como no handshake do TLS 1.3, tema do capítulo 3), na cifração híbrida (RSA-OAEP cifra uma chave simétrica pequena, que cifra o dado) e nas assinaturas.

A assinatura tem uma propriedade que o HMAC não tem. Com HMAC, quem verifica tem a chave e também consegue gerar tags válidas, o que serve entre dois sistemas seus. Com assinatura, milhares de verificadores (clientes validando JWTs RS256, servidores validando pacotes) conhecem a chave pública sem que nenhum deles consiga assinar nada.

```python
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

privada = Ed25519PrivateKey.generate()  # em produção, carregada de um KMS ou cofre
publica = privada.public_key()

recibo = b'{"aluno": 7, "curso": "ingles-b2", "valor_centavos": 39900}'
assinatura = privada.sign(recibo)
print(len(assinatura))

publica.verify(assinatura, recibo)  # silêncio significa sucesso
print("recibo autêntico")

adulterado = recibo.replace(b"39900", b"00001")
try:
    publica.verify(assinatura, adulterado)
except InvalidSignature:
    print("InvalidSignature: curso de inglês a R$ 0,01 não existe")
```

```text
64
recibo autêntico
InvalidSignature: curso de inglês a R$ 0,01 não existe
```

O Ed25519 (RFC 8032) tem chave pública de 32 bytes, assinatura de 64 e assinatura determinística. O ECDSA exige um número aleatório secreto por assinatura, e repeti-lo entrega a chave privada a quem tiver duas assinaturas, por álgebra de ensino médio. Foi assim que o grupo fail0verflow extraiu em 2010 a chave de assinatura de firmware do PlayStation 3, que usava sempre o mesmo número.

Pela NIST SP 800-57, RSA 3072 dá 128 bits de segurança, o mesmo que P-256 e Curve25519 com chaves bem menores. Contra computadores quânticos, o NIST publicou em 2024 o ML-KEM (FIPS 203) e o ML-DSA (FIPS 204).

## Envelope encryption e KMS

A chave da Fala Fácil, a esta altura conhecida até pelo estagiário que entrou ontem, tinha um defeito de origem: precisava estar na memória da aplicação, e o que está na memória da aplicação vai, cedo ou tarde, para um arquivo, um log ou um canal do chat.

O **KMS** (*key management service*) guarda chaves em hardware (HSM) e opera com elas sem exportá-las (AWS KMS, Google Cloud KMS, Azure Key Vault e o Transit do HashiCorp Vault são exemplos). Cada chamada custa alguns milissegundos de rede e aceita pouco dado (4 KB no AWS KMS), então ninguém manda um vídeo de aula de 2 GB para lá. A **envelope encryption** usa duas camadas de chave:

```text
KEK (key encryption key)   -> mora no KMS, nunca sai de lá
  └─ DEK (data encryption key) -> gerada por registro, arquivo ou tenant
        └─ dado cifrado localmente com AES-GCM

Armazenado lado a lado: [DEK cifrada pela KEK] + [nonce] + [dado cifrado]
```

A aplicação pede ao KMS uma chave de dados e recebe duas versões dela: em claro e cifrada pela KEK. Cifra o dado localmente com a DEK em claro, grava o resultado ao lado da DEK cifrada e descarta a versão em claro. Para decifrar, manda a DEK cifrada ao KMS, recebe a DEK em claro (se tiver permissão) e decifra localmente.

```python
import os
from typing import Protocol
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

class Kms(Protocol):
    def gerar_chave_de_dados(self, id_kek: str) -> tuple[bytes, bytes]: ...  # (em claro, cifrada)
    def decifrar_chave(self, dek_cifrada: bytes) -> bytes: ...

ID_KEK = os.environ["KMS_KEK_DOCUMENTOS"]

def cifrar_documento(kms: Kms, aluno_id: int, conteudo: bytes) -> dict:
    dek, dek_cifrada = kms.gerar_chave_de_dados(ID_KEK)
    nonce = os.urandom(12)
    cifrado = AESGCM(dek).encrypt(nonce, conteudo, f"doc:{aluno_id}".encode())
    del dek  # higiene; o GC do Python decide quando a memória some de verdade
    return {"dek_cifrada": dek_cifrada, "nonce": nonce, "cifrado": cifrado}
```

Com isso, o dump do banco deixa de bastar: as DEKs cifradas só abrem com uma credencial de KMS que não estava no bucket. Cada decifração vira uma linha no log de auditoria do KMS, e 212 mil `Decrypt` às 3h da manhã chamam atenção. Rotacionar a KEK não exige recifrar terabytes, porque o KMS guarda as versões antigas para decifrar. E uma DEK por tenant permite apagamento criptográfico: destruir a chave torna ilegíveis até as cópias em backup (o capítulo 23 usa isso com LGPD). O custo é uma chamada ao KMS por decifração, contra cotas da ordem de milhares por segundo; um cache de DEKs com prazo curto troca parte da auditoria por desempenho.

## Segredos, onde moram e como trocam de casa

Um **segredo** é qualquer valor que concede acesso: senha do banco, chave de API, chave HMAC, chave privada. A auditoria achou `fala-facil-2017!` em seis lugares, incluindo um `.env.exemplo` que de exemplo tinha só o nome, a camada 4 da imagem Docker e um print na wiki intitulado "Como subir o ambiente (FUNCIONA)".

No histórico do git, apagar o arquivo num commit novo deixa o segredo em todos os anteriores, e reescrever o histórico não desfaz clones nem forks: segredo que chegou a um remoto se revoga. Numa imagem Docker, `COPY .env .` seguido de `RUN rm .env` deixa o arquivo intacto na camada do `COPY`. Variáveis de ambiente são legíveis em `/proc/<pid>/environ`, aparecem em dumps de crash e são herdadas por todo subprocesso; um arquivo em `/run/secrets/` com permissão restrita expõe menos. E o Secret do Kubernetes guarda o valor em base64, que é codificação: sem *encryption at rest* configurada no etcd, quem lê o etcd ou o backup dele lê tudo.

Um **gerenciador de segredos** (HashiCorp Vault, AWS Secrets Manager, Google Secret Manager, Azure Key Vault) centraliza o armazenamento com acesso por identidade da carga de trabalho, versões e auditoria. Com **segredos dinâmicos**, o Vault cria um usuário de banco por instância, válido por horas. O capítulo 37 aplica a mesma ideia ao pipeline com OIDC.

### Rotação sem derrubar nada

A troca nunca chega a todas as réplicas no mesmo instante, então rotacionar sem downtime exige duas versões válidas ao mesmo tempo: criar a nova, fazer quem verifica aceitar as duas, migrar quem usa, confirmar nos logs que a antiga morreu e só então revogá-la. Em senha de banco, dois usuários alternados (`app_azul` e `app_verde`) fazem isso; em JWT, o `kid` e um JWKS com as duas chaves públicas. Em HMAC de webhook, o verificador tenta uma lista:

```python
SEGREDOS = [s.encode() for s in os.environ["WEBHOOK_SEGREDOS"].split(",")]  # novo primeiro

def assinatura_confere(mensagem: bytes, assinatura_hex: str) -> bool:
    return any(
        hmac.compare_digest(hmac.new(s, mensagem, hashlib.sha256).hexdigest(), assinatura_hex)
        for s in SEGREDOS
    )
```

Quem só rotaciona depois de um vazamento descobre esses passos à 1h da manhã, com alguém perguntando a cada dez minutos se "já trocou a senha". Rotação periódica automática mantém o procedimento testado.

## Propriedades e custos

| Primitiva | Garante | Chave | Custo típico | Uso típico |
|-----------|---------|-------|--------------|------------|
| Argon2id / bcrypt | Resistência a força bruta offline | Nenhuma (salt por senha) | Dezenas de ms e dezenas de MiB por cálculo | Senhas |
| SHA-256 | Integridade contra erro acidental | Nenhuma | GB/s por núcleo | Checksums, deduplicação |
| HMAC-SHA256 | Integridade e autenticidade entre quem tem a chave | Simétrica compartilhada | GB/s por núcleo | Webhooks, cursores, índice cego |
| AES-GCM / ChaCha20-Poly1305 | Confidencialidade e integridade | Simétrica | GB/s com AES-NI | Dados em repouso, TLS |
| Ed25519 / ECDSA / RSA-PSS | Autenticidade verificável por terceiros | Par assimétrico | Dezenas de µs (Ed25519) a ms (RSA 3072 assinando) | JWT, artefatos, recibos |
| Envelope + KMS | Chave mestra fora da aplicação, auditoria | KEK no HSM, DEK local | Uma chamada de rede por DEK | Dados sensíveis em escala |

Entre os hashes de senha, o Argon2id resiste melhor a GPU por causa da memória, que precisa caber no servidor de login sob pico. O bcrypt se contenta com 4 KiB e para de ler no byte 72, com a discrição de quem não avisa que parou. O PBKDF2 é o mais barato de atacar em GPU e o único dos três aprovado pelo FIPS 140, o que decide contratos que exigem essa certificação.

## Armadilhas e casos reais

> **Na vida real:** em 2013, a Adobe vazou cerca de 153 milhões de registros com senhas cifradas em 3DES-ECB, todas com a mesma chave, e dicas de senha em claro ao lado. Senhas iguais tinham o mesmo cifrado, e cruzar as dicas de cada grupo virou palavra cruzada coletiva. Ninguém precisou da chave.

> **Na vida real:** em 2016, atacantes acharam credenciais da AWS num repositório privado do GitHub usado por engenheiros da Uber e baixaram dados de 57 milhões de usuários e motoristas. Privado, no caso, significava "privado para quem não tem a senha de algum dos engenheiros".

> **Armadilha:** em 2024, a Okta divulgou que seu cache de autenticação delegada AD/LDAP usava bcrypt sobre `userId + username + senha`. Com nome de usuário de 52 caracteres ou mais, a senha ficava depois do byte 72 e era ignorada: qualquer senha passava, se houvesse login anterior em cache.

> **Armadilha:** o módulo `random` usa o Mersenne Twister, e 624 saídas observadas reconstroem o estado inteiro. Tokens, salts e nonces vêm de `secrets` ou `os.urandom`. Um contador em memória como nonce de GCM também falha: recomeça do zero a cada deploy.

O CPF cifrado com todo cuidado costuma aparecer em claro no log do middleware. E criptografia caseira (XOR "para ofuscar", SHA-256 "com 1.000 iterações") pede revisão de especialista em segurança; `cryptography` e `argon2-cffi` existem para que ninguém invente o próprio modo de operação.

Voltando à pergunta do começo: com Argon2id, as senhas da Fala Fácil custariam anos de GPU em vez de uma tarde. Com AES-GCM, AAD e envelope encryption, os CPFs seriam bytes aleatórios. E a chave `fala-facil-2017!`, num gerenciador com rotação automática, teria sido trocada umas trinta vezes antes de alguém pensar em fixá-la no `#geral`.

## Resumo

- Senha: hash lento e salgado (Argon2id, bcrypt até 72 bytes, PBKDF2 para FIPS), com rehash no login.
- AES-GCM e ChaCha20-Poly1305 cifram e autenticam; nonce único por chave, AAD amarra ao contexto. ECB revela padrões.
- HMAC autentica entre quem tem a chave; compare com `hmac.compare_digest`. Índice cego permite busca por igualdade.
- Assinatura é verificável por terceiros que não conseguem assinar; ECDSA com número repetido vaza a chave.
- Envelope encryption: DEK local, KEK no KMS; auditoria e rotação barata por uma chamada de rede.
- Segredo exposto se revoga. Rotação sem downtime exige duas versões válidas ao mesmo tempo.

## Referências

- RFC 9106, *Argon2 Memory-Hard Function for Password Hashing and Proof-of-Work Applications*: https://www.rfc-editor.org/rfc/rfc9106
- RFC 5116, *An Interface and Algorithms for Authenticated Encryption*: https://www.rfc-editor.org/rfc/rfc5116
- RFC 2104, *HMAC: Keyed-Hashing for Message Authentication*: https://www.rfc-editor.org/rfc/rfc2104
- RFC 8032, *Edwards-Curve Digital Signature Algorithm (EdDSA)*: https://www.rfc-editor.org/rfc/rfc8032
- NIST SP 800-38D, *Recommendation for Block Cipher Modes of Operation: Galois/Counter Mode (GCM) and GMAC*: https://csrc.nist.gov/pubs/sp/800/38/d/final
- NIST SP 800-57 Part 1 Rev. 5, *Recommendation for Key Management*: https://csrc.nist.gov/pubs/sp/800/57/pt1/r5/final
- NIST FIPS 203: https://csrc.nist.gov/pubs/fips/203/final
- OWASP Password Storage Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
- OWASP Secrets Management Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html
- `cryptography`, AEAD: https://cryptography.io/en/latest/hazmat/primitives/aead/
- `argon2-cffi`: https://argon2-cffi.readthedocs.io/
- Kubernetes, *Encrypting Confidential Data at Rest*: https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- Vaudenay, *Security Flaws Induced by CBC Padding*, EUROCRYPT 2002.
- Duong e Rizzo, *Flickr's API Signature Forgery Vulnerability*, 2009.
- fail0verflow, *Console Hacking 2010*, 27C3.
- Okta, aviso sobre autenticação delegada AD/LDAP, novembro de 2024.
