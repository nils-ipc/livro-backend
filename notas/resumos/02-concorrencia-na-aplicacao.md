# Resumo 02 — Concorrência na aplicação

## A Lastro ao fim do capítulo
- incidente: vendedor 42 (saldo R$ 500,00, duas abas) sacou 2× R$ 500,00 → saldo R$ −500,00; check-then-act com `await` entre SUM e INSERT
- correção do Carlos: dict de `asyncio.Lock` por conta → falhou: `temp-01` roda monólito com `--workers 3` (fundador) → funciona 1/3 dos casos; apagado
- decisão: saque = `SELECT ... FOR UPDATE` na linha de `contas` + `SUM` (comando novo, snapshot novo) + INSERT na mesma transação, read committed → lock no mesmo sistema do dado, liberado no COMMIT/ROLLBACK/queda da conexão; sem lease, sem fencing; saldo segue derivado (cap. 01)
- trigger `BEFORE INSERT` em lançamentos que debitam conta disponível: trava conta, recalcula, recusa saldo negativo → vale p/ qualquer caminho (job, `psql` do Carlos); créditos sem lock; Python só traduz erro em "saldo insuficiente"
- débitos em várias contas disponíveis: inserção em ordem crescente de `conta_id` (anti-deadlock)
- Pix ao banco parceiro só após COMMIT, nunca com lock (falha pós-débito → caps. 15, 18)
- números: ~400 saques/dia no Bazar; lock ~4 ms
- alternativas descartadas: Redis lock (peça nova), advisory lock, UPDATE condicional (exige saldo materializado)
- fundador fala em `temp-02` p/ Black Friday (cap. 27)
- próximo: limite diário de saque (gerente de produto) + proposta de repeatable read → write skew (cap. 03)

## Conceitos aprofundados aqui
- race condition, check-then-act, TOCTOU, read-modify-write; GIL, `await` como ponto de intercalação; heisenbug
- seção crítica, mutex, safety/liveness
- CAS, lock-free, `UPDATE` condicional (reavaliação em read committed)
- deadlock, 4 condições de Coffman, ordem de aquisição, livelock, `deadlock_timeout`
- escopo das primitivas (tabela)
- lock distribuído: `SET NX PX`, lease, pausa de GC, Redlock/Kleppmann, fencing (detalhe cap. 20)
- armadilha: FOR UPDATE + SUM falha em repeatable read (explicação cap. 03)

## Casos reais usados
- Flexcoin 2014 (896 BTC); Poloniex 12,3%

## Piadas recorrentes
- vendedor 42: "hobby" de saque duplo; termina abrindo a quarta aba
- Carlos: lock em memória com vazamento; caminho alternativo = especialidade
- "Tecnicamente é um lock. Juridicamente é um problema."
- lease zumbi com acesso de escrita; lock "replicado em pensamento"
- "partida dobrada, saque dobrado" → "saque único, partida dobrada"
