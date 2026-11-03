# Resumo 03 — Transações e isolamento

## A Lastro ao fim do capítulo
- incidente: limite diário saque R$ 5.000,00 (gerente) + `# por segurança` repeatable read (Carlos) → vendedor 42 (saldo R$ 6.000,00, R$ 1.000,00 já sacado) 2× R$ 4.000,00 → saldo −R$ 2.000,00, R$ 9.000,00 no dia; write skew (FOR UPDATE só travou, snapshot velho no trigger)
- pagamento com split: 1 transação de banco, read committed; ex. Pix R$ 100,00 = liquidante +10000, vendedor −8701, comissão Bazar −1200, receita Lastro −99
- débitos conta disponível (saque, estorno): SERIALIZABLE → regras sobre conjuntos de linhas; fila do gerente: limite noturno Pix, limite p/ chave Pix < 24 h (lê tabela de chaves)
- retry: até 3 tentativas p/ 40001 e 40P01, espera aleatória 5–50 ms, transação inteira do BEGIN; Pix só após COMMIT, fora do laço; falha → erro temporário
- trigger: mantém FOR UPDATE (fila; protege caminhos RC tipo `psql` do Carlos), confere saldo + limite diário, recusa débito em repeatable read
- extrato, conciliação: repeatable read READ ONLY
- papel padrão segue read committed
- próximo: conta de comissão do Bazar recebe crédito em toda venda; campanha "Black Friday o mês inteiro"; ninguém trava a conta "por enquanto" (cap. 04)

## Conceitos aprofundados aqui
- ACID; commit no WAL + `pg_xact`; abort = linhas invisíveis até VACUUM; `synchronous_commit` off perde até 3× `wal_writer_delay`
- níveis ISO/IEC 9075 por fenômenos; Berenson 1995; lost update, write skew, SI
- MVCC `xmin`/`xmax`, snapshot por comando (RC) / no 1º comando (RR); first-updater-wins; lock-only não dispara erro
- materializar conflito
- SSI: SIRead locks, rw-antidependency, pivô, falsos positivos, `max_pred_locks_per_transaction`, só entre serializables
- transação longa segura VACUUM; `idle_in_transaction_session_timeout`

## Termos
- "transação" do ledger vs transação do banco

## Casos reais usados
- médicos de plantão (write skew clássico); ACIDRain 2017 (22 ataques, 12 apps); Jepsen PostgreSQL 12.3 (G2-item, corrigido 12.4); Oracle serializable = SI

## Piadas recorrentes
- vendedor 42: quinta aba, `40001` particular
- financeiro não dorme desde cap. 01
- rollback = "luto mais barato"; snapshot "olhos vendados"; `# por segurança`
- "saque único, partida dobrada, com nota fiscal do PostgreSQL"
