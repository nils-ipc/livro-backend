# Resumo 37 — CI/CD e estratégias de deploy

## A Lastro ao fim do capítulo
- incidente terça 10h02–11h06: PR Carlos "refatora cálculo de tarifa (sem mudança de comportamento)", 2 aprovadores; gerente quer tarifa no checkout; `ROUND_HALF_EVEN` → `ROUND_UP` ("pra nunca cobrar menos"); fixtures R$ 100,00 (99 centavos exatos); rolling 30 pods 4 min, probes ok; 131 mil de 140 mil cobranças +1 centavo = R$ 1.310,00; vendedor 42 achou 10h51 (planilha própria); URGENTE 10h58 "CENTAVO ESCONDIDO???"
- correção: 131 mil transações ajuste, origem `ajuste`, referência `ajuste-tarifa:{cobranca_id}` UNIQUE; extrato "Ajuste de tarifa (devolução)"; evento novo `cobranca.tarifa_ajustada`
- tráfego manhã típica ~39 cobranças/s
- pagamentos: canary via mesh + controlador progressivo (Argo Rollouts/Flagger ex.), degraus 1% 10 min, 5% 15, 25% 15, 50% 15, 100% (~1 h) → requisito erro de cálculo atinge fração pequena; blue-green descartado (2× pods, exposição 100%)
- cobrança grava `versao_servico` (digest); análise vs baseline: 5xx, p99 autorização, fração `processando`, aprovação cartão (degrau ≥ 2), recusas consumidor ledger, resíduo de arredondamento (média 0 half-even vs 0,5)
- consumidores (ledger, entregador): rolling + flag
- flags versionadas no banco de configuração, caminho tarifas cap. 22 (memória, TTL 60 s, NOTIFY); regra de dinheiro atrás de flag por marketplace: "Lastro Interna" (marketplace produção próprio, Pix R$ 1,00) → pequeno → todos; cobrança grava `regras_aplicadas` (versão tabela + versão cálculo), conciliação 6h refaz; flag de lançamento com expiração, CI falha se vencida, nome não reaproveitado; mudança de flag também em degraus
- CI: chave permanente admin `ci-temporario` (2021) apagada → OIDC, papéis `ci-publica-imagem`, `ci-terraform-plan`, `ci-terraform-apply`, `sub` exato, 15 min; deploy por pull (Argo CD/Flux ex.), CI sem credencial do cluster; admissão só imagem assinada + digest; CDE pipeline/papéis próprios; merge → degrau 1 = 11 min
- próximo: sexta, aprovação cai sem deploy; Bazar percebe antes (cap. 38)

## Conceitos aprofundados aqui
- CI, entrega × implantação contínua; artefato imutável; config fora da imagem; proveniência SLSA/Sigstore
- OIDC: ID token por job, JWKS, política de confiança `sub`/`aud`
- recreate, rolling, blue-green, canary (tabela); poder estatístico `√(p(1−p)/n)`
- feature flags (tipos, combinatória, recibo); rollback × roll forward; correção compensatória

## Casos reais usados
- Knight Capital 1/8/2012 (Power Peg, >US$ 460 mi, ~45 min); CircleCI jan/2023

## Piadas recorrentes
- Carlos: título de PR mente; próximo "COM mudança de comportamento"
- vendedor 42 do lado certo da divergência
- `ci-temporario` = provisório do temp-01; chave de CI funcionário sem entrevista
- tabelião: 131 mil desculpas com firma
