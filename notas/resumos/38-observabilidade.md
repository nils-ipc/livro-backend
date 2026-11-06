# Resumo 38 — Observabilidade

## A Lastro ao fim do capítulo
- incidente sexta 18h52–~21h12, sem deploy: `redis-sinais` bate `maxmemory` (`noeviction`) → INCR recusado `OOM command not allowed...`; pipeline MGET+INCR falha inteiro → antifraude trata como "Redis fora", segue sem sinais (degradação cap. 25) → Vigia recusa mais; aprovação cartão 85% → 72%; ~16 mil recusas a mais; zero centavo errado; dashboards verdes (5xx 0, p99 1,1 s, CPU 31%); URGENTE 19h25 "APROVAÇÃO CAIU"; `grep` 60 pods 20h10, achado 21h05, 2 mi linhas `falha ao ler sinais, seguindo sem`
- canary cap. 37 só vigia em deploy
- OpenTelemetry SDK + instrumentação automática (FastAPI, httpx, gRPC, psycopg, Kafka); Collector por nó (DaemonSet) → Collector central, amostragem na cauda: 100% erro/`processando`/`recusada`/> 2 s, 5% resto; ~25 spans/cobrança, ~1.000 spans/s
- CDE: Collector próprio, atributos só lista permitida, Luhn descarta e conta
- `eventos_saida` + coluna `traceparent` → CDC → cabeçalho registro `cobrancas.eventos` → ledger-consumidor/agendador continuam (links); entregador envia `traceparent` ao marketplace; painel mostra `trace_id` por entrega
- logs JSON campos obrigatórios (`ts`, `nivel`, `servico`, `versao_servico`, `trace_id`, `span_id`, `evento`, `marketplace_id`, `cobranca_id`); formatador recusa campo fora da lista; repetição → contador + 1 log amostra/min; 30 dias pesquisável, 1 ano frio
- métricas RED, USE, negócio, degradação; rótulos por lista (Collector descarta e conta); ~400 mil séries; buckets autorização 0,25…1,5, 2, 3, 5, 8 s
- regra: todo caminho de degradação = contador + alerta (`antifraude_sinais_ausentes_total` por `causa`)
- alerta aprovação por marketplace/método vs mesma janela semana anterior, queda > 5 pontos 10 min; `redis-sinais` alerta 80% `maxmemory`, recalculado p/ Tuiuiú
- refeito: alerta 19h02, 23 min antes do Bazar
- próximo: contrato novo com SLA e multa (cap. 39)

## Conceitos aprofundados aqui
- monitoramento × observabilidade (Kálmán 1960); 3 sinais
- log estruturado, `evento` estável, custo volume/vazamento
- contador/`rate`, gauge, histograma cumulativo, `histogram_quantile` interpola (erro por bucket), cardinalidade = produto
- trace, span, W3C `traceparent`, links, amostragem cabeça × cauda
- OTel: API, SDK, semconv, OTLP, Collector; exemplars
- RED (Wilkie), USE (Gregg), sinais dourados; métricas de negócio

## Casos reais usados
- Dapper (Google 2010, 1/1.024)

## Piadas recorrentes
- Vigia: cego de um olho (cap. 25) → dos dois, agora com contador
- todo dashboard = postmortem emoldurado
- Carlos: três sinais num `print`; estatisticamente o 1º a pôr `vendedor_id` em rótulo
- tracing monogâmico, lote = relação aberta
