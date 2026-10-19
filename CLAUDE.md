# Livro de backend — Instruções do Projeto

Esta pasta contém o manuscrito de um livro que ensina a um dev sênior full stack, que sempre foi só implementador, o conhecimento técnico para ser o líder técnico do backend: rede, banco de dados, sistemas distribuídos, arquitetura, segurança, infraestrutura e operação. Escrito em Markdown, em português do Brasil, e exportado para PDF e EPUB. São 40 capítulos curtos e independentes, em 6 partes, só com conteúdo técnico e objetivo. Exemplos em Python; nuvem neutra (provedores só como exemplo).

## Estrutura

```
.
├── CLAUDE.md            # Este arquivo: índice das instruções
├── instrucoes/          # Regras do livro, divididas por assunto
├── capitulos/           # Um arquivo .md por capítulo (o livro em si)
├── notas/
│   └── resumos/         # Resumo de cada capítulo escrito (estilo telegráfico)
├── exportacao/          # Saída gerada: livro.pdf e livro.epub
├── logs/                # Logs do script de escrita
├── escrever-livro.sh    # Script que escreve os capítulos, um por vez
└── escrever-livro.ps1   # O mesmo script, nativo para Windows (PowerShell 7)
```

## Instruções

Leia apenas os arquivos de que a tarefa precisa.

| Arquivo | Conteúdo | Quem precisa |
|---------|----------|--------------|
| `instrucoes/livro.md` | Público-alvo, proposta, capítulos independentes, tamanho, sumário completo dos 40 capítulos | Todos |
| `instrucoes/estrutura-do-capitulo.md` | Esqueleto obrigatório de cada capítulo | Escrita |
| `instrucoes/estilo.md` | Tom, voz, faça/não faça, marcas de texto de IA a evitar | Escrita |
| `instrucoes/rigor-e-formatacao.md` | Rigor técnico (versões, padrões, segurança), nuvem neutra e formatação Markdown | Escrita |
| `instrucoes/resumos.md` | Formato dos resumos de capítulo em `notas/resumos/` | Escrita |
| `instrucoes/exportacao.md` | Comandos pandoc para gerar PDF e EPUB | Exportação |

## Regras que valem sempre

- O texto do livro (`capitulos/`) segue `instrucoes/estilo.md`: linguagem natural, como se fosse falada, sem gírias e muito engraçado: humor constante em todas as seções, sem nunca sacrificar a exatidão técnica. O leitor é inteligente (sem analogias forçadas) e só lê o livro: nenhum exemplo pede que ele rode código. O estilo telegráfico das `notas/` nunca vai para o livro.
- Só conteúdo técnico e objetivo: nada de opinião, liderança de pessoas ou processo de equipe. Cada capítulo é independente, sem projeto contínuo.
- Não editar `exportacao/` manualmente.
