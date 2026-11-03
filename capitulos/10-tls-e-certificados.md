# TLS e certificados

## Domingo, 3h12, ou a hora exata em que o fundador marcou o próprio funeral

Às 3h12 de um domingo, a API da Lastro estava perfeita: `201` com `Location`, `ETag` com aspas, CORS com `Vary: Origin`. E ninguém no planeta conseguia falar com ela, porque um arquivo de texto de 2 KB tinha passado da validade, igual iogurte.

O certificado TLS de `api.lastro.com.br` foi comprado pelo fundador, à mão, num sábado de madrugada, depois de uma pizza. Validade de um ano. Um ano depois de um sábado cai num domingo:

```text
$ openssl x509 -in api.lastro.com.br.crt -noout -subject -dates
subject=CN = api.lastro.com.br
notBefore=Nov  1 06:12:44 2025 GMT
notAfter=Nov  1 06:12:44 2026 GMT
```

São 6h12 em GMT, 3h12 em Brasília. O certificado morreu em inglês, sem velório. Quando `api-01` nasceu (capítulo 8), o Carlos copiou para ele o mesmo arquivo e a mesma chave privada, e as duas máquinas morreram no mesmo segundo, com a sincronia que nenhum cluster da Lastro jamais teve. Cada cliente recebeu:

```text
httpx.ConnectError: [SSL: CERTIFICATE_VERIFY_FAILED]
  certificate verify failed: certificate has expired
```

O Bazar abriu chamado às 3h14, assunto "URGENTE!!!!", com um print do navegador: "Sua conexão não é particular". Pior: o banco parceiro, que notifica cada Pix recebido chamando `api.lastro.com.br`, recusou o certificado três vezes e desistiu. O dinheiro chegava e a Lastro não sabia. Uma fintech que recebe dinheiro sem saber é, juridicamente, um cofrinho.

A conta da autoridade certificadora estava no e-mail pessoal do fundador, com MFA no celular dele, em modo avião. Às 5h47 o Carlos emitiu um certificado pela Let's Encrypt em `api-01` e copiou para `temp-01`, chave junto, reincidente em menos de três horas. Saldo: 2h35 fora, 214 cobranças não criadas e 61 Pix pagos sem notificação, que o financeiro conciliou à mão, de novo, agora com a calma de quem já não sente nada.

Na segunda, o fundador disse: "no meu tempo o certificado durava três anos". É verdade: até 2018 valia até 39 meses, e ele perderia o vencimento do mesmo jeito, só que com menos frequência. A pergunta: o que esse arquivo faz em cada conexão, e como tirar o vencimento das mãos de qualquer ser humano, principalmente desse?

## O que o TLS garante, em três propriedades e nenhuma a mais

O TLS (versão 1.3 na RFC 8446) fica entre o TCP e o HTTP e entrega três coisas sobre um canal que qualquer roteador pode ler e alterar:

- **Confidencialidade:** só as duas pontas leem os dados.
- **Integridade:** qualquer byte alterado no caminho é detectado e a conexão cai.
- **Autenticação do servidor:** prova criptográfica de que o outro lado tem a chave privada de um certificado válido para `api.lastro.com.br`. Opcionalmente, o cliente também se autentica (mTLS, mais adiante).

E só. O cadeado garante que você fala em particular com alguém, sem dizer se esse alguém é honesto. Golpista também tem cadeado, e o dele está em dia.

Os dados viajam em *records* cifrados com AEAD, que cifra e autentica ao mesmo tempo. O TLS 1.3 aceita cinco *cipher suites*, todas AEAD; o 1.2 aceitava centenas, algumas ensinando o atacante a decifrar o tráfego. O 1.0 e o 1.1 foram aposentados pela RFC 8996 e seguem vivos em servidor de prefeitura, de pijama.

## O handshake do TLS 1.3, ou dois estranhos combinando um segredo em voz alta numa praça

As duas pontas precisam de chaves de sessão que ninguém conheça, trocando mensagens que todo mundo vê. A ferramenta é o Diffie-Hellman efêmero (ECDHE): cada lado gera um par de chaves descartável, envia a parte pública e combina a própria privada com a pública do outro. Os dois chegam ao mesmo segredo; quem só viu as públicas não chega.

```text
Cliente                                              Servidor
ClientHello
  + key_share (X25519, pública do cliente)
  + server_name: api.lastro.com.br   (SNI)
  + alpn: h2, http/1.1
  + signature_algorithms
                         ───────────────►
                                              ServerHello
                                                + key_share (pública do servidor)
                                              {EncryptedExtensions: alpn=h2}
                                              {Certificate}
                                              {CertificateVerify}
                                              {Finished}
                         ◄───────────────
{Finished}
[GET /v1/cobrancas/... ]  ───────────────►    (1 RTT e o HTTP já vai junto)
```

As mensagens entre `{}` já vão cifradas. Passo a passo:

1. O **ClientHello** já leva a parte pública do ECDHE, apostando no grupo que o servidor vai aceitar (quase sempre X25519). Aposta errada, o servidor pede outra com `HelloRetryRequest`, e lá se vai mais um RTT.
2. O **ServerHello** traz a parte pública do servidor. Os dois derivam as chaves com HKDF, e tudo o que segue é cifrado.
3. **Certificate** manda a cadeia. **CertificateVerify** é uma assinatura, com a chave privada do certificado, sobre o hash de todas as mensagens até ali: a prova de que o servidor tem a chave, e não só o certificado, que é público e qualquer um baixa.
4. **Finished** é um HMAC sobre o histórico inteiro. Se alguém no caminho rebaixou a versão ou mexeu na lista de algoritmos, os hashes não batem e a conexão morre.

Uma ida e volta, contra duas do TLS 1.2: o RTT que o capítulo 8 cobrou do Hornero, enfim explicado.

A chave privada do certificado só assina; nunca cifra as chaves de sessão. Isso é **forward secrecy**: quem gravar o tráfego da Lastro hoje e roubar a chave daqui a dois anos não decifra nada, porque as chaves ECDHE de cada conexão já foram jogadas fora. No TLS 1.2 com troca de chaves RSA, a chave roubada abria todo o arquivo gravado, de trás pra frente. O 1.3 removeu essa opção, a primeira vez na história que um comitê de padronização apagou alguma coisa.

A retomada de sessão usa um *ticket* de conexão anterior e permite dados no primeiro voo, o 0-RTT, que um atacante pode gravar e reenviar: a mesma cobrança, duas vezes, com criptografia impecável. A Lastro recusou o 0-RTT no capítulo 8, e o vendedor 42 ficou ofendido de não ser consultado.

## O certificado, um documento que só vale porque alguém que você nunca viu assinou

Um certificado X.509 (RFC 5280) é uma estrutura assinada que liga uma chave pública a nomes. Os campos que derrubam produção:

- **Subject Alternative Name (SAN):** os nomes DNS para os quais o certificado vale; o cliente compara o nome que pediu com essa lista (RFC 9525). O `CN` do subject é ignorado pelos navegadores e segue preenchido por tradição, igual campo "fax" em formulário.
- **Validade:** `notBefore` e `notAfter`, em UTC. Fora disso, lixo.
- **Chave pública** e **assinatura do emissor** sobre tudo isso.
- **Extensões:** `basicConstraints` (pode assinar outros certificados?) e `extendedKeyUsage` (`serverAuth`, `clientAuth`).

Um curinga `*.lastro.com.br` cobre um nível: `api.lastro.com.br` sim, `x.api.lastro.com.br` e `lastro.com.br` não. Cobertura no padrão do plano de saúde do Carlos.

## Cadeia de confiança, ou o golpe da pirâmide que funciona

Ninguém confia no certificado da Lastro. O cliente confia em **raízes**: certificados autoassinados de autoridades certificadoras (CAs), no *trust store* do sistema, do navegador ou, em Python, do pacote `certifi`. A raiz fica offline e assina **intermediárias**, que assinam o certificado do servidor (a folha).

```text
ISRG Root X1        (no trust store do cliente; o servidor não envia)
  └── E7            (intermediária; o servidor ENVIA)
        └── api.lastro.com.br   (folha; o servidor envia)
```

Validar é subir a cadeia: assinaturas conferem com a chave de cima, todos no prazo, os de cima com `basicConstraints CA:TRUE`, o nome no SAN da folha, o caminho terminando numa raiz confiável. Um elo podre e a conexão cai.

As regras do CA/Browser Forum encurtam a vida do certificado em escada: no máximo 200 dias a partir de 15 de março de 2026, 100 a partir de março de 2027 e 47 a partir de março de 2029. O certificado de um ano do fundador nasceu pouco antes da lei, como quase tudo que o fundador fez. Em 2029, quem renova à mão renova mais vezes do que corta o cabelo.

**Revogação.** Chave vazada, a CA revoga e publica em CRLs (listas assinadas) ou responde por OCSP (consulta online). Navegadores tratam falha de OCSP como "deixa passar", e quem bloqueia a consulta anula a revogação; a Let's Encrypt desligou seu OCSP em agosto de 2025. A revogação que funciona é o certificado curto: morre de causas naturais antes que alguém precise matá-lo.

**Certificate Transparency.** Toda CA confiável publica cada certificado em logs públicos append-only (RFC 6962). Dá para monitorar quem emitiu para o seu domínio, e todo nome com certificado público fica público para sempre. Se o Carlos emitir um certificado para `banco-legado-nao-mexer.lastro.com.br`, o atacante recebe o convite com endereço. O registro DNS **CAA** (RFC 8659) lista as CAs autorizadas a emitir para o domínio, e elas são obrigadas a conferir.

## SNI e terminação TLS, ou onde a criptografia acaba e a confiança começa

Um IP, vários nomes, e o `Host` só chega depois do handshake. O **SNI** (RFC 6066) põe o nome pedido no ClientHello, em claro: o caminho inteiro vê que você acessou `api.lastro.com.br`, só não vê o quê. A **ALPN** (RFC 7301), no mesmo ClientHello, negocia `h2` ou `http/1.1`; foi por ela que a Lastro chegou ao HTTP/2 com o adquirente no capítulo 9.

**Terminar TLS** é decidir onde a conexão cifrada acaba:

| Arranjo | Quem guarda a chave | Custo |
|---------|---------------------|-------|
| No servidor de aplicação | cada processo | trocar certificado = recarregar a aplicação |
| No proxy | só o proxy | atrás dele, HTTP em claro; o trecho precisa ser confiável |
| Proxy re-cifra | proxy e backend | dois handshakes, dois certificados |
| *Passthrough* pelo SNI | só o backend | o proxy não lê HTTP nem roteia por caminho |

Terminando no proxy, a aplicação perde o IP do cliente e o esquema; o proxy repassa em `X-Forwarded-For` e `X-Forwarded-Proto` (ou `Forwarded`, RFC 7239), e a aplicação só acredita neles vindos do proxy. Acreditar em `X-Forwarded-For` de qualquer um é deixar o suspeito preencher o próprio boletim de ocorrência.

## ACME, o robô que não esquece aniversário

O ACME (RFC 8555) é o protocolo com que um cliente pede certificado, prova controle do domínio e recebe a cadeia sem humano no caminho. Let's Encrypt e Google Trust Services são exemplos de CAs que o falam.

1. O cliente registra uma conta, identificada por um par de chaves próprio, e cria uma **ordem** para os nomes; a CA devolve uma **autorização** por nome, com desafios.
2. O cliente cumpre um **desafio**:
   - **HTTP-01:** servir um token em `/.well-known/acme-challenge/<token>` na porta 80; a CA resolve o DNS e busca.
   - **DNS-01:** publicar um TXT em `_acme-challenge.<nome>`. Único que emite curinga; exige credencial de DNS.
   - **TLS-ALPN-01** (RFC 8737): responder na 443 com um certificado especial, pela ALPN `acme-tls/1`.
3. Com a autorização válida, o cliente envia um CSR (a chave pública, assinada pela privada) e baixa a cadeia.

O cliente renova sozinho, em geral com um terço da validade restante (aos 60 dias num certificado de 90); a extensão ARI deixa a CA antecipar a janela quando precisa revogar em massa. A chave não sai da máquina, ninguém compra nada e ninguém precisa do celular do fundador.

## mTLS, quando o servidor também pede documento

No **mTLS** (*mutual TLS*), o servidor manda `CertificateRequest` no handshake, e o cliente responde com o próprio `Certificate` e um `CertificateVerify`, assinando o histórico com a sua chave privada. O servidor valida a cadeia do cliente contra as CAs que **ele** escolhe, quase sempre uma CA privada, e a identidade do cliente passa a ser o subject ou o SAN do certificado, provada antes do primeiro byte de HTTP.

Uma chave de API trafega em cada requisição e vaza no log que a imprimir; a chave do mTLS nunca sai da máquina. O custo é operar certificados de cliente com prazos do parceiro. É a relação em que os dois exigem exame antes, e alguém sempre esquece de renovar o exame.

## Na Lastro: o vencimento sai das mãos humanas

**Requisitos.** Pix 24x7 (capítulo 7): troca de certificado sem janela. Duas máquinas respondem por `api.lastro.com.br`: `api-01`, alvo do DNS, e `temp-01`, com a integração do Bazar que resolveu o DNS há 200 dias (capítulo 8). E o banco parceiro avisou, por ofício, que sua API Pix exige mTLS em 60 dias.

**Terminação.** Hoje o Uvicorn termina TLS, e trocar certificado é reiniciar os workers. A Lastro põe um proxy reverso em cada máquina (nginx e Caddy são exemplos) na porta 443, falando HTTP com o Uvicorn em `127.0.0.1:8000`; o Uvicorn aceita `X-Forwarded-*` só de `127.0.0.1`. O proxy recarrega certificado sem derrubar conexão e oferece `h2` pela ALPN, o HTTP/2 na borda que o capítulo 9 deixou pendente. TLS 1.3 e 1.2 (só ECDHE e AEAD, porque um marketplace ainda chega em 1.2); 1.0 e 1.1 desligados. Um balanceador gerenciado, com certificado gerenciado, dispensaria o proxy e é a escolha quando houver balanceador (capítulo 27).

**Emissão.** O HTTP-01 só alcança a máquina para onde o DNS aponta, e `temp-01` ficaria sem certificado, com o Bazar dentro. Por isso, DNS-01 nas duas máquinas, cada uma com **sua própria chave** e seu certificado. O risco do DNS-01 é a credencial: quem edita a zona aponta `api.lastro.com.br` para onde quiser. A Lastro delega o desafio para uma zona que só contém desafios:

```text
api.lastro.com.br.                  300  IN A      203.0.113.10
_acme-challenge.api.lastro.com.br.  300  IN CNAME  api.desafios-acme.lastro.com.br.
lastro.com.br.                     3600  IN CAA    0 issue "letsencrypt.org"
lastro.com.br.                     3600  IN CAA    0 issue "pki.goog"
lastro.com.br.                     3600  IN CAA    0 iodef "mailto:seguranca@lastro.com.br"
```

A credencial das máquinas só escreve em `desafios-acme.lastro.com.br`: se vazar, o atacante publica TXT, e só. O CAA autoriza duas CAs, para a segunda emitir se a primeira estiver fora. Chave ECDSA P-256, certificado de 90 dias, renovação aos 60.

**Vigilância.** Automação que falha em silêncio é só um vencimento com etapas. Um verificador externo conecta uma vez por dia nos dois IPs, com SNI, e lê o certificado **servido** (o arquivo no disco pode estar renovado e o proxy, sem recarregar). Alerta abaixo de 21 dias: nove dias seguidos de renovação quebrada. Um monitor de Certificate Transparency avisa de todo certificado novo para `lastro.com.br`, inclusive os que ninguém pediu.

**mTLS com o banco parceiro.** Em duas direções, com dois nomes no mesmo IP, separados pelo SNI e ambos no SAN do certificado ACME de `api-01`:

```text
                    ┌──────────────── api-01 (203.0.113.10) ───────────────┐
marketplaces ──TLS──┼► proxy :443  SNI api.lastro.com.br                   │
                    │     cert ACME próprio, sem cert de cliente           │
banco parceiro ─mTLS┼► proxy :443  SNI webhooks-pix.lastro.com.br          │
  (notifica Pix)    │     exige cert de cliente da CA do banco             │
                    │        │ HTTP 127.0.0.1:8000                         │
                    │        ▼                                             │
                    │     Uvicorn ×3 ──mTLS (cert cliente api-01)──────────┼─► API Pix do banco
                    └──────────────────────────────────────────────────────┘
temp-01 (198.51.100.7): mesmo proxy p/ api.lastro.com.br, cert ACME próprio;
  repasse_final_v2_agora_vai.py ──mTLS (cert cliente temp-01)──► API Pix do banco
```

Para chamar o banco, cada máquina gera seu par de chaves, manda um CSR pelo portal e recebe um certificado de cliente assinado pela CA privada do banco, válido por um ano. A chave fica em arquivo `0600`, legível só pelo usuário do serviço, e nunca sai da máquina (KMS no capítulo 33). Sem ACME, a renovação é manual: o verificador acompanha esses certificados com alertas a 60, 30 e 14 dias, e a troca tem sobreposição, com o banco aceitando o novo antes de o velho morrer.

Na outra direção, as notificações de Pix passam para `webhooks-pix.lastro.com.br`, onde o proxy exige certificado de cliente e confia só na CA do banco. O proxy repassa o subject verificado num cabeçalho e **apaga** qualquer cabeçalho de mesmo nome vindo de fora; a aplicação só aceita o subject do banco. Sem isso, qualquer um mandaria um "Pix recebido de R$ 50.000,00" com um `curl`, e a Lastro creditaria com a maior boa vontade. Exigir mTLS dos marketplaces é decisão de autenticação (capítulo 30).

## Armadilhas e casos reais

> **Na vida real:** em 6 de dezembro de 2018, um certificado vencido no software SGSN-MME da Ericsson derrubou operadoras em 11 países; cerca de 30 milhões de clientes da O2, no Reino Unido, ficaram quase um dia sem serviço. Ninguém atacou nada. O calendário atacou sozinho, e calendário não tem CVE.

> **Na vida real:** em 30 de setembro de 2021 venceu a raiz DST Root CA X3, que assinava em cadeia cruzada os certificados da Let's Encrypt. Clientes com OpenSSL 1.0.x falharam mesmo confiando na raiz nova, por uma peculiaridade na construção do caminho: APIs, IoT, o servidor esquecido no canto. Toda empresa tem um. A Lastro deu nome ao dela.

> **Armadilha:** a intermediária que não foi enviada. O Chrome completa a cadeia buscando a intermediária pela URL do certificado e tudo "funciona"; o cliente Python, sobre o OpenSSL, não busca e falha com `unable to get local issuer certificate`. O dev abre no navegador e fecha o chamado. O marketplace reabre. Os dois envelhecem.

> **Armadilha:** `verify=False` para "resolver" erro de certificado. A conexão segue cifrada, só que até o atacante no meio, que decifra, lê e cifra de novo. Camisinha com furo de fábrica. O Carlos usou na madrugada do incidente, no script de reenvio de notificações, e o código está em revisão, com o Carlos dentro.
## Resumo

- TLS: confidencialidade, integridade, autenticação do servidor. TLS 1.3 em 1 RTT, ECDHE com forward secrecy, só AEAD; 0-RTT sujeito a replay.
- Certificado: nomes no SAN, validade em UTC, chave pública, assinatura do emissor. Cadeia até uma raiz do trust store; o servidor envia as intermediárias.
- Revogação é frágil; validade curta é a que funciona. CT publica todo certificado; CAA limita as CAs.
- SNI escolhe o certificado, ALPN o protocolo. Terminação no proxy exige confiar em `X-Forwarded-*` só vindo dele.
- ACME automatiza emissão e renovação (HTTP-01, DNS-01, TLS-ALPN-01); monitora-se o certificado servido.
- mTLS autentica o cliente por certificado, contra a CA que o servidor escolhe.

## A Lastro agora

Cada máquina tem um proxy na 443 terminando TLS 1.3 e 1.2, com HTTP/2 para os marketplaces e o Uvicorn escondido em `127.0.0.1`. Os certificados de `api.lastro.com.br` vêm por ACME com DNS-01 delegado, um por máquina, 90 dias, renovados aos 60, duas CAs no CAA e alerta externo com 21 dias. Com o banco parceiro, mTLS nas duas direções: certificados de cliente de um ano em `api-01` e `temp-01`, alertas a 60, 30 e 14 dias, e notificações de Pix em `webhooks-pix.lastro.com.br`. O certificado do fundador foi revogado e mora num pendrive na gaveta dele, etiquetado "backup".

O fundador perguntou se agora o certificado "nunca mais vence". Vence a cada 90 dias, só que sem plateia. Enquanto isso, o gerente de produto mandou incluir na resposta da cobrança um campo novo, `parcelas_detalhe`, porque "é só um campo, quem não usa ignora". O desserializador do Bazar não ignora nada, e o próximo "URGENTE!!!!" vai chegar por uma conexão impecável: TLS 1.3, forward secrecy, certificado válido por mais 89 dias e um JSON que o Bazar se recusa a ler.

## Referências

- RFC 8446, *The Transport Layer Security (TLS) Protocol Version 1.3*. <https://www.rfc-editor.org/rfc/rfc8446>
- RFC 5280, *Internet X.509 Public Key Infrastructure Certificate and CRL Profile*. <https://www.rfc-editor.org/rfc/rfc5280>
- RFC 9525, *Service Identity in TLS*. <https://www.rfc-editor.org/rfc/rfc9525>
- RFC 6066, *TLS Extensions* (SNI). <https://www.rfc-editor.org/rfc/rfc6066>
- RFC 7301, *TLS Application-Layer Protocol Negotiation Extension*. <https://www.rfc-editor.org/rfc/rfc7301>
- RFC 6962, *Certificate Transparency*. <https://www.rfc-editor.org/rfc/rfc6962>
- RFC 8659, *DNS Certification Authority Authorization (CAA) Resource Record*. <https://www.rfc-editor.org/rfc/rfc8659>
- RFC 8555, *Automatic Certificate Management Environment (ACME)*. <https://www.rfc-editor.org/rfc/rfc8555>
- CA/Browser Forum, *Baseline Requirements*. <https://cabforum.org/working-groups/server/baseline-requirements/requirements/>
- Let's Encrypt, "Ending OCSP Support in 2025". <https://letsencrypt.org/2024/12/05/ending-ocsp/>
- Let's Encrypt, "DST Root CA X3 Expiration (September 2021)". <https://letsencrypt.org/docs/dst-root-ca-x3-expiration-september-2021/>
- TechCrunch, "Here's what caused yesterday's O2 and SoftBank outages" (2018). <https://techcrunch.com/2018/12/07/heres-what-caused-yesterdays-o2-and-softbank-outages>
