# Livro de backend — Instruções do Projeto

Esta pasta contém o manuscrito de um livro que ensina a um dev sênior full stack, que sempre foi só implementador, o conhecimento técnico para ser o líder técnico do backend: rede, banco de dados, sistemas distribuídos, arquitetura, segurança, infraestrutura e operação. Escrito em Markdown, em português do Brasil, e exportado para PDF e EPUB. São 40 capítulos curtos, em 6 partes, lidos em sequência, só com conteúdo técnico e objetivo. Um projeto conduz o livro: o backend da Lastro, uma fintech fictícia de pagamentos para marketplaces (Pix, cartão, split, ledger, repasses), descrito ao longo dos capítulos e nunca implementado. Trechos de código só quando exemplificam um conceito; nuvem neutra (provedores só como exemplo).

## Estrutura

```
.
├── CLAUDE.md            # Este arquivo: índice das instruções
├── instrucoes/          # Regras do livro, divididas por assunto
├── capitulos/           # Um arquivo .md por capítulo (o livro em si)
├── notas/
│   └── resumos/         # Resumo de cada capítulo e estado da Lastro (estilo telegráfico)
├── exportacao/          # Saída gerada: livro.pdf e livro.epub
├── logs/                # Logs do script de escrita
├── escrever-livro.sh    # Script que escreve os capítulos, um por vez
└── escrever-livro.ps1   # O mesmo script, nativo para Windows (PowerShell 7)
```

## Instruções

Leia apenas os arquivos de que a tarefa precisa.

| Arquivo | Conteúdo | Quem precisa |
|---------|----------|--------------|
| `instrucoes/livro.md` | Público-alvo, proposta, capítulos em sequência, tamanho, sumário dos 40 capítulos com o roteiro da Lastro | Todos |
| `instrucoes/projeto.md` | O projeto Lastro: domínio, glossário, pilha, evolução, regras de continuidade, piadas recorrentes | Todos |
| `instrucoes/estrutura-do-capitulo.md` | Esqueleto obrigatório de cada capítulo | Escrita |
| `instrucoes/estilo.md` | Tom, voz, faça/não faça, marcas de texto de IA a evitar | Escrita |
| `instrucoes/rigor-e-formatacao.md` | Rigor técnico (versões, padrões, segurança), nuvem neutra e formatação Markdown | Escrita |
| `instrucoes/resumos.md` | Formato dos resumos de capítulo em `notas/resumos/` (memória do estado da Lastro) | Escrita |
| `instrucoes/exportacao.md` | Comandos pandoc para gerar PDF e EPUB | Exportação |

## Regras que valem sempre

- O texto do livro (`capitulos/`) segue `instrucoes/estilo.md`: cada capítulo é um show de stand-up que ensina backend: linguagem de palco, humor escrachado em todas as seções (piada idiota, humor negro, adulto e ofensivo, com os limites do arquivo), sem nunca sacrificar a exatidão técnica. O leitor é inteligente (sem analogias forçadas) e só lê o livro: nenhum exemplo pede que ele rode código. O estilo telegráfico das `notas/` nunca vai para o livro.
- Só conteúdo técnico e objetivo: nada de opinião, liderança de pessoas ou processo de equipe. Decisões da Lastro sempre justificadas por um requisito do projeto e uma propriedade técnica.
- A Lastro é descrita, nunca implementada: nada de código dos serviços; trechos curtos só para exemplificar um conceito.
- Cada capítulo parte do estado deixado pelos anteriores (registrado em `notas/resumos/`) e não o contradiz.
- Não editar `exportacao/` manualmente.
