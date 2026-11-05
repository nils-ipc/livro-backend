# Resumo 26 — Decomposição de sistemas

## A Lastro ao fim do capítulo
- incidente quinta: deploy 9h30 (14 mudanças, 5 pessoas) com relatório de risco no monólito; 10h05 analista "exportar 2 anos" → 14 mi linhas colunar em DataFrame no worker, 40 s CPU no loop, RSS 160 MB → 7 GB, OOM killer; 212 autorizações → `processando` (resolução cap. 15); 3 cliques = 1 worker morto por máquina, 1/3 capacidade em 90 s; URGENTE 10h09 "quem é essa analista"; rollback levou correção Pix do Hornero (bug de volta 10h20)
- decisão: 6 serviços, deploy próprio, dono único dos dados → requisitos: autorização sem destino compartilhado; deploy sem domínios alheios; ledger atômico
- pagamentos (`pg-pagamentos`: cobranças, `eventos_cobranca`, chaves idempotência, outbox); antifraude (redis-sinais, grafo, Vigia); ledger (`pg-ledger`, único escritor); repasses; notificações (`pg-notificacoes`); relatórios (sem dados, lê colunar + `pg-ledger-relat`, limite memória)
- MUDA cap. 21: eventos_cobranca não mais no COMMIT do ledger; ledger consome `cobrancas.eventos`, `referencia` UNIQUE → ledger fora do caminho síncrono; janela ms–s cobrança paga sem saldo; conciliação nova classe "paga sem transação ledger > 5 min"; alerta atraso consumidor 30 s
- débito síncrono: repasses → API ledger (lock/serializable/trigger intactos)
- pagamentos → antifraude 1 chamada grossa `avaliar`, deadline propagado, +~1 ms da folga
- disponibilidade (hipótese): tudo síncrono ≈ 99,49% (~223 min/mês); ledger assíncrono + antifraude degradável (≤ R$ 300,00) ≈ 99,79% (~92 min) = monólito atual
- PgBouncer transaction na frente `pg-ledger` e `pg-pagamentos`; LISTEN direto; advisory dia contábil `pg_advisory_xact_lock_shared`
- migração: modular (schemas + import-linter CI) → relatórios → notificações → antifraude, repasses → bancos pagamentos/ledger por último (replicação lógica + fencing)
- serviços em processos nas mesmas 3 máquinas
- próximo: lista IPs/portas à mão (Carlos, "são só seis"); réplica morta segue recebendo (cap. 27)

## Conceitos aprofundados aqui
- 3 fronteiras: deploy, processo, dados; monólito distribuído
- tipos de acoplamento (tabela); coesão via histórico git
- banco por serviço: perde JOIN, transação, FK
- custo chamada rede; interface grossa
- série produto, paralelo 1 − ∏; independência
- Conway 1968; hipótese do espelhamento

## Casos reais usados
- Prime Video 2023 (monitoramento, >90% custo)

## Piadas recorrentes
- tabelião "promovido": cliente único
- Carlos em todos os repositórios; arquivo de IPs à mão
- monólito distribuído = pior dos mundos com SLA de cada
- antifraude "cachorro na estação" esperando réplica morta
