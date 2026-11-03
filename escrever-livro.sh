#!/usr/bin/env bash
#
# Escreve os capítulos do livro chamando o Claude Code em modo não interativo,
# em lotes de POR_VEZ capítulos (padrão: 2) por chamada. Para cada capítulo do
# lote, em ordem: escreve o capítulo, faz uma checagem mecânica (grep de marcas
# de IA e contagem de palavras) e salva um resumo em notas/resumos/.
#
# Uso:
#   ./escrever-livro.sh              # escreve todos os capítulos que ainda não existem
#   INICIO=7 ./escrever-livro.sh     # começa a partir do capítulo 07
#   FIM=14 ./escrever-livro.sh       # para no capítulo 14
#   REESCREVER=1 ./escrever-livro.sh # reescreve mesmo se o capítulo já existir
#   POR_VEZ=1 ./escrever-livro.sh    # um capítulo por chamada do claude
#   MODELO=opus ESFORCO=medium ./escrever-livro.sh

set -euo pipefail

cd "$(dirname "$0")"

INICIO="${INICIO:-1}"
FIM="${FIM:-40}"
REESCREVER="${REESCREVER:-0}"
MODELO="${MODELO:-opus}"
ESFORCO="${ESFORCO:-medium}"
POR_VEZ="${POR_VEZ:-2}"

if ! [[ "$POR_VEZ" =~ ^[1-9][0-9]*$ ]]; then
  echo "!! POR_VEZ precisa ser um inteiro positivo (recebido: '$POR_VEZ')." >&2
  exit 1
fi

CAPITULOS=(
  01-modelagem-relacional
  02-concorrencia-na-aplicacao
  03-transacoes-e-isolamento
  04-locks-contencao-e-pools-de-conexao
  05-indices
  06-planos-de-execucao
  07-migracoes-sem-downtime
  08-tcp-ip-e-dns
  09-http-em-profundidade
  10-tls-e-certificados
  11-contratos-de-api
  12-estilos-de-comunicacao
  13-processos-threads-e-io-assincrono
  14-desempenho-mensuravel
  15-falhas-parciais
  16-idempotencia-e-semantica-de-entrega
  17-mensageria
  18-transacoes-distribuidas
  19-modelos-de-consistencia
  20-tempo-ordem-e-consenso
  21-event-sourcing-e-cqrs
  22-cache
  23-replicacao
  24-particionamento-e-sharding
  25-modelos-nao-relacionais
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
Tarefa: escrever __QTD__ do livro, em ordem:

__LISTA__

Não escreva nenhum outro capítulo. Além dos capítulos, só crie os resumos indicados.

Escreva um capítulo por vez: cumpra as etapas 2 a 4 inteiras para um capítulo (escrita, checagem e resumo) antes de começar o seguinte. O resumo de um capítulo faz parte do contexto do próximo.

## Etapa 1: contexto (uma vez, no início)

Leia:
- `instrucoes/livro.md`, `instrucoes/estrutura-do-capitulo.md`, `instrucoes/estilo.md`, `instrucoes/rigor-e-formatacao.md` e `instrucoes/resumos.md`.
- `instrucoes/projeto.md`: o projeto Lastro que conduz o livro. Na tabela do sumário em `instrucoes/livro.md`, a linha de cada capítulo (coluna "Na Lastro") é o roteiro dele; a do capítulo seguinte diz para onde apontar no fim.
- Todos os resumos já existentes em `notas/resumos/`, em ordem. Eles registram o estado da Lastro (componentes, decisões, números), que cada capítulo continua e não pode contradizer, além dos casos reais já usados (não repita), da terminologia adotada, de onde cada tema é aprofundado (para remissões) e das piadas recorrentes. Não leia os outros capítulos inteiros. Se precisar conferir um detalhe pontual, use Grep neles.

## Etapa 2: escrita

Escreva o capítulo completo com Write, de uma vez, com 2.000 a 3.000 palavras sem contar blocos de código. O capítulo parte de um problema da Lastro, ensina o mecanismo em termos gerais e aplica-o ao projeto, seguindo `instrucoes/estrutura-do-capitulo.md` (inclusive a seção "A Lastro agora" no fim). O projeto é descrito, nunca implementado: decisões justificadas por requisitos do projeto, fluxos, esquemas conceituais, diagramas em ASCII e tabelas; código só em trechos curtos quando for muito importante para exemplificar um conceito. Só conteúdo técnico e objetivo, sem opinião, e escrito como um show de stand-up: siga a seção "Humor" de `instrucoes/estilo.md` (abertura, bits, tags, callbacks e fechamento; humor escrachado, dentro dos limites), com piada em todas as seções, inclusive no mecanismo. O leitor é inteligente e entende de tecnologia: explique o mecanismo diretamente, sem analogias (ver a seção "Analogias"). O leitor só lê: os exemplos de código mostram a saída, e o texto nunca pede que ele rode, instale ou experimente nada. Escreva com o seu conhecimento. Caso real só com detalhes de que você tenha certeza; na dúvida, use cenário hipotético e diga que é hipotético. Confira a contagem (troque pelo arquivo do capítulo):

    sed '/^```/,/^```/d' capitulos/NN-nome.md | wc -w

## Etapa 3: checagem mecânica

Sem reler o capítulo inteiro:
1. Rode Grep no capítulo por "—", "não é", "não apenas", "mas também", "não se trata" e pelas palavras e expressões proibidas de `instrucoes/estilo.md`. Corrija com Edit cada ocorrência que caia num padrão proibido.
2. Humor: para cada seção `##` antes de "Resumo", confira a régua de `instrucoes/estilo.md` (uma piada a cada parágrafo ou dois e pelo menos um bit forte por seção) e aplique o teste da risada: piada que só arranca sorrisinho é reescrita mais pesada, mais absurda ou mais idiota, ou cortada. Confira também os limites do humor (alvo, pessoas reais, exatidão). Corrija com Edit, sem tirar precisão.
3. Rode Grep por "rode", "rodar", "execute", "instale", "experimente", "sua máquina", "terminal", "imagine", "como se", "é como", "lembra" e "funciona como". Remova pedidos para o leitor executar algo e analogias que não passem no critério de `instrucoes/estilo.md`.
4. Rode Grep por "```" e confira cada bloco de código: precisa exemplificar um conceito, ter até ~15 linhas e não ser implementação da Lastro (diagramas ` ```text ` estão liberados). Corte ou troque por descrição o que não passar.
5. Se a contagem ficou fora de 2.000 a 3.000 palavras, ajuste com Edit. Nunca reescreva o arquivo inteiro.

## Etapa 4: resumo

Salve o resumo do capítulo no caminho indicado na lista, no formato de `instrucoes/resumos.md`, em estilo telegráfico, com no máximo ~250 palavras. A seção "A Lastro ao fim do capítulo" é a mais importante: os próximos capítulos dependem dela, inclusive o seguinte desta tarefa, que só começa depois que este resumo estiver salvo.

## Resposta final

Uma linha por capítulo, telegráfico: número; palavras finais; pendências para o autor (ou "nenhuma").
EOF

total="${#CAPITULOS[@]}"

# Capítulos a escrever, em ordem.
pendentes=()
for ((i = INICIO; i <= FIM && i <= total; i++)); do
  num=$(printf '%02d' "$i")
  capitulo="capitulos/${CAPITULOS[$((i - 1))]}.md"
  if [[ -f "$capitulo" && "$REESCREVER" != "1" ]]; then
    echo ">> [$num/$total] $capitulo já existe, pulando."
    continue
  fi
  pendentes+=("$i")
done

# Uma chamada do claude por lote de até POR_VEZ capítulos.
for ((p = 0; p < ${#pendentes[@]}; p += POR_VEZ)); do
  lote=("${pendentes[@]:p:POR_VEZ}")

  lista=""
  nums=()
  for i in "${lote[@]}"; do
    num=$(printf '%02d' "$i")
    arquivo="${CAPITULOS[$((i - 1))]}"
    lista+="- Capítulo ${num}: \`capitulos/${arquivo}.md\`, resumo em \`notas/resumos/${arquivo}.md\`."$'\n'
    nums+=("$num")
  done
  if ((${#lote[@]} == 1)); then
    qtd="1 capítulo"
    log="logs/${CAPITULOS[$((lote[0] - 1))]}.escrita.log"
  else
    qtd="${#lote[@]} capítulos"
    log="logs/${nums[0]}-${nums[-1]}.escrita.log"
  fi

  # --- Escrita, checagem e resumo -------------------------------------------
  prompt="${PROMPT_ESCRITA//__QTD__/$qtd}"
  prompt="${prompt//__LISTA__/${lista%$'\n'}}"
  echo ">> [${nums[*]}/$total] Escrevendo $qtd ($(date '+%H:%M:%S')). Log: $log"

  if ! claude -p "$prompt" \
      "${OPCOES_COMUNS[@]}" \
      --model "$MODELO" \
      --tools "$FERRAMENTAS_ESCRITA" \
      --allowedTools "$PERMISSOES_ESCRITA" \
      2>&1 | tee "$log"; then
    echo "!! Falha na escrita dos capítulos ${nums[*]}. Parando." >&2
    exit 1
  fi

  for i in "${lote[@]}"; do
    num=$(printf '%02d' "$i")
    arquivo="${CAPITULOS[$((i - 1))]}"
    capitulo="capitulos/${arquivo}.md"
    resumo="notas/resumos/${arquivo}.md"

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
  done
  echo
done

echo ">> Fim. Capítulos em capitulos/, notas em notas/, logs em logs/."
