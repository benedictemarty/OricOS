#!/usr/bin/env python3
# SPDX-License-Identifier: EUPL-1.2
# Copyright (c) 2026 Bénédicte Marty
"""
audit-smart.py — détecteur de bugs latents `.smart` ca65 sur le kernel OricOS.

Pattern recherché (cf. bug taskbar fixé 2026-05-30, commit `1747df5`) :
- label précédé textuellement par un flow-break inconditionnel
  (`rts`/`rtl`/`rti`/`jmp`/`jml`/`bra`/`brl`) → pas de fall-through M=16,
- atteint par au moins une branche conditionnelle (`bcc`/`bcs`/`beq`/`bne`/
  `bmi`/`bpl`/`bvc`/`bvs`/`bra`/`brl`/`jmp`/`jml`) émise depuis une région
  M=16 (post-`rep #$20`, avant `sep #$20`),
- les premières instructions au label utilisent un opcode immédiat
  M-dépendant (`adc/cmp/lda/sbc/and/ora/eor/bit #imm`),
- pas de `.a16` explicite au label.

`.smart` propage l'état M en walk LINÉAIRE du source. Le pattern ci-dessus
casse la propagation : `.smart` re-bascule sur M=8 par défaut au label
→ opcode immédiat encodé en 2 octets au lieu de 3 → corruption silencieuse
en runtime M=16.

Usage : `python3 tools/audit-smart.py [SOURCE_DIR]`
Exit 0 si aucun suspect, 1 sinon. Intégrable en CI via `make audit-smart`.
"""

import os
import re
import sys

# Opcodes immédiat M-dépendants (consomment 1 byte si M=8, 2 si M=16).
M_DEP_IMM_OPS = {"adc", "cmp", "lda", "sbc", "and", "ora", "eor", "bit"}
# Flow-breaks unconditionnels (cassent fall-through linéaire).
FLOW_BREAKS = {"rts", "rtl", "rti", "jmp", "jml", "bra", "brl"}
# Branches conditionnelles + bra/brl/jmp (n'importe lequel peut viser un label).
BRANCHES = {"bcc", "bcs", "beq", "bne", "bmi", "bpl", "bvc", "bvs",
            "bra", "brl", "jmp", "jml"}

# Match `label:` (avec ou sans export) ou `label =`.
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:")
# Match instruction (mnémonique seul ou avec opérande).
INSTR_RE = re.compile(r"^\s+(\.?[a-z][a-z0-9]*)\b\s*(.*?)(?:\s*;.*)?$")


def strip_comment(line: str) -> str:
    """Enlève les commentaires `;` (hors strings, ignorés ici)."""
    semi = line.find(";")
    return (line[:semi] if semi >= 0 else line).rstrip()


def scan_file(path: str):
    """Walk linéaire d'un fichier .s. Renvoie liste de findings."""
    with open(path, "r", encoding="utf-8", errors="replace") as fp:
        raw = fp.readlines()

    # Première passe : index label → (line_no, m_state au label).
    labels = {}              # name → line_no (1-based)
    label_prev_instr = {}    # name → mnemonique de l'instr non-comment précédente
    label_m_at_def = {}      # name → m_state que `.smart` voit (0=16-bit, 1=8-bit)
    branch_to = {}           # name → liste (line_no, branch_mnemonic, m_at_site)
    label_first_imm = {}     # name → (line_no, mnemonique, opérande) ou None
    label_has_a16 = set()    # noms de labels qui démarrent par `.a16`

    m_state = 1               # init M=8 (sep #$30 au boot)
    last_real_instr = None    # dernier mnémonique non-directive

    # On scanne ligne par ligne pour identifier labels + flow + M-state.
    for i, line in enumerate(raw, start=1):
        stripped = strip_comment(line)
        if not stripped.strip():
            continue

        lbl_m = LABEL_RE.match(stripped)
        if lbl_m:
            name = lbl_m.group(1)
            # Capture l'état au moment de la définition + le prev real instr.
            labels[name] = i
            label_prev_instr[name] = last_real_instr
            label_m_at_def[name] = m_state
            label_first_imm[name] = None
            # Reste du même ligne après le `:` peut contenir une instr (rare).
            rest = stripped[lbl_m.end():].strip()
            if rest:
                handle_instr_text(name, rest, i, m_state,
                                  branch_to, label_first_imm, label_has_a16)
            continue

        instr_m = INSTR_RE.match(stripped)
        if not instr_m:
            continue
        mnemo = instr_m.group(1).lower()
        operand = instr_m.group(2).strip()

        # Update M-state (directives + rep/sep).
        if mnemo == ".a16":
            m_state = 0
            continue
        if mnemo == ".a8":
            m_state = 1
            continue
        # rep/sep : on regarde le bit 5 (M) de l'immédiat. NE PAS pré-filtrer
        # sur "20" dans la chaîne — ça écartait `#$30` (qui pose ET M ET X)
        # et corrompait silencieusement le tracker (bug critique : le linter
        # rendait des verdicts faussement verts sur tout fichier utilisant
        # rep/sep #$30 — cf. boot.s, wm.s, handlers.s, etc.).
        if mnemo == "rep":
            val = parse_imm(operand)
            if val is not None and (val & 0x20):
                m_state = 0           # M=0 → A 16-bit
            continue
        if mnemo == "sep":
            val = parse_imm(operand)
            if val is not None and (val & 0x20):
                m_state = 1           # M=1 → A 8-bit
            continue

        # Note la première instr réelle pour caractériser les flow-breaks.
        last_real_instr = mnemo

        # Branches → enregistrer la cible.
        if mnemo in BRANCHES:
            target = operand.split()[0] if operand else ""
            # Filtre les jumps indirects (parenthèses).
            if target and not target.startswith("("):
                branch_to.setdefault(target, []).append((i, mnemo, m_state))

    # Deuxième passe : pour chaque label, trouver la première instr immédiat
    # M-dépendante atteinte AVANT tout `.a16`/`.a8`/`rep`/`sep`/flow-break.
    # On re-scanne séquentiellement à partir de chaque label.
    for name, line_no in labels.items():
        scan_first_imm_after_label(raw, line_no, name,
                                   label_first_imm, label_has_a16)

    # Identifier les suspects.
    findings = []
    for name, line_no in labels.items():
        prev = label_prev_instr.get(name)
        m_at_def = label_m_at_def.get(name, 1)
        callers = branch_to.get(name, [])
        m16_callers = [c for c in callers if c[2] == 0]
        first_imm = label_first_imm.get(name)
        has_a16 = name in label_has_a16

        # Critères de suspicion :
        if has_a16:
            continue                              # explicitement marqué OK
        if m_at_def == 0:
            continue                              # ca65 sait M=16, encodage correct
        if not first_imm:
            continue                              # pas d'opcode immédiat affecté
        if prev not in FLOW_BREAKS:
            continue                              # fall-through existe → ca65 propage
        if not m16_callers:
            continue                              # pas d'appel en M=16 → safe

        findings.append({
            "file": os.path.basename(path),
            "label": name,
            "label_line": line_no,
            "prev_instr": prev,
            "callers": m16_callers,
            "first_imm": first_imm,
        })

    return findings


def handle_instr_text(label_name, text, line_no, m_state,
                      branch_to, label_first_imm, label_has_a16):
    """Pour le rare cas où une instr suit le `:` sur la même ligne."""
    instr_m = INSTR_RE.match("        " + text)
    if not instr_m:
        return
    mnemo = instr_m.group(1).lower()
    operand = instr_m.group(2).strip()
    if mnemo == ".a16":
        label_has_a16.add(label_name)
    if mnemo in M_DEP_IMM_OPS and operand.startswith("#"):
        if label_first_imm.get(label_name) is None and m_state == 1:
            label_first_imm[label_name] = (line_no, mnemo, operand)


def scan_first_imm_after_label(raw, label_line, label_name,
                               label_first_imm, label_has_a16):
    """Scan séquentiel après le label pour trouver la 1re instr immédiat
    M-dépendante atteinte AVANT tout reset d'état M ou flow-break."""
    for j in range(label_line, len(raw)):
        line = strip_comment(raw[j])
        if not line.strip():
            continue
        if LABEL_RE.match(line) and j != label_line - 1:
            # Nouveau label → on a dépassé sans trouver, abandonne.
            return
        instr_m = INSTR_RE.match(line)
        if not instr_m:
            continue
        mnemo = instr_m.group(1).lower()
        operand = instr_m.group(2).strip()

        # Si on rencontre `.a16` au début, le label est protégé.
        if mnemo == ".a16":
            label_has_a16.add(label_name)
            return
        if mnemo in (".a8",) or mnemo in ("rep", "sep"):
            # État M altéré explicitement avant immédiat → sortie analyse.
            return
        if mnemo in FLOW_BREAKS:
            return
        if mnemo in M_DEP_IMM_OPS and operand.startswith("#"):
            label_first_imm[label_name] = (j + 1, mnemo, operand)
            return


def parse_imm(operand: str):
    """Parse `#$XX` ou `#XX` ou `#%XXXX...` en entier."""
    s = operand.strip().lstrip("#").strip()
    try:
        if s.startswith("$"):
            return int(s[1:], 16)
        if s.startswith("%"):
            return int(s[1:], 2)
        return int(s, 10)
    except ValueError:
        return None


def main():
    src_dir = sys.argv[1] if len(sys.argv) > 1 else "kernel"
    if not os.path.isdir(src_dir):
        print(f"audit-smart: dossier source introuvable: {src_dir}",
              file=sys.stderr)
        sys.exit(2)

    all_findings = []
    for root, _, files in os.walk(src_dir):
        for fname in files:
            if not fname.endswith(".s"):
                continue
            path = os.path.join(root, fname)
            all_findings.extend(scan_file(path))

    if not all_findings:
        print("audit-smart: kernel propre — aucun label suspect détecté.")
        sys.exit(0)

    print(f"audit-smart: {len(all_findings)} label(s) suspect(s) :\n")
    for f in all_findings:
        print(f"  [{f['file']}:{f['label_line']}] {f['label']}:")
        print(f"    prev textuel = {f['prev_instr']} (flow-break)")
        callers_str = ", ".join(
            f"L{ln}({mn})" for ln, mn, _ in f["callers"][:3])
        print(f"    callers M=16 : {callers_str}"
              + (" ..." if len(f["callers"]) > 3 else ""))
        imm_ln, imm_mn, imm_op = f["first_imm"]
        print(f"    1re imm M-dép : L{imm_ln} `{imm_mn} {imm_op}`")
        print(f"    → ajouter `.a16` au début du label.\n")
    sys.exit(1)


if __name__ == "__main__":
    main()
