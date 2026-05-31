#!/usr/bin/env python3
# SPDX-License-Identifier: EUPL-1.2
# Copyright (c) 2026 Bénédicte Marty
"""
test_audit_smart.py — corpus de régression pour audit-smart.py.

Vérifie que le linter :
  - DÉTECTE les patterns suspects (`known_bad_rep20.s`, `known_bad_rep30.s`)
  - LAISSE PASSER les patterns OK (`known_good_a16.s`, `known_good_no_branch.s`)

Verrouille le bug critique fixé : le pré-filtre `"20" in operand` qui
ignorait `rep #$30` → tracker m_state faux → verdicts faussement verts.

Usage : `python3 tools/tests/test_audit_smart.py`
Exit 0 si tous les cas conformes, 1 sinon. Intégré à `make audit-smart`.
"""

import os
import sys

# Ajoute tools/ au path pour importer audit-smart (qui n'est pas un module
# .py classique — on appelle via sys.argv).
HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS_DIR = os.path.dirname(HERE)
sys.path.insert(0, TOOLS_DIR)

# Import direct du module (renommé internally à cause du tiret).
import importlib.util
spec = importlib.util.spec_from_file_location(
    "audit_smart", os.path.join(TOOLS_DIR, "audit-smart.py"))
audit_smart = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit_smart)

# (file, expected_finding_count, label_attendu) — None pour cas good.
CASES = [
    ("known_bad_rep20.s",   1, "bad_label"),
    ("known_bad_rep30.s",   1, "bad_label"),
    ("known_good_a16.s",    0, None),
    ("known_good_no_branch.s", 0, None),
]


def main():
    failed = []
    for fname, expected_n, expected_lbl in CASES:
        path = os.path.join(HERE, fname)
        findings = audit_smart.scan_file(path)
        labels = [f["label"] for f in findings]
        if len(findings) != expected_n:
            failed.append(
                f"  {fname}: expected {expected_n} finding(s), got "
                f"{len(findings)} ({labels})")
            continue
        if expected_lbl and expected_lbl not in labels:
            failed.append(
                f"  {fname}: expected label '{expected_lbl}' in findings, "
                f"got {labels}")
            continue
        print(f"  {fname}: OK ({len(findings)} finding(s))")

    if failed:
        print("\naudit-smart test corpus FAILED :")
        for line in failed:
            print(line)
        sys.exit(1)
    print("\ntest_audit_smart: corpus OK (4/4)")
    sys.exit(0)


if __name__ == "__main__":
    main()
