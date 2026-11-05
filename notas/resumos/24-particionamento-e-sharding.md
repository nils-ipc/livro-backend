# Resumo 24 — Particionamento e sharding

## A Lastro ao fim do capítulo
- incidente: estorno R$ 19,90 Capinhas (9 mi lançamentos) → `SUM` no trigger débito 1,9 s com lock da conta; `lancamentos` 420 mi, +1,5 mi/dia; VACUUM horas + WAL p/ 3 réplicas; fundador "máquina maior"; Carlos `DELETE` > 1 ano barrado pelo tabelião
- `lancamentos` particionada RANGE mensal `criado_em`; PK `(id, criado_em)`; nada referencia por FK
- migração sem cópia: rename → `lancamentos_legado`, `CHECK (criado_em < '2026-12-01')` NOT VALID + VALIDATE, índice único `(id, criado_em)` CONCURRENTLY, ATTACH `[MINVALUE, '2026-12-01')` sem varredura; triggers tabelião/débito recriados na mãe
- job cria partições 3 meses antes, alerta se faltar a seguinte
- mês corrente ~45 mi linhas, índice extrato ~2,3 GB, cabe no cache
- `saldos_fechados (conta_id, mes, saldo)`: gravado quando menor `xact_start` (sessões cliente) passa da virada; débito = último fechado + mês corrente → estorno Capinhas 4 ms
- retenção 10 anos: DETACH → armazenamento de arquivo, conferido pela soma
- sharding NÃO implantado; gatilho: escrita primário > 50% capacidade medida ou mês corrente fora do cache (conta no cap. 29); pico BF ~800 lançamentos/s
- chave escolhida: `marketplace_id` por diretório (41 marketplaces, tamanhos >1.000×; Bazar e gigante cap. 29 com shard próprio); diretório no primário de configuração, cache por processo, época como fencing
- liquidante e receita: subconta por shard; global = soma, conciliação confere
- transferência entre marketplaces do mesmo grupo (gerente: "é só um botão"): saga T1 shard A (origem → `transito_saida_A`), T2 shard B (`transito_entrada_B` → destino, referência UNIQUE), C1 estorno; soma trânsito entre shards = 0 na conciliação; 2PC descartado
- próximo: Vigia precisa contadores cartão/dispositivo ms, grafo contas ligadas (fraude em anel), agregações; Carlos criou `grafo_de_fraude (de, para)` no ledger + `WITH RECURSIVE` que "termina" (cap. 25)

## Conceitos aprofundados aqui
- partição RANGE/LIST/HASH; pruning plano/execução; manutenção local; DETACH; sem índice global; índice partitionado `ON ONLY` + ATTACH; erro `no partition of relation ... found for row`
- sharding: faixa (chave crescente), hash mod N (10→11 move ~91%), consistente (Karger 1997, ~1/N, nós virtuais), shards lógicos fixos (Redis 16.384 slots), diretório
- hot spot: subchaves/shard dedicado
- scatter-gather `1 − 0,99^20` ≈ 18%; rebalanceamento com replicação lógica + fencing

## Casos reais usados
- Notion 2021: 480 shards lógicos / 32 bancos, workspace ID, 480 pelos divisores

## Piadas recorrentes
- Capinhas: sucesso punido O(n)
- Carlos: "guardar num arquivo" ganho com 10 anos de atraso; job partições só olhava o mês
- baldes cap. 4 "promovidos a infraestrutura"; tabelião cobra carimbo por partição
- "dez apartamentos porque o armário encheu"; "ganhou dez bancos, perdeu o que sabia de tudo"
