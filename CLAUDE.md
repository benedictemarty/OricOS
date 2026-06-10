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

### `.smart` ca65 — convention obligatoire (cf. bug taskbar 2026-05-30)

**Tout label atteint UNIQUEMENT via `bcc`/`bcs`/`bra`/`brl`/`bne`/`beq` etc.
depuis une région M=16 (post-`rep #$20`), sans fall-through M=16 depuis
l'instruction textuelle précédente, DOIT ouvrir par `.a16` explicite.**

Pourquoi : `.smart` propage l'état M en walk linéaire du source. Quand
un label est précédé textuellement par un flow-break (`rts`/`jmp`/`bra`
inconditionnel/`rti`), `.smart` perd l'état M=16 ouvert plus haut et
re-bascule par défaut sur M=8 au label. Les opcodes à immédiat
(`adc`/`cmp`/`lda`/`sbc`/`and`/`ora`/`eor`/`bit #imm`) sont alors
encodés en 2 octets au lieu de 3. En runtime M=16, le décodeur consomme
le byte d'opcode suivant comme high byte → corruption silencieuse.

Bug type fixé : `wm.s _tbh_advance:` (commit `1747df5`). Cause : label
suivant `bra _tbh_got_slot` (flow-break), atteint via `bcc/bcs` M=16,
`adc #TB_BTN_STRIDE` encodé en 2 bytes (`69 7C`) au lieu de 3
(`69 7C 00`) → `TB_BTN_X` corrompu (`$8D80` au lieu de `$0080`).

Si ratifié : un audit kernel a vérifié (2026-05-30) qu'**aucun autre
label suspect ne reste**. Un script CI `tools/audit-smart.py` détecte
les nouveaux cas — `make audit-smart` doit passer à chaque commit.

Recette d'écriture safe :
```asm
some_label:                          ; ⬅ pas de fall-through M=16
        .a16                         ; ⬅ OBLIGATOIRE si atteint en M=16
        lda some_16bit_var
        adc #IMM_16BIT
        sta some_16bit_var
        sep #$20
        .a8                          ; ⬅ refermer proprement (optionnel mais propre)
```

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

## 5bis. Invariant — `WM_TASKMODE` : l'EVENT est la source de vérité, jamais le device

**En `WM_TASKMODE=$A5`, `kernel_wm_mouse_step` et toute sa chaîne (hit-test, drag, resize,
bouton) lisent l'ÉVÉNEMENT poppé de RAW_RING (`$D0..$D9`), JAMAIS l'état device
(`MOUSE_X/Y`, `MOUSE_DX/DY`, `MOUSE_BTN`/`PREV_BTN`).**

Pourquoi : en taskmode, mouse_step est différé. Entre l'IRQ qui lit MOU2 et le moment où
task_wm traite l'event, d'autres IRQ écrasent l'état device (positions, deltas read-clear,
bouton). Lire le device hors du contexte IRQ qui l'a produit = corruption (curseur figé,
fenêtre étirée, fragments).

Le code a déjà le bon modèle (`wm.s` ~3749 : `lda $D4 → WM_ARG_X`, where_x de l'event) et le
mauvais (`wm.s` ~2179 : `lda MOUSE_X`). **Tout nouveau code de traitement souris suit le
modèle 3749.** `task_wm_install_event_state` copie event→MOUSE_* AVANT mouse_step ; tant que
cette copie est complète et exacte, lire `MOUSE_*` redevient sûr — mais la règle de revue
reste : vérifier que la valeur lue vient de l'event, pas d'un device non-réinstallé.

Corollaire (état mutable à un seul producteur) : **TCB.STATE**, **GFX_BPL**, les slots ZP
partagés (`WM_ARG_*`, `GFX_*`) suivent la même loi — un état écrit par deux contextes
(IRQ + tâche) sans protocole = bug. Single-writer ou transaction atomique sous `sei`.

---

## 5ter. Largeur des grandeurs DÉRIVÉES d'un cumul (≠ device instantané)

**Une grandeur dérivée d'une position/compteur cumulé (ex. `delta = WHERE − LAST`) a une
dynamique plus large que la même grandeur lue du device. Sa largeur de stockage doit suivre :
16 bits, pas 8.**

Pourquoi : un delta device par IRQ est ≤ ±127 (8 bits OK). Mais un delta *dérivé* d'events
coalescés peut dépasser ±127 → un stockage 8-bit le tronque, et un `_sext8_to16` derrière
**inverse le signe** (saut de +200 → −56).

Recette : quand un fix fait d'un event/cumul la source d'une grandeur auparavant lue du
device, **auditer la largeur de TOUS ses consommateurs** (ex. drag ET resize). Méfiance
absolue sur tout commentaire « sat8 implicite » — il n'y a pas de saturation implicite en
asm, seulement de la troncature.

---

## 5quater. Discipline M/X sur les RMW mémoire

**Côté émulateur (Phosphoric) : toute instruction RMW mémoire (ASL/LSR/ROL/ROR/INC/DEC, modes
dp/dp,X/abs/abs,X) DOIT être M-aware** — 16-bit quand M=0, via `cpu816_mem_read16/write16` +
`update_nz_M`, comme les variantes accumulateur. Une RMW mem 8-bit-fixe sous M=16 corrompt
silencieusement (`asl $0080` → `$0000` au lieu de `$0100`).

**Côté kernel : tout `asl/lsr/rol/ror/inc/dec` sur MÉMOIRE sous `rep #$20`/`#$30` est un point
de vigilance**, à combiner avec la convention `.smart` ci-dessus. Site connu : `sched.s` scan
bitmap (`asl SCHED_TMP` M=16). Tout nouveau RMW-mem en mode 16-bit exige un test de conformance
CPU avant d'être considéré correct.

---

## 5quinquies. Règles de process debug (non négociables)

- **R1 — Pas de fix sans preuve de la cause.** Une hypothèse plausible n'est pas une cause.
  Avant tout fix : une trace, une mesure, ou une lecture de code qui EXCLUT les alternatives.
- **R2 — Lire pour CONTRAINDRE, pas pour confirmer.** Avant d'hypothéser une race : *qui tient
  I (sei/cli) ? qui écrit cet état, depuis combien de contextes ? la fenêtre supposée
  existe-t-elle physiquement ?*
- **R3 — Mesurer, jamais estimer en se faisant passer pour mesurer.** Si la donnée manque, dire
  « je ne peux pas l'affirmer » et l'obtenir (build, `kernel.map`, watchpoint). Distinguer
  **taille de fichier paddé** (`fill=yes`, `ls -l`) vs **contenu réel** (`kernel.map` fait foi).
- **R4 — Test différentiel d'abord.** Isoler la variable discriminante par différence (legacy
  vs taskmode, avec/sans ctl_demo, pid 7 vs 8) AVANT de lire le code.
- **R5 — Échec d'allocation kernel = BRUYANT.** `kernel_task_create`/`kernel_alloc_bank` dont
  le retour 0 n'est pas testé est interdit pour une ressource système :
  ```asm
          jsr kernel_task_create
          bne :+
          lda #PANIC_NO_SLOT
          jsr kernel_panic
  :
  ```
- **R6 — Après le 2ᵉ bug d'une même FAMILLE : ériger l'invariant, auditer proactivement.** Ne
  pas débuguer le 3ᵉ comme un incident isolé ; poser l'invariant, grep tous les sites, corriger
  d'un coup.

---

## 5sexies. Tests — conformance et fragilité

- **R7 — Conformance CPU indépendante obligatoire pour tout opcode touché.** Un test
  d'intégration ne peut PAS attraper une idée fausse partagée par l'OS et l'émulateur. Tout
  opcode CPU ajouté/modifié dans Phosphoric exige un test unitaire à vecteurs known-good
  externes (Klaus Dormann étendu 65C816 : RMW mem M=8/M=16, M/X, MVN/MVP, post-XCE, vecteurs).
- **R8 — Tests cycle-précis : marge, pas couperet.** Un test de timing ne doit pas transformer
  « +5 cycles d'un fix correct » en échec rouge. Si un fix correct change le budget, rebaser le
  budget en le justifiant dans le commit — jamais désactiver le test, jamais contourner le fix.
- **R9 — Versionner les harness de repro AVEC le code** (golden-model, pas workspace privé) :
  un repro non versionné = personne ne peut le rejouer = retour à l'analyse statique (source des
  erreurs R3).

---

## 5septies. Frontière kernel ↔ émulateur

**Quand un bug apparaît, déterminer AVANT tout fix s'il est côté kernel ou côté émulateur.**
Le kernel peut être correct et l'émulateur faux. Test décisif : *le comportement attendu est-il
celui d'un 65C816 réel ?* Si oui et que l'émulateur diverge → fix émulateur ; un fix kernel
serait une rustine masquant le vrai bug. Critère d'acceptation type : « le bug disparaît SANS
modifier le kernel » prouve que c'était l'émulateur.

---

## 5octies. Checklist avant tout commit de fix

1. [ ] Test différentiel fait, variable discriminante isolée (R4).
2. [ ] Cause PROUVÉE (trace/mesure/lecture excluant les alternatives), pas hypothèse (R1, R2).
3. [ ] Kernel vs émulateur tranché (R3 mesure, §5septies).
4. [ ] Si état mutable : single-writer / event-source vérifié (§5bis).
5. [ ] Si grandeur dérivée : largeur 16-bit auditée chez TOUS les consommateurs (§5ter).
6. [ ] Si RMW-mem en M=16 : M-aware + test conformance (§5quater, R7).
7. [ ] Si nouvelle famille : invariant posé, sites audités (R6).
8. [ ] `make audit-smart` + `make` + suite golden-model verte ; budgets cycles rebasés-justifiés (R8).
9. [ ] Échecs d'alloc bruyants (R5). Harness de repro versionné (R9).
10. [ ] Si état partagé IRQ↔tâche : protocole P1/P2/P3 respecté (§5nonies).

---

## 5nonies. INVARIANT ZP/IRQ — protocoles P1/P2/P3 (ADR-32 ratifiée 2026-06-10)

**Tout état partagé entre contexte IRQ top-half et contexte tâche obéit à
l'un des trois protocoles, sans exception :**

- **P1 — Enveloppe IRQ.** Un chemin IRQ qui clobbe des scratch ZP les
  sauvegarde/restaure intégralement. Existant : le bloc souris de
  `kernel_irq_handler` enveloppe la plage **$08-$93** vers `IRQ_ZP_SAVE`
  ($019100) — un syscall body préempté reprend avec ses scratch intacts.
  Tout nouveau sous-arbre IRQ écrivant de la ZP scratch passe sous
  l'enveloppe existante ou ajoute la sienne.
- **P2 — Section critique côté tâche.** Toute structure à RMW partagée
  (rings EVENT/RAW/KBD, compteurs, slots) s'accède côté tâche sous
  `php`/`sei` … `plp` — pattern `event_pop`/`raw_pop`/`kbd_ring_pop`/
  pushers tâche (`push_menu`, `push_verbatim`). Tout NOUVEAU pusher ou
  consommateur appelable hors IRQ suit la même règle.
- **P3 — Registres intégraux.** La frame IRQ sauvegarde A/X/Y en
  **16-bit** (`rep #$30` avant pha/phx/phy). Tout forgeur de resume frame
  suit le format 10 octets `[Y16][X16][A16][P][PCL][PCH][PBR]` — liste
  exhaustive en tête de `handlers.s`. Un push 8-bit décale S de 3 et le
  `rti` part dans le décor.

**Gardes mécaniques** (dans `make tests`, chacune vue ROUGE sur son
défaut avant son fix) : `test-oricos-irq-frame-m16` (P3),
`test-position-shift` v2.2 (P1), `test-oricos-evt-push-atomic` (P2),
`test-oricos-nmi-safe` (layout code/data $5500).

Rappel : `forbid`/`permit` (ADR-25) ne masque PAS les IRQ — sa portée est
tâche↔tâche uniquement. Les protocoles ci-dessus sont LA réponse au trou
IRQ↔tâche. Dossier complet : `docs/adr/0032-zp-race-irq-task.md`.

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
- [x] Event loop : `kernel_wm_mouse_step` IRQ-driven (clic→focus, drag→move
      + redraw). v0.3 : coords GPU 16-bit (FILL_RECT16) + `kernel_wm_redraw`
      (desktop XVGA visible). v0.4 : **main loop persistant** (`NO_STP_FLAG`) +
      delta par événement → **drag fenêtre live**. v0.5 : **curseur dessiné**
      (`kernel_wm_draw_cursor`) + relative-mode SDL (LCtrl+RShift). v0.6 :
      **backing-store curseur** (`kernel_wm_cursor_blit` : motion = sauve/restaure
      8×8 via VRAM I/O, plus de full-redraw par mouvement). v0.7 : **drag
      incrémental** (`kernel_wm_redraw_drag` : efface l'ancien rect au lieu du
      clear plein écran). v0.8 : **couleur titlebar selon focus**
      (`WM_TITLE_COL`, focus=lightblue/non-focus=darkgray ; multi-dirty-rect
      jugé inutile — le focus-change fait déjà un full-redraw correct).
- [x] Toolkit minimal (frame, label, button) — SP-3.d v0.1 (`kernel_tk_label`/
      `frame`/`button` + GPU TEXT16 coords 16-bit). v0.2 : **widgets managés**
      (`kernel_wm_add_widget` + `_wm_draw_all_widgets`) attachés aux fenêtres,
      redessinés avec elles → suivent le drag. v0.3 : **bouton cliquable**
      (`_wm_widget_hit` → `WIDGET_ACTIVE`, face pressée darkgray). v0.4 :
      **callbacks de bouton** (`_wm_invoke_active_cb`, `jsr (vec,X)` en bank 1).
      v0.5 : **barre de menu déroulant** ; v0.6 : **multi-menu table-driven**
      (`menu_defs`, N menus : System/View).
- [x] Chrome de fenêtre — SP-3.f : **titre dans titlebar** (v0.1) +
      **bouton fermer** (v0.2). `kernel_wm_add` uploade le titre en SDRAM
      (`WM_ARG_TITLE_LO/HI → $012000+slot×$100`), `WM_TITLES[slot]=$01`.
      `_wm_draw_title_and_close` : TEXT16 titre blanc + "X" lightred.
      `_wm_close_btn_hit` : hit-test zone close. `kernel_wm_close` : efface
      slot, décrémente `WM_COUNT`, rebind focus. Fenêtres "OricOS"/"Editor".
      Tests : `test_wm_window_title` + `test_wm_close_button`. 549 tests verts.
- [x] **SP-3.h — Maximize/minimize** : `kernel_wm_maximize` (bascule normale↔max,
      sauvegarde coords dans `WM_SAVED_RECTS` via `STA f:WM_SAVED_RECTS,X`) +
      `kernel_wm_minimize` (cache fenêtre, `WM_STATE_HIDDEN`) + restore depuis
      taskbar. `_wm_chrome_hit` hit-test 3 zones chrome (×/□/_). Drag désactivé
      sur fenêtre maximisée. Fix critique : `rep #$20` explicite dans
      `_crh_test_max/_crh_test_min` (bug tracking mode ca65 → 8-bit tronqué
      corrompait ZP $22-$24). Tests : `test_wm_states_init`, `test_wm_maximize`,
      `test_wm_minimize_restore`. 554 tests verts.
- [x] **SP-3.j — Dialog modal** : `WM_MODAL` (`$015AD5`) + `kernel_wm_set_modal` /
      `kernel_wm_clear_modal`. Auto-clear dans `kernel_wm_close`. Blocage des clics
      hors modal dans `wm_step_normal_hit`. 3 tests. 560 tests verts.
- [x] **SP-3.k — Icônes desktop** : `ICON_TABLE` (4 × 16B, `$015ADA`), `kernel_icon_add`
      (upload label SDRAM `$011200+id×$10`), `kernel_icon_draw_all` (FILL_RECT16 32×32 +
      TEXT16 label), `_icon_hit` (hit-test mouse), callback `jsr (WM_DP_TMP,X)` (X=0).
      Intégré dans `kernel_wm_redraw` (icônes avant fenêtres) et `kernel_wm_mouse_step`
      (clic vide → `_icon_hit` → `ICON_SELECTED`). 2 icônes démo ("Files"/"Prefs").
      3 tests. 563 tests verts.
- [x] **SP-3.i — Resize fenêtres** : `_wm_resize_hit` (bord droit/bas,
      `RESIZE_MARGIN=6 px`, désactivé si maximisée) + `_wm_do_resize` (DX→w,
      DY→h, clamp `RESIZE_MIN_W=60/RESIZE_MIN_H=40`, redraw incrémental).
      `WM_RESIZE_ARMED` (`$015ACE`) + `WM_RESIZE_EDGE` (`$015ACF`) initialisés
      dans `kernel_wm_init`. Tests : `test_wm_resize_init`, `test_wm_resize_right_edge`,
      `test_wm_resize_bottom_edge`. 557 tests verts.

### Sprint 4 — Userland C (llvm-mos requis ; non-trivial)
- [x] **PoC llvm-mos 65C816 mode N** (TC-llvmmos-install + TC-poc-hello-c, 2026-05-25).
      llvm-mos v23.0.1, target `mos-oricos`, app `apps/hello_c/hello.c` exécutée
      sous OricOS dans Phosphoric (test `test_oricos_helloc`). Fixes post-revue :
      oricos.h LTO/SSOT (`_ORICOS_LDA_SYS`), `kernel_app_exec` copie 16-bit,
      driver console adressage long (DBR-indépendant), deadlock `SYS_READ_CHAR`
      (cli handler COP). Repro build durcie (`-I` SDK + deps Makefile modules).
- [~] libc minimal (TC-libc : `liboricos.a` — putchar/puts/printf/strlen/malloc
      bump bank-local ; cf. CHANGELOG). `printf` via syscalls : OK.
- [x] **Première app C : `clock`** (2026-05-26) : app pilotée par le temps
      (`apps/clock/`) — fenêtre + barre de progression rythmée par `SYS_GET_TICKS`
      ($1D) + `SYS_YIELD`, dessin `SYS_GFX_FILL_RECT`/`SYS_WIN_FLUSH`. Test
      `test_oricos_clock`.

### Sprint 5 — Guest Oric 1
- [ ] Lancement guest Oric 1 dans une fenêtre OricOS.
- [ ] Routage I/O guest (clavier, ULA guest).
- [ ] Démo : BASIC 1.0 fonctionnel dans une fenêtre OricOS.

---

## 8. Glossaire

Voir `/home/bmarty/oric2/CLAUDE.md` §8 et `/home/bmarty/oric2/docs/DAT.md` §7.

---

*v0.1 — 2026-05-08, initialisation.*
