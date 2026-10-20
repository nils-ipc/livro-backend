# Resumo 10 — Transações e isolamento

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- ACID Härder/Reuter 1983; C = restrições declaradas, regra de negócio fora do banco
- durabilidade: WAL + fsync; synchronous_commit=off perde até 3× wal_writer_delay (200 ms)
- serializabilidade: equivalente a alguma execução em série
- padrão ISO/IEC 9075: dirty read, non-repeatable read, phantom; Berenson et al. 1995 → lost update, write skew
- MVCC PG: xmin/xmax, snapshot `xmin:xmax:lista` (pg_current_snapshot), leitor não bloqueia escritor, VACUUM, wraparound/freeze
- PG: READ UNCOMMITTED = READ COMMITTED; RC snapshot por comando, UPDATE espera e reavalia WHERE
- REPEATABLE READ PG = snapshot isolation, snapshot no 1º comando, first-committer-wins, 40001 "concurrent update"; write skew passa
- Oracle SERIALIZABLE = SI; MySQL InnoDB RR deixa lost update
- SSI PG 9.1 (Cahill 2008, Ports/Grittner VLDB 2012): SIREAD locks, dependência rw, pivô, falsos positivos, seq scan = tabela inteira, max_pred_locks_per_transaction 64, READ ONLY DEFERRABLE
- retry da transação inteira, backoff + jitter, sem efeito externo
- write skew: FOR UPDATE (linhas existem) vs EXCLUDE/UNIQUE/SERIALIZABLE (linhas inexistentes)

## Termos e traduções adotados
- dirty read, non-repeatable read, phantom, lost update, write skew, snapshot em inglês
- write skew → "escrita enviesada" (1ª aparição)

## Casos reais e exemplos usados (não repetir)
- hipotético: plantão Tadeu e Lívia, sexta 23h58, alerta 2h47 sem ninguém
- estoque produto 7 (10→9)
- psycopg 3 RR vs SERIALIZABLE; `em_transacao_serializavel`
- Flexcoin mar/2014 896 BTC; ACIDRain SIGMOD 2017 (12 apps, 22 ataques); Jepsen PostgreSQL 12.3 G2-item
