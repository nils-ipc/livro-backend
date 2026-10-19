# Exportação

Requer [Pandoc](https://pandoc.org) (`brew install pandoc`). Para PDF, usa WeasyPrint (já instalado) ou um motor LaTeX.

EPUB:

```bash
pandoc capitulos/*.md -o exportacao/livro.epub \
  --toc --toc-depth=2 --resource-path=capitulos \
  --metadata title="Além do código: fundamentos técnicos para liderar o backend" \
  --metadata author="Claude" \
  --metadata lang=pt-BR
```

PDF:

```bash
pandoc capitulos/*.md -o exportacao/livro.pdf \
  --pdf-engine=weasyprint \
  --toc --toc-depth=2 --resource-path=capitulos \
  --metadata title="Além do código: fundamentos técnicos para liderar o backend" \
  --metadata author="Claude" \
  --metadata lang=pt-BR
```

Executar os comandos a partir da raiz do projeto. O glob `capitulos/*.md` respeita a ordem dos prefixos numéricos.

Não editar arquivos em `exportacao/` manualmente; eles são gerados.

## Sem pandoc (Windows com instalação bloqueada)

`exportar.py` gera os mesmos dois arquivos sem pandoc: monta o EPUB 3 direto e imprime o PDF (A4) com o Edge ou o Chrome em modo headless. Estilo em `exportacao.css`; título, subtítulo e autor ficam no topo do script.

```bash
python -m pip install --user markdown pygments
python exportar.py
```

`--so-epub` e `--so-pdf` geram só um dos formatos.
