# CHANGELOG - OricOS

All notable changes to the OricOS kernel project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.10.0] - 2026-05-08

### Sprint 2.e.1 — Driver console générique (print_char / print_string)

#### Added
- **`kernel_console_init`** : `CURSOR_ADDR=$BB81`, `CURSOR_X=1` (col 1
  après attribute byte INK $07).
- **`kernel_print_char (A=char)`** : gère char normal et LF (`$0A`).
  Stocke le char à `bank0:CURSOR_ADDR` via `STA [DP_PCPTR]` (opcode
  `$87` long indirect, pointer 24-bit en DP+$0C/$0D/$0E avec bank=$00).
  Avance `CURSOR_ADDR` et `CURSOR_X`. Wrap fin de ligne (CURSOR_X=40
  → reset à 0). Clamp si `CURSOR_ADDR >= $BFE0` (scroll v0.2).
- **`kernel_print_string (DP_PTR = ptr 24-bit)`** : lit string null-
  terminée via `LDA [DP_PTR],Y` (opcode `$B7`), boucle `print_char`.
- **`kernel_print_banner`** réécrit via `print_string` (banner_str =
  "OricOS v0.7\n\0" en CODE segment).
- **2 pointers DP séparés** : `DP_PTR` ($08-$0A) pour print_string
  (bank 1 strings) et `DP_PCPTR` ($0C-$0E) pour print_char (bank 0
  screen RAM). Évite la collision lors de print_string → print_char.

#### Diagnostic important — bug Phosphoric découvert
- **Opcode `$92` (STA (dp), DP indirect 16-bit) NON IMPLÉMENTÉ dans
  Phosphoric** + 7 autres opcodes DP indirect 65C816 manquants ($12,
  $32, $52, $72, $B2, $D2, $F2). Le decoder traite `$92` comme NOP
  size=1 (table opcode 6502), donc l'opérande est ré-interprété comme
  opcode → corruption stack → crash.
- Contournement OS-2.e.1 : utiliser `STA [dp]` (long indirect, $87,
  implémenté) avec bank explicite en DP+$0E.
- Tracé en dette technique workspace (`PH-fix-dp-indirect`).

#### Validation
- 494 tests OK (compteur inchangé).
- Démo SDL2 (`oric1-emu --kernel build/kernel.bin`) affiche
  "OricOS v0.7" en blanc à $BB81+ (banner via print_string).
- Screenshot test_oricos_sprint2a vérifie attribute byte $07 +
  banner "OricOS v0.7" + clear screen comme avant.

#### v0.2 (reportés)
- Carriage return (`$0D`).
- Scroll up.
- Attribut couleur multiple par ligne.
- Cursor blink visuel.

---

## [0.9.0] - 2026-05-08

### Sprint 2.d.1 — Driver clavier matrice (scan via PSG R14)

#### Added
- **Routines PSG bus** (`psg_set_reg`, `psg_write_data`, `psg_read_data`)
  via VIA PCR (CA2=BC1, CB2=BDIR). Constantes : `PCR_LATCH_ADDR=$EE`,
  `PCR_WRITE_DATA=$EA`, `PCR_READ_DATA=$AE`, `PCR_INACTIVE=$AA`.
- **`kernel_kbd_init`** : `DDRA=$FF`, `DDRB=$F7`, PSG R7=`$FF` (port A
  input), init `KBD_MATRIX[0..7]=$FF` (= no key pressed, active low).
- **`kernel_kbd_scan`** : scan 8 colonnes via VIA ORB[0:2] + lecture
  PSG R14, stocke matrice 8 octets à `$015470`. Appelé depuis IRQ T1
  handler à chaque tick.

#### Changed
- **Période T1 : 512 → 4096 cycles** (`T1_PERIOD_HI = $10`). Le scan
  dure ~830 cycles ; à 512 cycles de période, T1 ré-asserte avant que
  les tasks aient le temps d'exécuter (B_ctr restait à 0). 4096 cycles
  = 8 ticks/frame PAL, ~3000 cycles/slot disponibles aux tasks.

#### Validation
- 494 tests passent (compteur inchangé).
- `test_oricos_sprint2a` : avec scan actif, A_ctr=149 B_ctr=66 swap=9
  (vs A=247 B=239 sans scan, avant T1=512 → 4096).

#### Known issue (à creuser)
- **Bug Phosphoric latent** : `TXS` en mode N M=X=1 + ldx 8-bit copie
  seulement low byte → S high = $00 (au lieu de $01 attendu pour page 1
  stack). Stack OricOS tourne en bank 0 page 0 par chance. Observable
  via `TASK_A_S=$00F8` après save_A. Tracé dans `BACKLOG.md` racine
  workspace. Ne casse rien actuellement — à fixer côté Phosphoric.

---

## [Unreleased] - 2026-05-08

### Docs — Roadmap révisée suite point critique architecte
- §7 CLAUDE.md : insertion Sprints 2.d → 2.m comme prérequis stricts
  avant Sprint 3 GUI (driver clavier, console générique, syscalls,
  TCB refactor, allocator avec free, modèle d'erreur, FAT32, bundle
  apps, app loader).
- Source de vérité : `../BACKLOG.md` racine workspace.

---

## [0.8.0] - 2026-05-08

### Sprint 2.c+ — Fonte char embarquée (autonomie OS native)

#### Added
- **`data/charset.bin`** : fonte char 1024 octets (128 chars × 8 lignes),
  extraite de `roms/basic11b.rom` offset `$3B78`. Embarquée dans
  `kernel.bin` via `.incbin` au sein du segment `CHARSET`.
- **`kernel_install_charset`** : routine de boot qui copie 1024 octets
  de `bank 1 $5800` (segment CHARSET) vers `bank 0 $B400` (zone fonte
  Oric 1 mode TEXT). Boucle long-addressing, X 16-bit.
- **Segment `CHARSET`** dans `kernel.cfg`, start `$5800` (après
  IRQ_HANDLER à `$5600`).
- **Attribute byte `$07` (INK 7 = blanc)** écrit en `$00BB80`
  par `kernel_print_banner` pour rendre le banner visible (sans
  cela, INK par défaut = 0 = noir invisible).

#### Why
Le rendu Oric 1 mode TEXT lit la fonte char depuis RAM bank 0
`$B400-$B7FF`. La ROM Oric 1 historique copie cette fonte au boot
depuis sa propre image. OricOS boote sans la ROM Oric 1 — donc la
zone reste à zéro et tous les chars rendent en pixels noirs.
Solution philosophiquement cohérente avec l'identité d'OS natif :
embarquer la fonte directement dans `kernel.bin` et l'installer au
boot. OricOS devient totalement indépendant de la ROM Oric 1.

#### Validation
- `make` produit `build/kernel.bin` (57 344 octets, fill complet bank 1).
- Char 'O' confirmé à file offset `0x5878` (bitmap `1c 22 22 22 22 22 1c 00`).
- Test `test_oricos_sprint2a_via_t1_timer_drives_scheduler` passe (494 tests).
- Démo visible (`oric1-emu --kernel build/kernel.bin`) : "OricOS v0.7"
  s'affiche en blanc en haut-gauche dans la fenêtre SDL2.

---

## [0.7.0] - 2026-05-08

### Sprint 2.c — Driver console minimal
- `kernel_clear_screen` : remplit screen RAM Oric 1 (40x28, 1120 octets)
  d'espaces ASCII via boucle X 16-bit + STA long abs,X.
- `kernel_print_banner` : écrit "OricOS v0.7" à `$00BB80+1`.

## [0.6.0] - 2026-05-08

### Sprint 2.b — Bank allocator
- `kernel_alloc_bank` : allocation incrémentale pool banks 4-127.
- 3 démo allocs au boot, stockés à `BANK_DEMO+0..2`.

## [0.5.0] - 2026-05-08

### Sprint 2.a — VIA T1 drives scheduler
- Setup VIA T1 mode continuous IRQ (ACR=$40, T1CL/T1CH=$0200, IER=$C0).
- Scheduler ack via lecture `T1CL`.
- 10 ticks → STP propre.

## [0.4.0] - 2026-05-08

### Sprint 1.c — IRQ-driven scheduler

## [0.3.0] - 2026-05-08

### Sprint 1.b — Preemptive scheduler 2 tasks (round-robin)

## [0.2.0] - 2026-05-08

### Sprint 1.a — Native interrupts + sentinel "ORIOS\x00"

## [0.1.0] - 2026-05-08

### Sprint 0 — Hello world boot
- Bascule mode N (XCE), sentinels en bank 1.
