# OricOS

> Système d'exploitation **multitâche graphique** natif pour la machine [Oric 2](https://github.com/benedictemarty/oric2) (CPU 65C816).
> Émulateur de référence : [oric2-golden-model](https://github.com/benedictemarty/oric2-golden-model) (alias *Phosphoric*).

[![Status](https://img.shields.io/badge/version-v0.40--alpha-green)](CHANGELOG.md)
[![Tests](https://img.shields.io/badge/tests%20golden%20model-541%2F541-brightgreen)](https://github.com/benedictemarty/oric2-golden-model)
[![Sprint](https://img.shields.io/badge/sprint-3.c%20v0.4-blue)](#roadmap)

## Statut

**v0.40-alpha — Sprint 3.c v0.4** (2026-05-09). Phase 1 du programme état-de-l'art active.

Le kernel boote sous Phosphoric `--machine oric2`, pré-charge fonte + chaîne en SDRAM via le GPU blitter, affiche **3 fenêtres distinctes** au format XVGA 1024×768×4bpp avec démo de drag (BLIT + clear).

## Caractéristiques v1 (ratifiées)

- **Multitâche préemptif** dirigé par timer VIA T1 — TCB×16 en bank 1 ([ADR-03](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md), [ADR-14](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md)).
- **Banking sans MMU**, isolation bank-based v1, *OS de confiance* ([ADR-04](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md)).
- **Kernel asm 65C816** + **userland C llvm-mos** mode 8-bit native mono-bank ([ADR-05 v2](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md)).
- **GUI multifenêtré** style SymbOS — drag, focus, BLIT/CLEAR via GPU ([ADR-06](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md)).
- **FAT32 sur SD** via SPI (`fat_init`/`fat_open`/`fat_read_file` multi-cluster) ([ADR-07](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md)).
- **Apps en bundle léger** `.oosobj` (header magique + sections) ([ADR-08](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md)).
- **Audio AY-3-8912** + extension SID-like (futur) ([ADR-09](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md)).
- **GPU blitter HW** alimenté via I/O ports `$0340-$034F` — 5 commandes (CLEAR, FILL_RECT, BLIT, LINE, TEXT) ([ADR-21](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md)).
- **VRAM en SDRAM unifiée** 16 MiB — framebuffer XVGA 1024×768×4bpp + backing-stores fenêtres ([ADR-19 v2](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md), [ADR-20 v3](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md)).
- **ABI syscall stable** : 18 syscalls v1 via `cop #$AA` + table dispatch, sentinelle `A=$FF` errno bank 1 ([ADR-17](https://github.com/benedictemarty/oric2/blob/main/docs/adr/0017-abi-syscall-userland.md)).
- **Driver model hybride** event-driven + sync ([ADR-16](https://github.com/benedictemarty/oric2/blob/main/docs/adr/0016-driver-model.md)).

## Build

Prérequis : **cc65** (`ca65`/`ld65` ≥ 2.19) avec support 65C816.

```bash
make            # produit build/kernel.bin
make clean
```

L'app `hello` standalone se construit avec :

```bash
cd apps/hello && make    # produit hello.oosobj (bundle .oosobj)
```

## Test

OricOS s'exécute sous Phosphoric en mode `--machine oric2`. Les tests d'intégration vivent côté `oric2-golden-model` :

| Test | Couvre |
|---|---|
| `tests/integration/test_oricos_boot.c` | Boot kernel + sentinelle |
| `tests/integration/test_oricos_visual.c` | Render PPM golden |
| `tests/integration/test_oricos_window.c` | Window manager 3 fenêtres + drag |
| `tests/integration/test_oricos_sd.c` | FAT32 multi-cluster |
| `tests/integration/test_oricos_gpu.c` | API kernel_gfx_* |
| `tests/integration/test_oricos_vram.c` | I/O ports VRAM |
| `tests/integration/test_oricos_live_alloc.c` | `kernel_alloc_live_bank` |

Run :

```bash
cd ../Phosphoric
make tests        # suite complète, doit afficher 541/541
```

## Layout du sous-projet

```
OricOS/
├── README.md            ← ce fichier
├── CLAUDE.md            ← instructions tactiques OricOS
├── CHANGELOG.md         ← journal des sprints
├── Makefile
├── kernel/              ← code kernel asm 65C816
│   ├── kernel.s         ← entry point + boot + drivers
│   └── kernel.cfg       ← linker config (ld65)
├── apps/                ← apps userland
│   └── hello/           ← première app standalone .oosobj
├── data/                ← assets (fontes, golden, etc.)
├── tools/               ← oricos-bundle.py et autres
├── include/             ← headers exportés (à venir)
├── docs/                ← spec internes
└── build/               ← artefacts (gitignored)
```

## Roadmap

> **Source de vérité unifiée** : [`oric2/BACKLOG.md`](https://github.com/benedictemarty/oric2/blob/main/BACKLOG.md).

### Sprints clos
- **Sprint 0** Hello world ✅
- **Sprint 1** Kernel core (vecteurs, scheduler round-robin, IRQ T1) ✅
- **Sprint 2.a-2.c+** VIA T1 scheduler, bank allocator v0.1, console minimal, fonte char ✅
- **Sprint 2.f-2.i** COP handler v0.1, TCB table 16 (ADR-14), free list LIFO, kernel_panic ✅
- **Sprint 2.j** FAT32 lecture seule (pipeline complet jusqu'à `fat_read_file` multi-cluster) ✅
- **Sprint 2.k-2.m** Format bundle + app loader + première app `hello` standalone ✅
- **Sprint 3.a-3.b** Mode HIRES Oric 2 (ADR-12) + intégration compositor + `kernel_hires2_*` ✅ (partiellement *legacy* depuis ADR-19 v2)
- **Sprint VRAM-1/2/3** vram_device 16 MiB, kernel_vram_*, pool LIVE banks ✅
- **Sprint GPU-1/2/3** GPU blitter v0.1→v0.3 (5 commandes) + API kernel_gfx_* complète ✅
- **Sprint 3.c v0.1→v0.4** Window manager basique + multi-fenêtre BLIT + true drag + démo palette VGA ✅

### Sprints actifs (Phase 1 programme état-de-l'art)
- **OS-2.f.v2** — COP handler v0.2 : table dispatch syscall 18 entrées (ADR-17). En cours.
- **OS-2.d** — driver clavier IRQ-driven event queue 16 keycodes (ADR-16). Débloqué.
- **OS-2.e** — driver console générique (`print_char`, `print_string`, cursor, scroll).

### Sprints à venir
- **Sprint 3.d** Toolkit minimal : font HIRES, label, button.
- **Sprint 3.e** Event loop multifenêtré + focus + drag depuis clavier/souris.
- **Sprint 4** Userland C llvm-mos : libc minimale, premier `hello.c`.
- **Sprint 5** Guest Oric 1 visible dans une fenêtre OricOS.

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — instructions OricOS spécifiques.
- [`../CLAUDE.md`](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md) — ADR ratifiées (workspace).
- [`../docs/adr/`](https://github.com/benedictemarty/oric2/blob/main/docs/adr/) — décisions au format MADR.
- [`../docs/MEMORY_MAP.md`](https://github.com/benedictemarty/oric2/blob/main/docs/MEMORY_MAP.md) — layout banks 24 bits.
- [`../docs/CONTRACT_HDL.md`](https://github.com/benedictemarty/oric2/blob/main/docs/CONTRACT_HDL.md) — contrat HDL ↔ golden model.

## Licence

**EUPL-1.2** (European Union Public Licence) © 2026 Bénédicte Marty — voir
[LICENSE](LICENSE).

> Licensed under the EUPL

## Contact

- **Maintainer**: [@benedictemarty](https://github.com/benedictemarty) (bmarty)
- **Email**: bmarty@mailo.com
- **Issues**: https://github.com/benedictemarty/OricOS/issues
- **Oric 2 hub**: https://github.com/benedictemarty/oric2
