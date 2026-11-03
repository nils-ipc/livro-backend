# Rigor técnico e formatação

## Rigor técnico

- Código só em trechos curtos que exemplificam um conceito, nunca a implementação da Lastro (ver `instrucoes/projeto.md`). Todo trecho e todo comando que aparecer deve ser **tecnicamente correto**: se alguém rodasse, funcionaria e produziria a saída mostrada. O leitor, porém, só lê; o texto não lista pré-requisitos nem pede que ele execute nada.
- Versões de referência: Python 3.12+, PostgreSQL 16+, Redis (ou Valkey), Docker, Kubernetes e Terraform em versões atuais. Bibliotecas Python conhecidas e mantidas (FastAPI, SQLAlchemy 2.x, psycopg 3, httpx). É a mesma pilha da Lastro.
- Trechos autocontidos: mostram só o que importa para o conceito, sem configuração de ambiente, instalação ou passo a passo.
- Domínio de pagamentos: regras de cartão, do Pix, do Banco Central e do PCI DSS só com fonte verificada e só quando servem a um ponto técnico. Na dúvida, descrever o comportamento da Lastro como decisão do projeto, sem atribuí-lo a uma norma.
- Números da Lastro (volumes, metas, latências) são fictícios, plausíveis e consistentes com os resumos anteriores. Números do mundo real continuam precisando de fonte.
- Citar padrões pelo identificador exato (RFC 9110, RFC 9457, RFC 8446, ISO/IEC 9075) quando o capítulo se apoiar neles.
- Números de referência (latências, limites, tamanhos padrão) com a fonte e, se dependerem de versão, a versão. Preços, quando inevitáveis, como aproximados e com o mês/ano da consulta.
- Segurança por padrão: nenhuma senha, chave ou token no código, nem em exemplo "rápido". Ler de variável de ambiente. Nada exposto em `0.0.0.0` sem motivo explicado.
- Não recomendar ferramenta, algoritmo ou protocolo descontinuado ou inseguro (MD5 e SHA-1 para senha, TLS 1.0/1.1, fluxo implícito do OAuth) a não ser para mostrar por que não usar.

## Nuvem

- O livro é **neutro em relação a provedores**. Ensina o conceito (rede virtual, balanceador, fila gerenciada, KMS), nunca o produto.
- Serviços da AWS (ou de outro provedor) podem aparecer **só como exemplo** de implementação de um conceito, entre parênteses ou numa frase: "uma fila gerenciada (o Amazon SQS é um exemplo)". Nada de console, CLI, preços ou configuração de um provedor específico.
- Quando um exemplo de provedor for citado, citar se possível o equivalente de outro, ou deixar claro que é só um exemplo.

## Formatação

- Idioma: **português do Brasil**.
- Nome do arquivo: `NN-titulo-em-kebab-case.md`, conforme o sumário. O prefixo de dois dígitos define a ordem.
- Um único `#` por arquivo. Seções com `##` e `###`.
- Blocos de código sempre com a linguagem indicada (` ```bash `, ` ```python `, ` ```sql `, ` ```json `, ` ```http `, ` ```yaml `, ` ```hcl `, ` ```text `).
- Saídas de terminal em um bloco separado do comando quando forem longas.
- Termos em inglês que são o jargão técnico do mercado (deploy, cache, sharding, lock) ficam em inglês, em itálico na primeira aparição. São vocabulário técnico da área.
- Fórmulas em texto simples ou em bloco de código, de forma legível sem renderização de LaTeX (ex.: `L = λ × W`).
- Tabelas para comparações entre opções.
- Imagens em `capitulos/imagens/`, referenciadas com caminho relativo (`![legenda](imagens/arquivo.png)`). Diagramas da arquitetura e dos fluxos da Lastro em ASCII dentro de um bloco ` ```text `.
- Contagem de palavras sem blocos de código: `sed '/^```/,/^```/d' capitulos/ARQUIVO.md | wc -w`.
