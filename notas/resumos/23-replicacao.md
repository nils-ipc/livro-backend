# Resumo 23 — Replicação

## A Lastro ao fim do capítulo
- incidente dia 1º 9h: PR Carlos "cachear relatório 30 dias" (acerto zero) + 41 relatórios em paralelo no primário → cache do banco expulso, INSERT lançamento 0,13 → 9 ms, autorização p99 1,3 → 2,4 s; URGENTE 9h07; fundador: "e se morrer?" → backup 3h + 6 h restauração
- 41 marketplaces
- ledger: `pg-ledger-1` primário (zona A), `pg-ledger-2` (B) e `pg-ledger-3` (C) standbys físicos, `ANY 1` + `synchronous_commit = on` → requisito zero lançamento confirmado perdido; zonas ~1 ms
- Patroni + etcd 3 nós (1/zona), `synchronous_mode_strict` → sem réplica = `503` em débitos/pagamentos (C); failover automático só p/ síncrona, 30–40 s; libpq multi-host `target_session_attrs=read-write`
- primário isolado não confirma nada (modo estrito = fencing)
- COMMIT +~1,5 ms; posse balde ~2 → ~3,5 ms; teto conta quente 8.000 → ~4.500/s (pico comissão ~200/s)
- CDC PG16: slot perdido no failover (recuperação cap. 18) + janela evento sem lançamento; migração p/ PG17 (`synchronized_standby_slots`) via replicação lógica planejada; conciliação 6h cobre
- `pg-ledger-relat` assíncrona `nofailover`: relatórios; `max_standby_streaming_delay = 15min`, `hot_standby_feedback` off, rodapé "dados até" (`pg_last_xact_replay_timestamp()`), alerta lag > 20 min
- painel GraphQL lê nas réplicas síncronas; RYW: LSN pós-COMMIT em Redis `posicao:vendedor:{id}` TTL 5 min + maior LSN no painel (monotônicas); réplica com replay ≥ token ou primário após 200 ms; Redis fora → primário
- saldo do saque e escritas: primário; `saldos_painel` intacto
- números: `lancamentos` 420 mi linhas, +1,5 mi/dia, retenção 10 anos (política Lastro) → >5 bi; índice extrato não cabe na memória
- próximo: cap. 24 particionamento/sharding

## Conceitos aprofundados aqui
- statement/físico/lógico; streaming (walsender, walreceiver, startup); hot standby; LSN
- lógica: sem DDL/sequências até PG17
- síncrona × assíncrona; tabela `synchronous_commit`; ANY/FIRST; espera eterna; WARNING "committed locally"; locks seguram durante espera
- lag, replay single-thread, conflito recovery (30 s), `hot_standby_feedback`
- RYW: tempo, `remote_apply`, token LSN
- failover 4 passos, split-brain, Patroni TTL 30 s, watchdog, STONITH, `pg_rewind`
- multi-líder conflitos; sem líder N/W/R, read repair, Merkle, sloppy quorum, quórum ≠ linearizável

## Casos reais usados
- GitHub 21/10/2018 (43 s, 24h11); GitLab 31/1/2017 (~300 GB, primário apagado); MySQL SBR unsafe (`UUID()`, `LIMIT`)

## Piadas recorrentes
- Carlos: cache acerto zero "exatamente o previsto"; 380 cancelamentos = "Sísifo com cron"; procurou "nenhuma das anteriores"
- vendedor 42: saque sumido na réplica = convite, sacou de novo, print ao Bazar
- master/slave "sem direito a opinião"; réplica "convalescença eterna"; "eu fiz, só não posso provar"; STONITH humor de pistoleiro; split-brain "segundo cérebro"
- fundador: "problema replicado com perfeição"
