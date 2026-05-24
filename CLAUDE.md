# CLAUDE.md — OricOS

> Document directeur pour Claude Code dans le sous-projet OricOS du
> workspace Oric 2. À lire avant toute modification de code.

---

## 1. Identité

OricOS est le système d'exploitation natif de la machine **Oric 2**
(CPU 65C816, ULA double + compositor, banking 24-bit, sortie HDMI).

Caractéristiques v1 (ratifiées dans `/home/bmarty/oric2/CLAUDE.md` §2) :
- **Multitâche préemptif** dirigé par timer (ADR-03, réf SymbOS).
- **Banking sans MMU** — isolation bank-based v1, OS de confiance (ADR-04).
- **Kernel asm 65C816 + userland C llvm-mos** (ADR-05).
- **GUI SymbOS-like** : multifenêtré, drag & drop, taskbar (ADR-06).
- **FAT32 SD via SPI** (ADR-07) ; option `--hostfs` côté émulateur.
- **Apps en bundle léger** : header + sections (ADR-08).
- **Audio AY-3-8912 + extension SID-like** (ADR-09).

OricOS s'exécute par-dessus Phosphoric (mode `--machine oric2`) en mode
de développement, et sur ULX3S en cible HDL finale.

---

## 2. Toolchain

### Statut v0.1
- **ca65 / ld65** (cc65 toolchain) : disponibles, support 65C816 actif.
- **llvm-mos** : **non installé** — userland C différé.

### Build kernel
```bash
make            # produit build/kernel.bin
make clean
```

### Cible v1 (à venir)
- llvm-mos pour les apps userland.
- Linker scripts par bank avec relocations.
- Outils de packaging d'apps (bundle léger, ADR-08).

---

## 3. Layout du sous-projet

```
OricOS/
├── CLAUDE.md               ← ce fichier
├── README.md
├── Makefile
├── kernel/                 ← code kernel asm 65C816
│   ├── kernel.s            ← entry point + boot
│   └── kernel.cfg          ← linker config (ld65)
├── include/                ← headers exportés (vers userland futur)
├── tools/                  ← scripts build/test
├── docs/                   ← spec internes (à venir)
└── build/                  ← artefacts (gitignored)
```

---

## 4. Memory map cible

Cf. `/home/bmarty/oric2/docs/MEMORY_MAP.md` (spec ratifiée v1.0,
2026-05-08). En résumé :
- **Bank 0** : compat Oric 1 (intouchable par le kernel).
- **Bank 1** : kernel OricOS + ROM système (vecteurs natifs en $01FFE0+).
- **Bank 2** : code apps (initial pool).
- **Bank 3** : données apps (initial pool).
- **Banks 4-15** : pool kernel/apps additionnel.
- **Banks 16-127** : pool apps étendu.
- **Banks 128-191** : framebuffers et fenêtres.
- **Banks 192-255** : réservé.

---

## 5. Conventions

### Style asm
- Syntaxe **ca65** (`--cpu 65816`).
- Commentaires en français OK ; **noms de symboles en anglais** (cohérent
  avec Phosphoric).
- Préfixes : `kernel_*` pour symboles kernel publics, `_*` pour
  symboles privés au fichier.
- Indentation : 8 colonnes pour les instructions, mnémoniques en
  minuscules WDC (`lda`, `xce`, `jml`, …).

### Workflow
- Petits commits atomiques. Format : `[OS-vX.Y] description`.
- Référencer une ADR en commentaire si la décision n'est pas évidente :
  `; ADR-04 : pas de MMU, banking via PBR/DBR`.
- Tester contre Phosphoric `--machine oric2` à chaque modification.
- Avant tout refactor structurel, demander confirmation à l'humain.

### Git
- Auteur des commits : `benedicte <bmarty@mailo.com>` (config locale).
  Ne pas overrider via `-c user.name=…`.
- Remote `origin` = github.com/benedictemarty/OricOS (privé).

---

## 6. Validation

À chaque modification :
1. `make` compile sans erreur.
2. `make test` (à mettre en place — boot Phosphoric).
3. `make` aussi côté Phosphoric à la racine : 492+ tests doivent passer
   (le golden model n'est jamais cassé par OricOS).

---

## 7. Roadmap OricOS

> **Note 2026-05-08** : roadmap **révisée suite point critique**
> architecte senior. La version d'origine sautait directement de
> Sprint 2.c (driver console minimal) à Sprint 3 (GUI), ce qui n'était
> pas viable. Ajout de Sprints 2.d → 2.i comme prérequis stricts
> avant tout sprint GUI. Voir `BACKLOG.md` à la racine du workspace
> pour la source de vérité ordonnée.

### Sprint 0 — Hello world ✅ (clos 2026-05-08)
- [x] Kernel hello world : boot asm 65C816, sentinel, STP.
- [x] Build ca65/ld65 → flat binary chargeable en bank 1.
- [x] Test `test_oricos_boot` côté Phosphoric.

### Sprint 1 — Kernel core ✅ (clos 2026-05-08)
- [x] Vecteurs natifs (NMI/RES/IRQ) installés bank 0/1.
- [x] Stubs trampoline en bank 0 (routage E↔N).
- [x] Scheduler préemptif round-robin 2 tâches.
- [x] IRQ timer VIA T1.

### Sprint 2 — IPC et drivers ✅ (clos 2026-05-24)
- [x] **2.a** VIA T1 drives scheduler autonomously
- [x] **2.b** Bank allocator (incrémental v0.1)
- [x] **2.c** Driver console minimal (banner hardcoded)
- [x] **2.c+** Fonte char embarquée (autonomie OS native)
- [x] **2.d** Driver clavier Oric 2 KBD2 IRQ-driven (ADR-22, contrôleur paravirtualisé `$0350-$035F`, ring `$5860`, SYS_GET_KEY/READ_CHAR)
- [x] **2.e** Driver console générique (`print_char`/`print_string`/cursor/scroll/CR) — OS-2.e.2 ajoute CR + scroll up
- [x] **2.f** Mécanisme syscall (COP handler + table) — ✅ v0.2 (table dispatch 18 syscalls, ADR-13/17)
- [x] **2.g** Scheduler TCB-based (table 16 + bitmap, ADR-14) — ✅ v0.1 (N tâches dynamiques reporté v0.2)
- [x] **2.h** Bank allocator free list LIFO — ✅ v0.1 (bitmap reportée v0.2)
- [x] **2.i** Modèle d'erreur kernel — v0.1 (panic+hex) + v0.2 (log ring buffer `$54E0`, codes nommés, wiring panic/cop_invalid/alloc)
- [x] **2.j** FAT32 SD lecture seule — v0.8 (`fat_init`/`fat_open`/`fat_read_cluster`/`fat_next_cluster`/`fat_read_file`, multi-cluster ≤ 64 KiB ; reporté : > 64 KiB, BPS≠512, subdirs)
- [x] **2.k** Format bundle apps (header + sections, ADR-08) — `kernel_bundle_validate`/`find_code`
- [x] **2.l** App loader (parse bundle, alloc bank, exec) — v0.2 multi-cluster depuis SD
- [x] **2.m** Première app "hello" en asm — `apps/hello/`, pipeline ca65+ld65+`oricos-bundle.py`

> **Sprint 2 clos.** Prochain : voir BACKLOG.md (source de vérité ordonnée) —
> options : Sprint 3 GUI (partiellement amorcé : `kernel_window_draw`, GPU helpers),
> Sprint 4 userland C (llvm-mos), ou PH-bootrom (refactor `--kernel`).

### Sprint 3 — GUI (en cours)
- [x] Compositor logique au-dessus du HW (B4 + GPU blitter ADR-21).
- [~] Window manager basique : `kernel_window_draw` (SP-3.c) + **window table
      N fenêtres / focus / hit-test / move** (SP-3.e v0.1, ADR-24 souris).
- [~] Event loop : `kernel_wm_mouse_step` (clic→focus, drag) **IRQ-driven**
      (v0.2 : IRQ MOU2 dans le handler, scheduler gaté sur T1). Backing-store
      DMA + drag live visible reportés v0.3 (bloqué affichage XVGA SDL).
- [ ] Toolkit minimal (frame, label, button) — SP-3.d.

### Sprint 4 — Userland C (llvm-mos requis ; non-trivial)
- [ ] PoC llvm-mos 65C816 mode N (peut nécessiter PR upstream).
- [ ] libc minimal (printf via syscalls, malloc bank-based).
- [ ] Première app C : `clock`.

### Sprint 5 — Guest Oric 1
- [ ] Lancement guest Oric 1 dans une fenêtre OricOS.
- [ ] Routage I/O guest (clavier, ULA guest).
- [ ] Démo : BASIC 1.0 fonctionnel dans une fenêtre OricOS.

---

## 8. Glossaire

Voir `/home/bmarty/oric2/CLAUDE.md` §8 et `/home/bmarty/oric2/docs/DAT.md` §7.

---

*v0.1 — 2026-05-08, initialisation.*
