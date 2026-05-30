#!/usr/bin/env python3
"""
gen-font-geos.py — Génère une fonte 8x8 bitmap style GEOS BSW pour OricOS.

Stratégie : rend chaque caractère ASCII 32..127 via PIL avec une fonte
TTF monospaced bold à taille fixe, applique un threshold binaire, et
extrait un bitmap 8x8 par caractère. Sortie : 1024 octets bruts (128
chars × 8 lignes), format identique à `data/charset.bin` (chaque ligne =
1 octet, bit 7 = pixel le plus à gauche).

Style : Liberation Mono Bold (plus serré, plus moderne que Oric Atmos).
Look BSW-inspired (lettres compactes, traits forts).
"""

import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont


def render_char(c: str, font: ImageFont.FreeTypeFont, threshold: int = 128) -> bytes:
    """Rend un caractère en bitmap 8x8 monochrome (1 byte/ligne, bit 7=gauche)."""
    img = Image.new("L", (8, 8), 0)
    draw = ImageDraw.Draw(img)
    # Décalage vertical : essaye de centrer le glyphe dans 8 lignes.
    draw.text((0, -2), c, fill=255, font=font)
    out = bytearray(8)
    for y in range(8):
        b = 0
        for x in range(8):
            if img.getpixel((x, y)) >= threshold:
                b |= 1 << (7 - x)
        out[y] = b
    return bytes(out)


def main() -> int:
    ttf_path = "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf"
    out_path = Path(__file__).parent.parent / "data" / "charset.bin"
    if not Path(ttf_path).exists():
        print(f"erreur: fonte TTF introuvable: {ttf_path}", file=sys.stderr)
        return 1
    # Taille 8 → glyphes denses qui remplissent bien 8x8 px.
    font = ImageFont.truetype(ttf_path, size=8)
    blob = bytearray(1024)
    for code in range(128):
        glyph = chr(code) if 32 <= code < 127 else " "
        bitmap = render_char(glyph, font)
        blob[code * 8 : code * 8 + 8] = bitmap
    out_path.write_bytes(bytes(blob))
    print(f"écrit: {out_path} ({len(blob)} octets, 128 chars × 8 lignes)")
    # Aperçu console : affiche A, O, S, R, I, c, k
    samples = "AORSIckW0"
    for c in samples:
        print(f"\n  '{c}' ({ord(c):3d}):")
        bm = render_char(c, font)
        for line in bm:
            print("    " + "".join("█" if line & (1 << (7 - x)) else "·" for x in range(8)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
