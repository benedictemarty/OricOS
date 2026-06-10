#!/usr/bin/env python3
# SPDX-License-Identifier: EUPL-1.2
# Copyright (c) 2026 Bénédicte Marty
"""
gen-font-bold.py — SP-GUI (fontes multiples : variante GRASSE).

Génère une variante BOLD de la fonte XVGA par « smear » horizontal :
chaque ligne de glyphe est OR'd avec elle-même décalée d'1 px à droite
(bits[col] |= bits[col-1]) — épaissit chaque trait vertical d'1 px, sans
sortir de la cellule 8 px (le bit décalé hors de la colonne 7 est perdu,
mais la fonte XVGA a des glyphes ≤ 6 px → sûr). Sorties :

    data/charset-xvga-bold.bin (1024 o : 128 glyphes × 8 lignes)
    data/font_widths_bold.bin  (128 o : largeur rendue prop. du gras)

Le gras est ~1 px plus large par trait → table de largeurs dédiée
(consommée par kernel_tk_label_prop quand TK_STYLE = bold). Mêmes
conventions que gen-font-widths.py (SPACING/SPACE_W/MIN_W).

Usage : python3 tools/gen-font-bold.py   (depuis OricOS/)
Idempotent ; appelé par le Makefile avant l'assemblage du kernel.
"""

from pathlib import Path

ROOT = Path(__file__).parent.parent
SRC = ROOT / "data" / "charset-xvga.bin"
DST_FONT = ROOT / "data" / "charset-xvga-bold.bin"
DST_W = ROOT / "data" / "font_widths_bold.bin"

SPACING = 1
SPACE_W = 4
MIN_W = 3


def bold_row(bits: int) -> int:
    # smear : chaque pixel allumé allume aussi son voisin de droite.
    # bits a la colonne 0 en MSB ($80). « voisin droite » = >> 1.
    return (bits | (bits >> 1)) & 0xFF


def glyph_width(rows: bytes) -> int:
    rightmost = -1
    for bits in rows:
        for col in range(8):
            if bits & (0x80 >> col):
                rightmost = max(rightmost, col)
    if rightmost < 0:
        return SPACE_W
    return max(MIN_W, rightmost + 1 + SPACING)


def main() -> int:
    data = SRC.read_bytes()
    if len(data) != 1024:
        raise SystemExit(f"FATAL : {SRC} fait {len(data)} octets (1024 attendus)")

    bold = bytes(bold_row(b) for b in data)
    widths = bytes(glyph_width(bold[c * 8:(c + 1) * 8]) for c in range(128))

    changed = False
    if not (DST_FONT.exists() and DST_FONT.read_bytes() == bold):
        DST_FONT.write_bytes(bold)
        changed = True
    if not (DST_W.exists() and DST_W.read_bytes() == widths):
        DST_W.write_bytes(widths)
        changed = True

    tag = "généré" if changed else "à jour"
    pr = {c: widths[c] for c in (0x20, 0x4D, 0x69, 0x2E)}  # ' ', M, i, .
    print(f"charset-xvga-bold.bin + font_widths_bold.bin : {tag} — "
          f"espace={pr[0x20]} M={pr[0x4D]} i={pr[0x69]} .={pr[0x2E]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
