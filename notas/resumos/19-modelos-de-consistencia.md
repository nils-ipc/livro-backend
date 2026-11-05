# Resumo 19 — Modelos de consistência

## A Lastro ao fim do capítulo
- incidente sexta 17h02 (D+30 da BF): vendedor 42 sacou R$ 870,00 pelo celular 16h58; notebook mostra R$ 870,00; saque recusado `saldo-insuficiente` 3×; URGENTE 17h09 "ISSO É CALOTE???"; projeção aplicou saque 17h13
- projeção (Carlos, 2 semanas antes): painel 1.500 abas pico, refresh 15 s → 100 `SUM`/s primário (Capinhas 0,7 s); evento `conta.movimentada` na outbox → tópico `contas.movimentos` (chave `conta_id`, 12 partições) → consumidor `painel-saldos` → tabela `saldos_painel` + inbox `transacao_id` no `pg-notificacoes`; leitura 1 ms, atraso típico 300 ms; liberação D+30 BF 310 mil eventos a partir 16h50, consumidor único 500/s → 11 min
- descartado: saque ler projeção (Carlos) → saque dobrado
- tabela por leitura: débito, tela de saque, chave idempotência → primário (linearizável); cabeçalho painel + GraphQL saldo → `saldos_painel` eventual + RYW + monotônicas; webhooks eventual + `versao`; conciliação RR READ ONLY; extrato segue primário (projeção cap. 21)
- RYW: sessão = vendedor (não cookie); último débito do vendedor no primário (índice < 1 ms) → inbox tem? sim → projeção; não → espera NOTIFY até 2 s → senão "atualizando", sem número
- monotônicas por construção: 1 cópia, só aplica; réplica → token de posição (cap. 23)
- `painel-saldos` 3 instâncias; alerta atraso > 30 s
- recusa saque RFC 9457 traz saldo + último débito do mesmo snapshot
- partição: sem primário → painel mostra (A), débito `503` (C)
- próximo: fundador copia crontab temp-01 → api-02 "alta disponibilidade"; `repasse_final_v2_agora_vai.py` roda nas duas, relógios discordam da meia-noite (cap. 20)

## Conceitos aprofundados aqui
- 3 sentidos de consistência; modelo = conjunto de histórias
- linearizabilidade (Herlihy/Wing 1990), recência, custo RTT; strict serializability
- sequencial (Lamport 1979), causal (Ahamad 1995; Mahajan 2011 teto), eventual (Vogels), soma comutativa/CRDT
- 4 garantias de sessão (Terry 1994), prefixo consistente (Terry 2013)
- CAP Gilbert/Lynch 2002 precisa; A do CAP ≠ SLA; PACELC (Abadi 2012: Dynamo/Cassandra/Riak PA/EL; VoltDB/Megastore PC/EC)

## Casos reais usados
- DynamoDB RCU forte 1 × eventual 0,5, GSI sem forte; Dynamo carrinho itens ressuscitam; S3 forte dez/2020; Kleppmann "stop calling CP/AP"

## Piadas recorrentes
- vendedor 42: print = petição inicial; saque duplo "sem querer" pela 1ª vez; conspiracionista
- Carlos: "tempo real" p/ tudo
- consistência = "lista de mentiras autorizadas"; eventual = promessa de político / horóscopo
- fundador: servidor único "linearizável de graça"
