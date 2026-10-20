# Resumo 13 — Replicação

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- líder único / multi-líder / sem líder
- WAL, LSN (`0/3A2F1B8`); réplica física = recuperação permanente, byte a byte, mesma versão e arquitetura
- walsender/walreceiver/startup (replay em 1 processo); hot_standby
- slot de replicação retém WAL → disco cheio; max_slot_wal_keep_size PG 13
- conflito replay: max_standby_streaming_delay 30 s, "conflict with recovery"; hot_standby_feedback → bloat no principal
- synchronous_commit off/local/remote_write/on/remote_apply; só remote_apply = visível na réplica; SET LOCAL por transação
- synchronous_standby_names ANY 1 / FIRST 2; única síncrona caiu → commits esperam para sempre
- cancelar espera síncrona: já commitado localmente
- lógica: publication/subscription PG 10, sem DDL, sem sequências até PG 18, replica identity
- lag: pg_stat_replication write/flush/replay_lag; pg_last_xact_replay_timestamp engana sem escritas
- read-your-writes: janela no principal, perfil no principal, LSN (pg_last_wal_replay_lsn), fixar réplica (monotônicas)
- failover: pg_promote PG 12, timeline, pg_rewind; split-brain; fencing/STONITH; Patroni chave líder TTL etcd; libpq target_session_attrs
- multi-líder: LWW, CRDT; quórum N/W/R, W+R>N só interseção, read repair, Merkle, sloppy quorum; Cassandra ONE/QUORUM/LOCAL_QUORUM/ALL
- recovery_min_apply_delay; réplica não substitui backup

## Termos e traduções adotados
- standby/réplica, principal; lag de replicação; read-your-writes → ler as próprias escritas; monotonic reads → leituras monotônicas
- split-brain, fencing, timeline, slot, bloat, read repair em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: Dona Cecília troca e-mail 4×, `replica-b` 3,4 s atrás, `relatorio_trimestral_completo_v2.sql`
- pg_stat_replication replica-b 212 MB
- psycopg LSN read-your-writes, LSN 2/9C41E7A8
- diálogo split-brain pedido 9001 Ana/Bruno
- slot de réplica de testes março→junho
- GitHub 21/10/2018, 43 s, Orchestrator, 24 h 11 min
