# Resumo 37 — CI/CD e estratégias de deploy

## Conceitos aprofundados aqui (outros capítulos remetem para cá)
- CI / entrega contínua (botão) / implantação contínua (sem botão); Humble/Farley 2010
- pipeline = DAG de jobs, ordem por custo; duração = tempo mínimo de correção
- construir uma vez, implantar muitas; deploy por digest; lockfile com hash (`uv sync --locked`, `--require-hashes`); config fora da imagem (12-factor III)
- build reproduzível `SOURCE_DATE_EPOCH`; SLSA, Sigstore
- recreate, rolling (versões convivem), blue-green (2× capacidade, banco único), canary (raio de impacto vs amostra)
- canário: 0,1% → 0,2%, 3σ ≈ 27.000 req; 20 req/s → 22,5 min; teste z duas proporções
- feature flags: tipos Hodgson 2017; balde sha256(flag:usuário) % 10.000, monotônico; `hash()` randomizado; 2^10 caminhos; OpenFeature
- rollback (artefato anterior + compatibilidade) vs roll forward (tempo do pipeline)
- OIDC no CI: JWT do job, `sub` repo:...:environment:..., trust policy StringEquals, STS 1 h; papel por ambiente

## Termos e traduções adotados
- smoke test → teste de fumaça; digest, lockfile, rollback, roll forward, kill switch, feature flag, pipeline em inglês

## Casos reais e exemplos usados (não repetir)
- hipotético: academia Ferro & Fôlego, Wanderley, sexta 17h50, limite 2→3 check-ins, `deploy_final_agora_vai.sh`, lib 3.0 às 18h07, 6 unidades, caderno 1.140 entradas, rollback rebuild quebrado
- workflow GitHub Actions + ECR 111122223333
- Knight Capital 01/08/2012 (SEC, Power Peg, >US$ 460 mi)
- CrowdStrike Channel File 291 19/07/2024 (21 vs 20 campos, ~8,5 mi)
- tj-actions CVE-2025-30066; Codecov 2021; CircleCI jan/2023
