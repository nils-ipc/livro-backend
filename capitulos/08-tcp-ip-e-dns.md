# TCP/IP e DNS

O Mercadito Hornero mandou um gráfico. Cliente que manda gráfico já desistiu de ser educado e está montando o processo.

A linha de baixo é o processamento que a API da Lastro informa em cada resposta: 40 ms. A de cima é o que o cliente do Hornero mede para a mesma chamada: 340 ms. Trezentos milissegundos somem no caminho, e o Bazar Bem-te-vi, na mesma API, nunca reclamou. O Bazar reclama de tudo. Quando o Bazar não reclama, o problema existe só para os outros.

Na mesma reunião, o fundador anunciou que vai trocar `temp-01` por um servidor novo, `api-01`: "é só mudar o IP no DNS, coisa de cinco minutos". O Carlos concordou, e o financeiro começou a separar café para o fim de semana.

Para onde vão 300 ms que nenhum código da Lastro gasta, e por que "só mudar o IP no DNS" pode deixar o Pix parado por um dia inteiro?

## Camadas, ou como 300 bytes de JSON viajam com mais cabeçalho do que conteúdo

O `POST /v1/cobrancas` do Hornero sai como um JSON de 300 bytes e desce pelas quatro camadas do modelo TCP/IP, cada uma com seu cabeçalho: aplicação (HTTP, DNS; o TLS fica logo abaixo), transporte (TCP, UDP: dados entre processos), internet (IP: pacotes entre máquinas) e enlace (Ethernet: quadros entre vizinhos). O modelo OSI tem sete; as camadas 5 e 6 só existem em entrevista de emprego, onde ninguém lembra o nome delas e todo mundo finge.

Um quadro Ethernet carrega até 1.500 bytes de pacote IP (a *MTU*). Tirando 20 bytes de cabeçalho IPv4 e 20 de TCP, sobram 1.460 de dados por segmento (o *MSS*). Os 300 bytes do Hornero cabem num segmento só, com folga para mais quatro JSONs e um pedido de desculpas.

## IP, portas e o endereço que ninguém tem de verdade

O IP entrega pacotes entre endereços em regime de *best effort*: o pacote pode se perder, duplicar ou chegar fora de ordem, e o IP não pede desculpa por nenhum dos três. Cada roteador decrementa o campo TTL do pacote (*hop limit* no IPv6); em zero, o pacote é descartado e a origem recebe um ICMP *Time Exceeded*. O `traceroute` manda pacotes com TTL 1, 2, 3 e anota quem assinou cada atestado de óbito. O DNS tem outro TTL, que mata registro em vez de pacote; os dois se encontram neste capítulo.

O IPv4 tem 32 bits, uns 4,3 bilhões de endereços, e o estoque central da IANA acabou em 2011. O IPv6 tem 128 bits, o suficiente para o Carlos criar ambientes de teste até a morte térmica do universo sem apagar nenhum.

Faixas se escrevem em **CIDR**: endereço e quantos bits iniciais formam o prefixo. `10.0.1.0/24` deixa 8 bits livres, 256 endereços; `/32` é um endereço só, a notação que todo firewall de parceiro pede. O fundador uma vez sugeriu ao banco liberar `0.0.0.0/0` "pra simplificar". É a internet inteira. O banco respondeu com um silêncio que durou duas semanas e uma auditoria.

A RFC 1918 reserva três faixas **privadas**, que a internet não roteia: `10.0.0.0/8`, `172.16.0.0/12` e `192.168.0.0/16`. Máquina privada sai por **NAT**: a borda troca IP e porta de origem pelo seu IP **público** e anota o par numa tabela para traduzir a resposta. De fora, ninguém inicia conexão com quem está atrás dela. E a tabela esquece: mapeamento ocioso é removido e o próximo pacote leva RST (no NAT Gateway da AWS, após 350 segundos). A conexão estava viva para as duas pontas e morta para o meio, um casamento em que o cartório perdeu a certidão.

Dentro da máquina, quem recebe é uma **porta** de 16 bits: o servidor escuta numa conhecida (443), o cliente ganha uma **efêmera** (no Linux, de 32768 a 60999). Uma conexão TCP é a quíntupla protocolo, IP e porta de origem, IP e porta de destino. Troque qualquer um dos cinco e nasce outra conexão, com outro handshake, que é para onde foram os 300 ms.

## O handshake, ou como dois computadores precisam de três mensagens para dizer oi

O TCP entrega bytes confiáveis e ordenados sobre um IP que perde e embaralha. Antes, as pontas combinam números de sequência:

```text
cliente                                servidor
   SYN  seq=x                    ─────►
                                 ◄─────  SYN-ACK  seq=y  ack=x+1
   ACK  ack=y+1  (já pode levar dados) ─────►
```

O número inicial é aleatório (RFC 6528), para que ninguém de fora adivinhe a sequência e injete bytes na conversa. Cada byte tem número; o receptor confirma com ACK cumulativo ("recebi tudo até o byte N"). Segmento sem confirmação dentro do *retransmission timeout* (RTO, calculado do RTT medido, RFC 6298) é reenviado; três ACKs duplicados disparam a retransmissão antes do timeout.

O custo é um RTT inteiro antes do primeiro byte de dados. É o protocolo mais inseguro do mundo: precisa de três mensagens para ter certeza de que o outro está a fim, e ainda assim às vezes o outro não estava ouvindo.

Sem resposta, o Linux reenvia o SYN 6 vezes (`tcp_syn_retries`), dobrando a espera a partir de 1 segundo: 127 segundos até desistir. Dois minutos mandando mensagem para quem já bloqueou você. Cliente sem *connect timeout* espera isso tudo (capítulo 15).

Efeito colateral da ordem: perdido o segmento 4, os de 5 a 40 esperam no buffer do kernel pela retransmissão. Esse *head-of-line blocking* é o motivo de o HTTP/3 ter largado o TCP (capítulo 9).

## Controle de fluxo e de congestionamento, ou o TCP pisando no freio por dois motivos diferentes

O **controle de fluxo** protege o receptor: cada ACK anuncia a janela de recepção (*rwnd*), quantos bytes ainda cabem no buffer de quem recebe (16 bits, 64 KiB; até 1 GiB com *window scaling*, RFC 7323). O **controle de congestionamento** protege a rede, e a janela dele (*cwnd*) mora só na cabeça do emissor, que mantém em trânsito no máximo `min(cwnd, rwnd)` bytes sem confirmação:

```text
vazão máxima ≈ janela / RTT
64 KiB / 100 ms ≈ 655 KB/s ≈ 5,2 Mbit/s   (com um link de 1 Gbit/s, tanto faz)
```

Conexão nova começa em *slow start*: janela inicial de 10 segmentos (RFC 6928), uns 14,6 KB, dobrando a cada RTT até uma perda ou um limiar. Uma resposta de 200 KB numa conexão recém-aberta leva quatro idas e voltas: 14,6 KB, mais 29,2, mais 58,4, mais 116,8. Quem batizou crescimento exponencial de "slow start" também chamaria o Carlos de "cauteloso".

Na perda, o CUBIC (RFC 9438), padrão do Linux, multiplica a janela por 0,7 e volta a crescer por uma função cúbica do tempo; o BBR estima banda e RTT mínimo em vez de esperar perda. E conexão reaproveitada nem sempre é rápida: com `tcp_slow_start_after_idle = 1`, o padrão do Linux, a janela volta ao valor inicial após um RTO de ociosidade. Conexão parada esquece que já foi rápida, como o Carlos depois das férias.

## Fim de conexão e TIME_WAIT, o luto obrigatório

Para fechar, cada direção manda o seu FIN e recebe ACK: quatro segmentos. Quem fecha primeiro entra em **TIME_WAIT** por 2 × MSL (vida máxima de um segmento; a RFC 9293 sugere MSL de 2 minutos, o Linux usa 60 segundos fixos de TIME_WAIT). Serve para reenviar o último ACK se ele se perder e para que um segmento atrasado da conexão morta não seja aceito por uma nova com a mesma quíntupla. O corpo fica velado um minuto, caso algum parente distante apareça com bytes atrasados.

Cada conexão em TIME_WAIT segura uma porta efêmera. Com 28.232 portas e 60 segundos de luto, um cliente que abre conexão nova a cada chamada para o mesmo destino sustenta umas 470 por segundo antes de o `connect()` falhar com `EADDRNOTAVAIL`. O cemitério lota antes da fila de vivos. Já o `RST` é morte sem velório: aborta na hora, e o kernel o manda para segmento de conexão que ele não conhece, como aquela que o NAT esqueceu.

## UDP, o protocolo que manda e vai embora

O UDP põe 8 bytes de cabeçalho (portas, tamanho, checksum) no datagrama e entrega ao IP. Sem conexão, retransmissão, ordem ou controle de congestionamento; datagrama perdido é problema da aplicação. É a rapidinha da pilha de rede: zero preliminar, zero garantia, e ninguém liga no dia seguinte. Serve a DNS, NTP (capítulo 20), mídia em tempo real e ao QUIC, que refaz confiabilidade e congestionamento por cima do UDP para escapar do head-of-line blocking (capítulo 9).

## RTT, ou a velocidade da luz não aceita chamado com "URGENTE!!!!"

Luz em fibra anda a uns 200 mil km/s, dois terços da velocidade no vácuo: 1 ms de RTT a cada 100 km de fibra, no mínimo físico. A rota real é mais longa que a linha reta, e cada roteador soma fila.

Os servidores do Hornero ficam numa região de nuvem na Virgínia, nos Estados Unidos. `temp-01` está num datacenter em São Paulo, a uns 7.600 km em linha reta: pelo menos 76 ms de RTT, mesmo esticando um cabo reto por cima da Amazônia e do Caribe. O Hornero mede 100 ms. O Bazar, em São Paulo, mede 2 ms. E o cliente do Hornero abre conexão nova em toda chamada:

```text
RTT 100 ms        Hornero (Virgínia)          temp-01 (São Paulo)
   0 ms  SYN                       ──────────►
 100 ms                            ◄──────────  SYN-ACK          TCP: 1 RTT
         ACK + ClientHello         ──────────►
 200 ms                            ◄──────────  ServerHello...   TLS 1.3: 1 RTT
         Finished + POST           ──────────►
 300 ms                            ◄──────────  201 Created      HTTP: 1 RTT
         (fecha, e a próxima chamada recomeça do SYN)
```

Três RTTs, 300 ms, mais 40 de processamento: o gráfico, centavo por centavo (o handshake TLS fica para o capítulo 10). O Bazar comete o mesmo pecado, mas a 2 ms de distância o pecado custa 6 ms e ninguém confessa.

## DNS, o banco de dados distribuído que todo mundo esquece que é um banco de dados

O DNS traduz nomes em registros, e a resolução atravessa uma hierarquia de servidores:

```text
aplicação ─► stub resolver (getaddrinfo, no SO)
               ─► resolver recursivo (do provedor, da nuvem, 1.1.1.1...)
                    ─► raiz       "para .br, pergunte a estes"
                    ─► TLD .br    "para lastro.com.br, pergunte a estes"
                    ─► autoritativo de lastro.com.br   "198.51.100.7, TTL 86400"
```

O **autoritativo** guarda a zona e responde por ela. O **recursivo** faz a caminhada, guarda cada resposta em cache e devolve ao stub do sistema operacional. Consultas vão por UDP na porta 53; resposta grande demais volta truncada e é refeita por TCP, que todo servidor DNS precisa suportar (RFC 7766).

Os registros que um backend usa: A e AAAA (endereço IPv4 e IPv6), CNAME (apelido para outro nome), MX (e-mail), TXT (texto livre: SPF, verificação de domínio), NS (quem é autoritativo pela zona) e SOA (metadados da zona, inclusive o TTL das respostas negativas).

Cada registro tem **TTL** em segundos: quanto tempo um cache pode reutilizar a resposta. Dois minutos depois, o mesmo recursivo devolve o registro com o TTL descontado:

```text
$ dig +noall +answer api.lastro.com.br
api.lastro.com.br.	86400	IN	A	198.51.100.7

$ dig +noall +answer api.lastro.com.br     # 2 minutos depois
api.lastro.com.br.	86280	IN	A	198.51.100.7
```

Esse é o número que o fundador escolheu, um dia, "pra não ficar consultando à toa". Mudar o registro muda o autoritativo e só ele; cada recursivo do planeta com a resposta em cache segue entregando o IP antigo até o seu TTL acabar.

O mercado chama isso de "propagação de DNS", como se o registro novo saísse em turnê pelo mundo. Nada propaga. Caches vencem, cada um no seu tempo. A única propagação real é do autoritativo primário para os secundários, por transferência de zona guiada pelo serial do SOA.

E há quem guarde além do TTL. A JVM guarda por 30 segundos por padrão e, com *security manager*, para sempre, porque o Java nunca soube largar nada. Processo que resolve o nome só ao iniciar usa aquele IP até reiniciar, e conexão TCP aberta não resolve nada de novo.

## Na Lastro: 200 ms recuperados e uma troca de IP de duas semanas

### Os 300 ms do Hornero

| Opção | Latência por chamada | Custo |
|-------|---------------------|-------|
| Reuso de conexão no cliente, *keep-alive* longo no servidor | 3 RTTs → 1 (300 → 100 ms) | conexões ociosas ocupam memória e descritor no servidor |
| TLS 0-RTT na retomada | 3 → 2 RTTs | dados 0-RTT podem ser repetidos por atacante; inaceitável para criar cobrança (capítulo 10) |
| API numa região perto do Hornero | ~100 ms a menos até a API | o banco fica em São Paulo: cada consulta passa a pagar 100 ms |

A Lastro adota a primeira. O Hornero passa a usar pool de conexões, e o servidor ASGI de `temp-01` sobe o *keep-alive* de 5 segundos (padrão do Uvicorn) para 65. O guia de integração pede que o cliente feche conexões ociosas antes de 60 segundos. O cliente fecha primeiro de propósito: no caso contrário, o servidor fecha no instante em que o cliente manda uma requisição, o cliente leva um RST e não sabe se a cobrança foi criada (capítulo 16).

Resultado: 140 ms por chamada, 100 de física e 40 de processamento. O gerente perguntou se dava para pedir ao provedor "uma fibra mais rápida". O Carlos anotou o pedido.

### A troca de `temp-01`

```text
                   internet
                       │
          198.51.100.7 │ (IP público efêmero, preso à máquina)
               ┌───────┴───────┐
               │    temp-01    │ 10.0.1.10   monólito, 3 workers
               │  crontab:     │             repasse_final_v2_agora_vai.py
               └───────┬───────┘
     rede privada      │ 10.0.1.0/24
               ┌───────┴───────┐
               │  PostgreSQL   │ 10.0.1.20   sem IP público
               └───────────────┘
```

O PostgreSQL mora em máquina própria, só com IP privado, e o `pg_hba.conf` aceita `10.0.1.0/24`. `api-01` entra na mesma rede e fala com o banco a 0,3 ms. Como o capítulo 2 pôs a verificação de saldo no banco, duas máquinas atendendo juntas é seguro; o vendedor 42 vai precisar de uma sexta aba.

**O IP fixo do banco parceiro.** O banco que dá acesso ao Pix só aceita conexões de IPs cadastrados no firewall dele: hoje, `198.51.100.7/32`. Esse IP é efêmero, atribuído pelo provedor à máquina, intransferível e perdido se ela for destruída. O medo coletivo de desligar `temp-01` acaba de ganhar fundamento técnico. A decisão: reservar um IP público fixo e transferível entre máquinas (um *Elastic IP* na AWS ou um IP externo estático no Google Cloud, por exemplo), `203.0.113.10`, e pedir ao banco que o cadastre **ao lado** do antigo. Prazo do banco: até 10 dias úteis e um formulário com firma reconhecida. Depois disso, trocar de máquina é mover o IP, sem cadastro novo.

**O TTL de um dia.** Mudar o registro A com TTL 86400 deixa até 24 horas de clientes divididos entre as duas máquinas, sem controle de quem. A sequência:

| Quando | Passo |
|--------|-------|
| D−14 | reserva de `203.0.113.10`; pedido ao banco parceiro |
| D−2 | TTL de `api.lastro.com.br` cai para 300; espera de 24 h, o TTL antigo |
| D−1 | banco confirma; `api-01` sobe com o IP reservado; Pix de teste |
| D0 | registro A → `203.0.113.10`; em 5 minutos os caches vencem; `temp-01` responde com `Connection: close` para que conexões keep-alive (as do Hornero, recém-convertido) reconectem e resolvam o nome de novo |

O TTL fica em 300 segundos: o requisito é apontar a API para outra máquina em minutos se `api-01` cair, ao custo de uma consulta ao autoritativo a cada 5 minutos por recursivo. TTL de horas serve a registros estáveis (MX, TXT) e sobrevive a uma queda do autoritativo.

Uma semana depois, `temp-01` ainda recebe tráfego, de duas fontes. Uma integração do Bazar que resolveu o nome ao iniciar, há 200 dias, e nunca reiniciou. E o `repasse_final_v2_agora_vai.py`, no crontab de `temp-01`, com sua cópia particular do código, chamando o banco a partir de `198.51.100.7`. O IP antigo fica no cadastro do banco, e `temp-01` fica ligado. O fundador disse "eu avisei". Tecnicamente avisou, só que de outra coisa.

## Armadilhas e casos reais

> **Armadilha:** consultar o nome antes de criá-lo. "Não existe" (`NXDOMAIN`) também vai para cache, pelo tempo do SOA da zona (RFC 2308). O Carlos testou `api-01.lastro.com.br` dez minutos antes de criar o registro, o resolvedor guardou a inexistência por uma hora, e ele passou essa hora reiniciando a máquina errada.

> **Armadilha:** CNAME no ápice da zona. Nome com CNAME não pode ter outros registros (RFC 1034), e o ápice sempre tem SOA e NS. Provedores oferecem registros proprietários (ALIAS, *CNAME flattening*) que resolvem o alvo no servidor e respondem com A.

> **Na vida real:** em 4 de outubro de 2021, um comando de manutenção desconectou o *backbone* do Facebook dos datacenters. Os servidores DNS, feitos para retirar seus anúncios de rota (BGP) quando perdem contato com os datacenters, fizeram exatamente isso, e Facebook, Instagram e WhatsApp sumiram da resolução de nomes por cerca de seis horas. Um mecanismo de segurança que funcionou com perfeição, contra a própria empresa.

> **Na vida real:** em 19 e 20 de outubro de 2025, uma condição de corrida na automação que gerencia o DNS do DynamoDB, na região us-east-1 da AWS, deixou vazio o registro de `dynamodb.us-east-1.amazonaws.com`. O serviço estava de pé; ninguém achava o endereço. A condição de corrida do capítulo 2 sacou o dobro de um vendedor; esta sacou o registro inteiro e deixou saldo zero: um nome com nenhum IP.

## Resumo

- IP *best effort*; CIDR; faixas privadas; NAT esquece conexões ociosas.
- TCP: quíntupla, handshake de 1 RTT, retransmissão, head-of-line blocking.
- Fluxo protege o receptor, congestionamento protege a rede; vazão ≤ janela / RTT.
- TIME_WAIT (60 s no Linux) prende portas de quem fecha primeiro.
- UDP: sem conexão nem garantias.
- RTT: ~1 ms a cada 100 km de fibra; conexão nova com TLS 1.3 custa 3 RTTs.
- DNS: recursivo, autoritativo, TTL e cache (inclusive negativo); nada propaga, caches vencem.

## A Lastro agora

O Hornero reutiliza conexões e mede 140 ms por chamada. A API responde em `api-01`, com o IP reservado `203.0.113.10` cadastrado no banco parceiro e TTL de 300 segundos. `temp-01` continua ligado, com o IP antigo no firewall do banco, servindo uma integração do Bazar que não reinicia e o job de repasse que ninguém migrou.

O fundador queria trocar de servidor em cinco minutos. Levou duas semanas, um formulário com firma reconhecida, e a Lastro terminou com dois servidores. `temp-01` tem agora dois motivos técnicos para viver, nenhum para morrer, e ganhou um irmão. Enquanto isso, o Carlos descobriu que o estorno do painel é um `GET` e achou prático: "dá pra estornar colando o link no navegador". Qualquer coisa que siga links também acha.

## Referências

- RFC 791. *Internet Protocol*. <https://www.rfc-editor.org/rfc/rfc791>
- RFC 8200. *Internet Protocol, Version 6 (IPv6) Specification*. <https://www.rfc-editor.org/rfc/rfc8200>
- RFC 9293. *Transmission Control Protocol (TCP)*. <https://www.rfc-editor.org/rfc/rfc9293>
- RFC 768 (UDP). <https://www.rfc-editor.org/rfc/rfc768>
- RFC 6298 (RTO). <https://www.rfc-editor.org/rfc/rfc6298>
- RFC 6528 (números de sequência). <https://www.rfc-editor.org/rfc/rfc6528>
- RFC 7323 (window scaling). <https://www.rfc-editor.org/rfc/rfc7323>
- RFC 6928 (janela inicial). <https://www.rfc-editor.org/rfc/rfc6928>
- RFC 9438 (CUBIC). <https://www.rfc-editor.org/rfc/rfc9438>
- RFC 1918 (endereços privados). <https://www.rfc-editor.org/rfc/rfc1918>
- RFC 4632 (CIDR). <https://www.rfc-editor.org/rfc/rfc4632>
- RFC 1034 e RFC 1035 (DNS). <https://www.rfc-editor.org/rfc/rfc1034>, <https://www.rfc-editor.org/rfc/rfc1035>
- RFC 2308 (cache negativo). <https://www.rfc-editor.org/rfc/rfc2308>
- RFC 7766 (DNS sobre TCP). <https://www.rfc-editor.org/rfc/rfc7766>
- Linux, "IP Sysctl". <https://docs.kernel.org/networking/ip-sysctl.html>
- Uvicorn, "Settings". <https://www.uvicorn.org/settings/>
- AWS, "Troubleshoot NAT gateways". <https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-troubleshooting.html>
- Meta, "More details about the October 4 outage". <https://engineering.fb.com/2021/10/05/networking-traffic/outage-details/>
- AWS, resumo da interrupção do DynamoDB em us-east-1 (outubro de 2025). <https://aws.amazon.com/message/101925/>
