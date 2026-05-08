# OricOS

> Système d'exploitation multitâche graphique natif Oric 2 (CPU 65C816).
> Sous-projet du workspace [Oric 2](https://github.com/benedictemarty/oric2).
> Émulateur de référence : [Phosphoric](https://github.com/benedictemarty/Phosphoric).

## Statut

**v0.1 (Sprint 0 — Hello world)** — initialisation 2026-05-08.

Caractéristiques v1 (ratifiées) :
- Multitâche **préemptif** dirigé par timer (ADR-03, réf SymbOS).
- Banking sans MMU, isolation bank-based v1 (ADR-04).
- Kernel **asm 65C816** + userland **C llvm-mos** (ADR-05).
- GUI **SymbOS-like** : multifenêtré, drag & drop, taskbar (ADR-06).
- FAT32 sur SD via SPI (ADR-07).
- Apps en **bundle léger** (header + sections, ADR-08).
- Audio AY-3-8912 + extension SID-like (ADR-09).
- Mode HIRES 240×200 × 3 bpp direct, 8 couleurs/pixel (ADR-12).

Spécifications :
- [`/home/bmarty/oric2/CLAUDE.md`](https://github.com/benedictemarty/oric2/blob/main/CLAUDE.md) — instructions tactiques (ADR ratifiées).
- [`/home/bmarty/oric2/docs/DAT.md`](https://github.com/benedictemarty/oric2/blob/main/docs/DAT.md) — Document d'Architecture (IEEE 42010).
- [`/home/bmarty/oric2/docs/MEMORY_MAP.md`](https://github.com/benedictemarty/oric2/blob/main/docs/MEMORY_MAP.md) — Memory map.

## Build

Prérequis : **cc65** (ca65/ld65 ≥ 2.19) avec support 65C816.

```bash
make            # produit build/kernel.bin
make clean
```

## Test

OricOS s'exécute sous Phosphoric en mode `--machine oric2`. Le test
d'intégration boot-sentinel vit côté Phosphoric : voir
[`Phosphoric/tests/integration/test_oricos_boot.c`](https://github.com/benedictemarty/Phosphoric/blob/main/tests/integration/test_oricos_boot.c).

## Roadmap

Sprint 0 (en cours) → Sprint 5 : guest Oric 1 dans OricOS. Voir
[CLAUDE.md §7](CLAUDE.md).

## Licence

À définir (TBD — décision business).
