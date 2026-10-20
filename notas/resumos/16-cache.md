# Resumo 16 — Cache

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- cache = cópia; fonte da verdade continua no banco
- hit/miss, taxa de acerto h; carga fonte = (1−h)×taxa; 99%→98% dobra; cache vira dependência de capacidade
- cache-aside, read-through, write-through (escrita dupla → cap. 22), write-behind (perde janela)
- invalidação: TTL, DEL (não regravar), chave versionada / geração por namespace, CDC
- corrida leitor lento × escritor (t0–t4); leases (Facebook NSDI 2013), duplo delete, TTL limita
- LRU (varredura), LFU (decaimento); Redis maxmemory-samples 5, LFU 8 bits logarítmico, lfu-log-factor 10, início 5, lfu-decay-time 1 min; padrão noeviction → erro OOM
- stampede: coalescência (singleflight, asyncio.shield), lock SET NX PX, stale-while-revalidate lógico, XFetch VLDB 2015 p = e^(−t/(delta×beta)), jitter TTL
- camadas: processo, Redis, navegador, CDN; RFC 5861 stale-while-revalidate/stale-if-error; lru_cache sem TTL, maxsize 128
- negative caching, cache penetration, filtro de Bloom; tenant na chave; pickle = RCE

## Termos e traduções adotados
- hit/miss → acerto/falha; eviction → despejo; taxa de acerto
- cache stampede, thundering herd, request coalescing → coalescência de requisições
- cache-aside, read-through, write-through, write-behind, lease, purge em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: home:ofertas liquidação meia-noite, 3.200 consultas 800 ms, TODO 2021
- asyncio 1000 vs 1 consulta; INFO stats 99,70%
- Facebook 23/09/2010 laço configuração inválida
- ChatGPT 20/03/2023 redis-py, 1,2% Plus
