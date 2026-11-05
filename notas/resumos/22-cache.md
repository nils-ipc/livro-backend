# Resumo 22 — Cache

## A Lastro ao fim do capítulo
- incidente: Carlos `@functools.lru_cache` em `tarifa_do_marketplace` (sem TTL, maxsize 128), 9 workers; Hornero Pix 0,99% → 0,79% segunda 00h; workers reciclados a cada 50 mil requisições (fundador, vazamento de memória) → tarifa por sorteio 3 dias, 6.100 cobranças a 0,99%; financeiro devolveu diferença em lançamentos novos
- PR Carlos "cache do saldo do saque no Redis (write-through, seguro)" fechado
- tarifas + split: versões imutáveis com `vigente_desde` (próxima hora cheia, ≥ 10 min antecedência); cache memória do processo, todas vigências (< 1 MB), TTL 60 s ± 20%; vigente pelo `now()` da transação; urgência → `NOTIFY config_tarifas` + LISTEN existente (cap. 12); versão aplicada gravada na cobrança, conciliação confere; primário −2.200 consultas/s no pico; 11 leituras/cobrança
- Redis (ou Valkey) gerenciado entra: só resumo do painel (GraphQL), ~15 ms CPU + ~40 ms banco, 40 abas/marketplace; cache-aside `painel:resumo:{marketplace}:{dia}`, TTL 30 s ± 20%, coalescência `SET NX PX`, stale-while-revalidate, "atualizado às…", `allkeys-lru` + `maxmemory`; Redis fora → coalescência local, ≤ 9 cálculos/marketplace/30 s
- `/v1/moedas` `public, max-age=86400`; JS checkout em CDN, hash no nome, `max-age=31536000, immutable`; respostas de cobrança `private`
- sem cache: cobrança na API, chave idempotência, saldo do saque (escrita dupla, replicação assíncrona Redis, sem lock/snapshot); painel saldo segue `saldos_painel`
- próximo: relatórios mensais marketplaces no primário, 40 s cada, dia 1º 9h, disputam I/O com lançamentos; Carlos quer "cachear por 30 dias" (acerto zero, 2 aprovadores) → cap. 23

## Conceitos aprofundados aqui
- hit ratio, latência efetiva, carga origem `(1 − h) × leituras`
- cache = réplica sem protocolo: eventual, TTL limita, sem RYW
- cache-aside, read-through, write-through, write-behind; corrida stale set; valor versionado (Lua), leases, DEL após COMMIT
- invalidação: TTL, explícita, evento, chave versionada; cache negativo
- LRU, LFU, TTL; Redis amostragem (`maxmemory-samples` 5), LFU 8 bits, `noeviction` padrão, allkeys/volatile
- stampede: single-flight, SWR (RFC 5861), XFetch (VLDB 2015), jitter
- camadas somam atraso

## Casos reais usados
- Facebook 23/9/2010 (~2,5 h, config inválida, loop); Steam Natal 2015 (~34 mil usuários); memcache Facebook NSDI 2013 (leases); Karlton

## Piadas recorrentes
- Carlos: emoji de foguete; de luto pelo PR; `cache_simples` errou nome e invalidação
- tarifa "estabilidade de servidor público"; worker convicto = tio no grupo da família
- financeiro baniu "sorteio" do canal
