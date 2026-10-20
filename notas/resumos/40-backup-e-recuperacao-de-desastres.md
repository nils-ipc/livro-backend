# Resumo 40 — Backup e recuperação de desastres

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- RPO = perda máxima aceitável (tempo); RTO = tempo máximo até voltar; meta vs valor real, só teste mede
- completo / incremental (cadeia, 1+N) / diferencial (2 arquivos); PG 17 summarize_wal + pg_basebackup --incremental + pg_combinebackup
- lógico pg_dump (REPEATABLE READ, portável, restauração lenta) vs físico (mesma versão, precisa WAL da cópia); snapshot crash-consistent, volumes atômicos
- PITR: backup base + archive_command, segmento 16 MB, archive_timeout, pg_receivewal; restore_command, recovery_target_time/xid/lsn/name, recovery.signal, promote, timeline 2; replay em 1 processo (40 GB/dia × 6 = 240 GB)
- réplica copia erro; recovery_min_apply_delay
- 3-2-1, 3-2-1-1-0, WORM (Object Lock compliance, Azure imutável), outra conta, chave KMS sobrevive
- DR (whitepaper AWS): backup e restauração / pilot light / warm standby / ativo-ativo; RPO assíncrono = lag
- pg_stat_archiver last_archived_time, failed_count; teste de restauração automático com métricas; data checksums padrão PG 18

## Termos e traduções adotados
- disaster recovery → recuperação de desastres (DR); crash-consistent → consistente em caso de queda
- pilot light, warm standby, multi-site, timeline, WORM em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: escola de natação Braçada Firme, quarta 15h41, `limpa_dados_de_teste.py`, 14.212 matrículas, 214 gzip de 20 bytes, pg_dump 15 vs PG 16, sem pipefail; salva por réplica parada 15h12
- PITR 15h40, transação 918274; restore test 11,4 min / 3,2 h
- GitLab 31/01/2017; OVHcloud SBG2 10/03/2021; Code Spaces jun/2014
