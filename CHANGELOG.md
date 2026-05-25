# CHANGELOG - OricOS

All notable changes to the OricOS kernel project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased+gardes-overlap-mmap] - 2026-05-25

### Dette #4 — gardes d'overlap memory map bank 1 (pivot après investigation)

#### Context
L'objectif initial (migrer les 126 constantes absolues `= $01xxxx` vers un
`.segment`/`.res` linker-alloué) s'est révélé **contre-productif** : ces adresses
forment une ABI d'introspection white-box — les tests Phosphoric lisent l'état
interne du kernel via 205 références littérales dans 7 fichiers. Les relocaliser
casserait les tests et imposerait de recopier les adresses assignées par le
linker dans chaque test → on recrée la synchro manuelle, en pire.

#### Added
- **`kernel/kernel.s`** : 11 gardes `.assert … error` en fin de fichier. Adresses
  inchangées (ABI test préservée) mais **tout chevauchement devient une erreur de
  build** au lieu d'une corruption silencieuse (cf. overlap ICON_TABLE/TCB_BITMAP
  qui avait mordu en SP-3.k). Chaque garde encode « cette structure tient avant la
  variable suivante » via les tailles réelles (`WM_MAX`, `TCB_MAX*TCB_SIZE`,
  `KBD_RING_SIZE`, buffer secteur 512o). Validé négatif : `WM_MAX=20` fait
  échouer le build avec les messages d'overlap attendus. 563 tests verts.

## [Unreleased+revue-fine-OricOS] - 2026-05-25

### Réduction dette/bugs (analyse fine OricOS, revue senior)

#### Fixed
- **`kernel/modules/kbd.s` — `kernel_kbd_ring_pop` : race producteur/consommateur**
  (P1, régression du fix deadlock). Depuis le `cli` du handler COP, l'IRQ KBD2
  peut préempter un syscall et appeler `kbd_poll → ring_push` EN PLEIN POP. Le
  RMW partagé sur `KBD_RING_COUNT` (push `inc` / pop `dec`) perdait une mise à
  jour et `DP_KBD_TMP` était écrasé par le push → ring corrompu / mauvais
  keycode. Ajout d'une section critique `php; sei … plp` autour du pop (le
  producteur étant uniquement l'IRQ, le masquage rend le pop atomique). `plp`
  restaure le I de l'appelant (=0 en contexte COP → `WAI` de `sys_read_char`
  toujours fonctionnel).

#### Changed
- **`kernel/modules/wm.s` — discipline largeur M/X aux dispatch indirects** (P3).
  Ajout `.a8`/`.i8` en tête du bloc des handlers syscall. `.smart` (global) ne
  peut pas propager la largeur à travers `jsr (syscall_table,X)` ; l'assertion
  garantit que les `lda #imm` 8-bit des handlers (ex. `sys_invalid lda #$FF`)
  sont encodés conformément au `sep #$30` runtime du dispatcher. Prévient la
  classe de bug ca65 « tracking mode » déjà rencontrée en SP-3.h.

563 tests verts. Dette restante identifiée (non traitée ici, plus gros rayon) :
memory map bank 1 100% hardcodée (→ `.segment`/`.res`), réentrance ZP scratch
au context-switch + écart ADR-14 16-TCB vs scheduler 2-tâches (socle OS-2.g v2).

## [Unreleased+oricos.h-SSOT] - 2026-05-25

### oricos.h — source unique de vérité pour les numéros de syscalls (P2 revue)

#### Changed
- **`tools/oricos-sdk/include/oricos.h`** : les numéros de syscalls dans les
  templates asm ne sont plus des littéraux dupliqués (`"lda #1\n"`) mais
  stringifiés depuis les `#define SYS_*` via `_ORICOS_LDA_SYS(SYS_PRINT_CHAR)`
  → `"lda #" "0x01" "\n"`. Garde le bénéfice anti-LTO (LDA #imm, jamais hoisté
  en ZP) ET restaure la source unique de vérité : renuméroter un syscall dans
  le `#define` (ou ADR-17) propage automatiquement à l'asm. Vérifié : `a9 01`,
  `a9 03` présents, `a5 01` (forme ZP buggée) absent. 563 tests verts.

## [Unreleased+SYS_READ_CHAR-deadlock] - 2026-05-25

### Fix deadlock SYS_READ_CHAR (P1 revue) — IRQ démasquée pendant les syscalls

#### Fixed
- **`kernel/modules/handlers.s` — `kernel_cop_handler`** : `cli` ajouté en entrée
  du dispatcher COP. Le COP entre avec I=1 (hardware) ; un syscall bloquant
  (`SYS_READ_CHAR`) figeait alors **tout le noyau** car l'IRQ KBD2 ne pouvait
  plus remplir le ring → deadlock garanti en usage réel. Le `rti` final restaure
  le P (donc I) de l'appelant. Conforme ADR-03 (kernel jamais bloqué par une app).
  ⚠️ v1 : rend les syscalls interruptibles — sûr tant qu'une seule tâche émet des
  syscalls ; réentrance sur la ZP scratch kernel à revisiter en OS-2.g v2.
- **`kernel/modules/wm.s` — `sys_read_char`** : `WAI` entre deux tentatives de
  pop au lieu d'un busy-spin. Avec I=0 (cli du handler), `WAI` dort jusqu'à l'IRQ
  KBD2 qui remplit le ring, puis re-poll.
- **`kernel/modules/boot.s`** : suppression du hack de pré-injection clavier
  (`lda #'A'; jsr kernel_kbd_ring_push`) dans le chemin TC_HELLOC_FLAG. C'était
  un pansement masquant le deadlock ; la touche arrive maintenant par l'IRQ
  KBD2 réelle.

Validation : `test_oricos_helloc` ne pré-injecte plus ; il livre 'A' via le
device KBD2 quand l'app bloque (`cpu.waiting`), exerçant la chaîne complète
KBD2→IRQ→ring→read_char. 563 tests verts.

## [Unreleased+TC-poc-hello-c-hardening] - 2026-05-25

### TC-poc-hello-c — durcissement post-revue (P0 repro + fix racine DBR)

#### Fixed
- **Reproductibilité build (P0) — `apps/hello_c/Makefile`** : `-isystem` → `-I`
  pour le SDK. Le driver clang ajoute `mos-platform/oricos/include` avec une
  priorité supérieure à `-isystem`, donc le `oricos.h` plateforme (hors repo,
  non versionné) shadowait le SDK → build non reproductible. `-I` est cherché
  avant les includes plateforme → le SDK versionné devient autoritaire.
- **Reproductibilité build (P0) — `Makefile`** : ajout `KERNEL_DEPS =
  $(wildcard kernel/modules/*.s)` aux prérequis de `kernel.o`. Sans ça, éditer
  un module `.include`é ne déclenchait pas de rebuild → kernel obsolète testé
  silencieusement (un faux FAIL puis faux PASS observés en séance).
- **Fix racine DBR — `kernel/modules/console.s`** : le driver console écrit
  désormais dans l'écran bank 0 via **adressage long** (indépendant du DBR) :
  `kernel_print_char` utilise `STA [DP_PCPTR]` (bank byte $0E = 0) au lieu de
  `STA (DP_PCPTR)` DBR-relatif ; `kernel_scroll_up` utilise `f:` (long,X). Une
  app userland a DBR = son bank (≠ 0) ; l'ancien code écrivait l'écran dans le
  mauvais bank. Corrige `SYS_PRINT_CHAR` **et** `SYS_PRINT_STRING` (ce dernier
  était cassé pour DBR≠0 mais non testé — il passe par `kernel_print_char`).
- **`kernel/modules/wm.s` — `sys_print_char`** : suppression du
  `phb/plb` (DBR save/restore) devenu redondant grâce au fix racine console.

## [Unreleased+TC-poc-hello-c] - 2026-05-25

### TC-poc-hello-c — première app C llvm-mos sous OricOS

#### Fixed
- **`tools/oricos-sdk/include/oricos.h`** : numéros de syscalls en littéraux asm
  (`"lda #1\n"`) au lieu de contrainte `"i"` paramétrée. Avec `-flto`, la contrainte
  était hoistée en variable ZP par l'optimiseur, générant `LDA ZP` au lieu de `LDA #imm`.
  Même correction appliquée à `/home/bmarty/llvm-mos/mos-platform/oricos/include/oricos.h`
  (priorité sur le SDK local dans le build llvm-mos).
- **`kernel/modules/wm.s` — `sys_print_char`** : ajout sauvegarde/restaure DBR
  (`phb; lda #0; pha; plb ... plb`) avant d'appeler `kernel_print_char`. Les apps
  userland ont DBR = bank propre (ex. bank 4) ; `kernel_print_char` suppose DBR=0
  pour écrire dans le buffer texte $BB80 via `sta (DP_PCPTR)`.
- **`kernel/modules/fat.s` — `kernel_app_exec`** : boucle de copie améliorée v0.2
  (Y 16-bit via `rep #$10`, taille lue en 16-bit via `rep #$20`) pour bundles > 255 B.
  hello_c = 584 octets ($0248) ; l'ancienne boucle 8-bit ne copiait que 72 octets ($48).

#### Added
- **`kernel/modules/boot.s`** : bloc conditionnel `TC_HELLOC_FLAG` ($01EF10=$A5) :
  pré-injection touche 'A' dans ring kbd, DP_PTR ← `bundle_hello_c`, JSR `kernel_app_exec`.
- **`kernel/modules/console.s`** : `.export bundle_hello_c` — bundle hello_c embarqué
  via `.incbin "../apps/hello_c/build/hello.oos"`.
- **`Makefile`** : `APPS` et `APP_BUNDLES` étendus à `hello_c`.
- **`kernel/kernel.s`** : constante `TC_HELLOC_FLAG = $01EF10`.

## [Unreleased] - 2026-05-25

### TC-libc — libc minimale OricOS (liboricos.a) v1.0

#### Added
- **`tools/oricos-sdk/lib/liboricos.c`** : libc minimale
  - Sortie : `putchar`, `puts`
  - String : `strlen`, `memset`, `memcpy`, `strcpy`, `strcat`, `strcmp`
  - Format : `printf`, `sprintf`, `vprintf` (spécificateurs : `%s %d %u %c %x %%`)
  - Conversion : `itoa` (base 10 et 16)
- **`tools/oricos-sdk/lib/malloc.c`** : allocateur bump bank-local
  - `malloc(n)` → bump pointer depuis `__heap_start` (fin BSS) jusqu'à `$FFFF`
  - `free(p)` → no-op v1 (bump monotone)
  - `calloc(nmemb, size)`, `heap_available()`
- **`tools/oricos-sdk/include/liboricos.h`** : header public de la libc
- **`install.sh`** : mis à jour pour compiler et installer `liboricos.a`
- **`apps/test_libc/`** : app de validation (14 tests : printf/strlen/strcmp/strcpy/memset/malloc/calloc/sprintf/heap_available)
  - Compilée → `test_libc.oos` 9068B

### TC-llvmmos-target-oricos — Target llvm-mos `mos-oricos` v1.0

#### Added
- **`tools/oricos-sdk/`** : SDK userland C OricOS (target llvm-mos `mos-oricos`)
  - `lib/crt0.S` : startup 65C816 en sections llvm-mos (`.init.000` DBR:=PBR,
    `.init.200` zero-BSS, `.call_main` jsr main, `.after_main` SYS_EXIT+RTL)
  - `lib/link.ld` : linker script (code à $0200, imag-regs ZP à $89-$A8)
  - `include/oricos.h` : API publique 18 syscalls ADR-17 (inline asm COP #$AA)
  - `mos-oricos.cfg` : config clang (mcpu=mosw65816, -flto, chemins platform)
  - `install.sh` : script d'installation dans `$HOME/llvm-mos`
- **`apps/hello_c/`** : première app OricOS en C (TC-poc-hello-c phase 1)
  - `hello.c` : print_string + read_char + exit via `oricos.h`
  - `Makefile` : `make → build/hello.oos` (bundle ADR-08 prêt à exécuter)
- **Validation** : `clang --target=mos-oricos hello.c -lcrt0 -o hello.bin`
  produit un binaire 65C816 8-bit (M=1/X=1, ADR-05 v2) commençant à $0200
  avec la séquence PHK/PLB correcte. Bundle `.oos` = 600B.

### SP-3.R S5 — Split kernel.s en modules

#### Changed
- **`kernel/kernel.s`** transformé en orchestrateur pur (711 lignes) :
  constantes/ZP/I/O + 11 `.include "modules/X.s"`.
- **`kernel/modules/`** (nouveau répertoire) : 11 modules extraits.

| Module | Lignes | Contenu |
|--------|--------|---------|
| `boot.s` | 1149 | entry, scheduler, TCB |
| `fat.s` | 691 | FAT32 + SD + bundle + loader |
| `log.s` | 120 | log ring + panic + hex |
| `console.s` | 221 | print + scroll + banner |
| `kbd.s` | 118 | driver clavier KBD2 |
| `alloc.s` | 196 | bank allocator |
| `vram.s` | 135 | VRAM I/O |
| `gfx.s` | 267 | GPU blitter helpers |
| `tk.s` | 865 | toolkit + widgets + menu |
| `wm.s` | 2519 | WM + taskbar + icônes + curseur |
| `handlers.s` | 190 | NMI/COP/IRQ + CHARSET |

Build identique : 57 344 octets. 563 tests verts.

### SP-3.R S6 — Dirty rect resize

#### Changed
- **`_wm_do_resize`** : remplace `kernel_wm_redraw` (clear 393 Ko) par
  `kernel_wm_redraw_drag` — `_wm_capture_focused_rect` en tête de la
  fonction avait déjà peuplé `WM_DRAG_OLD_*`, le dirty rect incrémental
  suffit.

### SP-3 bugfix — Session 2026-05-25 : WM robustesse complète

#### Fixed
- **Z-order fenêtres** : `_wm_draw_windows` refactorisé en deux passes
  (non-focus d'abord, focus en dernier). Extrait `_wm_draw_one`. PHY/PLY
  ajouté autour de l'appel dans la boucle (Y clobbé par GPU).
- **focus avant maximize/minimize** : `wm_step_chrome_max/min` appellent
  `kernel_wm_set_focus` avant l'action → Z-order correct au redraw.
- **Trous après close (WM_COUNT vs WM_MAX)** : `_wm_draw_windows`,
  `kernel_wm_hit_test`, `kernel_taskbar_draw` passent de `cmp WM_COUNT`
  à `cmp #WM_MAX`. `kernel_wm_add` cherche le premier slot libre au lieu
  d'utiliser `WM_COUNT` comme id.
- **Taskbar compacte** : `kernel_taskbar_draw` n'avance `TB_BTN_X` que
  pour les slots UTILISÉS. `kernel_taskbar_hit` reproduit le même calcul
  d'itération (suppression de la division fixe par TB_BTN_STRIDE).
- **Maximize + marge 20 px** : `w_max = 1004` (au lieu de 1024) réserve
  le bord droit pour les boutons chrome visibles et la future taskbar verticale.
- **WM_STATE_HIDDEN_MAXED ($03)** : minimiser une fenêtre maximisée mémorise
  l'état. La taskbar restaure à MAXED (dims + WM_SAVED_RECTS intacts) → □
  fonctionne correctement après restore.

### SP-3 bugfix — Fantômes widget/titre lors du resize + icônes drag

#### Fixed
- **Fantôme widget/titre au resize** : `_wm_do_resize` utilisait `kernel_wm_redraw_drag`
  (redraw incrémental), qui n'effaçait pas les pixels TEXT16 de l'ancien titre/boutons
  (TEXT16 = pixels lit uniquement, pas de fond). Corrigé : `_wm_do_resize` appelle
  désormais `kernel_wm_redraw` (full redraw avec clear desktop).
- **Corruption `WM_DP_TMP` dans `_wm_draw_widgets_for_slot`** : `kernel_wm_offset`
  (appelé pour calculer le décalage en table) écrasait `WM_DP_TMP` (2×slot), corrompant
  le test de parent au prochain tour de boucle pour les slots ≥ 1. Corrigé : le slot
  cible est désormais sauvé dans `WIN_SLOT` (non touché par `kernel_wm_offset`) et
  `WIN_SLOT` est utilisé pour le test et l'appel `kernel_wm_offset`.
- **Icônes disparaissant lors du drag** : `kernel_wm_redraw_drag` (redraw incrémental)
  n'appelait pas `kernel_icon_draw_all`. Corrigé : appel ajouté avant `_wm_draw_windows`.

### Sprint 3.k — Icônes desktop (SP-3.k)

#### Added
- **`ICON_TABLE`** (`$015ADA`, 4 × 16B) : table des icônes desktop. Entrée :
  flags, color, x(2B), y(2B), cb_lo/hi (callback), label (8B).
- **`ICON_COUNT`** (`$015B1A`) + **`ICON_SELECTED`** (`$015B1B`) : compteur et
  sélection courante (initialisée à `$FF`).
- **`kernel_icon_add`** : ajoute une icône (args ZP : `WM_ARG_X/Y`, `GFX_COLOR`,
  `DP_PCPTR` label, `WM_ARG_DX` callback). Upload le label en SDRAM
  `$011200 + id×$10`. Retourne l'id (0..3) ou `$FF` si plein.
- **`kernel_icon_draw_all`** : dessine toutes les icônes via `FILL_RECT16`
  (32×32, couleur icône ou lightcyan si sélectionnée) + `TEXT16` (label en
  dessous, blanc). Appelée automatiquement dans `kernel_wm_redraw` après le
  clear desktop, avant les fenêtres.
- **`_icon_hit`** : hit-test des icônes sous `(MOUSE_X, MOUSE_Y)`. Retourne
  l'id (0..3) ou `$FF`. Appelé dans `kernel_wm_mouse_step` quand aucune
  fenêtre n'est touchée.
- **Callback icône** : clic sur icône → `ICON_SELECTED = id` + appel callback
  via `jsr (WM_DP_TMP,X)` (X=0, JSR indirect).
- **Démo boot** : 2 icônes créées au démarrage : "Files" (cyan, x=20,y=20) et
  "Prefs" (yellow, x=20,y=80). Sentinelles `ICON_K_TEST_RES` ($015B1C-$015B1F).
- **3 tests** : `test_wm_icons_init`, `test_wm_icon_hit`, `test_wm_icon_click`.
  563 tests verts.

### Sprint 3.j — Dialog modal (SP-3.j)

#### Added
- **`WM_MODAL`** (`$015AD5`, 1B) : slot de la fenêtre modale active (`$FF` = aucune).
  Initialisé à `$FF` dans `kernel_wm_init`.
- **`kernel_wm_set_modal(slot)`** : déclare une fenêtre comme modale. Bloque les
  clics sur toutes les autres fenêtres tant qu'elle est active.
- **`kernel_wm_clear_modal()`** : libère le modal.
- **Auto-clear dans `kernel_wm_close`** : si la fenêtre fermée est la fenêtre modale,
  `WM_MODAL` est automatiquement remis à `$FF`.
- **Comportement dans `wm_step_normal_hit`** : si `WM_MODAL != $FF` et clic hors
  du slot modal → `wm_step_modal_block` (désarme drag/resize, curseur léger, ignore).
  Les boutons chrome (×/□/_) de n'importe quelle fenêtre restent actifs.
- 3 tests : `test_wm_modal_init`, `test_wm_modal_block`, `test_wm_modal_close_clears`.
  560 tests verts.

### Sprint 3.i — Resize des fenêtres par les bords (SP-3.i)

#### Added
- **`_wm_resize_hit`** : hit-test bord droit / bord bas de la fenêtre focus
  (`RESIZE_MARGIN = 6 px`). Retourne 0 (rien), 1 (droit), 2 (bas), 3 (coin).
  Désactivé sur fenêtre maximisée.
- **`_wm_do_resize`** : applique `MOUSE_DX/DY` à `w` / `h` selon l'arête hit.
  Clamp : `w >= RESIZE_MIN_W = 60`, `h >= RESIZE_MIN_H = 40`. Redraw incrémental
  via `kernel_wm_redraw_drag`.
- **`WM_RESIZE_ARMED`** (`$015ACE`, 1B) et **`WM_RESIZE_EDGE`** (`$015ACF`, 1B) :
  nouveaux flags armement/arête, initialisés à 0 dans `kernel_wm_init`.
- **Intégration `kernel_wm_mouse_step`** : nouveau clic → `_wm_resize_hit` avant
  drag, si bord → arme resize ; drag = branche vers `_wm_do_resize` si armé.
- **Désarmement** dans le chemin "bouton relâché" (en même temps que `WM_DRAG_ARMED`).
- **3 tests** `test_wm_resize_init`, `test_wm_resize_right_edge`,
  `test_wm_resize_bottom_edge` dans `test_oricos_boot.c`. 557 tests verts.

### Sprint 3.h — Maximize/minimize fenêtres (SP-3.h)

#### Added
- **`kernel_wm_maximize`** : bascule une fenêtre entre état normal et maximisé.
  Dimensions maximisées : x=0, y=14 (`MENU_BAR_H`), w=1024, h=741 (`TB_Y_SEP-MENU_BAR_H`).
  Sauvegarde les coords originales dans `WM_SAVED_RECTS` (`$015AA9`, 4×8B, entrées slot×8)
  via `STA f:WM_SAVED_RECTS,X` (opcode `$9F` = long,X). `WM_CRH_TMP` ($25-$26) sert de ZP
  tampon pour le slot*10 WM_TABLE pendant le calcul avec X=slot*8.
- **`kernel_wm_minimize`** : cache une fenêtre (clear `WM_F_VISIBLE`, state = `WM_STATE_HIDDEN`).
  Le focus est redistribué si nécessaire.
- **Restore depuis taskbar** : `kernel_taskbar_hit` restaure une fenêtre `WM_STATE_HIDDEN`
  (set `WM_F_VISIBLE` + `WM_STATE_NORMAL`) avant de donner le focus.
- **Boutons □ et _ dessinés dans la titlebar** : `_wm_draw_title_and_close` appelle
  2 `kernel_gfx_text16` supplémentaires pour les boutons maximize ("O") et minimize ("_").
  Strings uploadées en SDRAM au boot (`WM_MAX_STR=$011090`, `WM_MIN_STR=$0110A0`).
- **`_wm_chrome_hit`** : hit-test 3 zones chrome (retourne 0/1/2/3 = none/×/□/_).
  Zones (12px chacune, de droite à gauche) : × `[right-12..right-1]`,
  □ `[right-24..right-13]`, _ `[right-36..right-25]`.
- **`_wm_close_btn_hit`** : conservé comme wrapper de `_wm_chrome_hit` (retour==1).
- **Drag désactivé sur fenêtre maximisée** : `kernel_wm_move_focused` vérifie
  `WM_STATES[focus]` avant de déplacer.
- Nouvelles constantes : `WM_STATE_NORMAL=$00`, `WM_STATE_MAXED=$01`, `WM_STATE_HIDDEN=$02`,
  `WM_STATES=$015AA5` (4×1B), `WM_SAVED_RECTS=$015AA9` (4×8B), `WM_H_TEST_RES=$015AC9`,
  `WM_MAX_STR=$011090`, `WM_MIN_STR=$0110A0`, `BTN_MAX_OFFSET=22`, `BTN_MIN_OFFSET=34`,
  `WM_CRH_TMP=$25` (6B).

#### Fixed
- **Bug critique `_wm_chrome_hit`** : `sbc #12` dans `_crh_test_max` et `_crh_test_min`
  assemblé en mode 8-bit par ca65 (tracking mode perdu après `sep #$20` d'une branche
  adjacente). L'opcode 2B `E9 0C` au lieu de 3B `E9 0C 00` en mode 16-bit rendait le
  `sbc` incorrect et laissait l'octet suivant ($85/$27) être interprété comme opérande.
  Conséquence : `WM_DP_TMP+1` ($21), `WM_DP_TMP+2` ($22 = WM_ARG_TITLE_LO), $23/$24
  (WIN_SLOT) corrompus → 4 régressions silencieuses sur SP-3.e/f/g (drag, focus, widgets).
  Fix : ajout de `rep #$20` explicite au début de chaque label cible. `WM_CRH_TMP` ($25)
  utilisé à la place de `WM_DP_TMP+n` pour éviter la zone de collision.

### Sprint 3.g — Taskbar fixe bas desktop XVGA

#### Added
- **`kernel_taskbar_draw`** : dessine la taskbar (fond darkgray `(0,755,1024,13)`,
  séparateur blanc `y=755`, boutons par fenêtre `WM_F_USED`). `btn_x = 4 + i×124`,
  `w=120`, `h=10`, `y=757`. Couleur bouton : lightblue ($09) si focus, darkgray ($08)
  sinon. Texte titre lu depuis SDRAM `$012000+slot×$100` si `WM_TITLES[slot]=$01`,
  sinon fallback `"WinN\0"` (généré en bank 1 `TB_WIN_SCRATCH=$015AA0`, uploadé en
  SDRAM `TB_WIN_SDRAM=$011100`). `TB_BTN_X` avance de `TB_BTN_STRIDE=124` par slot.
- **`kernel_taskbar_hit`** : reçoit `MOUSE_BTN & LEFT` + `MOUSE_Y ≥ 755`. Calcule
  `slot = (MOUSE_X - 4) / 124` par soustraction répétée (≤ 4 itérations).
  Vérifie `slot < WM_COUNT` et `WM_F_USED`. Appelle `kernel_wm_set_focus(slot)`
  + `kernel_wm_redraw` + `kernel_wm_draw_cursor`. Retourne A=1 si consommé.
- **Intégration render** : `kernel_menu_draw` se termine par `jmp kernel_taskbar_draw`
  (deux points de sortie remplacés : menu fermé + après dropdown). Taskbar toujours
  au-dessus du dropdown dans l'ordre de rendu.
- **Intégration event loop** : `wm_step_not_drag` appelle `kernel_taskbar_hit` en
  priorité absolue avant le menu. Si consommé, retour immédiat.
- **Constantes SP-3.g** : `TB_I=$015A9C`, `TB_BTN_X=$015A9E`, `TB_WIN_SCRATCH=$015AA0`,
  `TB_WIN_SDRAM=$011100`, `TB_Y_SEP=755`, `TB_H=13`, `TB_BTN_Y=757`, `TB_BTN_H=10`,
  `TB_BTN_W=120`, `TB_BTN_SP=4`, `TB_BTN_STRIDE=124`.

---

### Sprint 3.f — Chrome de fenêtre : titre + bouton fermer

#### Added
- **SP-3.f v0.1 — Titre dans la titlebar** : `kernel_wm_add` reçoit deux
  nouvelles ZP args (`WM_ARG_TITLE_LO/HI = $22/$23`) pointant vers la
  chaîne de titre en bank 1. Le titre est uploadé en SDRAM via
  `kernel_vram_write_block` à `$012000 + slot×$100`. Le flag
  `WM_TITLES[slot]` (table `$015986`) est positionné à `$01`.
  `_wm_draw_title_and_close` dessine le titre (couleur blanche, `TEXT16`)
  dans la titlebar à `win_x+4, win_y+3`.
- **SP-3.f v0.2 — Bouton fermer** : `_wm_draw_title_and_close` dessine
  le texte "X" (lightred, `TEXT16`) en `win_x+win_w-10, win_y+3`.
  La chaîne "X\0" (`WM_CLOSE_STR = $011080`) est uploadée en SDRAM au
  boot. `_wm_close_btn_hit` : hit-test sur la zone
  `[win_x+w-12..win_x+w-1, win_y..win_y+13]`. Retour $01 si touché.
  `kernel_wm_close` : efface le slot (WM_F_USED=0), reset `WM_TITLES`,
  décrémente `WM_COUNT`, cherche un nouveau focus. Intégré dans
  `wm_step_hit` : le close button est prioritaire sur le focus/drag.
- Fenêtres de démonstration baptisées **"OricOS"** (slot 0) et
  **"Editor"** (slot 1).

#### Fixed
- **GFX_STR_HI** dans `_wm_dtc_close` : `$00` → `$01` (bank byte correct
  pour `WM_CLOSE_STR = $01:1080` ; le GPU lisait auparavant `$001080`).

### Added (OS-2.f.v2 clos 2026-05-24)
- **OS-2.f.v2 clos** : table dispatch syscall v0.2 déjà en production dans
  `kernel.s`. Tests C côté Phosphoric ajoutés :
  `test_syscall_dispatch_invalid`, `test_syscall_yield`, `test_syscall_table_size`.
  64 entrées × 2B à `$01:5750`, 18 syscalls câblés + 45 × `sys_invalid`.

### Added
- **CI GitHub Actions** (`.github/workflows/ci.yml`) : build du kernel (cc65) à
  chaque push/PR. Phase 1 assainissement.

### Sprint 3.d v0.6 — Barre de menu multi (table-driven)

#### Changed
- **`kernel_menu_draw` / `kernel_menu_handle_click`** réécrits **table-driven** :
  itèrent `menu_defs` (table statique bank1, N=2 menus × 16 o, lue via pointeur
  24-bit pour éviter DBR). `MENU_OPEN` devient l'**index** du menu ouvert (`$FF`=fermé).
- 2 menus : "System" (About/Clear) + "View" (Tile/Hide), callbacks distincts.
- `_menu_setbase` : DP_PCPTR = `menu_defs + MENU_I*16`, bank $01.


### Sprint 3.d v0.5 — Barre de menu déroulant

#### Added
- **`kernel_menu_draw`** : barre de menu en haut (darkgray, full width) + titre
  "System" ; si ouvert, dropdown (fond lightgray + cadre + items "About"/"Clear").
  Dessinée en dernier dans le redraw (par-dessus fenêtres + widgets).
- **`kernel_menu_handle_click`** : ouvre/ferme le menu, hit-test des items →
  invoque leur callback. Retourne « consommé » pour intercepter le clic avant
  le window manager.
- `kernel_wm_mouse_step` : le menu intercepte le nouveau clic en priorité.
  Callbacks démo `menu_about_cb`/`menu_clear_cb`. `MENU_OPEN` reset par wm_init.


### Sprint 3.d v0.4 — Callbacks de bouton (action au clic)

#### Added
- Widget bouton : champ **callback** (offset bank1 à entry+14/+15), passé via
  `WG_CB` à `kernel_wm_add_widget`.
- **`_wm_invoke_active_cb`** : après le hit-test, si un bouton actif a un
  callback non nul, l'invoque via `jsr (vecteur,X)` (opcode `$FC`, exécuté en
  bank 1). Appelé par `kernel_wm_mouse_step`.
- Démo : le bouton "OK" a un callback `demo_ok_cb` qui incrémente `CB_FLAG`.


### Sprint 3.d v0.3 — Bouton cliquable (retour visuel pressé)

#### Added
- **`_wm_widget_hit`** : hit-test des widgets BOUTON sous (MOUSE_X,MOUSE_Y) à
  leur position absolue (fenêtre + offset) → `WIDGET_ACTIVE` (index ou $FF).
- **`kernel_wm_mouse_step`** (clic sur fenêtre) appelle `_wm_widget_hit` après
  le focus → le bouton sous le curseur devient actif.
- **`kernel_tk_button`** / `_wm_draw_all_widgets` : le bouton actif
  (`WIDGET_ACTIVE`) est dessiné **pressé** (face darkgray `$08` vs lightgray
  `$07`), via `TK_BTN_PRESSED`. `WIDGET_ACTIVE` reset par `kernel_wm_init`.


### Sprint 3.d v0.2 — Widgets managés (attachés aux fenêtres)

#### Added
- **Table de widgets** (8 × 16 o, `$015A00`) : chaque widget a un parent (fenêtre),
  type (label/button), rect relatif, couleur, chaîne (bank 1).
- **`kernel_wm_add_widget`** : enregistre un widget attaché à une fenêtre.
- **`_wm_draw_all_widgets`** : dessine les widgets à leur position absolue
  (fenêtre parente + offset relatif), appelé **après** `_wm_draw_windows` (hook
  dans `kernel_wm_redraw` ET `kernel_wm_redraw_drag`).
- Démo boot : label "OricOS" + bouton "OK" attachés à la fenêtre 0.

#### Changed
- Les widgets **persistent** aux redraws et **suivent leur fenêtre au drag**
  (vs démo flottante one-shot v0.1 qui disparaissait). `kernel_wm_init` reset
  `WIDGET_COUNT`.


### Sprint 3.d v0.1 — Toolkit minimal (label / frame / button)

#### Added
- **`kernel_gfx_text16`** : GPU TEXT coords 16-bit (ADR-21, opcode `$07`) —
  packe `ARG4 = color<<20 | y<<10 | x` (x/y ≤1023). Permet du texte n'importe
  où sur XVGA (le TEXT 8-bit limitait à x/y ≤255).
- **`kernel_tk_font_init`** : upload la fonte ASCII (charset, 1024 o) en SDRAM
  `$010000` au boot (hors zone self-test VRAM).
- **`kernel_tk_label`** : texte à (x,y) 16-bit, couleur, chaîne bank 1 (copiée en
  SDRAM scratch `$011000` via `_tk_upload_str`).
- **`kernel_tk_frame`** : cadre 2px (4 bords via FILL_RECT16).
- **`kernel_tk_button`** : face lightgray + cadre blanc + label noir.
- Démo boot : label "OricOS Toolkit" + bouton "OK" à x=400 (prouve TEXT16).

#### Note
- Fonte/scratch en SDRAM `$010000`/`$011000` (et non `$002000`/`$003000` qui
  collisionnaient avec le self-test VRAM read_block/DMA du boot).


### SP-3.e v0.8 — Couleur titlebar selon focus

#### Added
- **Couleur de titlebar selon le focus** dans `_wm_draw_windows` : la fenêtre
  ayant le focus (`WM_FOCUS`) reçoit `WIN_TITLE_FOCUS` (lightblue 9), les autres
  `WIN_TITLE_NORMAL` (darkgray 8). Couleur calculée par fenêtre (`WM_TITLE_COL`)
  pendant la boucle de dessin.

#### Note
- **Aucun nouveau redraw** : le changement de focus déclenche déjà
  `kernel_wm_redraw` (clic) et le drag `kernel_wm_redraw_drag`, tous deux via
  `_wm_draw_windows` → les titlebars sont repeintes avec la bonne couleur au
  redraw déjà en place. C'est pourquoi le **multi-dirty-rect est inutile** : un
  changement de focus fait un full-redraw qui repeint correctement les 2 titlebars.

### SP-3.e v0.7 — Drag incrémental (dirty rect, plus de full-clear)

#### Added
- **`kernel_wm_redraw_drag`** : efface uniquement l'ancien rectangle de la
  fenêtre (`WM_DRAG_OLD_*`) en bleu via FILL_RECT16, puis redessine les fenêtres
  (`_wm_draw_windows` factorisé) — au lieu du `kernel_gfx_clear` plein écran 393 Ko.
- **`_wm_capture_focused_rect`** : capture le rect de la fenêtre focus avant
  déplacement (dirty rect à effacer).

#### Changed
- **`kernel_wm_mouse_step`** (drag) : capture rect ancien → restaure le curseur
  (efface) → déplace → `kernel_wm_redraw_drag` → `kernel_wm_draw_cursor`. Le drag
  ne fait plus de clear plein écran → fluide.
- `kernel_wm_redraw` factorisé : clear plein + `_wm_draw_windows` (partagé).

#### Note
- Coût drag : efface ~ rect fenêtre (80×60 ≈ 2.4 Ko) + redessine N fenêtres, vs
  393 Ko avant. Côté Phosphoric : test `wm_drag_no_ghost` (pas de fantôme).

### Licence — EUPL-1.2 (2026-05-24)

- OricOS passe sous **EUPL-1.2** © 2026 Bénédicte Marty (cohérent workspace +
  Phosphoric). Fichier `LICENSE` ajouté, README mis à jour. En-têtes
  **SPDX-License-Identifier: EUPL-1.2** ajoutés au kernel + apps.


### SP-3.e v0.6 — Backing-store curseur (pas de full-redraw par motion)

#### Added
- **`kernel_wm_cursor_save`/`restore`/`blit`** + `_cursor_calc_addr`/`clamp`/
  `draw` : sauvegarde/restauration de la zone 8×8 (4 octets × 8 lignes) sous le
  curseur via VRAM I/O (`kernel_vram_read_block`/`write_block`). État en bank 1
  `$5950` (CURSOR_SAVE 32B, OLD_X/Y, VALID, CUR_DRAW_X/Y).
- Adresse SDRAM calculée `$100000 + y*512 + x>>1` (BPL XVGA 512, 4bpp).

#### Changed
- **`kernel_wm_mouse_step`** : sur **motion seule** → `kernel_wm_cursor_blit`
  (restaure ancien fond, sauve nouveau, dessine) **sans** full-redraw du desktop.
  Le full-redraw (`kernel_wm_redraw` + `kernel_wm_draw_cursor`) n'est conservé que
  sur **clic-focus** et **drag** (le desktop change réellement).
- `kernel_wm_draw_cursor` : invalide l'ancien backing (desktop repeint), capture
  le nouveau fond, dessine.

#### Note
- Gain : un mouvement de souris ne redessine plus 393 Ko mais ~64 octets de
  VRAM I/O → curseur fluide. Le drag reste un full-redraw (backing-store fenêtre
  reporté). Côté Phosphoric : fix du masque reg VRAM I/O (`& 0x0F` → `& 0x3F`)
  qui empêchait les ports VRAM de fonctionner. Test `cursor_backing_store`.

### SP-3.e v0.1 — Driver souris + window manager (ADR-24)

#### Added
- `kernel.s` — **driver souris MOU2** (`$0360-$036F`, ADR-24) :
  - `kernel_mouse_init` (reset état ; v0.1 **polled**, IRQ MOU2 reportée v0.2
    car le dispatch IRQ ne gère pas encore MOU2).
  - `kernel_mouse_read` : MOU2 → `MOUSE_X/Y/BTN` (lecture 16-bit directe des
    registres X_LO/X_HI consécutifs), clear event.
- **Window manager** (`kernel_wm_*`) : table 4 fenêtres en bank 1 `$5900`
  (flags/id/x/y/w/h, 16-bit), `kernel_wm_init`/`add`/`hit_test` (topmost)/
  `set_focus`/`move_focused`. Coords 16-bit (espace XVGA).
- **`kernel_wm_mouse_step`** : 1 itération event loop — clic gauche → focus
  fenêtre sous le curseur ; bouton tenu + mouvement → drag (delta MOU2 DX/DY).
- Self-test boot : 2 fenêtres, hit-test, focus, move, lecture souris →
  sentinelle `WM_TEST_RES` (`$015940`).

### SP-3.e v0.2 — Event loop IRQ-driven (ADR-24)

#### Changed
- **`kernel_irq_handler`** : traite l'**event souris MOU2** en tête (lit
  `MOU2_STATUS` ; si event → `kernel_mouse_read` + `kernel_wm_mouse_step`),
  puis **gate le scheduler sur T1 réellement présent** (`VIA_IFR` bit6) —
  une IRQ souris/clavier seule ne compte plus un faux tick.
- **`kernel_mouse_init`/`read`** activent l'IRQ MOU2 (`MOU2_CT_IRQ_EN`). Fin
  du polling v0.1 : la souris est event-driven.

### SP-3.e v0.3 — Coords GPU 16-bit + redraw multi-fenêtre

#### Added
- **`kernel_gfx_fill_rect16`** : FILL_RECT16 GPU (opcode $06, ADR-21 v0.2) avec
  packing 12-bit des coords 16-bit (fenêtres plein écran XVGA, hors limite 8-bit).
- **`kernel_wm_redraw`** : efface le desktop (clear bleu) + dessine toutes les
  fenêtres de la table (corps + titlebar) via FILL_RECT16, peinture back-to-front.
  Framebuffer XVGA à SDRAM $100000. Appelé au boot + sur clic/drag (`wm_mouse_step`).
- `GPU_OP_FILL_RECT16` = $06.

#### Note
- Desktop XVGA visible : fenêtres aux positions 16-bit de la table.

### SP-3.e v0.4 — Main loop persistant + drag fenêtre live

#### Added
- **Mode persistant** : le scheduler ne STP plus au tick 10 si `NO_STP_FLAG`
  (`$01EF00`) = magic `$A5` (posé par Phosphoric `--kernel`). Le kernel tourne
  indéfiniment → GUI interactive. Les tests (flag non posé) gardent le STP.
- **`MOUSE_DX/DY`** : `kernel_mouse_read` lit+clear `MOU2_DX/DY` à chaque IRQ →
  delta **par événement** (plus d'accumulation). `wm_mouse_step` drague la
  fenêtre focus de ce delta → la fenêtre suit la souris.

#### Note
- Le drag live est fonctionnel : souris IRQ → `wm_mouse_step` (clic→focus,
  drag→move + `wm_redraw`) → fenêtre déplacée visible (`--kernel --xvga`).

### SP-3.e v0.5 — Curseur dessiné par l'OS

#### Added
- **`kernel_wm_draw_cursor`** : dessine un curseur 6×8 blanc à (`MOUSE_X`,`MOUSE_Y`)
  via FILL_RECT16, par-dessus le desktop. Curseur initial dessiné au boot.
- **`kernel_wm_mouse_step`** redessine desktop + curseur sur **tout** événement
  souris (y compris simple mouvement) → le curseur suit la souris.

#### Fixed
- **Drag fenêtre borné** : `WM_DRAG_ARMED` — le drag n'est armé que si le clic a
  atterri **sur** une fenêtre (hit-test). Avant, un clic sur le vide + glissé
  déplaçait quand même la fenêtre focus. Désarmé au relâchement.

#### Note
- Côté Phosphoric : relative-mode SDL (pointeur capturé/confiné, curseur OS hôte
  masqué) en mode `--xvga` ; bascule capture via **LCtrl+RShift**. Fix : la
  capture est (ré)activée après le resize XVGA (sinon annulée).
- v0.6 reporté : backing-store DMA + redraw incrémental (dirty rects) au lieu du
  full-clear par événement (le curseur force un redraw complet à chaque mouvement).

### OS-perf — Copie charset via MVN (block move)

#### Changed
- **`kernel_install_charset`** : la copie fonte `$015800 → $00B400` (1024 octets)
  passe d'une boucle octet-par-octet (~18K cycles) à l'instruction **MVN**
  (block move 65C816, ~2K cycles). Boot STP de ~153K → ~143K cycles.
  Encodage explicite `.byte $54, dst, src` (ordre machine dest_bank, src_bank).

#### Note
- `rep #$30` / **`sep #$30`** (pas `php`/`plp`) pour encadrer le mode 16-bit :
  `plp` est invisible au tracking `.smart` de ca65 → mal-dimensionnement des
  immédiats suivants. `sep #$30` explicite garde `.smart` cohérent.

### OS-2.i.v2 — Modèle d'erreur kernel : log ring buffer + codes nommés

#### Added
- `kernel.s` :
  - **Codes d'erreur nommés** : `ERR_NONE`, `ERR_BANK_EXHAUSTED`,
    `ERR_BAD_SYSCALL`, `ERR_BUNDLE_INVALID`. Niveaux `LOG_INFO/WARN/ERROR/PANIC`.
  - **`kernel_log_write`** (A=code, X=level) : ring buffer circulaire 8 entrées
    × 2 octets (level, code) en bank 1 `$54E0` ; écrase la plus ancienne si plein.
  - **`kernel_log_init`** : vide le ring (appelé tôt au boot).
  - **Points de journalisation câblés** : `kernel_panic` (LOG_PANIC),
    `cop_invalid` (syscall ≥ 64 → WARN/ERR_BAD_SYSCALL), `alloc_none`
    (pool épuisé → ERROR/ERR_BANK_EXHAUSTED).
  - Self-test boot : COP invalide ($50) → 1 entrée vérifiée → `LOG_TEST_RES`.
  - `DP_LOG_TMP` ($13) scratch.

#### Note
- `SYS_PANIC` ($0A) journalise désormais via `kernel_panic`.
- Log inspectable post-mortem (ring en bank 1). Persistance disque reportée.

### OS-2.e.2 — Console : CR (\r) + scroll up

#### Added
- `kernel.s` :
  - **`kernel_print_char`** gère désormais **CR (`\r`, $0D)** : retour en début
    de ligne courante (`CURSOR_ADDR -= CURSOR_X`, `CURSOR_X = 0`), sans écriture.
  - **`kernel_scroll_up`** : scroll écran d'une ligne (lignes 1..27 → 0..26,
    dernière ligne remplie d'espaces, attribut INK 7 restauré en `$BB80`).
  - `kernel_print_char` : dépassement bas d'écran → `kernel_scroll_up` (au lieu
    du clamp v0.1) ; le curseur reste sur la dernière ligne (col 0).
  - Self-tests boot (avant `clear_screen`) : scroll + CR, résultats en
    `SCROLL_TEST_RES` (`$015477`).

#### Note
- Modèle console à attribut unique : la cellule ligne0/col0 (`$BB80`) reste
  réservée à l'INK ; le caractère ligne1/col0 est perdu au scroll (artefact mineur).
- Reporté : attribut couleur par ligne, INKs multiples simultanés.

### OS-2.d — Driver clavier Oric 2 (KBD2 IRQ-driven, ADR-22)

#### Added
- `kernel.s` :
  - **Driver clavier paravirtualisé** : remplace le scan matriciel Oric 1 par
    une lecture IRQ-driven du contrôleur KBD2 (`$0350-$035F`, ADR-22).
  - `kernel_kbd_init` : vide le ring + active l'IRQ KBD2 (`KBD2_CTRL`).
  - `kernel_kbd_poll` : draine la FIFO KBD2 → ring buffer (appelé par l'IRQ
    handler à chaque tick + par la démo boot).
  - `kernel_kbd_ring_push` / `kernel_kbd_ring_pop` : ring buffer 16 keycodes
    en bank 1 `$5860` (ADR-16), head/tail/count, wrap puissance de 2.
  - **`SYS_GET_KEY`** ($06, non-bloquant) et **`SYS_READ_CHAR`** ($03,
    bloquant spin-poll) câblés sur le ring (étaient des stubs).
  - Démo boot OS-2.d : drain + SYS_GET_KEY → sentinelle `KBD_GETKEY_RES`.
  - Constantes `KBD2_*`, `KBD_RING*`, `DP_KBD_TMP`.

#### Removed
- `kernel_kbd_scan` (scan matriciel VIA/PSG) + init DDR/PSG de `kernel_kbd_init` :
  obsolètes avec le contrôleur KBD2 (la keymap est faite côté contrôleur, ADR-22).

#### Note
- L'IRQ handler appelle désormais `kernel_kbd_poll` au lieu de `kernel_kbd_scan`.
- Blocage vrai de `SYS_READ_CHAR` (task BLOCKED + wake) reporté à OS-2.g (TCB states).

### OS-2.f.v2 — COP handler v0.2 : table de dispatch 18 syscalls (ADR-13/17)

#### Added
- `kernel.cfg` : segment `SYSCALL_TABLE` à `$01:5750` (bank 1).
- `kernel.s` :
  - `kernel_cop_handler` v0.2 : sauve X (arg1) en `DP_SYS_ARG_X` (`$11`),
    valide `num < 64`, dispatch via `jsr (syscall_table,x)` (opcode `$FC`).
    Erreur `A=$FF` si num hors table (sentinelle ADR-17).
  - `syscall_table` : 64 entrées × 2 octets, 18 syscalls v1 ($01-$12) +
    slots réservés pointant vers `sys_invalid`.
  - 19 handlers `sys_*` : print_char/string, read_char/get_key (stubs
    clavier OS-2.d), exit, yield, fat_open/read/close, panic, alloc/free_bank,
    gfx_clear/fill_rect/blit/line/text, sleep_ms (stub).
  - `DP_SYS_ARG_X = $11` : sauvegarde de l'arg X avant écrasement par l'index.

#### Note
- Dépend de l'opcode 65C816 `$FC` (`jsr (a,x)`) — implémenté côté Phosphoric
  golden model en v1.22.20-alpha. Sans lui, le dispatch était un no-op silencieux.

## [Unreleased] - 2026-05-09

### Phase 1 PH-cleanup-zombie — Retrait kernel_hires2_* legacy

#### Removed
- `kernel.s` :
  - `kernel_hires2_clear` (~62 lignes) + `pattern_table` (8 × 3 octets).
  - `kernel_fill_rect_aligned` (~134 lignes).
  - 14 constantes ZP `HIRES2_*` (BANK, FB_SIZE, BPL, GX_START/COUNT,
    Y_START/COUNT, RECT_COL, PAT_PTR, FB_PTR, PB0/1/2).
  - Appels boot `jsr kernel_hires2_clear` (color blue=4) et
    `jsr kernel_fill_rect_aligned` (red rect 80×80 centre).

#### Justification
- ADR-19 v2 (VRAM SDRAM unifiée) a rendu bank `$80` (ex-VRAM live)
  invisible côté compositor. `kernel_hires2_*` écrivait dans le vide.
- Rendu desktop XVGA = **GPU blitter (ADR-21)** via `kernel_gfx_*`
  (Sprint GPU-3 v0.3) exclusivement.

#### Validation
- Build `make` → `kernel.bin` 57344 bytes.
- Tests Phosphoric : 540 OK (-1, suppression `test_oricos_hires2`).

---

## [Unreleased] - 2026-05-09

### Phase 0 programme état-de-l'art — décisions architecture OricOS

#### Ratified
- **ADR-16** Driver model OricOS : hybride event-driven + sync, sans struct ops v1.
  - Classe 1 IRQ-driven event queue : clavier (VIA T1, ring buffer 16 keycodes en bank 1 `$5860`), audio AY (futur), GPU async (ADR-21 v2).
  - Classe 2 sync : FAT32, console, GPU sync v1, bank alloc.
  - Mécanisme IRQ formalisé : table dispatch `$01:5680`.
  - Débloque OS-2.d (clavier).
- **ADR-17** ABI kernel publique exposée à userland :
  - 18 syscalls v1, slots `$01-$12`, table dispatch `$01:5750`.
  - `cop #$AA` ABI v1 versionné (v2 future = `cop #$AB`).
  - Convention sentinelle `A=$FF` + errno bank 1 `$5760`.
  - Args > 2 bytes via zero-page kernel `$D0-$DF`.
  - Préservés : X (sauf retour multi-byte), D, DBR, PBR, pile.
  - Débloque Sprint 4 userland C.

#### Sprints à venir Phase 1
- **OS-2.f.v2** — migration COP handler v0.1 (cmp/bne hardcoded sur SYS_PRINT_CHAR) → v0.2 table dispatch 18 syscalls. Estim. 2 j.
- **OS-2.d** — driver clavier IRQ-driven event queue selon ADR-16. Estim. 3-5 j.
- **OS-2.e** — driver console générique. Estim. 2-3 j.

#### Documentation
- Cf. `../docs/adr/0016-driver-model.md`, `../docs/adr/0017-abi-syscall-userland.md`, et `../CLAUDE.md` §2.

#### Aucun changement de code en Phase 0
- Pas de modification `kernel.s`. État du kernel inchangé.

---

## [0.40.0] - 2026-05-09

### Sprint 3.c v0.4 — 3e fenêtre démo palette ✨

#### Added
- Boot kernel : ajout window 3 colorful à (140, 100), 80×60.
- Couleurs distinctes : frame=12=lightred, title=14=yellow,
  body=11=lightcyan.
- Démontre la palette VGA-IBM 16 couleurs (ADR-20 v3).

#### Notes / contraintes connues
- `kernel_window_draw` v0.1 utilise des args ZP 8-bit (WIN_X/Y/W/H).
- Limite : x+w-1 ≤ 255 et y+h-1 ≤ 255.
- Window 3 placée à (140, 100, 80, 60) → x_end=219, y_end=159 (OK).
- Extension args 16-bit prévue v0.5 pour fenêtres dépassant la zone
  haute-gauche du framebuffer XVGA.

#### Validation
- 541 tests OK (+6 ASSERTs window 3).
- PPM `/tmp/oricos_window_xvga.ppm` montre 3 fenêtres simultanées.

#### Démo PPM finale (visualisation 1024×768)
- **Window 1** (20, 10) titlebar BLEUE avec "OS" en BLANC.
- **Window 2** (300, 300) titlebar VERTE — *dragged* depuis (50, 80).
- **Window 3** (140, 100) frame rouge clair, titlebar JAUNE,
  body cyan clair ✨ NOUVEAU.
- Position (50, 80) tout NOIR (zone effacée par drag).

---

## [0.39.0] - 2026-05-09

### Sprint 3.c v0.3 — true drag (BLIT + CLEAR pos1) ✨✨

#### Added
- Boot kernel : démo true drag de window 2.
  - **BLIT** depuis (50, 80) vers (300, 300), 80×60 pixels.
  - **FILL_RECT** clear ancienne pos avec color 0 (effacement).
- Window 1 + "OS" titlebar intacte.

#### Démo PPM finale (3 actions visuelles)
- **Window 1** (20, 10) titlebar BLEUE avec "OS" en BLANC ✨
- **Window 2** (300, 300) titlebar VERTE — *dragged* depuis (50, 80)
- Position (50, 80) tout NOIR (zone effacée par drag) ✨

#### Validation
- 541 tests OK.
- Test mis à jour pour valider :
  - Anciennes asserts (50, 80) effacées → color 0.
  - Nouvelles asserts (300, 300) → pattern fenêtre via BLIT.
  - Frame, titlebar green, body lgray vérifiés à nouvelle pos.

#### Notes implémentation
- **Bug d'arithmétique** trouvé et fixé : confusion entre $58 et $18
  pour MID byte de dst_addr ($031896, pas $035896). Différence
  visuelle = +16 KiB, hors zone visible. Fix : un seul `$58 → $18`.

#### Importance
**True drag** = BLIT (move pixels) + CLEAR (effacer trace originale).
C'est l'opération de base d'un window manager interactif. SP-3.c
v0.4 ajoutera : window list / TCB par fenêtre, focus management,
event-driven drag depuis souris/clavier.

#### Reportés Sprint 3.c v0.4
- struct window_t en RAM (id, x, y, w, h, base_offset, flags).
- Liste fixe 8 windows (TCB-like).
- `kernel_window_create/destroy/move/raise/lower`.
- close/minimize avec backing-store SDRAM via DMA.

---

## [0.38.0] - 2026-05-09

### Sprint GPU-3 v0.3 — kernel_gfx_text + démo "OS" titlebar ✨✨

#### Added
- **`kernel_gfx_text`** : 5e helper kernel utilisant GPU TEXT.
  Args ZP : GFX_BASE, GFX_FONT_LO/MID/HI ($79-$7B), GFX_STR_LO/MID/HI
  ($7C-$7E), GFX_ARG2_LO=x, GFX_ARG2_MID=y, GFX_COLOR.
- **API kernel_gfx_* 100% complète** (5/5 commandes) :
  - kernel_gfx_clear ✅
  - kernel_gfx_fill_rect ✅
  - kernel_gfx_blit ✅
  - kernel_gfx_line ✅
  - **kernel_gfx_text ✅** (NEW)
- Mini-fonte 8×8 embedded en bank 1 : `mini_font_O` + `mini_font_S`.
- String embedded : `mini_text_OS` ('O', 'S', 0).

#### Boot kernel intégré (démo titre)
1. **Pré-charger** bitmap 'O' à SDRAM[$001278] (= font + 'O'×8) via
   `kernel_vram_write_block` (3 octets sources → 8 octets dest).
2. **Pré-charger** bitmap 'S' à SDRAM[$001298].
3. **Pré-charger** string "OS\\0" à SDRAM[$002000].
4. **TEXT(base=$00C000, font=$001000, str=$002000, x=24, y=11,
   color=15)** : écrit "OS" en blanc sur la titlebar bleue de window 1.

#### Validation
- 541 tests OK (inchangé en compte ; nouveaux ASSERTs ajoutés au test
  existant).
- Test `test_oricos_window_draw` étendu : 6 ASSERTs supplémentaires
  pour le texte (pixels (25,11) et (30,11) du 'O' + (33,11) et
  (38,11) du 'S' = white ; (24,11) et (31,11) frontières = blue).
- ASSERT précédent (titlebar pixel (30,11)=blue) déplacé à
  (60,11)=blue car la zone "OS" couvre x=24..39.

#### Démo PPM visualisable
**Le PPM `/tmp/oricos_window_xvga.ppm`** affiche maintenant :
- Window 1 (20, 10) avec **"OS"** en blanc dans la titlebar bleue.
- Window 2 (50, 80) clone via BLIT, titlebar verte.

#### Pipeline complet end-to-end
```
Boot kernel asm (65C816)
  ├─ kernel_vram_write_block × 3 (font 'O', font 'S', string "OS")
  └─ kernel_gfx_text(base, font, str, x, y, color)
       → I/O ports $0340-$034F
       → gpu_device GPU_OP_TEXT exec
       → vram_peek bitmaps + gpu_set_pixel × N pixels
       → SDRAM 16 MiB
       → ASSERTs pixel par pixel + PPM dump visible
```

#### État Sprint 3 / API GPU
- ADR-21 : 100% commandes implémentées (Phosphoric + kernel API).
- API kernel_gfx_* : 5/5 helpers ✅.
- SP-GPU-3 v0.3 ✅ clos.

#### Reportés
- v0.4 : color_bg pour TEXT (background au lieu de transparency).
- v0.4 : fonte taille variable (4×6, 16×16).
- SP-3.c v0.3 : window list / TCB par fenêtre, true drag, close.

---

## [0.37.0] - 2026-05-09

### Sprint 3.c v0.2 — Multi-fenêtre via BLIT (clone) ✨

#### Added
- Boot kernel : démo multi-fenêtre.
  - Window 1 dessinée à (20, 10) via `kernel_window_draw` (titlebar
    blue, body lgray) — déjà en v0.1.
  - **BLIT(src=window1, dst=(50, 80), 80×60)** : clone l'intégralité
    de window 1 vers une 2e position via GPU BLIT.
  - **FILL_RECT** repaint titlebar window 2 en green (color 2) pour
    distinction visuelle.

#### Validation
- 540 tests OK.
- Test `test_oricos_window_draw` étendu : 18 ASSERTs window 1 +
  10 ASSERTs window 2 (4 coins frame + 3 titlebar green + 3 body
  lgray du BLIT).
- PPM dump 1024×768 16-color montre **2 fenêtres distinctes** :
  - Window 1 : (20, 10), titlebar blue.
  - Window 2 : (50, 80), titlebar green (clone via BLIT puis
    repaint).

#### Importance
**Premier multi-fenêtre OricOS** dessiné via le pipeline GPU
autonome. Démontre :
1. BLIT HW pour cloner/déplacer une fenêtre rapidement (l'équivalent
   du drag fenêtre, sans avoir à redessiner depuis scratch).
2. Composition multi-couche via FILL_RECT repaint (changer un
   élément d'une fenêtre clonée).

#### Reportés Sprint 3.c v0.3
- True drag : BLIT + CLEAR pos1 (effacer original après move).
- Window list / TCB par fenêtre : multi-fenêtré dynamique.
- `kernel_window_close` / `kernel_window_minimize` : backing-store
  SDRAM via DMA.
- Title text via `kernel_gfx_text` (dépend SP-GPU-2 v0.3).

#### Notes implémentation
- Erreur initiale dans calcul dst_addr : confusion entre 80×512=40960
  (bon) vs 41000 (faux). Correct = $00C000 + 40985 = $016019.
- Le BLIT v0.1 byte-aligned exige x_pair pour src et dst (50 et 20
  sont OK pairs).

---

## [0.36.0] - 2026-05-09

### Sprint 3.c v0.1 — Window manager basique ✨

#### Added
- **`kernel_window_draw`** : dessine 1 fenêtre rectangulaire via GPU.
  - Args ZP : WIN_BASE_LO/MID/HI ($88-$8A) = base SDRAM framebuffer.
    WIN_X ($80), WIN_Y ($81), WIN_W ($82), WIN_H ($83) = position et
    dimensions (8-bit). WIN_TITLEBAR_H ($84) = hauteur title bar.
    WIN_COLOR_FRAME ($85), WIN_COLOR_TITLE ($86), WIN_COLOR_BODY ($87)
    = couleurs 4-bit.
  - Algorithme : 6 commandes GPU séquentielles :
    1. FILL_RECT body entier.
    2. FILL_RECT titlebar par-dessus.
    3-6. 4 LINEs Bresenham pour le cadre (top, bottom, left, right).
  - Pré-calcul X+W-1 et Y+H-1 dans tmp $8B/$8C.

#### Boot kernel intégré (démo window)
- CLEAR(base=$00C000, size=32 KiB, color=0=black) : fond noir 64 lignes.
- kernel_window_draw(base=$00C000, x=20, y=10, w=80, h=60, titlebar=8,
  frame=0=black, title=1=blue, body=7=lgray).

#### Validation
- 540 tests OK (539 → 540, +1).
- Test `test_oricos_window_draw` valide pixel par pixel :
  - 4 coins du cadre = 0 (black).
  - 4 milieux des bords = 0.
  - 3 pixels titlebar interior = 1 (blue).
  - 3 pixels body interior = 7 (lgray).
  - 4 pixels hors fenêtre = 0 (CLEAR initial).

#### Importance
**Première fenêtre GUI dessinée par OricOS via le pipeline GPU
complet end-to-end** :
```
Boot kernel
  → kernel_window_draw (asm OricOS)
  → kernel_gfx_fill_rect/line (asm)
  → I/O ports $0340-$034F
  → gpu_device dispatch (Phosphoric C)
  → exec FILL_RECT/LINE (4bpp pixel mask)
  → vram_device SDRAM
ASSERT pixel par pixel : cadre + titlebar + body corrects.
```

Sprint 3.c v0.1 démontre que OricOS peut dessiner une fenêtre via le
GPU autonome. Sprint 3.c v0.2 (à venir) ajoutera : drag fenêtre via
BLIT, multifenêtré, focus management.

#### Reportés Sprint 3.c v0.2
- `kernel_window_move(window_id, dx, dy)` via BLIT depuis position
  ancienne vers nouvelle.
- `kernel_window_close` / `kernel_window_minimize` (backing-store
  SDRAM via DMA).
- Multifenêtré (TCB par fenêtre).
- Title text via `kernel_gfx_text` (dépend SP-GPU-2 v0.3).

---

## [0.35.0] - 2026-05-09

### Sprint GPU-3 v0.2 — kernel_gfx_blit + kernel_gfx_line ✨

#### Added
- **`kernel_gfx_blit`** : copie bloc rectangulaire SDRAM → SDRAM via
  GPU BLIT. Args ZP : GFX_BASE (= src), GFX_ARG2 (= dst, 24-bit),
  GFX_ARG3_LO=byte_w, GFX_ARG3_MID=byte_h.
- **`kernel_gfx_line`** : tracé Bresenham 4bpp via GPU LINE. Args
  ZP : GFX_BASE, GFX_ARG2_LO=x1, GFX_ARG2_MID=y1, GFX_ARG3_LO=x2,
  GFX_ARG3_MID=y2, GFX_COLOR.
- Constantes I/O : GPU_OP_BLIT = $03, GPU_OP_LINE = $04.

#### Boot kernel intégré (démos)
- BLIT(src=$004000, dst=$008000, byte_w=10, byte_h=8) : copie 8 lignes
  × 10 bytes (= 20 pixels) du framebuffer test vers ligne 32+.
  Le rect FILL_RECT (lignes 2..5 byte 2..5) est répliqué en lignes
  34..37 byte 2..5 dans le dst.
- LINE((40, 20)→(40, 25), color=2=green) : ligne verticale 6 pixels
  vert sur fond blue. Pixel 40 pair → mask 0xF0 → byte = (clear $44 &
  $0F) | (color 2 << 4) = $24.

#### Validation
- 539 tests OK (inchangé en compte mais test couvre maintenant 4
  commandes GPU au lieu de 2).
- Test étendu `test_oricos_gpu_clear_then_fill_rect` :
  - CLEAR + FILL_RECT (existants).
  - BLIT : rect copié à dst correct, hors range = $44 (zone CLEAR).
  - LINE : 3 pixels x=40 sur lignes 20, 22, 25 = $24 ; hors LINE = $44.

#### État API kernel_gfx_*
| Helper | Status | GPU opcode |
|--------|--------|------------|
| kernel_gfx_clear | ✅ v0.1 | CLEAR |
| kernel_gfx_fill_rect | ✅ v0.1 | FILL_RECT |
| kernel_gfx_blit | ✅ v0.2 | BLIT |
| kernel_gfx_line | ✅ v0.2 | LINE |
| kernel_gfx_text | ⏳ v0.3 | TEXT (font ROM) |

#### Reportés
- `kernel_gfx_text` : dépend de SP-GPU-2 v0.3 (font ROM côté Phosphoric).
- IRQ-based wait (vs polling busy actuel timeout 256).
- Refactor `kernel_hires2_*` legacy → suppression Sprint 3.b cleanup.

#### Importance
**Le kernel OricOS dispose maintenant d'une API graphique complète
pour Sprint 3.c** : clear, fill_rect, blit, line. Suffisant pour un
window manager basique sans texte (ou avec texte minimal via
fill_rect bitmap manuelle).

---

## [0.34.0] - 2026-05-09

### Sprint GPU-3 — kernel API kernel_gfx_* via GPU (ADR-21) ✨

#### Added
- **`kernel_gfx_clear`** : remplit zone SDRAM via GPU CLEAR.
  Args ZP : GFX_BASE_LO/MID/HI ($70-$72), GFX_ARG2_LO/MID/HI ($73-$75
  pour size 24-bit), GFX_COLOR ($78). Setup registres I/O GPU
  $0341-$0349, trigger via $034E, poll busy timeout 256.
- **`kernel_gfx_fill_rect`** : rectangle 4bpp dans framebuffer SDRAM
  via GPU FILL_RECT. Args ZP : GFX_BASE_LO/MID/HI, GFX_ARG2_LO=x,
  GFX_ARG2_MID=y, GFX_ARG3_LO=w, GFX_ARG3_MID=h, GFX_COLOR. v0.1
  limites 8-bit chacun (≤255) ; BPL hardcodé GPU=512 (XVGA ADR-20 v3).
- Constantes I/O `GPU_*_IO` (ports $0340-$034F) + opcodes
  GPU_OP_CLEAR=$01, GPU_OP_FILL_RECT=$02 + bits status.
- ZP args $70-$78 (9 octets).

#### Boot kernel intégré (démo)
- CLEAR(base=$004000, size=32 KiB, color=4=blue) → 32 KiB pattern $44.
- FILL_RECT(base=$004000, x=4, y=2, w=8, h=4, color=15=white) →
  rectangle 8×4 pixels white sur fond blue.

#### Validation
- 534 tests OK (533 → 534, +1).
- Test `test_oricos_gpu_clear_then_fill_rect` :
  - 32 KiB pattern $44 vérifié sur 3 points + frontières.
  - Rect 4 coins bytes vérifiés à $FF.
  - Hors rect vérifié à $44 (avant/après/dessus/dessous).

#### Reportés Sprint GPU-3 v0.2
- Helpers `kernel_gfx_blit`, `kernel_gfx_line`, `kernel_gfx_text`
  (dépendent de SP-GPU-2 = extension Phosphoric).
- IRQ-based wait (vs polling busy actuel).
- Refactor : `kernel_hires2_clear` / `kernel_fill_rect_aligned`
  deviennent obsolètes vs `kernel_gfx_*`. Cleanup Sprint 3.b.

#### Importance
**Premier code OricOS qui utilise le GPU** au lieu d'écrire directement
en VRAM. SP-3.c (window manager) pourra s'appuyer sur ces helpers
pour dessiner des fenêtres.

---

## [0.33.0] - 2026-05-09

### Pool LIVE ajusté pour ADR-20 (banks 132-159)

Suite à la ratification d'ADR-20 (mode HIRES Oric 2 desktop = SVGA
800×600×4bpp, framebuffer occupe 4 banks 128-131), le pool LIVE
allocator démarre à **bank 132 ($84)** au lieu de bank 129.

- `BANK_LIVE_POOL_BASE` : $81 → $84.
- Pool live = 28 banks (132-159) au lieu de 31.
- Démo allocator au boot retourne maintenant $84/$85/$86/$85.

Toujours 526 tests OK.

---

## [0.32.0] - 2026-05-09

### Sprint VRAM-3 — Pool LIVE banks 129-159 + robustesse DMA ✨

#### Added
- **`kernel_alloc_live_bank`** : alloue un bank dans le pool LIVE
  (banks 129-159 = $81-$9F, 31 banks BRAM ECP5 selon ADR-19).
  Algorithme identique au pool système : pop free list LIFO, sinon
  bump `BANK_LIVE_NEXT`. Retourne A=$00 si pool épuisé.
- **`kernel_free_live_bank`** : libère un bank live (push sur free
  list, drop silencieux si full).
- Constantes : `BANK_LIVE_POOL_BASE=$81`, `BANK_LIVE_POOL_END=$A0`
  (banks 129-159 inclusifs). Bank 128 ($80) réservé framebuffer
  principal HIRES Oric 2 (ADR-12), pas dans le pool live.
- Storage : `BANK_LIVE_NEXT` ($015458), `BANK_LIVE_FREE_LIST`
  ($0154C0..$0154CF), `BANK_LIVE_FREE_TOP` ($0154D0).

#### Boot kernel intégré (démo allocator live)
- Init `BANK_LIVE_NEXT = $81` + `BANK_LIVE_FREE_TOP = 0`.
- Alloc 3 banks live consécutifs ($81, $82, $83) → BANK_LIVE_DEMO+0/1/2.
- Free $82 → push sur free list.
- Alloc → pop free list → $82 → BANK_LIVE_DEMO+3.

#### Robustesse `kernel_vram_dma` (fix incident sprint VRAM-2)
- Le poll busy avait une **boucle potentiellement infinie** si
  `vram_device` absent ou stuck (lecture default $FF avec bit 7 set).
- Fix : timeout 256 polls (X 8-bit count). Robuste en simulation
  sans vram_device et en HDL face à un controller stuck.
- Pas d'impact sur le cas nominal v0.1 (busy=0 dès la 1ère poll).

#### Validation
- 526 tests OK (525 → 526, +1).
- Test `test_oricos_live_alloc_demo` :
  - ASSERT BANK_LIVE_DEMO+0..3 = $81 $82 $83 $82 (3 alloc + free + alloc).

#### Architecture
**Deux pools de banks distincts** désormais :
- Pool système (banks 4-127, $04..$7F) pour code/data apps.
- Pool live (banks 129-159, $81..$9F) pour fenêtres GUI live.

OricOS peut désormais allouer des banks dédiés au framebuffer/fenêtres
GUI sans interférer avec le pool d'apps. SP-3.c (window manager)
exploitera ce pool : 1 bank live par fenêtre active.

---

## [0.31.0] - 2026-05-09

### Sprint VRAM-2 — kernel API vram_* (ADR-19) ✨

#### Added
- **`kernel_vram_write_block`** : copie RAM banking → VRAM cold via
  I/O port `VRAM_DATA` avec auto-increment HW. Args ZP : DP_PCPTR
  source, VRAM_OP_ADDR (24-bit), VRAM_OP_LEN (16-bit).
- **`kernel_vram_read_block`** : VRAM cold → RAM banking. Mêmes args.
- **`kernel_vram_dma`** : trigger DMA HW SDRAM↔bank. Args ZP :
  VRAM_DMA_SRC (24-bit), DST (24-bit), LEN (16-bit, 0=64K), DIR
  (0=SDRAM→bank, $02=bank→SDRAM). Polling `busy` bit après trigger.
- Constantes I/O : VRAM_*_IO ($000330-$00033C), VRAM_DMA_TRIG/DIR/BUSY.
- ZP args : $60-$64 (write/read_block), $65-$6D (dma).

#### Boot kernel intégré
Tests en séquence après fill_rect_aligned :
1. **write_block** : "VRAM" embedded (data `vram_test_str`) → SDRAM[$001000].
2. **read_block** : SDRAM[$002000] (pré-rempli "ABCD" côté C) → bank $04:0500.
3. **dma** : bank $04:0500 → SDRAM[$003000], 4 bytes (DIR=bank→SDRAM).

#### Validation
- 525 tests OK (524 → 525, +1).
- Test `test_oricos_vram_write_read_dma` : ASSERT
  - vram[$001000..3] = "VRAM" (write_block)
  - mem[$04:0500..3] = "ABCD" (read_block)
  - vram[$003000..3] = "ABCD" (dma)

#### Reportés v0.2
- Helper `kernel_vram_alloc(size)` retourne adresse 24-bit (allocator
  bumb-only ou bitmap).
- Wrapper `kernel_vram_blit(src_24, dst_24, w, h)` pour copier des
  rectangles 2D entre fenêtres backing.

#### Importance architecturale
**Premier code kernel utilisant l'I/O VRAM cold.** Les Sprints
suivants (SP-VRAM-3 refactor allocator, SP-3.c window manager)
peuvent maintenant s'appuyer sur ces helpers comme primitives de
base pour gérer les backing-stores fenêtres.

---

## [0.30.0] - 2026-05-09

### Sprint 3.b v0.2 — kernel_fill_rect_aligned ✨ (+ fix Phosphoric)

#### Added
- **`kernel_fill_rect_aligned`** : rectangle 8-px-aligned X (groupes
  de 8 pixels). Args ZP : gx_start, gx_count, y_start, y_count, color.
- Algorithme : pour chaque ligne (count-down 8-bit en zp $3B),
  inner loop écrit gx_count triples consécutifs via DP indirect long
  [HIRES2_FB_PTR],Y avec Y 16-bit.
- Constantes : HIRES2_BPL=90, HIRES2_GX_START..RECT_COL en zp $40-$44.
- Boot kernel intégré : appel `kernel_fill_rect_aligned(gx=10,
  gxc=10, y=60, yc=80, red)` après `kernel_hires2_clear(blue)`.

#### Bug racine (côté Phosphoric, fixé) — analyse instructive
La 1ère implémentation montrait un rectangle dessiné à (-6gx, -51y)
du target. Sentinels asm (zone bank 1 $015D00..$015D0E) ont permis
d'isoler le bug DANS Phosphoric, pas OricOS :
- Opcodes ASL/LSR/ROL/ROR Accumulator (`$0A`, `$4A`, `$2A`, `$6A`)
  ne propageaient PAS le carry low → high byte en M=0.
- Calcul `y * 90` par shifts 16-bit donnait `$0318 = 792` au lieu de
  `$1518 = 5400` pour y=60.

Fix Phosphoric : branchement M=8bit/M=16bit explicite dans les 4 cas
Accumulator, utilisant `cpu->C` 16-bit en M=0 (cf. Phosphoric/CHANGELOG).

Cette session est un **bel exemple de pluri-projets** : un bug
golden-model découvert via la primitive OS, fixé en amont, le code
OricOS s'avère correct depuis le début.

#### Validation
- 515 tests OK.
- Test `test_oricos_hires2_clear_and_rect` : boot kernel → ASSERT
  6400 pixels red à (80..159, 60..139) + 41600 pixels blue partout
  ailleurs + 0 autres couleurs. Frontières strictes vérifiées.

#### Reportés v0.3
- `kernel_pixel_set(x, y, color)` arbitraire pixel-perfect.
- `kernel_blit(src, dst, w, h)` pour fontes / icônes.
- Bascule mode TEXT ↔ HIRES via registre I/O `VID_MODE`.

---

## [0.29.0] - 2026-05-09

### Sprint 3.b v0.1 — Kernel primitive HIRES Oric 2 (clear_screen) ✨

#### Added
- **`kernel_hires2_clear(A=color)`** : remplit le framebuffer HIRES
  Oric 2 (bank 128, ADR-12) avec une couleur uniforme 0..7. 18 000
  octets écrits via DP indirect long (3 octets par groupe de 8 pixels).
- **`pattern_table`** : 8 entries × 3 octets, pré-calcul du pattern
  24-bit `color × $249249` (8 pixels même couleur).
- Constantes `HIRES2_BANK = $80`, `HIRES2_FB_SIZE = 18000`.
- ZP tmp : `HIRES2_PAT_PTR ($20)`, `HIRES2_FB_PTR ($24)`,
  `HIRES2_PB0..PB2 ($34..$36)`.
- **Boot kernel intégré** : appel `kernel_hires2_clear(blue)` tôt dans
  `kernel_entry` (après bascule mode N, avant sentinel). Lazy alloc
  bank 128 via 1ère écriture (mécanisme B1.8 Phosphoric).

#### Validation (côté Phosphoric)
- 515 tests OK (514 → 515, +1).
- Test `test_oricos_hires2_clear_fills_blue` :
  - Boot kernel → ASSERT pattern octets `$92 $49 $24` aux 4 coins
    + dernier triple (offset 17997-17999).
  - ASSERT `hires_oric2_get_pixel = 4` (blue) sur 5 positions.
  - ASSERT 100% des pixels ARGB = `0x0000FF` (= scan complet 240×200).

#### Reportés Sprint 3.b v0.2
- `kernel_pixel_set(x, y, color)` arbitraire pixel-perfect
  (gestion bit_shift cross-octet pour pixels 2 et 5).
- `kernel_fill_rect(x, y, w, h, color)` arbitraire.
- `kernel_blit(src, dst, w, h)` pour rendering de fontes / icônes.
- Bascule mode TEXT Oric 1 ↔ HIRES Oric 2 (registre I/O `VID_MODE`).

#### Importance architecturale
**Premier code OricOS qui écrit dans le framebuffer Oric 2.** Le pipeline
complet est désormais opérationnel : kernel asm → bank 128 → render
ARGB → ASSERT visuel. Les futurs sprints 3.c/d/e (window manager,
toolkit, multifenêtré) pourront s'appuyer sur des primitives de plus
haut niveau (fill_rect, blit) construites sur ce socle.

---

## [0.28.0] - 2026-05-09

### Sprint 2.l v0.2 — App loader multi-cluster depuis SD ✨

#### Added
- **Boot kernel intégré** : ouvre MULTI.BIN (bundle 527B, 2 clusters)
  via `kernel_fat_open`, charge le fichier complet vers $01:8000 via
  `kernel_fat_read_file`, puis exécute via `kernel_app_exec`.
- **App MULTI.BIN** : bundle dont la section CODE est à offset 520
  (= dans le 2e cluster). Exerce le pipeline cross-cluster :
  - Header bundle dans cluster 6 (LBA 164).
  - Code app à offset 520 = dans cluster 7 (LBA 165).
  - `kernel_app_exec` calcule `DP_SRC = DP_PTR + offset` (16-bit add)
    puis copie 7 octets vers `$BANK:0200`.
- L'app exécute `ldx #'X' ; lda #1 ; cop #$AA ; rtl` → 'X' à $BBAD.

#### Validation
- 503 tests OK (`kernel_app_exec` v0.1 supporte déjà bundle multi-cluster
  en RAM ; aucune modification de l'API).
- Image SD test : 166 secteurs (FAT étendue avec FAT[6]=7, FAT[7]=EOC ;
  3e entry root dir MULTI.BIN cluster=6 size=527).
- ASSERT `mem[$BBAD] = 'X'` après boot kernel — confirme exec depuis
  bundle multi-cluster.
- Démo SDL2 attendue : "OricOS v0.7" + "YABZZX" (5 chars : Y syscall +
  AB hex + 2 Z = 2 apps single-cluster + X = app multi-cluster).

#### Importance architecturale
**OricOS peut désormais charger ET exécuter une app de taille arbitraire
depuis FAT32 SD**. C'est le pipeline complet :
1. fat_open (lookup 8.3)
2. fat_read_file (multi-cluster)
3. app_exec (validate + alloc bank + copy + JSL)

Aucune limite de taille pour la section CODE en RAM (l'offset 32-bit du
bundle permet section CODE > 64 KiB ; seule la limite size 8-bit dans
app_exec v0.1 borne le code copié à 256 octets — à étendre v0.3 si
besoin).

#### Reportés v0.3 / Reportés OS-2.l v0.3
- Section CODE > 256 octets (passage size 16-bit dans la copie).
- Sections multiples (DATA, ICON) traitées par app_exec.
- Free bank au RTS de l'app (resource tracking).
- Sandbox / privilege check.

---

## [0.27.0] - 2026-05-08

### Sprint 2.j v0.3 — kernel_fat_read_file (multi-cluster) ✨

#### Added
- **`kernel_fat_read_file`** : lit un fichier complet en suivant la
  chaîne FAT32 jusqu'à EOC. Boucle `read_cluster` + `next_cluster`,
  avance `DP_PCPTR` de 512 octets entre chaque cluster.
- API : input `FS_FOUND_CLUSTER` (4B, first cluster du fichier),
  `DP_PCPTR` (24-bit, destination). Préserve `FS_FOUND_CLUSTER` à la
  sortie (sauvegarde/restauration via zp tmp $28-$2B).
- Sortie sur EOC (cluster >= $0FFFFFF8) : test 4 bytes du cluster avec
  AND $0F sur byte 3 (FAT32 28 bits).
- Boot kernel intégré : ouvre BIG.BIN (1024 octets, 2 clusters) puis
  lit le fichier vers $01:7000. Cluster 4 (LBA 162, pattern $AA) +
  cluster 5 (LBA 163, pattern $55) = 1024 octets contigus en mémoire.

#### Validation
- 503 tests OK.
- Image SD test étendue : 164 secteurs (boot + zéros + FAT + root dir
  avec 2 entries + 3 clusters de données).
- ASSERTs supplémentaires :
  - `mem[$01:7000]` = $AA (début cluster 4)
  - `mem[$01:71FF]` = $AA (fin cluster 4, 512 octets exacts)
  - `mem[$01:7200]` = $55 (début cluster 5, suivi de la chaîne FAT[4]→5)
  - `mem[$01:73FF]` = $55 (fin cluster 5)

#### Reportés v0.4
- Fichiers > 64 KiB (DP_PCPTR low+mid 16-bit, propagation vers bank).
- BPS != 512.
- Cluster >= 16384 (FAT spread sur plusieurs secteurs).
- Subdirectories.

#### Importance architecturale
**OricOS peut désormais charger un fichier de taille arbitraire**
(jusqu'à 64 KiB en v0.3) depuis FAT32 SD. C'est le building block
final pour exécuter des apps réelles : un app loader complet pourra
charger un bundle multi-cluster, alloc autant de banks que nécessaire,
et exécuter. La granularité 1 cluster = 1 secteur (SPC=1) est typique
en FAT32 sur petites cartes SD.

---

## [0.26.0] - 2026-05-08

### Sprint 2.j v0.2 — kernel_fat_next_cluster (cluster chain) ✨

#### Added
- **`kernel_fat_next_cluster`** : lit l'entry FAT32 d'un cluster pour
  obtenir le cluster suivant dans la chaîne. Permet la lecture de
  fichiers > 1 cluster.
- Convention : input dans `FS_QUERY_CLUSTER` (4B, $016180..$016183),
  output dans `FS_NEXT_CLUSTER` (4B, $01617C..$01617F). Le high
  nibble du byte 3 est masqué (FAT32 = 28 bits effectifs). Une valeur
  de retour >= $0FFFFFF8 = EOC (fin de chaîne).
- Algorithme : LBA = `FS_RSC + (cluster*4) / FS_BPS`,
  `offset_in_sec = (cluster*4) % FS_BPS`. Hypothèse v0.2 : BPS=512,
  cluster < 16384 (offset_bytes 16-bit).
- Boot kernel intégré : test cluster chain avec `FS_QUERY_CLUSTER = 4`,
  vérifie `FS_NEXT_CLUSTER == 5` (FAT[4] = 5 dans l'image test).

#### Validation
- 503 tests OK (pas de nouveau test, ASSERT supplémentaire dans
  `test_oricos_fat_init_validates_fat32_signature`).
- Image SD test étendue : LBA 32 contient une vraie FAT FAT32 partielle
  avec FAT[0..5] (media descriptor + reserved + root EOC + HELLO.BIN
  EOC + BIG.BIN cluster 4 → 5 → EOC).
- ASSERT `FS_NEXT_CLUSTER = $00000005` après boot kernel.

#### Reportés v0.3
- `kernel_fat_read_file` : itération sur la chaîne complète pour
  charger un fichier > 1 cluster.
- BPS != 512.
- Cluster >= 16384 (FAT spread sur plusieurs secteurs).
- Subdirectories (parser dirs au-delà de root).

#### Importance architecturale
La traversée de chaîne FAT est un building block essentiel : sans elle,
OricOS ne peut charger que des fichiers ≤ 512 octets. Avec elle, la
v0.3 pourra charger des fichiers de taille arbitraire en bouclant sur
`fat_next_cluster` jusqu'à EOC.

---

## [0.25.0] - 2026-05-08

### Sprint 2.j.5/6 — App chargée depuis SD via FAT32 ✨

#### Added
- **`kernel_fat_read_cluster`** : lit 1 cluster (v0.1, SPC=1 = 1 secteur)
  vers `DP_PCPTR`. LBA = `FS_FDS + (FS_FOUND_CLUSTER - 2)`. Modifie A,
  X, Y, $30/$31, FS_BUFFER (transitoirement).
- **Boot kernel intégré** : après `fat_open` OK, lit le cluster du
  bundle vers `$01:6200` puis appelle `kernel_app_exec` avec ce bundle.
  L'app exécutée depuis SD écrit un 'Z' supplémentaire après le 'Z'
  du bundle inline.

#### Validation
- 503 tests OK.
- Image FAT32 test étendue : 162 secteurs (boot + zéros + root dir +
  cluster 3 = bundle hello).
- Test ASSERT après boot kernel :
  - `mem[$01:6200..]` contient le bundle ("OOS\\x01...A2 Z..6B").
  - `mem[$BBAB] = 'Z'` (bundle inline).
  - `mem[$BBAC] = 'Z'` (bundle chargé depuis SD).
- Démo SDL2 visible : "OricOS v0.7" + "YABZZ" (Y syscall + AB hex +
  **deux Z** — premier de l'app inline, second de l'app SD).

#### Importance architecturale
**Le pipeline complet est fonctionnel** :
1. Boot kernel.
2. SD device émulé (Phosphoric I/O $0320-$0327).
3. `kernel_sd_read_block` ↔ image hôte.
4. `kernel_fat_init` valide FAT32 + parse champs.
5. `kernel_fat_open` localise fichier 8.3 dans root dir.
6. `kernel_fat_read_cluster` charge le contenu en mémoire.
7. `kernel_app_exec` valide bundle + alloc bank + copy code + JSL.
8. App exécute en bank dédiée + syscall vers kernel.

**OricOS peut désormais charger et exécuter une app depuis FAT32 SD**
sans qu'elle soit embedded dans le kernel.

#### v0.2 (reportés)
- Cluster chain traversal (fichier > 1 cluster).
- Fichier > 32 MiB (LBA 32-bit).
- Subdirectories.
- Lectures partielles (offset + size).
- Cache de blocs.

---

## [0.24.0] - 2026-05-08

### Sprint 2.j.4 — kernel_fat_open (root dir lookup 8.3)

#### Added
- **`kernel_fat_open`** : recherche un fichier 11B (8.3 padded espaces,
  uppercase) dans le root dir.
  - Args : `DP+$40..$4A` = filename 11B.
  - Lit root dir cluster (LBA = `FS_FDS`, suppose `FS_ROOT=2`) dans
    `FS_BUFFER` via `kernel_sd_read_block`.
  - Scanne 16 entries de 32B :
    - skip `$00` (end of dir, → NOT_FOUND)
    - skip `$E5` (deleted)
    - skip `$0F` attribute (LFN)
    - skip `$08`/`$10` attributes (volume label, directory)
    - sinon compare nom byte-par-byte via `cmp a:DP_FILENAME,Y`
  - Sur match : extrait `first_cluster` (cluster_low+high → 4B) et
    `size` (4B) → stocke dans `FS_FOUND_CLUSTER`/`FS_FOUND_SIZE`.
  - `FS_OPEN_RESULT` = `$00` OK / `$01` NOT_FOUND.
- **Constantes `DE_*`** pour offsets dir entry, `DP_FILENAME = $40`,
  `DP_ENTRY = $50` (pointer 24-bit en zero page).

#### Validation
- 503 tests OK.
- Image FAT32 test étendue à 161 secteurs : boot sector + zéros +
  bloc FDS=160 avec entry "HELLO   BIN" cluster=3, size=$DEADBEEF.
- Test ASSERT après boot kernel : `FS_OPEN_RESULT=0`,
  `FS_FOUND_CLUSTER=$00000003`, `FS_FOUND_SIZE=$DEADBEEF`.

#### Limitations v0.1
- 1 secteur de root dir max (16 entries). Cluster chain non parcourue.
- LBA root = `FS_FDS` (suppose `FS_ROOT=2`). Si `FS_ROOT > 2`, faut
  calculer `FDS + (FS_ROOT-2)*FS_SPC` — reporté v0.2.
- Pas de support LFN (long filename).

#### Reportés (OS-2.j.5+)
- **OS-2.j.5** : `kernel_fat_read(file, dest, size)` — traverse FAT
  chain via lookups dans la FAT.
- **OS-2.j.6** : intégration loader (charge app depuis SD).

---

## [0.23.0] - 2026-05-08

### Sprint 2.j.3 — Parse complet boot sector FAT32

#### Added
- **`fat_parse_boot_sector`** (helper interne appelé par fat_init après
  signature OK) : parse 6 champs critiques du boot sector FAT32 :
  - `FS_BPS` (2B) bytes per sector — offset $0B
  - `FS_SPC` (1B) sectors per cluster — offset $0D
  - `FS_RSC` (2B) reserved sectors count — offset $0E
  - `FS_NFAT` (1B) num FATs — offset $10
  - `FS_SPF` (4B) sectors per FAT (FAT32) — offset $24
  - `FS_ROOT` (4B) root cluster (FAT32) — offset $2C
- **Calcul `FS_FDS`** (first data sector) = `FS_RSC + FS_NFAT * FS_SPF`
  par boucle d'addition (NFAT typique = 2). v0.1 limite à 16-bit
  (disque < 32 MiB), high bytes = 0.
- **Constantes `BS_*`** pour les offsets dans le boot sector.

#### Validation
- 503 tests OK (compteur inchangé, ASSERT étendus dans le test
  fat_init existant).
- Test `test_oricos_fat_init_validates_fat32_signature` étendu : ASSERT
  les 6 champs parsés + FS_FDS calculé sur image FAT32 minimale
  (BPS=512, SPC=1, RSC=32, NFAT=2, SPF=64, ROOT=2 → FDS=160).

#### v0.1+ (reportés OS-2.j.4+)
- **OS-2.j.4** : `kernel_fat_open(filename)` — read root dir cluster,
  scan entries 32B pour 8.3 match, retourne first_cluster + size.
- **OS-2.j.5** : `kernel_fat_read` traverse FAT chain.
- **OS-2.j.6** : intégration `kernel_app_exec` charge depuis SD.

---

## [0.22.0] - 2026-05-08

### Sprint 2.j.2 — kernel_fat_init (signature FAT32)

#### Added
- **`kernel_fat_init`** : lit boot sector (LBA 0) via `kernel_sd_read_block`,
  vérifie signature `"FAT32"` à offset $52 du boot sector. Retourne via
  `FS_INIT_RESULT` ($016160) : $00 OK ou $01 BAD.
- **Constantes `FS_BUFFER` ($015F60), `FS_INIT_RESULT` ($016160),
  `FS_FAT32_SIG = $52`**.
- Buffer FS distinct du buffer test sd_read_block ($015D40) — préserve
  les ASSERT pattern A..Z du Sprint 2.j.1.
- Test au boot : `kernel_fat_init` après `kernel_sd_read_block`.

#### Validation
- 503 tests OK (502 → +1).
- Test `test_oricos_fat_init_validates_fat32_signature` : image FAT32
  minimale, ASSERT mem[$015F60+$52..+$56] = "FAT32" et
  mem[$016160] = $00.
- Test sd_read_block étendu : sur image pattern A..Z (pas de signature),
  ASSERT mem[$016160] = $01 (BAD).

#### v0.1+ (reportés OS-2.j.3+)
- **OS-2.j.3** : parser complet boot sector (bytes_per_sector,
  sectors_per_cluster, reserved_sectors, num_fats, sectors_per_fat,
  root_cluster) → calcul `first_data_sector`.
- **OS-2.j.4** : `kernel_fat_open(filename)` lecture root dir + lookup
  fichier 8.3.
- **OS-2.j.5** : `kernel_fat_read(file, dest, size)` traverse FAT chain.
- **OS-2.j.6** : intégration loader (charger app depuis SD au lieu de
  `.incbin`).

---

## [Unreleased] - 2026-05-08

### Sprint 2.j.1 — Test fonctionnel SD validé

- Test côté Phosphoric `test_oricos_sd` : pipeline complet driver
  kernel `kernel_sd_read_block` ↔ device SD émulé ↔ fichier image
  hôte. Image test 512B (pattern A..Z répété) chargée, kernel lit
  bloc 0 au boot, ASSERT contenu en bank 1 $5D40+.
- 502 tests OK.

---

## [0.21.0] - 2026-05-08

### Sprint 2.j.0 — Driver bloc SD minimal

#### Added
- **`kernel_sd_read_block`** : lecture d'un bloc 512 octets via le device
  SD émulé (mappé à `$0320-$0327` en bank 0).
- **Convention v0.1** : LBA 16-bit en zero page `$30`/`$31`, destination
  via `DP_PCPTR` (24-bit pointer en `$0C-$0E`). Bit 16-23 du LBA ignoré
  (max 32 MiB en v0.1, à étendre).
- **Constantes SD_LBA_LO/MID/HI/CTRL/DATA** + `SD_CTRL_READ`/`SD_CTRL_BUSY`.
- Test au boot : `kernel_sd_read_block(LBA=0, dest=$01:5D40)`. Sans
  image SD : copie 512 zéros (no-op fonctionnel). Avec image : lit
  bloc 0.

#### Validation
- 501 tests OK (pas de régression).
- Sans crash quand sd_read_block appelé sans image SD active.
- Test fonctionnel avec image réelle reporté OS-2.j.1.

#### v0.1+ (reportés)
- **OS-2.j.1** : test fonctionnel avec image SD réelle (FAT32 ou raw).
- **OS-2.j.2** : parser FAT32 boot sector + root dir lookup.
- **OS-2.j.3** : `kernel_fat_open(filename)` lecture fichier.
- **OS-2.j.4** : intégration loader (charger app depuis SD au lieu de
  `.incbin` dans kernel.bin).
- LBA 24-bit (8 GiB), écriture, asynchrone busy.

---

## [0.20.0] - 2026-05-08

### Sprint 2.m.1 — Première app asm "hello" standalone ✨

#### Added
- **`apps/hello/hello.s`** : source asm 65C816 mode N de la première
  app standalone d'OricOS. Code position-independent : `ldx #'Z' ;
  lda #$01 ; cop #$AA ; rtl`. Charge à `$BANK_APP:$0200`.
- **`apps/hello/hello.cfg`** : ld65 config flat binary, segment CODE
  loaded à `$0200`.
- **`apps/hello/Makefile`** : pipeline build app : `ca65` → `ld65` →
  `oricos-bundle.py` → `.oosobj`.
- **`tools/oricos-bundle.py`** : script Python qui wrappe un binaire
  flat dans un bundle OricOS Object v1 (header 8B + section CODE
  entry 8B + data). Usage : `oricos-bundle.py input.bin output.oosobj`.
- **`Makefile` racine** étendu : variable `APPS = hello`,
  build récursif des apps avant le kernel, dependency
  `$(KERNEL_O): ... $(APP_BUNDLES)` pour rebuild kernel quand un
  bundle change. `make clean` aussi récursif.
- **`kernel.s`** : `bundle_test` désormais via `.incbin
  "../apps/hello/build/hello.oosobj"` au lieu d'inline `.byte`. Le
  kernel embarque le bundle produit par le pipeline app externe.

#### Validation
- 501 tests OK (compteur inchangé — le test 'Z' à $BBAB passe avec
  la nouvelle source).
- Bundle généré : 23 bytes (8 header + 8 section entry + 7 code).
- Pipeline build complet : source asm app → binaire flat → bundle
  .oosobj → embedded dans kernel.bin → loaded par kernel_app_exec
  → exec en bank dédiée → syscall print.

#### Importance
- C'est le **premier exécutable userland OricOS** dont la source vit
  hors du kernel. Démontre la viabilité du pipeline d'apps tierces.
- Sprint 4 (userland C llvm-mos) reposera sur le même pipeline mais
  avec compilateur C → ld65 → oricos-bundle.

#### v0.2 (reportés)
- App avec sections multiples (CODE + DATA + ICON).
- App avec manifest (nom, version, auteur, args).
- 2e app de test (graphics demo, calculator).
- llvm-mos toolchain Sprint 4.

---

## [0.19.0] - 2026-05-08

### Sprint 2.l.1 — kernel_app_exec : LOADER COMPLET ✨

#### Added
- **`kernel_app_exec (DP_PTR)`** : orchestre l'exécution complète d'une
  app bundle. Pipeline :
  1. `kernel_bundle_validate` (magic + version).
  2. `kernel_bundle_find_code` (size + offset section CODE).
  3. `kernel_alloc_bank` → bank app dédiée.
  4. **Copy** section CODE de bundle vers `bank:0200` via DP indirect
     long (`[$18],Y` source, `[$1B],Y` dest, byte-by-byte).
  5. **Patch JSL self-modifying** : écrit `BUNDLE_APP_BANK` au byte 4
     de `app_exec_call` (instruction JSL al). Workaround ld65 :
     utilise `STA [dp]` long indirect car `STA al` sur label CODE
     génère bank=$00 par défaut.
  6. `jsr app_exec_call` → exécute JSL `$BANK:0200`.
- **`bundle_test`** refactor : section CODE = vraie app `ldx #'Z';
  lda #$01; cop #$AA; rtl` (7 bytes). Exécute en bank app via syscall
  SYS_PRINT_CHAR pour écrire 'Z' à l'écran.
- **`BUNDLE_APP_BANK`** ($01549F) : bank alloué pour app courante.

#### Validation
- Test d'intégration : ASSERT `mem[$00BBAB] = 'Z'` — l'app a écrit 'Z'
  via syscall depuis bank 7. ASSERT `mem[$01549F] = $07`.
- 501 tests OK.
- **Démo SDL2 visible** : "OricOS v0.7" + "YABZ" sur écran (Y kernel
  syscall + AB hex + **Z app loader**).
- Golden frame régénérée pour test visuel pixel-perfect.

#### Note technique
- ld65 ne distingue pas le bank d'un label dans un segment. `STA al`
  sur label = bank $00 par défaut. Workaround : init pointer 24-bit
  en DP zero page avec bank explicite ($01) puis `STA [dp]`.
- App tourne en mode N + M=1/X=1 préservés (cf. fix PH-bug-dp-indirect-Y
  bank1 sur P mode N qui rendait possible cop syscall propre).

#### v0.2 (reportés)
- Free bank app après exit (kernel_free_bank).
- Multi-section CODE+DATA+ICON+MANIFEST.
- App args via syscall (argc/argv).
- Sandbox bank-based — privilèges app (ADR-15 future).

---

## [0.18.0] - 2026-05-08

### Sprint 2.l.0 — kernel_bundle_find_code (parse sections)

#### Added
- **`kernel_bundle_find_code (DP_PTR)`** : parse les sections d'un
  bundle, trouve la section CODE. Retourne :
  - A = `BUNDLE_OK` ($00) si trouvée, `BUNDLE_ERR_NOT_FOUND` ($03) sinon.
  - `BUNDLE_FOUND_SIZE` ($015498, 16-bit) = taille section.
  - `BUNDLE_FOUND_OFFSET` ($01549A, 16-bit) = offset relatif au bundle.
- **Constantes** `BNL_HDR_SIZE=8`, `BNL_SEC_SIZE=8`, `BNL_SEC_TYPE/SZ_LO/
  SZ_HI/OFF_LO/OFF_HI`.
- **Test au boot** : `kernel_bundle_find_code` sur `bundle_test`.
  ASSERT côté Phosphoric : SIZE=$0002, OFFSET=$0010.

#### Notes implémentation
- `cpx` n'a pas de variant long-absolute (24-bit). Utilise tmp DP
  zero page `$15` pour stocker nsec et faire `cpx zp`.
- Boucle parcourt les sections jusqu'à TYPE=CODE ou nsec atteint.
- Calcul entry offset : `(X+1)*8` (= BNL_HDR_SIZE + X*BNL_SEC_SIZE
  pour valeurs 8/8). À généraliser quand HDR/SEC tailles changeront.

#### Validation
- 501 tests OK.

#### v0.1 (suite — OS-2.l.1)
- `kernel_app_exec (DP_PTR)` : validate + find_code + alloc_bank +
  copy code section vers `bank:0200` + JSL self-modifying.
- App test : bundle inline avec section CODE = `ldx #'Z'; lda #$01;
  cop #$AA; rtl`.

---

## [0.17.0] - 2026-05-08

### Sprint 2.k.1 finalisé — bug Phosphoric corrigé, validate fonctionnel

#### Fixed (côté Phosphoric, PH-bug-dp-indirect-Y-bank1)
- Bug majeur 65C816 mode N : COP/BRK/IRQ/NMI/PHP/PLP/RTI manipulaient
  P avec masque mode E qui en mode N corrompait les flags X/M (index
  width / accumulator width).
- Manifestation OricOS : `cop #$AA` syscall corrompait X (passait à
  16-bit) au RTI → `ldy #$00` du caller consommait 2 bytes d'imm →
  crash $00:0000.

#### Changed (OricOS)
- `kernel_bundle_validate` ré-activé au boot. Validate OK confirmé
  pour `bundle_test` inline. ASSERT côté Phosphoric : `mem[$01549C]=$00`.
- Tous les `[dp],Y` long indirects et opérations dépendantes de X/M
  fonctionnent désormais après COP/IRQ/NMI.

#### Tests
- 501 tests OK.
- Démo SDL2 toujours fonctionnelle.

---

## [0.16.0] - 2026-05-08

### Sprint 2.k.1 — Format bundle apps (ADR-08 v0.1 partiel)

#### Added
- **Spec format bundle "OOS\x01"** : header 8B (magic 4B + version 1B +
  flags 1B + num_sections 1B + reserved 1B) + section entries 8B
  (type, reserved, size 2B, offset 2B, reserved 2B) + section data.
  Types : CODE ($01), DATA ($02), ICON ($03), MANIFEST ($04).
- **Constantes** `BUNDLE_MAGIC_*`, `BUNDLE_VERSION`, `BUNDLE_SEC_*`,
  `BUNDLE_OK`/`BUNDLE_ERR_*`, offsets `BNL_*`.
- **`kernel_bundle_validate (DP_PTR)`** : code écrit (ldy/lda [dp],Y/
  cmp/bne/iny/rts). Vérifie magic + version, retourne A=$00 OK ou
  code erreur.
- **`bundle_test`** inline dans CODE segment : header + 1 section
  CODE 2 bytes (RTS RTS placeholder).

#### Known issue (OS-2.k.2 reportée)
- **Crash mystérieux** quand `kernel_bundle_validate` est appelé au
  boot du kernel : la routine n'arrive pas à terminer (CPU crash
  $00:0000). Hypothèse : bug subtil Phosphoric `lda [dp],Y` quand
  DP_PTR_BK = $01 et offset spécifique. Validate fonctionne à certaines
  positions, crash à d'autres. Print_string utilise le même opcode
  sans souci.
- **Tracé** dans BACKLOG : `PH-bug-dp-indirect-Y-bank1`. À investiguer
  via test unitaire isolé dans Phosphoric (test_cpu65c816_native.c).
- **Workaround temporaire** : `kernel_bundle_validate` non appelé
  au boot ; placeholder `lda #$00; sta BUNDLE_VALIDATE_RES`.

#### Validation
- 500 tests OK (compteur inchangé — le validate n'est pas testé
  fonctionnellement).
- Le code validate reste dans le kernel pour usage futur après fix bug.

#### v0.2 (reportés)
- Fix crash `[dp],Y` ou contournement via `[dp]` long indirect.
- `kernel_bundle_find_section (type)` : trouve section par type.
- `kernel_app_exec (DP_PTR)` : load + exec section CODE en bank dédiée.
- Test : un bundle test exec écrit char à l'écran via syscall.

---

## [0.15.0] - 2026-05-08

### Sprint 2.g.1 — Refactor scheduler vers TCB-based (ADR-14)

#### Added
- **ADR-14 ratifiée** : table fixe 16 TCBs en bank 1 $5C00 + bitmap free
  16 bits à $5B00. Layout TCB 20 octets (PID, STATE, PRIO, PARENT,
  saved_S, entry_pc, code_bank, data_bank, stack_bank, flags, name 8B).
- **Constantes TCB_*** : offsets champs, états (DEAD/READY/RUNNING/
  BLOCKED/ZOMBIE), alias TCB_1/TCB_2/TCB_1_S/TCB_2_S pour les 2
  premiers slots.
- **Init au boot** : bitmap `$07` (slot 0 invalide + TCB_1 + TCB_2).
  TCB_1 init RUNNING (task A), TCB_2 init READY (task B). Champs
  PID/STATE/PRIO/PARENT/PC/PB/DB tous initialisés. saved_S task B = $02F4.

#### Changed
- **`TASK_CUR`** sémantique : 0/1 → 1/2 (PID 1=task A, 2=task B).
- **Scheduler `do_switch`** refactor : sauve dans `TCB_1_S`/`TCB_2_S`
  au lieu de `TASK_A_S`/`TASK_B_S`. Met à jour les `STATE` des TCBs
  (READY ↔ RUNNING) à chaque swap.
- **Symboles `TASK_A_S`/`TASK_B_S`** retirés (remplacés par
  TCB_1_S/TCB_2_S).

#### Validation
- Test 2.a `test_oricos_sprint2a_via_t1_timer_drives_scheduler` : PASS.
- Test visuel `test_oricos_visual_matches_golden` : PASS pixel-identique
  au golden — preuve que le comportement est strictement préservé.
- 501 tests OK (compteur inchangé).

#### v0.2 (reportés)
- `kernel_task_create` dynamique (alloc PID via bitmap scan, init TCB
  depuis args, alloc stack page).
- `kernel_task_destroy` (set STATE=DEAD, clear bitmap bit).
- `kernel_task_yield` syscall.
- Scheduler avec priorité réelle (skip basse-prio si haute-prio READY).
- N tasks > 2 dans le test.

---

## [0.14.0] - 2026-05-08

### Sprint 2.i.1 — Modèle erreur kernel (panic + print_hex8)

#### Added
- **`kernel_panic` (A=code)** : stocke le code dans `PANIC_CODE`
  ($015495), affiche "PANIC <hex>" via `print_string`+`print_hex8`,
  puis STP. Remplace l'ancien `kernel_panic` stub (juste STP).
- **`kernel_print_hex8` (A=byte)** : écrit 2 chars hex (high/low nibble).
  Tail-call vers `kernel_print_nibble`.
- **`kernel_print_nibble` (A=0..15)** : écrit 1 char hex `0-9`/`A-F`,
  tail-call vers `kernel_print_char`.
- **`panic_msg`** : string "PANIC " ($00-terminée) en CODE segment.
- **Test au boot** : `lda #$AB; jsr kernel_print_hex8` après le syscall
  COP. Vérifie que `mem[$BBA9]='A'`, `mem[$BBAA]='B'`. Démo SDL2
  affiche "YAB" sur ligne 2.

#### Validation
- 498 tests OK.

#### v0.2 (reportés)
- **Log ring buffer** (256 bytes en bank 1) : `kernel_log_byte`,
  `kernel_log_str`. Lectur via syscall.
- **SYS_PANIC syscall** ($02) : userland peut déclencher panic via COP.
- **Stack trace** : trace les RTS jusqu'à kernel_entry au moment du panic.
- **Codes panic standardisés** : enum `PANIC_NULL_PTR`, `PANIC_STACK_OVF`,
  `PANIC_INVALID_SYSCALL`, `PANIC_BANK_EXHAUSTED`, etc.

---

## [0.13.0] - 2026-05-08

### Sprint 2.h.1 — Bank allocator avec free (LIFO list)

#### Added
- **Free list LIFO 16 entries** : `BANK_FREE_LIST` ($0154A0, 16 bytes)
  + `BANK_FREE_TOP` ($0154B0, count 0..16).
- **`kernel_alloc_bank` étendu** : pop free list si non vide, sinon
  bump (ancien comportement). Conserve la sémantique "0 = épuisé".
- **`kernel_free_bank`** (nouvelle routine) : push bank num sur free
  list, drop silencieux si pleine.

#### Validation
- Test au boot : alloc 3 ($04, $05, $06), free $05, alloc → doit
  retourner $05 (LIFO), pas $07 (bump). Stocké à `BANK_DEMO+3`.
- ASSERT côté test : `mem[$015463] = $05`.
- 498 tests OK.

#### v0.2 (reportés)
- Bitmap allocator (256 bits = 32 bytes) pour fragmentation arbitraire.
- Réservation explicite de banks (mark-as-used).
- Compteur de banks libres exposé via syscall (SYS_BANK_COUNT_FREE).

---

## [0.12.0] - 2026-05-08

### Cleanup — basculer vers opcodes natifs après fixes Phosphoric

#### Changed
- **`kernel_entry`** : `ldx #$FF; txs` (mode N + X=1, S=$00FF par bug
  perçu) → `lda #$01FF; tcs` (M=0). Stack désormais en page 1 standard
  $01FF — clarifié WDC §A.32 : SEP #$10 force X high=0, TXS copie X
  entier → S=$00:XL. Pour stack page 1, utiliser TCS.
- **`kernel_print_char`** : `STA [DP_PCPTR]` (long indirect $87 + bank
  explicite en DP+$0E) → `STA (DP_PCPTR)` (DP indirect $92, écrit à
  DBR:ptr). Code plus court, plus idiomatique. Possible suite à
  PH-fix-dp-indirect côté Phosphoric.

#### Fixed
- DP_PCPTR réduit de 24-bit à 16-bit (DP+$0C/$0D), bank fournie par DBR=0.

#### Tests
- 498 tests OK.

---

## [0.11.0] - 2026-05-08

### Sprint 2.f.1 — Mécanisme syscall COP (ADR-13 ratifiée)

#### Added
- **ADR-13 ratifiée** : OricOS expose ses services via `cop #$AA`
  (signature OricOS magic). Numéro de syscall en `A`, args en `X`/`Y`.
  Référence : GS/OS sur Apple IIgs.
- **Segment `COP_HANDLER`** dans `kernel.cfg` à `$5700` (bank 1).
- **`kernel_cop_handler`** (v0.1 minimal, dispatch hardcoded) :
  - `A=$01` (SYS_PRINT_CHAR) : `X` = char → call `kernel_print_char`.
  - Autres syscalls : ignored (rti immediat).
  - v0.2 : table de pointers indexée par A*2 (256 syscalls max).

#### Validation
- Test au boot kernel : `ldx #'Y'; lda #$01; cop #$AA` →
  test vérifie `mem[$BBA8] = 'Y'`.
- 494 tests OK.
- Démo SDL2 : "OricOS v0.7" sur ligne 1 + "Y" sur ligne 2 (résultat
  du syscall).

#### Note
- Phosphoric supporte déjà l'opcode COP en mode N (push PB+PC+P,
  clear PBR, vector $00FFE4). Trampoline bank 0 $0150 = JML $015700
  installé par main.c (`--kernel`) et par `test_oricos_boot.c`.

#### v0.2 (reportés)
- Table de dispatch (à la place du `cmp #$01`).
- Plus de syscalls (SYS_PRINT_STRING, SYS_KBD_GET, SYS_BANK_ALLOC).
- ABI versioning (utiliser le byte signature COP comme version).

---

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
