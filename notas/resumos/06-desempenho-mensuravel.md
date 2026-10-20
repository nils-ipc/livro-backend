# Resumo 06 — Desempenho mensurável

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- latência = espera + serviço, medida num ponto; app mede trecho menor que cliente
- throughput máx. 1 atendente = 1/tempo_serviço
- média esconde cauda; percentil nearest-rank; percentis não se agregam com média, histogramas sim
- página com 40 requisições: 33% batem acima do p99; fan-out 1-0,99^N (N=100 → 63,4%)
- Tail at Scale: p99 folha 10 ms vs todas 140 ms; hedged requests 1.800→74 ms p99,9, +2%
- Little L=λW, sem hipótese de distribuição; detector de métricas inconsistentes
- Amdahl S=1/((1-p)+p/n), teto 1/(1-p); USL Gunther α contenção, β coerência (retrógrado)
- ρ=λS; M/M/1 W=S/(1-ρ), L=ρ/(1-ρ), p99=ln(100)·W; Kingman (ca²+cs²)/2; M/M/c desloca joelho
- números de latência Dean 2009/Colin Scott (L1 1 ns … transatlântico 150 ms)
- modelo fechado X=N/(W+Z) vs aberto (taxa fixa); Schroeder NSDI 2006; k6 constant-vus/constant-arrival-rate
- coordinated omission (Gil Tene, wrk2, HdrHistogram); correção: medir desde instante planejado
- perf_counter/monotonic, nunca time.time

## Termos e traduções adotados
- throughput → vazão; utilização ρ
- coordinated omission, hedged requests, fan-out, outlier em inglês
- open/closed model → modelo aberto/fechado; think time → tempo de reflexão

## Casos reais e exemplos usados (não repetir)
- hipotético: painel "latência média 95 ms" verde, checkout 98% 42 ms / 1,5% 950 ms / 0,5% 8 s → média 95,41
- tabela M/M/1 S=20 ms (ρ 0,5→0,99)
- relatório 400 ms, 6 chamadas 50 ms, gather → 150 ms, teto 100 ms
- API 1.200 req/s × 80 ms = 96 em andamento
- travamento 10 s em t=50 s: fechado p99,9 1 ms vs aberto p99 9.501 ms
