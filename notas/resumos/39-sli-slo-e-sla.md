# Resumo 39 — SLI, SLO e SLA

## A Lastro ao fim do capítulo
- incidente: contrato definitivo Tuiuiú (84 p., anexo 3 p. 61) 99,99% mensal; gerente "de acordo" em 11 min ("só um nove a mais"; 99,9 do slide de vendas 2023); Carlos "100%" (pods); medido retroativo na borda: 99,971% / 99,938% / 99,989% → multa nos 3 meses
- ~50 mi cobranças/mês com Tuiuiú
- 8 SLIs na borda (gateway, RED + histograma cap. 38), 30 dias deslizantes: autorização disponibilidade 99,97% (exclui 4xx cliente e `429`; `503` shedding = ruim); autorização latência 99% estado final ≤ 1,5 s (`processando` = ruim); qualidade 99,9% (sinais completos, `antifraude_sinais_ausentes_total`); criação Pix 99,97% ≤ 500 ms; notificação banco `webhooks-pix` 99,97% `2xx` ≤ 1 s; webhook 1ª tentativa ≤ 10 s do COMMIT 99,9%; GET cobrança 99,95% ≤ 300 ms; sonda externa 99,95%
- recusa emissor = bom
- sonda: 2 provedores fora da Lastro, a cada 30 s, Pix R$ 1,00 no Lastro Interna + GET
- Tuiuiú SLIs próprios por `marketplace_id`; resto agregado, nunca média
- SLA Tuiuiú: 99,95% mensal calendário (criação + consulta); minuto indisponível = > 5% falhas válidas Tuiuiú na borda ou sonda falha 2× seguidas; latência 99% ≤ 2 s; multa 10% (< 99,95), 25% (< 99,9), 50% (< 99,5); exclui falha parceiro comprovada; sem exclusão manutenção; contestação 15 dias
- SLO interno sem exclusão de parceiro; orçamento ~13 min/mês vs SLA 21,6 → ~9 min de folga
- alertas burn rate: 14,4 (1 h + 5 min), 6 (6 h + 30 min) página; 1 (3 d + 6 h) chamado; avaliação 30 s; mín 100 eventos janela curta; rótulo `causa`; limiares fixos apagados
- canary lê orçamento: < 25% degraus 2×; < 0 promoção para, rollback livre
- próximo: `UPDATE` sem `WHERE` na tabela de contas + região principal fora no mesmo mês (cap. 40)

## Conceitos aprofundados aqui
- SLI bons/válidos; SLO; SLA = consequência
- tipos: disponibilidade, latência (proporção), qualidade, frescor, correção, durabilidade
- pontos: servidor, borda, cliente, sonda; 0/0 cego
- tabela noves (30 d/ano); dependência em série limita
- error budget; calendário × deslizante
- burn rate, multijanela 1/12

## Casos reais usados
- Chubby derrubado de propósito (SRE book cap. 4); S3 us-east-1 28/2/2017 (~4 h, painel de status dependia do S3)

## Piadas recorrentes
- gerente: "um nove a mais" = 90% a menos; pediu estimativa do décimo nove
- disponibilidade do morto (100% no túmulo)
- Bazar = sonda sintética mais confiável, agora com concorrência
- financeiro: aba "SLA", linha por minuto de orçamento, aba de contestação
- Carlos quis sonda "no cluster"
