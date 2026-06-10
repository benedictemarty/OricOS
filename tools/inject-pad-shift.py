#!/usr/bin/env python3
# SPDX-License-Identifier: EUPL-1.2
# Copyright (c) 2026 Bénédicte Marty
"""
inject-pad-shift.py — ADR-32 §10.5 outil principal.

Insère/retire idempotemment un bloc de `nop` (taille paramétrable, défaut 120)
juste avant `kernel_wm_redraw_drag:` dans `kernel/modules/wm.s`. Reproduit
la condition historique du bug Opt-A/clock (handoff : « +120 sans protection
= FAIL »).

Usage :
    python3 tools/inject-pad-shift.py --apply 120
    python3 tools/inject-pad-shift.py --remove
    python3 tools/inject-pad-shift.py --status

Sentinelles dans le source pour idempotence :
    ; [PAD-SHIFT-BEGIN]
    .proc _pad_shift_test
            .res N, $EA
    .endproc
    ; [PAD-SHIFT-END]

Ne touche PAS aux SEI/CLI d'Opt-A — ceux-ci doivent être édités séparément
si on veut reproduire la condition no-SEI.
"""

import argparse
import re
import sys
from pathlib import Path

WM_S = Path(__file__).parent.parent / "kernel" / "modules" / "wm.s"
ANCHOR_RE = re.compile(r"^kernel_wm_redraw_drag:\s*$", re.MULTILINE)
BEGIN = "; [PAD-SHIFT-BEGIN]"
END = "; [PAD-SHIFT-END]"


def read_source():
    if not WM_S.exists():
        sys.exit(f"FATAL : {WM_S} introuvable")
    return WM_S.read_text(encoding="utf-8")


def write_source(text):
    WM_S.write_text(text, encoding="utf-8")


def find_pad_size(text):
    """Retourne (debut, fin, taille_actuelle) si pad présent, sinon None."""
    if BEGIN not in text or END not in text:
        return None
    b = text.index(BEGIN)
    e = text.index(END) + len(END) + 1
    block = text[b:e]
    m = re.search(r"\.res\s+(\d+)", block)
    if not m:
        return (b, e, 0)
    return (b, e, int(m.group(1)))


def status():
    text = read_source()
    info = find_pad_size(text)
    if info is None:
        print("PAD : absent")
        return 0
    _, _, n = info
    print(f"PAD : present, size={n} octets ($EA nop)")
    return 0


def remove(text):
    info = find_pad_size(text)
    if info is None:
        return text
    b, e, _ = info
    return text[:b] + text[e:]


def apply_pad(n):
    text = read_source()
    # idempotent : retire d'abord, puis insère
    text = remove(text)
    m = ANCHOR_RE.search(text)
    if not m:
        sys.exit("FATAL : ancre `kernel_wm_redraw_drag:` introuvable dans wm.s")
    block = (
        f"{BEGIN}\n"
        f"; [TEST-INFRA ADR-32 §10.5] pad temporaire de {n} octets pour reproduire\n"
        f"; la condition historique du bug Opt-A/clock. Insertion idempotente,\n"
        f"; retirer via `inject-pad-shift.py --remove`.\n"
        f".proc _pad_shift_test\n"
        f"        .res {n}, $EA\n"
        f".endproc\n"
        f"{END}\n"
    )
    new_text = text[: m.start()] + block + text[m.start() :]
    write_source(new_text)
    print(f"PAD : appliqué, {n} octets devant kernel_wm_redraw_drag")
    return 0


def remove_cmd():
    text = read_source()
    if find_pad_size(text) is None:
        print("PAD : déjà absent (no-op)")
        return 0
    write_source(remove(text))
    print("PAD : retiré")
    return 0


def main():
    ap = argparse.ArgumentParser(description="ADR-32 §10.5 pad-shift idempotent")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--apply", type=int, metavar="N", help="insère pad de N octets")
    g.add_argument("--remove", action="store_true", help="retire pad")
    g.add_argument("--status", action="store_true", help="indique l'état courant")
    args = ap.parse_args()
    if args.apply is not None:
        if args.apply < 0:
            sys.exit("FATAL : --apply N doit être >= 0")
        return apply_pad(args.apply)
    if args.remove:
        return remove_cmd()
    if args.status:
        return status()
    return 1


if __name__ == "__main__":
    sys.exit(main())
