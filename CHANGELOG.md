# CHANGELOG - OricOS

All notable changes to the OricOS kernel project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).




## [Unreleased+scroll-wgrelh+windraw-determ] - 2026-05-27

### Fixed
- **`_wm_scroll_update` (wm.s) : corruption de course par l'IRQ** — `WG_RELX/Y/W/H`
  sont des scratch partagés avec l'IRQ (`kernel_wm_mouse_step`→redraw→`_wm_draw_widget_body`
  écrit `WG_RELH`). Un mouse IRQ corrompait la COURSE entre son calcul et le clamp →
  la value de l'ascenseur plafonnait à mi-course (~50 %, observé en interactif). Fix :
  section critique `sei`/`cli` autour du seul calcul (redraw hors-sei pour ne pas
  affamer le `cursor_blit` IRQ). `sei/cli` et non `php/plp` (éviter la désync `.smart`).
- **`task_wdraw` (alloc.s) : déterminisme de `test_oricos_win_draw`** — la tâche démo
  faisait `compose→SYS_EXIT` (ferme la fenêtre) → le pixel composité `$10A032=$FF`
  n'était que transitoire, rendant le test sensible au layout (PH-test-winflaky : un
  simple décalage de 2 octets le faisait faux-échouer). Fix : la tâche boucle
  `compose+SYS_YIELD` → fenêtre persistante, pixel = état STABLE → test robuste.
  (Le flux exit→close reste couvert par `test_oricos_win_app`.) 595 tests verts.

## [Unreleased+scroll-hang-fix] - 2026-05-27

### Fixed — GUI gelée après drag d'ascenseur au max
- **`kernel_event_push_mouse` (event.s) : coalescing des `MOUSE_MOVED`** — un drag
  de scrollbar long saturait le ring d'événements (16) de moves → le button-UP
  suivant était droppé → `SCROLL_DRAG_ID` restait armé → le WM restait bloqué en
  mode drag, avalant tout clic ultérieur → l'app ne répondait plus. Fix : si le
  dernier event en file est déjà un `MOUSE_MOVED`, on met à jour sa position en
  place au lieu d'en empiler un → la file ne sature plus, DOWN/UP toujours enfilés.
- **Collision ZP $6E** : `GFX_ARG4_LO` (blit byte_h, ajouté en 1.22.87) chevauchait
  `EVT_TMP` (scratch IRQ event-push). `GFX_ARG4` déplacé en `$92/$93`.

## [Unreleased+gpu-arg-race-fix] - 2026-05-27

### Fixed — OS-gpu-race : commandes GPU atomiques vs IRQ (option 2)
- Les 7 helpers GPU (`kernel_gfx_set_bpl`/`_clear`/`_fill_rect`/`_blit`/`_line`/
  `_text` dans gfx.s + `kernel_gfx_fill_rect16` dans wm.s) bracketés `php;sei …
  plp`. Un mouse IRQ ne peut plus clobber les registres ARG/CMD entre le setup
  et le TRIGGER d'une commande en cours (race latente révélée par l'instruction
  ADR-27). `php/plp` préserve le flag I (cli en syscall, sei en IRQ) et ne
  perturbe pas le tracking `.smart` (pas de rep/sep). Transparent — 594 verts.
- Pré-requis au flip backing store compact (ADR-27 opt.b, §0bis).

## [Unreleased+adr27-bpl-configurable] - 2026-05-27

### Added — ADR-27 opt.b : stride GPU configurable (SET_BPL)
- **`kernel_gfx_set_bpl`** (gfx.s) : émet `GPU_OP_SET_BPL` ($08) avec
  `GFX_BPL_LO/HI` (ZP `$90/$91`) → fixe la stride persistante du GPU. 0 → 512.
  `sep #$20` explicite en tête (8-bit), conforme M=X=1.
- Constantes `GPU_OP_SET_BPL = $08` et `GFX_BPL_LO/HI` (kernel.s).

### Fixed
- Régression `.smart` ca65 : helper sans `sep #$20` corrompait l'assemblage de
  `kernel_gfx_clear` (mode A 16-bit propagé) → échec compositeur (`win_draw`,
  `ctl_demo`). Fix : ancrage 8-bit explicite. Diagnostic via bisection (le code
  mort décalait/perturbait le tracking de mode lexical).

### Note
- Reste à faire (migration kernel ADR-27, < 50 %) : backing store compact +
  pose `bpl=byte_w` par fenêtre dans `kernel_wm_compose`, reset `bpl=0` avant
  `kernel_wm_redraw`. Le helper est en place mais pas encore câblé dans compose.

## [Unreleased+blit-v0.2-16bit] - 2026-05-27

### Fixed — GPU BLIT v0.2 : encodage 16-bit byte_w/byte_h (Bug A)
- **`kernel_wm_compose` (wm.s) : byte_w/byte_h tronqués à 8 bits** — après `lsr a`
  (16-bit), les stores étaient faits en `sep #$20` → seul l'octet bas était écrit.
  Fenêtres de ≥ 256 px largeur ou hauteur : contenu non composité (BLIT silencieux).
  Fix : stores 16-bit en `rep #$20` + `sta GFX_ARG3_LO` et `sta GFX_ARG4_LO`.
- **`kernel_gfx_blit` (gfx.s)** : ajout des writes GPU_ARG4_LO/MID/HI (byte_h).
- **`boot.s` : 3 appels BLIT ancienne convention** — byte_h migré vers GFX_ARG4_LO.

### Added
- ZP `GFX_ARG4_LO = $6E` et `GFX_ARG4_MID = $6F` (kernel.s, précédemment libres).

## [Unreleased+debug-gpu-toolbox-3bugs] - 2026-05-26

### Debug GPU toolbox kernel — 3 bugs supplémentaires

#### Fixed
- **`kernel_wm_compose` (wm.s) : Z-order ignoré → composite dans le mauvais ordre**
  Le compositor itérait les slots 0..WM_MAX-1 (ordre d'allocation) au lieu de
  WM_ZORDER (ordre fond→premier plan maintenu par le WM). Pour des fenêtres
  superposées, la fenêtre de premier plan pouvait être BLITtée AVANT celle
  d'arrière-plan, qui l'écrasait ensuite. Fix : itération sur WM_ZORDER[0..N-1]
  comme `_wm_draw_windows`. Slot id sauvegardé dans WCMP_XB avant overwrite par x/2.
  Branches hors-portée (>127 bytes) remplacées par `bcc/jmp wcmp_done` et `jmp wcmp_loop`.
- **`kernel_wm_compose` (wm.s) : fenêtres minimisées composées à tort**
  La condition ne vérifiait que `WM_F_USED` ; les fenêtres cachées/minimisées
  (`WM_F_VISIBLE` absent) étaient quand même BLITtées, affichant du contenu périmé.
  Fix : contrôle `(WM_F_USED | WM_F_VISIBLE)` identique à `_wm_draw_one`.
- **`kernel_gfx_fill_rect16` (wm.s) : poll loop manquant après GPU_TRIGGER**
  Seul helper GPU sans attente après déclenchement (tous les autres : clear, fill_rect,
  blit, line, text, text16 ont un poll loop). Latent v0.1 (GPU synchrone) mais critique
  pour v0.2 async : des commandes enchaînées sans poll risquent de se chevaucher.
  Fix : ajout du poll loop `ldx #0 / gfx_fr16_wait / lda GPU_STATUS_IO ...`
- **`sys_win_flush` (wm.s) : CURSOR_VALID non invalidé après BLIT**
  Après `kernel_wm_compose`, le framebuffer sous le curseur était modifié mais
  CURSOR_SAVE restait périmé. La prochaine `kernel_wm_cursor_restore` écrivait
  l'ancien fond (pré-flush) à la position du curseur, corrompant l'affichage si le
  curseur ne bougeait pas. Fix : `lda #0 / sta CURSOR_VALID` après le BLIT.

## [Unreleased+debug-wm-compose] - 2026-05-26

### Debug GPU toolbox kernel — Fix kernel_wm_compose (bug critique)

#### Fixed
- **`kernel_wm_compose` (wm.s) : BLIT destination erronée → affichage invisible**
  Bug critique dans la compositing loop du Window Manager. L'adresse SDRAM de
  destination du BLIT était calculée comme `y*512 + x/2` depuis la base `$000000`,
  alors que le framebuffer XVGA (ADR-20) est localisé à `$100000`. Conséquence :
  `SYS_WIN_FLUSH` ($14) ne produisait aucun affichage visible ; les backing stores
  des fenêtres étaient écrits dans une zone SDRAM non affichée par le compositor
  hardware.
  Fix : ajout de `clc / adc #$10` sur `GFX_ARG2_HI` (octet de poids fort de
  l'adresse 24-bit destination), immédiatement après le calcul `y*512 + x/2`.
  La destination est désormais `$100000 + y*512 + x/2` pour chaque fenêtre USED.
  Commentaires de la fonction corrigés (`$000000` → `$100000`).
- **Commentaire erroné dans `kernel_wm_redraw`** : le commentaire mentionnait
  `$000000` comme base framebuffer alors que le code utilisait déjà correctement
  `$100000`. Corrigé pour éviter toute confusion future.

## [Unreleased+SP-3.o-S7v2b-fix-corps] - 2026-05-26

### SP-3.o S.7 v2b — Fix régression : corps de fenêtre effacé au clic d'un contrôle

#### Fixed
- **Corps de fenêtre effacé (fond gris → bleu) au clic sur un contrôle** :
  régression introduite par v2. Le bloc de calcul de la **course** de la gouttière
  dans `_wm_scroll_update` opérait en mode 16-bit (`rep #$20` puis immédiats
  `sbc #SCROLL_THUMB_SZ` / `cmp #$0100`). Le tracking de mode A par ca65 générait
  du code corrompu (même classe de bug que SP-3.h `_crh_test_max`), ce qui
  effaçait le corps des fenêtres lors du full-redraw IRQ déclenché par le clic.
  Réécrit en **calcul 8-bit pur** (dimensions de gouttière ≤ 255 : lecture de
  l'octet bas de `+10`/`+8`, `sbc` 8-bit, clamp 8-bit comme la v1 — aucun `rep`/
  `sep` ni immédiat 16-bit). Diagnostic par dump du framebuffer XVGA `$100000` :
  corps intact + pouce atteignant le bas de la gouttière dans la fenêtre. 588 verts.

## [Unreleased+SP-3.o-S7v2-fixes] - 2026-05-26

### SP-3.o S.7 v2 — Fix 2 bugs P0 (critique senior widgets/windows)

#### Fixed
- **Ascenseur (scrollbar) bloqué à mi-course** : le pouce ne descendait jamais
  jusqu'en bas. `_wm_scroll_update` mappait la position souris vers `value` puis
  la clampait au **max logique** du contrôle (ex. 40), alors que la course réelle
  de la gouttière vaut `dimension − SCROLL_THUMB_SZ` (ex. `RELH 60 − 16 = 44`).
  Désormais `value` est clampée à la **course de la gouttière** (vertical : `RELH` ;
  horizontal : `RELW` ; moins l'épaisseur du pouce ; cap à 255, négatif→0). Le
  pouce parcourt toute la gouttière.
- **Curseur souris disparaissait** après un redraw ciblé (régression du
  `kernel_wm_redraw_widget` de S.7) : repeindre la zone d'un contrôle écrasait le
  curseur sans le redessiner et laissait son backing-store périmé. Nouveau
  `_wm_redraw_ctl` (`php`/`sei` ; `kernel_wm_redraw_widget` ;
  `kernel_wm_draw_cursor` qui invalide le backing et redessine ; `plp`/`rts`),
  appelé sur les 3 sites de redraw ciblé (drag ascenseur, `_wte_store` champ texte,
  `mlc_ctl_text` sur `MSG_CONTROL`). 588 verts.

## [Unreleased+SP-3.o-S7-redraw] - 2026-05-26

### SP-3.o S.7 — Redraw ciblé d'un contrôle (fix scintillement)

#### Fixed
- **Scintillement plein écran** au drag d'ascenseur et à l'édition de champ texte :
  `_wm_scroll_update` et `_wm_text_edit` (+ prise de focus `mlc_ctl_text`)
  appelaient `kernel_wm_redraw` (efface tout le desktop via `kernel_gfx_clear`
  puis repeint icônes + toutes les fenêtres + widgets) à **chaque** événement
  souris/clavier → flash visible plein écran.

#### Changed
- **`kernel_wm_redraw_widget` (A = index widget)** : nouveau point d'entrée qui
  repeint **uniquement** la zone du contrôle visé (le contrôle repeint
  entièrement sa propre région : track+thumb pour un ascenseur, box+texte+curseur
  pour un champ, etc.). Refactor de la boucle de dessin : le corps par-widget de
  `_wm_draw_widgets_for_slot` est extrait en `_wm_draw_widget_body` (réutilisé par
  la boucle complète ET par le redraw ciblé). Comportement inchangé (584 verts).

## [Unreleased+Sprint4-clock] - 2026-05-26

### Sprint 4 — Première vraie app userland C : clock

#### Added
- **App C `clock`** (`apps/clock/clock.c`) : première vraie app userland pilotée
  par le temps. Crée une fenêtre puis, tous les `STEP_TICKS` ticks scheduler
  (lus via `SYS_GET_TICKS`, mesure non signée wrap-safe, CPU cédé via `SYS_YIELD`),
  dessine une barre de progression croissante (`SYS_GFX_FILL_RECT` + `SYS_WIN_FLUSH`).
  Sort après `N_STEPS` pas. Valide get_ticks + yield + dessin fenêtré en C.
- **`SYS_GET_TICKS` ($1D)** : nouveau syscall — renvoie `TICK_COUNTER` (compteur
  8-bit libre incrémenté par l'IRQ timer, wrap à 256). Slot d'extension v1 réservé
  par ADR-17 ($13-$3F). SDK : `oricos_get_ticks()` (clobbers a/x/y — le COP ne
  préserve pas X/Y, cf. `kernel_cop_handler`).
- Bundle `bundle_clock` + spawn gardé `TC_CLOCKAPP_FLAG` ($01EE50) + `clock` au Makefile.

## [Unreleased+SP-3.o-S6] - 2026-05-26

### SP-3.o S.6 — Démo C contrôles déclaratifs (capstone, arc SP-3.o CLOS)

#### Added
- **App C `ctl_demo`** (`apps/ctl_demo/ctl.c`) : déclare une fenêtre + checkbox +
  ascenseur vertical + champ texte via une table GenUI inline, tourne le MainLoop,
  et sur chaque `MSG_CONTROL` lit la valeur du contrôle touché (`SYS_CTL_GET_VALUE`)
  et l'imprime. `MSG_CLOSE` → sortie. Capstone de l'arc SP-3.o (contrôles
  GeoWorks : déclaration + messages + lecture de valeur depuis userland C).
- Bundle `bundle_ctl` + spawn gardé `TC_CTLAPP_FLAG` ($01EE40) + `ctl_demo` au Makefile.

#### Changed
- **Segment `BUNDLES`** (kernel.cfg, $7000+) : les images d'apps `.incbin`
  (hello/hello_c/win/gui/view/ctl) sortent du segment CODE vers ce segment haut,
  au-dessus de toutes les données runtime. Motif : le CODE approchait son plafond
  $5400 (données `TICK_COUNTER`) ; les bundles (~6 Ko) le saturaient. CODE
  redescend de $5233 à ~$4327 (~3,8 Ko de marge regagnée) ; BUNDLES a de la place
  jusqu'à $E1FF. Chaque module repasse en `.segment "CODE"` après console.s.

## [Unreleased+SP-3.o-S5] - 2026-05-26

### SP-3.o S.5 — Tags GenUI déclaratifs des contrôles

#### Added
- **Tags `GU_CHECK`($05)/`GU_SCROLL_V`($06)/`GU_SCROLL_H`($07)/`GU_RADIO`($08)/
  `GU_TEXT`($09)** dans `sys_ui_define` : les contrôles valeur/saisie sont
  désormais déclarables dans une table GenUI (comme `GU_BUTTON`/`GU_VIEW`).
  Format : rect (relx16 rely16 relw16 relh16) + extra (value/max/group/maxlen 8 o).
- Helpers **`_sud_rect`** (lit le rect 8 o → WM_ARG_*) et **`_sud_attach`**
  (attache le widget à DLG_WIN si valide) pour factoriser les handlers (compacité).
- **`task_genui`** (gated `TC_GENUI_FLAG` $01EE30) : déclare fenêtre + checkbox +
  radio + ascenseur V + champ texte via une table GenUI bank 1. Id du 1er
  contrôle exposé en `TASK_GENUI_ID` ($015462).
- **SDK** : defines `GU_CHECK`/`GU_SCROLL_V`/`GU_SCROLL_H`/`GU_RADIO`/`GU_TEXT`.

#### Deferred
- `GU_LIST` : nécessite un pointeur vers le blob d'items, qui réside dans la bank
  de l'app (pas bank 1) → mécanisme de copie à concevoir. Reporté.

## [Unreleased+SP-3.o-S4c] - 2026-05-26

### SP-3.o S.4c — Liste sélectionnable (GenList)

#### Added
- **`WG_TYPE_LIST`** ($08) : liste d'items. `strptr`(+12/13) = blob d'items
  (slots de `LIST_ITEM_STRIDE`=8 o, null-term), `selected`(+14)/`count`(+15).
- **`kernel_tk_list`** : face lightgray + cadre + 1 ligne par item (hauteur
  `LIST_ITEM_H`=16), la ligne sélectionnée a un fond lightblue.
- **`kernel_ctl_list_select`** : `row = (MOUSE_Y - abs_y) / 16`, clampé à
  `[0, count-1]` ; stocke `selected`(+14) + redraw. Dispatch clic `mlc_ctl_list`
  (MainLoop) + `_iac_list` (desktop IRQ). Hit-test + dessin étendus à `WG_TYPE_LIST`.
- **`task_list`** (gated `TC_LIST_FLAG` $01EE20) : fenêtre + liste 3 items
  (blob `list_demo_items`) + MainLoop. Id exposé en `TASK_LIST_ID` ($015461).

#### Fixed
- **Collision layout** : le segment CODE avait grandi au-delà de `$5000` (toolkit
  widgets accumulés S.1→S.4) et écrasait `SENTINEL_BASE`/`VERSION_BASE` (données
  runtime à `$015000`/`$015010`) → corruption (crash scheduler après quelques
  ticks, MainLoop muet). Relocalisés en `$016300`/`$016310` (zone RAM haute
  libre, au-dessus de FS et de la région TEXT). La plus basse donnée est
  désormais `TICK_COUNTER` ($015400) = plafond effectif du CODE.

## [Unreleased+SP-3.o-S4b] - 2026-05-26

### SP-3.o S.4b — Champ texte éditable (GenText/LineEdit)

#### Added
- **`WG_TYPE_TEXT`** ($07) : champ texte éditable. Chaque widget TEXT a un buffer
  16 octets en bank 1 (`TEXT_BUFS`+id*16, câblé auto par `kernel_wm_add_widget`
  car `TEXT_BUF_SZ == WIDGET_ENTSZ`), `length`(+14) / `maxlen`(+15, défaut 14).
- **Focus clavier** : `TEXT_FOCUS_ID` ($FF=aucun, init dans `kernel_event_init`).
  Clic sur un champ → `mlc_ctl_text`/`_iac_text` posent le focus + redraw (curseur).
- **Édition** : `mlc_key` route les touches vers `_wm_text_edit` quand un champ est
  focalisé (l'app reçoit `MSG_CONTROL`+id au lieu de `MSG_KEY`). `_wm_text_edit` :
  caractère imprimable ($20-$7E) ajouté si length<maxlen, backspace ($08/$7F)
  retire le dernier ; pointeur 24-bit `DP_PTR`=$01:buffer pour écrire (`sta [DP_PTR],y`).
- **Rendu** `kernel_tk_text_field` : face blanche + cadre darkgray + texte noir
  (buffer) + curseur (barre noire 2px) après le texte si le champ a le focus.
- Hit-test `_wm_widget_hit` + dispatch dessin `_wdws_draw` étendus à `WG_TYPE_TEXT`.
- **`task_text`** (gated `TC_TEXT_FLAG` $01EE10) : fenêtre + champ texte rel(12,14,
  110,20) maxlen=14 + MainLoop. Id exposé en `TASK_TEXT_ID` ($015460).

## [Unreleased+SP-3.o-S4a] - 2026-05-26

### SP-3.o S.4a — Radios mutuellement exclusifs (GenItemGroup)

#### Added
- **`WG_TYPE_RADIO`** ($06) : radio (GenItemGroup). Réutilise le champ +14/+15
  du record widget comme `selected`(+14, 0/1) et `group id`(+15). Rendu = case
  colorée (lightblue sélectionné / lightgray non), comme la checkbox.
- **`kernel_ctl_radio_select`** (A=id) : lit le group id du radio cliqué,
  désélectionne tous les autres radios du même groupe (value=0, couleur décochée),
  puis sélectionne le cliqué (value=1, couleur cochée) et repeint.
- Dispatch clic : `mlc_control` (chemin MainLoop) + `_iac_go` (chemin desktop
  IRQ) → `RADIO` → `kernel_ctl_radio_select`. Hit-test `_wm_widget_hit` +
  dispatch dessin `_wdws_draw` étendus à `WG_TYPE_RADIO` (rendu comme bouton).
- **`task_radio`** (gated `TC_RAD_FLAG` $01EE00) : crée une fenêtre + 2 radios
  du même groupe (radio 0 sélectionné au départ) puis boucle MainLoop. Ids
  exposés en `TASK_RAD_ID0`/`TASK_RAD_ID1` ($01545E/$01545F) pour le test.

## [Unreleased+SP-3.o-S3c] - 2026-05-26

### SP-3.o S.3c — GenView déclaratif + démo C

#### Added
- **Tag `GU_VIEW`** ($04) dans `sys_ui_define` : un GenView peut être déclaré
  dans une table GenUI (`GU_VIEW` relx16 rely16 relw16 relh16 max8). `sud_view`
  lit le rect + le max scroll, crée un widget `WG_TYPE_VIEW` (scroll_y=0 en +14,
  max en +15) attaché à la fenêtre courante. Miroir de `sud_button` sans label.
- **App C `view_demo`** (`apps/view_demo/view.c`) : déclare une fenêtre + un
  `GU_VIEW`, boucle MainLoop ; sur `MSG_CONTROL` lit l'offset `scroll_y` via
  `SYS_CTL_GET_VALUE` et l'imprime ("view: scroll NN"). `MSG_CLOSE` → sortie.
  Modèle GeoWorks : le système gère barre/offset, l'app lit et réagit.
- **SDK** : `oricos_ctl_get_value(id)` (SYS_CTL_GET_VALUE $1B) +
  `oricos_msg_id()` (lit le bloc ZP $DA = id du contrôle/fenêtre du dernier
  message). Defines `GU_VIEW`, `SYS_CTL_GET_VALUE`, `SYS_CTL_SET_VALUE`.
- Bundle `bundle_view` (console.s) + spawn gardé `TC_VIEWAPP_FLAG` ($01EFF0,
  boot.s) + `view_demo` dans la liste APPS du Makefile.

## [Unreleased+SP-3.o-S3] - 2026-05-26

### SP-3.o S.3 — GenView (viewport scrollable managé)

#### Added
- **`WG_TYPE_VIEW`** : GenView = viewport + scrollbar **intégré** (bord droit).
  scroll_y(+14)/max(+15). Rendu `kernel_tk_view` : corps (lightgray) + gouttière
  (darkgray, bord droit `VIEW_SB_W`=12) + thumb (blanc) à `scroll_y`.
- **Drag du view** : `mlc_control` traite VIEW comme un scroll vertical (réutilise
  `SCROLL_DRAG_ID` + `_wm_scroll_update`) → `scroll_y = clamp(souris - haut viewport,
  0, max)` → `MSG_CONTROL`. L'app lit `scroll_y` via `SYS_CTL_GET_VALUE` et redessine
  son contenu décalé (modèle GeoWorks : le système scrolle, l'app peint).
- **`task_view`** (gated TC_VIEW_FLAG) : crée sa fenêtre + un GenView + boucle MainLoop.

Validé : `test_oricos_genview` — clic à y=234 (scroll_y=20) puis drag à y=244
(scroll_y=30, le scroll suit). 577 tests verts. Reste S.3c (tag GU_VIEW déclaratif
+ démo C qui redessine son contenu) ; thumb proportionnel = polish.

## [Unreleased+SP-3.o-S2] - 2026-05-26

### SP-3.o S.2 — ascenseurs (scrollbars V/H) + thumb-drag

#### Added
- **`WG_TYPE_SCROLL_V`/`_H`** : ascenseurs. value(+14)/max(+15). Rendu
  `kernel_tk_scrollbar` (gouttière darkgray + thumb blanc positionné à `value`
  le long de la gouttière), dispatché dans `_wm_draw_widgets_for_slot`.
- **Thumb-drag dans le MainLoop** : `SCROLL_DRAG_ID` (état entre appels) ;
  `_ml_classify` — clic sur scrollbar (`mlc_ctl_scroll`) arme le drag + pose la
  value ; `EV_MOUSE_MOVED` met à jour la value ; `EV_MOUSE_UP` termine. value =
  `clamp(souris - début gouttière, 0, max)` (`_wm_scroll_update`) → `MSG_CONTROL`.
- **`task_scr`** (gated TC_SCR_FLAG) : scrollbar V + boucle MainLoop.

#### Fixed
- **Conflit drag fenêtre ↔ contrôle** : `wm_step_arm_drag` teste désormais le
  widget AVANT d'armer le drag de fenêtre. Un clic sur un contrôle (scrollbar,
  bouton, checkbox) **n'arme plus** le drag de fenêtre (sinon draguer un thumb
  déplaçait toute la fenêtre, figeant la value).

Validé : `test_oricos_scrollbar` — clic à y=140 (value=26) puis drag à y=130
(value=16, la value suit la souris). 576 tests verts. Suite : S.3 GenView.

## [Unreleased+SP-3.o-S1] - 2026-05-26

### SP-3.o S.1 — API valeur de contrôle + checkbox (GenBoolean)

#### Added
- **`SYS_CTL_GET_VALUE` ($1B)** (X=id → A=value, $FF si id invalide) +
  **`SYS_CTL_SET_VALUE` ($1C)** (X=id, Y=value). API de valeur des contrôles —
  débloque checkbox + futurs ascenseurs/sliders.
- **`WG_TYPE_CHECK`** ($02, GenBoolean) : value stockée en `+14` du record widget
  (réutilise le champ callback — exclusif du bouton). `kernel_ctl_toggle`
  (bascule value + couleur lightblue/lightgray + redraw).
- **`_wm_widget_hit`** matche désormais CHECK ; **`_iac_go` dispatche par type**
  (BUTTON→callback, CHECK→toggle) — garde indispensable : un clic checkbox ne
  jsr plus la value comme un callback (anti-crash). `_ml_classify` (MainLoop)
  bascule la checkbox avant `MSG_CONTROL`.
- **`task_chk`** (gated TC_CHK_FLAG) : crée une checkbox + round-trip SET/GET value.

Validé : `test_oricos_ctl_value` — SET_VALUE(1)+GET_VALUE→1. 575 tests verts.
Suite SP-3.o : S.2 ascenseurs, S.3 GenView, S.4 radios/texte/liste.

## [Unreleased+SP-3.n-polish] - 2026-05-26

### SP-3.n polish — titres + libellés de boutons

#### Changed
- **GenUI chaînes INLINE** : `GU_TITLE`/`GU_BUTTON` portent désormais une chaîne
  null-terminée INLINE dans la table (plus de pointeur — trivial en C, évite de
  splitter une adresse dans un initialiseur const). `sys_ui_define` les stage en
  bank 1 (`UI_STR_BUF` $015580, gap après NMI_HANDLER) via `_sud_copy_inline` →
  le rendu titre/label (qui lit en bank 1) les trouve. v1 : 1 label persistant à
  la fois (réutilisé après upload du titre en SDRAM).
- **Libellés distincts dialogue/alerte** : `_ddb_add_button` prend le label via
  DP_PCPTR (posé par l'appelant). DoDlgBox : "OK"/"Cancel". SYS_ALERT : "OK"
  (OK/OK-Cancel) ou "Yes"/"No" (Yes-No) — plus de boutons tous nommés "OK".
- **`apps/gui_demo`** : titre "Demo C" + bouton "Clic" (déclarés inline) →
  visibles à l'écran (titlebar, bouton, taskbar "Demo C").

Branches `bra`→`jmp` (routines agrandies). 574 tests verts. Vérifié au screenshot
XVGA (`--gui-demo`) : titre et libellé affichés.

## [Unreleased+SP-3.n-G7b] - 2026-05-26

### SP-3.n G.7 (suite) — démo gui_demo visible

#### Changed
- **`sys_ui_define`** : repeint le desktop (`kernel_wm_redraw`) après création de
  la fenêtre déclarée → l'UI apparaît immédiatement (sans attendre un événement
  souris). Indispensable pour voir la fenêtre du gui_demo au lancement.
- **`apps/gui_demo/gui.c`** : fenêtre repositionnée en (420,420,170,110), bouton
  rel(20,50,90,24) — zone vide du desktop → fenêtre nettement distincte des
  fenêtres boot (OricOS/Editor). Taskbar : 3e entrée "Win2" (focus).

Côté Phosphoric : nouvelle option `--gui-demo` (pose TC_GUIAPP_FLAG) pour lancer
l'app depuis la CLI : `./oric1-emu --kernel build/kernel.bin --xvga --gui-demo`.

## [Unreleased+SP-3.n-G7] - 2026-05-26

### SP-3.n G.7 — app C GUI déclarative + MainLoop (arc SP-3.n CLOS)

#### Added
- **`apps/gui_demo/gui.c`** : app userland C qui **déclare** son UI (table GenUI :
  fenêtre + bouton) via `oricos_ui_define`, puis tourne une **boucle MainLoop**
  (`oricos_main_loop`) et réagit aux **messages** : `MSG_CONTROL` (bouton cliqué →
  imprime "gui: bouton"), `MSG_CLOSE` (sort). Bundle `bundle_gui` (console.s),
  spawné par `TC_GUIAPP_FLAG` ($01EFB0). Aucune coord XVGA, aucun callback.
- **`sys_ui_define` refondu (G.7a)** : `GU_WINDOW` crée la fenêtre immédiatement
  (handle dans `DLG_WIN`), `GU_TITLE` (avant `GU_WINDOW`) pose le titre, **nouveau
  `GU_BUTTON`** ($03 : relx16 rely16 relw16 relh16) attache un bouton enfant.
  Branches converties en `jmp` (routine agrandie). `genui_demo` réordonné.
- **SDK `oricos.h`** : `oricos_ui_define` / `oricos_main_loop` / `oricos_alert` /
  `oricos_do_dlgbox` (ptr table 24-bit via `phk`/`pla` → bank de l'app) ; defines
  `SYS_*` ($15-$1A), `MSG_*`, `GU_*`, `ALERT_*`.

Validé : `test_oricos_gui_demo` — l'app C déclare fenêtre+bouton, clic bouton →
"gui: bouton" (MSG_CONTROL), clic case fermeture → "gui: sortie" (MSG_CLOSE).
**Arc SP-3.n (G.1→G.7) CLOS. 574 tests verts.**

## [Unreleased+SP-3.n-G6] - 2026-05-26

### SP-3.n G.6 — SYS_ALERT : alertes pré-câblées

#### Added
- **`sys_alert` ($1A)** (wm.s) : alerte pré-câblée selon le type en X
  (`ALERT_OK`=0 / `ALERT_OKCANCEL`=1 / `ALERT_YESNO`=2). Crée une fenêtre modale
  fixe (280,260,180,70) + 1 ou 2 boutons, puis **réutilise la boucle modale de
  DoDlgBox** (`jmp ddb_show`) → retour A = 1 (gauche : OK/Yes) / 0 (droite :
  Cancel/No). `TASK_ALERT_RES`/`TC_ALERT_FLAG` ($01EFA0). Table dispatch : $1A.
- **`task_alert`** (alloc.s, gated TC_ALERT_FLAG) : alerte OK-Cancel de test.

v1 : pas de texte de message (label cosmétique reporté) ; libellés boutons "OK".
Validé : `test_oricos_alert` — clic OK (alerte OK-Cancel) → retour 1 + fermeture
(`WM_MODAL`=$FF). 573 tests verts. Reste SP-3.n : G.7 (démo C fenêtrée).

## [Unreleased+SP-3.n-G5] - 2026-05-26

### SP-3.n G.5 — SYS_DO_DLGBOX : dialogue modal (command table, GEOS)

#### Added
- **`sys_do_dlgbox` ($19)** (wm.s) : modèle GEOS — l'app passe une **command
  table** (`DB_POSITION x16 y16 w16 h16` / `DB_OK` / `DB_CANCEL` / `DB_END`) ; le
  kernel crée une fenêtre **modale** (`WM_MODAL`) + les boutons (auto-positionnés),
  exécute une **boucle modale** et rend A = 1 (OK) / 0 (Cancel). **UI-modal** : la
  saisie va au dialogue ; la tâche appelante **bloque et rend le CPU** (les autres
  tâches continuent — préemption préservée). Helper `_ddb_add_button`.
- **`kernel_event_wait`** (event.s) : helper réutilisable — bloque la tâche
  jusqu'à un événement (block/wake ADR-25, sans le pop), spin+WAI en boot-context.
- **`kernel.s`** : tags `DB_*`, état `DLG_WIN`/`DLG_OK_ID`/`DLG_CANCEL_ID`/
  `DLG_RESULT` ($015925+), sentinelle `TASK_DLG_RES`, `TC_DLG_FLAG` ($01EF90).
  Table dispatch : $19 câblé (`.repeat 38`).
- **`task_dlg`** (alloc.s, gated TC_DLG_FLAG) + command table `db_demo`.

Choix de conception (cf. réponse humain) : **UI-modal** (réutilise `WM_MODAL`,
comportement GEOS) ; task-modal (autres fenêtres interactives) parqué v2.
Validé : `test_oricos_dlgbox` — clic OK → retour 1 + dialogue fermé (`WM_MODAL`
=$FF). 572 tests verts. Reste SP-3.n : G.6 (`SYS_ALERT`), G.7 (démo C).

## [Unreleased+SP-3.n-G4] - 2026-05-26

### SP-3.n G.4 — contrôles → MSG_CONTROL

#### Added
- **`_ml_classify` étendu** : après le chrome, un clic qui touche un contrôle
  (bouton) de la fenêtre (`_wm_widget_hit` → `WIDGET_ACTIVE` != $FF) → `MSG_CONTROL`
  + id du contrôle (index widget) en $DA. L'app réagit au contrôle via son
  MainLoop (le callback kernel `_wm_invoke_active_cb` reste en coexistence v1).

Validé : `test_oricos_mainloop_control` — clic sur le bouton "OK" de la fenêtre 0
(boot, rel 6,34,44×18) en mode app-driven → MSG_CONTROL + id widget. 571 tests
verts. Reste SP-3.n : G.5 (`SYS_DO_DLGBOX`), G.6 (`SYS_ALERT`), G.7 (démo C).
NB : les contrôles déclarés dans la table GenUI (tag `GU_BUTTON`) sont reportés
à G.7 (l'app C déclarera son UI complète).

## [Unreleased+SP-3.n-G3c] - 2026-05-26

### SP-3.n G.3c — chrome → messages (MSG_CLOSE / MSG_MENU) ; G.3 complet

#### Added
- **`_ml_classify` étendu** : un clic dans la barre de menu (`where_y < MENU_BAR_H`)
  → `MSG_MENU` ; un clic sur la case fermeture d'une fenêtre (`_wm_chrome_hit`==1)
  → `MSG_CLOSE` + id fenêtre en $DA ; sinon `MSG_CONTENT`.
- **`WM_APP_DRIVEN`** ($015924) : posé à $A5 par `sys_main_loop` (une app pilote
  la boucle). En mode app-driven, `wm_step_chrome_close` **ne ferme plus** la
  fenêtre — l'app reçoit `MSG_CLOSE` et décide (modèle GeoWorks « l'app décide »).
  Sinon (desktop sans app, ex. `test_wm_close_button`) : auto-close conservé.

Validé : `test_oricos_mainloop_close` (clic close-box app-driven → MSG_CLOSE +
fenêtre RESTE ouverte), `test_oricos_mainloop_menu` (clic barre de menu →
MSG_MENU). **Arc G.3 (a/b/c) complet. 570 tests verts.** Reste SP-3.n : G.4
(contrôles→MSG_CONTROL), G.5/G.6 (DoDlgBox/Alert), G.7 (démo C).

## [Unreleased+SP-3.n-G3b] - 2026-05-26

### SP-3.n G.3b — SYS_UI_DEFINE : UI déclarative (table GenUI)

#### Added
- **`sys_ui_define` ($18)** (wm.s) : modèle déclaratif GeoWorks — l'app passe un
  pointer 24-bit ($D0-$D2) vers une **table GenUI** (flux de tags) ; le kernel la
  parse via `lda [$D0],y` et crée la fenêtre par `kernel_wm_add`. Tags v1 :
  `GU_WINDOW` (x16 y16 w16 h16), `GU_TITLE` (ptr16 bank 1), `GU_END`. Retour :
  A = handle ou $FF ; la fenêtre prend le focus. Les contrôles déclarés (G.4).
- **`kernel.s`** : tags `GU_*`, sentinelle `TASK_UI_HANDLE`, `TC_UI_FLAG` ($01EF80).
  Table dispatch : $18 câblé (`.repeat 39`).
- **`task_ui`** (alloc.s, gated TC_UI_FLAG) + table `genui_demo` (fenêtre
  300,200,120,90 + titre "UI").

#### Fixed
- **`_ml_classify` (G.3a) — race WM_ARG_X/Y** : `WM_ARG_*` est partagé avec l'IRQ
  souris ; un event souris pouvait clobber les coords entre l'écriture et le
  hit-test → MSG_CONTENT manqué. Encadré par `php/sei … plp` (ADR-25
  Disable/Enable : section critique courte RMW partagée avec un handler).

Validé : `test_oricos_ui_define` — la table GenUI crée la fenêtre déclarée
(handle valide, WM_TABLE[handle].x == 300). 568 tests verts.

## [Unreleased+SP-3.n-G3a] - 2026-05-26

### SP-3.n G.3a — SYS_MAIN_LOOP : événements bruts → messages sémantiques

#### Added
- **`sys_main_loop` ($17)** (wm.s) : modèle GeoWorks — bloque jusqu'à un
  **message** significatif en consommant les événements bruts de la file et en
  les traduisant via `_ml_classify` : `EV_KEY_DOWN`→`MSG_KEY` (keycode en $D1),
  `EV_MOUSE_DOWN`→`MSG_CONTENT` (hit-test `kernel_wm_hit_test` → id fenêtre en
  $DA), moved/up→`MSG_NULL` (sautés, boucle). Blocage réel via block/wake
  (`EVENT_WAITER`, réveil IRQ). Détails dans le bloc ZP $D0-$DF.
- **`kernel.s`** : constantes `MSG_*`, sentinelles `TASK_ML_MSG`/`TASK_ML_DETAIL`,
  `TC_ML_FLAG` ($01EF70). Table dispatch : $17 câblé (`.repeat 40`).
- **`task_ml`** (alloc.s, gated TC_ML_FLAG) : consomme un message MainLoop.

`kernel_wm_mouse_step` (IRQ) **inchangé** : focus/drag restent des comportements
WM automatiques ; le MainLoop ne fait qu'ajouter une couche de traduction
sémantique pour l'app (additif, pas de migration des comportements WM). Validé :
`test_oricos_mainloop_message` — move (sauté) puis clic fenêtre → MSG_CONTENT +
id valide. 567 tests verts.

## [Unreleased+SP-3.n-G2] - 2026-05-26

### SP-3.n G.2 — SYS_GET_NEXT_EVENT + SYS_EVENT_AVAIL (Event Manager)

#### Added
- **`sys_event_avail` ($15)** : non-bloquant, A = 1 si la file contient un
  événement, 0 sinon.
- **`sys_get_next_event` ($16)** : extrait le prochain événement (A = what,
  record 10 o copié dans le bloc ZP $D0-$D9). **Bloquant** si la file est vide
  (block/wake ADR-25, calqué sur `sys_read_char`) : `EVENT_WAITER` ($015923)
  enregistre la tâche en attente, réveillée par l'IRQ via `kernel_event_wake`.
- **`kernel_event_wake`** (event.s) : appelé par l'IRQ handler après le post
  des événements ; passe `EVENT_WAITER` READY si la file est non vide (pas
  d'éligibilité focus — file globale du MainLoop).
- **`task_evt`** (alloc.s, gated `TC_EVT_FLAG` $01EF60) : tâche de test qui
  bloque sur SYS_GET_NEXT_EVENT, stocke what/message puis sort.
- **`kernel.s`** : `EVENT_WAITER`, `TASK_EVT_WHAT`/`TASK_EVT_MSG` (sentinelles),
  `TC_EVT_FLAG`. Table dispatch : $15/$16 câblés (`.repeat 41`).

Mono-waiter v1 (cohérent KBD_WAITER ; signaux multi-bits = polish #1). Validé :
`test_oricos_event_syscall` — task_evt bloque, reçoit la touche 'B' par IRQ →
EV_KEY_DOWN, message 'B'. 566 tests verts.

## [Unreleased+SP-3.n-G1] - 2026-05-26

### SP-3.n G.1 — file d'événements unifiée (ADR-26 draft, modèle GeoWorks)

#### Added
- **`kernel/modules/event.s`** : file d'événements bank 1 (`EVENT_RING` $015880,
  16 entrées × 10 octets : what/message/mods/where_x16/where_y16/when).
  `kernel_event_init`, `kernel_event_push_key` (A=keycode → EV_KEY_DOWN, mods=
  KBD2_MOD, where=souris), `kernel_event_push_mouse` (A=type, mods=boutons),
  `kernel_event_pop` (copie le record en tête vers le bloc ZP $D0, base de
  SYS_MAIN_LOOP G.2). Helpers `_evt_tail_offset` (×10), `_evt_advance_tail`,
  `_evt_fill_where_when`.
- **`kernel.s`** : constantes `EVENT_*`/`EVT_*`/`EV_*` + `EVT_TMP`=$6E (scratch ZP
  IRQ-only) + 2 `.assert` anti-recouvrement (logé dans le trou $015873-$01592F de
  la région charset morte, avant `MOUSE_X`).

#### Changed
- **Migration PROGRESSIVE** (coexistence — aucun consommateur actuel modifié) :
  `kernel_kbd_poll` (kbd.s) pousse chaque touche dans `KBD_RING` **et** poste un
  EV_KEY_DOWN ; l'IRQ MOU2 (handlers.s) appelle `kernel_wm_mouse_step` **et**
  poste EV_MOUSE_DOWN/UP/MOVED (edge-detect bouton gauche). `boot.s` :
  `kernel_event_init` à l'init.

Sûreté concurrence : push appelé uniquement depuis l'IRQ (I=1, pas de nesting) ;
`EVT_TMP` dédié IRQ-only ; ZP basse ($00-$88) disjointe de la ZP app llvm-mos
($89-$CF) → l'IRQ ne corrompt pas l'app courante. Validé : `test_oricos_event_queue`
(touche 'A' → EV_KEY_DOWN ; clic (250,150) → événement souris). 565 tests verts.

## [Unreleased+SP-3.m-G6] - 2026-05-25

### SP-3.m G.6 — app C démo fenêtrée (arc SP-3.m clos)

#### Added
- **`apps/win_hello/win.c` + Makefile** : première app userland C **fenêtrée**
  (llvm-mos, target mos-oricos). Crée sa fenêtre, dessine en coords locales,
  flush, lit le clavier au focus, sort. Bundle embarqué `bundle_win` (console.s),
  spawné par `TC_WINAPP_FLAG` ($01EF50) via `kernel_app_spawn`.
- **`tools/oricos-sdk/include/oricos.h`** : helpers `oricos_win_create(x,y,w,h)`
  (args via $D0-$D7, retourne handle), `oricos_gfx_fill_rect(x,y,w,h,color)`
  (args via ZP gfx $73-$78), `oricos_win_flush()`. Defines `SYS_WIN_CREATE`
  ($13), `SYS_WIN_FLUSH` ($14).
- **`sys_win_flush` ($14)** : nouveau syscall → `kernel_wm_compose` (permet à une
  app de rendre son dessin visible sans connaître l'adresse XVGA). Câblé dans
  `syscall_table` (`.repeat 43` ajustée).
- **`sys_win_create`** : la fenêtre créée **prend le focus** (`kernel_wm_set_focus`)
  → son propriétaire reçoit le clavier (boucle la chaîne G.3 depuis userland).

Validé : `test_oricos_win_app` — l'app C crée sa fenêtre (slot 2, focus),
dessine `$080000==$FF` (G.4), composite `$00A032==$FF` (G.4bis), reçoit la touche
au focus → imprime "win_hello: sortie" (G.3), puis sort → `WM_COUNT` 3→2 +
`WM_OWNER[2]=0` (G.5). **Arc SP-3.m complet (G.1→G.6). 564 tests verts.**

#### ABI : compatibilité 65C816 / llvm-mos vérifiée
- Args ZP `$73-$78`/`$D0-$D7` écrits par l'app : sûrs car le crt0 mos-oricos
  garantit D=0 et la ZP app (`$A9-$CF`) + imag-regs (`$89-$A8`) ne recouvrent pas
  ces plages (link.ld plateforme conçu pour l'ABI syscall ADR-17).

## [Unreleased+SP-3.m-G4bis] - 2026-05-25

### SP-3.m G.4bis — compositor (backing stores → framebuffer XVGA)

#### Added
- **`kernel/modules/wm.s` — `kernel_wm_compose`** : parcourt les slots utilisés de
  `WM_TABLE` et BLITe chaque backing store `($06+slot):$0000` vers le framebuffer
  XVGA à la position de la fenêtre (`dst = y*512 + x/2`, byte_w=`w/2`, byte_h=`h`,
  stride fixe 512). Place les pixels dessinés en coords locales (G.4) sur l'écran
  réel → **indépendance complète app ↔ adresse XVGA** (modèle GrafPort/QuickDraw II).
- **`kernel.s`** : variables bank 1 `WCMP_SLOT`/`WCMP_XB`/`WCMP_MIDHI` ($015BD5+)
  avec garde `.assert` anti-recouvrement.
- **`kernel/modules/alloc.s` — `task_wdraw_entry`** : après le FILL_RECT local,
  appelle `kernel_wm_compose` puis sort. Couleur de remplissage portée à **15
  ($FF)**, distincte du fond desktop ($44), pour une preuve de compositing
  non-ambiguë.

Validé : `test_oricos_win_draw` — backing store `$080000==$FF` (G.4) **et**
framebuffer `$00A032==$FF` (fenêtre (100,80) → `dst=80*512+50`) après compositing
(G.4bis). 563 verts. Bug initial diagnostiqué : la couleur 4 collisionnait avec le
fond desktop, faussant l'assertion du compositor.

## [Unreleased+SP-3.m-G4] - 2026-05-25

### SP-3.m G.4 — dessin fenêtré (backing store, coords locales)

#### Added
- **`kernel/modules/gfx.s` — `kernel_gfx_window_base`** : pose `GFX_BASE` =
  backing store de la fenêtre du caller = `($06+slot):$0000` (slot = `WM_OWNER`
  de `TASK_CUR`). No-op si la tâche n'a pas de fenêtre.
- **`kernel/modules/wm.s`** : les 5 handlers `sys_gfx_*` appellent
  `kernel_gfx_window_base` avant le `kernel_gfx_*` interne → **une app dessine en
  coords LOCALES dans SON backing store, sans connaître l'adresse XVGA**. Les
  `kernel_gfx_*` (WM interne, base explicite) restent inchangés.
- **`kernel/modules/alloc.s` — `task_wdraw_entry`** + **`kernel.s` `TC_WDRAW_FLAG`**
  ($01EF40) + boot gated : tâche de test qui crée sa fenêtre puis FILL_RECT local.

Validé : `test_oricos_win_draw` — task_wdraw crée sa fenêtre (slot 2 → backing
store SDRAM $080000) et FILL_RECT (0,0,8,8) couleur 4 en coords locales ;
`vram_peek($080000)==$44` → l'app dessine dans son backing store, indépendamment
du framebuffer XVGA (modèle GrafPort). 563 verts. Suite : G.4bis compositor.

## [Unreleased+SP-3.m-G3] - 2026-05-25

### SP-3.m G.3 — clavier → focus (routage)

#### Added
- **`kernel/modules/sched.s` — `kernel_kbd_waiter_eligible`** : décide si le waiter
  clavier (`KBD_WAITER`) doit recevoir la touche : C=1 s'il ne possède **aucune
  fenêtre** (tâche non-GUI, exempte) **ou** s'il possède la **fenêtre focus**
  (`WM_FOCUS`) ; C=0 s'il possède une fenêtre **non-focus** (touche retenue).
- **`kernel_kbd_wake`** : ne réveille le waiter que s'il est éligible → le clavier
  va au **propriétaire de la fenêtre focus**. Une tâche GUI non-focus reste bloquée.
- **`kernel/modules/wm.s` — `kernel_wm_set_focus`** : appelle `kernel_kbd_wake`
  en fin (réveille le nouveau propriétaire focus si une touche est déjà bufferisée).
- **`kernel/kernel.s`** : `KW_TMP` ($3C, scratch).

Validé (non-régression) : 563 tests verts ; **task_e** (sans fenêtre → exempt)
reçoit toujours sa touche → la branche « exempt » et le mécanisme sont OK.
La branche **fenêtre-focus** (app GUI focus reçoit / non-focus retient) sera
validée en intégration par **G.6** (app C fenêtrée au focus) — flux réaliste.

#### Limite connue (→ polish #1 signaux génériques)
`KBD_WAITER` est unique : une seule tâche peut attendre le clavier à la fois.
Suffit en v1 (un seul focus) ; les signaux multi-bits par TCB (polish ADR-25)
permettront plusieurs attentes + un test focus/non-focus simultané propre.

## [Unreleased+SP-3.m-G5] - 2026-05-25

### SP-3.m G.5 — exit → close (fin de v1.a)

#### Added
- **`kernel/modules/wm.s` — `kernel_wm_close_owner`** (A=pid) : scanne `WM_OWNER`,
  ferme la fenêtre possédée par la tâche (`kernel_wm_close`) + efface l'owner.
  Appelé par **`sys_exit`** (teardown) → **la fenêtre d'une tâche se ferme
  automatiquement quand elle sort**. No-op pour les tâches sans fenêtre.
- **`kernel/kernel.s`** : `WCO_PID` ($3B, scratch).

#### Changed
- **`kernel/modules/alloc.s` — `task_win_entry`** : crée sa fenêtre puis
  `SYS_EXIT` (au lieu de dormir) → exerce G.2 (create) **et** G.5 (close on exit).

Validé : `test_oricos_boot` — `TASK_WIN_HANDLE==2` (G.2 : créée via syscall), puis
à l'exit `WM_COUNT==2` (redescend aux 2 démo) + `WM_OWNER[2]==0` (G.5 : fermée).
563 verts. **v1.a de SP-3.m complet** (fenêtre liée à la tâche : ouvre/ferme).
Suite v1.b : G.3 clavier→focus, G.4 dessin fenêtré, G.4bis compositor.

## [Unreleased+SP-3.m-G2] - 2026-05-25

### SP-3.m G.2 — SYS_WIN_CREATE : une app ouvre sa fenêtre

#### Added
- **`kernel/modules/wm.s` — `sys_win_create`** (syscall **$13**) : wrapper COP
  autour de `kernel_wm_add`. Args via le bloc ZP ADR-17 `$D0-$D7` (x/y/w/h 16-bit)
  → `WM_ARG_*` → création fenêtre + `WM_OWNER[slot]=TASK_CUR` (G.1). Retour A =
  handle (slot 0..7) ou $FF. **Backing store SDRAM implicite par slot** : base =
  `($06+slot):$0000` (64 KiB/slot, calcul trivial sans multiply ; utilisé G.4/G.4bis).
- **`kernel/modules/handlers.s`** : `syscall_table[$13] = sys_win_create` (était
  réservé `.repeat`). `$14-$3F` restent `sys_invalid`.
- **`kernel/kernel.s`** : `TC_WIN_FLAG` ($01EF30), `TASK_WIN_HANDLE` ($015451).
- **`kernel/modules/alloc.s` — `task_win_entry`** : remplit $D0-$D7, COP
  SYS_WIN_CREATE, stocke le handle, puis dort. **`boot.s`** : crée task_win
  (gated `TC_WIN_FLAG`).

Validé : `test_oricos_boot` (TC_WIN_FLAG) — `TASK_WIN_HANDLE==2` (3e fenêtre),
`WM_OWNER[2]==8` (task_win pid 8), `WM_COUNT==3`. Une tâche ouvre sa fenêtre via
syscall. `test_syscall_table_size` mis à jour ($13≠invalid, $14=invalid). 563 verts.

## [Unreleased+SP-3.m-G1] - 2026-05-25

### SP-3.m G.1 — lien fenêtre↔tâche (WM_OWNER)

#### Added
- **`kernel/kernel.s`** : `WM_OWNER` ($015BCD, WM_MAX×1B = pid propriétaire par
  slot fenêtre ; 0 = aucun) + garde `.assert` vs TCB_TABLE_BASE.
- **`kernel/modules/wm.s` — `kernel_wm_add`** : enregistre `WM_OWNER[id] =
  TASK_CUR` (tâche créatrice) à la création de fenêtre. Fondation du modèle
  GUI×multitâche (SP-3.m, backing-store/GrafPort) : chaque fenêtre est liée à
  sa tâche propriétaire.

Validé : `test_oricos_boot` asserte `WM_OWNER[0]==1` (fenêtre démo "OricOS" créée
par task_a pid 1). 563 tests verts. Suite : G.2 `SYS_WIN_CREATE` (+ backing store).

## [Unreleased+sys-sleep-ms] - 2026-05-25

### OS-2.g v2.b — SYS_SLEEP_MS : sleep bloquant piloté par le timer

#### Changed
- **`kernel/modules/wm.s` — `sys_sleep_ms`** : de stub (`rts`) à **blocage réel**.
  Gate `SCHED_ACTIVE` (no-op en contexte boot). Pose `SLEEP_TICKS[CUR]` = durée,
  permit, forge une resume frame (reprise après le COP, comme yield) et bascule
  via `kernel_block_switch` (BLOCKED). v1 : argument en **ticks** (~0,5 ms/tick ;
  conversion ms→ticks 16-bit reportée).

#### Added
- **`kernel/modules/sched.s` — `kernel_sleep_tick`** : appelé par l'IRQ T1 à
  chaque tick ; décrémente `SLEEP_TICKS[pid]` des tâches endormies, les passe
  `READY` à 0 (réveil timer).
- **`kernel/kernel.s`** : `SLEEP_TICKS` ($015480, 16 o, garde `.assert` vs
  CURSOR_ADDR), `TASK_F_CTR` ($01544B).
- **`kernel/modules/handlers.s`** : `jsr kernel_sleep_tick` dans l'IRQ T1.
- **`kernel/modules/alloc.s` — `task_f_entry`** : tâche dormeuse (inc + sleep 3
  ticks en boucle). **`boot.s`** : crée task_f (pid 7).

2ᵉ source de réveil (timer) après le clavier (g.5) → le modèle block/wake d'ADR-25
est général. Validé : `TASK_F_CTR > 0` (task_f endormie puis réveillée) ;
bitmap=$CF ; IDLE_CTR==0. 563 tests verts.

## [Unreleased+app-as-task] - 2026-05-25

### OS-2.g v2.b — apps userland comme tâches schedulées (kernel_app_spawn)

#### Added
- **`kernel/modules/fat.s` — `kernel_app_load`** : front commun extrait
  d'`app_exec` (validate + find_code + alloc bank + copie CODE). Retourne A = bank
  alloué (≠0) ou 0 (échec). **`kernel_app_spawn`** : charge un bundle et le lance
  comme **TÂCHE préemptive** via `task_create` (entry crt0 BANK:$0200, PB=bank app)
  au lieu du JSL boot-context. `app_exec` (JSL legacy) refactoré sur `app_load`.
- **`kernel/kernel.s`** : `TC_HELLOC_TASK_FLAG` ($01EF20, spawn hello_c en tâche).
- **`kernel/modules/boot.s`** : spawn hello_c gated, placé **après l'init de
  l'allocateur de banks** (app_spawn → kernel_alloc_bank ; placé trop tôt,
  BANK_NEXT non initialisé → alloc échouait).

Le crt0 mos-oricos attend exactement ce que `task_create` forge (mode N M=X=1,
D=0, pile fournie, pas de XCE) ; `SYS_EXIT` (scheduler actif) détruit la tâche.

Validation : `test_oricos_helloc_as_task` — hello_c spawné comme tâche, tourne
parmi les tâches démo et imprime « Hello OricOS from C! » dans $BB80. **Une app C
llvm-mos tourne comme tâche préemptive schedulée.** 3/3 helloc + 563 tests verts.

## [Unreleased+OS-2.b-idle] - 2026-05-25

### OS-2.g v2.b — idle task (ferme le trou « dernière tâche »)

#### Added
- **`kernel/modules/alloc.s` — `idle_entry`** : tâche idle (toujours READY,
  priorité la plus basse). Incrémente `IDLE_CTR` puis `WAI` (dort jusqu'à l'IRQ).
- **`kernel/kernel.s`** : `IDLE_PID` ($01547D, pid de l'idle), `IDLE_CTR` ($01547E).
- **`kernel/modules/boot.s`** : crée l'idle **en dernier** via `task_create`,
  mémorise son pid dans `IDLE_PID`.

#### Changed
- **`kernel/modules/sched.s` — `kernel_sched_find_next`** : scan **borné**
  (≤ TCB_MAX essais, fini le risque de boucle infinie), **saute `IDLE_PID`** dans
  la passe normale, et **retombe sur l'idle** si aucune autre tâche READY. Ferme
  le trou « dernière tâche / tout bloqué » (avant : hang). L'idle n'est élue
  qu'en dernier recours → zéro temps volé aux tâches réelles.

Validation : `IDLE_CTR == 0` (l'idle n'a jamais tourné tant que a/b/c étaient
READY → dépriorisation correcte) ; bitmap=$4F (idle pid 6 vivante, task_d/e
détruites). 563 tests verts. (Le fallback idle « tout bloqué » sera exercé
naturellement à l'étape app_exec → task_create.)

## [Unreleased+OS-2.b-g5-block] - 2026-05-25

### OS-2.g v2.b/g.5 — SYS_READ_CHAR bloquant + réveil IRQ (Exec-classique 2/2)

#### Added
- **`kernel/modules/sched.s` — `kernel_block_switch`** : comme `do_switch` mais
  marque CUR `BLOCKED` (resume frame déjà forgée par l'appelant). **`kernel_kbd_wake`**
  : appelé par le handler IRQ après `kbd_poll` ; si `KBD_WAITER≠0` et ring non
  vide, passe la tâche `READY` et efface `KBD_WAITER`.
- **`kernel/kernel.s`** : `KBD_WAITER` ($01544F, pid bloqué sur clavier — signal
  dégénéré généralisable), `TASK_E_KEY` ($01544A, test).
- **`kernel/modules/alloc.s` — `task_e_entry`** : tâche qui bloque sur
  `SYS_READ_CHAR`, stocke la touche, puis `SYS_EXIT`.
- **`kernel/modules/handlers.s`** : `jsr kernel_kbd_wake` après `kernel_kbd_poll`.
- **`kernel/modules/boot.s`** : init `KBD_WAITER`/`TASK_E_KEY`, crée task_e (pid 5).

#### Changed
- **`kernel/modules/wm.s` — `sys_read_char`** : deux modes (gate `SCHED_ACTIVE`,
  comme `SYS_EXIT`). Scheduler **inactif** (app boot-context, ex. hello_c) → spin +
  `WAI` (v1, préserve le test hello_c). Scheduler **actif** (vraie tâche) →
  **blocage réel** : sous `sei` (anti lost-wakeup), si ring vide enregistre
  `KBD_WAITER`, forge une resume frame (reprise → re-check), met `FORBID=0`
  (tâche suivante préemptible) et bascule via `kernel_block_switch` ; au réveil
  restaure `FORBID=1` et re-pop. **Plus de spin** : la tâche rend le CPU.

Validation : task_e bloque (KBD_WAITER=5), une autre tâche tourne, le test injecte
'K' via le device KBD2 → IRQ → `kernel_kbd_wake` réveille task_e → elle lit 'K'
(`TASK_E_KEY=='K'`) puis `SYS_EXIT` (bitmap=$0F). hello_c 2/2 (fallback WAI
préservé). **563 tests verts.**

→ Le modèle de concurrence **Exec-classique (ADR-25)** est désormais implémenté
(Forbid/Permit + atomicité syscall + block/wake) → ADR-25 ratifiable.

## [Unreleased+OS-2.b-g6-forbid] - 2026-05-25

### OS-2.g v2.b/g.6 — Forbid/Permit (ADR-25 Exec-classique, incrément 1/2)

#### Added
- **`kernel/modules/sched.s` — `kernel_forbid`/`kernel_permit`** : compteur
  `FORBID_COUNT` ($01544E) suspend la préemption (le timer vérifie le compteur
  dans `do_switch`) ; les IRQ continuent de tourner. LDA/STA long (INC sans mode
  abs-long sur 65816). **Préservent A** (porte le num syscall / la valeur de
  retour à l'entrée/sortie COP), X, Y.

#### Changed
- **`kernel/modules/handlers.s`** : le dispatcher COP fait `cli` + `kernel_forbid`
  à l'entrée et `kernel_permit` à la sortie → un syscall ne peut plus être
  **préempté** en plein milieu (corrige la réentrance ZP **#2**), tout en gardant
  les IRQ actives (pas de deadlock). `do_switch` saute le switch si `FORBID≠0`
  (restaure la même tâche).
- **`kernel/modules/wm.s`** : `sys_yield` et `sys_exit` font `permit` avant de
  basculer (switch volontaire ≠ préemption ; la garde `FORBID` ne doit pas les
  bloquer). yield → reprise en contexte app (FORBID=0) ; exit → tâche suivante
  un-forbidden.
- **`kernel/modules/boot.s`** : init `FORBID_COUNT=0`.

Fondation d'atomicité d'Exec-classique. Validé par non-régression (563 verts ;
un bug « A clobbé par forbid » détecté par les tests puis corrigé). La validation
positive + le superseding du spin/cli arrivent avec g.5 (blocage read_char,
incrément 2). ADR-25 reste DRAFT (ratifiable quand g.5/g.6 ≥ 50 %).

## [Unreleased+OS-2.g-v2.a-g4] - 2026-05-25

### OS-2.g v2.a/g.4 — SYS_EXIT teardown (fin du STP global)

#### Changed
- **`kernel/modules/wm.s` — `sys_exit`** : remplace `stp` par un **teardown réel** :
  `tcb[CUR].STATE=DEAD`, `kernel_bitmap_clear` (libère le slot), puis élit la
  prochaine tâche READY et restaure SON contexte (le contexte de la tâche morte
  n'est PAS sauvé). Une app qui sort ne fige plus la machine.
- **Garde-fou hello_c** : `SYS_EXIT` ne fait le teardown que si `SCHED_ACTIVE==$A5`
  (scheduler timer-driven démarré). Avant ça — app lancée en contexte boot via
  JSL, ex. hello_c (TC-poc) qui n'est pas une vraie tâche — `SYS_EXIT` retombe
  sur `stp` (sémantique v1 préservée, test hello_c intact).

#### Added
- **`kernel/modules/sched.s` — `kernel_bitmap_clear`** (A=pid → efface bit pid).
- **`kernel/modules/handlers.s`** : `.export restore_and_return` (cible du jmp
  depuis sys_exit après le tcs).
- **`kernel/modules/alloc.s` — `task_d_entry`** : tâche éphémère (inc 1× puis
  SYS_EXIT) ; `bra` final = filet anti-crash si exit échouait.
- **`kernel/kernel.s`** : `TASK_D_CTR` ($015449), `SCHED_ACTIVE` ($01544D).
- **`kernel/modules/boot.s`** : init `SCHED_ACTIVE=0`, crée task_d (pid 4),
  passe `SCHED_ACTIVE=$A5` juste avant `cli`/`jmp task_a_entry`.

Validation : `TASK_D_CTR == 1` (tourne 1×, sys_exit bascule sans boucler) +
bitmap=$0F (slot 4 libéré, task_c vivante) → teardown correct. hello_c 2/2
(STP préservé). 563 tests verts.

#### Limites connues (reportées)
- La **page de pile** de la tâche détruite fuit (pas de free-list de pages v2.a).
- Cas **« dernière tâche »** : `sys_exit` suppose ≥1 autre tâche READY (task A/B
  permanentes) ; idle task / halt propre reporté.
- `exit_code` (X) ignoré (pas de `wait()` parent / zombie reaping).

## [Unreleased+OS-2.g-v2.a-g7] - 2026-05-25

### OS-2.g v2.a/g.7 — SYS_YIELD coopératif réel

#### Changed
- **`kernel/modules/wm.s` — `sys_yield`** : remplace le no-op (`rts`) par un
  vrai yield coopératif. Entré via `jsr (syscall_table,X)`, il jette le retour
  du jsr, reconstruit sur la frame COP la frame attendue par `do_switch`
  (`[Y][X][A][P][PCL][PCH][PBR]`), puis `jmp do_switch` → sauve le SP (point de
  reprise après le COP) dans `tcb[CUR].S` et bascule. Au réveil, ply/plx/pla/rti
  reprend après le COP. `sei` protège la chirurgie de pile (mini section
  critique ; do_switch ressort en rti → I de la tâche suivante).
- **`kernel/modules/handlers.s`** : `.export do_switch` (cible du jmp depuis yield).
- **`kernel/modules/alloc.s`** : `task_c_entry` cède via `SYS_YIELD` ($05) à
  chaque itération (exerce g.7).

Validation : avec task_c qui yield à chaque tour, `TASK_C_CTR > 0` + A/B > 0 +
tick=10 + STP propre → la chirurgie de pile est correcte (switch + reprise après
le COP). Un bug aurait crashé/hang task_c. 563 tests verts.

## [Unreleased+OS-2.g-v2.a-g3] - 2026-05-25

### OS-2.g v2.a/g.3 — création dynamique de tâches (task_create)

#### Added
- **`kernel/modules/sched.s` — `kernel_task_create`** (X=entry lo, Y=entry hi,
  A=prio → A=pid ou 0). Scanne le bitmap pour un slot libre, alloue une page de
  pile bank 0 (`STACK_NEXT_PAGE` bump, départ page $04), initialise le TCB et
  **forge la frame d'interruption initiale** (Y/X/A=0, P=$30, PC=entry, PB=1 ;
  saved_S=page:$F4) — même format que la pré-init de task B. La frame est écrite
  en adressage long (bank 0 explicite, indépendant du DBR).
- **`kernel/modules/alloc.s` — `task_c_entry`** : 3e tâche démo (compteur).
- **`kernel/kernel.s`** : `TASK_C_CTR` ($015448), `STACK_NEXT_PAGE` ($01544C),
  ZP scratch task_create (`TC_*` $32-$39).
- **`kernel/modules/boot.s`** : init `STACK_NEXT_PAGE=$04` + appel `task_create`
  (task_c → pid 3, pile page $04).

Validation : `test_oricos_boot` asserte `TASK_C_CTR > 0` (la tâche forgée
s'exécute → frame correcte) **et** bitmap=$0F (slot 3 réservé). Prouve la
création dynamique + le round-robin N-tâches élisant pid 3 **end-to-end**.
563 tests verts. (g.4 exit + g.5/g.6 block/wake = suite.)

## [Unreleased+OS-2.g-v2.a] - 2026-05-25

### OS-2.g v2.a — scheduler N-tâches round-robin (implémente ADR-14)

#### Added
- **`kernel/modules/sched.s`** (nouveau module, segment CODE) :
  - `kernel_tcb_ptr` — pid (1..16) → `SCHED_PTR` = `&tcb[pid]` 24-bit
    (`TCB_TABLE_BASE + (pid-1)*TCB_SIZE`, indexation (pid-1) conforme au layout
    TCB_1/TCB_2). Math 16-bit `(pid-1)*20`, discipline `.a8`/`.i8`.
  - `kernel_sched_find_next` — pid courant → prochain pid `READY` (round-robin
    1..16 avec wrap, saute les slots non-READY). Terminaison garantie (CUR passé
    READY avant l'appel).
- **`kernel/kernel.s`** : ZP scheduler `SCHED_PTR` ($2C-$2E), `SCHED_CAND` ($2F),
  `SCHED_TMP` ($30-$31), zone libre disjointe de WM/kbd/FAT.

#### Changed
- **`kernel/modules/handlers.s` — `do_switch`** : remplace le swap **figé
  2 tâches** (`CUR∈{1,2}`, `NEXT=3-CUR`) par un **round-robin table-driven**
  (sauve SP→`tcb[CUR].S` via `kernel_tcb_ptr`, choisit le suivant via
  `kernel_sched_find_next`, charge son SP). Les helpers (jsr) sont appelés
  **avant** le `tcs` (aucun jsr/rts ne traverse le changement de pile).
  Segment IRQ_HANDLER : 114 o / 256 (le switch généralisé est plus compact).

Comportement préservé : avec 2 tâches live, le round-robin reproduit l'alternance
1↔2 → **563 tests verts**. Le scan exerce réellement l'indexation, le saut des
14 slots DEAD et le wrap. Reste à v2.b : `task_create`/`destroy` (g.3), block/wake
+ Forbid/Disable (g.5/g.6, modèle de concurrence ADR-25 DRAFT). Implémente ADR-14
(déjà ratifiée) — ne présuppose pas ADR-25.

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
