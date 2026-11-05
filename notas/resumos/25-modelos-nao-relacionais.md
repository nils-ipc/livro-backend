# Resumo 25 — Modelos não relacionais

## A Lastro ao fim do capítulo
- incidente quarta 15h20: Vigia aceita "sinais" no `Avaliar`; Carlos `grafo_de_fraude (de, para)` sem tipo no `pg-ledger-1` + `WITH RECURSIVE` 4 saltos `UNION ALL`, flag `sinal_anel_beta` 5% autorizações; pico 60/s campanha aniversário Bazar; IP CGNAT 11 mil celulares (supernó) → 40 mi caminhos, 30 GB temp; deadline 8 s cancela; 3/s × 8 s = 24 conexões > 18 → Pix parou 15h22; URGENTE 15h23 "vocês estão investigando a gente?"; flag off 15h24, tabela fora 15h31
- contadores: `redis-sinais` instância separada do cache (cap. 22), `noeviction`, TTL em tudo, ~2 GB; 8 contadores (tentativas + valor cartão 10 min/1 h/24 h; cartões e contas distintos por dispositivo 24 h); baldes minuto/hora, `MGET`, HyperLogLog por hora; leitura + incremento 1 pipeline ~1 ms antes do Vigia, conta recusadas; cartão por identificador derivado (cap. 33) → requisito ~1 ms, erro tolerável
- Redis fora → sinais ausentes (`optional`) + regra local cap. 15
- descartados: count/sum no primário (+480 consultas/s), réplica
- grafo: banco de grafos (Neo4j/Neptune ex.) alimentado por `cobrancas.eventos`, `repasses.eventos`, cadastro; ~2 mi nós, 9 mi arestas; supernó > 500 arestas vira atributo; job 5 min → `sinal:anel:{conta}` no redis-sinais TTL 1 h; autorização só 1 GET; analista de risco escreve Cypher; tabela PG com `CYCLE` seria certa p/ perguntas fixas ≤ 2 saltos
- agregações: colunar analítico (ClickHouse ex.) via `cobrancas.eventos` lotes 10 s, ordem `(marketplace_id, criado_em)`; relatório risco 2 anos < 1 s (relat 90 s); chargeback = linha nova
- séries temporais → cap. 38
- ledger segue relacional
- próximo: deploy relatório de risco no mesmo processo que autoriza cartão (cap. 26)

## Conceitos aprofundados aqui
- modelagem por padrão de acesso
- chave-valor; Redis INCR/EXPIRE/HLL 12 KB 0,81%; RDB/AOF everysec; WAIT
- documento: agregado, 16 MB, multi-doc 4.0/4.2, `$lookup`
- wide-column, LSM, tombstone 100.000; colunar analítico, granule 8.192
- grafo: index-free adjacency, supernó, `CYCLE` PG14
- séries: downsampling, Gorilla 1,37 B/ponto, cardinalidade

## Casos reais usados
- Discord MongoDB→Cassandra 2017 `(channel_id, bucket)`; Jepsen MongoDB 4.2.6 (2020)

## Piadas recorrentes
- Carlos: query "termina" (aos 8 s); correto do tipo que derruba Pix
- nova: analista de risco (contratada pós cap. 21)
- supernó "virou fofoca"; Vigia "cego de um olho"; cemitério com lotação
- gerente: sem série temporal = "atraso no roadmap"
