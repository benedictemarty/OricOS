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

### Sprint 0 — Hello world (en cours)
- [x] Repo créé, structure initialisée.
- [ ] Kernel hello world : boot asm 65C816, écrit sentinel, STP.
- [ ] Build via ca65/ld65 → flat binary chargeable en bank 1.
- [ ] Test intégration côté Phosphoric (`test_oricos_boot`).

### Sprint 1 — Kernel core
- [ ] Vecteurs natifs (NMI/RES/IRQ/COP/BRK/ABORT) installés en bank 1.
- [ ] Stubs trampoline en bank 0 (routage E↔N).
- [ ] Scheduler préemptif minimal (1-2 tâches kernel).
- [ ] IRQ timer (ULA tick).

### Sprint 2 — IPC et drivers
- [ ] Driver console (text mode 80x25 sur ULA host).
- [ ] FAT32 SD lecture seule.
- [ ] Allocator banks dynamique.

### Sprint 3 — GUI
- [ ] Window manager basique (1 fenêtre).
- [ ] Toolkit minimal (frame, text, button).
- [ ] Compositor logique au-dessus du HW.

### Sprint 4 — Userland C (llvm-mos requis)
- [ ] Toolchain llvm-mos intégrée.
- [ ] libc minimal.
- [ ] Première app : `clock` (horloge).

### Sprint 5 — Guest Oric 1
- [ ] Lancement guest Oric 1 dans une fenêtre OricOS.
- [ ] Routage I/O guest (clavier, ULA guest).
- [ ] Démo : BASIC 1.0 fonctionnel dans une fenêtre OricOS.

---

## 8. Glossaire

Voir `/home/bmarty/oric2/CLAUDE.md` §8 et `/home/bmarty/oric2/docs/DAT.md` §7.

---

*v0.1 — 2026-05-08, initialisation.*
