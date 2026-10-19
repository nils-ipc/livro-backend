"""Gera exportacao/livro.pdf e exportacao/livro.epub a partir de capitulos/*.md.

Alternativa ao pandoc (ver instrucoes/exportacao.md) para máquinas onde ele não
pode ser instalado. Requer: Python 3.10+, `pip install markdown pygments` e o
Microsoft Edge (ou Chrome) para imprimir o PDF.

Uso: python exportar.py [--so-epub | --so-pdf]
"""

from __future__ import annotations

import html
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import uuid
import zipfile
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from xml.etree import ElementTree

import markdown
from pygments.formatters import HtmlFormatter

RAIZ = Path(__file__).resolve().parent
CAPITULOS = RAIZ / "capitulos"
SAIDA = RAIZ / "exportacao"

TITULO = "Além do código"
SUBTITULO = "Fundamentos técnicos para liderar o backend"
AUTOR = "Claude"
IDIOMA = "pt-BR"
DESCRICAO = (
    "O conhecimento técnico de que um dev sênior full stack precisa para "
    "liderar o backend: rede, banco de dados, sistemas distribuídos, "
    "arquitetura, segurança, infraestrutura e operação."
)

PARTES = [
    (1, 6, "Parte I", "Fundamentos de sistemas"),
    (7, 16, "Parte II", "Dados"),
    (17, 23, "Parte III", "Sistemas distribuídos"),
    (24, 29, "Parte IV", "Arquitetura e APIs"),
    (30, 33, "Parte V", "Segurança"),
    (34, 40, "Parte VI", "Infraestrutura e operação"),
]

NAVEGADORES = [
    Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
    Path(r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"),
    Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
    Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    Path("/usr/bin/google-chrome"),
    Path("/usr/bin/chromium"),
]


@dataclass
class Capitulo:
    numero: int
    arquivo: str
    titulo: str
    corpo: str  # XHTML do capítulo, sem o h1
    secoes: list[tuple[str, str]] = field(default_factory=list)  # (id, título)

    @property
    def id(self) -> str:
        return f"cap{self.numero:02d}"


def slug(prefixo: str):
    def _slug(texto: str, separador: str) -> str:
        texto = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
        texto = re.sub(r"[^\w\s-]", "", texto).strip().lower()
        return f"{prefixo}-" + re.sub(r"[\s_-]+", separador, texto)

    return _slug


def converter(caminho: Path) -> Capitulo:
    numero = int(caminho.name[:2])
    prefixo = f"cap{numero:02d}"
    md = markdown.Markdown(
        extensions=["extra", "codehilite", "toc", "sane_lists"],
        extension_configs={
            "codehilite": {"guess_lang": False, "css_class": "highlight"},
            "toc": {"slugify": slug(prefixo), "toc_depth": "1-3"},
        },
        output_format="xhtml",
    )
    corpo = md.convert(caminho.read_text(encoding="utf-8"))

    tokens = md.toc_tokens  # type: ignore[attr-defined]
    if len(tokens) != 1 or tokens[0]["level"] != 1:
        raise SystemExit(f"{caminho.name}: esperado exatamente um título nível 1")
    titulo = html.unescape(tokens[0]["name"])
    secoes = [(t["id"], html.unescape(t["name"])) for t in tokens[0]["children"] if t["level"] == 2]

    # O h1 vira a abertura do capítulo, montada em abrir_capitulo().
    corpo = re.sub(r"<h1[^>]*>.*?</h1>\s*", "", corpo, count=1, flags=re.S)
    # Chaves vazias de XHTML que o markdown às vezes deixa como HTML.
    corpo = corpo.replace("<br>", "<br />").replace("<hr>", "<hr />")
    return Capitulo(numero, caminho.name, titulo, corpo, secoes)


def parte_de(numero: int):
    for inicio, fim, rotulo, nome in PARTES:
        if inicio <= numero <= fim:
            return inicio, rotulo, nome
    raise ValueError(numero)


def esc(texto: str) -> str:
    return html.escape(texto, quote=True)


def abrir_capitulo(cap: Capitulo) -> str:
    return (
        f'<section class="capitulo" id="{cap.id}">\n'
        f'<p class="rotulo-capitulo">Capítulo {cap.numero}</p>\n'
        f'<h1 class="titulo-capitulo">{esc(cap.titulo)}</h1>\n'
        f"{cap.corpo}\n</section>\n"
    )


def pagina_parte(rotulo: str, nome: str, id_: str) -> str:
    return (
        f'<section class="parte" id="{id_}">\n'
        f'<p class="rotulo-parte">{esc(rotulo)}</p>\n'
        f'<h1 class="titulo-parte">{esc(nome)}</h1>\n</section>\n'
    )


def folha_de_rosto() -> str:
    return (
        '<section class="rosto">\n'
        f'<h1 class="titulo-livro">{esc(TITULO)}</h1>\n'
        f'<p class="subtitulo-livro">{esc(SUBTITULO)}</p>\n'
        f'<p class="autor-livro">{esc(AUTOR)}</p>\n</section>\n'
    )


def pagina_creditos() -> str:
    return (
        '<section class="creditos">\n'
        f"<p><strong>{esc(TITULO)}</strong>: {esc(SUBTITULO)}</p>\n"
        f"<p>Texto escrito por {esc(AUTOR)}, um modelo de IA da Anthropic.</p>\n"
        "<p>Versões, valores padrão e recomendações de ferramentas e padrões mudam com o tempo. "
        "Confira a documentação oficial antes de tomar decisões com base neles.</p>\n"
        f"<p>Edição gerada em {date.today():%d/%m/%Y}.</p>\n</section>\n"
    )


def css_base() -> str:
    pygments = HtmlFormatter(style="friendly").get_style_defs(".highlight")
    return (RAIZ / "exportacao.css").read_text(encoding="utf-8") + "\n" + pygments


# --------------------------------------------------------------------- PDF


def sumario_html(caps: list[Capitulo]) -> str:
    linhas = ['<nav class="sumario" id="sumario">', "<h1>Sumário</h1>", "<ol class=\"partes\">"]
    for inicio, fim, rotulo, nome in PARTES:
        linhas.append(f'<li class="parte-item"><a href="#parte{inicio}">{esc(rotulo)}: {esc(nome)}</a><ol>')
        for cap in (c for c in caps if inicio <= c.numero <= fim):
            linhas.append(
                f'<li class="cap-item"><a href="#{cap.id}"><span class="num">{cap.numero}</span> '
                f"{esc(cap.titulo)}</a><ol>"
            )
            linhas += [f'<li><a href="#{i}">{esc(t)}</a></li>' for i, t in cap.secoes]
            linhas.append("</ol></li>")
        linhas.append("</ol></li>")
    linhas += ["</ol>", "</nav>"]
    return "\n".join(linhas)


def montar_html(caps: list[Capitulo]) -> str:
    partes_vistas: set[int] = set()
    corpo = [folha_de_rosto(), pagina_creditos(), sumario_html(caps)]
    for cap in caps:
        inicio, rotulo, nome = parte_de(cap.numero)
        if inicio not in partes_vistas:
            partes_vistas.add(inicio)
            corpo.append(pagina_parte(rotulo, nome, f"parte{inicio}"))
        corpo.append(abrir_capitulo(cap))
    return (
        f'<!DOCTYPE html>\n<html lang="{IDIOMA}">\n<head>\n<meta charset="utf-8" />\n'
        f"<title>{esc(TITULO)}</title>\n<meta name=\"author\" content=\"{esc(AUTOR)}\" />\n"
        f"<style>\n{css_base()}\n</style>\n</head>\n<body class=\"pdf\">\n"
        + "\n".join(corpo)
        + "\n</body>\n</html>\n"
    )


def navegador() -> Path:
    for caminho in NAVEGADORES:
        if caminho.exists():
            return caminho
    raise SystemExit("Edge ou Chrome não encontrado; necessário para gerar o PDF.")


def imprimir_pdf(caps: list[Capitulo], tmp: Path) -> None:
    origem = tmp / "livro.html"
    origem.write_text(montar_html(caps), encoding="utf-8")
    destino = SAIDA / "livro.pdf"
    destino.unlink(missing_ok=True)
    subprocess.run(
        [
            str(navegador()),
            "--headless=new",
            "--disable-gpu",
            "--no-first-run",
            f"--user-data-dir={tmp / 'perfil'}",
            "--no-pdf-header-footer",
            "--generate-pdf-document-outline",
            f"--print-to-pdf={destino}",
            origem.as_uri(),
        ],
        check=True,
        timeout=600,
        capture_output=True,
    )
    if not destino.exists():
        raise SystemExit("O navegador não gerou o PDF.")
    print(f"PDF:  {destino} ({destino.stat().st_size / 1e6:.1f} MB)")


# -------------------------------------------------------------------- EPUB


def xhtml(titulo: str, corpo: str, extra_ns: str = "") -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n'
        f'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"{extra_ns} '
        f'lang="{IDIOMA}" xml:lang="{IDIOMA}">\n<head>\n<meta charset="utf-8" />\n'
        f'<title>{esc(titulo)}</title>\n<link rel="stylesheet" type="text/css" href="estilo.css" />\n'
        f"</head>\n<body>\n{corpo}\n</body>\n</html>\n"
    )


def gerar_epub(caps: list[Capitulo]) -> None:
    ident = f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, 'livro-backend/' + TITULO)}"
    agora = date.today().isoformat() + "T00:00:00Z"
    arquivos: list[tuple[str, str, str]] = []  # (id, href, conteúdo)

    arquivos.append(("rosto", "rosto.xhtml", xhtml(TITULO, folha_de_rosto())))
    arquivos.append(("creditos", "creditos.xhtml", xhtml("Créditos", pagina_creditos())))

    nav_itens: list[str] = []
    ncx_pontos: list[str] = []
    ordem = 0

    def ponto_ncx(texto: str, href: str, filhos: str = "") -> str:
        nonlocal ordem
        ordem += 1
        return (
            f'<navPoint id="np{ordem}" playOrder="{ordem}"><navLabel><text>{esc(texto)}</text></navLabel>'
            f'<content src="{href}"/>{filhos}</navPoint>'
        )

    for inicio, fim, rotulo, nome in PARTES:
        href_parte = f"parte{inicio}.xhtml"
        arquivos.append((f"parte{inicio}", href_parte, xhtml(rotulo, pagina_parte(rotulo, nome, f"parte{inicio}"))))
        itens_caps, pontos_caps = [], []
        for cap in (c for c in caps if inicio <= c.numero <= fim):
            href = f"{cap.id}.xhtml"
            arquivos.append((cap.id, href, xhtml(cap.titulo, abrir_capitulo(cap))))
            secoes = "".join(f'<li><a href="{href}#{i}">{esc(t)}</a></li>' for i, t in cap.secoes)
            itens_caps.append(f'<li><a href="{href}">{cap.numero}. {esc(cap.titulo)}</a><ol>{secoes}</ol></li>')
            pontos_caps.append(
                ponto_ncx(
                    f"{cap.numero}. {cap.titulo}",
                    href,
                    "".join(ponto_ncx(t, f"{href}#{i}") for i, t in cap.secoes),
                )
            )
        nav_itens.append(f'<li><a href="{href_parte}">{esc(rotulo)}: {esc(nome)}</a><ol>{"".join(itens_caps)}</ol></li>')
        ncx_pontos.append(ponto_ncx(f"{rotulo}: {nome}", href_parte, "".join(pontos_caps)))

    nav = xhtml(
        "Sumário",
        f'<nav epub:type="toc" id="toc"><h1>Sumário</h1><ol>{"".join(nav_itens)}</ol></nav>\n'
        '<nav epub:type="landmarks" hidden="hidden"><ol>'
        '<li><a epub:type="toc" href="nav.xhtml">Sumário</a></li>'
        f'<li><a epub:type="bodymatter" href="{caps[0].id}.xhtml">Início</a></li></ol></nav>',
    )
    ncx = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
        f'<head><meta name="dtb:uid" content="{ident}"/></head>\n'
        f"<docTitle><text>{esc(TITULO)}</text></docTitle>\n"
        f"<navMap>{''.join(ncx_pontos)}</navMap>\n</ncx>\n"
    )

    # Confere se cada XHTML é XML bem formado; leitores de EPUB rejeitam o arquivo se não for.
    for _, href, conteudo in arquivos + [("nav", "nav.xhtml", nav)]:
        try:
            ElementTree.fromstring(re.sub(r"<!DOCTYPE[^>]*>", "", conteudo).encode("utf-8"))
        except ElementTree.ParseError as erro:
            raise SystemExit(f"EPUB: {href} não é XHTML válido: {erro}")

    manifesto = [
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
        '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
        '<item id="css" href="estilo.css" media-type="text/css"/>',
    ] + [f'<item id="{i}" href="{h}" media-type="application/xhtml+xml"/>' for i, h, _ in arquivos]
    espinha = ['<itemref idref="rosto"/>', '<itemref idref="creditos"/>', '<itemref idref="nav"/>'] + [
        f'<itemref idref="{i}"/>' for i, _, _ in arquivos[2:]
    ]
    opf = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" '
        f'xml:lang="{IDIOMA}">\n<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        f'<dc:identifier id="bookid">{ident}</dc:identifier>\n'
        f"<dc:title>{esc(TITULO)}: {esc(SUBTITULO)}</dc:title>\n"
        f"<dc:creator>{esc(AUTOR)}</dc:creator>\n<dc:language>{IDIOMA}</dc:language>\n"
        f"<dc:description>{esc(DESCRICAO)}</dc:description>\n"
        f'<meta property="dcterms:modified">{agora}</meta>\n</metadata>\n'
        f"<manifest>\n{chr(10).join(manifesto)}\n</manifest>\n"
        f'<spine toc="ncx">\n{chr(10).join(espinha)}\n</spine>\n</package>\n'
    )
    container = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
        "</rootfiles>\n</container>\n"
    )

    destino = SAIDA / "livro.epub"
    with zipfile.ZipFile(destino, "w") as z:
        # O mimetype precisa ser o primeiro arquivo e sem compressão.
        z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/toc.ncx", ncx, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/estilo.css", css_base(), compress_type=zipfile.ZIP_DEFLATED)
        for _, href, conteudo in arquivos:
            z.writestr(f"OEBPS/{href}", conteudo, compress_type=zipfile.ZIP_DEFLATED)
    print(f"EPUB: {destino} ({destino.stat().st_size / 1e6:.1f} MB)")


def main() -> None:
    args = set(sys.argv[1:])
    caps = [converter(p) for p in sorted(CAPITULOS.glob("[0-9][0-9]-*.md"))]
    if not caps:
        raise SystemExit("Nenhum capítulo encontrado em capitulos/.")
    SAIDA.mkdir(exist_ok=True)
    if "--so-pdf" not in args:
        gerar_epub(caps)
    if "--so-epub" not in args:
        tmp = Path(tempfile.mkdtemp(prefix="livro-backend-"))
        try:
            imprimir_pdf(caps, tmp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
