# Resumo 01 — TCP/IP e DNS

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- camadas TCP/IP (4, RFC 1122); "camada 4/7" = apelido OSI
- MTU 1.500, MSS 1.460
- CIDR: `/n` = 2^(32-n) endereços; RFC 1918: 10/8, 172.16/12, 192.168/16
- NAT: tabela expira, conexão ociosa morre em silêncio (350 s valor comum)
- TCP: handshake 1 RTT; RTO inicial 1 s; tcp_syn_retries=6 → 127 s; RST → ConnectionRefusedError
- janela de recepção, window scaling, cwnd, slow start IW10 (~14,6 KB), CUBIC, BBR; vazão = janela/RTT
- TIME_WAIT 60 s Linux; portas efêmeras 32768–60999 = 28.232 → ~470 conexões/s por destino; `Errno 99`; tcp_tw_reuse; tcp_tw_recycle removido 4.12
- UDP: 8 bytes, sem garantia
- RTT: luz na fibra ~200 mil km/s; SP–Washington 76 ms teórico; 1ª requisição HTTPS = 3–4 RTTs
- DNS: stub, recursivo, autoritativo, raiz 13 identidades anycast; EDNS(0), TC→TCP; tipos de registro; CNAME proibido no apex; TTL; "propagação" = caches vencendo; cache negativo RFC 2308; conexões abertas não reconsultam DNS (pool_recycle)

## Termos e traduções adotados
- ephemeral port → porta efêmera
- receive window / congestion window → janela de recepção / janela de congestionamento (`cwnd`)
- stub resolver, resolver recursivo, servidor autoritativo

## Casos reais e exemplos usados (não repetir)
- hipotético: troca de DNS sexta 17h50, TTL 86.400, servidor `temp-01` desligado 18h05
- httpx sem Client esgotando portas; ss com 28.190 TIME_WAIT
- Facebook 4/10/2021 (BGP retirado pelos DNS autoritativos)
- AWS DynamoDB us-east-1 19–20/10/2025 (registro DNS vazio, condição de corrida)
- Kubernetes ndots:5
