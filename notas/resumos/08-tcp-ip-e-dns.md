# Resumo 08 — TCP/IP e DNS

## A Lastro ao fim do capítulo
- incidente: Mercadito Hornero (servidores em região de nuvem na Virgínia) mede 340 ms/chamada vs 40 ms processamento; RTT 100 ms (mínimo físico ~76 ms, 7.600 km); conexão nova por chamada = TCP 1 + TLS 1.3 1 + HTTP 1 = 3 RTT; Bazar (SP) RTT 2 ms, mesmo pecado, 6 ms
- decisão: reuso de conexão no cliente + keep-alive servidor 5 s (padrão Uvicorn) → 65 s; guia de integração: cliente fecha ociosas < 60 s → evita RST no meio da requisição; Hornero 140 ms
- descartados: TLS 0-RTT (replay, cap. 10); API perto do Hornero (banco em SP, +100 ms/consulta)
- rede: temp-01 `10.0.1.10`, PostgreSQL `10.0.1.20` sem IP público, rede privada `10.0.1.0/24`, `pg_hba.conf` aceita /24
- servidor novo `api-01`: IP público reservado transferível `203.0.113.10`; temp-01 IP efêmero `198.51.100.7` (intransferível)
- banco parceiro Pix: allowlist por IP; cadastrou `203.0.113.10/32` ao lado do antigo (até 10 dias úteis, formulário com firma)
- DNS `api.lastro.com.br`: TTL 86400 (fundador) → 300 permanente; troca D−14 a D0; temp-01 `Connection: close` após troca
- temp-01 continua ligado: integração do Bazar que resolveu DNS há 200 dias sem reiniciar + `repasse_final_v2_agora_vai.py` no crontab saindo de `198.51.100.7`
- deploy agora em 2 máquinas (temp-01, api-01)
- próximo: estorno do painel é `GET` (Carlos: "estornar colando o link") → cap. 09

## Conceitos aprofundados aqui
- camadas TCP/IP, MTU 1.500, MSS 1.460
- IP best effort, TTL de pacote, traceroute, CIDR, RFC 1918, NAT (350 s AWS)
- portas efêmeras 32768–60999, quíntupla
- handshake, ISN aleatório, ACK cumulativo, RTO, SYN 127 s, HOL blocking
- rwnd, cwnd, vazão ≤ janela/RTT, IW10, CUBIC 0,7, BBR, slow start after idle
- TIME_WAIT 60 s Linux, ~470 conexões/s por destino, RST
- UDP; RTT 1 ms/100 km fibra
- DNS: stub, recursivo, autoritativo, registros, TTL, cache negativo (RFC 2308), CNAME no ápice, "propagação" = caches vencendo; JVM 30 s

## Casos reais usados
- Facebook 4/10/2021 (BGP + DNS, ~6 h); AWS DynamoDB us-east-1 19–20/10/2025 (registro DNS vazio)

## Piadas recorrentes
- "é só mudar o IP no DNS" (fundador) → duas semanas, dois servidores; "eu avisei"
- temp-01: medo de desligar ganhou fundamento técnico; agora tem irmão
- gerente: "fibra mais rápida"; Carlos anotou
- Carlos: NXDOMAIN em cache, reiniciou máquina errada
- vendedor 42 precisaria de sexta aba
- UDP = rapidinha; TIME_WAIT = velório; Java "nunca soube largar nada"
