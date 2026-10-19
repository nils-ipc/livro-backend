#Requires -Version 7
<#
.SYNOPSIS
  Escreve os capítulos do livro, um por vez, chamando o Claude Code em modo
  não interativo. Versão nativa para Windows (PowerShell 7) de escrever-livro.sh.

.DESCRIPTION
  Para cada capítulo: escreve o capítulo, faz uma checagem mecânica (grep de
  marcas de IA e contagem de palavras) e salva um resumo em notas/resumos/.

  Cada opção pode vir como parâmetro ou como variável de ambiente com o mesmo
  nome do script .sh (INICIO, FIM, REESCREVER, ...). O parâmetro tem prioridade.

.EXAMPLE
  .\escrever-livro.ps1                        # escreve todos os capítulos que ainda não existem
.EXAMPLE
  .\escrever-livro.ps1 -Inicio 5 -Fim 8       # só do capítulo 05 ao 08
.EXAMPLE
  .\escrever-livro.ps1 -Reescrever            # reescreve mesmo se o capítulo já existir
.EXAMPLE
  .\escrever-livro.ps1 -Modelo opus -Esforco medium
.EXAMPLE
  .\escrever-livro.ps1 -Claude 'C:\caminho\para\claude.exe'   # se o claude não estiver no PATH
#>
[CmdletBinding()]
param(
  [int]$Inicio = $(if ($env:INICIO) { [int]$env:INICIO } else { 1 }),
  [int]$Fim = $(if ($env:FIM) { [int]$env:FIM } else { 40 }),
  [switch]$Reescrever = ($env:REESCREVER -eq '1'),
  [string]$Modelo = $(if ($env:MODELO) { $env:MODELO } else { 'opus' }),
  [string]$Esforco = $(if ($env:ESFORCO) { $env:ESFORCO } else { 'medium' }),
  # Caminho do executável do Claude Code, se ele não estiver no PATH.
  [string]$Claude = $(if ($env:CLAUDE_BIN) { $env:CLAUDE_BIN } else { 'claude' })
)

$ErrorActionPreference = 'Stop'

# Acentos corretos no prompt enviado ao claude e na saída lida dele.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)

Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Command $Claude -ErrorAction SilentlyContinue)) {
  Write-Error "!! Claude Code não encontrado ('$Claude'). Instale o CLI ou passe o caminho com -Claude."
}

$Capitulos = @(
  '01-tcp-ip-e-dns'
  '02-http-em-profundidade'
  '03-tls-e-certificados'
  '04-processos-threads-e-io-assincrono'
  '05-concorrencia-na-aplicacao'
  '06-desempenho-mensuravel'
  '07-modelagem-relacional'
  '08-indices'
  '09-planos-de-execucao'
  '10-transacoes-e-isolamento'
  '11-locks-contencao-e-pools-de-conexao'
  '12-migracoes-sem-downtime'
  '13-replicacao'
  '14-particionamento-e-sharding'
  '15-modelos-nao-relacionais'
  '16-cache'
  '17-modelos-de-consistencia'
  '18-tempo-ordem-e-consenso'
  '19-falhas-parciais'
  '20-idempotencia-e-semantica-de-entrega'
  '21-mensageria'
  '22-transacoes-distribuidas'
  '23-event-sourcing-e-cqrs'
  '24-estilos-de-comunicacao'
  '25-contratos-de-api'
  '26-decomposicao-de-sistemas'
  '27-balanceamento-e-proxies'
  '28-controle-de-carga'
  '29-escalabilidade-e-capacidade'
  '30-autenticacao'
  '31-autorizacao-e-multitenancy'
  '32-vulnerabilidades-de-backend'
  '33-criptografia-aplicada-e-segredos'
  '34-conteineres'
  '35-kubernetes'
  '36-redes-em-nuvem-e-infraestrutura-como-codigo'
  '37-ci-cd-e-estrategias-de-deploy'
  '38-observabilidade'
  '39-sli-slo-e-sla'
  '40-backup-e-recuperacao-de-desastres'
)

# Opções comuns: sem plugins/hooks/configurações do usuário (só as do projeto),
# sem servidores MCP, sem skills, esforço reduzido.
$OpcoesComuns = @(
  '--setting-sources', 'project'
  '--strict-mcp-config'
  '--disable-slash-commands'
  '--effort', $Esforco
  '--output-format', 'text'
)

$FerramentasEscrita = 'Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Bash'
$PermissoesEscrita = 'Read,Write,Edit,Glob,Grep,WebSearch,WebFetch,Bash(wc:*),Bash(sed:*),Bash(grep:*),Bash(ls:*)'

foreach ($pasta in 'capitulos', 'notas/resumos', 'logs') {
  New-Item -ItemType Directory -Force -Path $pasta | Out-Null
}

# Conta palavras excluindo blocos de código (equivale a: sed '/^```/,/^```/d' | wc -w).
function Get-ContagemPalavras([string]$Caminho) {
  $dentroDeCodigo = $false
  $total = 0
  foreach ($linha in Get-Content -LiteralPath $Caminho -Encoding utf8) {
    if ($linha.StartsWith('```')) {
      $dentroDeCodigo = -not $dentroDeCodigo
      continue
    }
    if (-not $dentroDeCodigo) {
      $total += @($linha -split '\s+' | Where-Object { $_ -ne '' }).Count
    }
  }
  return $total
}

# Roda o claude com o prompt via stdin (evita problemas de aspas na linha de
# comando do Windows), mostra a saída na tela e grava no log.
function Invoke-Claude([string]$Prompt, [string]$Log, [string[]]$Argumentos) {
  $Prompt | & $Claude -p @OpcoesComuns @Argumentos 2>&1 |
    ForEach-Object { "$_" } |
    Tee-Object -FilePath $Log |
    Out-Host
  return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# Prompt da escrita
# ---------------------------------------------------------------------------
$PromptEscrita = @'
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
'@

$total = $Capitulos.Count

for ($i = $Inicio; $i -le $Fim -and $i -le $total; $i++) {
  $num = '{0:D2}' -f $i
  $arquivo = $Capitulos[$i - 1]
  $capitulo = "capitulos/$arquivo.md"
  $resumo = "notas/resumos/$arquivo.md"

  if ((Test-Path -LiteralPath $capitulo) -and -not $Reescrever) {
    Write-Host ">> [$num/$total] $capitulo já existe, pulando."
    continue
  }

  # --- Escrita, checagem e resumo -------------------------------------------
  $prompt = $PromptEscrita.Replace('__NUM__', $num).Replace('__ARQUIVO__', $arquivo)
  $log = "logs/$arquivo.escrita.log"
  Write-Host ">> [$num/$total] Escrevendo $capitulo ($(Get-Date -Format 'HH:mm:ss')). Log: $log"

  $ok = Invoke-Claude $prompt $log @(
    '--model', $Modelo
    '--tools', $FerramentasEscrita
    '--allowedTools', $PermissoesEscrita
  )
  if (-not $ok) {
    Write-Host "!! Falha na escrita do capítulo $num. Parando." -ForegroundColor Red
    exit 1
  }
  if (-not (Test-Path -LiteralPath $capitulo)) {
    Write-Host "!! O capítulo $num não foi criado ($capitulo). Parando." -ForegroundColor Red
    exit 1
  }
  if (-not (Test-Path -LiteralPath $resumo)) {
    Write-Host "!! O resumo do capítulo $num não foi criado ($resumo). Os próximos capítulos dependem dele. Parando." -ForegroundColor Red
    exit 1
  }

  $palavras = Get-ContagemPalavras $capitulo
  Write-Host ">> [$num/$total] Concluído: $palavras palavras sem código."
  if ($palavras -lt 2000 -or $palavras -gt 3000) {
    Write-Host "!! Atenção: capítulo $num fora da faixa de 2.000 a 3.000 palavras." -ForegroundColor Yellow
  }
  Write-Host ''
}

Write-Host '>> Fim. Capítulos em capitulos/, notas em notas/, logs em logs/.'
