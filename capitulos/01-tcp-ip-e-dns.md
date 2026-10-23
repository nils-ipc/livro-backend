# TCP/IP e DNS

## A semana mais longa do `temp-01`

O `temp-01` foi ligado em 2016 "só por uma semana" e, desde então, atende sozinho a API de pagamentos. Numa sexta-feira, às 17h50, ele finalmente vai se aposentar. O servidor novo está de pé, os testes passaram, e falta só uma linha: trocar o registro DNS de `api.example.com` do `temp-01` para o balanceador novo. Alguém troca a linha, confere no navegador, vê a resposta do servidor novo e desliga o `temp-01` às 18h05, com a sensação de dever cumprido.

Às 18h07 começam os alertas. Metade dos clientes recebe timeout de conexão. Os workers internos insistem no endereço antigo. E quem chega ao servidor novo reclama que a primeira requisição leva 400 ms, embora o servidor responda em 3 ms.

A situação é hipotética, mas cada peça dela acontece toda semana em algum lugar. Se o DNS foi trocado às 17h50, por que ainda há gente batendo no endereço antigo horas depois? E de onde vêm os 397 ms que o servidor não gastou?

## Quatro camadas, cada uma com o seu cabeçalho

A pilha da internet é a do TCP/IP, com quatro camadas (RFC 1122). O modelo OSI tem sete, aparece em entrevistas e empresta os números como apelido ("balanceador de camada 4").

| Camada (número OSI) | Entrega | Exemplos |
|---|---|---|
| Enlace (2) | Quadros na rede local | Ethernet |
| Internet (3) | Pacotes entre redes, por IP | IPv4, IPv6 |
| Transporte (4) | Dados entre processos, por porta | TCP, UDP |
| Aplicação (7) | O que o seu código fala | HTTP, DNS |

Cada camada põe o próprio cabeçalho na frente do que a de cima entregou. Um JSON de 80 bytes viaja com 54 bytes de cabeçalhos (Ethernet, IPv4 e TCP), e ninguém na reunião de custos pergunta por eles. O quadro Ethernet comum tem **MTU** de 1.500 bytes; sem os cabeçalhos de IP e TCP, sobram 1.460 bytes de dados por segmento, o **MSS**.

## IP, CIDR e endereços que só existem do lado de dentro

O IP entrega pacotes entre máquinas pelo endereço, em *best effort*: o pacote pode chegar, chegar duplicado, fora de ordem ou sumir, e o protocolo não avisa ninguém. O IPv4 tem endereços de 32 bits (uns 4,3 bilhões, que acabaram); o IPv6 tem 128 (RFC 8200) e está no plano de "ano que vem" de muita empresa desde 2012.

O cabeçalho IP tem um campo TTL que conta saltos: cada roteador decrementa 1 e descarta o pacote no zero. O TTL do DNS conta segundos. Mesmo nome, unidades diferentes, e muita conversa longa em canal de incidente.

Redes são escritas em notação **CIDR** (RFC 4632): endereço base e quantos bits iniciais identificam a rede. Um `/n` tem `2^(32 - n)` endereços: `10.20.0.0/16` tem 65.536, um `/24` tem 256, um `/32` é um endereço só, e `0.0.0.0/0` é a internet inteira, o que explica por que ele merece uma segunda leitura numa regra de firewall.

A RFC 1918 reserva três faixas privadas, não roteadas na internet: `10.0.0.0/8`, `172.16.0.0/12` e `192.168.0.0/16`. Milhões de empresas usam `10.0.0.5` ao mesmo tempo sem conflito. Detalhe que pega gente experiente: `172.16.0.0/12` termina em `172.31.255.255`. Uma regra "para a rede interna" com `172.0.0.0/8` libera um pedaço da internet que pertence a outras pessoas.

## NAT, a tabela que esquece

Um servidor com IP privado baixa pacotes do PyPI pelo **NAT** (*network address translation*): o roteador de borda troca o endereço e a porta de origem de cada pacote que sai pelo IP público dele, anota a troca numa tabela e a desfaz na volta. De fora, ninguém inicia conexão para quem está atrás do NAT, porque não há entrada na tabela (o capítulo 36 trata de redes em nuvem).

A parte traiçoeira: a tabela expira. Uma conexão TCP ociosa por tempo demais some dela sem que nenhum dos lados saiba. A aplicação manda uma consulta pelo *socket* que parece aberto e espera. E espera. Gateways NAT gerenciados expiram conexões ociosas em poucos minutos (350 segundos é um valor comum; muda por provedor), e um *pool* com conexões paradas por mais tempo coleciona sockets mortos.

## TCP por dentro

O TCP (RFC 9293) transforma pacotes que se perdem num fluxo de bytes confiável e ordenado entre dois processos. Uma conexão é identificada por IP e porta de origem e IP e porta de destino. O servidor escuta numa porta fixa (443, 5432); o cliente usa uma **porta efêmera**, que no Linux sai por padrão da faixa de 32768 a 60999.

Cada byte tem número de sequência, e o receptor confirma com ACK ("recebi tudo até o byte N"). Sem ACK dentro do RTO (*retransmission timeout*, 1 segundo inicial pela RFC 6298), o remetente retransmite, e o RTO dobra a cada tentativa.

### O handshake, ou três pacotes antes do primeiro byte útil

Antes de qualquer dado, o TCP abre a conexão com o *three-way handshake*:

```text
Cliente:  SYN, meu número de sequência começa em 1.904.331.017
Servidor: SYN-ACK. Anotado. O meu começa em 3.002.118.440
Cliente:  ACK. Anotado também.
Cliente:  (agora sim) GET /pagamentos/123
```

O número de sequência inicial é aleatório, para que ninguém adivinhe e injete dados numa conexão alheia. O custo do handshake é um RTT inteiro antes do primeiro byte útil, e o servidor ainda nem sabe o que você quer.

Sem resposta ao SYN, o Linux (padrão `net.ipv4.tcp_syn_retries = 6`) espera 1, 2, 4, 8, 16, 32 e mais 64 segundos: 127 segundos retransmitindo SYN, com paciência exemplar, para uma máquina desligada às 18h05. Se a máquina está ligada e ninguém escuta na porta, o kernel dela responde RST e a conexão falha na hora com `ConnectionRefusedError`, uma recusa muito mais gentil que dois minutos de silêncio.

### Controle de fluxo e de congestionamento

Em cada ACK, o receptor anuncia o espaço livre no buffer, a **janela de recepção**, e o remetente não pode ter mais bytes sem confirmação do que isso. O campo tem 16 bits (65.535 bytes, muito em 1981); o *window scaling* (RFC 7323) permite janelas de até 1 GB.

Para proteger a rede, o remetente mantém a **janela de congestionamento** (`cwnd`) e usa a menor das duas. Uma conexão nova começa em *slow start* com 10 segmentos (RFC 6928), uns 14,6 KB, e dobra a janela a cada RTT sem perdas. Ao detectar perda, reduz. O padrão do Linux é o CUBIC (RFC 9438); o BBR estima banda e RTT em vez de reagir só a perdas.

"Slow start" é o caso mais antigo de propaganda enganosa da pilha: o crescimento é exponencial, lento é só o começo. Uma resposta de 200 KB leva 4 RTTs numa conexão nova (14,6 + 29 + 58 + 117 KB) e 1 numa conexão aquecida. A vazão máxima é `janela / RTT`: com 64 KB e 100 ms, 640 KB/s, mesmo num link de 10 Gbit/s.

### TIME_WAIT e as portas que acabam

O encerramento troca FIN e ACK nos dois sentidos, e o lado que fecha primeiro fica em **TIME_WAIT** por 2 × MSL (*maximum segment lifetime*), fixo em 60 segundos no Linux e sem `sysctl` para mudar. Assim, segmentos atrasados da conexão antiga não são aceitos por uma nova com os mesmos endereços e portas.

A conta: um cliente falando com um único destino tem 28.232 portas efêmeras, e cada conexão fechada prende a sua por 60 segundos. Teto: 28.232 / 60 ≈ 470 conexões novas por segundo. Na de número 28.233 do minuto, o kernel desiste:

```text
OSError: [Errno 99] Cannot assign requested address
```

A correção é reaproveitar conexões, com keep-alive e pool. O `net.ipv4.tcp_tw_reuse` deixa conexões de saída reutilizarem portas em TIME_WAIT com segurança, via timestamps do TCP. O `tcp_tw_recycle`, estrela de tutoriais de "otimização", quebrava clientes atrás de NAT e saiu do kernel na versão 4.12; se ele aparece num script de provisionamento, o script é mais velho que o `temp-01`.

## UDP, o protocolo que não promete nada

O UDP (RFC 768) tem cabeçalho de 8 bytes e nenhuma garantia: sem handshake, confirmação, retransmissão ou ordem. O datagrama sai, e o resto é problema de quem mandou. O DNS usa UDP porque pergunta e resposta cabem num pacote cada. O QUIC, base do HTTP/3, implementa confiabilidade própria por cima do UDP porque mudar o TCP em todos os kernels e equipamentos do mundo levaria décadas (o capítulo 2 trata do HTTP/3).

## Latência, ou a física não aceita reclamação

O **RTT** (*round-trip time*) tem um piso: a luz na fibra anda uns 200 mil km/s. São Paulo fica a uns 7.600 km de Washington; ida e volta dá 76 ms no mínimo teórico e, por rotas reais, costuma passar de 100 ms. Nenhuma refatoração tira esse número do caminho. A primeira requisição HTTPS para um servidor novo paga, em sequência:

| Etapa | RTTs | Com RTT de 100 ms |
|---|---|---|
| Consulta DNS (sem cache) | 1 ou mais | 0 a 100+ ms |
| Handshake TCP | 1 | 100 ms |
| Handshake TLS 1.3 | 1 | 100 ms |
| Requisição e resposta HTTP | 1 | 100 ms + 3 ms do servidor |

Dá uns 400 ms, dos quais o servidor gastou 3: a segunda pergunta da abertura. A requisição seguinte na mesma conexão custa 1 RTT (o capítulo 3 detalha o TLS).

## DNS

O DNS (RFCs 1034 e 1035) é um banco de dados hierárquico, distribuído e cacheado em todas as camadas, o que explica a escala dele e quase todos os incidentes que levam o nome dele.

### Quem pergunta para quem

`httpx.get("https://api.example.com")` acaba em `getaddrinfo`, da libc, o **stub resolver**: ele lê `/etc/resolv.conf` e manda a pergunta, quase sempre por UDP na porta 53, ao **resolver recursivo** (o da rede da nuvem, o do provedor, ou um público como `1.1.1.1`). Com a resposta em cache, ele devolve na hora. Sem ela, faz o trabalho pesado:

```text
Resolver: Raiz, onde fica api.example.com?
Raiz:     Não sei. Pergunte aos servidores de .com.
Resolver: .com, onde fica api.example.com?
.com:     Não sei. Os servidores de example.com são estes dois.
Resolver: example.com, onde fica api.example.com?
example:  203.0.113.10, válido por 300 segundos.
```

A raiz tem 13 identidades (`a` a `m.root-servers.net`), cada uma servida por centenas de instâncias com *anycast*: o mesmo IP anunciado em vários lugares, e o roteamento entrega na mais próxima. A resposta final vem do **servidor autoritativo** da zona; todos os outros repetem o que ouviram, por um tempo combinado. Respostas acima de 512 bytes usam EDNS(0) (RFC 6891) ou voltam truncadas e são repetidas por TCP, que a RFC 7766 exige. Um firewall que libera só UDP na porta 53 funciona até o dia em que a resposta cresce.

### Tipos de registro

| Tipo | Conteúdo |
|---|---|
| A / AAAA | Endereço IPv4 / IPv6 |
| CNAME | Outro nome (ex.: o de um balanceador gerenciado) |
| NS / SOA | Servidores autoritativos e dados da zona |
| MX / TXT | E-mail; texto livre (verificação de domínio, SPF) |
| CAA | Autoridades que podem emitir certificados TLS |

Um nome com CNAME não pode ter nenhum outro registro. Como o *apex* (`example.com`) precisa de SOA e NS, ele não pode ser CNAME; provedores contornam com tipos fora do padrão (ALIAS, ANAME), resolvidos no servidor.

### TTL e a lenda da propagação

Cada registro traz um **TTL** em segundos. O resolver reaproveita a resposta em cache até o TTL zerar, e até lá o autoritativo pode mudar o que quiser. "Esperar o DNS propagar" é folclore: ninguém empurra a mudança para ninguém. Existem caches independentes, cada um esperando o próprio relógio vencer.

Primeira resposta da abertura: o registro de `api.example.com` tinha TTL de 86.400 segundos, configurado em 2016 junto com o `temp-01`. Quem consultou o nome nas 24 horas anteriores continuou recebendo o IP antigo, e a troca das 17h50 só chegaria a todos às 17h50 do sábado. A migração segura baixa o TTL para 60 pelo menos um TTL antigo antes da troca, e deixa o servidor antigo ligado até o tráfego nele zerar.

Respostas negativas também vão para o cache (RFC 2308): um `NXDOMAIN` consultado um minuto antes de o registro existir fica guardado pelo menor valor entre o TTL do SOA e o campo *minimum*, muitas vezes uma hora.

### Os caches que você não configurou

Há caches no sistema operacional (systemd-resolved, nscd) e em alguns runtimes (a JVM, conforme a configuração, já guardou respostas para sempre). O Python não tem cache próprio. Isso não salvou os workers da abertura, porque o DNS só é consultado ao abrir uma conexão. O pool deles tinha conexões abertas desde a manhã para o IP antigo, e trocar o registro não afeta conexão estabelecida. Quando o `temp-01` foi desligado, o pool abriu conexões novas, consultou o DNS e, com o cache do resolver válido, recebeu de novo o endereço do `temp-01`. Limitar a vida das conexões no pool (o `pool_recycle` do SQLAlchemy, por exemplo) força consultas periódicas.

## Na prática

O `dig` mostra o que o resolver responde e com qual TTL restante:

```bash
$ dig +noall +answer api.example.com
api.example.com.        300     IN      CNAME   lb-prod.example.net.
lb-prod.example.net.    60      IN      A       203.0.113.10
lb-prod.example.net.    60      IN      A       203.0.113.11
```

Treze segundos depois, o TTL veio menor: a resposta saiu do cache, com contagem regressiva visível.

```bash
$ dig +noall +answer api.example.com
api.example.com.        287     IN      CNAME   lb-prod.example.net.
lb-prod.example.net.    47      IN      A       203.0.113.11
lb-prod.example.net.    47      IN      A       203.0.113.10
```

A ordem dos registros A mudou: o resolver faz rodízio, e quem pega sempre o primeiro distribui carga de graça. O módulo `ipaddress` faz as contas de CIDR sem erro de cabeça:

```python
import ipaddress

vpc = ipaddress.ip_network("10.20.0.0/16")
print(vpc.num_addresses)                # 65536

subredes = list(vpc.subnets(new_prefix=24))
print(len(subredes), subredes[0], subredes[-1])
# 256 10.20.0.0/24 10.20.255.0/24

print(ipaddress.ip_address("172.31.5.9").is_private)   # True
print(ipaddress.ip_address("172.32.5.9").is_private)   # False, é internet de outra pessoa
```

Medindo resolução e handshake separados (host fictício, números de uma execução hipotética com RTT de 100 ms):

```python
import socket
import time

HOST, PORTA = "api.example.com", 443

t0 = time.perf_counter()
endereco = socket.getaddrinfo(HOST, PORTA, type=socket.SOCK_STREAM)[0][4]
t1 = time.perf_counter()
with socket.create_connection(endereco[:2], timeout=3):  # nunca 127 segundos
    t2 = time.perf_counter()

print(f"DNS: {(t1 - t0) * 1000:.0f} ms")
print(f"TCP: {(t2 - t1) * 1000:.0f} ms")
```

```text
DNS: 104 ms
TCP: 101 ms
```

Com a resposta em cache, o DNS cai para 1 ms. O TCP não cai nunca. Agora, um código de cara inocente que esgota portas efêmeras:

```python
import httpx

def buscar_preco(sku: str) -> dict:
    # Uma conexão TCP nova (e um handshake TLS) por chamada.
    return httpx.get(f"https://precos.example.com/v1/{sku}").json()
```

A 600 chamadas por segundo, são 600 handshakes TCP, 600 TLS e, em menos de um minuto, um `Errno 99`. A versão que reaproveita conexões cria o cliente uma vez:

```python
import httpx

cliente = httpx.Client(
    base_url="https://precos.example.com",
    timeout=httpx.Timeout(5.0, connect=2.0),
    limits=httpx.Limits(max_keepalive_connections=20, keepalive_expiry=60),
)

def buscar_preco(sku: str) -> dict:
    return cliente.get(f"/v1/{sku}").json()
```

O `keepalive_expiry` de 60 segundos também protege contra o NAT e o DNS: nenhuma conexão ociosa vive o bastante para virar socket fantasma. Na máquina com a versão antiga, o `ss` mostra o estrago:

```bash
$ ss -tan state time-wait | tail -n +2 | wc -l
28190
$ sysctl net.ipv4.ip_local_port_range net.ipv4.tcp_syn_retries
net.ipv4.ip_local_port_range = 32768	60999
net.ipv4.tcp_syn_retries = 6
```

Vinte e oito mil conexões em TIME_WAIT contra um limite de 28.232 portas: faltam 42 para o próximo `Errno 99`.

## Propriedades e custos

| Propriedade | TCP | UDP |
|---|---|---|
| Estabelecimento | 1 RTT | Nenhum |
| Entrega e ordem | Garantidas | Nenhuma garantia |
| Cabeçalho | 20 a 60 bytes | 8 bytes |
| Perda de um pacote | Atrasa os bytes seguintes (*head-of-line blocking*) | Afeta só aquele datagrama |

TCP serve quando cada byte precisa chegar em ordem (HTTP/1.1, HTTP/2, bancos). UDP serve quando a mensagem cabe num pacote, quando dado atrasado vale menos que dado perdido (voz) ou quando o protocolo tem confiabilidade própria (QUIC).

| TTL | Até todos verem a mudança | Se o autoritativo cair, caches seguram |
|---|---|---|
| 60 s | 1 minuto | 1 minuto |
| 3.600 s | 1 hora | 1 hora |
| 86.400 s | 1 dia | 1 dia, e um sábado perdido |

TTL curto acelera migração e failover por DNS, ao custo de mais consultas e mais latência de resolução.

## Armadilhas e casos reais

> **Armadilha:** em Kubernetes, pods vêm com `ndots:5` e domínios de busca. `api.example.com` (menos de cinco pontos) é tentado antes com cada sufixo (`api.example.com.default.svc.cluster.local` e companhia), e uma consulta vira várias, quase todas `NXDOMAIN`. O ponto final (`api.example.com.`) torna o nome absoluto.

> **Na vida real:** em 4 de outubro de 2021, o Facebook ficou fora do ar por cerca de seis horas. Um comando de manutenção derrubou o backbone entre datacenters, e os servidores DNS autoritativos, projetados para retirar seus anúncios BGP ao perder contato com os datacenters, fizeram exatamente isso. Continuavam funcionando; só não havia rota na internet até eles.

> **Na vida real:** em 19 e 20 de outubro de 2025, na região us-east-1 da AWS, uma condição de corrida na automação de DNS do DynamoDB aplicou um plano antigo por cima de um novo, e a limpeza automática apagou todos os IPs de `dynamodb.us-east-1.amazonaws.com`. O banco funcionava; ninguém conseguia descobrir o endereço dele. O reparo exigiu intervenção manual.

> **Armadilha:** sem timeout de conexão, vale o `tcp_syn_retries`: um destino desligado, como o `temp-01` depois das 18h05, prende cada worker por 127 segundos, e um pool de 32 workers se esgota em segundos.

## Resumo

- Um `/n` tem `2^(32 - n)` endereços; faixas privadas: `10/8`, `172.16/12`, `192.168/16`. A tabela do NAT expira e mata conexões ociosas em silêncio.
- TCP: 1 RTT de handshake, janela inicial de 10 segmentos, 60 segundos de TIME_WAIT no Linux. Sem reuso de conexões, umas 470 conexões novas por segundo para um mesmo destino.
- A primeira requisição HTTPS paga 3 a 4 RTTs antes de o servidor trabalhar.
- DNS: stub, recursivo e autoritativo. Propagação é cache vencendo pelo TTL; baixe o TTL antes de migrar. Conexões abertas não consultam o DNS.

## Referências

- RFC 1122, Requirements for Internet Hosts: https://www.rfc-editor.org/rfc/rfc1122
- RFC 791, Internet Protocol (IPv4): https://www.rfc-editor.org/rfc/rfc791
- RFC 8200, IPv6: https://www.rfc-editor.org/rfc/rfc8200
- RFC 1918, Address Allocation for Private Internets: https://www.rfc-editor.org/rfc/rfc1918
- RFC 4632, CIDR: https://www.rfc-editor.org/rfc/rfc4632
- RFC 5737, endereços IPv4 reservados para documentação: https://www.rfc-editor.org/rfc/rfc5737
- RFC 9293, Transmission Control Protocol: https://www.rfc-editor.org/rfc/rfc9293
- RFC 6298, Computing TCP's Retransmission Timer: https://www.rfc-editor.org/rfc/rfc6298
- RFC 6928, Increasing TCP's Initial Window: https://www.rfc-editor.org/rfc/rfc6928
- RFC 7323, TCP Extensions for High Performance: https://www.rfc-editor.org/rfc/rfc7323
- RFC 9438, CUBIC: https://www.rfc-editor.org/rfc/rfc9438
- RFC 768, User Datagram Protocol: https://www.rfc-editor.org/rfc/rfc768
- RFC 1034 e RFC 1035, Domain Names: https://www.rfc-editor.org/rfc/rfc1034 e https://www.rfc-editor.org/rfc/rfc1035
- RFC 2308, Negative Caching of DNS Queries: https://www.rfc-editor.org/rfc/rfc2308
- RFC 6891, EDNS(0): https://www.rfc-editor.org/rfc/rfc6891
- RFC 7766, DNS Transport over TCP: https://www.rfc-editor.org/rfc/rfc7766
- Documentação do módulo `ipaddress`: https://docs.python.org/3/library/ipaddress.html
- Meta, "More details about the October 4 outage" (2021): https://engineering.fb.com/2021/10/05/networking-traffic/outage-details/
- AWS, "Summary of the Amazon DynamoDB Service Disruption in the Northern Virginia (US-EAST-1) Region" (2025): https://aws.amazon.com/message/101925/
