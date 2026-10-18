#!/usr/bin/env python3
"""Générateur PDF du cours MLOps : énoncés Markdown (labs, syllabus) -> PDF.

Reproduit la charte des PDF originaux (ReportLab) : couverture bleu nuit pleine page,
en-tête/pied de page, bandeaux d'étape, encadrés colorés, blocs de code, tables zébrées.

Usage :
    uv run --project tools/build_pdf python tools/build_pdf/build.py labs/*/README.md -o dist/pdf

Format d'entrée : voir CONVENTIONS.md §6 (front matter YAML + Markdown GFM + alertes GitHub).
"""

from __future__ import annotations

import argparse
import dataclasses
import re
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from xml.sax.saxutils import escape as _xml_escape

import yaml
from markdown_it import MarkdownIt
from markdown_it.tree import SyntaxTreeNode
from pygments import lex
from pygments.lexers import get_lexer_by_name
from pygments.token import Token
from pygments.util import ClassNotFound
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_JUSTIFY, TA_LEFT, TA_RIGHT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.lib.utils import simpleSplit
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate,
    CondPageBreak,
    Flowable,
    Frame,
    NextPageTemplate,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)

# --------------------------------------------------------------------------------------
# Charte graphique (couleurs mesurées dans les PDF originaux)
# --------------------------------------------------------------------------------------
HEX = {
    "navy": "#0B1E3F",  # couverture, titres, en-têtes de table
    "ink": "#0F172A",  # texte courant
    "teal": "#14B8A6",  # accents (kicker, étapes, sous-titres, puces)
    "teal_dark": "#0F766E",  # liens
    "green": "#16A34A",  # « Sortie attendue », validation
    "muted": "#64748B",  # en-tête/pied, sous-titre, durée
    "cover_soft": "#C9D6E8",  # textes secondaires de couverture
    "rule": "#DBE2EC",  # filets, grilles
    "code_border": "#CBD5E1",
    "code_bg": "#F1F5F9",
    "step_bg": "#E8EEF7",
    "zebra": "#F8FAFC",
    "amber": "#D97706",
    "amber_badge": "#F59E0B",
    "red": "#DC2626",
    "purple": "#7C3AED",
    "info_bg": "#EFF6FF",
    "ok_bg": "#DCFCE7",
    "sortie_bg": "#F0FDF4",
    "warn_bg": "#FEF3C7",
    "danger_bg": "#FEE2E2",
    "quote_bg": "#F8FAFC",
    # coloration syntaxique sobre
    "kw": "#1E3A8A",
    "str": "#0F766E",
    "num": "#B45309",
    "var": "#7C3AED",
}
C = {k: colors.HexColor(v) for k, v in HEX.items()}

PAGE_W, PAGE_H = A4
MARGIN_X = 18 * mm  # 51.02 pt, comme l'original
CONTENT_W = PAGE_W - 2 * MARGIN_X  # 493.2 pt
FRAME_TOP = 778.0
FRAME_BOTTOM = 54.0
TEXT_INSET = 6.0  # le texte courant est en retrait de 6 pt par rapport aux encadrés

# --------------------------------------------------------------------------------------
# Polices embarquées (fonts/) : Liberation Sans (OFL), DejaVu Sans Mono / DejaVu Sans (Vera)
# --------------------------------------------------------------------------------------
FONT_DIR = Path(__file__).resolve().parent / "fonts"
FONT_FILES = {
    "Sans": "LiberationSans-Regular.ttf",
    "Sans-Bold": "LiberationSans-Bold.ttf",
    "Sans-Italic": "LiberationSans-Italic.ttf",
    "Sans-BoldItalic": "LiberationSans-BoldItalic.ttf",
    "Mono": "DejaVuSansMono.ttf",
    "Mono-Bold": "DejaVuSansMono-Bold.ttf",
    "Mono-Oblique": "DejaVuSansMono-Oblique.ttf",
    "Sym": "DejaVuSans.ttf",
    "Sym-Bold": "DejaVuSans-Bold.ttf",
}
COVER: dict[str, set[int]] = {}


def register_fonts() -> None:
    for name, fname in FONT_FILES.items():
        path = FONT_DIR / fname
        if not path.exists():
            sys.exit(f"Police manquante : {path}")
        font = TTFont(name, str(path))
        pdfmetrics.registerFont(font)
        COVER[name] = set(font.face.charToGlyph)
    pdfmetrics.registerFontFamily(
        "Sans", normal="Sans", bold="Sans-Bold", italic="Sans-Italic", boldItalic="Sans-BoldItalic"
    )
    pdfmetrics.registerFontFamily(
        "Mono", normal="Mono", bold="Mono-Bold", italic="Mono-Oblique", boldItalic="Mono-Bold"
    )
    pdfmetrics.registerFontFamily(
        "Sym", normal="Sym", bold="Sym-Bold", italic="Sym", boldItalic="Sym-Bold"
    )


# Emoji (absents des polices vectorielles) -> glyphe DejaVu équivalent + couleur
EMOJI_SUBST = {
    "\u2705": ("\u2714", "green"),  # ✅ -> ✔
    "\u2714": ("\u2714", "green"),  # ✔
    "\u2611": ("\u2611", "green"),  # ☑
    "\u274c": ("\u2718", "red"),  # ❌ -> ✘
    "\u274e": ("\u2718", "red"),
    "\u2716": ("\u2718", "red"),
    "\u26a0": ("\u26a0", "amber"),  # ⚠
    "\U0001f389": ("\u2605", "teal"),  # 🎉 -> ★
    "\U0001f973": ("\u2605", "teal"),  # 🥳
    "\u2728": ("\u2726", "teal"),  # ✨ -> ✦
    "\U0001f680": ("\u279c", "teal"),  # 🚀 -> ➜
    "\U0001f449": ("\u279c", "ink"),  # 👉
    "\u27a1": ("\u279c", "ink"),
    "\U0001f4a1": ("\u2726", "amber"),  # 💡
    "\u2b50": ("\u2605", "amber"),  # ⭐
    "\U0001f534": ("\u25cf", "red"),  # 🔴
    "\U0001f7e0": ("\u25cf", "amber"),  # 🟠
    "\U0001f7e1": ("\u25cf", "amber"),  # 🟡
    "\U0001f7e2": ("\u25cf", "green"),  # 🟢
    "\U0001f6a8": ("\u26a0", "red"),  # 🚨
    "\U0001f4cc": ("\u25b8", "red"),  # 📌
    "\U0001f512": ("\u25a0", "muted"),  # 🔒
}
IGNORED_CHARS = {"\ufe0f", "\ufe0e", "\u200d"}  # sélecteurs de variante, ZWJ
MISSING_GLYPHS: set[str] = set()


def esc(text: str) -> str:
    return _xml_escape(text, {'"': "&quot;"})


def glyph_runs(text: str, family: str) -> list[tuple[str, str | None, str | None]]:
    """Découpe `text` en segments (texte, police, couleur) selon la couverture des polices.

    police None = police courante ; les glyphes absents passent en DejaVu Sans (« Sym »),
    les emoji sont substitués par un glyphe monochrome coloré.
    """
    runs: list[tuple[str, str | None, str | None]] = []
    cover = COVER[family]

    def push(ch: str, font: str | None, color: str | None) -> None:
        if runs and runs[-1][1] == font and runs[-1][2] == color:
            runs[-1] = (runs[-1][0] + ch, font, color)
        else:
            runs.append((ch, font, color))

    for ch in text:
        if ch in IGNORED_CHARS:
            continue
        sub = EMOJI_SUBST.get(ch)
        if sub:
            glyph, col = sub
            if ord(glyph) not in COVER["Sym"]:
                glyph = "*"
            push(glyph, "Sym", col)
            continue
        cp = ord(ch)
        if cp in cover or ch in "\n\t":
            push(ch, None, None)
        elif cp in COVER["Sym"]:
            push(ch, "Sym", None)
        else:
            MISSING_GLYPHS.add(ch)
            push("\u25a1", "Sym", "muted")
    return runs


def run_markup(text: str, family: str = "Sans") -> str:
    """Texte brut -> balisage Paragraph échappé, avec repli de police glyphe par glyphe."""
    out = []
    for chunk, font, col in glyph_runs(text, family):
        s = esc(chunk)
        if font is None and col is None:
            out.append(s)
        else:
            attrs = []
            if font:
                attrs.append(f'name="{font}"')
            if col:
                attrs.append(f'color="{HEX[col]}"')
            out.append(f"<font {' '.join(attrs)}>{s}</font>")
    return "".join(out)


_NBSP_BEFORE = re.compile(r" ([:;!?»])")
_NBSP_AFTER = re.compile(r"« ")


def french_spaces(text: str) -> str:
    """Espaces insécables de la typographie française (pas de « : » en début de ligne)."""
    text = _NBSP_BEFORE.sub("\u00a0\\1", text)
    return _NBSP_AFTER.sub("«\u00a0", text)


_URL_RE = re.compile(r"https?://[^\s<>()\[\]{}\"'`]+[^\s<>()\[\]{}\"'`.,;:!?»)]")

# --------------------------------------------------------------------------------------
# Styles de paragraphe
# --------------------------------------------------------------------------------------
_STYLE_CACHE: dict[tuple, ParagraphStyle] = {}


def pstyle(**kw) -> ParagraphStyle:
    base = dict(
        fontName="Sans",
        fontSize=10.5,
        leading=14,
        textColor=C["ink"],
        alignment=TA_LEFT,
        spaceBefore=0,
        spaceAfter=0,
        leftIndent=0,
        rightIndent=0,
        bulletIndent=0,
        bulletFontName="Sans-Bold",
        allowWidows=0,
        allowOrphans=0,
        splitLongWords=1,
    )
    base.update(kw)
    key = tuple(sorted((k, str(v)) for k, v in base.items()))
    st = _STYLE_CACHE.get(key)
    if st is None:
        st = ParagraphStyle(f"s{len(_STYLE_CACHE)}", **base)
        _STYLE_CACHE[key] = st
    return st


class SmartPara(Paragraph):
    """Paragraphe justifié qui ne justifie pas les lignes trop étirées.

    Une ligne coupée avant un long `code` ou une URL serait étirée avec des blancs
    énormes : on la laisse alignée à gauche (comme le ferait TeX avec une ligne creuse).
    """

    def wrap(self, aw, ah):
        r = super().wrap(aw, ah)
        if self.style.alignment == TA_JUSTIFY and hasattr(self, "blPara"):
            lim = 0.36 * self.style.fontSize
            bl = self.blPara
            lines = bl.lines
            for i in range(len(lines) - 1):
                line = lines[i]
                if bl.kind == 1:
                    n = line.wordCount - 1
                    if n > 0 and line.extraSpace / n > lim:
                        line.lineBreak = True
                else:
                    extra, words = line
                    n = len(words) - 1
                    if n > 0 and extra / n > lim:
                        lines[i] = (0, words)
        return r


# --------------------------------------------------------------------------------------
# Flowables
# --------------------------------------------------------------------------------------
class OutlineState:
    """Niveaux de signets PDF (ReportLab refuse un saut de plus d'un niveau)."""

    def __init__(self) -> None:
        self.last = -1
        self.keys: set[str] = set()

    def level(self, wanted: int) -> int:
        lvl = max(0, min(wanted, self.last + 1))
        self.last = lvl
        return lvl

    def unique(self, key: str) -> str:
        """Ancre unique, règle GitHub : « titre », « titre-1 », « titre-2 »…"""
        base, n = key or "section", 0
        key = base
        while key in self.keys:
            n += 1
            key = f"{base}-{n}"
        self.keys.add(key)
        return key


class Anchored(Flowable):
    """Enveloppe un flowable « titre » : signet PDF + entrée du sommaire latéral."""

    def __init__(self, inner: Flowable, key: str, title: str | None, level: int, outline: OutlineState):
        super().__init__()
        self.inner = inner
        self.key = key
        self.title = title
        self.level = level
        self.outline = outline

    def wrap(self, aw, ah):
        w, h = self.inner.wrap(aw, ah)
        self.width, self.height = aw, h
        return aw, h

    def getSpaceBefore(self):
        return self.inner.getSpaceBefore()

    def getSpaceAfter(self):
        return self.inner.getSpaceAfter()

    def split(self, aw, ah):
        return []

    def draw(self):
        canv = self.canv
        canv.bookmarkHorizontal(self.key, 0, self.height + 4)
        if self.title:
            lvl = self.outline.level(self.level)
            canv.addOutlineEntry(self.title, self.key, level=lvl, closed=lvl >= 1)
        self.inner.drawOn(canv, 0, 0)


class Indented(Flowable):
    """Décale un flowable (listes, retrait du texte) tout en conservant la coupure de page."""

    def __init__(self, inner: Flowable, left: float = 0.0, right: float = 0.0):
        super().__init__()
        self.inner, self.left, self.right = inner, left, right

    def wrap(self, aw, ah):
        w, h = self.inner.wrap(max(aw - self.left - self.right, 20), ah)
        self.width, self.height = aw, h
        return aw, h

    def split(self, aw, ah):
        parts = self.inner.split(max(aw - self.left - self.right, 20), ah)
        return [Indented(p, self.left, self.right) for p in parts]

    def getSpaceBefore(self):
        return self.inner.getSpaceBefore()

    def getSpaceAfter(self):
        return self.inner.getSpaceAfter()

    def draw(self):
        self.inner.drawOn(self.canv, self.left, 0)


def indented(f: Flowable, left: float, right: float) -> Flowable:
    if abs(left) < 0.01 and abs(right) < 0.01:
        return f
    return Indented(f, left, right)


class KeepWithNext(CondPageBreak):
    """Saut de page conditionnel : un titre n'est jamais laissé seul en bas de page.

    Exige la place des titres du groupe + min(hauteur du bloc suivant, `min_after`).
    """

    def __init__(self, group: list[Flowable], nxt: Flowable | None, min_after: float = 64):
        super().__init__(0)
        self.group, self.nxt, self.min_after = group, nxt, min_after

    def wrap(self, aw, ah):
        need = 4.0  # marge de sécurité (arrondis, interlignage)
        for f in self.group:
            _, h = f.wrap(aw, ah)
            need += h + f.getSpaceAfter() + f.getSpaceBefore()
        if self.nxt is not None:
            _, h = self.nxt.wrap(aw, 10_000)
            need += self.nxt.getSpaceBefore() + min(h, self.min_after)
        self.height = need
        return super().wrap(aw, ah)


class Box(Flowable):
    """Encadré (alerte, « Sortie attendue », citation) sécable sur plusieurs pages."""

    def __init__(self, content, *, bg, bar=None, bar_w=3.0, border=None, pad=(9, 12, 9, 12),
                 space_before=6, space_after=10):
        super().__init__()
        self.content = list(content)
        self.bg, self.bar, self.bar_w, self.border = bg, bar, bar_w, border
        self.pt, self.pr, self.pb, self.pl = pad
        self.spaceBefore, self.spaceAfter = space_before, space_after

    def _clone(self, content, first: bool, last: bool) -> "Box":
        b = Box(content, bg=self.bg, bar=self.bar, bar_w=self.bar_w, border=self.border,
                pad=(self.pt, self.pr, self.pb, self.pl),
                space_before=self.spaceBefore if first else 0,
                space_after=self.spaceAfter if last else 0)
        return b

    def _inner_w(self, aw):
        return aw - self.pl - self.bar_w - self.pr

    def _layout(self, aw):
        iw = self._inner_w(aw)
        items, prev_after = [], 0.0
        for i, f in enumerate(self.content):
            _, h = f.wrap(iw, 10_000)
            gap = max(prev_after, f.getSpaceBefore()) if i else 0.0
            items.append((f, h, gap))
            prev_after = f.getSpaceAfter()
        return items

    def wrap(self, aw, ah):
        self.width = aw
        self._items = self._layout(aw)
        self.height = self.pt + self.pb + sum(h + g for _, h, g in self._items)
        return aw, self.height

    def split(self, aw, ah):
        iw = self._inner_w(aw)
        avail = ah - self.pt - self.pb
        if avail < 36:
            return []
        items = self._layout(aw)
        used, head = 0.0, []
        for idx, (f, h, gap) in enumerate(items):
            if used + gap + h <= avail:
                head.append(f)
                used += gap + h
                continue
            rest = [x[0] for x in items[idx + 1:]]
            parts = f.split(iw, avail - used - gap) if avail - used - gap > 24 else []
            if len(parts) >= 2:
                head.append(parts[0])
                tail = list(parts[1:]) + rest
            else:
                tail = [f] + rest
            if not head or (len(head) == 1 and len(parts) < 2 and used < 20):
                return []
            return [self._clone(head, True, False), self._clone(tail, False, True)]
        return [self]

    def draw(self):
        canv = self.canv
        w, h = self.width, self.height
        canv.saveState()
        canv.setFillColor(self.bg)
        canv.rect(0, 0, w, h, stroke=0, fill=1)
        if self.border is not None:
            canv.setStrokeColor(self.border)
            canv.setLineWidth(0.5)
            canv.rect(0, 0, w, h, stroke=1, fill=0)
        if self.bar is not None:
            canv.setStrokeColor(self.bar)
            canv.setLineWidth(self.bar_w)
            canv.line(self.bar_w / 2, 0, self.bar_w / 2, h)
        canv.restoreState()
        y = h - self.pt
        x = self.bar_w + self.pl
        for f, fh, gap in self._items:
            y -= gap + fh
            f.drawOn(canv, x, y)


class CodeBlock(Flowable):
    """Bloc de code : fond gris bordé, coloration sobre, retour à la ligne visuel (↪), sécable."""

    PAD_X, PAD_Y = 9.0, 7.0
    MAX_SIZE, MIN_SIZE = 8.0, 7.2
    CONT = "\u21aa "  # ↪ en début de ligne de continuation

    def __init__(self, lines, size: float | None = None, first=True, last=True):
        super().__init__()
        self.lines = lines  # liste de lignes ; ligne = liste de (texte, police, couleur)
        self.size = size
        self.first, self.last = first, last
        self.spaceBefore = 3 if first else 0
        self.spaceAfter = 8 if last else 0

    @staticmethod
    def _len(line) -> int:
        return sum(len(t) for t, _, _ in line)

    def _metrics(self, aw):
        inner = aw - 2 * self.PAD_X
        if self.size is None:
            longest = max((self._len(ln) for ln in self.lines), default=1) or 1
            size = inner / (longest * 0.6021)
            self.size = max(self.MIN_SIZE, min(self.MAX_SIZE, size))
            if size < self.MIN_SIZE:  # on renonce à rétrécir : retour à la ligne à taille normale
                self.size = self.MAX_SIZE
        cw = pdfmetrics.stringWidth("M", "Mono", self.size)
        cols = max(int(inner // cw), 20)
        leading = round(self.size * 1.32, 2)
        return cols, leading, cw

    def _wrap_line(self, line, cols):
        """Coupe une ligne logique en lignes visuelles de `cols` caractères au plus."""
        chars = [(ch, font, col) for text, font, col in line for ch in text]
        if len(chars) <= cols:
            return [line]
        text = "".join(c for c, _, _ in chars)
        indent = min(len(text) - len(text.lstrip(" ")), cols // 3)
        out, start, first = [], 0, True
        while start < len(chars):
            width = cols if first else cols - indent - len(self.CONT)
            end = start + width
            if end < len(chars):
                window = text[start:end]
                for seps, ratio in ((" ", 0.55), (",;", 0.5), ("/-.=&|:", 0.6)):
                    cut = max(window.rfind(c) for c in seps)
                    if cut > width * ratio:
                        end = start + cut + 1
                        break
            piece = chars[start:end]
            segs: list[tuple[str, str, str]] = []
            if not first:
                segs.append((" " * indent, "Mono", "ink"))
                segs.append((self.CONT, "Mono", "teal"))
                while piece and piece[0][0] == " ":
                    piece = piece[1:]
            for ch, font, col in piece:
                if segs and segs[-1][1] == font and segs[-1][2] == col:
                    segs[-1] = (segs[-1][0] + ch, font, col)
                else:
                    segs.append((ch, font, col))
            out.append(segs)
            start, first = end, False
        return out

    def _visual(self, aw):
        cols, leading, cw = self._metrics(aw)
        vis = [self._wrap_line(ln, cols) for ln in self.lines]
        return vis, leading

    def wrap(self, aw, ah):
        self._vis, self._leading = self._visual(aw)
        n = sum(len(v) for v in self._vis)
        self.width = aw
        self.height = 2 * self.PAD_Y + n * self._leading + 1
        return aw, self.height

    def split(self, aw, ah):
        vis, leading = self._visual(aw)
        total = sum(len(v) for v in vis)
        fit = int((ah - 2 * self.PAD_Y - 1) // leading)
        if fit < 3 or total < 5:
            return []
        k, count = 0, 0
        while k < len(vis) and count + len(vis[k]) <= fit:
            count += len(vis[k])
            k += 1
        if total - count < 2 and k > 1:  # pas de ligne veuve isolée en haut de page
            k -= 1
            count -= len(vis[k])
        if k == 0 or count < 2:
            return []
        return [
            CodeBlock(self.lines[:k], self.size, self.first, False),
            CodeBlock(self.lines[k:], self.size, False, self.last),
        ]

    def draw(self):
        canv = self.canv
        w, h = self.width, self.height
        canv.saveState()
        canv.setFillColor(C["code_bg"])
        canv.setStrokeColor(C["code_border"])
        canv.setLineWidth(0.5)
        canv.rect(0, 0, w, h, stroke=1, fill=1)
        y = h - self.PAD_Y - self.size * 0.95
        for vlines in self._vis:
            for segs in vlines:
                tx = canv.beginText(self.PAD_X, y)
                for text, font, col in segs:
                    tx.setFont(font, self.size)
                    tx.setFillColor(C[col])
                    tx.textOut(text)
                canv.drawText(tx)
                y -= self._leading
        canv.restoreState()


class StepBanner(Flowable):
    """Bandeau d'étape : fond bleu clair, « ÉTAPE N / T » teal, titre, durée, filet teal."""

    def __init__(self, num: str, total: str, title_markup: str, duration: str):
        super().__init__()
        self.label = f"ÉTAPE {num} / {total}"
        self.title = Paragraph(title_markup, pstyle(fontName="Sans-Bold", fontSize=13, leading=16,
                                                      textColor=C["navy"]))
        self.duration = duration
        self.spaceBefore, self.spaceAfter = 16, 10

    def wrap(self, aw, ah):
        self.width = aw
        self.label_w = pdfmetrics.stringWidth(self.label, "Sans-Bold", 13)
        self.dur_w = max(pdfmetrics.stringWidth(self.duration, "Sans", 10), 40)
        tw = aw - 12 - self.label_w - 12 - 14 - self.dur_w - 12
        _, th = self.title.wrap(tw, ah)
        self.th = th
        self.height = max(32.0, th + 16)
        return aw, self.height

    def split(self, aw, ah):
        return []

    def draw(self):
        canv = self.canv
        w, h = self.width, self.height
        canv.saveState()
        canv.setFillColor(C["step_bg"])
        canv.rect(0, 0, w, h, stroke=0, fill=1)
        canv.setStrokeColor(C["teal"])
        canv.setLineWidth(2)
        canv.line(0, 0, w, 0)
        # libellé sur la ligne de base de la 1re ligne du titre (titre sur 1 ou 2 lignes)
        label_y = h - 8 - 13 * 0.93 if self.th > 16 else (h - 13 * 0.72) / 2
        canv.setFillColor(C["teal"])
        canv.setFont("Sans-Bold", 13)
        canv.drawString(12, label_y, self.label)
        canv.setFillColor(C["muted"])
        canv.setFont("Sans", 10)
        canv.drawRightString(w - 12, (h - 10 * 0.72) / 2, self.duration)
        canv.restoreState()
        ty = (h - self.th) / 2
        self.title.drawOn(canv, 12 + self.label_w + 12, ty)


class ModuleBanner(Flowable):
    """Bandeau de module du syllabus : pavé coloré « MODULE N » + titre + filet teal."""

    BADGE = {0: "navy", 10: "navy"}

    def __init__(self, num: int, title_markup: str):
        super().__init__()
        self.num = num
        color = self.BADGE.get(num)
        if color is None:
            color = "teal" if num <= 3 else "amber_badge" if num <= 6 else "purple"
        self.color = C[color]
        self.title = Paragraph(title_markup, pstyle(fontName="Sans-Bold", fontSize=18, leading=22,
                                                      textColor=C["navy"]))
        self.spaceBefore, self.spaceAfter = 4, 8

    def wrap(self, aw, ah):
        self.width = aw
        _, self.th = self.title.wrap(aw - 85 - 10 - 6, ah)
        self.height = max(42.0, self.th + 16)
        return aw, self.height

    def split(self, aw, ah):
        return []

    def draw(self):
        canv = self.canv
        w, h = self.width, self.height
        canv.saveState()
        canv.setFillColor(self.color)
        canv.rect(0, 0, 85, h, stroke=0, fill=1)
        canv.setFillColor(colors.white)
        canv.setFont("Mono-Bold", 13)
        canv.drawCentredString(42.5, h / 2 - 4.5, f"MODULE {self.num}")
        canv.setStrokeColor(C["teal"])
        canv.setLineWidth(2)
        canv.line(0, 0, w, 0)
        canv.restoreState()
        self.title.drawOn(canv, 95, (h - self.th) / 2)


class HRule(Flowable):
    def __init__(self):
        super().__init__()
        self.spaceBefore, self.spaceAfter = 6, 8

    def wrap(self, aw, ah):
        self.width, self.height = aw, 1
        return aw, 1

    def draw(self):
        self.canv.setStrokeColor(C["rule"])
        self.canv.setLineWidth(0.8)
        self.canv.line(0, 0.5, self.width, 0.5)


class LazyTable(Flowable):
    """Table GFM construite à la largeur disponible (colonnes proportionnelles au contenu)."""

    def __init__(self, builder):
        super().__init__()
        self.builder = builder
        self._table = None
        self._aw = None
        self.spaceBefore, self.spaceAfter = 4, 10

    def _get(self, aw):
        if self._table is None or abs(self._aw - aw) > 0.5:
            self._table, self._aw = self.builder(aw), aw
        return self._table

    def wrap(self, aw, ah):
        t = self._get(aw)
        w, h = t.wrap(aw, ah)
        self.width, self.height = aw, h
        return aw, h

    def split(self, aw, ah):
        t = self._get(aw)
        t.wrap(aw, ah)
        rh = list(t._rowHeights)
        n, acc = 0, 0.0
        for h in rh:
            if acc + h > ah:
                break
            acc += h
            n += 1
        body_total, body_first = len(rh) - 1, n - 1
        if body_first >= body_total:
            return [t]
        # pas de table réduite à 1-2 lignes d'un côté ou de l'autre de la coupure
        if body_total - body_first < 2:
            n -= 2 - (body_total - body_first)
            body_first = n - 1
        if body_first < min(3, body_total):
            return []
        parts = t.split(aw, sum(rh[:n]) + 0.01)
        for p in parts[1:]:
            p.spaceBefore = 0
        return parts

    def draw(self):
        self._table.drawOn(self.canv, 0, 0)


# --------------------------------------------------------------------------------------
# Rendu Markdown -> flowables
# --------------------------------------------------------------------------------------
@dataclass(frozen=True)
class Ctx:
    left: float = TEXT_INSET  # retrait du texte
    right: float = TEXT_INSET
    base: float = TEXT_INSET  # retrait du texte au niveau 0 du contexte (0 dans un encadré)
    size: float = 10.5
    leading: float = 14.0
    justify: bool = True
    in_box: bool = False
    para_after: float = 6.0
    code_color: str | None = None  # couleur du code inline (None = bleu nuit ; clair sur fond foncé)


STEP_RE = re.compile(r"^Étape\s+(\d+)\s*/\s*(\d+)\s*[—–-]\s*(.+?)\s*\(([^()]*)\)\s*$")
MODULE_RE = re.compile(r"^Module\s+(\d+)\s*[—–:-]\s*(.+)$")
ALERT_RE = re.compile(r"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*)$", re.S)
ALERTS = {
    "NOTE": ("info_bg", "navy"),
    "TIP": ("step_bg", "teal"),
    "IMPORTANT": ("ok_bg", "green"),
    "WARNING": ("warn_bg", "amber"),
    "CAUTION": ("danger_bg", "red"),
}
CENTER_CELL_RE = re.compile(
    r"^([~≈<>≥≤]?\s*\d[\d\s.,/]*\s*(min|h|s|ms|pts?|points?|%|Go|Mo|Gi|Mi|x)?|—|-|☐|☑|✔|✘|\[ \]|\[x\]|)$"
)


def slugify(text: str) -> str:
    """Ancre à la GitHub : minuscules, ponctuation retirée, espaces -> tirets."""
    s = text.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")


def plain_text(node: SyntaxTreeNode) -> str:
    if node.type in ("text", "code_inline"):
        return node.content
    if node.type in ("softbreak", "hardbreak"):
        return " "
    return "".join(plain_text(c) for c in node.children)


class Renderer:
    def __init__(self, doc_type: str, outline: OutlineState, single_h1: bool):
        self.doc_type = doc_type
        self.outline = outline
        self.single_h1 = single_h1
        self.after_steps = False
        self.seen_steps = False
        self.h1_count = 0
        self.after_banner = False
        self.anchors: set[str] = set()

    # ---------------------------------------------------------------- inline
    def inline(self, nodes, ctx: Ctx, in_link=False) -> str:
        out = []
        code_size = round(ctx.size * 0.9, 2)
        for n in nodes:
            t = n.type
            if t == "text":
                txt = french_spaces(n.content)
                if in_link:
                    out.append(run_markup(txt))
                else:
                    pos = 0
                    for m in _URL_RE.finditer(txt):
                        out.append(run_markup(txt[pos:m.start()]))
                        url = m.group(0)
                        out.append(f'<a href="{esc(url)}" color="{HEX["teal_dark"]}">{run_markup(url)}</a>')
                        pos = m.end()
                    out.append(run_markup(txt[pos:]))
            elif t == "softbreak":
                out.append(" ")
            elif t == "hardbreak":
                out.append("<br/>")
            elif t == "code_inline":
                code = n.content
                if len(code) <= 24:  # court : insécable (« decision_threshold = 0.3 » d'un bloc)
                    code = code.replace(" ", "\u00a0")
                color = ctx.code_color or HEX["navy"]
                out.append(f'<font name="Mono" size="{code_size}" color="{color}">'
                           f'{run_markup(code, "Mono")}</font>')
            elif t == "strong":
                out.append(f"<b>{self.inline(n.children, ctx, in_link)}</b>")
            elif t == "em":
                out.append(f"<i>{self.inline(n.children, ctx, in_link)}</i>")
            elif t == "s":
                out.append(f"<strike>{self.inline(n.children, ctx, in_link)}</strike>")
            elif t == "link":
                href = str(n.attrs.get("href", ""))
                inner = self.inline(n.children, ctx, True)
                if href.startswith("#"):
                    slug = slugify(href[1:])
                    href = "#" + slug if slug in self.anchors else ""
                elif not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", href):
                    href = ""  # lien relatif (fichier du repo) : pas de cible dans le PDF
                if href:
                    out.append(f'<a href="{esc(href)}" color="{HEX["teal_dark"]}">{inner}</a>')
                else:
                    out.append(f'<font color="{HEX["teal_dark"]}">{inner}</font>')
            elif t == "image":
                out.append(f"<i>[{run_markup(plain_text(n))}]</i>")
            elif t == "html_inline":  # balise brute : affichée telle quelle (sauf commentaire)
                if not n.content.startswith("<!--"):
                    out.append(run_markup(n.content))
            else:  # nœud inconnu : texte brut
                out.append(run_markup(n.content or plain_text(n)))
        return "".join(out)

    # ---------------------------------------------------------------- helpers
    def para_style(self, ctx: Ctx, **kw) -> ParagraphStyle:
        args = dict(fontSize=ctx.size, leading=ctx.leading, leftIndent=ctx.left,
                    rightIndent=ctx.right, alignment=TA_JUSTIFY if ctx.justify else TA_LEFT,
                    spaceAfter=ctx.para_after)
        args.update(kw)
        return pstyle(**args)

    def heading(self, markup: str, title: str, level: int, style: ParagraphStyle) -> Flowable:
        p = Paragraph(markup, style)
        key = self.outline.unique(slugify(title))
        if self.single_h1:
            out_level = {1: 0, 2: 0, 3: 1, 4: 2}.get(level, 2)
        else:
            out_level = min(level - 1, 3)
        f = Anchored(p, key, title, out_level, self.outline)
        f.keep_with_next = True
        return f

    # ---------------------------------------------------------------- blocs
    def blocks(self, nodes, ctx: Ctx) -> list[Flowable]:
        out: list[Flowable] = []
        nodes = list(nodes)
        i = 0
        while i < len(nodes):
            n = nodes[i]
            t = n.type
            if t == "heading":
                self.after_banner = False
                level = int(n.tag[1])
                consumed = self.heading_block(n, level, nodes[i + 1] if i + 1 < len(nodes) else None,
                                              ctx, out)
                i += consumed
                continue
            after_banner, self.after_banner = self.after_banner, False
            if t == "table" and after_banner and self.doc_type == "syllabus":
                strip = self.meta_strip(n)
                if strip is not None:
                    out.append(strip)
                    i += 1
                    continue
            if t == "paragraph":
                out.extend(self.paragraph(n, ctx))
            elif t in ("bullet_list", "ordered_list"):
                out.extend(self.list_block(n, ctx))
            elif t == "blockquote":
                extra = []
                nxt = nodes[i + 1] if i + 1 < len(nodes) else None
                if nxt is not None and nxt.type in ("fence", "code_block") and _is_bare_sortie(n):
                    extra = [nxt]  # « > **Sortie attendue :** » suivi d'un bloc de code : on l'intègre
                    i += 1
                out.append(indented(self.blockquote(n, ctx, extra), ctx.left - ctx.base, 0))
            elif t in ("fence", "code_block"):
                out.append(indented(self.code(n.content, (n.info or "").strip()), ctx.left, ctx.right))
            elif t == "table":
                out.append(indented(self.table(n, ctx), ctx.left - ctx.base, 0))
            elif t == "hr":
                out.append(indented(HRule(), ctx.left, ctx.right))
            elif t == "html_block":  # HTML brut (hors convention) : commentaires ignorés, le reste en texte
                if not n.content.lstrip().startswith("<!--"):
                    out.append(Paragraph(run_markup(n.content), self.para_style(ctx)))
            i += 1
        return out

    def paragraph(self, n, ctx: Ctx) -> list[Flowable]:
        inline = n.children[0] if n.children else None
        if inline is None:
            return []
        markup = self.inline(inline.children, ctx)
        if not markup.strip():
            return []
        para = SmartPara(markup, self.para_style(ctx))
        text = plain_text(inline).rstrip()
        if text.endswith(":") and len(text) < 400:
            para.keep_with_next = True  # « Créez le fichier … : » reste avec le bloc annoncé
        return [para]

    def heading_block(self, n, level, nxt, ctx: Ctx, out: list) -> int:
        inline = n.children[0]
        title = plain_text(inline).strip()
        markup = self.inline(inline.children, ctx)
        consumed = 1
        is_syllabus = self.doc_type == "syllabus"

        if level == 1:
            self.h1_count += 1
            if is_syllabus and self.h1_count > 1:
                out.append(PageBreak())
            m = MODULE_RE.match(title)
            if is_syllabus and m:
                banner = ModuleBanner(int(m.group(1)), self.inline_text_markup(m.group(2), inline, ctx))
                out.append(self._anchor(banner, title, 0))
                self.after_banner = True
            else:
                out.append(self.heading(markup, title, 1, pstyle(
                    fontName="Sans-Bold", fontSize=28, leading=32, textColor=C["navy"],
                    leftIndent=TEXT_INSET, rightIndent=TEXT_INSET, spaceAfter=2)))
            # sous-titre : paragraphe entièrement en italique juste après le titre
            if nxt is not None and nxt.type == "paragraph" and nxt.children:
                kids = [k for k in nxt.children[0].children if not (k.type == "text" and not k.content)]
                if len(kids) == 1 and kids[0].type == "em":
                    out.append(Paragraph(self.inline(kids[0].children, ctx), pstyle(
                        fontName="Sans-Italic", fontSize=12, leading=15, textColor=C["muted"],
                        leftIndent=TEXT_INSET, rightIndent=TEXT_INSET, spaceAfter=12)))
                    out[-1].keep_with_next = True
                    consumed = 2
            return consumed

        if level == 2:
            m = STEP_RE.match(title)
            if m and not is_syllabus:
                self.seen_steps = True
                num, total, ttl, dur = m.groups()
                # balisage du titre seul (sans « Étape N/T — » ni la durée)
                tmark = self.inline_text_markup(ttl, inline, ctx)
                banner = StepBanner(num, total, tmark, dur)
                out.append(self._anchor(banner, f"Étape {num}/{total} — {ttl}", 0 if self.single_h1 else 1,
                                        key_source=title))
                return 1
            m = MODULE_RE.match(title)
            if is_syllabus and m:
                if out:
                    out.append(CondPageBreak(FRAME_TOP - FRAME_BOTTOM - 8))
                banner = ModuleBanner(int(m.group(1)), self.inline_text_markup(m.group(2), inline, ctx))
                out.append(self._anchor(banner, title, 1))
                self.after_banner = True
                return 1
            if self.seen_steps and not is_syllabus:
                # sections finales (checklist, barème, annexes) : grand titre ; les annexes
                # ouvrent une nouvelle page, la première section finale si le tiers de page manque
                if title.lower().startswith("annexe"):
                    out.append(CondPageBreak(FRAME_TOP - FRAME_BOTTOM - 8))
                elif not self.after_steps:
                    out.append(CondPageBreak((FRAME_TOP - FRAME_BOTTOM) * 0.33))
                self.after_steps = True
                out.append(self.heading(markup, title, 2, pstyle(
                    fontName="Sans-Bold", fontSize=22, leading=26, textColor=C["navy"],
                    leftIndent=TEXT_INSET, rightIndent=TEXT_INSET, spaceBefore=14, spaceAfter=8)))
                return 1
            out.append(self.heading(markup, title, 2, pstyle(
                fontName="Sans-Bold", fontSize=15, leading=18, textColor=C["navy"],
                leftIndent=ctx.left, rightIndent=ctx.right, spaceBefore=14, spaceAfter=6)))
            return 1

        if level == 3:
            out.append(self.heading(markup, title, 3, pstyle(
                fontName="Sans-Bold", fontSize=12, leading=15, textColor=C["teal"],
                leftIndent=ctx.left, rightIndent=ctx.right, spaceBefore=11, spaceAfter=4)))
            return 1
        out.append(self.heading(markup, title, 4, pstyle(
            fontName="Sans-Bold", fontSize=10.5, leading=14, textColor=C["navy"],
            leftIndent=ctx.left, rightIndent=ctx.right, spaceBefore=8, spaceAfter=3)))
        return 1

    def _anchor(self, banner: Flowable, title: str, level: int, key_source: str | None = None) -> Flowable:
        key = self.outline.unique(slugify(key_source or title))
        f = Anchored(banner, key, title, level, self.outline)
        f.keep_with_next = True
        return f

    def inline_text_markup(self, fragment: str, inline, ctx: Ctx) -> str:
        """Balisage d'un fragment du titre : on rejoue l'inline en ne gardant que `fragment`."""
        full = self.inline(inline.children, ctx)
        # cas courant : le fragment est en texte brut ou contient du `code`
        plain = plain_text(inline)
        if fragment == plain:
            return full
        # reconstruit à partir des enfants en coupant au niveau du texte
        start = plain.find(fragment)
        if start < 0:
            return run_markup(fragment)
        end = start + len(fragment)
        pos, parts = 0, []
        for c in inline.children:
            txt = plain_text(c)
            a, b = pos, pos + len(txt)
            pos = b
            lo, hi = max(a, start), min(b, end)
            if lo >= hi:
                continue
            if c.type == "code_inline":
                if lo == a and hi == b:
                    parts.append(self.inline([c], ctx))
                else:
                    parts.append(run_markup(txt[lo - a:hi - a], "Mono"))
            elif c.type == "text":
                parts.append(run_markup(french_spaces(txt[lo - a:hi - a])))
            else:
                parts.append(self.inline([c], ctx) if (lo == a and hi == b) else run_markup(txt[lo - a:hi - a]))
        return "".join(parts)

    # ---------------------------------------------------------------- listes
    def list_block(self, n, ctx: Ctx) -> list[Flowable]:
        ordered = n.type == "ordered_list"
        start = int(n.attrs.get("start", 1)) if ordered else 1
        out: list[Flowable] = []
        count = len(n.children)
        label_w = 18 if ordered and start + count - 1 >= 10 else (15 if ordered else 13)
        for idx, item in enumerate(n.children):
            kids = list(item.children)
            sub = replace(ctx, left=ctx.left + label_w, justify=False)
            if ordered:
                bullet = f'<bullet color="{HEX["teal"]}" face="Sans-Bold">{start + idx}.</bullet>'
            else:
                bullet = f'<bullet color="{HEX["teal"]}" face="Sans">•</bullet>'
            first_flow: list[Flowable] = []
            if kids and kids[0].type == "paragraph" and kids[0].children:
                inl = kids[0].children[0]
                children = list(inl.children)
                if children and children[0].type == "text":
                    m = re.match(r"^\[([ xX])\]\s+", children[0].content)
                    if m:  # liste de tâches GFM
                        box = "\u2611" if m.group(1).lower() == "x" else "\u2610"
                        bullet = f'<bullet face="Sym" color="{HEX["navy"]}">{box}</bullet>'
                        children = list(children)
                        rest_txt = children[0].content[m.end():]
                        markup = run_markup(french_spaces(rest_txt)) + self.inline(children[1:], ctx)
                        children = None
                if children is not None:
                    markup = self.inline(children, ctx)
                st = self.para_style(sub, bulletIndent=ctx.left, alignment=TA_LEFT,
                                     spaceAfter=3, bulletFontSize=ctx.size)
                first_flow.append(Paragraph(bullet + markup, st))
                kids = kids[1:]
            else:
                st = self.para_style(sub, bulletIndent=ctx.left, alignment=TA_LEFT, spaceAfter=3)
                first_flow.append(Paragraph(bullet + "\u00a0", st))
            out.extend(first_flow)
            if kids:
                inner = self.blocks(kids, replace(sub, para_after=3))
                out.extend(inner)
        if out:
            last = out[-1]
            if isinstance(last, Paragraph):
                last.style = pstyle(**{**_style_kwargs(last.style), "spaceAfter": max(ctx.para_after, 5)})
        return out

    # ---------------------------------------------------------------- encadrés
    def blockquote(self, n, ctx: Ctx, extra=()) -> Flowable:
        kids = list(n.children) + list(extra)
        box_ctx = Ctx(left=0, right=0, base=0, size=10, leading=13.5, justify=True, in_box=True,
                      para_after=5)
        first = kids[0] if kids else None
        first_inl = first.children[0] if first is not None and first.type == "paragraph" else None
        children = list(first_inl.children) if first_inl is not None else []

        # Alerte GitHub : > [!TYPE] puis **Titre** sur la ligne suivante
        if children and children[0].type == "text":
            m = ALERT_RE.match(children[0].content)
            if m:
                kind = m.group(1)
                bg, bar = ALERTS[kind]
                rest = children[1:]
                content: list[Flowable] = []
                trailing = m.group(2).strip()
                rest = _strip_leading_breaks(rest)
                if not trailing and rest and rest[0].type == "strong":
                    title = self.inline(rest[0].children, box_ctx)
                    content.append(Paragraph(title, pstyle(fontName="Sans-Bold", fontSize=11, leading=14,
                                                           textColor=C["navy"], spaceAfter=3)))
                    rest = _strip_leading_breaks(rest[1:])
                body = (run_markup(french_spaces(trailing)) + " " if trailing else "") + self.inline(rest, box_ctx)
                if body.strip():
                    content.append(SmartPara(body, self.para_style(box_ctx)))
                content.extend(self.blocks(kids[1:], box_ctx))
                return Box(content, bg=C[bg], bar=C[bar], bar_w=3, border=C["rule"], pad=(9, 12, 9, 12))

        # « Sortie attendue : … »
        if children and children[0].type == "strong" or (
            len(children) > 1 and children[0].type == "text" and not children[0].content
            and children[1].type == "strong"
        ):
            strong = children[0] if children[0].type == "strong" else children[1]
            label = plain_text(strong).strip()
            if label.lower().startswith("sortie attendue"):
                s_ctx = replace(box_ctx, size=9.5, leading=12.5, para_after=4, justify=False)
                idx = children.index(strong)
                body = self.inline(children[idx + 1:], s_ctx)
                lab = (f'<font name="Sans-Bold" color="{HEX["green"]}">'
                       f'{run_markup(french_spaces(label))}</font>')
                content = [Paragraph(lab + body, self.para_style(s_ctx))]
                content.extend(self.blocks(kids[1:], s_ctx))
                return Box(content, bg=C["sortie_bg"], bar=C["green"], bar_w=2, border=None,
                           pad=(6, 10, 6, 14), space_before=2, space_after=10)

        # citation simple
        content = self.blocks(kids, box_ctx)
        return Box(content, bg=C["quote_bg"], bar=C["code_border"], bar_w=3, border=None,
                   pad=(8, 12, 8, 12))

    # ---------------------------------------------------------------- code
    def code(self, text: str, lang: str) -> CodeBlock:
        text = text.expandtabs(4).rstrip("\n")
        raw_lines = text.split("\n")
        lang = (lang.split() or [""])[0].lower()
        lexer = None
        if lang and lang not in ("text", "txt", "plain", "output", "console-output"):
            alias = {"sh": "bash", "shell": "bash", "zsh": "bash", "yml": "yaml", "docker": "docker",
                     "dockerfile": "docker", "py": "python", "make": "make", "makefile": "make",
                     "jinja": "jinja"}.get(lang, lang)
            try:
                lexer = get_lexer_by_name(alias, stripnl=False, ensurenl=False)
            except ClassNotFound:
                lexer = None
        lines: list[list[tuple[str, str, str]]] = [[]]
        if lexer is None:
            tokens = [(Token.Text, text)]
        else:
            tokens = list(lex(text, lexer))
        for ttype, value in tokens:
            font, col = _token_style(ttype)
            for j, piece in enumerate(value.split("\n")):
                if j:
                    lines.append([])
                if piece:
                    for chunk, fb, fcol in glyph_runs(piece, "Mono"):
                        f2 = "Sym" if fb == "Sym" else font
                        lines[-1].append((chunk, f2, fcol or col))
        while len(lines) > len(raw_lines) and not lines[-1]:
            lines.pop()
        return CodeBlock(lines)

    # ---------------------------------------------------------------- tables
    def meta_strip(self, n) -> Flowable | None:
        """Fiche module du syllabus : table 1 ligne -> bandeau « libellé / valeur »."""
        rows = [list(tr.children) for sec in n.children for tr in sec.children]
        if len(rows) != 2 or len(rows[0]) != len(rows[1]):
            return None
        cctx = Ctx(left=0, right=0, base=0, size=9, leading=12, justify=False, in_box=True, para_after=0)
        cells, nat = [], []
        for h, v in zip(rows[0], rows[1], strict=True):
            lab = self.inline(h.children[0].children, cctx) if h.children else ""
            val = self.inline(v.children[0].children, cctx) if v.children else ""
            p = Paragraph(f'<font color="{HEX["muted"]}">{lab}</font><br/><b>{val}</b>',
                          pstyle(fontSize=9, leading=12))
            p.wrap(10_000, 10_000)
            nat.append(max(p.getActualLineWidths0() or [0]) + 21)
            cells.append(p)

        def build(aw):
            mins = [min(c.minWidth() + 21, aw / len(cells)) for c in cells]
            widths = nat if sum(nat) <= aw else _waterfill(aw, mins, nat, nat)
            if sum(widths) < aw:
                extra = aw - sum(widths)
                widths = [w + extra / len(widths) for w in widths]
            t = Table([cells], colWidths=widths, hAlign="LEFT")
            t.setStyle(TableStyle([
                ("FONT", (0, 0), (-1, -1), "Sans", 9),
                ("BACKGROUND", (0, 0), (-1, -1), C["step_bg"]),
                ("LINEAFTER", (0, 0), (-2, -1), 0.4, C["rule"]),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 10),
                ("RIGHTPADDING", (0, 0), (-1, -1), 10),
                ("TOPPADDING", (0, 0), (-1, -1), 7),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
            ]))
            return t

        lt = LazyTable(build)
        lt.spaceBefore, lt.spaceAfter = 0, 10
        return lt

    def table(self, n, ctx: Ctx) -> Flowable:
        head_rows, body_rows = [], []
        for section in n.children:
            for tr in section.children:
                cells = list(tr.children)
                (head_rows if section.type == "thead" else body_rows).append(cells)
        if not head_rows and body_rows:
            head_rows, body_rows = [body_rows[0]], body_rows[1:]
        header = head_rows[0]
        ncols = len(header)
        aligns = []
        for c in header:
            st = (c.attrs or {}).get("style", "")
            m = re.search(r"text-align:(\w+)", st)
            aligns.append(m.group(1) if m else None)

        def cell_plain(c):
            return plain_text(c.children[0]).strip() if c.children else ""

        num_col, center_col = [], []
        for j in range(ncols):
            vals = [cell_plain(r[j]) for r in body_rows if j < len(r)]
            hdr = cell_plain(header[j])
            is_num = bool(vals) and (hdr in ("#", "N°", "No", "n°") or all(re.fullmatch(r"\d{1,3}", v) for v in vals))
            num_col.append(is_num and all(len(v) <= 3 for v in vals))
            center_col.append(bool(vals) and all(CENTER_CELL_RE.match(v) for v in vals) and len(hdr) <= 16)

        def build(aw):
            fs = 9.5
            if ncols >= 5:
                fs = 8.5
            if ncols >= 7:
                fs = 8.0
            for _attempt in range(3):
                result = self._build_table(header, body_rows, aligns, num_col, center_col, aw, fs)
                if result is not None:
                    return result
                fs -= 0.75
            return self._build_table(header, body_rows, aligns, num_col, center_col, aw, fs, force=True)

        return LazyTable(build)

    def _build_table(self, header, body_rows, aligns, num_col, center_col, aw, fs, force=False):
        ncols = len(header)
        lead = round(fs * 1.28, 2)
        pad_x, pad_y = (6 if fs < 9 else 7), 4.5
        cctx = Ctx(left=0, right=0, base=0, size=fs, leading=lead, justify=False, in_box=True, para_after=0)
        # en-tête sur fond bleu nuit : code inline en clair (sinon invisible)
        hctx = dataclasses.replace(cctx, code_color="#CFE0F5")

        def align_for(j):
            a = aligns[j]
            if a == "center" or num_col[j] or center_col[j]:
                return TA_CENTER
            if a == "right":
                return TA_RIGHT
            return TA_LEFT

        rows_p, nat, mins, area = [], [0.0] * ncols, [0.0] * ncols, [0.0] * ncols
        all_rows = [header] + body_rows
        total_rows = []
        for ri, row in enumerate(all_rows):
            prow = []
            for j in range(ncols):
                c = row[j] if j < len(row) else None
                ictx = hctx if ri == 0 else cctx
                markup = self.inline(c.children[0].children, ictx) if c is not None and c.children else ""
                if ri == 0:
                    st = pstyle(fontName="Sans-Bold", fontSize=fs, leading=lead, textColor=colors.white,
                                alignment=align_for(j))
                elif num_col[j]:
                    st = pstyle(fontName="Sans-Bold", fontSize=fs, leading=lead, textColor=C["teal"],
                                alignment=TA_CENTER)
                else:
                    st = pstyle(fontSize=fs, leading=lead, alignment=align_for(j))
                p = Paragraph(markup or "", st)
                prow.append(p)
                p.wrap(10_000, 10_000)
                widths = p.getActualLineWidths0() if markup else [0]
                nat[j] = max(nat[j], max(widths or [0]) + 2 * pad_x + 1)
                if ri > 0:
                    area[j] += sum(widths or [0]) + 2 * pad_x
                mins[j] = max(mins[j], min(p.minWidth(), aw * 0.25) + 2 * pad_x + 1)
            if ri > 0 and cell_plain_first(row).lower().startswith("total"):
                total_rows.append(ri)
            rows_p.append(prow)

        if sum(mins) > aw * 1.02 and not force:
            return None
        if sum(nat) <= aw:
            extra = aw - sum(nat)
            tot = sum(nat) or 1
            widths = [w + extra * w / tot for w in nat]
        elif sum(mins) >= aw:
            widths = [w * aw / sum(mins) for w in mins]
        else:
            widths = _waterfill(aw, mins, nat, area)

        style = [
            ("FONT", (0, 0), (-1, -1), "Sans", fs),  # police par défaut des cellules (sinon Helvetica)
            ("BACKGROUND", (0, 0), (-1, 0), C["navy"]),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, C["zebra"]]),
            ("GRID", (0, 0), (-1, -1), 0.5, C["rule"]),
            ("LINEBELOW", (0, 0), (-1, 0), 0.5, C["navy"]),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("LEFTPADDING", (0, 0), (-1, -1), pad_x),
            ("RIGHTPADDING", (0, 0), (-1, -1), pad_x),
            ("TOPPADDING", (0, 0), (-1, -1), pad_y),
            ("BOTTOMPADDING", (0, 0), (-1, -1), pad_y + 1),
        ]
        for ri in total_rows:
            style.append(("BACKGROUND", (0, ri), (-1, ri), C["step_bg"]))
        t = Table(rows_p, colWidths=widths, repeatRows=1, hAlign="LEFT")
        t.setStyle(TableStyle(style))
        return t


def _waterfill(aw: float, mins: list[float], nat: list[float], area: list[float]) -> list[float]:
    """Largeurs de colonnes proportionnelles à la quantité de texte de chaque colonne.

    Bornes : au moins la largeur minimale (mot le plus long), au plus la largeur naturelle
    (texte sur une ligne). Le reste est réparti au prorata du « volume » de texte, ce qui
    équilibre la hauteur des lignes (une seule cellule très longue ne capte pas tout).
    """
    n = len(mins)
    fixed: dict[int, float] = {}
    # 1) les colonnes étroites (texte tenant sur une ligne dans leur part équitable) gardent
    #    leur largeur naturelle : pas de « Coûts / métier » coupé pour rien
    while True:
        free = [j for j in range(n) if j not in fixed]
        if not free:
            break
        fair = (aw - sum(fixed.values())) / len(free)
        narrow = [j for j in free if nat[j] <= fair]
        if not narrow or len(narrow) == len(free):
            break
        for j in narrow:
            fixed[j] = nat[j]
    weights = [max(a, 1.0) for a in area]
    for _ in range(n + 1):
        free = [j for j in range(n) if j not in fixed]
        room = aw - sum(fixed.values())
        tot = sum(weights[j] for j in free) or 1.0
        share = {j: room * weights[j] / tot for j in free}
        changed = False
        for j in free:
            if share[j] < mins[j]:
                fixed[j] = mins[j]
                changed = True
            elif share[j] > nat[j]:
                fixed[j] = nat[j]
                changed = True
        if not changed:
            fixed.update(share)
            break
    widths = [fixed.get(j, mins[j]) for j in range(n)]
    scale = aw / (sum(widths) or 1.0)
    return [w * scale for w in widths]


def _is_bare_sortie(n) -> bool:
    """Blockquote réduit à « **Sortie attendue :** » (le contenu suit dans un bloc de code)."""
    if len(n.children) != 1 or n.children[0].type != "paragraph" or not n.children[0].children:
        return False
    text = plain_text(n.children[0].children[0]).strip()
    return text.lower().startswith("sortie attendue") and len(text) <= len("sortie attendue :") + 2


def cell_plain_first(row) -> str:
    if not row or not row[0].children:
        return ""
    return plain_text(row[0].children[0]).strip()


def _strip_leading_breaks(nodes):
    nodes = list(nodes)
    while nodes and (nodes[0].type in ("softbreak", "hardbreak") or (nodes[0].type == "text" and not nodes[0].content.strip())):
        nodes = nodes[1:]
    return nodes


def _style_kwargs(st: ParagraphStyle) -> dict:
    keys = ("fontName", "fontSize", "leading", "textColor", "alignment", "spaceBefore", "spaceAfter",
            "leftIndent", "rightIndent", "bulletIndent", "bulletFontName", "bulletFontSize")
    return {k: getattr(st, k) for k in keys}


def _token_style(ttype) -> tuple[str, str]:
    if ttype in Token.Comment:
        return "Mono-Oblique", "muted"
    if ttype in Token.Keyword:
        return "Mono-Bold", "kw"
    if ttype in Token.Literal.String:
        return "Mono", "str"
    if ttype in Token.Literal.Number:
        return "Mono", "num"
    if ttype in Token.Name.Builtin or ttype in Token.Name.Tag:
        return "Mono", "kw"
    if ttype in Token.Name.Variable or ttype in Token.Name.Decorator:
        return "Mono", "var"
    return "Mono", "ink"


# --------------------------------------------------------------------------------------
# Post-traitement : titres jamais orphelins
# --------------------------------------------------------------------------------------
def protect_headings(story: list[Flowable]) -> list[Flowable]:
    out: list[Flowable] = []
    i = 0
    while i < len(story):
        f = story[i]
        if getattr(f, "keep_with_next", False):
            group = [f]
            j = i + 1
            while j < len(story) and getattr(story[j], "keep_with_next", False):
                group.append(story[j])
                j += 1
            nxt = None
            k = j
            while k < len(story) and isinstance(story[k], (CondPageBreak, PageBreak, Spacer)):
                k += 1
            if k < len(story) and k == j:
                nxt = story[k]
            min_after = 90 if any(isinstance(getattr(g, "inner", None), StepBanner) for g in group) else 64
            out.append(KeepWithNext(group, nxt, min_after))
            out.extend(group)
            i = j
            continue
        out.append(f)
        i += 1
    return out


# --------------------------------------------------------------------------------------
# Document : couverture, en-tête, pied de page
# --------------------------------------------------------------------------------------
@dataclass
class DocMeta:
    doc_type: str
    title: str
    subtitle: str
    kicker: str
    fields: list[tuple[str, str]]
    header: str
    footer_left: str
    cover_footer_title: str
    cover_footer_text: str
    pdf_title: str
    pdf_subject: str
    keywords: str
    top_bar: bool
    title_size: float
    out_name: str


def load_markdown(path: Path) -> tuple[dict, str]:
    text = path.read_text(encoding="utf-8")
    if text.startswith("﻿"):
        text = text[1:]
    fm: dict = {}
    if text.startswith("---"):
        m = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, re.S)
        if m:
            fm = yaml.safe_load(m.group(1)) or {}
            text = text[m.end():]
    return fm, text


def build_meta(fm: dict, body: str, path: Path) -> DocMeta:
    doc_type = str(fm.get("doc_type", "lab")).lower()
    title = str(fm.get("title", path.stem))
    subtitle = str(fm.get("subtitle", ""))
    if doc_type == "syllabus":
        fields = [tuple(map(str, f)) if isinstance(f, (list, tuple)) else
                  (str(f.get("label", "")), str(f.get("value", ""))) for f in fm.get("cover_fields", [])]
        running = str(fm.get("running_title", f"Cours MLOps — {title}"))
        return DocMeta(
            doc_type=doc_type, title=title, subtitle=subtitle,
            kicker=str(fm.get("cover_kicker", "COURS MLOps")), fields=fields,
            header=running,
            footer_left=str(fm.get("footer_left", "Cycle Ingénieur Informatique — 36h")),
            cover_footer_title=str(fm.get("cover_footer_title", "Document maître du cours")),
            cover_footer_text=str(fm.get("cover_footer_text", "")),
            pdf_title=running, pdf_subject=subtitle or title,
            keywords="MLOps, syllabus", top_bar=True, title_size=48, out_name="MLOps_Syllabus.pdf",
        )
    module = fm.get("module")
    lab = fm.get("lab", module)
    running = str(fm.get("running_title", title))
    h1 = re.search(r"^#\s+(.+)$", body, re.M)
    h1_text = h1.group(1).strip() if h1 else ""
    if fm.get("cover_kicker"):
        kicker = str(fm["cover_kicker"])
    elif re.match(r"^Lab\s+\d+", h1_text) or not h1_text:
        kicker = f"MODULE {module} · LAB {lab}"
    else:
        kicker = f"MODULE {module} · {title.split()[0].upper()}"
    if fm.get("cover_fields"):
        fields = [tuple(map(str, f)) for f in fm["cover_fields"]]
    else:
        fields = [(lab_, str(fm[k])) for k, lab_ in (
            ("duree", "Durée"), ("format", "Format"), ("prerequis", "Prérequis"),
            ("livrable", "Livrable"), ("stack", "Stack")) if fm.get(k)]
    header = running if running.lower().startswith("module") else f"Module {module} · {running}"
    return DocMeta(
        doc_type="lab", title=title, subtitle=subtitle, kicker=kicker, fields=fields,
        header=f"MLOps · {header}",
        footer_left=str(fm.get("footer_left", "Cycle Ingénieur Informatique — Cours MLOps 36h")),
        cover_footer_title=str(fm.get("cover_footer_title", "Cycle Ingénieur Informatique")),
        cover_footer_text=str(fm.get("cover_footer_text",
                                     f"Cours MLOps — 36h · Document compagnon des slides du Module {module}")),
        pdf_title=f"MLOps — {running}" if running.lower().startswith("module") else f"MLOps — Module {module} — {running}",
        pdf_subject=subtitle or title,
        keywords=", ".join(["MLOps", f"Module {module}"] + [s.strip() for s in str(fm.get("stack", "")).split("·") if s.strip()]),
        top_bar=False, title_size=38,
        out_name=f"MLOps_Module{module}_Lab.pdf" if module is not None else f"{path.parent.name}.pdf",
    )


def draw_runs(canv, x: float, y: float, text: str, font: str, size: float, color) -> None:
    """Écrit une ligne sur le canevas avec repli de police glyphe par glyphe (couverture)."""
    tx = canv.beginText(x, y)
    for chunk, fb, col in glyph_runs(text, "Sans"):
        tx.setFont(fb or font, size)
        tx.setFillColor(C[col] if col else color)
        tx.textOut(chunk)
    canv.drawText(tx)


def draw_lines(canv, x: float, y: float, text: str, font: str, size: float, leading: float,
               color, maxw: float) -> float:
    """Paragraphe sur le canevas (1re ligne de base à `y`) ; renvoie la dernière ligne de base."""
    lines = simpleSplit(text, font, size, maxw) or [""]
    for i, line in enumerate(lines):
        draw_runs(canv, x, y - i * leading, line, font, size, color)
    return y - (len(lines) - 1) * leading


def draw_cover(canv, meta: DocMeta) -> None:
    """Couverture pleine page. Géométrie relevée sur les PDF originaux :
    labs : kicker à 612 pt, 1re ligne du titre à 558 pt, le bloc descend ;
    syllabus : dernière ligne du titre à 558 pt, le bloc monte (titre 48 pt, bandeau teal).
    """
    W, H = PAGE_W, PAGE_H
    x = MARGIN_X
    maxw = W - 2 * x
    canv.saveState()
    canv.setFillColor(C["navy"])
    canv.rect(0, 0, W, H, stroke=0, fill=1)
    if meta.top_bar:
        canv.setFillColor(C["teal"])
        canv.rect(0, H - 8.5, W, 8.5, stroke=0, fill=1)

    size = meta.title_size
    lines = simpleSplit(meta.title, "Sans-Bold", size, maxw)
    while len(lines) > 3 and size > 24:
        size -= 2
        lines = simpleSplit(meta.title, "Sans-Bold", size, maxw)
    if meta.doc_type == "syllabus":
        lead = size * 0.9
        first = 558.4 + (len(lines) - 1) * lead
        kicker_y = first + 68
    else:
        lead = size * 1.045
        first = 558.4
        kicker_y = 612.3

    # kicker espacé teal, précédé d'une pastille
    canv.setFillColor(C["teal"])
    canv.circle(x + 4, kicker_y + 3.2, 3.2, stroke=0, fill=1)
    spaced = "   ".join(" ".join(word) for word in meta.kicker.split())
    canv.setFont("Mono-Bold", 10.5)
    canv.drawString(x + 12, kicker_y, spaced)

    for i, line in enumerate(lines):
        draw_runs(canv, x, first - i * lead, line, "Sans-Bold", size, colors.white)
    y = first - (len(lines) - 1) * lead

    if meta.subtitle:
        y = draw_lines(canv, x, y - 42.5, meta.subtitle, "Sans-Italic", 16, 19.2, C["cover_soft"], maxw)
    y -= 42.5
    canv.setStrokeColor(C["teal"])
    canv.setLineWidth(2)
    canv.line(x, y, x + 170, y)

    fs = 11 if meta.doc_type != "syllabus" else 10.5
    label_w = max([pdfmetrics.stringWidth(lbl, "Sans-Bold", fs) for lbl, _ in meta.fields] + [60]) + 22
    label_w = max(label_w, 85)
    y -= 42.5
    for label, value in meta.fields:
        draw_runs(canv, x, y, label, "Sans-Bold", fs, colors.white)
        last = draw_lines(canv, x + label_w, y, value, "Sans", fs, fs * 1.25, C["cover_soft"], maxw - label_w)
        y = last - fs * 1.8

    draw_runs(canv, x, 51.0, meta.cover_footer_title, "Sans-Bold", 10, C["teal"])
    if meta.cover_footer_text:
        draw_lines(canv, x, 34.0, meta.cover_footer_text, "Sans", 9, 11, C["cover_soft"], maxw)
    canv.restoreState()


def draw_page_frame(canv, doc, meta: DocMeta) -> None:
    canv.saveState()
    canv.setFont("Sans", 8.5)
    canv.setFillColor(C["muted"])
    header = meta.header
    maxw = CONTENT_W
    if pdfmetrics.stringWidth(header, "Sans", 8.5) > maxw:
        while header and pdfmetrics.stringWidth(header + "…", "Sans", 8.5) > maxw:
            header = header[:-1]
        header += "…"
    canv.drawString(MARGIN_X, 807.9, header)
    canv.setStrokeColor(C["rule"])
    canv.setLineWidth(0.4)
    canv.line(MARGIN_X, 802.2, PAGE_W - MARGIN_X, 802.2)
    canv.line(MARGIN_X, 40.5, PAGE_W - MARGIN_X, 40.5)
    canv.drawString(MARGIN_X, 28.35, meta.footer_left)
    canv.drawRightString(PAGE_W - MARGIN_X, 28.35, f"Page {canv.getPageNumber()}")
    canv.restoreState()


class CourseDoc(BaseDocTemplate):
    def __init__(self, filename, meta: DocMeta, **kw):
        super().__init__(
            filename, pagesize=A4, leftMargin=MARGIN_X, rightMargin=MARGIN_X,
            topMargin=PAGE_H - FRAME_TOP, bottomMargin=FRAME_BOTTOM,
            title=meta.pdf_title, author="Cours MLOps", subject=meta.pdf_subject,
            creator="tools/build_pdf (ReportLab)", keywords=meta.keywords, lang="fr-FR",
            displayDocTitle=1, initialFontName="Sans", initialFontSize=10, initialLeading=12, **kw,
        )
        self.meta = meta
        frame = Frame(MARGIN_X, FRAME_BOTTOM, CONTENT_W, FRAME_TOP - FRAME_BOTTOM,
                      leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0, id="content")
        cover_frame = Frame(MARGIN_X, FRAME_BOTTOM, CONTENT_W, FRAME_TOP - FRAME_BOTTOM, id="cover")
        self.addPageTemplates([
            PageTemplate(id="cover", frames=[cover_frame], onPage=self._on_cover),
            PageTemplate(id="content", frames=[frame], onPage=self._on_page),
        ])

    def _on_cover(self, canv, doc):
        canv.showOutline()
        draw_cover(canv, self.meta)

    def _on_page(self, canv, doc):
        draw_page_frame(canv, doc, self.meta)


# --------------------------------------------------------------------------------------
# Point d'entrée
# --------------------------------------------------------------------------------------
def collect_anchors(tree: SyntaxTreeNode) -> set[str]:
    """Ancres des titres (même ordre et même règle que le rendu) pour valider les liens internes."""
    state = OutlineState()
    anchors: set[str] = set()

    def walk(node):
        for c in node.children:
            if c.type == "heading" and c.children:
                anchors.add(state.unique(slugify(plain_text(c.children[0]).strip())))
            elif c.type in ("blockquote", "bullet_list", "ordered_list", "list_item"):
                walk(c)

    walk(tree)
    return anchors


def build_one(md_path: Path, out_dir: Path) -> tuple[Path, int]:
    fm, body = load_markdown(md_path)
    meta = build_meta(fm, body, md_path)
    md = MarkdownIt("commonmark", {"html": True, "typographer": False}).enable(["table", "strikethrough"])
    tree = SyntaxTreeNode(md.parse(body))
    h1s = sum(1 for n in tree.children if n.type == "heading" and n.tag == "h1")
    outline = OutlineState()
    renderer = Renderer(meta.doc_type, outline, single_h1=h1s <= 1)
    renderer.anchors = collect_anchors(tree)
    story: list[Flowable] = [NextPageTemplate("content"), PageBreak()]
    story += protect_headings(renderer.blocks(tree.children, Ctx()))
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / meta.out_name
    doc = CourseDoc(str(out_path), meta)
    doc.build(story)
    return out_path, doc.page


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Énoncés Markdown du cours MLOps -> PDF (charte du cours).")
    ap.add_argument("inputs", nargs="+", type=Path, help="fichiers Markdown (labs/*/README.md, docs/syllabus.md)")
    ap.add_argument("-o", "--output", type=Path, default=Path("dist/pdf"), help="dossier de sortie")
    args = ap.parse_args(argv)
    register_fonts()
    failures = 0
    for path in args.inputs:
        if not path.is_file():
            print(f"ERREUR : {path} introuvable", file=sys.stderr)
            failures += 1
            continue
        MISSING_GLYPHS.clear()
        try:
            out, pages = build_one(path, args.output)
        except Exception as exc:  # noqa: BLE001 — on continue avec les autres fichiers
            print(f"ERREUR : {path} : {type(exc).__name__}: {exc}", file=sys.stderr)
            failures += 1
            continue
        print(f"{out}  ({pages} pages)  <- {path}")
        if MISSING_GLYPHS:
            chars = " ".join(f"U+{ord(c):04X}" for c in sorted(MISSING_GLYPHS))
            print(f"  attention : glyphes sans police, remplacés par □ : {chars}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
