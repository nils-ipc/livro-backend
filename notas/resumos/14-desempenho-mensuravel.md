# Resumo 14 — Desempenho mensurável

## A Lastro ao fim do capítulo
- contrato Bazar Black Friday, cláusula 7.2: p99 autorização < 1,5 s no pico projetado + capacidade comprovada p/ 2× pico; multa por hora fora
- Carlos: slide "0,9 s" (média); teste fechado 50 usuários → "aguenta 55/s" = limite Little do gerador (50/0,9); p99 1,1 s com coordinated omission (simulador Java, pausa GC 12 s)
- medição real (log proxy, 21.418/h): média 0,93; p50 0,87; p90 1,04; p99 1,31; p99,9 2,9 s
- SLI: latência no proxy (recebimento → último byte), histograma por processo agregado por minuto, histograma por etapa (SLI/SLO formal cap. 39)
- orçamento p99 1.500 ms: proxy/loop 20, validação+tx1 20, Vigia 120, adquirente 1.200 (medido 1.180), tx2+resposta 20, folga 120 → 80% adquirente; Lastro controla 60 ms
- projeção pico BF (Bazar+Hornero): 60 cartão/s, 140 Pix/s, 900 GET/s, 40 GraphQL/s; CPU 6/4/1,5/15 ms → 2,87 s CPU/s
- regra: ρ CPU/worker ≤ 0,7 no 2× pico
- novo `api-02` (4 vCPU, 3 workers, proxy TLS, cert ACME) → 9 workers: ρ 0,32 pico, 0,64 2×
- `pool_size` 3 → 2 (9 × 2 = 18); demanda 3,2 conexões pico, 6,4 no 2×
- adquirente: 54 em andamento pico, 108 2×; 9 conexões × 100 streams
- comissão Bazar ~200 créditos/s pico; baldes teto 8.000/s
- teste aberto taxa constante, simuladores Vigia/adquirente com histogramas reais, 3 patamares 30 min: 9 workers p99 1,32/1,33/1,36 s; 6 workers 2× = 2,7 s
- épico "migrar autorização para Rust" fechado (Amdahl: 6%)
- próximo: BF sexta 21h40 adquirente p99 4 s; timeout 1,3 s → 3.000 respondidas "recusada", 412 aprovadas no arquivo do dia seguinte (cap. 15)

## Conceitos aprofundados aqui
- latência = serviço + espera; vazão; pontos de medição
- percentis, cauda, 1 − 0,99^N, histogramas agregáveis, média de percentil inválida
- Little `L = λW`; M/M/1 `W = S/(1−ρ)`, p99 ≈ 4,6 × média; Kingman variabilidade
- Amdahl `1/((1−p)+p/s)`, aplicado a latência
- números de latência (Dean 2009)
- modelo aberto × fechado; coordinated omission (Tene); wrk2, k6 `constant-arrival-rate`, Gatling

## Casos reais usados
- Tail at Scale (Dean/Barroso 2013, 63% com fan-out 100); wrk2 README

## Piadas recorrentes
- Carlos: slide fonte 96 → três números fonte 72 ("um tem vírgula"); teste mediu o gerador
- fundador: p99 = modelo de celular
- média = pé no forno e no freezer
- média de percentil = "alma de horóscopo"
