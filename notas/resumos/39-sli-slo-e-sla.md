# Resumo 39 — SLI, SLO e SLA

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- SLI = bons / válidos (0 a 1); SLO = SLI + alvo + janela; SLA = contrato com consequência, mais frouxo que SLO (SRE book 2016)
- válido: fora /health, /metrics; bom: 5xx ruim, 4xx bom, 429 do próprio limitador ruim, lento acima do limiar ruim
- latência como proporção abaixo do limiar, não percentil; limiar = borda de balde (padrão Python pula 0,25 → 0,5)
- ponto de medição: app não vê processo morto; balanceador vê 502; sintético; cliente
- SLI por requisição (peso = usuários) vs por tempo (intervalos bons/ruins)
- tempo permitido = (1 − SLO) × janela; 99,9% = 43,2 min/30 d; 99,99% = 4,32 min; 99,999% = 5,26 min/ano; janela 28 dias móveis
- série: 0,999^5 ≈ 99,5%
- error budget = 1 − SLO; 12.960.000 req → 12.960
- burn rate = erro / (1 − SLO); consumido = burn × duração / janela; 100% erro esgota em 43 min 12 s
- multiwindow multi-burn-rate (Workbook): 14,4 1 h/5 min 2%; 6 6 h/30 min 5%; 1 3 d/6 h 10% ticket; janela curta = 1/12
- pouco tráfego: agrupar, sintético, mínimo de eventos, janela maior

## Termos e traduções adotados
- error budget → orçamento de erro; burn rate → taxa de consumo
- SLI, SLO, SLA, recording rule em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: confeitaria Doce Prazo, Seu Teodoro, cláusula 7.2 99,999%, manutenção domingo 2h 30 min (26 h/ano), "uptime 100%" via /health, bolo de brigadeiro, SLI 98,80% vs 99,96%, dia 10 30% / dia 12 90%
- Chubby interrupção planejada (SRE book)
- SLA S3 Standard 28/11/2023: intervalos 5 min, 10/25/100%
