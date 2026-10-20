# Resumo 38 — Observabilidade

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- observabilidade (Kálmán 1960) vs monitoramento; 3 sinais: logs, métricas, traces
- log estruturado: JSON por linha, evento fixo + campos, `trace_id` correlaciona; 2.000 req/s × 10 × 500 B = 864 GB/dia
- métricas modelo Prometheus: série = nome + rótulos; contador (`rate()`, reinício), gauge, histograma cumulativo `le`/`_sum`/`_count`, summary não agregável
- `histogram_quantile` interpolação linear; erro = largura do balde; `+Inf` → limite do último balde finito; padrão Python 5 ms–10 s; nativos Prometheus 2.40, exponencial OTel
- cardinalidade = produto; 17 séries/combinação; 652.800 séries; + cliente_id → 130 bi
- pull (`up == 0`) vs push (silêncio ambíguo)
- trace/span (Dapper 2010), trace_id 16 B, span_id 8 B, kind; CLIENT − SERVER = caminho
- W3C traceparent `00-trace-parent-flags`, sampled 01, tracestate, baggage; links em lotes
- contextvars: cópia em create_task/to_thread, não em run_in_executor/ThreadPoolExecutor
- OTel 2019: API/SDK/OTLP 4317/4318/semconv `http.route`/Collector; `unknown_service`
- head (TraceIdRatioBased, ParentBased) vs tail (`tail_sampling` 30 s, exporter `loadbalancing`)
- RED (Wilkie 2015), USE (Gregg 2012), sinais dourados
- BatchSpanProcessor fila 2.048 vs SimpleSpanProcessor síncrono

## Termos e traduções adotados
- bucket → balde; head/tail sampling → amostragem na cabeça/cauda
- span, trace, gauge, summary, pull, push, baggage, links em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: lavanderia Bolha Azul, Seu Anselmo 11 camisas 112 pontos, Renata, "chegou aqui 2", `Erro: sucesso`, média 257 ms, 198/10.000 > 10 s, SMS brinde 100 pontos ReadTimeout
- série vazia de status 500 não dispara alerta; scanner 4.000 séries 404
- Twitter mai/2018 e Facebook mar/2019 senhas em log; Log4Shell CVE-2021-44228
