; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty

; ============================================================
; OricOS — Kernel core (Sprint 1.b — scheduler préemptif 2 tâches)
; ============================================================
; Auteur : bmarty (benedicte) <bmarty@mailo.com>
; Date   : 2026-05-08
;
; Ce fichier est l'ORCHESTRATEUR du kernel. Il contient :
;   1. Toutes les constantes, définitions ZP, I/O maps.
;   2. Les .include des modules (dans kernel/modules/).
;
; Modules (ordre d'inclusion = ordre dans le segment CODE) :
;   boot.s      — entry point, scheduler, TCB
;   fat.s       — FAT32, SD, bundle, app loader
;   log.s       — log ring, panic, hex print
;   console.s   — print char/string, scroll, banner
;   kbd.s       — driver clavier KBD2 IRQ-driven
;   alloc.s     — bank allocator (bump + free list)
;   vram.s      — VRAM cold device I/O
;   gfx.s       — GPU blitter helpers
;   tk.s        — toolkit (label/frame/button/widgets/menu)
;   wm.s        — window manager + taskbar + icônes + curseur
;   handlers.s  — NMI/COP/IRQ handlers + table syscalls + CHARSET
;
; Convention : ca65 syntaxe WDC, --cpu 65816.
; ============================================================

        .setcpu "65816"
        .smart  +

; ─── Macros d'invariant mode M/X (audit 65C816 §3.6 / 8.3) ──────────
; `.smart` ca65 ne suit le mode A/I qu'en linéaire ; toute branche qui
; entre dans un label depuis ailleurs peut désynchroniser l'état tracé
; et le mode réel runtime (cf. bug taskbar `_tbh_advance:` 2026-05-30 et
; convention `.a16` du CLAUDE.md OricOS). Ces macros documentent
; l'invariant attendu en tête de routine/bloc et servent d'ancre de
; revue. Elles s'appuient sur les pseudo-fonctions `.asize` (A bits) et
; `.isize` (X/Y bits) de ca65 — vérification à l'assemblage.
.macro ASSERT_A16
        .assert .asize = 16, error, "ASSERT_A16 : ici A doit etre 16-bit (rep #$20)"
.endmacro
.macro ASSERT_A8
        .assert .asize = 8, error, "ASSERT_A8 : ici A doit etre 8-bit (sep #$20)"
.endmacro
.macro ASSERT_I16
        .assert .isize = 16, error, "ASSERT_I16 : ici X/Y doivent etre 16-bit (rep #$10)"
.endmacro
.macro ASSERT_I8
        .assert .isize = 8, error, "ASSERT_I8 : ici X/Y doivent etre 8-bit (sep #$10)"
.endmacro

; ─── Constantes ─────────────────────────────────────────────────────
; ADR-32 §10.13 (2026-06-10) : TICK_COUNTER relocalisé $5500 → $9093.
; $015500 était AUSSI le start du segment NMI_HANDLER : chaque tick
; écrasait l'opcode `rti` du handler NMI (tout NMI réel aurait exécuté la
; valeur du compteur comme opcode). Gardé par test_oricos_nmi_safe
; (Phosphoric, make tests). Nouvelle adresse : zone data runtime $90xx,
; entre CURSOR_X ($9092) et BANK_FREE_LIST ($90A0).
TICK_COUNTER    = $019093       ; 1B counter (tick T1, incrémenté par l'IRQ)
; ADR-34 étape B (GPU-ISA v2) : capabilities lues au boot (read GPU_TRIGGER_IO
; = caps<<4 | version ; 0 = carte v1 sans FIFO). L'OS route ses chemins gfx
; selon CES bits, jamais selon l'identité de la carte — contrat ISA.
GPU_CAPS_KERNEL = $019094       ; 1B : caps<<4 | version
; ADR-34 C2 : display-lists — slots 0-7 fenêtres (chrome + widgets, C2b),
; 8 icônes, 9 barre de menu, 10 taskbar (sans horloge). Une liste = le rendu
; d'UN élément en coords absolues, rejouée par EXEC_LIST tant que valide ;
; invalidée par resize/focus/close/add/changement d'état widget ou menu.
; C2b : le MOVE n'invalide PLUS si la carte a EXEC_LIST_XY — le drag rejoue
; la liste translatée de (x−org_x, y−org_y), zéro reconstruction.
; ⚠ C2b reloge le bloc en $0191A0+ : l'ancien WL_VALID ($019095, 9B)
; chevauchait PANIC_CODE ($019095) et BUNDLE_FOUND_* ($019096-$01909C) —
; collision latente C2a (un panic invalidait la liste 0 ; une liste validée
; corrompait le résultat du scan bundle). Asserts de layout ci-dessous.
WL_SLOTS         = 11           ; 0-7 fenêtres, 8 icônes, 9 menu, 10 taskbar
WL_SLOT_ICONS    = 8
WL_SLOT_MENU     = 9
WL_SLOT_TASKBAR  = 10
WL_VALID         = $0191A0      ; 11B : $A5 = liste rejouable (0 au boot)
WL_FLIP          = $0191AB      ; 11B : buffer courant (0/1) par slot
WL_ORG_X         = $0191B6      ; 11×2B : x fenêtre au moment du record (slots 0-7)
WL_ORG_Y         = $0191CC      ; 11×2B : y fenêtre au moment du record
WL_NENT          = $0191E2      ; 1B : entrées émises pendant le record courant
WL_ABORT         = $0191E3      ; 1B : $A5 = record avorté (>64 entrées ou arène
                                ;   pleine) → liste non validée, rendu direct
WL_ARENA_BASE    = $0191E4      ; 2B : base 16-bit du chunk d'arène du record
WL_ARENA_BUMP    = $0191E6      ; 2B : bump dans le chunk (0..WL_ARENA_CHUNK)
WL_DX            = $0191E8      ; 2B : delta x signé (calc replay translaté)
WL_DY            = $0191EA      ; 2B : delta y signé
; C2b coalescing + dirty-rect du drag :
WM_RD_SKIPPED    = $0191EC      ; 1B : $A5 = dernière frame de geste SKIPPÉE
                                ;   (GPU saturé) → la capture du rect sale est
                                ;   gelée et la fin de geste rattrape la frame
WM_RD_DIRTY      = $0191ED      ; 1B : $A5 = chaîne de dessin en mode dirty-rect
                                ;   (redraw_drag) → fenêtres/menu/taskbar non
                                ;   touchés par (ancien ∪ nouveau rect) skippés
WM_RD_NOCLEAR    = $0191EE      ; 1B : $A5 (one-shot) = full redraw SANS le clear
                                ;   desktop — clic « focus pur », rien d'exposé,
                                ;   tout repeint par-dessus (anti-flash bleu :
                                ;   le clear 98k cyc GPU traversait le pipeline
                                ;   au milieu du geste suivant)
WL_REC           = $01909E      ; 1B : $A5 = mode record (fill16/text16 émettent)
WL_PTR           = $0190B1      ; 3B : curseur d'émission SDRAM (l'IRQ peut
                                ;      clobber VRAM_ADDR → re-posé par émission)
WL_LISTS         = $030000      ; SDRAM : 11 slots × 2 buffers × $400 (double-
                                ;   buffer : record dans l'autre pendant que le
                                ;   courant peut être en vol — zéro drain).
                                ;   $400/buffer = 64 entrées × 13 o + terminateur
                                ;   (64 = borne GPU_LIST_MAX_ENTRIES).
WL_LIST_STRIDE   = $0800        ; par slot ($400 par buffer)
; C2b : arène de chaînes per-(slot, flip) — les chaînes référencées par une
; liste doivent rester stables TANT QUE la liste est valide (le ring 32×32
; n'offre que 2×FIFO de profondeur). Bump-alloc remis à zéro à chaque
; record ; chunk = (slot×2 + flip) × $400. 22 chunks × $400 = $5800.
WL_ARENA         = $038000      ; SDRAM : $038000-$03D7FF
WL_ARENA_CHUNK   = $0400
WL_SCRATCH16     = $0190BD      ; 2B : adresse de liste en cours (calcul 16-bit
                                ;   hors ZP — sta DP_TMP 16-bit écraserait $11
                                ;   = DP_SYS_ARG_X, l'arg COP !)
GPU_CAP_FIFO_BIT = $10          ; bit 4 : FIFO async disponible
GPU_CAP_LISTXY_BIT = $80        ; bit 7 : EXEC_LIST_XY (GPU-ISA v4, ADR-34 C2b)
GPU_ST_QFULL    = $20           ; STATUS bit 5 : FIFO pleine
GPU_ST_BUSY     = $80           ; STATUS bit 7 : busy
; Layout : le bloc WL v2 vit entre IRQ_ZP_SAVE ($019100+140=$01918C) et le
; segment GUICODE ($019200).
.assert WL_VALID >= $01918C,                  error, "WL block chevauche IRQ_ZP_SAVE"
.assert WL_DY + 2 <= $019200,                 error, "WL block chevauche GUICODE"
; SP-3.o S.4c : SENTINEL/VERSION relocalisés de $015000/$015010 vers la zone
; haute libre. Motif : le segment CODE a grandi au-delà de $5000 (toolkit
; widgets) et écrasait ces données runtime → corruption.
SENTINEL_BASE   = $016300        ; 6 octets ("ORIOS\0" sentinelle boot)
VERSION_BASE    = $016310        ; 5 octets (version kernel)
TASK_CUR        = $019032       ; PID actuellement RUNNING (1..16)
TASK_A_CTR      = $019040
TASK_B_CTR      = $019044
TASK_C_CTR      = $019048       ; OS-2.g v2.a g.3 : compteur 3e tâche (créée par task_create)
TASK_D_CTR      = $019049       ; OS-2.g v2.a g.4 : compteur tâche éphémère (s'auto-termine)
TASK_E_KEY      = $01904A       ; OS-2.g v2.b g.5 : touche lue par task_e (test blocage)
TASK_F_CTR      = $01904B       ; OS-2.g v2.b sleep : compteur tâche dormeuse (test SYS_SLEEP_MS)
TASK_WIN_HANDLE = $019051       ; SP-3.m G.2 : handle fenêtre retourné par SYS_WIN_CREATE (test)
TASK_EVT_WHAT   = $019052       ; SP-3.n G.2 : what de l'événement lu par task_evt (test)
TASK_EVT_MSG    = $019053       ; SP-3.n G.2 : message (keycode) lu par task_evt (test)
TASK_ML_MSG     = $019054       ; SP-3.n G.3a : message rendu par SYS_MAIN_LOOP (test)
TASK_ML_DETAIL  = $019055       ; SP-3.n G.3a : détail ($DA : id fenêtre / keycode) (test)
TASK_UI_HANDLE  = $019056       ; SP-3.n G.3b : handle fenêtre créée par SYS_UI_DEFINE (test)
TASK_DLG_RES    = $019057       ; SP-3.n G.5 : retour SYS_DO_DLGBOX lu par task_dlg (test)
TASK_ALERT_RES  = $019059       ; SP-3.n G.6 : retour SYS_ALERT lu par task_alert (test)
TASK_CHK_VAL    = $01905A       ; SP-3.o S.1 : valeur checkbox lue par task_chk (test)
TASK_CHK_ID     = $01905B       ; SP-3.o S.1 : id du widget checkbox créé (test)
TASK_SCR_ID     = $01905C       ; SP-3.o S.2 : id du scrollbar créé par task_scr (test)
TASK_VIEW_ID    = $01905D       ; SP-3.o S.3 : id du GenView créé par task_view (test)
TASK_RAD_ID0    = $01905E       ; SP-3.o S.4a : id du 1er radio créé par task_radio (test)
TASK_RAD_ID1    = $01905F       ; SP-3.o S.4a : id du 2e radio créé par task_radio (test)
TASK_TEXT_ID    = $019060       ; SP-3.o S.4b : id du champ texte créé par task_text (test)
TASK_LIST_ID    = $019061       ; SP-3.o S.4c : id de la liste créée par task_list (test)
TASK_GENUI_ID   = $019062       ; SP-3.o S.5 : id du 1er contrôle déclaré par task_genui (test)
TASK_CPCT_HANDLE = $019063      ; ADR-27 B2.c : slot fenêtre créée par task_compact
SLEEP_TICKS     = $019080       ; OS-2.g v2.b sleep : 16 octets, SLEEP_TICKS[pid] = ticks restants
                                ; ($5481..$548F pour pid 1..15) ; >0 = tâche endormie (timer décrémente)
KBD_WAITER      = $01904F       ; OS-2.g v2.b g.5 : pid bloqué sur le clavier (0=aucun).
                                ; Signal dégénéré (1 attente clavier) ; généralisable en
                                ; masque de signaux par TCB (ADR-25) si besoin.
IDLE_PID        = $01907D       ; OS-2.g v2.b idle : pid de la tâche idle (0=non créée).
                                ; find_next la saute (passe normale) et n'y retombe QUE si
                                ; aucune autre tâche READY → ferme le trou « dernière tâche ».
IDLE_CTR        = $01907E       ; compteur idle (test : ==0 tant que des tâches réelles tournent)
STACK_NEXT_PAGE = $01904C       ; OS-2.g v2.a g.3 : prochaine page de pile bank 0 (bump)
SCHED_ACTIVE    = $01904D       ; OS-2.g v2.a g.4 : $A5 = scheduler démarré (timer-driven).
                                ; SYS_EXIT fait STP si inactif (app boot-context, ex. hello_c),
                                ; sinon teardown+reschedule.
FORBID_COUNT    = $01904E       ; OS-2.g v2.b g.6 (ADR-25 Exec-classique) : compteur Forbid.
                                ; ≠0 = tâche en syscall → le timer NE préempte PAS (atomicité,
                                ; corrige la réentrance ZP #2). yield/exit font permit avant switch.
TICK_GOAL       = $0A           ; 10 ticks → STP

; ─── ADR-14 : Table TCB (Sprint 2.g) ────────────────────────────────
; 16 TCBs × 20 bytes = 320 octets en bank 1 à $5C00.
; Bitmap free 2 octets à $5B00 (16 bits).
TCB_TABLE_BASE  = $015C00
TCB_BITMAP      = $015B20       ; 2 bytes : bit set = slot occupé (déplacé $5B00→$5B20 pour éviter overlap ICON_TABLE)
TCB_SIZE        = 20            ; bytes par TCB
TCB_MAX         = 16            ; tasks max

; Offsets dans un TCB
TCB_PID         = 0
TCB_STATE       = 1
TCB_PRIO        = 2
TCB_PARENT      = 3
TCB_S_LO        = 4
TCB_S_HI        = 5
TCB_PC_LO       = 6
TCB_PC_HI       = 7
TCB_PB          = 8
TCB_DB          = 9
TCB_STACK_BANK  = 10
TCB_FLAGS       = 11
TCB_NAME        = 12            ; 8 bytes

; Task states
TASK_STATE_DEAD     = 0
TASK_STATE_READY    = 1
TASK_STATE_RUNNING  = 2
TASK_STATE_BLOCKED  = 3
TASK_STATE_ZOMBIE   = 4

; v0.1 : alias pour les 2 premiers TCBs (task A=PID1, task B=PID2)
TCB_1           = TCB_TABLE_BASE                ; $015C00
TCB_2           = TCB_TABLE_BASE + TCB_SIZE     ; $015C14
TCB_1_S         = TCB_1 + TCB_S_LO              ; $015C04 (16-bit)
TCB_2_S         = TCB_2 + TCB_S_LO              ; $015C18
TCB_1_STATE     = TCB_1 + TCB_STATE
TCB_2_STATE     = TCB_2 + TCB_STATE

; ─── Bank allocator pool système (Sprint 2.b/2.h) ──────────────────
; Pool système : banks 4-127 (= $04..$7F, 124 banks) pour code/data apps.
BANK_NEXT       = $019050       ; prochain bank libre via bump (uint8)
BANK_DEMO       = $019060       ; 3 octets : résultats de l'alloc démo
BANK_POOL_BASE  = $04            ; premier bank du pool
BANK_POOL_END   = $80            ; dernier bank du pool + 1 (= $80, banks 4-127)

; Sprint 2.h : free list LIFO 16 entries. alloc pop d'abord, sinon bump.
BANK_FREE_LIST  = $0190A0       ; 16 bytes stack (banks libérés)
BANK_FREE_TOP   = $0190B0       ; 1 byte (count 0..16)

; ── ADR-32 §10.11 : buffer de sauvegarde ZP du chemin souris IRQ ────
; kernel_irq_handler copie les scratch ZP $08-$93 (140 octets) ici avant
; le bloc souris (mouse_read → mouse_step/drag → event_push_mouse) et les
; restaure après : un syscall body préempté par une IRQ souris reprend
; avec ses scratch (WM_ARG_*/WM_DP_TMP/GFX_*/EVT_TMP/VRAM_OP_*) intacts.
; Une seule instance suffit : pas d'IRQ imbriquée (I=1 dans le handler).
IRQ_ZP_SAVE     = $019100       ; 140 bytes ($019100-$01918B)
IRQ_ZP_SAVE_LEN = $8C           ; 140 = $94-$08 (plage ZP $08..$93 incluse)

; ─── Bank allocator pool LIVE (Sprint VRAM-3, ADR-19 + ADR-20) ─────
; Pool live : banks 132-159 (= $84..$9F, 28 banks) en BRAM ECP5.
; Banks 128-131 ($80..$83) réservés au framebuffer principal XVGA
; 1024×768×4bpp (4 banks consécutifs, ADR-20 ; BPL=512 → 1024 px/ligne).
; Pool live = backing-stores fenêtres GUI actives + buffers GPU.
BANK_LIVE_NEXT       = $019058   ; prochain bank live via bump (uint8)
BANK_LIVE_DEMO       = $019068   ; 4 octets : résultats alloc/free demo
BANK_LIVE_POOL_BASE  = $84       ; bank 132 (= $84, 1er bank libre après FB)
BANK_LIVE_POOL_END   = $A0       ; bank 160 (exclusif), banks 132-159
BANK_LIVE_FREE_LIST  = $0190C0   ; 16 bytes stack
BANK_LIVE_FREE_TOP   = $0190D0   ; 1 byte (count 0..16)

; ─── Modèle erreur kernel (Sprint 2.i / OS-2.i.v2) ──────────────────
PANIC_CODE      = $019095       ; 1 byte : dernier code panic (0 = OK)

; Codes d'erreur/panic nommés (8-bit). 0 = OK.
ERR_NONE            = $00
ERR_BANK_EXHAUSTED  = $01       ; pool de banks épuisé (kernel_alloc_bank)
ERR_BAD_SYSCALL     = $02       ; numéro de syscall invalide (COP dispatch)
ERR_BUNDLE_INVALID  = $03       ; bundle app malformé (réservé)

; Niveaux de log kernel.
LOG_INFO            = $01
LOG_WARN            = $02
LOG_ERROR           = $03
LOG_PANIC           = $04

; Log ring buffer (OS-2.i.v2) — bank 1, gap $5400-$54FF (hors CODE/segments).
; 8 entrées × 2 octets (level, code) = 16B. Circulaire : si plein, l'entrée
; la plus ancienne est écrasée (head suit tail). Inspectable post-mortem.
LOG_RING        = $0190E0       ; 16 octets (8 entrées × {level, code})
LOG_HEAD        = $0190F0       ; index lecture (entrée la plus ancienne)
LOG_TAIL        = $0190F1       ; index écriture
LOG_COUNT       = $0190F2       ; nb entrées (0..8)
LOG_SIZE        = 8
LOG_MASK        = LOG_SIZE - 1
DP_LOG_TMP      = $13           ; DP+$13 : scratch code log
LOG_TEST_RES    = $0190F3       ; sentinelle test OS-2.i.v2 : 3 octets (count, lvl, code)

; ─── Format bundle apps (Sprint 2.k, ADR-08 v0.1) ───────────────────
; Header bundle "OOS\x01" : 8 octets fixes :
;   +0  magic         "OOS\x01"  (4B)
;   +4  version       (1B, = $01)
;   +5  flags         (1B, bit 0 = relocatable, autres réservés)
;   +6  num_sections  (1B)
;   +7  reserved      (1B)
;   +8  section[i] entries (8B chacune) :
;     +0 type          (1B : $01=CODE, $02=DATA, $03=ICON, $04=MANIFEST)
;     +1 reserved      (1B)
;     +2 size          (2B little-endian, max $FFFF par section v1)
;     +4 offset        (2B little-endian, relatif au début bundle)
;     +6 reserved      (2B)
;   +8+8N section data (concaténé selon offsets)
BUNDLE_MAGIC_0  = 'O'
BUNDLE_MAGIC_1  = 'O'
BUNDLE_MAGIC_2  = 'S'
BUNDLE_MAGIC_3  = $01
BUNDLE_VERSION  = $01
BUNDLE_SEC_CODE = $01
BUNDLE_SEC_DATA = $02
BUNDLE_SEC_ICON = $03
BUNDLE_SEC_MAN  = $04
BNL_HDR_VER     = 4
BNL_HDR_NSEC    = 6

; Erreur codes pour validate / find
BUNDLE_OK              = $00
BUNDLE_ERR_MAGIC       = $01
BUNDLE_ERR_VERSION     = $02
BUNDLE_ERR_NOT_FOUND   = $03

BNL_HDR_SIZE       = 8          ; bytes header total (avant sections)
BNL_SEC_SIZE       = 8          ; bytes per section entry
; Offsets dans une section entry (relatifs à entry start)
BNL_SEC_TYPE       = 0
BNL_SEC_SZ_LO      = 2
BNL_SEC_SZ_HI      = 3
BNL_SEC_OFF_LO     = 4
BNL_SEC_OFF_HI     = 5

BUNDLE_VALIDATE_RES = $01909C   ; 1 byte : résultat dernier validate

; Sprint 2.l : résultats find_code + app_exec
BUNDLE_FOUND_NSEC   = $019096   ; 1 byte : nsec scan tmp
BUNDLE_FOUND_SIZE   = $019098   ; 2 bytes : size de la section trouvée
BUNDLE_FOUND_OFFSET = $01909A   ; 2 bytes : offset de la section
BUNDLE_APP_BANK     = $01909F   ; 1 byte : bank alloué pour app

; ─── Driver console (Sprint 2.c/2.e) — Oric 1 screen RAM ───────────
; Mode TEXT 40x28 : $BB80-$BFE7 (40*28 = 1120 octets = $460).
; Caractère ASCII direct ; 0-31 = attribute bytes.
SCREEN_BASE     = $00BB80
SCREEN_END      = $00BFE0       ; 1 past last char ($BB80 + $0460)
SCREEN_SIZE     = $0460          ; 40 * 28
SCREEN_FILL     = $20            ; espace ASCII
SCREEN_COLS     = $28            ; 40
SCREEN_ROWS     = $1C            ; 28
SCREEN_LAST_ROW = $00BFB8       ; SCREEN_BASE + 27*40

; Variables console (bank 1)
CURSOR_ADDR     = $019090       ; 16-bit, addr écran courante
CURSOR_X        = $019092       ; 8-bit, colonne courante (0..39)

; ════════════════════════════════════════════════════════════════════
;  REGISTRE D'ALLOCATION ZERO PAGE (DP = $0000, bank 0)
;  Mode N : toutes les adresses sont 16-bit ZP (D=0 au boot).
;  RÈGLE : toute variable ZP kernel doit figurer ici avant d'être ajoutée.
;  ⚠️  $20-$21 (WM_DP_TMP) : scratch CLOBBÉ par kernel_wm_offset → jamais
;      supposer stable après un jsr kernel_wm_offset. Utiliser WIN_SLOT ($24).
;
;  Adresse   Taille   Symbole            Usage
;  --------  ------   ------             -----
;  $08-$0A   3B       DP_PTR             pointer 24-bit (print_string, long indirect)
;  $0B       1B       (libre)
;  $0C-$0D   2B       DP_PCPTR           pointer 16-bit (print_char, screen RAM)
;  $0E       1B       DP_PCPTR+2         bank byte du DP_PCPTR (écriture temporaire)
;  $0F       1B       (libre)
;  $10       1B       DP_TMP             scratch char temp (print_char, misc)
;  $11       1B       DP_SYS_ARG_X       X sauvé avant dispatch COP (OS-2.f.v2)
;  $12       1B       DP_KBD_TMP         scratch ring clavier (OS-2.d)
;  $13       1B       DP_LOG_TMP         scratch code log (OS-2.i.v2)
;  $14-$15   2B       WM_ARG_X           arg x fenêtre (16-bit)
;  $16-$17   2B       WM_ARG_Y           arg y fenêtre (16-bit)
;  $18-$19   2B       WM_ARG_W           arg w fenêtre (16-bit)
;  $1A-$1B   2B       WM_ARG_H           arg h fenêtre (16-bit)
;  $1C-$1D   2B       WM_ARG_DX          arg delta-x signé (drag/resize)
;  $1E-$1F   2B       WM_ARG_DY          arg delta-y signé (drag/resize)
;  $20-$21   2B       WM_DP_TMP  ⚠️      scratch WM (clobbé par kernel_wm_offset)
;  $22       1B       WM_ARG_TITLE_LO    pointeur titre (lo)
;  $23       1B       WM_ARG_TITLE_HI    pointeur titre (hi)
;  $24       1B       WIN_SLOT           slot fenêtre courant (STABLE post-wm_offset)
;  $25-$2A   6B       WM_CRH_TMP         scratch _wm_chrome_hit (SP-3.h)
;  $32-$33   2B       WM_RH_TMP          scratch _wm_resize_hit (audit §3.6.2 :
;                                        ex WM_ARG_DX overload — conflit IRQ↔task)
;  $34-$3B   8B       PIR_RECT_*         rect 16-bit pour _point_in_rect16
;                                        (X/Y/W/H, audit §3.6 / axe 8.2)
;  $3C-$3D   2B       PIR_TMP            scratch interne _point_in_rect16
;  $2B       1B       WM_ZN_CACHE        cache ZP de WM_ZORDER_N (CPY/CPX sans mode long)
;  $2C-$2E   3B       SCHED_PTR          pointeur &tcb[pid] (scheduler, contexte IRQ)
;  $2F       1B       SCHED_CAND         pid candidat scan round-robin
;  $30-$31   2B       SCHED_TMP          scratch 16-bit (pid*20)
;  $32-$3F   14B      (libres)
;  $60-$62   3B       VRAM_OP_ADDR_*     adresse SDRAM 24-bit (vram_write/read_block)
;  $63-$64   2B       VRAM_OP_LEN_*      longueur 16-bit vram block
;  $65-$67   3B       VRAM_DMA_SRC_*_ZP  source DMA SDRAM 24-bit
;  $68-$6A   3B       VRAM_DMA_DST_*_ZP  destination DMA SDRAM 24-bit
;  $6B-$6C   2B       VRAM_DMA_LEN_*_ZP  longueur DMA 16-bit
;  $6D       1B       VRAM_DMA_DIR_ZP    direction DMA
;  $6E       1B       EVT_TMP            scratch IRQ-only (event push, ×10 offset)
;  $6F       1B       (libre)
;  $70-$72   3B       GFX_BASE_*         base SDRAM 24-bit GPU (clear/fill/blit...)
;  $73-$75   3B       GFX_ARG2_*         arg2 GPU (size|x/y/unused)
;  $76-$77   2B       GFX_ARG3_*         arg3 GPU (w/h | blit: byte_w 16-bit)
;  $78       1B       GFX_COLOR          couleur palette 4-bit (0..15)
;  $79-$7B   3B       GFX_FONT_*         font_addr 24-bit (GPU TEXT)
;  $7C-$7E   3B       GFX_STR_*          string_addr 24-bit (GPU TEXT)
;  $7F       1B       (libre)
;  $80-$8F   16B      WIN_X/…/TMP        args kernel_window_draw legacy (SP-3.c) + tmp scratch
;  $90-$91   2B       GFX_BPL_LO/HI      stride GPU configurable (ADR-27 opt.b, SET_BPL)
;  $92-$93   2B       GFX_ARG4_LO/MID    blit byte_h 16-bit (v0.2)
;  $94-$FF   108B     (libres)
; ════════════════════════════════════════════════════════════════════

; Zero page kernel (DP=0)
; print_string utilise DP_PTR (long indirect [dp],Y → bank 1 strings).
; print_char utilise DP_PCPTR (DP indirect (dp) → bank DBR=0 screen RAM).
; Séparés pour éviter conflit lors de print_char appelé depuis print_string.
DP_PTR          = $08            ; DP+$08/$09/$0A : pointer 24-bit
DP_PCPTR        = $0C            ; DP+$0C/$0D : pointer 16-bit
DP_TMP          = $10            ; DP+$10 : char temp
DP_SYS_ARG_X    = $11            ; DP+$11 : X sauvé avant corruption dispatch (OS-2.f.v2)
DP_KBD_TMP      = $12            ; DP+$12 : scratch ring clavier (OS-2.d)

; ── Scheduler N-tâches (OS-2.g v2.a) : scratch ZP dédié, zone libre $2C-$3F ──
; Utilisé uniquement par le scheduler en contexte IRQ. Disjoint de WM ($14-$2B),
; kbd ($12), FAT ($40+). (Réentrance ZP générale = dette #2, traitée v2.b/ADR-25.)
SCHED_PTR       = $2C            ; $2C-$2E : pointeur 24-bit &tcb[pid] (bank 1)
SCHED_CAND      = $2F            ; $2F : pid candidat dans le scan round-robin
SCHED_TMP       = $30            ; $30-$31 : scratch 16-bit (calcul pid*20, masque bitmap)
; kernel_task_create (g.3) : scratch ZP, zone libre $32-$3F.
TC_ENTRY_LO     = $32            ; entry PC lo
TC_ENTRY_HI     = $33            ; entry PC hi
TC_PRIO         = $34            ; priorité
TC_PID          = $35            ; pid alloué
TC_PAGE         = $36            ; page de pile (octet haut de S)
TC_FPTR         = $37            ; $37-$39 : pointeur 24-bit frame forgée (bank 0)
TC_CODE_BANK    = $3A            ; bank de code (PB) de la tâche à créer (entrée task_create).
                                ; Posé par l'appelant avant l'appel ; 1 = tâche kernel.
WCO_PID         = $3B            ; SP-3.m G.5 : scratch pid pour kernel_wm_close_owner
KW_TMP          = $3C            ; SP-3.m G.3 : scratch pid pour kernel_kbd_waiter_eligible

; ─── Charset (Sprint 2.c+) ──────────────────────────────────────────
; Le rendu Oric 1 mode TEXT lit la fonte char depuis bank 0 $B400-$B7FF
; (128 chars × 8 lignes). La ROM Oric 1 historique copie sa fonte ici
; au boot ; OricOS doit faire pareil puisqu'il boote sans la ROM.
; La fonte (1024 octets) est embedded dans le kernel.bin en bank 1
; à $5800 via .incbin (segment CHARSET).
CHARSET_SRC     = $015800        ; source Atmos (bank 1, mode TEXT Oric 1)
CHARSET_DST     = $00B400        ; dest (bank 0, Oric 1 mode TEXT)
CHARSET_XVGA_SRC = $015C00       ; source IBM CGA VGA8 (bank 1, après Atmos)
                                 ; — Doit être constante 24-bit pour que #^
                                 ; retourne la bank ($01). Le symbole de
                                 ; segment kernel_charset_xvga est 16-bit
                                 ; (linker ld65) → #^ = 0 → upload garbage.
CHARSET_SIZE    = $0400          ; 1024 octets (128 chars × 8 lignes)

STACK_A_TOP     = $01FF         ; bank 0, task A stack top
STACK_B_TOP     = $02FF         ; bank 0, task B stack top

; ─── VIA 6522 registers (bank 0 mappés $0300-$030F) ─────────────────
; Note 6522 : pour démarrer T1, écrire au registre T1C-H ($05). Le
; registre T1L-L/H ($06/$07) ne fait que poser le latch sans démarrer.
VIA_ORB         = $000300       ; port B (bits 0-2 = col select clavier)
VIA_ORA         = $000301       ; port A (bus PSG data)
VIA_DDRB        = $000302
VIA_DDRA        = $000303
VIA_T1CL        = $000304       ; T1 counter low (read=ack T1 / write=latch lo)
VIA_T1CH        = $000305       ; T1 counter high (write load+start)
VIA_ACR         = $00030B       ; Aux control (T1 mode)
VIA_PCR         = $00030C       ; Periph control (CA2/CB2 = BC1/BDIR PSG)
VIA_IFR         = $00030D       ; Interrupt flag register
VIA_IER         = $00030E       ; Interrupt enable register

; ─── FAT32 (Sprint 2.j.2/3 Oric 2) — buffer + résultat + champs ────
; Buffer 512B en bank 1 zone fill (après CHARSET). Distinct du buffer
; sd_read_block test ($015D40) pour ne pas écraser le pattern testé.
FS_BUFFER       = $015F60       ; 512 octets
FS_INIT_RESULT  = $016160       ; 1 octet : 0=OK, 1=BAD
FS_FAT32_SIG    = $52            ; offset signature "FAT32   " dans boot sector

; Champs parsés du boot sector (Sprint 2.j.3)
FS_BPS          = $016161       ; 2 bytes per sector
FS_SPC          = $016163       ; 1 sectors per cluster
FS_RSC          = $016164       ; 2 reserved sectors count
FS_NFAT         = $016166       ; 1 num FATs
FS_SPF          = $016167       ; 4 sectors per FAT (FAT32)
FS_ROOT         = $01616B       ; 4 root cluster (FAT32)
FS_FDS          = $01616F       ; 4 first data sector (calculé)

; Sprint 2.j.4 : résultats fat_open
FS_FOUND_CLUSTER = $016173      ; 4 first cluster du fichier trouvé
FS_FOUND_SIZE    = $016177      ; 4 size en octets
FS_OPEN_RESULT   = $01617B      ; 1 (0=OK, 1=NOT_FOUND)

; Sprint 2.j v0.2 : kernel_fat_next_cluster (cluster chain)
FS_NEXT_CLUSTER  = $01617C      ; 4 cluster suivant (>= $0FFFFFF8 = EOC)
FS_QUERY_CLUSTER = $016180      ; 4 cluster en entrée (caller setup)

; SP-3.o S.4b : champs texte éditables (GenText/LineEdit). Zone haute libre
; (au-dessus des structures FS). 8 buffers (1 par id widget) de 16 octets en
; bank 1 ; strptr du widget TEXT = TEXT_BUFS + id*16. TEXT_FOCUS_ID = id du champ
; ayant le focus clavier ($FF = aucun) ; les touches arrivant via MainLoop quand
; un champ est focalisé éditent son buffer.
TEXT_BUFS        = $016200      ; 8 × 16 = 128 octets ($6200-$627F)
TEXT_BUF_SZ      = 16
TEXT_MAX_LEN     = 14           ; 14 caractères + null (buffer 16o : char[len], null[len+1])
TEXT_FOCUS_ID    = $016280      ; 1B : id champ texte focalisé, $FF=aucun
TEXT_TMP_LEN     = $016281      ; 1B : scratch longueur courante (édition)
TEXT_TMP_MAX     = $016282      ; 1B : scratch longueur max (édition)
.assert TEXT_TMP_MAX < $01E000, error, "région TEXT hors zone RAM bank 1"

; Filename 11B en zero page (DP+$40..$4A)
DP_FILENAME      = $40

; Pointer entry courante en zero page (DP+$50..$52, 24-bit)
DP_ENTRY         = $50

; Offsets dans le boot sector
BS_BPS          = $0B
BS_SPC          = $0D
BS_RSC          = $0E
BS_NFAT         = $10
BS_SPF          = $24            ; FAT32 spécifique
BS_ROOT         = $2C            ; FAT32 spécifique

; Offsets dans une dir entry 32B
DE_NAME         = $00            ; 11 bytes
DE_ATTR         = $0B            ; 1 byte
DE_CLUS_HI      = $14            ; 2 bytes
DE_CLUS_LO      = $1A            ; 2 bytes
DE_SIZE         = $1C            ; 4 bytes
DE_SIZE_BYTES   = 32             ; total entry

DE_ATTR_LFN     = $0F            ; long filename : skip
DE_ATTR_DIR_VOL = $18            ; mask : volume_label ($08) | directory ($10)

; ─── SD device (Sprint 2.j Oric 2) — bloc 512 bytes via I/O ────────
; Mappé à $0320-$0327 dans bank 0 :
;   $0320  SD_LBA_LO   (R/W)
;   $0321  SD_LBA_MID  (R/W)
;   $0322  SD_LBA_HI   (R/W)
;   $0323  SD_CTRL     (R/W) — bit 0 = read trigger, bit 7 = busy
;   $0324  SD_DATA     (R)   — auto-increment lecture buffer
SD_LBA_LO       = $000320
SD_LBA_MID      = $000321
SD_LBA_HI       = $000322
SD_CTRL         = $000323
SD_DATA         = $000324
SD_CTRL_READ    = $01
SD_CTRL_BUSY    = $80

; ─── Driver clavier (Sprint 2.d) ────────────────────────────────────
; Matrice 8x8, scan via VIA ORB[0:2] (col select) + PSG R14 (rows).
; PSG bus : VIA CA2 = BC1, VIA CB2 = BDIR.
;   PCR = $EE → BDIR=1 BC1=1 (Latch Address)
;   PCR = $EA → BDIR=1 BC1=0 (Write Data)
;   PCR = $AE → BDIR=0 BC1=1 (Read Data)
;   PCR = $AA → Inactive (BDIR=0 BC1=0)
; Active low : 0 = touche pressée.
PCR_LATCH_ADDR  = $EE
PCR_WRITE_DATA  = $EA
PCR_READ_DATA   = $AE
PCR_INACTIVE    = $AA
KBD_MATRIX      = $019070       ; 8 octets bank 1 (legacy scan Oric 1, inutilisé OS-2.d)

; ─── Contrôleur clavier Oric 2 KBD2 (ADR-22, OS-2.d) ────────────────
; Modèle hybride paravirtualisé : l'hôte OricOS lit une FIFO ASCII via
; IRQ (plus de scan matriciel). Registres I/O bank 0 $0350-$035F.
KBD2_STATUS     = $000350       ; R : bit7=data_ready, bit6=overflow, bit0=guest_focus
KBD2_DATA       = $000351       ; R : pop FIFO (keycode ASCII), avance la file
KBD2_CTRL       = $000352       ; R/W : bit0=IRQ en, bit1=clear, bit2=route_guest
KBD2_MOD        = $000353       ; R : SHIFT/CTRL/FUNCT/CAPS
KBD2_ST_READY   = $80
KBD2_CT_IRQ_EN  = $01

; Ring buffer keycodes (ADR-16) — bank 1 $5860, 16 entrées (puissance de 2
; pour wrap via AND). Réutilise la région source charset, morte après la
; copie boot vers $B400 (cf. kernel_install_charset, même pattern que TCB).
KBD_RING        = $015860       ; 16 octets
KBD_RING_HEAD   = $015870       ; index lecture (pop)
KBD_RING_TAIL   = $015871       ; index écriture (push)
KBD_RING_COUNT  = $015872       ; nb octets en file (0..16)
KBD_RING_SIZE   = 16
KBD_RING_MASK   = KBD_RING_SIZE - 1
KBD_GETKEY_RES  = $019076       ; sentinelle test : résultat SYS_GET_KEY démo
SCROLL_TEST_RES = $019077       ; sentinelle test OS-2.e.2 : 4 octets (scroll+CR)

; ─── File d'événements unifiée (SP-3.n G.1, ADR-26 draft) ──────────
; Couche événementielle façon GeoWorks/GEOS : les drivers IRQ (KBD2, MOU2)
; postent des records d'événement ; consommée plus tard par SYS_MAIN_LOOP (G.2).
; Migration PROGRESSIVE : coexiste avec KBD_RING + MOUSE_* (les producteurs
; alimentent les deux en parallèle), donc aucune régression des consommateurs
; actuels. Logée dans la région charset morte ($015800-$015BFF), trou
; $015873-$01592F (avant MOUSE_X $015930).
; Record = 10 octets : what(1) message(2) mods(1) where_x(2) where_y(2) when(2).
EVENT_RING        = $015880      ; 160 octets = 16 entrées × 10
EVENT_RING_HEAD   = $015920      ; index entrée lecture (pop), 0..15
EVENT_RING_TAIL   = $015921      ; index entrée écriture (push), 0..15
EVENT_RING_COUNT  = $015922      ; nb événements en file (0..16)
EVENT_ENTRIES     = 16           ; puissance de 2 → wrap via AND
EVENT_SIZE        = 10
; Offsets de champ dans un record (octet)
EVT_WHAT          = 0
EVT_MSG_LO        = 1
EVT_MSG_HI        = 2
EVT_MODS          = 3
EVT_WHERE_X       = 4            ; 2B (position souris absolue XVGA)
EVT_WHERE_Y       = 6            ; 2B
EVT_WHEN          = 8            ; 2B (tick, best-effort v1)
; Types d'événement (champ what)
EV_NULL           = 0
EV_KEY_DOWN       = 1
EV_MOUSE_DOWN     = 2
EV_MOUSE_UP       = 3
EV_MOUSE_MOVED    = 4
EV_MENU_CLICK     = 5            ; ADR-30 Étape 2b : payload menu_id + item_id
; Messages sémantiques du MainLoop (SP-3.n G.3, SYS_MAIN_LOOP $17). Le MainLoop
; consomme les événements bruts et rend ces messages à l'app (modèle GeoWorks).
; Détails dans le bloc ZP $D0-$DF : MSG_KEY → keycode en $D1 ; MSG_CONTENT →
; id fenêtre en $DA. ($DA-$DF libres après le record d'événement $D0-$D9.)
MSG_NULL          = 0
MSG_KEY           = 1
MSG_CONTENT       = 2
MSG_CLOSE         = 3            ; G.3c
MSG_MENU          = 4            ; G.3c
MSG_CONTROL       = 5            ; G.4
; Tags de la table GenUI (SP-3.n G.3b, SYS_UI_DEFINE $18). L'app déclare son UI
; comme un flux de tags (modèle déclaratif GeoWorks). v1 : fenêtre + titre.
GU_END            = $00         ; fin de table
GU_WINDOW         = $01         ; suivi de x16 y16 w16 h16 (8 octets)
GU_TITLE          = $02         ; suivi d'une chaîne INLINE null-terminée (AVANT GU_WINDOW)
GU_BUTTON         = $03         ; suivi de relx16 rely16 relw16 relh16 + label INLINE null-term
GU_VIEW           = $04         ; suivi de relx16 rely16 relw16 relh16 + max8 (GenView, SP-3.o S.3c)
; SP-3.o S.5 : tags déclaratifs des contrôles « valeur/saisie » (rect 8 o + extra).
GU_CHECK          = $05         ; + relx16 rely16 relw16 relh16 + value8 (checkbox)
GU_SCROLL_V       = $06         ; + relx16 rely16 relw16 relh16 + max8 (ascenseur vertical)
GU_SCROLL_H       = $07         ; + relx16 rely16 relw16 relh16 + max8 (ascenseur horizontal)
GU_RADIO          = $08         ; + relx16 rely16 relw16 relh16 + value8 + group8 (radio)
GU_TEXT           = $09         ; + relx16 rely16 relw16 relh16 + maxlen8 (champ texte)
GU_LIST           = $0B         ; ADR-30 Étape 1 : + relx16 rely16 relw16 relh16 + count8 +
                                ; count chaînes null-term INLINE (alignement GeoWorks
                                ; GenListClass / gListC.def — items statiques v1)
GU_MENU           = $0C         ; ADR-30 Étape 2 : + nom INLINE null-term. Ouvre un menu
                                ; (à la place du `menu_defs` hardcodé). Suivi par 0..2
                                ; `GU_MENU_ITEM` jusqu'au prochain `GU_MENU` ou `GU_END`.
GU_MENU_ITEM      = $0D         ; ADR-30 Étape 2 : + label INLINE null-term. Item dans
                                ; le dernier menu déclaré. v1 : callback = 0 (clic
                                ; consommé silencieusement, post MSG_MENU à venir).
GU_SPIN           = $0F         ; ADR-30 Étape 4 : + relx16 rely16 relw16 relh16 + max8.
                                ; Incrémenteur (GeoWorks SpinClass). Value (+14) clampée
                                ; à [min..max] où min = GU_HINT_MIN_VALUE si présent.
GU_FIELD          = $10         ; ADR-30 Étape 5 : + relx16 rely16 relw16 relh16 + label inline.
                                ; Champ étiqueté (GeoWorks gFieldC) : label statique + value
                                ; courante affichée 2 digits. Non cliquable. Value posée par
                                ; l'app via SYS_CTL_SET_VALUE.
GU_SUBMENU        = $11         ; ADR-30 post-clôture (pattern GEOS DoMenu) : + nom inline.
                                ; Comme GU_MENU mais menu invisible du top-bar (caché). Ouvert
                                ; en clic sur un item dont cb_hi == $80, cb_lo = idx du submenu.
GU_MENU_OPEN      = $12         ; ADR-30 post-clôture : + label inline + submenu_idx8.
                                ; Item de menu qui ouvre un sub-menu au lieu d'envoyer MSG_MENU.

; ── ADR-29 Étape 2 : hints déclaratifs (alignement GeoWorks GenValueClass) ──
; Placés AVANT un widget value-type (GU_SCROLL_V/H, GU_VIEW) pour basculer ce
; widget seul en mode IMMEDIATE. Default (aucun hint) = DELAYED.
GU_HINT_IMMEDIATE_DRAG_NOTIFY = $0A   ; tag seul (pas de data)
HINT_DRAG_DELAYED   = $00         ; default — aligné HINT_VALUE_DELAYED_DRAG_NOTIFICATION
HINT_DRAG_IMMEDIATE = $01         ; opt-in — aligné HINT_VALUE_IMMEDIATE_DRAG_NOTIFICATION
; ── ADR-30 Étape 3 : hint ATTR_GEN_VALUE_MINIMUM (alignement GeoWorks GenValue)
; Placé AVANT un widget GU_SCROLL_V/H. SYS_CTL_GET_VALUE retourne value+min.
; Default (aucun hint) = min 0 (compat). GenRangeClass nuked 7/1992 par GeoWorks
; → l'attribut min sur GenValue couvre seul le besoin (cf. ADR-30 §Étape 3).
GU_HINT_MIN_VALUE   = $0E         ; + min8 (offset ajouté à la value retournée)
; Buffer de staging bank 1 : les chaînes inline (dans le bank de l'app) sont
; copiées ici pour que le rendu titre/label (qui lit en bank 1) les trouve.
; Gap libre après NMI_HANDLER ($5500, 1 octet rti). v1 : 1 seule chaîne label
; persistante à la fois (réutilisé après upload du titre en SDRAM).
UI_STR_BUF        = $015580      ; 32 octets
; SP-3.o S.2 : id du scrollbar en cours de drag (thumb), $FF = aucun. Persiste
; entre les appels MainLoop (le drag couvre down→moved*→up).
SCROLL_DRAG_ID    = $0155A0
.assert SCROLL_DRAG_ID + 1 <= $015600, error, "scroll/UI buf recouvre IRQ_HANDLER ($5600)"
; Tags de la command table DoDlgBox (SP-3.n G.5, SYS_DO_DLGBOX $19, style GEOS).
; Le dialogue EST une donnée : l'app passe la table, le kernel l'exécute modalement.
DB_END            = $00         ; fin de table
DB_POSITION       = $01         ; suivi de x16 y16 w16 h16 (géométrie dialogue)
DB_OK             = $02         ; bouton OK (auto-positionné, terminant → retour 1)
DB_CANCEL         = $03         ; bouton Cancel (auto-positionné, terminant → retour 0)
DB_TEXT           = $04         ; SP-3.p D.1 : texte du dialogue (GEOS DBTXTSTR) —
                                ; suivi de relx16 rely16 ptr16 (chaîne null-term dans
                                ; le bank de la table). Rendu proportionnel (LABELP).
; Types d'alerte (SP-3.n G.6, SYS_ALERT $1A — arg X). Construites sur DoDlgBox.
; Retour : 1 = bouton gauche (OK/Yes), 0 = bouton droit (Cancel/No).
ALERT_OK          = $00         ; un seul bouton OK
ALERT_OKCANCEL    = $01         ; OK + Cancel
ALERT_YESNO       = $02         ; Yes + No
; Scratch ZP dédié au push (IRQ-only → I=1, pas de nesting ; $6E libre)
EVT_TMP           = $6E
; SP-3.n G.2 : tâche bloquée sur SYS_GET_NEXT_EVENT (0=aucune). Mono-waiter v1
; (cohérent avec KBD_WAITER ; signaux multi-bits génériques = polish #1).
EVENT_WAITER      = $015923
; SP-3.n G.3c : mode « app-driven ». Posé à $A5 par SYS_MAIN_LOOP (une app pilote
; la boucle d'événements) → le shell (kernel_wm_mouse_step) NE ferme plus une
; fenêtre au clic close-box : l'app reçoit MSG_CLOSE et décide (modèle GeoWorks).
; Sinon (desktop sans app, ex. tests SP-3.f) : auto-close conservé.
WM_APP_DRIVEN     = $015924
; SP-3.n G.5 : état DoDlgBox (modal). DLG_WIN = slot fenêtre dialogue,
; DLG_OK_ID/DLG_CANCEL_ID = index widgets boutons terminants ($FF=absent),
; DLG_RESULT = retour (1=OK, 0=Cancel).
DLG_WIN           = $015925
DLG_OK_ID         = $015926
DLG_CANCEL_ID     = $015927
DLG_RESULT        = $015928
.assert EVENT_RING + EVENT_ENTRIES * EVENT_SIZE <= EVENT_RING_HEAD, error, "EVENT_RING recouvre ses pointeurs"
.assert DLG_RESULT < MOUSE_X, error, "état event/dlg recouvre MOUSE_X"

; ── ADR-28 Étape 0 : RAW input ring (scaffolding, NON câblé) ─────────────
; File d'entrée BRUTE destinée à terme à la tâche serveur WM (ADR-28 §7.0) :
; l'IRQ y postera les events souris/clavier verbatim, le serveur les consommera
; en contexte tâche. Pour l'instant AUCUN producteur/consommateur n'est branché
; (mort-code testé en isolation, cf. test_oricos_raw_ring). Même géométrie que
; EVENT_RING (16 × 10). Record verbatim copié via le bloc ZP $D0..$D9 (comme
; kernel_event_pop). Logé en bank 1 haute libre ($016400+, au-dessus de
; VERSION_BASE $016310).
RAW_RING          = $016400      ; 160 octets = 16 entrées × 10
RAW_RING_HEAD     = $0164A0      ; index lecture (pop), 0..15
RAW_RING_TAIL     = $0164A1      ; index écriture (push), 0..15
RAW_RING_COUNT    = $0164A2      ; nb records en file (0..16)
RAW_WAITER        = $0164A3      ; tâche serveur WM bloquée (0=aucune) — Étape 2
.assert RAW_RING + EVENT_ENTRIES * EVENT_SIZE <= RAW_RING_HEAD, error, "RAW_RING recouvre ses pointeurs"
.assert RAW_WAITER < $01FFE0, error, "RAW_RING déborde sur les vecteurs natifs bank 1"

; ─── GPU Blitter HW I/O (ADR-21, Sprint GPU-3) ────────────────────
; Ports $0340-$034F en bank 0 (DBR=0).
GPU_CMD_OP_IO    = $000340
GPU_ARG1_LO_IO   = $000341
GPU_ARG1_MID_IO  = $000342
GPU_ARG1_HI_IO   = $000343
GPU_ARG2_LO_IO   = $000344
GPU_ARG2_MID_IO  = $000345
GPU_ARG2_HI_IO   = $000346
GPU_ARG3_LO_IO   = $000347
GPU_ARG3_MID_IO  = $000348
GPU_ARG3_HI_IO   = $000349
GPU_ARG4_LO_IO   = $00034A
GPU_ARG4_MID_IO  = $00034B
GPU_ARG4_HI_IO   = $00034C
GPU_STATUS_IO    = $00034D
GPU_TRIGGER_IO   = $00034E
GPU_INT_CTRL_IO  = $00034F

GPU_OP_CLEAR     = $01
GPU_OP_FILL_RECT = $02
GPU_OP_FILL_RECT16 = $06         ; coords 16-bit packed (ADR-21 v0.2)
GPU_OP_BLIT      = $03
GPU_OP_LINE      = $04
GPU_OP_TEXT      = $05
GPU_OP_SET_BPL   = $08           ; ADR-27 opt.b : stride configurable (ARG1[15:0]=bpl, 0→512)
GPU_STATUS_BUSY  = $80
GPU_STATUS_ERR   = $40

; ZP args pour kernel_window_draw (Sprint 3.c v0.1)
WIN_X            = $80           ; coin haut-gauche x (8-bit)
WIN_Y            = $81           ; coin haut-gauche y (8-bit)
WIN_W            = $82           ; largeur (8-bit)
WIN_H            = $83           ; hauteur (8-bit)
WIN_TITLEBAR_H   = $84           ; hauteur title bar (8-bit, typ. 8)
WIN_COLOR_FRAME  = $85           ; couleur cadre (4-bit)
WIN_COLOR_TITLE  = $86           ; couleur title bar
WIN_COLOR_BODY   = $87           ; couleur corps
WIN_BASE_LO      = $88           ; base SDRAM framebuffer (24-bit)
WIN_BASE_MID     = $89
WIN_BASE_HI      = $8A
; Tmp $8B-$8F pour calculs (X+W-1, Y+H-1)
WIN_TMP_X_END    = $8B
WIN_TMP_Y_END    = $8C

; ─── Souris Oric 2 MOU2 (ADR-24, SP-3.e) — I/O bank 0 $0360-$036F ────
MOU2_STATUS      = $000360       ; R : bit7=event, bit0=G bit1=D bit2=M
MOU2_X_LO        = $000361
MOU2_X_HI        = $000362
MOU2_Y_LO        = $000363
MOU2_Y_HI        = $000364
MOU2_BUTTONS     = $000365
MOU2_CTRL        = $000366       ; bit0=IRQ en, bit1=clear event
MOU2_DX          = $000367       ; R : delta X signé (read-clear)
MOU2_DY          = $000368       ; R : delta Y signé (read-clear)
MOU2_CT_IRQ_EN   = $01
MOU2_BTN_LEFT    = $01

; ─── Sprite HW curseur Oric 2 (ADR-33) — I/O bank 0 $0370-$037F ─────
SPR_X_LO         = $000370
SPR_X_HI         = $000371       ; bits [9:8]
SPR_Y_LO         = $000372
SPR_Y_HI         = $000373       ; bits [9:8]
SPR_ENABLE       = $000374       ; $A5 = on
SPR_DATA_IDX_LO  = $000375       ; reset index data byte
SPR_DATA_IDX_HI  = $000376
SPR_DATA         = $000377       ; data[IDX], auto-incrément
SPR_ENABLE_ON    = $A5

; État souris (bank 1)
MOUSE_X          = $015930       ; 2B position absolue
MOUSE_Y          = $015932       ; 2B
MOUSE_BTN        = $015934       ; 1B boutons courants
MOUSE_PREV_BTN   = $015935       ; 1B boutons frame précédente (edge-detect clic)
MOUSE_DX         = $015936       ; 1B delta X signé par événement (lu de MOU2_DX)
MOUSE_DY         = $015937       ; 1B delta Y signé par événement
WM_DRAG_ARMED    = $015938       ; 1B : 1 si le clic a atterri sur une fenêtre (drag autorisé)
; BUG_drag_glitch_taskmode (2026-06-02) — état event-derived pour mouse_step en taskmode.
; En WM_TASKMODE=$A5, task_wm copie event → MOUSE_X/Y/BTN/DX/DY AVANT mouse_step.
; Delta dérivé par soustraction des positions consécutives (Option A du dossier).
WM_LAST_X        = $015939       ; 2B : position event précédent (pour delta)
WM_LAST_Y        = $01593B       ; 2B
WM_LAST_BTN      = $01593D       ; 1B : bouton event précédent
WM_LAST_INIT     = $01593E       ; 1B : $A5 si WM_LAST_* initialisé (premier event = setup)
WM_TEST_RES      = $015940       ; sentinelle test SP-3.e (12 octets)
; ── SP-3.e v0.6 : backing-store curseur (évite le full-redraw par mouvement) ──
CURSOR_SAVE      = $015950       ; 32B : pixels sauvés sous le curseur (8px×8 = 4B×8)
CURSOR_OLD_X     = $015970       ; 2B : position du backing courant (clampée)
CURSOR_OLD_Y     = $015972       ; 2B
CURSOR_VALID     = $015974       ; 1B : 1 si CURSOR_SAVE/OLD valides
CUR_DRAW_X       = $015975       ; 2B : position de dessin clampée [0,1016]×[0,760]
CUR_DRAW_Y       = $015977       ; 2B
CUR_XB           = $015979       ; 2B : temp x>>1
CUR_MIDHI        = $01597B       ; 2B : temp (mid,hi) de l'adresse SDRAM
; ── SP-3.e v0.7 : drag incrémental (efface l'ancien rect, pas tout l'écran) ──
WM_DRAG_OLD_X    = $01597D       ; 2B : rect fenêtre AVANT déplacement (dirty rect)
WM_DRAG_OLD_Y    = $01597F       ; 2B
WM_DRAG_OLD_W    = $015981       ; 2B
WM_DRAG_OLD_H    = $015983       ; 2B
WM_TITLE_COL     = $015985       ; 1B : couleur titlebar courante (focus/non-focus)
; BUG_drag_v2_fragments Fix A : delta 16-bit pour drag taskmode (un sat8/truncation
; inversait le signe pour les sauts > 127 px). MOUSE_DX/DY 8-bit conservé pour
; legacy + IRQ. install_event_state écrit ici le delta 16-bit signé COMPLET.
; kernel_mouse_read sign-extend MOUSE_DX→MOUSE_DX16 pour cohérence en legacy.
; _wm_do_drag / _wm_do_resize lisent MOUSE_DX16/DY16 (plus de _sext8_to16).
MOUSE_DX16       = $015986       ; 2B : delta X signé 16-bit (cohérent taskmode + legacy)
MOUSE_DY16       = $015988       ; 2B : delta Y signé 16-bit
; ── SP-3.f : table de flags de titres (4 fenêtres × 1B = 4B) ─────────
; Slot : $01 = titre présent (uploadé en SDRAM $012000+slot*$100), $00 = pas de titre.
; Les titres sont stockés en SDRAM : slot 0 → $012000, slot 1 → $012100,
; slot 2 → $012200, slot 3 → $012300 (256 o max par titre, suffit pour 255 chars).
; Uploadés au moment de kernel_wm_add (hors IRQ context, safe pour DP_PCPTR).
WM_TITLES        = $015B74       ; 8 × 1B = 8 octets ($5B74-$5B7B, WM_MAX=8)
; ZP args pour kernel_wm_add (titre, bank1 pointer 16-bit)
WM_ARG_TITLE_LO  = $22           ; low byte du pointer titre
WM_ARG_TITLE_HI  = $23           ; high byte du pointer titre
WIN_SLOT         = $24           ; slot courant pour kernel_window_draw (SP-3.f)
; Base SDRAM pour les titres (4 slots × 256 octets = $400 = 1KiB)
WM_SDRAM_TITLE_BASE_MID = $20    ; addr mid du slot 0 : $01_20_00 = $012000
; Scratch SDRAM pour close button string "X\0" (8 octets alignés, hors scratch label $011000)
WM_CLOSE_STR     = $011080       ; "X\0" uploadé au boot
; ── SP-3.d : temps toolkit (rect bouton + rect frame, distincts) ──────
TK_X             = $015990       ; 2B : rect bouton
TK_Y             = $015992       ; 2B
TK_W             = $015994       ; 2B
TK_H             = $015996       ; 2B
TKF_X            = $015998       ; 2B : rect frame (distinct, frame appelé par bouton)
TKF_Y            = $01599A       ; 2B
TKF_W            = $01599C       ; 2B
TKF_H            = $01599E       ; 2B
; ── SP-3.d v0.2 : widgets managés (attachés à une fenêtre) ────────────
; Table 8 widgets × 16 o à $015A00. Entrée :
;   +0 flags(used) +1 parent_win +2 type(0=label,1=button) +3 color
;   +4 rel_x(2) +6 rel_y(2) +8 rel_w(2) +10 rel_h(2) +12 str_off(2, bank1)
WIDGET_TABLE     = $015A00       ; 8 × 16 = 128 o ($5A00-$5A7F)
WIDGET_COUNT     = $015A80       ; 1B : nb widgets
WIDGET_ACTIVE    = $015A81       ; 1B : widget bouton cliqué (actif) ou $FF
TK_BTN_PRESSED   = $015A82       ; 1B : 0=normal 1=pressé (face couleur)
TK_COL_BTN_PRESS = $08           ; bouton pressé : face darkgray
; ── SP-3.d v0.4 : callbacks de bouton ─────────────────────────────────
WG_CB            = $015A83       ; 2B : input add_widget (offset callback bank1, 0=aucun)
WG_CB_VEC        = $015A85       ; 2B : vecteur pour jsr (abs,X) indirect
CB_FLAG          = $015A87       ; 1B : compteur démo (clics sur "OK")
; ── SP-3.d v0.5/v0.6 : barre de menu déroulant (table de N menus) ─────
MENU_OPEN        = $015A88       ; 1B : index menu ouvert, ou $FF=fermé
MENU_I           = $015A89       ; 1B : index boucle menu
MENU_HOVER       = $015A8A       ; 1B : item du dropdown sous la souris (0/1,
                                 ;   $FF=aucun) — surlignage GeoWorks (SP-GUI M.2)
MENU_BAR_H       = 14            ; hauteur barre de menu (px)
MENU_N           = 2             ; nb de menus dans la barre (top-level static)
MENU_TOTAL_N     = 4             ; nb total de menus en table (top + submenus dyn, ADR-30 post-clôture)
MENU_ENTSZ       = 16            ; taille entrée menu_defs (octets)
WIDGET_MAX       = 8
WIDGET_ENTSZ     = 16
WG_TYPE_LABEL    = $00
WG_TYPE_BUTTON   = $01
WG_TYPE_CHECK    = $02           ; SP-3.o S.1 : checkbox (GenBoolean) ; value en +14
WG_TYPE_SCROLL_V = $03           ; SP-3.o S.2 : ascenseur vertical ; value(+14)/max(+15)
WG_TYPE_SCROLL_H = $04           ; SP-3.o S.2 : ascenseur horizontal
WG_TYPE_VIEW     = $05           ; SP-3.o S.3 : GenView (viewport scrollable) ;
                                 ; scroll_y(+14) / content_h(+15), scrollbar intégré bord droit
WG_TYPE_RADIO    = $06           ; SP-3.o S.4a : radio (GenItemGroup) ; selected(+14)/group(+15)
                                 ; exclusion mutuelle par group id ; rendu = case colorée (comme check)
WG_TYPE_TEXT     = $07           ; SP-3.o S.4b : champ texte éditable (GenText/LineEdit) ;
                                 ; strptr(+12/13)=buffer TEXT_BUFS+id*16, length(+14)/maxlen(+15)
WG_TYPE_LIST     = $08           ; SP-3.o S.4c : liste (GenList) ; strptr(+12/13)=blob d'items
WG_TYPE_SPIN     = $09           ; ADR-30 Étape 4 : incrémenteur (GenValue, alignement
                                 ; GeoWorks SpinClass). value(+14) ; max(+15). Click haut
                                 ; moitié = +1, click bas moitié = -1, clamp [min..max].
WG_TYPE_FIELD    = $0A           ; ADR-30 Étape 5 : champ étiqueté (gFieldC). Label statique
WG_TYPE_LABELP   = $0B           ; SP-3.p F.1 : label PROPORTIONNEL (FONT_WIDTHS,
                                 ; kernel_tk_label_prop). Utilisé par DB_TEXT (dialogues)
                                 ; et SYS_ALERT (message). strptr (+12/13) comme LABEL.
                                 ; (strptr +12/13 bank 1) + value (+14) affichée 2 digits.
                                 ; Non cliquable. Update via SYS_CTL_SET_VALUE.
                                 ; (count slots de LIST_ITEM_STRIDE o), selected(+14)/count(+15)
LIST_ITEM_STRIDE = 8             ; octets par item (7 caractères + null)
LIST_ITEM_H      = 16            ; hauteur d'une ligne d'item (px) — puissance de 2 (>>4)
SCROLL_THUMB_SZ  = 16            ; taille du thumb (px) le long de la gouttière
VIEW_SB_W        = 12            ; largeur de la barre intégrée du GenView (bord droit)
WG_COL_TRACK     = $08           ; gouttière : darkgray
WG_COL_THUMB     = $0F           ; thumb : blanc
WG_COL_VIEW_BODY = $07           ; corps du viewport : lightgray
; SP-3.o S.1 : API valeur de contrôle. Pour les contrôles « valeur » (check,
; scrollbar…), le champ callback du record widget (+14/+15) est réutilisé comme
; value(+14)/max(+15) — exclusif du callback (réservé aux boutons). Le rendu
; reflète l'état via la couleur (+3) : coché = lightblue, décoché = lightgray.
WG_OFF_VALUE     = 14
WG_OFF_MAX       = 15
WG_COL_CHECKED   = $09           ; lightblue (coché)
WG_COL_UNCHECKED = $07           ; lightgray (décoché)
WG_I             = $015A90       ; 1B : index boucle (_wm_draw_widgets_for_slot)
WG_PARENT        = $015A91       ; 1B
WG_TYPE          = $015A92       ; 1B
WG_RELX          = $015A94       ; 2B
WG_RELY          = $015A96       ; 2B
WG_RELW          = $015A98       ; 2B
WG_RELH          = $015A9A       ; 2B

; ─── SP-3.g : taskbar (band y=755..767 du desktop XVGA) ─────────────
; Fond + séparateur dessinés par kernel_taskbar_draw, clic par kernel_taskbar_hit.
TB_I             = $015A9C       ; 1B : index boucle taskbar
TB_BTN_X         = $015A9E       ; 2B : btn_x courant (4 + i*124)
TB_WIN_SCRATCH   = $015AA0       ; 5B : "WinN\0" en bank 1 RAM (source pour upload)
TB_CLK_SCRATCH   = $015AA5       ; 5B : "TNNN\0" bank 1 (horloge taskbar)
; ── SP-3.h : états maximize/minimize + rects sauvegardés ──────────────
WM_STATE_NORMAL      = $00       ; état fenêtre : normal
WM_STATE_MAXED       = $01       ; état fenêtre : maximisée
WM_STATE_HIDDEN      = $02       ; état fenêtre : minimisée depuis état normal
WM_STATE_HIDDEN_MAXED= $03       ; état fenêtre : minimisée depuis état maximisé
WM_STATES        = $015B7C       ; 8 × 1B : état par slot ($5B7C-$5B83, WM_MAX=8)
WM_SAVED_RECTS   = $015B84       ; 8 × 8B : x(2)+y(2)+w(2)+h(2) avant maximize ($5B84-$5BC3, WM_MAX=8)
WM_H_TEST_RES    = $015AC9       ; sentinelle test SP-3.h (5 octets)
; ── SP-3.i : resize des fenêtres (bord droit + bas) ──────────────────
WM_RESIZE_ARMED  = $015ACE       ; 1B : 1 si resize armé (bouton tenu sur bord)
WM_RESIZE_EDGE   = $015ACF       ; 1B : 1=droit, 2=bas, 3=coin
WM_I_TEST_RES    = $015AD0       ; sentinelle test SP-3.i (5 octets)
; ── SP-3.j : dialog modal ──────────────────────────────────────────────
WM_MODAL         = $015AD5       ; 1B : slot fenêtre modale ($FF = aucune)
WM_J_TEST_RES    = $015AD6       ; sentinelle test SP-3.j (4 octets)
; ── SP-3.k : icônes desktop ────────────────────────────────────────────
; Entrée : flags(1) color(1) x(2) y(2) cb_lo(1) cb_hi(1) label(7+null=8) = 16B
ICON_MAX         = 4
ICON_ENTSZ       = 16
ICON_TABLE       = $015ADA       ; 4 × 16B = 64B ($5ADA-$5B19)
ICON_COUNT       = $015B1A       ; 1B : nb icônes actives
ICON_SELECTED    = $015B1B       ; 1B : id sélectionné ($FF=aucun)
ICON_K_TEST_RES  = $015B1C       ; sentinelle test SP-3.k (4 octets)
; Offsets dans une entrée ICON_TABLE
ICON_OFF_FLAGS   = 0             ; 1B : $00=libre, $01=utilisé, $03=sélectionné
ICON_OFF_COLOR   = 1             ; 1B : couleur boîte (palette 0..15)
ICON_OFF_X       = 2             ; 2B : x desktop
ICON_OFF_Y       = 4             ; 2B : y desktop
ICON_OFF_CB_LO   = 6             ; 1B : callback offset low (0=aucun)
ICON_OFF_CB_HI   = 7             ; 1B : callback offset high
ICON_OFF_LABEL   = 8             ; 8B : label ASCII null-terminé (max 7 chars)
; SDRAM labels : $011200 + id*$10 (16B par icône)
ICON_SDRAM_BASE_LO = $12         ; addr mid du bank 1 label base : $01_12_00
ICON_SDRAM_BASE_HI = $01
ICON_SIZE_PX     = 32            ; côté de la boîte icon en pixels
ICON_F_USED      = $01
ICON_F_SEL       = $03           ; used + selected
RESIZE_MARGIN    = 6             ; px de marge bord pour hit-test resize
RESIZE_MIN_W     = 60            ; largeur minimale fenêtre
RESIZE_MIN_H     = 40            ; hauteur minimale fenêtre
; Strings boutons max/min uploadées en SDRAM au boot
WM_MAX_STR       = $011090       ; "O\0" uploadé au boot (□ simplifié)
WM_MIN_STR       = $0110A0       ; "_\0" uploadé au boot
; Offsets relatifs (depuis win_x+win_w) pour les boutons chrome
BTN_MAX_OFFSET   = 22            ; □ : 12px à gauche du ×
BTN_MIN_OFFSET   = 34            ; _ : 24px à gauche du ×
TB_WIN_SDRAM     = $011100       ; adresse SDRAM du scratch "WinN\0" (5 bytes)
TB_CLK_SDRAM     = $011200       ; adresse SDRAM du scratch horloge (5 bytes)

; Taskbar layout (ADR-20 XVGA 1024×768)
TB_Y_SEP         = 755           ; y du séparateur blanc (1 px)
TB_Y_FILL        = 755           ; y du fond (inclut séparateur)
TB_H             = 13            ; h fond (y=755..767)
TB_BTN_Y         = 757           ; y du bouton
TB_BTN_H         = 10            ; h du bouton
TB_BTN_TY        = 758           ; y du texte bouton
TB_BTN_W         = 120           ; largeur bouton
TB_BTN_SP        = 4             ; spacing gauche initial
TB_BTN_STRIDE    = 124           ; 120 + 4px entre boutons

WIN_TITLE_FOCUS  = $09           ; titlebar fenêtre focus : lightblue vif
WIN_TITLE_NORMAL = $08           ; titlebar fenêtre non focus : darkgray
NO_STP_FLAG      = $01EF00        ; SP-3.e v0.4 : $A5 (posé par --kernel) → pas de STP (live)
TC_HELLOC_FLAG   = $01EF10        ; TC-poc-hello-c : $A5 (posé par le test) → exec bundle_hello_c (JSL)
TC_HELLOC_TASK_FLAG = $01EF20     ; OS-2.g v2.b : $A5 → spawn bundle_hello_c comme TÂCHE schedulée
TC_WIN_FLAG      = $01EF30        ; SP-3.m G.2 : $A5 → crée task_win (test SYS_WIN_CREATE)
TC_WDRAW_FLAG    = $01EF40        ; SP-3.m G.4 : $A5 → crée task_wdraw (test dessin fenêtré)
TC_WINAPP_FLAG   = $01EF50        ; SP-3.m G.6 : $A5 → spawn bundle_win (app C démo fenêtrée)
TC_EVT_FLAG      = $01EF60        ; SP-3.n G.2 : $A5 → crée task_evt (test SYS_GET_NEXT_EVENT)
TC_ML_FLAG       = $01EF70        ; SP-3.n G.3a : $A5 → crée task_ml (test SYS_MAIN_LOOP)
TC_UI_FLAG       = $01EF80        ; SP-3.n G.3b : $A5 → crée task_ui (test SYS_UI_DEFINE)
TC_DLG_FLAG      = $01EF90        ; SP-3.n G.5 : $A5 → crée task_dlg (test SYS_DO_DLGBOX)
TC_ALERT_FLAG    = $01EFA0        ; SP-3.n G.6 : $A5 → crée task_alert (test SYS_ALERT)
TC_GUIAPP_FLAG   = $01EFB0        ; SP-3.n G.7 : $A5 → spawn bundle_gui (app C démo GUI)
TC_CHK_FLAG      = $01EFC0        ; SP-3.o S.1 : $A5 → crée task_chk (test API valeur/checkbox)
TC_SCR_FLAG      = $01EFD0        ; SP-3.o S.2 : $A5 → crée task_scr (test scrollbar/drag)
TC_VIEW_FLAG     = $01EFE0        ; SP-3.o S.3 : $A5 → crée task_view (test GenView/scroll)
TC_VIEWAPP_FLAG  = $01EFF0        ; SP-3.o S.3c : $A5 → spawn bundle_view (app C GenView déclaratif)
TC_RAD_FLAG      = $01EE00        ; SP-3.o S.4a : $A5 → crée task_radio (test radios/exclusion)
TC_TEXT_FLAG     = $01EE10        ; SP-3.o S.4b : $A5 → crée task_text (test champ texte éditable)
TC_LIST_FLAG     = $01EE20        ; SP-3.o S.4c : $A5 → crée task_list (test liste/sélection)
TC_GENUI_FLAG    = $01EE30        ; SP-3.o S.5 : $A5 → crée task_genui (test tags GenUI déclaratifs)
TC_CTLAPP_FLAG   = $01EE40        ; SP-3.o S.6 : $A5 → spawn bundle_ctl (app C démo contrôles)
TC_CLOCKAPP_FLAG = $01EE50        ; Sprint 4 : $A5 → spawn bundle_clock (app C clock)
TC_CPCT_FLAG     = $01EEA0        ; ADR-27 B2.c v2 : $A5 → crée task_compact (flip + C-2 garde XVGA)
TC_FILESELECT_FLAG = $01EEB0      ; $A5 → spawn bundle_fileselect (file selector dialog)
TC_SCOREAPP_FLAG = $01EE80        ; ADR-30 capstone : $A5 → spawn bundle_score (app C démo
                                  ; complète exerçant FIELD + BUTTONs + MENU + set_value)
TC_WM_FLAG       = $01EE60        ; ADR-28 Étape 2 : $A5 → crée task_wm (serveur WM passe-plat)
                                  ;   BASCULE 2026-06-10 : posé $A5 PAR LE BOOT par défaut
TC_WM_LEGACY     = $01EE90        ; ADR-28 bascule : $A5 (poké pré-boot par --wm-legacy ou
                                  ;   un test) → opt-out explicite : pas de task_wm, l'IRQ
                                  ;   rend comme avant (chemin legacy conservé et testé)
PANIC_NO_TASK_SLOT = $E8          ; R5 : kernel_task_create → 0 pour une tâche SYSTÈME
WM_TASKMODE      = $01EE68        ; ADR-32 §3 : $A5 → IRQ skip mouse_step + task_wm le fait
                                  ; (anti-revert ADR-28 Étape 3 ; default $00 = comportement
                                  ; actuel ; rollback runtime instantané possible)
WM_DRAG_NOTIFY_HINT = $01EE70     ; ADR-29 Étape 1 : 0 (default) = DELAYED_DRAG_NOTIFICATION
                                  ;                  $A5 = override IMMEDIATE global (kill-switch debug)
WIDGET_HINTS        = $016320     ; ADR-29 Étape 2 : 8 × 1B = hint par widget (0=DELAYED, 1=IMMEDIATE)
UI_PENDING_HINT     = $016328     ; ADR-29 Étape 2 : 1B = hint en attente, posé sur le prochain widget créé
.assert UI_PENDING_HINT < $016400, error, "WIDGET_HINTS déborde sur RAW_RING"
UI_LIST_BUF         = $016330     ; ADR-30 Étape 1 : 128B buffer items GU_LIST (~10 items × 12 chars)
.assert UI_LIST_BUF + 128 <= $016400, error, "UI_LIST_BUF déborde sur RAW_RING"
; ── ADR-30 Étape 3 : attribut min par widget (offset ajouté par SYS_CTL_GET_VALUE)
WIDGET_MIN_VALUES   = $0163B0     ; 8 × 1B (un par widget, idx = id widget)
UI_PENDING_MIN_VALUE = $0163B8    ; 1B = min en attente, posé sur prochain widget créé
.assert UI_PENDING_MIN_VALUE < $016400, error, "WIDGET_MIN_VALUES déborde sur RAW_RING"
; ── ADR-30 Étape 2 : structures du parser GU_MENU / GU_MENU_ITEM ──────
; Bank 1, zone libre post-RAW_RING ($0164A4+).
MENU_DYN_ACTIVE   = $0164B0     ; 1B : $A5 = menus dyn parsés (override menu_defs)
MENU_DYN_COUNT    = $0164B1     ; 1B : nb menus total (top + submenus), 0..MENU_TOTAL_N
MENU_DYN_ITEM_CNT = $0164B2     ; 1B : nb items posés dans le menu courant (0..2)
MENU_DYN_STR_OFF  = $0164B3     ; 1B : offset courant dans MENU_DYN_STR_BUF
MENU_DYN_COUNT_BAR = $0164B4    ; 1B : nb menus dans la barre top (0..MENU_N), submenus exclus
MENU_DYN_STR_BUF  = $0164C0     ; 192B : titres + labels (offset référencé par menu_defs)
.assert MENU_DYN_STR_BUF + 192 <= $01FFE0, error, "MENU_DYN_STR_BUF déborde sur les vecteurs natifs"
; ── ADR-30 Étape 4 : scratch pour kernel_ctl_spin_click ──
SPIN_ID           = $016580     ; 1B : id widget en cours de spin click
SPIN_TMP          = $016581     ; 1B : scratch (min value, etc.)
; ── ADR-30 Étape 5 : buffer pour labels des champs GU_FIELD ──
; 128 octets (jusqu'à 8 champs × ~16 chars en moyenne).
FIELD_STR_BUF     = $016600
; ── Pattern GEOS InitProcesses (post-clôture ADR-30, 2026-05-30) ──
; Table de N timers globaux. 8 entrées × 4 octets = 32 octets.
; Entrée : +0 flag (0=libre, 1=actif, 2=bloqué) ; +1 owner_pid ;
;          +2 period8 ; +3 counter8 (décrémenté par VIA T1 IRQ).
; Quand counter atteint 0 : post EV_TIMER au owner + reload counter=period.
TIMER_N           = 8
TIMER_ENTSZ       = 4
TIMER_TABLE       = $016700
.assert TIMER_TABLE + TIMER_N*TIMER_ENTSZ <= $01FFE0, error, "TIMER_TABLE déborde sur les vecteurs natifs"
TIMER_F_FREE      = $00
TIMER_F_ACTIVE    = $01
TIMER_F_BLOCKED   = $02
EV_TIMER          = 6
MSG_TIMER         = 6
; ── Pattern GEOS DoIcons (post-clôture ADR-30, 2026-05-30) ──
; Table de N hot-zones globales — rectangles cliquables sans widget chrome.
; 8 entrées × 10 octets : flag (1B), win_slot (1B), x_rel16 (2B), y_rel16 (2B),
; w16 (2B), h16 (2B). id implicite = index dans la table.
; Posté en MSG_CONTROL avec $DA = 128 | hotzone_id (high bit distingue
; hotzones des widgets, id 0..15).
HOTZONE_N         = 8
HOTZONE_ENTSZ     = 10
HOTZONE_TABLE     = $016800
HOTZONE_F_FREE    = $00
HOTZONE_F_ACTIVE  = $01
HOTZONE_ID_BASE   = $80         ; bit 7 = « c'est une hotzone, pas un widget »
HOTZONE_DEBUG_FLAG = $01EE90    ; $A5 → draw cadre 1px autour des hotzones actives
                                ; (off par défaut, affecte le framebuffer → tests rouges).
.assert HOTZONE_TABLE + HOTZONE_N*HOTZONE_ENTSZ <= $01FFE0, error, "HOTZONE_TABLE déborde sur les vecteurs natifs"
FIELD_STR_OFF     = $016680     ; 1B : offset d'écriture courant dans le buffer
.assert FIELD_STR_OFF < $01FFE0, error, "FIELD_STR_BUF déborde sur vecteurs natifs"

; ── ADR-27 Étape A : shadow kernel du registre GPU `bpl` ────────────
; Le GPU n'expose pas de port de lecture pour `bpl` (réf §0bis option 4).
; Le kernel maintient un miroir 16-bit ; toute modification via
; `kernel_gfx_set_bpl` met le shadow à jour. Permet la garde IRQ
; (save/restore autour de `kernel_wm_mouse_step`) prévue Étape B.
; Invariant cible : shadow == valeur réelle posée dans le GPU. 0 = défaut
; (512 octets/ligne) ; toute valeur != 0 = stride compacte d'une fenêtre.
GFX_BPL_SHADOW    = $016900     ; 2B : miroir kernel de gpu->bpl (0=512)
.assert GFX_BPL_SHADOW + 2 <= $01EE00, error, "GFX_BPL_SHADOW chevauche TC flags"

; ── ADR-27 Étape B2 : bascule compact slot par slot ──────────────────
; WM_COMPACT_FLAGS[slot] = $A5 → backing store compact (stride = byte_w
; = WM_TABLE[slot].W>>1). Sinon stride par défaut 512 (compat v1).
; Maintenu par les helpers WM, lu par kernel_gfx_window_base / compose.
WM_COMPACT_FLAGS  = $016902     ; 8B : flag compact par slot
WM_COMPACT_MAGIC  = $A5         ; valeur indiquant slot en mode compact
WCMP_SLOT_ID      = $01690A     ; 1B : slot id courant pendant compose (B2.b)
; ── Finding chrome-direct-FB (post ADR-27 ratification 2026-05-30v) ──
; Les fenêtres système (slots 0/1) dessinent leur chrome DIRECTEMENT
; dans le framebuffer XVGA via `_wm_draw_one`, pas dans leur backing
; store. Quand task_compact ou une app appelle `kernel_wm_compose` en
; boucle, le compose copie leur backing store VIDE → carrés noirs à
; leur place. Workaround : `WM_NO_BACKING_FLAGS[slot]=$A5` → compose
; skip ce slot, laissant son chrome direct framebuffer intact.
WM_NO_BACKING_FLAGS = $01690B   ; 8B : skip compose si $A5 (chrome direct FB)
WM_NO_BACKING_MAGIC = $A5

; ── Bug pré-existant : labels boutons partagés (révélé par file_select 2026-05-31) ──
; UI_STR_BUF est un SEUL scratch SDRAM. Tous les boutons stockent leur
; strptr → UI_STR_BUF → tous lisent le DERNIER label uploadé. Fix : buffer
; per-widget pour les labels boutons. 8 widgets × 16 octets = 128 octets
; (cohérent WIDGET_ENTSZ).
BUTTON_LABELS    = $016A00      ; 8 × 16 = 128B bank 1, label par widget id
; SP-3.p D.1 : texte des dialogues (DB_TEXT / message SYS_ALERT), copié du
; bank app vers bank 1 (le rendu widget lit strptr en bank 1).
DLG_TEXT_BUF     = $016A80      ; 64B bank 1 (63 chars + terminateur)
; SP-GUI : copie bank 1 des titres de fenêtres (rendu PROPORTIONNEL —
; label_prop lit [DP_PCPTR] côté CPU ; la copie SDRAM $012000 reste pour
; compat). 8 slots × 32 o.
WM_TITLES_B1     = $016B00      ; 256B bank 1 ($016B00-$016BFF)
.assert DLG_TEXT_BUF + 64 <= WM_TITLES_B1, error, "DLG_TEXT_BUF chevauche WM_TITLES_B1"
.assert WM_TITLES_B1 + 256 <= $017000, error, "WM_TITLES_B1 chevauche BUNDLES"
.assert WM_COMPACT_FLAGS + 8 <= $01EE00, error, "WM_COMPACT_FLAGS chevauche TC flags"
.assert WCMP_SLOT_ID < $01EE00, error, "WCMP_SLOT_ID chevauche TC flags"
.assert WM_NO_BACKING_FLAGS + 8 <= $01EE00, error, "WM_NO_BACKING_FLAGS chevauche TC flags"

; ─── Window manager — table + Z-order (SP-3.e v0.1, SP-3.R S4) ─────
; WM_MAX=8 fenêtres × 10 octets. Entry : flags(1) id(1) x(2) y(2) w(2) h(2).
WM_TABLE         = $015B22       ; 8 × 10 = 80 octets ($5B22-$5B71)
WM_COUNT         = $015B72       ; 1B : nb fenêtres actives
WM_FOCUS         = $015B73       ; 1B : slot fenêtre focus ($FF = aucune)
WM_MAX           = 8
; SP-3.R S4 — Z-order table : liste compacte des slots actifs, du fond vers l'avant.
; WM_ZORDER[0] = slot le plus en fond, WM_ZORDER[WM_ZORDER_N-1] = slot au premier plan.
; Mise à jour par kernel_wm_add, kernel_wm_close, kernel_wm_set_focus.
WM_ZORDER        = $015BC4       ; WM_MAX × 1B = 8B ($5BC4-$5BCB)
WM_ZORDER_N      = $015BCC       ; 1B : nb entrées actives (= WM_COUNT en pratique)
WM_OWNER         = $015BCD       ; SP-3.m G.1 : WM_MAX × 1B = pid propriétaire par slot
                                ; (0 = aucun) ; renseigné par kernel_wm_add = TASK_CUR créateur.
WCMP_SLOT        = $015BD5       ; SP-3.m G.4bis : compositor — slot itérateur (1B)
WCMP_XB          = $015BD6       ; compositor — x>>1 (2B)
WCMP_MIDHI       = $015BD8       ; compositor — (mid,hi) adresse dst (2B)
WM_ENTSZ         = 10
WM_F_USED        = $01           ; flags bit0 : slot occupé
WM_F_VISIBLE     = $02           ; bit1 : visible
WM_F_FOCUS       = $04           ; bit2 : a le focus
WM_OFF_FLAGS     = 0
WM_OFF_ID        = 1
WM_OFF_X         = 2
WM_OFF_Y         = 4
WM_OFF_W         = 6
WM_OFF_H         = 8

; ZP args window manager (16-bit). DP $14-$1F libres.
WM_ARG_X         = $14           ; 2B
WM_ARG_Y         = $16           ; 2B
WM_ARG_W         = $18           ; 2B
WM_ARG_H         = $1A           ; 2B
WM_ARG_DX        = $1C           ; 2B signé
WM_ARG_DY        = $1E           ; 2B signé
WM_DP_TMP        = $20           ; 2B scratch
WM_CRH_TMP      = $25           ; 6B scratch pour _wm_chrome_hit (SP-3.h) : $25-$2A
WM_ZN_CACHE     = $2B           ; 1B cache ZP de WM_ZORDER_N (CPY/CPX ne font pas le mode long)
; Audit §3.6.2 : scratch dédié _wm_resize_hit (était : overload WM_ARG_DX,
; problématique car WM_ARG_DX est un ARG syscall partagé avec contexte IRQ).
WM_RH_TMP       = $32           ; 2B : win_bottom 16-bit

; Audit §3.6 / axe 8.2 : primitive _point_in_rect16 — couche géométrie isolée.
; Le rect est posé en ZP par le caller, le point est lu directement depuis
; MOUSE_X/MOUSE_Y (bank 1) par la primitive. Conserve X/Y pour itérations.
PIR_RECT_X      = $34           ; 2B : rect.x (16-bit)
PIR_RECT_Y      = $36           ; 2B : rect.y (16-bit)
PIR_RECT_W      = $38           ; 2B : rect.w (16-bit)
PIR_RECT_H      = $3A           ; 2B : rect.h (16-bit)
PIR_TMP         = $3C           ; 2B : scratch interne (rx+w, ry+h)

; ZP args pour kernel_gfx_clear / kernel_gfx_fill_rect
; (sémantique partagée selon le helper appelé)
GFX_BASE_LO      = $70           ; base address 24-bit (SDRAM offset)
GFX_BASE_MID     = $71
GFX_BASE_HI      = $72
GFX_ARG2_LO      = $73           ; clear: size_lo  | rect: x
GFX_ARG2_MID     = $74           ; clear: size_mid | rect: y
GFX_ARG2_HI      = $75           ; clear: size_hi  | rect: unused
GFX_ARG3_LO      = $76           ; clear: unused   | rect: w  | blit: byte_w lo
GFX_ARG3_MID     = $77           ; clear: unused   | rect: h  | blit: byte_w hi
GFX_ARG4_LO      = $92           ; blit: byte_h lo (v0.2) — PAS $6E (= EVT_TMP scratch IRQ)
GFX_ARG4_MID     = $93           ; blit: byte_h hi
GFX_COLOR        = $78           ; couleur 4-bit (0..15)
; ZP additionnels TEXT (en plus de BASE/ARG2_LO=x/ARG2_MID=y/COLOR)
GFX_FONT_LO      = $79           ; font_addr 24-bit
GFX_FONT_MID     = $7A
GFX_FONT_HI      = $7B
GFX_STR_LO       = $7C           ; string_addr 24-bit (null-terminated)
GFX_STR_MID      = $7D
GFX_STR_HI       = $7E
; ── ADR-27 opt.b : stride GPU configurable (SET_BPL) ───────────────────
GFX_BPL_LO       = $90           ; stride 16-bit (octets/ligne) ; 0 → défaut XVGA 512
GFX_BPL_HI       = $91

; ── SP-3.d : toolkit (label/frame/button) — adresses SDRAM ─────────────
TK_FONT_ADDR     = $010000       ; fonte ASCII (1024 o) uploadée au boot (hors zone self-test VRAM $001000-$00C000)
GPU_OP_TEXT16    = $07           ; texte coords 16-bit (ADR-21, SP-3.d)
GPU_OP_EXEC_LIST = $09           ; GPU-ISA v3 (ADR-34 C) : display-list en SDRAM
GPU_OP_EXEC_LIST_XY = $0A        ; GPU-ISA v4 (ADR-34 C2b) : replay translaté —
                                 ;   ARG2 = dy<<12 | dx (12-bit two's complement)
GPU_LIST_END     = $FF           ; terminateur de display-list
GPU_CAP_LIST_BIT = $40           ; GPU_CAPS_KERNEL : cap EXEC_LIST (<<4)
GPU_LIST_MAX_ENT = 64            ; borne d'entrées GPU — le record avorte au-delà
; ADR-34 C2 : scratch du label proportionnel en DOUBLE-BUFFER — une liste
; peut être en vol (FIFO) pendant qu'on construit la suivante, zéro drain
; en régime normal. ⚠ l'ancienne TK_LIST_SCRATCH ($011100) écrasait les
; labels d'icônes ($011200+) — bug C1 corrigé par cette relocalisation.
TK_LP_STR0       = $011000       ; chaînes espacées, buffer 0 (128 o : 64 ch × 2)
TK_LP_STR1       = $015600       ; buffer 1
TK_LP_LIST0      = $015800       ; display-list, buffer 0 (64×13 = 832 o)
TK_LP_LIST1      = $015C00       ; buffer 1
TK_LP_FLIP       = $0190BF       ; 1B : buffer courant (0/1)
TK_LP_PEND       = $0190C0       ; 2B : buffer émis-sans-drain (garde réutilisation)
; ADR-34 C2 : ring de chaînes pour tk_label — 32 slots × 32 o en SDRAM.
; SÛRETÉ STRUCTURELLE : ring (32) ≥ 2 × GPU FIFO (16) → un slot réutilisé
; ne peut plus être référencé par une commande en vol. Ferme AUSSI le bug
; historique « labels partagés » (kernel.s ~1030 : UI_STR_BUF unique).
TK_STR_RING      = $016000       ; SDRAM : 32 × 32 o = 1 Ko ($016000-$0163FF)
TK_STR_RING_IDX  = $0190C2       ; 1B : slot courant (0-31, round-robin)
TK_LP_STRB       = $0190C3       ; 3B : base SDRAM du buffer chaînes courant
TK_LP_LISTB      = $0190C6       ; 3B : base SDRAM de la display-list courante
TK_COL_BORDER    = $0F           ; frame : blanc
TK_COL_BTN_FACE  = $07           ; bouton : lightgray
TK_COL_BTN_TEXT  = $00           ; bouton : texte noir

; ─── VRAM cold device I/O (ADR-19, Sprint VRAM-2) ──────────────────
; Ports $0330-$033C en bank 0 (DBR=0).
VRAM_ADDR_LO_IO     = $000330
VRAM_ADDR_MID_IO    = $000331
VRAM_ADDR_HI_IO     = $000332
VRAM_DATA_IO        = $000333
VRAM_DMA_CTRL_IO    = $000334
VRAM_DMA_SRC_LO_IO  = $000335
VRAM_DMA_SRC_MID_IO = $000336
VRAM_DMA_SRC_HI_IO  = $000337
VRAM_DMA_DST_LO_IO  = $000338
VRAM_DMA_DST_MID_IO = $000339
VRAM_DMA_DST_HI_IO  = $00033A
VRAM_DMA_LEN_LO_IO  = $00033B
VRAM_DMA_LEN_HI_IO  = $00033C
VRAM_DMA_TRIG       = $01       ; bit 0 trigger DMA
VRAM_DMA_DIR        = $02       ; bit 1 : 0=SDRAM→bank, 1=bank→SDRAM
VRAM_DMA_BUSY       = $80       ; R bit 7 : busy flag

; ZP args pour kernel_vram_write_block / kernel_vram_read_block
VRAM_OP_ADDR_LO     = $60       ; SDRAM addr 24-bit
VRAM_OP_ADDR_MID    = $61
VRAM_OP_ADDR_HI     = $62
VRAM_OP_LEN_LO      = $63       ; longueur 16-bit (LEN=0 supportée par DMA mais pas write/read_block)
VRAM_OP_LEN_HI      = $64
; ZP args pour kernel_vram_dma
VRAM_DMA_SRC_LO_ZP  = $65       ; source 24-bit
VRAM_DMA_SRC_MID_ZP = $66
VRAM_DMA_SRC_HI_ZP  = $67
VRAM_DMA_DST_LO_ZP  = $68       ; destination 24-bit
VRAM_DMA_DST_MID_ZP = $69
VRAM_DMA_DST_HI_ZP  = $6A
VRAM_DMA_LEN_LO_ZP  = $6B       ; longueur 16-bit (0 → 65 536)
VRAM_DMA_LEN_HI_ZP  = $6C
VRAM_DMA_DIR_ZP     = $6D       ; 0=SDRAM→bank, VRAM_DMA_DIR=bank→SDRAM

; ─── Période timer T1 (cycles entre IRQ) ────────────────────────────
; Sprint 2.d : passé de 512 → 4096 cycles. L'IRQ handler avec
; kernel_kbd_scan dure ~830 cycles ; à 512 cycles de période,
; T1 ré-asserte avant que les tasks aient le temps d'exécuter
; (B_ctr restait à 0). 4096 cycles laisse ~3000 cycles/slot aux
; tasks, suffisant pour incrémenter leur compteur.
T1_PERIOD_LO    = $00           ; $1000 = 4096 cycles
T1_PERIOD_HI    = $10

; ─── HIRES Oric 2 framebuffer (Sprint 3.b, ADR-12) ──────────────────
; Bank 128 ($80xxxx) offset 0, 240×200×3bpp = 18 000 octets/frame.
; 8 pixels groupés en 24 bits sur 3 octets, big-endian (pixel 0 = bits hauts).
; Palette 8 couleurs Oric 1 : 0=black, 1=red, 2=green, 3=yellow,
;                              4=blue, 5=magenta, 6=cyan, 7=white.
; HIRES2_* constants et ZP slots retirés en PH-cleanup-zombie (ADR-19 v2).
; Voir suppression kernel_hires2_clear / kernel_fill_rect_aligned plus bas.

; ════════════════════════════════════════════════════════════════════
;  MODULES
; ════════════════════════════════════════════════════════════════════

        .include "modules/boot.s"
        .include "modules/fat.s"
        .include "modules/log.s"
        .include "modules/console.s"
        .include "modules/kbd.s"
        .include "modules/alloc.s"
        .include "modules/vram.s"
        .include "modules/gfx.s"
        .include "modules/tk.s"
        .include "modules/wm.s"
        .include "modules/sched.s"
        .include "modules/event.s"
        .include "modules/handlers.s"

; ════════════════════════════════════════════════════════════════════
;  Gardes d'overlap memory map bank 1 (revue senior, dette #4)
; ════════════════════════════════════════════════════════════════════
;
; Les variables data bank 1 sont des constantes absolues hardcodées (= $01xxxx)
; — choix imposé par l'ABI d'introspection des tests Phosphoric qui lisent ces
; adresses fixes (205 réfs littérales dans 7 fichiers de test). On ne peut donc
; pas les relocaliser vers un .segment/.res sans casser les tests. À défaut, ces
; .assert transforment tout chevauchement en ERREUR DE BUILD (au lieu d'une
; corruption silencieuse, cf. overlap ICON_TABLE/TCB_BITMAP corrigé en SP-3.k).
; Chaque garde encode « cette structure tient avant la variable suivante » via
; les tailles réelles (WM_MAX, TCB_*, KBD_RING_SIZE) : grossir une structure
; au-delà de sa zone échoue à la compilation.

; ── Garde linker : CODE ne doit pas déborder le segment NMI_HANDLER ────
; Audit 65C816 §3.1 : les `.assert` ci-dessous couvrent les chevauchements
; entre variables nommées, mais PAS la croissance de CODE au-delà de $5500.
; ld65 le détecte aussi (NMI_HANDLER start=$5500) mais en warning peu
; lisible — l'assert rend l'échec explicite. (TICK_COUNTER relocalisé en
; $019093 par ADR-32 §10.13 — il n'est plus le plancher.)
; Symboles ld65 auto-générés pour le segment CODE.
.import __CODE_LOAD__, __CODE_SIZE__
.assert (__CODE_LOAD__ + __CODE_SIZE__) <= $5500, error, "CODE deborde le segment NMI_HANDLER ($5500)"
; ADR-32 §10.13 : TICK_COUNTER vit entre CURSOR_X et BANK_FREE_LIST.
.assert CURSOR_X + 1     <= TICK_COUNTER,    error, "overlap CURSOR_X/TICK_COUNTER"
.assert TICK_COUNTER + 1 <= GPU_CAPS_KERNEL, error, "overlap TICK_COUNTER/GPU_CAPS_KERNEL"
.assert GPU_CAPS_KERNEL + 1 <= PANIC_CODE,   error, "overlap GPU_CAPS_KERNEL/PANIC_CODE"
; C2b : bloc WL relogé $0191A0+ (l'ancien $019095 chevauchait PANIC_CODE
; et BUNDLE_FOUND_* — collision latente C2a). Chaîne d'asserts du bloc :
.assert PANIC_CODE + 1 <= BUNDLE_FOUND_NSEC, error, "overlap PANIC_CODE/BUNDLE_FOUND"
.assert WL_REC + 1 <= BUNDLE_APP_BANK,       error, "overlap WL_REC/BUNDLE_APP_BANK"
.assert BANK_FREE_TOP + 1 <= WL_PTR,         error, "overlap BANK_FREE_TOP/WL_PTR"
.assert WL_PTR + 3 <= WL_SCRATCH16,          error, "overlap WL_PTR/WL_SCRATCH16"
.assert WL_SCRATCH16 + 2 <= TK_LP_FLIP,      error, "overlap WL_SCRATCH16/TK_LP_FLIP"
.assert IRQ_ZP_SAVE + 140 <= WL_VALID,       error, "overlap IRQ_ZP_SAVE/WL_VALID"
.assert WL_VALID + WL_SLOTS <= WL_FLIP,      error, "overlap WL_VALID/WL_FLIP"
.assert WL_FLIP + WL_SLOTS <= WL_ORG_X,      error, "overlap WL_FLIP/WL_ORG_X"
.assert WL_ORG_X + 2*WL_SLOTS <= WL_ORG_Y,   error, "overlap WL_ORG_X/WL_ORG_Y"
.assert WL_ORG_Y + 2*WL_SLOTS <= WL_NENT,    error, "overlap WL_ORG_Y/WL_NENT"
.assert WL_NENT + 1 <= WL_ABORT,             error, "overlap WL_NENT/WL_ABORT"
.assert WL_ABORT + 1 <= WL_ARENA_BASE,       error, "overlap WL_ABORT/WL_ARENA_BASE"
.assert WL_ARENA_BASE + 2 <= WL_ARENA_BUMP,  error, "overlap WL_ARENA_BASE/BUMP"
.assert WL_ARENA_BUMP + 2 <= WL_DX,          error, "overlap WL_ARENA_BUMP/WL_DX"
.assert WL_DX + 2 <= WL_DY,                  error, "overlap WL_DX/WL_DY"
.assert WL_DY + 2 <= WM_RD_SKIPPED,          error, "overlap WL_DY/WM_RD_SKIPPED"
.assert WM_RD_NOCLEAR + 1 <= $019200,        error, "WM_RD_NOCLEAR chevauche GUICODE"
.assert TK_LP_PEND + 2 <= TK_STR_RING_IDX,   error, "overlap TK_LP_PEND/TK_STR_RING_IDX"
.assert TK_STR_RING_IDX + 1 <= TK_LP_STRB,   error, "overlap TK_STR_RING_IDX/TK_LP_STRB"
.assert TK_LP_LISTB + 3 <= LOG_RING,         error, "overlap TK_LP_LISTB/LOG_RING"

; ── Cluster dense WM / ICON / TCB ($5A00-$5D40) ───────────────────────
.assert WIDGET_TABLE + WM_MAX*16   <= WIDGET_COUNT,    error, "overlap WIDGET_TABLE"
.assert ICON_TABLE   + 4*16        <= TCB_BITMAP,      error, "overlap ICON_TABLE/TCB_BITMAP"
.assert TCB_BITMAP   + 2           <= WM_TABLE,        error, "overlap TCB_BITMAP/WM_TABLE"
.assert WM_TABLE     + WM_MAX*10   <= WM_COUNT,        error, "overlap WM_TABLE"
.assert WM_TITLES    + WM_MAX      <= WM_STATES,       error, "overlap WM_TITLES/WM_STATES"
.assert WM_STATES    + WM_MAX      <= WM_SAVED_RECTS,  error, "overlap WM_STATES/WM_SAVED_RECTS"
.assert WM_SAVED_RECTS + WM_MAX*8  <= WM_ZORDER,       error, "overlap WM_SAVED_RECTS/WM_ZORDER"
.assert WM_ZORDER    + WM_MAX      <= WM_ZORDER_N,     error, "overlap WM_ZORDER"
.assert WM_OWNER     + WM_MAX      <= TCB_TABLE_BASE,  error, "overlap WM_OWNER/TCB_TABLE"
.assert WCMP_MIDHI   + 2           <= TCB_TABLE_BASE,  error, "overlap WCMP/TCB_TABLE"
.assert TCB_TABLE_BASE + TCB_MAX*TCB_SIZE <= $015D40,  error, "overlap TCB_TABLE (>$5D40)"

; ── Ring clavier ($5860) + buffer secteur FAT ($5F60, 512 o) ──────────
.assert KBD_RING + KBD_RING_SIZE   <= KBD_RING_HEAD,   error, "overlap KBD_RING"
.assert SLEEP_TICKS + 16           <= CURSOR_ADDR,     error, "overlap SLEEP_TICKS/CURSOR_ADDR"
.assert FS_BUFFER + 512            <= FS_INIT_RESULT,  error, "overlap FS_BUFFER (secteur 512o)"
