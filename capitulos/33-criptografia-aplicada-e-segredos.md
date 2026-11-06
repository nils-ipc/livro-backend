# Criptografia aplicada e segredos

O Carlos foi procurar um token roubado nos logs e achou um cartão de crédito. Depois outro. Quando parou de contar, eram 318 mil autorizações de 204 mil cartões, com número, validade e nome, em texto puro, num bucket que toda máquina da Lastro lia até a semana passada.

A linha vinha do `conector-adquirente`: um `logger.debug(corpo)` ligado na Black Friday "só pra ver o que o adquirente estava recebendo". O adquirente estava recebendo cartões. O bucket também. O CVV escapou porque o log cortava o campo, o único acerto do sistema, cometido sem querer por uma biblioteca.

O PCI DSS, o padrão de segurança da indústria de cartões, cobre todo sistema que armazena, processa ou transmite dados de cartão e todo sistema conectado a eles. O número do cartão (PAN, *primary account number*) passava pelo gateway, por pagamentos, pelo conector, pelo coletor de logs e pelo bucket: o escopo da auditoria virou quase a Lastro inteira, `temp-01` incluído. O auditor pediu o inventário de software do `temp-01`. O fundador mandou uma foto do monitor.

Como guardar e transportar o que não pode vazar, para que o vazamento entregue só lixo?

## Hash de senha, ou a arte de ser lento de propósito

Senha não se guarda, nem cifrada: guarda-se um hash, e o login compara hashes. Cifrar senha significa existir uma chave que devolve todas elas, morando no mesmo servidor, numa variável chamada `CHAVE_SENHAS`.

Mas não qualquer hash. Uma GPU de jogo calcula SHA-256 na casa das dezenas de bilhões por segundo, e todas as variações de `Capinha@2024` caem antes do café esfriar. Hash de senha usa **sal** aleatório por usuário (os milhões de `123456` ficam diferentes e tabela pré-calculada morre), **custo de tempo** ajustável e **custo de memória**, porque GPU tem milhares de núcleos e pouca RAM por núcleo.

O **bcrypt** (1999) tem custo exponencial (`cost` 12 = 2^12 rodadas) e uma surpresa: só os primeiros 72 bytes da senha contam. O **Argon2id** venceu a Password Hashing Competition em 2015, está na RFC 9106 e tem três parâmetros: memória `m`, passadas `t`, paralelismo `p`. A RFC sugere `m` = 64 MiB, `t` = 3, `p` = 4 para pouca memória; o mínimo da OWASP é `m` = 19 MiB, `t` = 2, `p` = 1. É a primeira função da história projetada para ser lenta e gorda de propósito, e o fundador se sentiu representado. O resultado carrega tudo:

```text
$argon2id$v=19$m=65536,t=3,p=4$Wm9yM2tOcFhxQmM0ZE1aVw$q8H3vYp0mK2tR7sLxN4cWbE9jF1uGzAiDoSeTkQhVnU
          versão  parâmetros     sal (base64)          hash (base64)
```

Subir o custo é gradual: cada login bem-sucedido regrava com os parâmetros novos. Existe ainda a **pimenta** (*pepper*), um segredo fora do banco aplicado como HMAC antes do hash: se só o banco vazar, nenhum hash é atacável. Sim, hash de senha leva sal e pimenta. O Carlos perguntou se tinha sobremesa, e a resposta é o Argon2, que leva 64 MiB e meia hora de explicação.

## AES-GCM, ou cifrar sem autenticar é deixar a porta encostada

Dado que precisa voltar a ser lido, como o PAN na hora de autorizar, usa criptografia simétrica: AES (FIPS 197), chave de 256 bits. Quem decide se presta é o **modo de operação**. O ECB cifra cada bloco de 16 bytes isoladamente, e blocos iguais viram cifras iguais: o pinguim do Linux cifrado em ECB continua um pinguim, exposto na Wikipédia há anos como réu primário. CBC e CTR escondem padrão, mas não detectam adulteração: em CTR, inverter um bit da cifra inverte o mesmo bit do texto, e o atacante muda um valor sem saber a chave.

Daí o **AEAD** (*authenticated encryption with associated data*), o mesmo do TLS 1.3 (capítulo 10). O **AES-GCM** (NIST SP 800-38D) cifra em modo contador e calcula uma etiqueta de 128 bits sobre a cifra e os **dados associados** (AAD), um contexto público amarrado à mensagem. Um bit alterado em qualquer dos dois e a decifração falha inteira:

```python
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

aes = AESGCM(AESGCM.generate_key(bit_length=256))
nonce = os.urandom(12)                                  # 96 bits, nunca repetir
cifra = aes.encrypt(nonce, b"4111111111111111", b"tok_7Hq2")
aes.decrypt(nonce, cifra, b"tok_9Xz1")                  # AAD de outro registro
```

```text
cryptography.exceptions.InvalidTag
```

O AAD é o identificador do registro: quem copia no banco a cifra do cartão A para a linha do cartão B ganha um `InvalidTag`. Sem AAD, o sistema decifraria feliz o cartão errado para a cobrança errada.

O preço do GCM é o *nonce*, 96 bits que nunca se repetem com a mesma chave. O nome é *number used once*, a especificação inteira cabe no nome, e mesmo assim tem gente que usa duas vezes. Nonce repetido entrega o XOR dos dois textos e a chave de autenticação, com a qual o atacante forja mensagens. Com nonce aleatório, a SP 800-38D limita a 2^32 cifragens por chave; com contador, basta um processo reiniciar e recomeçar do zero, coisa que processos fazem toda vez que o kernel os mata. O ChaCha20-Poly1305 (RFC 8439) é o AEAD alternativo, com a mesma regra.

## Assimétrica e assinaturas, ou a chave que pode ir para o outdoor

Na assimétrica, a privada fica guardada e a pública pode ir para um outdoor. Ela serve para **troca de chaves** (o ECDH do capítulo 10) e para **assinatura**: só a privada assina, qualquer um verifica, e o verificador não ganha poder de assinar. Dado grande não se cifra com ela, lenta e limitada em tamanho: ela protege uma chave simétrica, que carrega o peso. Ed25519 (RFC 8032) e ECDSA P-256 são as opções comuns. O ECDSA tem a fragilidade do GCM com outro nome: cada assinatura usa um número secreto `k`, e dois `k` iguais revelam a chave privada com álgebra de ensino médio. O Ed25519 deriva o `k` da própria mensagem e protege o engenheiro de si mesmo, que é o único inimigo que nunca tira férias.

## HMAC, ou como provar que foi você sem mostrar o RG

Com segredo compartilhado, assinatura assimétrica é exagero. O **HMAC** (RFC 2104) é `H((K ⊕ opad) ‖ H((K ⊕ ipad) ‖ m))`: só quem tem `K` produz o código de `m`. Os dois níveis têm motivo: o ingênuo `SHA-256(segredo ‖ m)` sofre *length extension*, e quem conhece esse hash calcula o de `segredo ‖ m ‖ enchimento ‖ qualquer_coisa` sem saber o segredo. Em 2009, Thai Duong e Juliano Rizzo forjaram assim assinaturas da API do Flickr, que usava MD5 nesse formato. O atacante assinou embaixo do que o Flickr tinha assinado, e o Flickr reconheceu firma.

A comparação é em tempo constante (`hmac.compare_digest`): o `==` para no primeiro byte diferente, e medindo milhões de respostas o atacante acha o código byte a byte. É lento e chato, como todo ataque que funciona.

Hash com chave também identifica um cartão sem guardar o número. O `SHA-256(PAN)` parece anônimo até a conta:

```text
PAN de 16 dígitos  = BIN (6) + conta (9) + verificador Luhn (1)
painel mostra      = BIN + 4 últimos   (o máximo que o PCI DSS permite exibir)
falta descobrir    = 6 dígitos, e o Luhn elimina 9 em cada 10 candidatos
tentativas         = 100.000 SHA-256 por cartão  →  milissegundos numa CPU
```

Hash sem chave de espaço pequeno é só um jeito demorado de escrever o número, com mais etapas e o mesmo crime. Por isso o PCI DSS 4.0 exige hash de PAN com chave: HMAC com uma chave que o atacante não tem.

## Envelope encryption e KMS, ou chave dentro de chave dentro de caixa

Cifrar desloca o problema para a chave. Chave num arquivo ao lado do banco: o atacante leva os dois e agradece.

Um **KMS** (*key management service*; o AWS KMS e o Cloud KMS do Google são exemplos) guarda chaves mestras em HSMs (*hardware security modules*) e nunca as exporta; cada operação passa por política e entra na auditoria. Como ele limita taxa e custa uma ida e volta de rede, a **envelope encryption** tira o volume de dentro dele:

1. A aplicação pede uma **chave de dados** (DEK) e recebe a DEK em claro e a DEK cifrada pela **chave mestra** (KEK).
2. Cifra localmente com a DEK, guarda a DEK cifrada ao lado e descarta a DEK em claro.
3. Para ler, manda a DEK cifrada ao KMS e decifra localmente com o que voltar.

Quem rouba o banco leva lixo. Rotacionar a KEK recifra as DEKs (kilobytes), e não os dados (terabytes). Apagar uma DEK torna ilegível tudo o que ela cifrou: o *crypto-shredding* prometido no capítulo 21. A chave mestra é a única coisa na Lastro que nunca saiu de casa, nem para uma reunião de alinhamento.

## Segredos, ou onde a senha do banco passa as noites

Segredo no repositório deu o capítulo 30. Em variável de ambiente, é herdado por todo processo filho, legível em `/proc/<pid>/environ` pelo mesmo usuário e despachado junto no relatório de erro que "manda o ambiente para ajudar a depurar". O lugar dele é um **gerenciador de segredos** (o HashiCorp Vault ou o serviço equivalente do provedor): o processo se autentica com a identidade da máquina (o papel do capítulo 32, sem "segredo zero" em disco), recebe o segredo na partida, guarda em memória, e cada leitura fica auditada.

Rotação é o que todo mundo adia, porque trocar a senha do banco com 60 processos conectados derruba alguma coisa. O padrão sem queda é o das chaves de API do capítulo 30, duas credenciais válidas: os processos usam o usuário A, a rotação troca a senha do B, espera todos relerem e só então troca a do A. Gerenciadores mais completos emitem **segredos dinâmicos**, um usuário criado na hora para aquele processo e apagado no prazo. Segredo vencido que vaza vale o mesmo que cupom de pizzaria de 2019.

## Tokenização, ou o cartão no programa de proteção a testemunhas

**Tokenização** troca o dado sensível por um substituto aleatório: nenhuma conta leva do token ao PAN, e o único caminho é perguntar a um **cofre**, que guarda o mapeamento para o PAN cifrado e só responde a quem tem autorização. PAN cifrado continua sendo dado de cartão, e quem alcança a cifra e a chave fica no escopo; token fora do cofre é só uma string, e quem só vê token sai da auditoria. (Token com formato preservado, por cifra FPE do NIST SP 800-38G, traz a chave de volta ao escopo.)

Duas regras do PCI DSS 4.0 completam o quadro: dado de autenticação sensível (CVV, trilha, PIN) não pode ser guardado depois da autorização, nem cifrado; e o PAN exibido mostra no máximo o BIN e os quatro últimos dígitos. O cartão entra no programa de proteção a testemunhas, ganha nome novo, e quem pergunta pelo nome antigo precisa de crachá.

## Na Lastro: o cofre, a fronteira e o resto do lixo

Primeiro, a limpeza: no bucket versionado, apagar criou só marcadores de exclusão, e as versões antigas saíram uma a uma, depois o índice do coletor e o backup semanal. A resposta seguiu o plano combinado com o adquirente, que fala com as bandeiras. O vendedor 42 achou o próprio cartão na amostra: tinha comprado capinha de si mesmo para testar o saque.

As alternativas para o cartão:

| Opção | O que fica no escopo da Lastro | Cartão salvo | Troca de adquirente | Custo principal |
|---|---|---|---|---|
| Repassar sem guardar | gateway, pagamentos, conector, logs | não | sem impacto | o escopo de hoje |
| Token do adquirente | página de captura e conector | sim | cartões ficam presos ao adquirente | dependência |
| Cofre de terceiro | quase nada | sim | sim | taxa por transação e uma ida e volta externa na autorização |
| Cofre próprio | cofre, conector, a entrada deles | sim | sim | operar um segmento auditado |

O contrato do Tuiuiú pede cartão salvo para recompra em um clique e cartões que sobrevivam a uma troca de adquirente, contingência que a Lastro precisa prever desde o bloqueio por IP do capítulo 29. Sobram as duas últimas linhas, e o cofre de terceiro põe uma chamada externa de 20 a 40 ms (hipótese) na folga de 120 ms do orçamento da autorização (capítulo 14), a 360 autorizações por segundo no pico. A Lastro fica com o **cofre próprio**. Com volume pequeno e sem equipe para operar um ambiente auditado, o de terceiro seria o certo.

```text
navegador do comprador
  ├─ página do marketplace + checkout da Lastro (capítulo 22)
  │     └─ iframe cofre.lastro.com.br ──TLS──┐
  │                                           ▼
  │           ┌──────────── segmento de dados de cartão ─────────────┐
  │           │ entrada própria ─► cofre ×3 ─► pg-cofre              │
  │           │                      │  └─► KMS (KEK, nunca sai)     │
  │           │                      ▲                               │
  │           │        conector-adquirente ──PAN──► adquirente       │
  │           └──────────────────────│────────────────────────────────┘
  └─ tok_... ─► gateway ─► pagamentos ─┘ (só token)
```

O formulário de cartão roda num iframe de `cofre.lastro.com.br`, com entrada e TLS próprios, fora do alcance dos scripts da página do marketplace (outra origem). Gateway, pagamentos, broker, logs e `temp-01` passam a ver `tok_` mais 128 bits aleatórios. O `temp-01` saiu do escopo: primeira auditoria em que ele passa, e foi por não comparecer.

No `pg-cofre`, cada cartão guarda PAN e validade cifrados com AES-256-GCM (token no AAD), a DEK cifrada, BIN, quatro últimos e `marketplace_id` com RLS (capítulo 31). Cada processo pede uma DEK por hora: a 360 cifragens por segundo, cerca de 1,3 milhão por chave, longe das 2^32. DEKs decifradas ficam 5 minutos em memória; a KEK rotaciona por ano no KMS, com as DEKs recifradas em lote. O CVV nunca toca disco: Redis exclusivo do cofre, sem persistência, cifrado, 10 minutos, apagado na autorização.

O `conector-adquirente` muda para máquinas próprias no segmento e, a cada autorização, troca o token pelo PAN no cofre, monta a requisição e esquece: 2 ms a mais, medidos em homologação, pagos pela folga. Do cofre saem dois HMAC do PAN com chaves diferentes: a **impressão**, que responde "este cartão já está salvo neste marketplace?", e o identificador do antifraude prometido no capítulo 25, para os contadores e o grafo. A chave do antifraude, que fica fora do segmento, rotaciona por ano com os dois identificadores em paralelo por 24 horas, o prazo dos contadores.

O resto da casa:

- **Webhooks**: o cabeçalho reservado no capítulo 11 virou `Lastro-Assinatura: t=1762352400,v1=<hex>`, HMAC-SHA256 sobre `t + "." + corpo bruto`, no formato que a Stripe usa. Segredo por inscrição, prefixo `lastro_whsec_` (varredura do capítulo 30), `t` aceito por 5 minutos, dois `v1` durante a rotação. Ed25519 seria o certo se alguém precisasse provar a terceiros quem assinou.
- **Senhas do painel** (capítulo 30): Argon2id `m` = 64 MiB, `t` = 3, `p` = 4, ~50 ms por login, semáforo de 4 cálculos por processo, porque 40 logins juntos pediriam 2,5 GiB.
- **Segredos**: gerenciador lido pela identidade da máquina; senhas dos bancos em pares A/B, rotação a cada 30 dias.
- **Logs**: mascaramento no logger e detector no coletor de 13 a 19 dígitos que passam no Luhn e caem numa faixa de BIN (capítulo 38).

E o arquivo do fundador: `/root/senhas.txt` no `temp-01`, cabeçalho "NÃO APAGAR (backup)", com a credencial do adquirente, a senha da conta do DNS (inclusive a zona ACME do capítulo 10) e uma chave permanente da conta da nuvem criada em 2019, a única identidade da Lastro com mais poder que o fundador. Tudo foi rotacionado. Ele ainda quis passar `shred`, que em SSD grava a sobrescrita noutro bloco físico e deixa o original, como a própria documentação avisa. O `shred` foi feito mesmo assim, como missa de sétimo dia.

## Armadilhas e casos reais

> **Na vida real:** em 2013, a Adobe vazou cerca de 150 milhões de registros com senhas cifradas em 3DES no modo ECB, sem sal, ao lado das dicas de senha em texto puro. Senhas iguais tinham cifras iguais, e a dica de um usuário entregava a senha de todos com a mesma cifra. O maior jogo de palavras cruzadas da história, com 150 milhões de jogadores involuntários.

> **Na vida real:** em dezembro de 2010, no 27C3, o grupo fail0verflow mostrou que a Sony assinava o software do PlayStation 3 com ECDSA usando o mesmo `k` em toda assinatura. Duas assinaturas bastaram para calcular a chave privada da plataforma. Um console inteiro protegido por uma constante.

> **Armadilha:** verificar a assinatura do webhook depois de desserializar e serializar o JSON de novo. Ordem e espaços mudam, o HMAC não bate, e a verificação é desligada "temporariamente". A consultoria Java do Bazar já pediu 8 horas para entender por que o HMAC só falha quando o nome do vendedor tem acento.

> **Armadilha:** criptografia caseira: CBC com HMAC "na ordem certa", nonce gerado com `random` em vez de `secrets`. Em criptografia, "eu mesmo implementei" vai para o boletim de ocorrência, e não para o currículo.

## Resumo

- Senha: hash lento com sal e custo de memória, Argon2id (RFC 9106) ou bcrypt (72 bytes); parâmetros no próprio hash.
- Simétrica é AEAD (AES-GCM, ChaCha20-Poly1305): AAD amarra o contexto, nonce nunca se repete.
- Assimétrica troca chaves e assina; `k` repetido no ECDSA entrega a chave privada.
- HMAC autentica com segredo compartilhado, sem length extension, comparado em tempo constante; hash sem chave de PAN é reversível.
- Envelope encryption: DEK local, KEK no KMS, rotação recifra só DEKs.
- Segredos num gerenciador, pela identidade da máquina, com rotação em pares.
- Tokenização tira do escopo do PCI DSS tudo o que só vê o token.

## A Lastro agora

O cartão entra por um iframe do cofre, vira `tok_` e só volta a ser número dentro do segmento, por 2 ms, no `conector-adquirente`. Os webhooks saem assinados e o escopo do PCI DSS caiu de quase tudo para quatro componentes. O financeiro comentou que a planilha tokeniza cartões desde o primeiro dia: chama todo mundo de "cliente do final 4421".

Para subir o conector nas máquinas novas, o Carlos fez o primeiro contêiner da Lastro, com o Python iniciado por um script de shell "só pra carregar os segredos". No primeiro deploy, o `docker stop` mandou o `SIGTERM` educado, o shell não repassou, e dez segundos depois veio o `SIGKILL` no meio de 31 autorizações. Na mesma tarde, o contêiner do painel sumiu sem uma linha de log: três workers, quatro Argon2id de 64 MiB cada, e um limite de memória de 512 MiB escolhido por segurança.

## Referências

- RFC 9106, *Argon2 Memory-Hard Function for Password Hashing and Proof-of-Work Applications*: https://www.rfc-editor.org/rfc/rfc9106
- OWASP, *Password Storage Cheat Sheet*: https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
- NIST SP 800-38D, *Galois/Counter Mode (GCM) and GMAC*: https://csrc.nist.gov/pubs/sp/800/38/d/final
- NIST SP 800-38G, *Methods for Format-Preserving Encryption*: https://csrc.nist.gov/pubs/sp/800/38/g/final
- RFC 8439, *ChaCha20 and Poly1305 for IETF Protocols*: https://www.rfc-editor.org/rfc/rfc8439
- RFC 8032, *Edwards-Curve Digital Signature Algorithm (EdDSA)*: https://www.rfc-editor.org/rfc/rfc8032
- RFC 2104, *HMAC: Keyed-Hashing for Message Authentication*: https://www.rfc-editor.org/rfc/rfc2104
- Documentação do `cryptography`, AEAD: https://cryptography.io/en/latest/hazmat/primitives/aead/
- Documentação do Python, módulo `hmac`: https://docs.python.org/3/library/hmac.html
- PCI Security Standards Council, PCI DSS v4.0.1 (biblioteca de documentos): https://www.pcisecuritystandards.org/document_library/
- Stripe, verificação de assinatura de webhooks: https://docs.stripe.com/webhooks
- T. Duong e J. Rizzo, *Flickr's API Signature Forgery Vulnerability* (2009).
- fail0verflow, *Console Hacking 2010*, 27C3 (dezembro de 2010).
- Análises públicas do vazamento da Adobe (2013), 3DES em modo ECB e dicas de senha.
