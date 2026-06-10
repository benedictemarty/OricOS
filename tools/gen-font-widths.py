#!/usr/bin/env python3
# SPDX-License-Identifier: EUPL-1.2
# Copyright (c) 2026 Bénédicte Marty
"""
gen-font-widths.py — SP-3.p F.1 (fontes proportionnelles, suite GUI).

Génère data/font_widths.bin (128 octets) depuis data/charset-xvga.bin
(128 glyphes x 8 octets, MSB = colonne 0). Pour chaque glyphe :

    largeur = (index de la colonne allumée la plus à droite) + 1
              + ESPACEMENT (1 px inter-caractères)

Cas particuliers :
  - glyphe vide (aucun pixel, ex. espace $20) -> SPACE_W (4 px) ;
  - largeur minimale MIN_W (3 px) pour les glyphes très étroits (',', '.').

La table est consommée par kernel_tk_text_width / kernel_tk_label_prop
(OricOS tk.s) : la somme des largeurs d'une chaîne = sa largeur rendue.

Usage : python3 tools/gen-font-widths.py   (depuis OricOS/)
Idempotent ; appelé par le Makefile avant l'assemblage du kernel.
"""

from pathlib import Path

ROOT = Path(__file__).parent.parent
SRC = ROOT / "data" / "charset-xvga.bin"
DST = ROOT / "data" / "font_widths.bin"

SPACING = 1   # pixels entre caractères
SPACE_W = 4   # largeur d'un glyphe vide (espace)
MIN_W = 3     # largeur plancher (glyphes 1-colonne : 2 px utiles + spacing)


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
    widths = bytes(glyph_width(data[c * 8:(c + 1) * 8]) for c in range(128))
    if DST.exists() and DST.read_bytes() == widths:
        print(f"font_widths.bin : à jour ({len(widths)} octets)")
        return 0
    DST.write_bytes(widths)
    printable = {c: widths[c] for c in (0x20, 0x4D, 0x69, 0x2E)}  # ' ', M, i, .
    print(f"font_widths.bin : généré ({len(widths)} octets) — "
          f"espace={printable[0x20]} M={printable[0x4D]} i={printable[0x69]} .={printable[0x2E]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
