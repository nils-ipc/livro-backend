# Resumo 40 — Backup e recuperação de desastres

## A Lastro ao fim do capítulo
- incidente 1, terça 20/10 14h03: Carlos, `quebra_vidro` (chamado legítimo: bloquear conta 8812, anel de fraude), cliente gráfico, só 1ª linha selecionada → `UPDATE contas SET bloqueada = true` → `UPDATE 61300` no shard 0, autocommit; síncronas replicaram em 1,5 ms; `422` fora do SLI → Bazar URGENTE 14h11 "BLOQUEARAM GERAL???"; 212 já bloqueadas (judicial/fraude), planilha "bloqueados" tinha 209; backup 3h restaurado ao lado + logs → saques parados até 20h05
- coluna nova `contas.bloqueada` (trigger débito recusa)
- incidente 2, sábado 10 dias depois 9h20: falha região provedor 5h40 (hipotético); tudo na mesma região, inclusive backups; banco desistiu 3.400 notificações; Tuiuiú 340 min → 99,21% → multa 50%; provedor fora da exclusão
- RPO/RTO: ledger (shards) + `pg-pagamentos` RPO 0, RTO região 30 min; `pg-cofre` ≤ 5 s assíncrono; `pg-notificacoes` ≤ 1 min; broker reconstruído da outbox; Redis sem cópia; colunar/grafo 24 h
- região secundária ~400 km, RTT ~8 ms (hipótese); `FIRST 2 (pg-dr, pg-ledger-2, pg-ledger-3)`; DR fora > 60 s = alerta, escritas seguem
- COMMIT +8 ms; Tuiuiú 32 → 64 baldes (~5.600/s; 2× pico comissão ~4.000/s); autorização +16 ms da folga
- WAL arquivado, base diária, PITR 35 dias, conta de backup separada, object lock, KMS próprio; cópia mensal outro provedor (3-2-1)
- réplica atrasada 1 h `nofailover` por shard; histórico por trigger em `contas`; `quebra_vidro` `default_transaction_read_only = on`
- warm standby: cluster 25% mín, mesmos módulos Terraform `for_each`; failover humano ≤ 10 min p/ declarar; etcd 5 nós (2+2+testemunha) → primário isolado rebaixado 30 s
- pré-requisitos: adquirente aditivo 4 IPs; IPs DR no banco Pix; certs mTLS DR; KMS multirregião; segredos, imagens, estado Terraform replicados; DNS TTL 300
- pós-failover: republica outbox 1 h, resolução cap. 15, saga repasses, conciliação D0 por EndToEndId, só então fechamento
- testes: semanal PITR automático (soma zero, saldos_fechados, contagem por LSN, alerta > 4 h); mensal réplica atrasada; semestral troca de região (pausa ~3 min); 1º teste 47 min, 2º 26 min
- fim do livro

## Conceitos aprofundados aqui
- RPO (dado) × RTO (serviço)
- replicação ≠ proteção contra erro lógico
- lógico × físico; completo/diferencial/incremental (PG17 `pg_combinebackup`); contínuo/PITR, `recovery_target_*`, `archive_timeout`; réplica atrasada
- 3-2-1 (Krogh), imutável/WORM
- 4 estratégias DR (tabela)

## Casos reais usados
- OVHcloud SBG2 10/3/2021; Toy Story 2 1998

## Piadas recorrentes
- Carlos: 1.024 baldes → 64 "vitória moral"; propôs desfazer também sem `WHERE`
- Bazar fecha o livro: "URGENTE!!!! tá tudo bem aí? tá quieto demais"
- financeiro: aba "bloqueados" como sistema oficial; conferiu às 3h40 por esporte
- fundador: "só um servidor e funcionava" sem contestação
