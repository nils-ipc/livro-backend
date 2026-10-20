# TLS e certificados

## O arquivo que derrubou a API sem nenhum bug

Sábado, 3h12. O aplicativo de pagamentos para de funcionar para todo mundo ao mesmo tempo. O código não mudou desde quarta, o banco está calmo, a CPU dorme a 4%. Os logs do aplicativo trazem uma única linha, repetida 80 mil vezes:

```text
ssl.SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED]
certificate verify failed: certificate has expired (_ssl.c:1000)
```

A história é hipotética e o enredo, clássico. O certificado de `api.example.com` foi comprado à mão 397 dias antes, o lembrete de renovação estava na agenda de uma pessoa que saiu da empresa em 2023, e o inventário oficial de certificados é a planilha `certificados_FINAL_v3.xlsx`, editada pela última vez pela mesma pessoa. O certificado tinha uma data dentro. A data chegou.

Nenhuma linha de código estava errada, e mesmo assim nada funcionava. O que o cliente verifica, exatamente, entre o `connect()` e o primeiro byte de HTTP, e por que uma data num arquivo pode parar tudo?

## O que o TLS promete

O TLS (*Transport Layer Security*) roda sobre o TCP e garante ao canal confidencialidade, integridade e autenticação do servidor (você está falando com `api.example.com`, e não com o roteador do café).

A versão atual é o TLS 1.3 (RFC 8446, 2018). O TLS 1.2 (RFC 5246) continua em uso e é seguro quando bem configurado. O 1.0 e o 1.1 foram aposentados pela RFC 8996 em 2021, o que não impediu muito appliance corporativo de continuar oferecendo os dois com o orgulho de quem ainda usa fax.

Primeiro vem o *handshake*, que combina chaves e autentica as partes; depois, o *record protocol* cifra os dados com essas chaves. Todas as falhas das 3h da manhã acontecem no handshake.

## O handshake do TLS 1.3, ou uma conversa de um RTT

No TLS 1.2, o handshake completo custava dois RTTs antes do primeiro byte de HTTP. O TLS 1.3 reduziu para um, porque o cliente aposta logo na primeira mensagem: em vez de perguntar quais algoritmos de troca de chaves o servidor aceita, ele já manda a sua parte da troca para o algoritmo mais provável.

```text
Cliente                                         Servidor

ClientHello
  + key_share (X25519)
  + server_name (SNI)
  + ALPN (h2, http/1.1)
  + signature_algorithms        -------->
                                                ServerHello
                                                  + key_share
                                         {EncryptedExtensions}
                                                 {Certificate}
                                           {CertificateVerify}
                                <--------           {Finished}
{Finished}                      -------->
[Dados da aplicação]            <------->  [Dados da aplicação]

{ } = cifrado com chaves de handshake
[ ] = cifrado com chaves de tráfego
```

O ClientHello leva um número aleatório, as *cipher suites* aceitas, uma chave pública efêmera (`key_share`), o nome do servidor (SNI) e os protocolos de aplicação (ALPN). O ServerHello devolve a escolha da cipher suite e a chave efêmera do servidor; daí em diante os dois lados já calculam um segredo compartilhado, e o resto sai cifrado. O `Certificate` traz a cadeia de certificados. O `CertificateVerify` é uma assinatura, feita com a chave privada do certificado, sobre o hash de todas as mensagens anteriores: prova que o servidor tem a chave, e não só uma cópia do certificado (que é público e qualquer um baixa). O `Finished` é um HMAC sobre a transcrição inteira; se alguém no caminho mexeu em um byte do handshake (para rebaixar a versão, por exemplo), os HMACs não batem e a conexão morre.

Se o cliente apostou num grupo que o servidor não aceita, recebe um *HelloRetryRequest* e paga um RTT extra pela aposta errada. O modo 0-RTT, com seu risco de *replay*, é tratado no capítulo 2.

Uma conexão HTTPS nova custa um RTT do TCP mais um do TLS antes de a requisição sair: com 150 ms de RTT, 300 ms de cerimônia antes do `GET`. Daí a importância de reusar conexões e da *session resumption*, em que o servidor entrega um ticket (um *pre-shared key*, PSK) e o cliente o apresenta na conexão seguinte, pulando a verificação do certificado.

## Troca de chaves, ou como combinar um segredo em voz alta

O segredo compartilhado sai de um Diffie-Hellman efêmero sobre curva elíptica (ECDHE). Cada lado gera um par de chaves descartável, envia a parte pública e combina a pública do outro com a sua privada. A matemática garante que os dois chegam ao mesmo valor e que quem só viu as duas chaves públicas passando pela rede não consegue calcular esse valor. A curva mais usada é a X25519 (RFC 7748), com chaves públicas de 32 bytes.

Do segredo, uma função de derivação (HKDF) produz as chaves de handshake e de tráfego, cada uma amarrada ao hash da transcrição.

A palavra que importa é "efêmero": as chaves do Diffie-Hellman nascem para uma conexão e morrem com ela. A chave privada do certificado só assina o `CertificateVerify` e nunca participa da cifragem. Quem gravar seu tráfego hoje e roubar a chave do certificado amanhã continua sem conseguir ler o que gravou. Essa propriedade se chama *forward secrecy*.

No TLS 1.2 havia a troca de chaves por RSA, em que o cliente cifrava o segredo com a chave pública do certificado; quem roubasse a chave privada decifrava anos de tráfego gravado, com a calma de quem lê um arquivo morto. O TLS 1.3 removeu essa opção e todas as cifras que não fossem AEAD (cifragem autenticada). Na prática sobram `TLS_AES_128_GCM_SHA256`, `TLS_AES_256_GCM_SHA384` e `TLS_CHACHA20_POLY1305_SHA256`, e aquela string de cifras de 400 caracteres copiada de um blog em 2016 deixa de se aplicar.

Um computador quântico grande o suficiente quebraria o ECDHE retroativamente, então os navegadores principais passaram a negociar por padrão o grupo híbrido `X25519MLKEM768`, que soma ao X25519 o ML-KEM, pós-quântico, padronizado pelo NIST (FIPS 203). O ClientHello cresce cerca de 1,2 KB, o bastante para alguns middleboxes antigos, que esperavam o ClientHello num único pacote, descobrirem a fragmentação da pior forma.

## Certificados e a cadeia de confiança

A troca de chaves garante um canal secreto, mas sem dizer com quem: um atacante no meio do caminho faz um Diffie-Hellman impecável com você. O certificado liga uma chave pública a um nome, e alguém em quem você confia assina essa ligação.

Um certificado X.509 v3 (RFC 5280) traz os nomes válidos no *Subject Alternative Name* (SAN; o Chrome deixou de olhar o `CN` em 2017), o período de validade (`notBefore` e `notAfter`, a data do sábado às 3h12), a chave pública, o emissor com a assinatura dele sobre tudo isso e extensões como `basicConstraints`, que diz se o certificado pode emitir outros. O curinga `*.example.com` cobre exatamente um nível: vale para `api.example.com` e não vale para `example.com` nem para `v2.api.example.com`, regra que já custou mais de uma migração de sexta à tarde.

### A cadeia

O certificado do servidor (o *leaf*) é assinado por uma CA intermediária, assinada por uma CA raiz, que é autoassinada e vem pré-instalada no *trust store*. Em Python, o módulo `ssl` usa o trust store do sistema via OpenSSL, enquanto `requests` e `httpx` usam por padrão o pacote `certifi`, com as raízes do Mozilla. São duas listas, e por isso um certificado pode passar no `curl` e falhar no worker Python na mesma máquina.

O cliente monta o caminho do leaf até uma raiz confiável e confere, em cada elo, a assinatura, as datas contra o relógio local, se o emissor tem `CA:TRUE` e, no leaf, se o nome pedido está no SAN. Relógio errado também reprova: um dispositivo sem bateria de relógio que acorda em 1970 rejeita a internet inteira.

O servidor deve enviar o leaf mais as intermediárias (a raiz o cliente já tem). Esquecer a intermediária é o erro de configuração mais comum, e é traiçoeiro: navegadores completam a cadeia sozinhos (pela URL da extensão AIA ou por cache), enquanto Python, `curl` e Java falham. Daí a frase "no navegador funciona", dita com toda a sinceridade.

### Quem são as autoridades certificadoras

Uma CA pública só entra nos trust stores se seguir os *Baseline Requirements* do CA/Browser Forum e passar por auditorias. Para certificados de servidor, a CA valida o controle do domínio (*Domain Validation*, DV) pelo DNS ou pelo HTTP daquele nome.

Três mecanismos limitam o estrago de uma CA que erre. A *Certificate Transparency* (RFC 6962) registra todo certificado público em logs públicos, e Chrome e Safari exigem prova desse registro; efeito colateral: o nome `admin-legado-nao-mexer.example.com`, que você achava secreto, está num log público para sempre. O registro DNS CAA (RFC 8659) diz quais CAs podem emitir para o domínio. E há a revogação, por listas (CRL) ou consulta online (OCSP), que sempre funcionou mal: se a consulta falha, os navegadores seguem em frente (*soft-fail*), e quem intercepta a conexão também bloqueia a consulta. A Let's Encrypt desligou seu OCSP em 2025.

Como revogar funciona mal, a saída foi encurtar a vida dos certificados. O CA/Browser Forum aprovou em 2025 (ballot SC-081) validade máxima de 200 dias a partir de 15 de março de 2026, 100 dias a partir de março de 2027 e 47 dias a partir de março de 2029. Com 47 dias, a planilha `certificados_FINAL_v3.xlsx` precisaria ser editada umas oito vezes por ano por certificado, o argumento mais forte já feito contra ela.

## SNI, ou como um IP serve mil domínios

O certificado é enviado antes de qualquer HTTP, então o cabeçalho `Host` chega tarde demais para escolher entre os domínios de um IP compartilhado. A extensão *Server Name Indication* (SNI, RFC 6066) põe o nome no ClientHello, e o servidor escolhe o certificado por ele. Cliente sem SNI recebe o certificado padrão, em geral de outro domínio ou um autoassinado chamado `localhost`, e a validação reclama de nomes que não batem. Como o ClientHello trafega em claro, o SNI revela o site acessado a qualquer observador; o *Encrypted Client Hello* (ECH), especificado pelo IETF e já suportado por navegadores e algumas CDNs, cifra esse trecho com uma chave publicada no registro DNS `HTTPS`.

## Na prática

### Olhando um handshake

O `openssl s_client` faz o papel do cliente e mostra o que o servidor apresentou. Saída abreviada:

```bash
openssl s_client -connect api.example.com:443 -servername api.example.com </dev/null
```

```text
depth=2 C = US, O = Internet Security Research Group, CN = ISRG Root X1
verify return:1
depth=1 C = US, O = Let's Encrypt, CN = R11
verify return:1
depth=0 CN = api.example.com
verify return:1
---
Certificate chain
 0 s:CN = api.example.com
   i:C = US, O = Let's Encrypt, CN = R11
 1 s:C = US, O = Let's Encrypt, CN = R11
   i:C = US, O = Internet Security Research Group, CN = ISRG Root X1
---
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
...
Verify return code: 0 (ok)
```

Vieram leaf e intermediária; a raiz estava no trust store. Contra um servidor que esqueceu a intermediária:

```text
depth=0 CN = api.example.com
verify error:num=20:unable to get local issuer certificate
verify error:num=21:unable to verify the first certificate
---
Certificate chain
 0 s:CN = api.example.com
   i:C = US, O = Let's Encrypt, CN = R11
---
Verify return code: 21 (unable to verify the first certificate)
```

Um certificado só, emitido por um desconhecido. O navegador do desenvolvedor abre a página sem reclamar; o worker Python, não.

### Medindo quanto falta para o desastre

Um monitor de expiração em Python, usando só a biblioteca padrão:

```python
import socket
import ssl
from datetime import datetime, timezone


def dias_ate_o_sabado_ruim(host: str, porta: int = 443) -> int:
    ctx = ssl.create_default_context()  # valida cadeia e nome
    with socket.create_connection((host, porta), timeout=5) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as tls:
            print(tls.version(), tls.cipher())
            cert = tls.getpeercert()
    expira = datetime.fromtimestamp(
        ssl.cert_time_to_seconds(cert["notAfter"]), tz=timezone.utc
    )
    return (expira - datetime.now(timezone.utc)).days


print(dias_ate_o_sabado_ruim("api.example.com"))
```

```text
TLSv1.3 ('TLS_AES_256_GCM_SHA384', 'TLSv1.3', 256)
23
```

O `server_hostname` envia o SNI e diz ao `ssl` qual nome conferir no SAN. Detalhe cômico: no dia da expiração esse monitor não imprime `-1`, porque o `wrap_socket` levanta `SSLCertVerificationError` antes. Sem tratar essa exceção como alerta, o monitor morre junto com o certificado que deveria vigiar.

### O `verify=False` temporário

```python
# TODO: remover quando o certificado do parceiro for corrigido (mar/2019)
resposta = httpx.get(URL_PARCEIRO, verify=False)
```

Com `verify=False`, o cliente cifra o canal e aceita qualquer certificado, então quem estiver no caminho fecha um TLS com você, outro com o parceiro, e lê tudo no meio. Você ganha um canal perfeitamente cifrado até o atacante. Para uma CA interna, a correção é apontar o cliente para ela (`verify=ssl.create_default_context(cafile=...)`).

## Terminação TLS, ou onde o cadeado acaba

Em quase todo backend em produção, o processo Python nunca vê o TLS: um balanceador, reverse proxy ou CDN decifra a requisição e a repassa. Há três arranjos:

```text
1. Terminação:     cliente ==TLS==> proxy --HTTP--> app
2. Reencriptação:  cliente ==TLS==> proxy ==TLS==> app
3. Passthrough:    cliente ==========TLS==========> app   (proxy só repassa bytes TCP)
```

| Arranjo | Proxy vê o HTTP? | Chave do certificado público | Custo |
|---------|------------------|------------------------------|-------|
| Terminação | Sim (rota, cache, cabeçalhos) | Só no proxy | Tráfego em claro na rede interna |
| Reencriptação | Sim | No proxy; a app usa certificado de CA interna | Dois handshakes, dois certificados para renovar |
| Passthrough | Não (camada 4, no máximo rota por SNI) | Em cada instância | Sem cache nem WAF no proxy |

Uma assinatura ECDSA P-256 custa bem menos CPU que uma RSA 2048, por isso proxies de alto volume costumam servir certificados ECDSA. O capítulo 27 trata de balanceadores e proxies.

A terminação tem uma consequência que todo mundo descobre do mesmo jeito: a aplicação recebe HTTP e acha que a requisição veio por HTTP. Ela redireciona para `https://`, o proxy encaminha de novo como HTTP, e o navegador desiste com `ERR_TOO_MANY_REDIRECTS` depois de vinte voltas no mesmo carrossel. O proxy informa o esquema original em `X-Forwarded-Proto` (ou no `Forwarded`, RFC 7239), e a aplicação deve confiar nele só quando vem do proxy; no Uvicorn, `--proxy-headers` com `--forwarded-allow-ips` listando os IPs do balanceador. Aceito de qualquer origem, o cabeçalho deixa o cliente declarar o próprio IP, com a honestidade de quem forja cabeçalhos.

## ACME, ou o fim da renovação manual

O ACME (*Automatic Certificate Management Environment*, RFC 8555) é o protocolo que a Let's Encrypt criou para emitir certificados sem humanos, hoje aceito por várias CAs. O cliente ACME (certbot, Caddy, Traefik, cert-manager no Kubernetes) cria uma conta identificada por um par de chaves, abre um pedido para os nomes, prova o controle de cada um num desafio e envia um CSR; a CA devolve o certificado.

No desafio HTTP-01, o cliente publica um token em `http://<domínio>/.well-known/acme-challenge/<token>` e a CA o busca pela porta 80, o que surpreende quem fechou a 80 "por segurança". No DNS-01, o cliente cria um TXT em `_acme-challenge.<domínio>`; é o único que emite curingas e funciona para servidores fora da internet, mas exige credenciais de escrita no DNS. No TLS-ALPN-01, a prova acontece num handshake especial na porta 443.

Os certificados da Let's Encrypt valem 90 dias, e os clientes renovam com cerca de um terço restante (o certbot, a 30 dias do fim), o que deixa semanas de alertas antes de um sábado às 3h12. Desde junho de 2025 a Let's Encrypt não manda mais e-mails de aviso de expiração, então a monitoração precisa ser sua.

> **Armadilha:** a Let's Encrypt limita a emissão (por exemplo, 5 certificados idênticos por semana). Um contêiner que pede certificado novo a cada inicialização e entra em *crash loop* esgota o limite em cinco reinícios, e o sexto passa a semana sem certificado. Certificados e conta ACME precisam de armazenamento persistente.

## mTLS, ou quando o servidor também pede documento

No *mutual TLS* (mTLS), o servidor manda um `CertificateRequest` no handshake, e o cliente responde com o próprio `Certificate` e `CertificateVerify`. O servidor valida a cadeia do cliente contra uma CA que ele escolhe (em geral interna) e tira a identidade do SAN. O uso típico é entre serviços: o estoque só aceita quem tem certificado da CA interna e sabe pelo SAN se do outro lado está `pedidos` ou `relatorios`. Service meshes como Istio e Linkerd automatizam isso com certificados de horas e identidades SPIFFE (`spiffe://empresa/ns/prod/sa/pedidos`).

Do lado do cliente:

```python
import os
import ssl

import httpx

ctx = ssl.create_default_context(cafile=os.environ["CA_INTERNA_PEM"])
ctx.load_cert_chain(
    certfile=os.environ["PEDIDOS_CERT_PEM"],
    keyfile=os.environ["PEDIDOS_CHAVE_PEM"],
)

with httpx.Client(verify=ctx, base_url="https://estoque.interno.example:8443") as client:
    resposta = client.get("/reservas/42")
    print(resposta.status_code, resposta.json())
```

```text
200 {'reserva': 42, 'itens': 3, 'status': 'confirmada'}
```

Do lado do servidor, o Uvicorn exige o certificado do cliente com `--ssl-ca-certs` apontando para a CA interna e `--ssl-cert-reqs 2` (o valor de `ssl.CERT_REQUIRED`). Um cliente sem certificado recebe:

```text
ssl.SSLError: [SSL: TLSV13_ALERT_CERTIFICATE_REQUIRED] tlsv13 alert certificate required
```

No TLS 1.3, o cliente termina o handshake antes de o servidor validar o certificado dele, então a recusa só aparece na primeira leitura, o que já fez gente passar uma tarde procurando o bug na rota `/reservas`.

Se o balanceador termina o TLS, é ele quem vê o certificado do cliente, e a aplicação só conhece a identidade se o proxy a repassar num cabeçalho (o Envoy usa `X-Forwarded-Client-Cert`). Aceito de qualquer origem, esse cabeçalho vira um campo de formulário chamado "quem sou eu".

| | TLS comum + token na aplicação | mTLS |
|--|--|--|
| Credencial roubável | Token, reutilizável até expirar | Só a chave privada; o certificado é público |
| Operação | Emitir e validar tokens | Operar CA interna, rotacionar certificados |
| Atravessa proxies | Sim | Só com passthrough ou repasse pelo proxy |

O capítulo 30 trata dos tokens e o capítulo 33, das chaves e da sua guarda.

## Armadilhas e casos reais

**Certificado expirado em software de terceiros.** Em 6 de dezembro de 2018, um certificado expirado em versões do software SGSN-MME da Ericsson derrubou os dados móveis da O2 no Reino Unido e da SoftBank no Japão. O certificado vinha embutido no produto, fora do inventário das operadoras, e milhões de pessoas ficaram sem dados por uma data que ninguém ali podia renovar.

**Raiz que expira.** Em 30 de setembro de 2021 expirou a raiz DST Root CA X3, usada pela Let's Encrypt em assinatura cruzada. Clientes com OpenSSL 1.0.2 escolhiam o caminho pela raiz expirada mesmo havendo outro válido pela ISRG Root X1, e passaram a recusar milhões de sites cujos servidores não tinham mudado nada.

**Pinning.** Fixar no app móvel o hash do certificado (*certificate pinning*) protege contra uma CA comprometida e transforma toda renovação num deploy de aplicativo; se o certificado muda antes de os usuários atualizarem, o app para. Fixa-se também uma chave de reserva.

**A chave privada no lugar errado.** O `server.key` dentro da imagem Docker ou no repositório "só no projeto de teste" frequentemente é a chave de produção. Como a revogação funciona mal, quem a copiou pode usar o certificado até ele expirar.

Quanto ao sábado hipotético: o certificado foi renovado às 4h40, depois que alguém achou a senha da conta na CA dentro da própria `certificados_FINAL_v3.xlsx`, na aba "não apagar".

## Resumo

- TLS 1.3 (RFC 8446): handshake em 1 RTT, com tudo depois do ServerHello cifrado.
- ECDHE efêmero dá *forward secrecy*; a chave do certificado só assina.
- O cliente valida assinatura, datas e nome em toda a cadeia; o servidor envia leaf e intermediárias.
- Revogação funciona mal, então a validade máxima cai até 47 dias em 2029.
- SNI escolhe o certificado e trafega em claro; ECH o cifra.
- Terminação no proxy exige `X-Forwarded-Proto` aceito só do proxy.
- ACME (RFC 8555) automatiza a renovação; a monitoração da expiração continua sendo sua.
- mTLS autentica o cliente no handshake, ao custo de operar uma CA interna.

## Referências

- RFC 8446, The Transport Layer Security (TLS) Protocol Version 1.3: https://www.rfc-editor.org/rfc/rfc8446
- RFC 5280, Internet X.509 Public Key Infrastructure Certificate and CRL Profile: https://www.rfc-editor.org/rfc/rfc5280
- RFC 8555, Automatic Certificate Management Environment (ACME): https://www.rfc-editor.org/rfc/rfc8555
- RFC 6066, TLS Extensions (SNI): https://www.rfc-editor.org/rfc/rfc6066
- RFC 6962, Certificate Transparency: https://www.rfc-editor.org/rfc/rfc6962
- RFC 8659, DNS Certification Authority Authorization (CAA): https://www.rfc-editor.org/rfc/rfc8659
- RFC 8996, Deprecating TLS 1.0 and TLS 1.1: https://www.rfc-editor.org/rfc/rfc8996
- RFC 7748, Elliptic Curves for Security (X25519): https://www.rfc-editor.org/rfc/rfc7748
- RFC 7239, Forwarded HTTP Extension: https://www.rfc-editor.org/rfc/rfc7239
- CA/Browser Forum, Baseline Requirements: https://cabforum.org/working-groups/server/baseline-requirements/
- DNSimple, SSL Certificate Validity Changes (2026–2029), resumo do ballot SC-081: https://support.dnsimple.com/articles/announcement-ssl-certificate-validity-changes/
- Let's Encrypt, Rate Limits: https://letsencrypt.org/docs/rate-limits/
- Let's Encrypt, DST Root CA X3 Expiration (September 2021): https://letsencrypt.org/docs/dst-root-ca-x3-expiration-september-2021/
- TechCrunch, Here's what caused yesterday's O2 and SoftBank outages (2018): https://techcrunch.com/2018/12/07/heres-what-caused-yesterdays-o2-and-softbank-outages
- Python, módulo `ssl`: https://docs.python.org/3/library/ssl.html
- Uvicorn, Settings: https://www.uvicorn.org/settings/
