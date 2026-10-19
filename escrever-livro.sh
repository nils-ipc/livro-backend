#!/usr/bin/env bash
#
# Escreve os capítulos do livro, um por vez, chamando o Claude Code em modo
# não interativo. Para cada capítulo: escreve o capítulo, faz uma checagem
# mecânica (grep de marcas de IA e contagem de palavras) e salva um resumo em
# notas/resumos/.
#
# Uso:
#   ./escrever-livro.sh              # escreve todos os capítulos que ainda não existem
#   INICIO=7 ./escrever-livro.sh     # começa a partir do capítulo 07
#   FIM=16 ./escrever-livro.sh       # para no capítulo 16
#   REESCREVER=1 ./escrever-livro.sh # reescreve mesmo se o capítulo já existir
#   MODELO=opus ESFORCO=medium ./escrever-livro.sh

set -euo pipefail

cd "$(dirname "$0")"

INICIO="${INICIO:-1}"
FIM="${FIM:-40}"
REESCREVER="${REESCREVER:-0}"
MODELO="${MODELO:-opus}"
ESFORCO="${ESFORCO:-medium}"

CAPITULOS=(
  01-tcp-ip-e-dns
  02-http-em-profundidade
  03-tls-e-certificados
  04-processos-threads-e-io-assincrono
  05-concorrencia-na-aplicacao
  06-desempenho-mensuravel
  07-modelagem-relacional
  08-indices
  09-planos-de-execucao
  10-transacoes-e-isolamento
  11-locks-contencao-e-pools-de-conexao
  12-migracoes-sem-downtime
  13-replicacao
  14-particionamento-e-sharding
  15-modelos-nao-relacionais
  16-cache
  17-modelos-de-consistencia
  18-tempo-ordem-e-consenso
  19-falhas-parciais
  20-idempotencia-e-semantica-de-entrega
  21-mensageria
  22-transacoes-distribuidas
  23-event-sourcing-e-cqrs
  24-estilos-de-comunicacao
  25-contratos-de-api
  26-decomposicao-de-sistemas
  27-balanceamento-e-proxies
  28-controle-de-carga
  29-escalabilidade-e-capacidade
  30-autenticacao
  31-autorizacao-e-multitenancy
  32-vulnerabilidades-de-backend
  33-criptografia-aplicada-e-segredos
  34-conteineres
  35-kubernetes
  36-redes-em-nuvem-e-infraestrutura-como-codigo
  37-ci-cd-e-estrategias-de-deploy
  38-observabilidade
  39-sli-slo-e-sla
  40-backup-e-recuperacao-de-desastres
)

# Opções comuns: sem plugins/hooks/configurações do usuário (só as do projeto),
# sem servidores MCP, sem skills, esforço reduzido.
OPCOES_COMUNS=(
  --setting-sources project
  --strict-mcp-config
  --disable-slash-commands
  --effort "$ESFORCO"
  --output-format text
)

FERRAMENTAS_ESCRITA="Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Bash"
PERMISSOES_ESCRITA="Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Bash(wc:*),Bash(sed:*),Bash(grep:*),Bash(ls:*)"

mkdir -p capitulos notas/resumos logs

# Conta palavras excluindo blocos de código.
contar_palavras() {
  sed '/^```/,/^```/d' "$1" | wc -w | tr -d ' '
}

# ---------------------------------------------------------------------------
# Prompt da escrita
# ---------------------------------------------------------------------------
read -r -d '' PROMPT_ESCRITA <<'EOF' || true
Tarefa: escrever o capítulo __NUM__ do livro em `capitulos/__ARQUIVO__.md`. Escreva apenas este capítulo. Além dele, só crie `notas/resumos/__ARQUIVO__.md`.

## Etapa 1: contexto

Leia:
- `instrucoes/livro.md`, `instrucoes/estrutura-do-capitulo.md`, `instrucoes/estilo.md`, `instrucoes/rigor-e-formatacao.md` e `instrucoes/resumos.md`.
- Os resumos já existentes em `notas/resumos/`. Eles dizem quais casos reais e exemplos já foram usados (não repita), a terminologia adotada e onde cada tema é aprofundado (para remissões). Não leia os outros capítulos inteiros. Se precisar conferir um detalhe pontual, use Grep neles.

## Etapa 2: escrita

Escreva o capítulo completo com Write, de uma vez, com 2.000 a 3.000 palavras sem contar blocos de código. O capítulo é independente: sem recapitulação, sem ponte, sem projeto contínuo; os exemplos são próprios dele. Só conteúdo técnico e objetivo, sem opinião, e muito engraçado: siga a seção "Humor" de `instrucoes/estilo.md`, com graça em todas as seções, inclusive no mecanismo. O leitor é inteligente e entende de tecnologia: explique o mecanismo diretamente, sem analogias (ver a seção "Analogias"). O leitor só lê: os exemplos de código mostram a saída, e o texto nunca pede que ele rode, instale ou experimente nada. Escreva com o seu conhecimento. Caso real só com detalhes de que você tenha certeza; na dúvida, use cenário hipotético e diga que é hipotético. Confira a contagem:

    sed '/^```/,/^```/d' capitulos/__ARQUIVO__.md | wc -w

## Etapa 3: checagem mecânica

Sem reler o capítulo inteiro:
1. Rode Grep no capítulo por "—", "não é", "não apenas", "mas também", "não se trata" e pelas palavras e expressões proibidas de `instrucoes/estilo.md`. Corrija com Edit cada ocorrência que caia num padrão proibido.
2. Humor: para cada seção `##` antes de "Resumo", confira se há momentos engraçados (a régua de `instrucoes/estilo.md` é um a cada três ou quatro parágrafos). Leia só as seções que parecerem secas e acrescente graça com Edit, sem tirar precisão.
3. Rode Grep por "rode", "rodar", "execute", "instale", "experimente", "sua máquina", "terminal", "imagine", "como se", "é como", "lembra" e "funciona como". Remova pedidos para o leitor executar algo e analogias que não passem no critério de `instrucoes/estilo.md`.
4. Se a contagem ficou fora de 2.000 a 3.000 palavras, ajuste com Edit. Nunca reescreva o arquivo inteiro.

## Etapa 4: resumo

Salve `notas/resumos/__ARQUIVO__.md` no formato de `instrucoes/resumos.md`, em estilo telegráfico, com no máximo ~200 palavras.

## Resposta final

No máximo 2 linhas, telegráfico: palavras finais; pendências para o autor (ou "nenhuma").
EOF

total="${#CAPITULOS[@]}"

for ((i = INICIO; i <= FIM && i <= total; i++)); do
  num=$(printf '%02d' "$i")
  arquivo="${CAPITULOS[$((i - 1))]}"
  capitulo="capitulos/${arquivo}.md"
  resumo="notas/resumos/${arquivo}.md"

  if [[ -f "$capitulo" && "$REESCREVER" != "1" ]]; then
    echo ">> [$num/$total] $capitulo já existe, pulando."
    continue
  fi

  # --- Escrita, checagem e resumo -------------------------------------------
  prompt="${PROMPT_ESCRITA//__NUM__/$num}"
  prompt="${prompt//__ARQUIVO__/$arquivo}"
  log="logs/${arquivo}.escrita.log"
  echo ">> [$num/$total] Escrevendo $capitulo ($(date '+%H:%M:%S')). Log: $log"

  if ! claude -p "$prompt" \
      "${OPCOES_COMUNS[@]}" \
      --model "$MODELO" \
      --tools "$FERRAMENTAS_ESCRITA" \
      --allowedTools "$PERMISSOES_ESCRITA" \
      2>&1 | tee "$log"; then
    echo "!! Falha na escrita do capítulo $num. Parando." >&2
    exit 1
  fi

  if [[ ! -f "$capitulo" ]]; then
    echo "!! O capítulo $num não foi criado ($capitulo). Parando." >&2
    exit 1
  fi

  if [[ ! -f "$resumo" ]]; then
    echo "!! O resumo do capítulo $num não foi criado ($resumo). Os próximos capítulos dependem dele. Parando." >&2
    exit 1
  fi

  palavras=$(contar_palavras "$capitulo")
  echo ">> [$num/$total] Concluído: $palavras palavras sem código."
  if ((palavras < 2000 || palavras > 3000)); then
    echo "!! Atenção: capítulo $num fora da faixa de 2.000 a 3.000 palavras." >&2
  fi
  echo
done

echo ">> Fim. Capítulos em capitulos/, notas em notas/, logs em logs/."
