; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty

; ============================================================
; OricOS — Kernel core (Sprint 1.b — scheduler préemptif 2 tâches)
; ============================================================
; Auteur : bmarty (benedicte) <bmarty@mailo.com>
; Date   : 2026-05-08
;
; Sprint 1.b livre :
;   - Scheduler préemptif round-robin (2 tâches kernel : A et B).
;   - Context switch via NMI handler : push A/X/Y, swap S, pull A/X/Y.
;   - Pré-init de la stack task B avec un frame d'interrupt fake.
;   - Stop conditionnel : NMI handler STP quand tick counter atteint
;     TICK_GOAL (10 ticks → 5 slices/task).
;
; Map mémoire (cf. /home/bmarty/oric2/docs/MEMORY_MAP.md) :
;   bank 0 $0100-$01FF : stack task A
;   bank 0 $0200-$02FF : stack task B
;   bank 1 $5400      : tick counter
;   bank 1 $5432      : current_task_id (0 = A, 1 = B)
;   bank 1 $5434-5435 : task_a_saved_S (16-bit)
;   bank 1 $5436-5437 : task_b_saved_S (16-bit)
;   bank 1 $5440-5443 : task A counter (visible sentinel)
;   bank 1 $5444-5447 : task B counter
;   bank 1 $5500     : NMI handler (segment NMI_HANDLER)
;   bank 1 $5600     : IRQ handler placeholder
;
; Convention : ca65 syntaxe WDC, --cpu 65816.
; ============================================================

        .setcpu "65816"
        .smart  +

; ─── Constantes ─────────────────────────────────────────────────────
TICK_COUNTER    = $015400
SENTINEL_BASE   = $015000
VERSION_BASE    = $015010
TASK_CUR        = $015432       ; PID actuellement RUNNING (1..16)
TASK_A_CTR      = $015440
TASK_B_CTR      = $015444
TICK_GOAL       = $0A           ; 10 ticks → STP

; ─── ADR-14 : Table TCB (Sprint 2.g) ────────────────────────────────
; 16 TCBs × 20 bytes = 320 octets en bank 1 à $5C00.
; Bitmap free 2 octets à $5B00 (16 bits).
TCB_TABLE_BASE  = $015C00
TCB_BITMAP      = $015B00       ; 2 bytes : bit set = slot occupé
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
BANK_NEXT       = $015450       ; prochain bank libre via bump (uint8)
BANK_DEMO       = $015460       ; 3 octets : résultats de l'alloc démo
BANK_POOL_BASE  = $04            ; premier bank du pool
BANK_POOL_END   = $80            ; dernier bank du pool + 1 (= $80, banks 4-127)

; Sprint 2.h : free list LIFO 16 entries. alloc pop d'abord, sinon bump.
BANK_FREE_LIST  = $0154A0       ; 16 bytes stack (banks libérés)
BANK_FREE_TOP   = $0154B0       ; 1 byte (count 0..16)

; ─── Bank allocator pool LIVE (Sprint VRAM-3, ADR-19 + ADR-20) ─────
; Pool live : banks 132-159 (= $84..$9F, 28 banks) en BRAM ECP5.
; Banks 128-131 ($80..$83) réservés au framebuffer principal SVGA
; 800x600x4bpp (4 banks consécutifs, ADR-20).
; Pool live = backing-stores fenêtres GUI actives + buffers GPU.
BANK_LIVE_NEXT       = $015458   ; prochain bank live via bump (uint8)
BANK_LIVE_DEMO       = $015468   ; 4 octets : résultats alloc/free demo
BANK_LIVE_POOL_BASE  = $84       ; bank 132 (= $84, 1er bank libre après FB)
BANK_LIVE_POOL_END   = $A0       ; bank 160 (exclusif), banks 132-159
BANK_LIVE_FREE_LIST  = $0154C0   ; 16 bytes stack
BANK_LIVE_FREE_TOP   = $0154D0   ; 1 byte (count 0..16)

; ─── Modèle erreur kernel (Sprint 2.i / OS-2.i.v2) ──────────────────
PANIC_CODE      = $015495       ; 1 byte : dernier code panic (0 = OK)

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
LOG_RING        = $0154E0       ; 16 octets (8 entrées × {level, code})
LOG_HEAD        = $0154F0       ; index lecture (entrée la plus ancienne)
LOG_TAIL        = $0154F1       ; index écriture
LOG_COUNT       = $0154F2       ; nb entrées (0..8)
LOG_SIZE        = 8
LOG_MASK        = LOG_SIZE - 1
DP_LOG_TMP      = $13           ; DP+$13 : scratch code log
LOG_TEST_RES    = $0154F3       ; sentinelle test OS-2.i.v2 : 3 octets (count, lvl, code)

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

BUNDLE_VALIDATE_RES = $01549C   ; 1 byte : résultat dernier validate

; Sprint 2.l : résultats find_code + app_exec
BUNDLE_FOUND_NSEC   = $015496   ; 1 byte : nsec scan tmp
BUNDLE_FOUND_SIZE   = $015498   ; 2 bytes : size de la section trouvée
BUNDLE_FOUND_OFFSET = $01549A   ; 2 bytes : offset de la section
BUNDLE_APP_BANK     = $01549F   ; 1 byte : bank alloué pour app

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
CURSOR_ADDR     = $015490       ; 16-bit, addr écran courante
CURSOR_X        = $015492       ; 8-bit, colonne courante (0..39)

; Zero page kernel (DP=0)
; print_string utilise DP_PTR (long indirect [dp],Y → bank 1 strings).
; print_char utilise DP_PCPTR (DP indirect (dp) → bank DBR=0 screen RAM).
; Séparés pour éviter conflit lors de print_char appelé depuis print_string.
DP_PTR          = $08            ; DP+$08/$09/$0A : pointer 24-bit
DP_PCPTR        = $0C            ; DP+$0C/$0D : pointer 16-bit
DP_TMP          = $10            ; DP+$10 : char temp
DP_SYS_ARG_X    = $11            ; DP+$11 : X sauvé avant corruption dispatch (OS-2.f.v2)
DP_KBD_TMP      = $12            ; DP+$12 : scratch ring clavier (OS-2.d)

; ─── Charset (Sprint 2.c+) ──────────────────────────────────────────
; Le rendu Oric 1 mode TEXT lit la fonte char depuis bank 0 $B400-$B7FF
; (128 chars × 8 lignes). La ROM Oric 1 historique copie sa fonte ici
; au boot ; OricOS doit faire pareil puisqu'il boote sans la ROM.
; La fonte (1024 octets) est embedded dans le kernel.bin en bank 1
; à $5800 via .incbin (segment CHARSET).
CHARSET_SRC     = $015800        ; source (bank 1)
CHARSET_DST     = $00B400        ; dest (bank 0, Oric 1 mode TEXT)
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
KBD_MATRIX      = $015470       ; 8 octets bank 1 (legacy scan Oric 1, inutilisé OS-2.d)

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
KBD_GETKEY_RES  = $015476       ; sentinelle test : résultat SYS_GET_KEY démo
SCROLL_TEST_RES = $015477       ; sentinelle test OS-2.e.2 : 4 octets (scroll+CR)

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

; État souris (bank 1)
MOUSE_X          = $015930       ; 2B position absolue
MOUSE_Y          = $015932       ; 2B
MOUSE_BTN        = $015934       ; 1B boutons courants
MOUSE_PREV_BTN   = $015935       ; 1B boutons frame précédente (edge-detect clic)
MOUSE_DX         = $015936       ; 1B delta X signé par événement (lu de MOU2_DX)
MOUSE_DY         = $015937       ; 1B delta Y signé par événement
WM_DRAG_ARMED    = $015938       ; 1B : 1 si le clic a atterri sur une fenêtre (drag autorisé)
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
WIDGET_MAX       = 8
WIDGET_ENTSZ     = 16
WG_TYPE_LABEL    = $00
WG_TYPE_BUTTON   = $01
; temps de _wm_draw_all_widgets
WG_I             = $015A90       ; 1B : index boucle
WG_PARENT        = $015A91       ; 1B
WG_TYPE          = $015A92       ; 1B
WG_RELX          = $015A94       ; 2B
WG_RELY          = $015A96       ; 2B
WG_RELW          = $015A98       ; 2B
WG_RELH          = $015A9A       ; 2B
WIN_TITLE_FOCUS  = $09           ; titlebar fenêtre focus : lightblue vif
WIN_TITLE_NORMAL = $08           ; titlebar fenêtre non focus : darkgray
NO_STP_FLAG      = $01EF00        ; SP-3.e v0.4 : $A5 (posé par --kernel) → pas de STP (live)

; ─── Window manager (SP-3.e v0.1) — table en bank 1 $5900 ───────────
; 4 fenêtres × 10 octets. Entry : flags(1) id(1) x(2) y(2) w(2) h(2).
WM_TABLE         = $015900       ; 4 × 10 = 40 octets ($5900-$5927)
WM_COUNT         = $015928       ; 1B : nb fenêtres
WM_FOCUS         = $015929       ; 1B : id fenêtre focus ($FF = aucune)
WM_MAX           = 4
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

; ZP args pour kernel_gfx_clear / kernel_gfx_fill_rect
; (sémantique partagée selon le helper appelé)
GFX_BASE_LO      = $70           ; base address 24-bit (SDRAM offset)
GFX_BASE_MID     = $71
GFX_BASE_HI      = $72
GFX_ARG2_LO      = $73           ; clear: size_lo  | rect: x
GFX_ARG2_MID     = $74           ; clear: size_mid | rect: y
GFX_ARG2_HI      = $75           ; clear: size_hi  | rect: unused
GFX_ARG3_LO      = $76           ; clear: unused   | rect: w
GFX_ARG3_MID     = $77           ; clear: unused   | rect: h
GFX_COLOR        = $78           ; couleur 4-bit (0..15)
; ZP additionnels TEXT (en plus de BASE/ARG2_LO=x/ARG2_MID=y/COLOR)
GFX_FONT_LO      = $79           ; font_addr 24-bit
GFX_FONT_MID     = $7A
GFX_FONT_HI      = $7B
GFX_STR_LO       = $7C           ; string_addr 24-bit (null-terminated)
GFX_STR_MID      = $7D
GFX_STR_HI       = $7E

; ── SP-3.d : toolkit (label/frame/button) — adresses SDRAM ─────────────
TK_FONT_ADDR     = $010000       ; fonte ASCII (1024 o) uploadée au boot (hors zone self-test VRAM $001000-$00C000)
TK_STR_SCRATCH   = $011000       ; scratch SDRAM pour les chaînes de label
GPU_OP_TEXT16    = $07           ; texte coords 16-bit (ADR-21, SP-3.d)
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
;  CODE — boot + tasks
; ════════════════════════════════════════════════════════════════════
        .segment "CODE"

.export kernel_entry
kernel_entry:
        ; ── Bascule mode N ─────────────────────────────────────────
        sec
        xce                     ; → mode E (force M=X=1)
        clc
        xce                     ; → mode N (M=1 et X=1 certifiés)

        rep #$20
        lda #$0000
        tcd                     ; D = 0
        ; ── Stack task A initiale en page 1 ($01FF) ────────────────
        ; TXS en mode N + X=1 (8-bit) ne donne S = $00:XL (high forcé
        ; à 0 par SEP #$10). Pour stack page 1 standard, utiliser TCS
        ; (transfer C 16-bit to S) en M=0.
        lda #$01FF
        tcs                     ; S = $01FF
        sep #$20
        sep #$30                ; M=1, X=1

        ; ── OS-2.i.v2 : init log ring buffer (tôt, avant tout log/panic) ──
        jsr kernel_log_init

        ; ── PH-cleanup-zombie (2026-05-09) ─────────────────────────
        ; Sprints 3.a/3.b kernel_hires2_clear + kernel_fill_rect_aligned
        ; retirés : code legacy ADR-19 v2 (écrivait en bank $80 = ex-VRAM
        ; live, devenue RAM normale invisible côté compositor).
        ; Le rendu desktop XVGA passe désormais par GPU blitter (ADR-21)
        ; via kernel_gfx_* (Sprint GPU-3 v0.3).

        ; ── Sprint VRAM-2 : exerce kernel_vram_* helpers ───────────
        ; Test 1 : write_block 4 bytes "VRAM" depuis bank 1 vers SDRAM[$001000].
        ; Source : zone bank 1 où "VRAM" est embedded plus bas (vram_test_str).
        lda #<vram_test_str
        sta DP_PCPTR
        lda #>vram_test_str
        sta DP_PCPTR+1
        lda #$01                        ; bank 1 (segment CODE)
        sta DP_PCPTR+2
        lda #$00
        sta VRAM_OP_ADDR_LO
        lda #$10
        sta VRAM_OP_ADDR_MID
        lda #$00
        sta VRAM_OP_ADDR_HI             ; SDRAM addr = $001000
        lda #$04
        sta VRAM_OP_LEN_LO
        lda #$00
        sta VRAM_OP_LEN_HI              ; len = 4
        jsr kernel_vram_write_block

        ; Test 2 : read_block depuis SDRAM[$002000] (pré-rempli côté C
        ; avec "ABCD") vers bank 4 $0500.
        lda #$00
        sta DP_PCPTR
        lda #$05
        sta DP_PCPTR+1
        lda #$04                        ; bank 4
        sta DP_PCPTR+2
        lda #$00
        sta VRAM_OP_ADDR_LO
        lda #$20
        sta VRAM_OP_ADDR_MID
        lda #$00
        sta VRAM_OP_ADDR_HI             ; SDRAM addr = $002000
        lda #$04
        sta VRAM_OP_LEN_LO
        lda #$00
        sta VRAM_OP_LEN_HI              ; len = 4
        jsr kernel_vram_read_block

        ; Test 3 : DMA bank $04:0500 → SDRAM[$003000], 4 bytes.
        lda #$00
        sta VRAM_DMA_SRC_LO_ZP
        lda #$05
        sta VRAM_DMA_SRC_MID_ZP
        lda #$04
        sta VRAM_DMA_SRC_HI_ZP          ; src = bank $04:0500
        lda #$00
        sta VRAM_DMA_DST_LO_ZP
        lda #$30
        sta VRAM_DMA_DST_MID_ZP
        lda #$00
        sta VRAM_DMA_DST_HI_ZP          ; dst = SDRAM $003000
        lda #$04
        sta VRAM_DMA_LEN_LO_ZP
        lda #$00
        sta VRAM_DMA_LEN_HI_ZP          ; len = 4
        lda #VRAM_DMA_DIR               ; bank → SDRAM
        sta VRAM_DMA_DIR_ZP
        jsr kernel_vram_dma

        ; ── Sprint GPU-3 : exerce kernel_gfx_clear / fill_rect ──
        ; Test GPU CLEAR : remplit framebuffer XVGA SDRAM[$004000..]
        ; (zone test 32 KiB = 64 lignes XVGA) avec color=4 (blue VGA).
        ; Pattern écrit = $44 (2 pixels color 4 par byte).
        lda #$00
        sta GFX_BASE_LO
        lda #$40
        sta GFX_BASE_MID
        lda #$00
        sta GFX_BASE_HI                 ; base = SDRAM $004000
        lda #$00
        sta GFX_ARG2_LO
        lda #$80
        sta GFX_ARG2_MID
        lda #$00
        sta GFX_ARG2_HI                 ; size = $8000 = 32768 octets
        lda #$04
        sta GFX_COLOR                   ; color = 4 (blue VGA)
        jsr kernel_gfx_clear

        ; Test GPU FILL_RECT : rectangle 8×4 pixels color=15 (white)
        ; à (x=4, y=2). Base SDRAM = $004000 (même framebuffer test).
        ; BPL hardcodé GPU = 512.
        lda #$00
        sta GFX_BASE_LO
        lda #$40
        sta GFX_BASE_MID
        lda #$00
        sta GFX_BASE_HI                 ; base = SDRAM $004000
        lda #$04
        sta GFX_ARG2_LO                 ; x = 4
        lda #$02
        sta GFX_ARG2_MID                ; y = 2
        lda #$08
        sta GFX_ARG3_LO                 ; w = 8
        lda #$04
        sta GFX_ARG3_MID                ; h = 4
        lda #$0F
        sta GFX_COLOR                   ; color = 15 (white)
        jsr kernel_gfx_fill_rect

        ; Test GPU BLIT : copie 10×8 bytes de src=$004000 (= ligne 0 du
        ; framebuffer test) vers dst=$008000 (= ligne 32). Couvre le
        ; rect en src lignes 2..5 → réplique en dst lignes 2..5 depuis
        ; ligne 32 = lignes 34..37 du framebuffer test.
        lda #$00
        sta GFX_BASE_LO
        lda #$40
        sta GFX_BASE_MID
        lda #$00
        sta GFX_BASE_HI                 ; src = $004000
        lda #$00
        sta GFX_ARG2_LO
        lda #$80
        sta GFX_ARG2_MID
        lda #$00
        sta GFX_ARG2_HI                 ; dst = $008000
        lda #$0A
        sta GFX_ARG3_LO                 ; byte_w = 10
        lda #$08
        sta GFX_ARG3_MID                ; byte_h = 8
        jsr kernel_gfx_blit

        ; Test GPU LINE : ligne verticale x=40, y=20..25, color=2 (green)
        ; sur le framebuffer test base $004000.
        lda #$00
        sta GFX_BASE_LO
        lda #$40
        sta GFX_BASE_MID
        lda #$00
        sta GFX_BASE_HI                 ; base = $004000
        lda #40
        sta GFX_ARG2_LO                 ; x1 = 40
        lda #20
        sta GFX_ARG2_MID                ; y1 = 20
        lda #40
        sta GFX_ARG3_LO                 ; x2 = 40
        lda #25
        sta GFX_ARG3_MID                ; y2 = 25
        lda #$02
        sta GFX_COLOR                   ; color = 2 (green)
        jsr kernel_gfx_line

        ; ── Sprint 3.c v0.1 : démo kernel_window_draw ─────────────
        ; D'abord CLEAR fond noir (color 0) sur 32 KiB à $00C000
        ; (= 64 lignes XVGA).
        lda #$00
        sta GFX_BASE_LO
        lda #$C0
        sta GFX_BASE_MID
        lda #$00
        sta GFX_BASE_HI                 ; base = SDRAM $00C000
        lda #$00
        sta GFX_ARG2_LO
        lda #$80
        sta GFX_ARG2_MID
        lda #$00
        sta GFX_ARG2_HI                 ; size = $8000 = 32 KiB
        lda #$00
        sta GFX_COLOR                   ; color = 0 (black)
        jsr kernel_gfx_clear

        ; Window à (x=20, y=10, w=80, h=60), titlebar h=8.
        ; Frame noir (0), title bar dark blue (1), body lightgray (7).
        lda #$00
        sta WIN_BASE_LO
        lda #$C0
        sta WIN_BASE_MID
        lda #$00
        sta WIN_BASE_HI                 ; base = SDRAM $00C000
        lda #20
        sta WIN_X
        lda #10
        sta WIN_Y
        lda #80
        sta WIN_W
        lda #60
        sta WIN_H
        lda #8
        sta WIN_TITLEBAR_H
        lda #$00
        sta WIN_COLOR_FRAME             ; frame = black
        lda #$01
        sta WIN_COLOR_TITLE             ; title = blue
        lda #$07
        sta WIN_COLOR_BODY              ; body = lgray
        jsr kernel_window_draw

        ; ── Sprint 3.c v0.2 : clone window via BLIT ──────────────
        ; BLIT window 1 (à (20, 10)) vers position (50, 80).
        ; src_addr = base + 10*512 + 20/2 = $00C000 + 5130  = $00D40A.
        ; dst_addr = base + 80*512 + 50/2 = $00C000 + 40985 = $016019.
        ; (40985 = $A019, base + $A019 = $016019)
        ; byte_w = 80/2 = 40, byte_h = 60.
        lda #$0A
        sta GFX_BASE_LO
        lda #$D4
        sta GFX_BASE_MID
        lda #$00
        sta GFX_BASE_HI                 ; src = $00D40A
        lda #$19
        sta GFX_ARG2_LO
        lda #$60
        sta GFX_ARG2_MID
        lda #$01
        sta GFX_ARG2_HI                 ; dst = $016019
        lda #40
        sta GFX_ARG3_LO                 ; byte_w = 40
        lda #60
        sta GFX_ARG3_MID                ; byte_h = 60
        jsr kernel_gfx_blit

        ; Repaint titlebar window 2 en green (color 2) pour distinction.
        ; FILL_RECT(base=$00C000, x=50, y=81, w=80, h=7, color=2).
        lda #$00
        sta GFX_BASE_LO
        lda #$C0
        sta GFX_BASE_MID
        lda #$00
        sta GFX_BASE_HI                 ; base = $00C000
        lda #50
        sta GFX_ARG2_LO                 ; x = 50
        lda #81
        sta GFX_ARG2_MID                ; y = 81 (1 px sous frame top)
        lda #80
        sta GFX_ARG3_LO                 ; w = 80
        lda #7
        sta GFX_ARG3_MID                ; h = 7 (gardons frame top y=80)
        lda #$02
        sta GFX_COLOR                   ; color = 2 (green)
        jsr kernel_gfx_fill_rect

        ; ── Sprint GPU-3 v0.3 : démo kernel_gfx_text ──────────────
        ; 1. Pré-charger bitmap 'O' à SDRAM[$001000 + 'O'*8 = $001278]
        ;    via kernel_vram_write_block (depuis bank 1 mini_font_O).
        lda #<mini_font_O
        sta DP_PCPTR
        lda #>mini_font_O
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        lda #$78
        sta VRAM_OP_ADDR_LO
        lda #$12
        sta VRAM_OP_ADDR_MID
        lda #$00
        sta VRAM_OP_ADDR_HI
        lda #$08
        sta VRAM_OP_LEN_LO
        lda #$00
        sta VRAM_OP_LEN_HI
        jsr kernel_vram_write_block

        ; 2. Pré-charger bitmap 'S' à SDRAM[$001000 + 'S'*8 = $001298]
        lda #<mini_font_S
        sta DP_PCPTR
        lda #>mini_font_S
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        lda #$98
        sta VRAM_OP_ADDR_LO
        lda #$12
        sta VRAM_OP_ADDR_MID
        lda #$00
        sta VRAM_OP_ADDR_HI
        lda #$08
        sta VRAM_OP_LEN_LO
        lda #$00
        sta VRAM_OP_LEN_HI
        jsr kernel_vram_write_block

        ; 3. Pré-charger string "OS\\0" à SDRAM[$002000]
        lda #<mini_text_OS
        sta DP_PCPTR
        lda #>mini_text_OS
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        lda #$00
        sta VRAM_OP_ADDR_LO
        lda #$20
        sta VRAM_OP_ADDR_MID
        lda #$00
        sta VRAM_OP_ADDR_HI
        lda #$03
        sta VRAM_OP_LEN_LO
        lda #$00
        sta VRAM_OP_LEN_HI
        jsr kernel_vram_write_block

        ; 4. TEXT(base=$00C000, font=$001000, str=$002000, x=24, y=11,
        ;    color=15) : écrit "OS" en blanc dans la titlebar de window 1.
        lda #$00
        sta GFX_BASE_LO
        lda #$C0
        sta GFX_BASE_MID
        lda #$00
        sta GFX_BASE_HI                 ; base = $00C000
        lda #$00
        sta GFX_FONT_LO
        lda #$10
        sta GFX_FONT_MID
        lda #$00
        sta GFX_FONT_HI                 ; font = $001000
        lda #$00
        sta GFX_STR_LO
        lda #$20
        sta GFX_STR_MID
        lda #$00
        sta GFX_STR_HI                  ; str = $002000
        lda #24
        sta GFX_ARG2_LO                 ; x = 24
        lda #11
        sta GFX_ARG2_MID                ; y = 11 (1 px sous frame top y=10)
        lda #$0F
        sta GFX_COLOR                   ; color = 15 (white)
        jsr kernel_gfx_text

        ; ── Sprint 3.c v0.3 : true drag window 2 → (300, 300) ────
        ; BLIT depuis ancienne pos (50, 80) vers nouvelle (300, 300).
        ; src = base + 80*512 + 50/2  = $00C000 + 40985 = $016019.
        ; dst = base + 300*512+ 300/2 = $00C000 + 153750 = $031896.
        ; byte_w = 40, byte_h = 60.
        lda #$19
        sta GFX_BASE_LO
        lda #$60
        sta GFX_BASE_MID
        lda #$01
        sta GFX_BASE_HI                 ; src = $016019
        lda #$96
        sta GFX_ARG2_LO
        lda #$18
        sta GFX_ARG2_MID
        lda #$03
        sta GFX_ARG2_HI                 ; dst = $031896
        lda #40
        sta GFX_ARG3_LO
        lda #60
        sta GFX_ARG3_MID
        jsr kernel_gfx_blit

        ; CLEAR ancienne pos (50, 80, 80, 60) en color 0 (effacement).
        ; Utilise FILL_RECT car CLEAR opère sur range linéaire, pas rect.
        lda #$00
        sta GFX_BASE_LO
        lda #$C0
        sta GFX_BASE_MID
        lda #$00
        sta GFX_BASE_HI                 ; base = $00C000
        lda #50
        sta GFX_ARG2_LO                 ; x = 50
        lda #80
        sta GFX_ARG2_MID                ; y = 80
        lda #80
        sta GFX_ARG3_LO                 ; w = 80
        lda #60
        sta GFX_ARG3_MID                ; h = 60
        lda #$00
        sta GFX_COLOR                   ; color = 0 (efface)
        jsr kernel_gfx_fill_rect

        ; ── Sprint 3.c v0.4 démo : window 3 colorful (140, 100) ──
        ; Démontre la palette VGA 16 couleurs avec une 3e fenêtre :
        ; frame=lightred(12), title=yellow(14), body=lightcyan(11).
        ; v0.1 limite : x+w-1 ≤ 255 et y+h-1 ≤ 255 (8-bit ZP args).
        lda #$00
        sta WIN_BASE_LO
        lda #$C0
        sta WIN_BASE_MID
        lda #$00
        sta WIN_BASE_HI                 ; base = $00C000
        lda #140
        sta WIN_X                       ; x = 140
        lda #100
        sta WIN_Y                       ; y = 100
        lda #80
        sta WIN_W                       ; w = 80 (x_end=219 OK 8-bit)
        lda #60
        sta WIN_H                       ; h = 60 (y_end=159 OK 8-bit)
        lda #8
        sta WIN_TITLEBAR_H
        lda #$0C
        sta WIN_COLOR_FRAME             ; lightred
        lda #$0E
        sta WIN_COLOR_TITLE             ; yellow
        lda #$0B
        sta WIN_COLOR_BODY              ; lightcyan
        jsr kernel_window_draw

        ; ── Sentinel "ORIOS\x00" + "v0.3\x00" ───────────────────────
        lda #'O'
        sta SENTINEL_BASE+0
        lda #'R'
        sta SENTINEL_BASE+1
        lda #'I'
        sta SENTINEL_BASE+2
        lda #'O'
        sta SENTINEL_BASE+3
        lda #'S'
        sta SENTINEL_BASE+4
        lda #$00
        sta SENTINEL_BASE+5     ; STZ ne supporte pas le long addressing

        lda #'v'
        sta VERSION_BASE+0
        lda #'0'
        sta VERSION_BASE+1
        lda #'.'
        sta VERSION_BASE+2
        lda #'7'
        sta VERSION_BASE+3
        lda #$00
        sta VERSION_BASE+4

        ; ── Init compteurs et état scheduler ───────────────────────
        lda #$00
        sta TICK_COUNTER
        sta TASK_A_CTR
        sta TASK_B_CTR
        ; ADR-14 : init TCB table + bitmap (16 slots).
        ; Bitmap : bits 0,1,2 set ($07) — slot 0 invalid + TCB_1 + TCB_2.
        lda #$07
        sta TCB_BITMAP
        lda #$00
        sta TCB_BITMAP+1
        ; TCB_1 (task A, current/RUNNING).
        lda #$01
        sta TCB_1+TCB_PID
        lda #TASK_STATE_RUNNING
        sta TCB_1+TCB_STATE
        lda #$00
        sta TCB_1+TCB_PRIO
        sta TCB_1+TCB_PARENT
        sta TCB_1+TCB_S_LO      ; saved_S sera mis à jour au 1er IRQ
        sta TCB_1+TCB_S_HI
        sta TCB_1+TCB_DB
        sta TCB_1+TCB_STACK_BANK
        sta TCB_1+TCB_FLAGS
        lda #<task_a_entry
        sta TCB_1+TCB_PC_LO
        lda #>task_a_entry
        sta TCB_1+TCB_PC_HI
        lda #$01
        sta TCB_1+TCB_PB
        ; TCB_2 (task B, READY).
        lda #$02
        sta TCB_2+TCB_PID
        lda #TASK_STATE_READY
        sta TCB_2+TCB_STATE
        lda #$00
        sta TCB_2+TCB_PRIO
        sta TCB_2+TCB_PARENT
        sta TCB_2+TCB_DB
        sta TCB_2+TCB_STACK_BANK
        sta TCB_2+TCB_FLAGS
        lda #<task_b_entry
        sta TCB_2+TCB_PC_LO
        lda #>task_b_entry
        sta TCB_2+TCB_PC_HI
        lda #$01
        sta TCB_2+TCB_PB
        ; CUR_PID = 1 (task A).
        lda #$01
        sta TASK_CUR

        ; ── Pré-init stack task B avec frame d'interrupt fake ──────
        ; Layout (mode N : hw push 4 bytes, handler push 3 bytes) :
        ;   $02F5 : Y init = 0       (3e ply du handler)
        ;   $02F6 : X init = 0       (2e plx du handler)
        ;   $02F7 : A init = 0       (1er pla du handler)
        ;   $02F8 : P init = $30 (mode N M=1 X=1, I=0 → IRQ enabled)
        ;   $02F9 : PCL of task_b_entry
        ;   $02FA : PCH of task_b_entry
        ;   $02FB : PB = $01 (bank 1)
        ; S "sauvegardé" pour B = $02F4 (handler reprend par ply à $02F5).
        lda #$00
        sta $0002F5             ; Y_init
        sta $0002F6             ; X_init
        sta $0002F7             ; A_init
        lda #$30                ; M=1, X=1 (mode N), I=0 (IRQ enabled)
        sta $0002F8             ; P_init
        lda #<task_b_entry
        sta $0002F9             ; PCL
        lda #>task_b_entry
        sta $0002FA             ; PCH
        lda #$01
        sta $0002FB             ; PB

        ; TCB_2.saved_S = $02F4 (frame fake task B).
        rep #$20
        lda #$02F4
        sta TCB_2_S
        sep #$20

        ; ── Sprint 2.c/2.e : install charset + clear + console init + banner ──
        jsr kernel_install_charset
        ; ── SP-3.d : upload la fonte (charset ASCII, 1024 o) en SDRAM pour le
        ;    GPU TEXT/TEXT16 (toolkit). DP_PCPTR = bank1:CHARSET_SRC. ──────
        jsr kernel_tk_font_init

        ; ── OS-2.e.2 : self-tests console (scroll + CR) AVANT clear_screen ──
        ; (le clear suivant efface l'écran ; les résultats vont en bank 1).
        ; Scroll : 'S' en ligne1/col1 ($BBA9) doit remonter ligne0/col1 ($BB81).
        lda #'S'
        sta $00BBA9
        jsr kernel_scroll_up
        lda $00BB81             ; = 'S' si scroll OK
        sta SCROLL_TEST_RES+0
        lda $00BFB8             ; dernière ligne effacée → espace $20
        sta SCROLL_TEST_RES+1
        ; CR : curseur $BB85/X=5 → CR → $BB80/X=0.
        rep #$20
        lda #$BB85
        sta CURSOR_ADDR
        sep #$20
        lda #$05
        sta CURSOR_X
        lda #$0D                ; CR
        jsr kernel_print_char
        lda CURSOR_ADDR         ; low byte → doit être $80
        sta SCROLL_TEST_RES+2
        lda CURSOR_X            ; doit être $00
        sta SCROLL_TEST_RES+3

        ; ── OS-2.i.v2 : self-test log (COP invalide → 1 entrée WARN) ──
        ; num syscall $50 (≥ $40) → cop_invalid journalise (WARN, ERR_BAD_SYSCALL).
        lda #$50
        cop #$AA
        lda LOG_COUNT           ; doit être 1
        sta LOG_TEST_RES+0
        lda LOG_RING+0          ; entrée 0 : level (head=0) → LOG_WARN
        sta LOG_TEST_RES+1
        lda LOG_RING+1          ; entrée 0 : code → ERR_BAD_SYSCALL
        sta LOG_TEST_RES+2

        ; ── SP-3.e self-test : window manager + souris (ADR-24) ──────
        jsr kernel_mouse_init
        jsr kernel_wm_init
        ; fenêtre 0 @ (100,100, 80×60)
        rep #$20
        lda #100
        sta WM_ARG_X
        sta WM_ARG_Y
        lda #80
        sta WM_ARG_W
        lda #60
        sta WM_ARG_H
        sep #$20
        jsr kernel_wm_add
        sta WM_TEST_RES+0       ; id0 = 0
        ; fenêtre 1 @ (300,300, 80×60)
        rep #$20
        lda #300
        sta WM_ARG_X
        sta WM_ARG_Y
        lda #80
        sta WM_ARG_W
        lda #60
        sta WM_ARG_H
        sep #$20
        jsr kernel_wm_add
        sta WM_TEST_RES+1       ; id1 = 1
        ; hit-test (110,110) → 0
        rep #$20
        lda #110
        sta WM_ARG_X
        sta WM_ARG_Y
        sep #$20
        jsr kernel_wm_hit_test
        sta WM_TEST_RES+2
        ; hit-test (320,320) → 1
        rep #$20
        lda #320
        sta WM_ARG_X
        sta WM_ARG_Y
        sep #$20
        jsr kernel_wm_hit_test
        sta WM_TEST_RES+3
        ; hit-test (500,500) → $FF
        rep #$20
        lda #500
        sta WM_ARG_X
        sta WM_ARG_Y
        sep #$20
        jsr kernel_wm_hit_test
        sta WM_TEST_RES+4
        ; focus fenêtre 1
        lda #$01
        jsr kernel_wm_set_focus
        lda WM_FOCUS
        sta WM_TEST_RES+5       ; = 1
        ; move focus (+50,+10) → fenêtre 1 x : 300 → 350
        rep #$20
        lda #50
        sta WM_ARG_DX
        lda #10
        sta WM_ARG_DY
        sep #$20
        jsr kernel_wm_move_focused
        lda #$01
        jsr kernel_wm_offset
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        sta WM_TEST_RES+6       ; = 350 ($015E)
        sep #$20
        ; lecture souris (position injectée par le test) → MOUSE_X/BTN
        jsr kernel_mouse_read
        rep #$20
        lda MOUSE_X
        sta WM_TEST_RES+8       ; X souris injectée
        sep #$20
        lda MOUSE_BTN
        sta WM_TEST_RES+10

        ; ── SP-3.d v0.2 : widgets managés attachés à la fenêtre 0 ─────
        ; Enregistrés AVANT le redraw → dessinés avec la fenêtre, persistent
        ; au drag (suivent la fenêtre). Label noir + bouton "OK".
        lda #$00
        sta WG_PARENT                   ; fenêtre 0
        lda #WG_TYPE_LABEL
        sta WG_TYPE
        rep #$20
        lda #6
        sta WM_ARG_X
        lda #16
        sta WM_ARG_Y
        lda #0
        sta WM_ARG_W
        lda #0
        sta WM_ARG_H
        sep #$20
        lda #$00                        ; label noir sur corps lightgray
        sta GFX_COLOR
        lda #<tk_demo_os
        sta DP_PCPTR
        lda #>tk_demo_os
        sta DP_PCPTR+1
        jsr kernel_wm_add_widget
        ; bouton "OK" rel(6,34, 44×18)
        lda #$00
        sta WG_PARENT
        lda #WG_TYPE_BUTTON
        sta WG_TYPE
        rep #$20
        lda #6
        sta WM_ARG_X
        lda #34
        sta WM_ARG_Y
        lda #44
        sta WM_ARG_W
        lda #18
        sta WM_ARG_H
        sep #$20
        lda #<tk_demo_ok
        sta DP_PCPTR
        lda #>tk_demo_ok
        sta DP_PCPTR+1
        jsr kernel_wm_add_widget

        ; SP-3.e v0.3 : dessine le desktop XVGA (fenêtres + widgets) via GPU
        ; FILL_RECT16 à SDRAM $100000. Visible avec --xvga / --xvga-screenshot.
        jsr kernel_wm_redraw
        jsr kernel_wm_draw_cursor       ; v0.5 : curseur initial

        jsr kernel_clear_screen
        jsr kernel_console_init
        jsr kernel_print_banner

        ; ── B3 : démo bascule E→N (paravirtualisation guest Oric 1) ──
        ; Affiche message entrée guest
        lda #$01
        sta DP_PTR+2
        lda #<str_b3_guest_in
        sta DP_PTR
        lda #>str_b3_guest_in
        sta DP_PTR+1
        jsr kernel_print_string
        ; Bascule mode E — simulation guest Oric 1 (ADR-18 / B3)
        sec
        xce                     ; → mode E (comportement 6502 strict)
        ldx #$20                ; 32 NOP en mode E
b3_guest_loop:
        nop
        dex
        bne b3_guest_loop
        ; Retour mode N
        clc
        xce                     ; → mode N
        sep #$30                ; restaure M=X=1
        ; Affiche confirmation retour
        lda #$01
        sta DP_PTR+2
        lda #<str_b3_guest_out
        sta DP_PTR
        lda #>str_b3_guest_out
        sta DP_PTR+1
        jsr kernel_print_string

        ; ── Sprint 2.f : test COP syscall (ADR-13) ─────────────────
        ; SYS_PRINT_CHAR ($01) : X = char.
        ldx #'Y'
        lda #$01
        cop #$AA                ; signature OricOS

        ; ── Sprint 2.i : test print_hex8 ───────────────────────────
        lda #$AB
        jsr kernel_print_hex8

        ; ── Sprint 2.k : bundle_validate (ré-activé après fix bug) ──
        lda #$01
        sta DP_PTR+2
        lda #<bundle_test
        sta DP_PTR
        lda #>bundle_test
        sta DP_PTR+1
        jsr kernel_bundle_validate
        sta BUNDLE_VALIDATE_RES

        ; ── Sprint 2.l : bundle_find_code ──────────────────────────
        jsr kernel_bundle_find_code
        ; A = $00 OK, BUNDLE_FOUND_SIZE/OFFSET stockés.

        ; ── OS-2.d : init driver clavier Oric 2 (KBD2 IRQ, ADR-22) ──
        jsr kernel_kbd_init

        ; Démo OS-2.d : draine la FIFO KBD2 (touche éventuellement pré-injectée
        ; par le test) vers le ring, puis lit via SYS_GET_KEY ($06). Le keycode
        ; est stocké en KBD_GETKEY_RES (sentinelle test). $00 si aucune touche.
        jsr kernel_kbd_poll
        lda #$06                ; SYS_GET_KEY
        cop #$AA
        sta KBD_GETKEY_RES

        ; ── Sprint 2.b/2.h : init bank allocator (bump + free list) ──
        lda #BANK_POOL_BASE
        sta BANK_NEXT
        lda #$00
        sta BANK_FREE_TOP

        ; ── Sprint VRAM-3 : init pool LIVE (banks 129-159, ADR-19) ──
        lda #BANK_LIVE_POOL_BASE
        sta BANK_LIVE_NEXT
        lda #$00
        sta BANK_LIVE_FREE_TOP

        ; Démo live : alloc 3, free 1, alloc 1 → résultats à BANK_LIVE_DEMO.
        jsr kernel_alloc_live_bank
        sta BANK_LIVE_DEMO+0    ; = $84 (132)
        jsr kernel_alloc_live_bank
        sta BANK_LIVE_DEMO+1    ; = $85 (133)
        jsr kernel_alloc_live_bank
        sta BANK_LIVE_DEMO+2    ; = $86 (134)
        lda BANK_LIVE_DEMO+1    ; libère $85
        jsr kernel_free_live_bank
        jsr kernel_alloc_live_bank
        sta BANK_LIVE_DEMO+3    ; doit être $85 (free list pop)

        ; Démo : alloue 3 banks, stocke à BANK_DEMO+0..2.
        jsr kernel_alloc_bank
        sta BANK_DEMO+0         ; = $04
        jsr kernel_alloc_bank
        sta BANK_DEMO+1         ; = $05
        jsr kernel_alloc_bank
        sta BANK_DEMO+2         ; = $06

        ; Sprint 2.h : test free list LIFO.
        lda BANK_DEMO+1         ; $05
        jsr kernel_free_bank
        jsr kernel_alloc_bank
        sta BANK_DEMO+3         ; doit être $05 (free list pop)

        ; ── Sprint 2.l.1 : kernel_app_exec sur bundle_test ─────────
        ; Doit être APRÈS bank init (alloc dépend de BANK_NEXT).
        lda #$01
        sta DP_PTR+2
        lda #<bundle_test
        sta DP_PTR
        lda #>bundle_test
        sta DP_PTR+1
        jsr kernel_app_exec
        ; App exec : 'Z' écrit à $BBAB.

        ; ── Sprint 2.j.0 : test kernel_sd_read_block ──────────────
        ; LBA = 0 (premier bloc), dest = $01:5D40 (zone libre bank 1).
        lda #$00
        sta $30                         ; LBA_LO
        sta $31                         ; LBA_HI (pour le moment 16-bit)
        lda #$40
        sta DP_PCPTR
        lda #$5D
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_sd_read_block
        ; Sans SD image : 512 zéros copiés. Avec image : contenu bloc 0.

        ; ── Sprint 2.j.2 : kernel_fat_init (signature FAT32) ──────
        ; Lit boot sector dans FS_BUFFER, valide signature.
        ; Buffer FS distinct ($5F60) → préserve test 2.j.1 à $5D40.
        jsr kernel_fat_init

        ; ── Sprint 2.j.4 : kernel_fat_open "HELLO   BIN" ──────────
        ; Setup DP_FILENAME 11 bytes (uppercase 8.3 padded espaces).
        lda #'H'
        sta $40
        lda #'E'
        sta $41
        lda #'L'
        sta $42
        sta $43
        lda #'O'
        sta $44
        lda #' '
        sta $45
        sta $46
        sta $47
        lda #'B'
        sta $48
        lda #'I'
        sta $49
        lda #'N'
        sta $4A
        jsr kernel_fat_open
        ; Sans image FAT32 valide : FS_OPEN_RESULT = $01.
        ; Avec image + entry "HELLO   BIN" : FS_OPEN_RESULT = $00,
        ; FS_FOUND_CLUSTER + FS_FOUND_SIZE renseignés.

        ; ── Sprint 2.j.5 : kernel_fat_read_cluster du cluster trouvé ──
        ; Si fat_open OK, lit le 1er cluster du fichier vers $01:6200.
        lda FS_OPEN_RESULT
        bne skip_fat_read
        lda #$00
        sta DP_PCPTR
        lda #$62
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_fat_read_cluster

        ; ── Sprint 2.j.6 : exec app depuis bundle chargé via SD ───
        ; DP_PTR = $01:6200 (bundle SD-loaded). kernel_app_exec validera,
        ; trouvera la section CODE, allouera une bank et l'exécutera.
        ; L'app écrira un autre 'Z' à $BBAC (CURSOR_ADDR avancé après
        ; le premier 'Z' du bundle_test inline).
        lda #$00
        sta DP_PTR
        lda #$62
        sta DP_PTR+1
        lda #$01
        sta DP_PTR+2
        jsr kernel_app_exec

        ; ── Sprint 2.j v0.2 : test cluster chain ─────────────────────
        ; Set FS_QUERY_CLUSTER = 4 (cluster fictif BIG.BIN), appelle
        ; kernel_fat_next_cluster. Sur l'image test, FAT[4] = 5 →
        ; FS_NEXT_CLUSTER doit valoir 5. Validation chaîne FAT32.
        ; Préserve FS_FOUND_CLUSTER (résultat fat_open intact).
        lda #$04
        sta FS_QUERY_CLUSTER
        lda #$00
        sta FS_QUERY_CLUSTER+1
        sta FS_QUERY_CLUSTER+2
        sta FS_QUERY_CLUSTER+3
        jsr kernel_fat_next_cluster
skip_fat_read:

        ; ── Sprint 2.j v0.3 : fat_read_file (multi-cluster) ──────────
        ; Open "BIG     BIN" puis lit le fichier complet (2 clusters)
        ; vers $01:7000. ASSERT cluster 4 (LBA 162) à $01:7000..$01:71FF
        ; (pattern $AA), cluster 5 (LBA 163) à $01:7200..$01:73FF ($55).
        lda #'B'
        sta $40
        lda #'I'
        sta $41
        lda #'G'
        sta $42
        lda #' '
        sta $43
        sta $44
        sta $45
        sta $46
        sta $47
        lda #'B'
        sta $48
        lda #'I'
        sta $49
        lda #'N'
        sta $4A
        jsr kernel_fat_open
        lda FS_OPEN_RESULT
        bne skip_big_read
        ; DP_PCPTR = $01:7000 (dest fichier complet)
        lda #$00
        sta DP_PCPTR
        lda #$70
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_fat_read_file
skip_big_read:

        ; ── Sprint 2.l v0.2 : app multi-cluster depuis SD ────────────
        ; Open MULTI.BIN (bundle 527B, 2 clusters), lit via fat_read_file
        ; vers $01:8000, puis exec via kernel_app_exec. App écrit 'X' à
        ; $BBAD (3e char après les 2 'Z' précédents). Valide qu'app_exec
        ; supporte un bundle multi-cluster avec section CODE à offset
        ; > 512 (offset = 520 dans cet exemple).
        lda #'M'
        sta $40
        lda #'U'
        sta $41
        lda #'L'
        sta $42
        lda #'T'
        sta $43
        lda #'I'
        sta $44
        lda #' '
        sta $45
        sta $46
        sta $47
        lda #'B'
        sta $48
        lda #'I'
        sta $49
        lda #'N'
        sta $4A
        jsr kernel_fat_open
        lda FS_OPEN_RESULT
        bne skip_multi_exec
        ; DP_PCPTR = $01:8000 (dest fichier MULTI.BIN)
        lda #$00
        sta DP_PCPTR
        lda #$80
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_fat_read_file
        ; DP_PTR = $01:8000 (bundle MULTI loaded), exec.
        lda #$00
        sta DP_PTR
        lda #$80
        sta DP_PTR+1
        lda #$01
        sta DP_PTR+2
        jsr kernel_app_exec
skip_multi_exec:

        ; ── Configure VIA T1 timer en mode continuous interrupt ────
        ; ACR bit 7=0, bit 6=1 → T1 continuous, no PB7 output.
        lda #$40
        sta VIA_ACR
        ; T1 latch low / high. Écrire T1CH démarre le timer en chargeant
        ; le counter depuis le latch.
        lda #T1_PERIOD_LO
        sta VIA_T1CL            ; latch low
        lda #T1_PERIOD_HI
        sta VIA_T1CH            ; latch high + start counter
        ; IER : bit 7 = set, bit 6 = T1 enable. Écrire $C0 enable T1 IRQ.
        lda #$C0
        sta VIA_IER

        ; ── Active interruptions et démarre task A ─────────────────
        cli                     ; I=0 → IRQ enabled
        jmp task_a_entry        ; same bank, JMP suffit

; ════════════════════════════════════════════════════════════════════
;  kernel_fat_init — vérifie signature FAT32 du boot sector (Sprint 2.j.2)
; ════════════════════════════════════════════════════════════════════
;
; Effets : lit bloc 0 (boot sector) dans FS_BUFFER, vérifie signature
;          "FAT32" à offset $52. FS_INIT_RESULT = $00 (OK) ou $01 (BAD).
; Modifie : A, X, Y, FS_BUFFER, FS_INIT_RESULT, $30/$31, DP_PCPTR.
; Pré-cond : SD device présent et image chargée.
; ════════════════════════════════════════════════════════════════════
.export kernel_fat_init
kernel_fat_init:
        ; Lit LBA 0 dans FS_BUFFER
        lda #$00
        sta $30
        sta $31
        lda #<FS_BUFFER
        sta DP_PCPTR
        lda #>FS_BUFFER
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_sd_read_block

        ; Vérifie "FAT32" à FS_BUFFER+$52..+$56
        lda FS_BUFFER + FS_FAT32_SIG + 0
        cmp #'F'
        bne fat_init_bad
        lda FS_BUFFER + FS_FAT32_SIG + 1
        cmp #'A'
        bne fat_init_bad
        lda FS_BUFFER + FS_FAT32_SIG + 2
        cmp #'T'
        bne fat_init_bad
        lda FS_BUFFER + FS_FAT32_SIG + 3
        cmp #'3'
        bne fat_init_bad
        lda FS_BUFFER + FS_FAT32_SIG + 4
        cmp #'2'
        bne fat_init_bad
        ; Sig OK : parse les champs FAT32
        jsr fat_parse_boot_sector
        lda #$00
        sta FS_INIT_RESULT
        rts
fat_init_bad:
        lda #$01
        sta FS_INIT_RESULT
        rts

; ════════════════════════════════════════════════════════════════════
;  fat_parse_boot_sector — parse champs FAT32 + calcule FDS (interne)
; ════════════════════════════════════════════════════════════════════
;
; Pré-cond : FS_BUFFER contient le boot sector valide.
; Effets : remplit FS_BPS, FS_SPC, FS_RSC, FS_NFAT, FS_SPF, FS_ROOT,
;          FS_FDS (= FS_RSC + FS_NFAT * FS_SPF, 16-bit en v0.1).
; Modifie : A, X, Y.
; ════════════════════════════════════════════════════════════════════
fat_parse_boot_sector:
        ; FS_BPS (2B) ← FS_BUFFER + BS_BPS
        lda FS_BUFFER + BS_BPS
        sta FS_BPS
        lda FS_BUFFER + BS_BPS + 1
        sta FS_BPS+1
        ; FS_SPC (1B)
        lda FS_BUFFER + BS_SPC
        sta FS_SPC
        ; FS_RSC (2B)
        lda FS_BUFFER + BS_RSC
        sta FS_RSC
        lda FS_BUFFER + BS_RSC + 1
        sta FS_RSC+1
        ; FS_NFAT (1B)
        lda FS_BUFFER + BS_NFAT
        sta FS_NFAT
        ; FS_SPF (4B)
        lda FS_BUFFER + BS_SPF
        sta FS_SPF
        lda FS_BUFFER + BS_SPF + 1
        sta FS_SPF+1
        lda FS_BUFFER + BS_SPF + 2
        sta FS_SPF+2
        lda FS_BUFFER + BS_SPF + 3
        sta FS_SPF+3
        ; FS_ROOT (4B)
        lda FS_BUFFER + BS_ROOT
        sta FS_ROOT
        lda FS_BUFFER + BS_ROOT + 1
        sta FS_ROOT+1
        lda FS_BUFFER + BS_ROOT + 2
        sta FS_ROOT+2
        lda FS_BUFFER + BS_ROOT + 3
        sta FS_ROOT+3

        ; FS_FDS = FS_RSC + FS_NFAT * FS_SPF (v0.1 16-bit max).
        ; Init FS_FDS = FS_RSC, puis ajouter FS_SPF NFAT fois.
        rep #$20
        lda FS_RSC
        sta FS_FDS
        sep #$20
        lda #$00
        sta FS_FDS+2
        sta FS_FDS+3
        lda FS_NFAT             ; ldx long-abs n'existe pas → via lda+tax
        tax
fds_loop:
        cpx #$00
        beq fds_done
        rep #$20
        lda FS_FDS
        clc
        adc FS_SPF
        sta FS_FDS
        sep #$20
        dex
        bra fds_loop
fds_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_fat_open — recherche un fichier dans le root dir (Sprint 2.j.4)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP+$40..$4A = filename 11B (8.3 padded espaces, uppercase).
; Effets : si trouvé, FS_FOUND_CLUSTER = first_cluster (4B),
;          FS_FOUND_SIZE = size (4B), FS_OPEN_RESULT = $00.
;          Sinon FS_OPEN_RESULT = $01.
; v0.1 : 1 secteur de root dir (16 entries max). FS_ROOT supposé = 2,
;        donc LBA root = FS_FDS. Cluster chain non parcourue (TODO v0.2).
; Modifie : A, X, Y, FS_BUFFER, FS_FOUND_*, $30/$31, DP_PCPTR, $50-$52.
; Pré-cond : kernel_fat_init OK (FS_INIT_RESULT = 0).
; ════════════════════════════════════════════════════════════════════
.export kernel_fat_open
kernel_fat_open:
        ; LBA = FS_FDS (16-bit, suppose root_cluster = 2)
        rep #$20
        lda FS_FDS
        sta $30
        sep #$20
        ; dest = FS_BUFFER
        lda #<FS_BUFFER
        sta DP_PCPTR
        lda #>FS_BUFFER
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_sd_read_block

        ; Init pointer DP_ENTRY = FS_BUFFER (entry 0)
        lda #<FS_BUFFER
        sta DP_ENTRY
        lda #>FS_BUFFER
        sta DP_ENTRY+1
        lda #$01
        sta DP_ENTRY+2

        ldx #$00                        ; entry counter (max 16 = $0200/$20)
fop_loop:
        cpx #16
        bcs fop_not_found

        ; Lire byte 0 de l'entry
        ldy #DE_NAME
        lda [DP_ENTRY],Y
        cmp #$00
        beq fop_not_found               ; $00 = end of dir
        cmp #$E5
        beq fop_next_entry              ; deleted

        ; Skip LFN ($0F)
        ldy #DE_ATTR
        lda [DP_ENTRY],Y
        cmp #DE_ATTR_LFN
        beq fop_next_entry
        ; Skip volume_label / directory
        and #DE_ATTR_DIR_VOL
        bne fop_next_entry

        ; Compare 11 bytes : entry name vs DP_FILENAME
        ldy #$00
fop_cmp:
        lda [DP_ENTRY],Y
        cmp a:DP_FILENAME,Y             ; cmp abs,Y (D9 abs LE) ; force abs
        bne fop_next_entry
        iny
        cpy #11
        bcc fop_cmp

        ; Match ! Lit cluster_low (offset $1A 2B)
        ldy #DE_CLUS_LO
        lda [DP_ENTRY],Y
        sta FS_FOUND_CLUSTER
        iny
        lda [DP_ENTRY],Y
        sta FS_FOUND_CLUSTER+1
        ; cluster_high (offset $14 2B)
        ldy #DE_CLUS_HI
        lda [DP_ENTRY],Y
        sta FS_FOUND_CLUSTER+2
        iny
        lda [DP_ENTRY],Y
        sta FS_FOUND_CLUSTER+3
        ; size (offset $1C 4B)
        ldy #DE_SIZE
        lda [DP_ENTRY],Y
        sta FS_FOUND_SIZE
        iny
        lda [DP_ENTRY],Y
        sta FS_FOUND_SIZE+1
        iny
        lda [DP_ENTRY],Y
        sta FS_FOUND_SIZE+2
        iny
        lda [DP_ENTRY],Y
        sta FS_FOUND_SIZE+3
        lda #$00
        sta FS_OPEN_RESULT
        rts

fop_next_entry:
        ; Avance pointer de 32 bytes
        rep #$20
        lda DP_ENTRY
        clc
        adc #DE_SIZE_BYTES
        sta DP_ENTRY
        sep #$20
        inx
        bra fop_loop

fop_not_found:
        lda #$01
        sta FS_OPEN_RESULT
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_fat_read_cluster — lit 1 cluster vers dest (Sprint 2.j.5)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP_PCPTR (= $0C-$0E) = pointer 24-bit destination (déjà setup).
;        FS_FOUND_CLUSTER = cluster à lire (4B).
; Effets : copie 1 secteur (SPC * BPS = 512 octets en v0.1) vers dest.
; v0.1 : assume SPC=1, FS_FDS et cluster < 65536 (16-bit arithm).
;        Pour cluster chain réelle, voir OS-2.j.5b/v0.2.
; Modifie : A, X, Y, $30/$31, FS_BUFFER (transitoirement).
; Pré-cond : kernel_fat_open a renseigné FS_FOUND_CLUSTER.
; ════════════════════════════════════════════════════════════════════
.export kernel_fat_read_cluster
kernel_fat_read_cluster:
        ; LBA = FS_FDS + (FS_FOUND_CLUSTER - 2) * FS_SPC
        ; v0.1 simplifié : SPC=1 → LBA = FS_FDS + cluster - 2.
        rep #$20
        lda FS_FOUND_CLUSTER
        sec
        sbc #$0002
        clc
        adc FS_FDS
        sta $30                         ; LBA pour sd_read_block
        sep #$20
        jsr kernel_sd_read_block
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_fat_next_cluster — lit FAT entry (Sprint 2.j v0.2)
; ════════════════════════════════════════════════════════════════════
;
; Args : FS_QUERY_CLUSTER (4B) = cluster courant.
; Effets : FS_NEXT_CLUSTER (4B) = cluster suivant dans la chaîne FAT32.
;          Si FS_NEXT_CLUSTER >= $0FFFFFF8 → EOC (fin de chaîne).
;          High nibble du byte 3 masqué (FAT32 = 28 bits effectifs).
; v0.2 : suppose BPS=512, cluster < 16384 (offset_bytes 16-bit).
;        FAT lookup : LBA = FS_RSC + cluster*4/512,
;                     offset_in_sec = cluster*4 % 512.
; Modifie : A, X, Y, FS_BUFFER (FAT sector), $20-$21, $30-$32, DP_PCPTR,
;           DP_ENTRY ($50-$52).
; Pré-cond : kernel_fat_init OK.
; ════════════════════════════════════════════════════════════════════
.export kernel_fat_next_cluster
kernel_fat_next_cluster:
        ; tmp = FS_QUERY_CLUSTER (low 16) * 4
        rep #$20
        lda FS_QUERY_CLUSTER
        asl                             ; *2
        asl                             ; *4
        sta $20                         ; tmp_offset 16-bit ($20-$21)
        sep #$20

        ; sector_offset = tmp >> 9 = ($21 >> 1) en 8-bit (cluster < 16384)
        lda $21
        lsr a
        ; LBA = FS_RSC + sector_offset (16-bit)
        clc
        adc FS_RSC
        sta $30
        lda FS_RSC+1
        adc #$00
        sta $31
        lda #$00
        sta $32

        ; DP_PCPTR = FS_BUFFER (bank 1)
        lda #<FS_BUFFER
        sta DP_PCPTR
        lda #>FS_BUFFER
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_sd_read_block

        ; DP_ENTRY = FS_BUFFER + offset_in_sec
        ; offset_in_sec = ($21 & 1) << 8 | $20 (max $1FF)
        clc
        lda $20
        adc #<FS_BUFFER
        sta DP_ENTRY
        lda $21
        and #$01
        adc #>FS_BUFFER
        sta DP_ENTRY+1
        lda #$01
        sta DP_ENTRY+2

        ; Lire 4 octets FAT entry → FS_NEXT_CLUSTER
        ldy #$00
        lda [DP_ENTRY],y
        sta FS_NEXT_CLUSTER
        iny
        lda [DP_ENTRY],y
        sta FS_NEXT_CLUSTER+1
        iny
        lda [DP_ENTRY],y
        sta FS_NEXT_CLUSTER+2
        iny
        lda [DP_ENTRY],y
        and #$0F                        ; FAT32 = 28 bits effectifs
        sta FS_NEXT_CLUSTER+3
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_fat_read_file — lit fichier complet via cluster chain (v0.3)
; ════════════════════════════════════════════════════════════════════
;
; Args : FS_FOUND_CLUSTER (4B) = first cluster (résultat fat_open).
;        DP_PCPTR (24-bit)     = destination (sera incrémentée).
; Effets : lit cluster par cluster en suivant la chaîne FAT32 jusqu'à
;          EOC (>= $0FFFFFF8). Chaque cluster (= 1 secteur en v0.3,
;          SPC=1) est copié vers DP_PCPTR puis DP_PCPTR avance de 512.
;          FS_FOUND_CLUSTER consommé/écrasé (vaut EOC à la fin).
; v0.3 : SPC=1, fichier < 64 KiB (DP_PCPTR low+mid 16-bit, pas de
;        propagation vers bank). Pour fichier > 64K, voir v0.4.
; Modifie : A, X, Y, FS_BUFFER (transitoirement), FS_FOUND_CLUSTER,
;           FS_QUERY_CLUSTER, FS_NEXT_CLUSTER, DP_PCPTR, $20-$21,
;           $25-$27, $30-$32, DP_ENTRY.
; Pré-cond : kernel_fat_init OK + fat_open a renseigné FS_FOUND_CLUSTER.
; ════════════════════════════════════════════════════════════════════
.export kernel_fat_read_file
kernel_fat_read_file:
        ; Sauvegarde FS_FOUND_CLUSTER initial en zp tmp $28-$2B
        ; (read_file consomme FS_FOUND_CLUSTER en interne mais le restaure
        ;  à la sortie, pour que l'état "fichier ouvert" reste cohérent).
        lda FS_FOUND_CLUSTER
        sta $28
        lda FS_FOUND_CLUSTER+1
        sta $29
        lda FS_FOUND_CLUSTER+2
        sta $2A
        lda FS_FOUND_CLUSTER+3
        sta $2B
rf_loop:
        ; Test EOC : FS_FOUND_CLUSTER >= $0FFFFFF8 ?
        lda FS_FOUND_CLUSTER+3
        and #$0F                        ; FAT32 = 28 bits
        cmp #$0F
        bne rf_not_eoc
        lda FS_FOUND_CLUSTER+2
        cmp #$FF
        bne rf_not_eoc
        lda FS_FOUND_CLUSTER+1
        cmp #$FF
        bne rf_not_eoc
        lda FS_FOUND_CLUSTER
        cmp #$F8
        bcc rf_not_eoc                  ; A < $F8 → pas EOC
        jmp rf_done                     ; cluster >= $0FFFFFF8 → EOC

rf_not_eoc:
        ; Lit cluster courant (FS_FOUND_CLUSTER) vers DP_PCPTR
        jsr kernel_fat_read_cluster

        ; Avance DP_PCPTR += 512 (= $0200)
        rep #$20
        lda DP_PCPTR
        clc
        adc #$0200
        sta DP_PCPTR
        sep #$20
        ; (overflow vers DP_PCPTR+2 ignoré : v0.3 fichier < 64K)

        ; Sauvegarde DP_PCPTR avant next_cluster (qui écrase DP_PCPTR)
        lda DP_PCPTR
        sta $25
        lda DP_PCPTR+1
        sta $26
        lda DP_PCPTR+2
        sta $27

        ; FS_QUERY_CLUSTER = FS_FOUND_CLUSTER (input pour next_cluster)
        lda FS_FOUND_CLUSTER
        sta FS_QUERY_CLUSTER
        lda FS_FOUND_CLUSTER+1
        sta FS_QUERY_CLUSTER+1
        lda FS_FOUND_CLUSTER+2
        sta FS_QUERY_CLUSTER+2
        lda FS_FOUND_CLUSTER+3
        sta FS_QUERY_CLUSTER+3

        jsr kernel_fat_next_cluster

        ; Restaure DP_PCPTR (next_cluster a réutilisé DP_PCPTR pour FAT)
        lda $25
        sta DP_PCPTR
        lda $26
        sta DP_PCPTR+1
        lda $27
        sta DP_PCPTR+2

        ; FS_FOUND_CLUSTER = FS_NEXT_CLUSTER (avance dans la chaîne)
        lda FS_NEXT_CLUSTER
        sta FS_FOUND_CLUSTER
        lda FS_NEXT_CLUSTER+1
        sta FS_FOUND_CLUSTER+1
        lda FS_NEXT_CLUSTER+2
        sta FS_FOUND_CLUSTER+2
        lda FS_NEXT_CLUSTER+3
        sta FS_FOUND_CLUSTER+3

        jmp rf_loop                     ; jmp (pas bra : > 127 bytes)

rf_done:
        ; Restaure FS_FOUND_CLUSTER initial (état "fichier ouvert" cohérent).
        lda $28
        sta FS_FOUND_CLUSTER
        lda $29
        sta FS_FOUND_CLUSTER+1
        lda $2A
        sta FS_FOUND_CLUSTER+2
        lda $2B
        sta FS_FOUND_CLUSTER+3
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_sd_read_block — lit 1 bloc 512 octets (Sprint 2.j.0)
; ════════════════════════════════════════════════════════════════════
;
; Args : LBA dans X 16-bit (low 16 bits — v0.1 supporte 16M blocs).
;        DP_PCPTR ($0C-$0E) = pointer 24-bit destination.
; Effets : copie 512 octets du bloc LBA vers [DP_PCPTR..+511].
; Modifie : A, X, Y. Préserve : nothing.
; Pré-cond : mode N M=1 X=1, DBR=0, SD device présent.
; ════════════════════════════════════════════════════════════════════
.export kernel_sd_read_block
kernel_sd_read_block:
        ; LBA en X 16-bit (mais on est en X=1 8-bit). Utiliser DP zp tmp.
        ; Convention v0.1 : caller stocke LBA 16-bit en $30/$31, bit 16-23 = 0.
        ; (extension future : 24-bit en $32 si besoin de SD > 32 MiB).
        lda $30
        sta SD_LBA_LO
        lda $31
        sta SD_LBA_MID
        lda #$00
        sta SD_LBA_HI

        ; Trigger read (synchrone, busy=0 immédiat dans Phosphoric stub)
        lda #SD_CTRL_READ
        sta SD_CTRL

        ; Wait busy clear (pour cibles asynchrones futures)
sd_wait:
        lda SD_CTRL
        and #SD_CTRL_BUSY
        bne sd_wait

        ; Copy 512 bytes from SD_DATA to [DP_PCPTR],Y
        ; Y 16-bit pour parcourir 512 bytes.
        rep #$10                ; X 16-bit (Y aussi)
        ldy #$0000
sd_copy:
        cpy #$0200              ; 512
        bcs sd_done
        lda SD_DATA             ; auto-increment côté device
        sta [DP_PCPTR],Y
        iny
        bra sd_copy
sd_done:
        sep #$10
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_bundle_find_code — trouve la section CODE (Sprint 2.l)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP_PTR (24-bit) → bundle.
; Out  : A = $00 (OK) ou $03 (NOT_FOUND).
;        Si OK : BUNDLE_FOUND_SIZE = size 16-bit,
;                BUNDLE_FOUND_OFFSET = offset 16-bit.
; Modifie : A, X, Y. Préserve : nothing important.
; ════════════════════════════════════════════════════════════════════
.export kernel_bundle_find_code
kernel_bundle_find_code:
        ; Lit nsec dans DP zero page tmp ($15) pour cpx ZP.
        ldy #BNL_HDR_NSEC
        lda [DP_PTR],Y
        sta BUNDLE_FOUND_NSEC
        sta $15                 ; tmp ZP pour cpx
        ldx #$00                ; section index
fc_loop:
        cpx $15                 ; cpx zp (cpx long abs n'existe pas)
        bcs fc_not_found
        ; entry offset = BNL_HDR_SIZE + X * BNL_SEC_SIZE = 8 + X*8 = (X+1)*8
        txa
        clc
        adc #$01                ; X+1
        asl                     ; (X+1)*2
        asl                     ; (X+1)*4
        asl                     ; (X+1)*8 = BNL_HDR_SIZE + X*BNL_SEC_SIZE (pour BNL_HDR_SIZE=8 et SEC_SIZE=8)
        tay                     ; Y = entry offset (max 8 sections * 8 = 64 bytes)
        ; Read type
        lda [DP_PTR],Y
        cmp #BUNDLE_SEC_CODE
        beq fc_found
        inx
        bra fc_loop
fc_found:
        ; Read size + offset depuis entry. Y = entry start.
        iny
        iny                     ; Y = entry + 2 (size_lo)
        lda [DP_PTR],Y
        sta BUNDLE_FOUND_SIZE
        iny                     ; Y = entry + 3
        lda [DP_PTR],Y
        sta BUNDLE_FOUND_SIZE+1
        iny                     ; Y = entry + 4
        lda [DP_PTR],Y
        sta BUNDLE_FOUND_OFFSET
        iny                     ; Y = entry + 5
        lda [DP_PTR],Y
        sta BUNDLE_FOUND_OFFSET+1
        lda #BUNDLE_OK
        rts
fc_not_found:
        lda #BUNDLE_ERR_NOT_FOUND
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_bundle_validate — vérifie format OricOS bundle (Sprint 2.k)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP_PTR (24-bit) → début bundle.
; Out  : A = 0 (OK), $01 (mauvais magic), $02 (mauvaise version).
;        Préserve : X. Modifie : A, Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_bundle_validate
kernel_bundle_validate:
        ldy #$00
        lda [DP_PTR],Y
        cmp #BUNDLE_MAGIC_0
        bne bv_bad_magic
        iny
        lda [DP_PTR],Y
        cmp #BUNDLE_MAGIC_1
        bne bv_bad_magic
        iny
        lda [DP_PTR],Y
        cmp #BUNDLE_MAGIC_2
        bne bv_bad_magic
        iny
        lda [DP_PTR],Y
        cmp #BUNDLE_MAGIC_3
        bne bv_bad_magic
        ldy #BNL_HDR_VER
        lda [DP_PTR],Y
        cmp #BUNDLE_VERSION
        bne bv_bad_version
        lda #BUNDLE_OK
        rts
bv_bad_magic:
        lda #BUNDLE_ERR_MAGIC
        rts
bv_bad_version:
        lda #BUNDLE_ERR_VERSION
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_app_exec — load + run une app bundle (Sprint 2.l.1)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP_PTR (24-bit) → bundle.
; Out  : A = $00 OK ou code erreur (validate/find_code/alloc).
;        Bank app conservée allouée (free explicite v0.2).
; Modifie : A, X, Y, BUNDLE_APP_BANK, DP zero page tmp slots.
; ════════════════════════════════════════════════════════════════════
.export kernel_app_exec
kernel_app_exec:
        jsr kernel_bundle_validate
        cmp #BUNDLE_OK
        beq ae_after_validate
        rts
ae_after_validate:
        jsr kernel_bundle_find_code
        cmp #BUNDLE_OK
        beq ae_after_find
        rts
ae_after_find:
        jsr kernel_alloc_bank
        cmp #$00
        bne ae_after_alloc
        rts                             ; A=$00 (pool exhausted)
ae_after_alloc:
        sta BUNDLE_APP_BANK

        ; Setup DP_SRC = DP_PTR + BUNDLE_FOUND_OFFSET (24-bit add)
        rep #$20
        lda DP_PTR
        clc
        adc BUNDLE_FOUND_OFFSET
        sta $18                         ; DP_SRC low/high (16-bit)
        sep #$20
        lda DP_PTR+2
        sta $1A                         ; DP_SRC bank

        ; Setup DP_DEST = APP_BANK : $0200
        lda #$00
        sta $1B
        lda #$02
        sta $1C
        lda BUNDLE_APP_BANK
        sta $1D

        ; Copy section CODE byte par byte (v0.1 : size 8-bit max)
        lda BUNDLE_FOUND_SIZE
        sta $16
        ldy #$00
ae_copy:
        cpy $16
        bcs ae_copy_done
        lda [$18],Y
        sta [$1B],Y
        iny
        bra ae_copy
ae_copy_done:

        ; Patch JSL self-modifying. ld65 résout les labels CODE en 16-bit
        ; (bank=0 par défaut dans STA al). Workaround : DP indirect long
        ; avec bank=$01 explicite (CODE segment loaded en bank 1).
        lda #<app_exec_jsl_bank
        sta $20
        lda #>app_exec_jsl_bank
        sta $21
        lda #$01
        sta $22
        lda BUNDLE_APP_BANK
        sta [$20]

        jsr app_exec_call
        lda #BUNDLE_OK
        rts

; Self-modifying JSL : opcode + 3 bytes addr. Le 4e byte (bank) est
; modifié dynamiquement avant l'appel.
app_exec_call:
        .byte $22                       ; JSL al opcode
        .byte $00                       ; addr lo  ($0200)
        .byte $02                       ; addr hi
app_exec_jsl_bank:
        .byte $00                       ; bank — modifié par app_exec
        rts                             ; retour ici quand l'app fait RTL

; ════════════════════════════════════════════════════════════════════
;  kernel_panic — erreur fatale (Sprint 2.i)
; ════════════════════════════════════════════════════════════════════
;
; Args : A = code panic (8-bit). Stocké dans PANIC_CODE pour inspection.
; Affiche "PANIC <hex>" à l'écran via print_string + print_hex8, puis STP.
; Pré-cond : mode N M=X=1, DBR=0, console initialisée (CURSOR_ADDR
; valide en bank 0 screen RAM).
; ════════════════════════════════════════════════════════════════════
; ── kernel_log_init : vide le log ring buffer ─────────────────────
; Pré-cond : mode N M=X=1, DBR=0. Modifie A.
.export kernel_log_init
kernel_log_init:
        lda #$00
        sta LOG_HEAD
        sta LOG_TAIL
        sta LOG_COUNT
        rts

; ── kernel_log_write : ajoute une entrée (A=code, X=level) ─────────
; Ring circulaire : si plein, écrase l'entrée la plus ancienne.
; Modifie A, X, Y. Pré-cond : mode N M=X=1, DBR=0.
.export kernel_log_write
kernel_log_write:
        sta DP_LOG_TMP          ; sauve code
        txa
        pha                     ; sauve level
        lda LOG_TAIL
        asl a                   ; offset octet = tail × 2
        tax
        pla                     ; A = level
        sta LOG_RING,X          ; ring[tail].level (abs long,X)
        inx
        lda DP_LOG_TMP          ; code
        sta LOG_RING,X          ; ring[tail].code
        ; tail = (tail+1) & mask
        lda LOG_TAIL
        inc a
        and #LOG_MASK
        sta LOG_TAIL
        ; count++ si non plein, sinon head suit tail (drop le plus ancien)
        lda LOG_COUNT
        cmp #LOG_SIZE
        bcs lw_full
        inc a
        sta LOG_COUNT
        rts
lw_full:
        lda LOG_HEAD
        inc a
        and #LOG_MASK
        sta LOG_HEAD
        rts

.export kernel_panic
kernel_panic:
        sta PANIC_CODE
        pha                     ; sauve code (A inchangé par pha)
        ; OS-2.i.v2 : journalise l'événement panic (A=code, X=level).
        ldx #LOG_PANIC
        jsr kernel_log_write
        ; Setup DP_PTR pour panic_msg en bank 1
        lda #$01
        sta DP_PTR+2
        lda #<panic_msg
        sta DP_PTR
        lda #>panic_msg
        sta DP_PTR+1
        jsr kernel_print_string
        pla                     ; restore code
        jsr kernel_print_hex8
        stp
        bra *

panic_msg:
        .byte "PANIC ", $00

; ════════════════════════════════════════════════════════════════════
;  kernel_print_hex8 / kernel_print_nibble (Sprint 2.i)
; ════════════════════════════════════════════════════════════════════
;
; print_hex8 : args A = byte → écrit 2 chars hex via print_char.
; print_nibble : args A 0..15 → écrit 1 char hex.
; Préserve : Y. Modifie : A, X.
; ════════════════════════════════════════════════════════════════════
.export kernel_print_hex8
kernel_print_hex8:
        pha                     ; save byte
        lsr a
        lsr a
        lsr a
        lsr a                   ; high nibble (0..15)
        jsr kernel_print_nibble
        pla                     ; restore
        and #$0F                ; low nibble
        ; tail-call print_nibble (sa rts retourne au caller de print_hex8)

.export kernel_print_nibble
kernel_print_nibble:
        cmp #$0A
        bcc nib_digit
        clc
        adc #$07                ; 'A'-'0'-10 = 7 → 'A'..'F'
nib_digit:
        clc
        adc #'0'
        jmp kernel_print_char   ; tail-call

; ════════════════════════════════════════════════════════════════════
;  kernel_install_charset — copie 1024 oct. fonte $015800 → $00B400
; ════════════════════════════════════════════════════════════════════
;
; Sprint 2.c+ : la ROM Oric 1 historique installe la fonte char en RAM
; bank 0 $B400-$B7FF lors du boot. OricOS boot sans la ROM, donc le
; kernel installe lui-même sa fonte (embedded via .incbin). Sans cela,
; le rendu mode TEXT affiche du noir partout (fonte tout-zéro).
;
; Pré-condition : mode N, M=X=1, DBR=0.
; Modifie : A, X, Y, DBR (=0 après). Préserve P (php/plp).
; OS-perf : copie via MVN (block move 65C816) au lieu d'une boucle
; octet-par-octet (~18K cycles → ~2K). MVN copie C+1 octets de
; src_bank:X vers dst_bank:Y en ascendant ; DBR finit = dst_bank.
; ════════════════════════════════════════════════════════════════════
.export kernel_install_charset
kernel_install_charset:
        rep #$30                     ; A/X/Y 16-bit (requis par MVN)
        lda #CHARSET_SIZE-1          ; C = nb octets - 1 ($03FF)
        ldx #.loword(CHARSET_SRC)    ; X = offset source ($5800, bank 1)
        ldy #.loword(CHARSET_DST)    ; Y = offset dest ($B400, bank 0)
        .byte $54, .bankbyte(CHARSET_DST), .bankbyte(CHARSET_SRC)  ; MVN dst,src
        sep #$30                     ; retour M=X=1 (cohérent .smart ; DBR=dst $00)
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_clear_screen — remplit screen RAM Oric 1 d'espaces (Sprint 2.c)
; ════════════════════════════════════════════════════════════════════
;
; Boucle sur 1120 octets ($BB80-$BFE7) en bank 0. Utilise X 16-bit
; pour parcourir l'espace complet (>256 octets).
;
; ════════════════════════════════════════════════════════════════════
.export kernel_clear_screen
kernel_clear_screen:
        rep #$10                ; X 16-bit
        ldx #$0000
clr_loop:
        cpx #SCREEN_SIZE
        bcs clr_done
        lda #SCREEN_FILL
        sta SCREEN_BASE,X       ; long $lll,X  → $9F opcode
        inx
        bra clr_loop
clr_done:
        sep #$10                ; X 8-bit retour
        rts

; ════════════════════════════════════════════════════════════════════
;  Driver console — print_char + print_string (Sprint 2.e.1)
; ════════════════════════════════════════════════════════════════════
;
; v0.1 minimal :
;   - kernel_print_char (A = char) : gère LF (\n) et char normal
;   - kernel_print_string (DP+$08/$09 = ptr 16-bit en bank 1)
;   - kernel_print_banner réécrit via print_string
;
; OS-2.e.2 : CR (\r) → début de ligne, scroll up (lignes 1..27 → 0..26).
; Non-implémenté (reporté) : attribut couleur par ligne, INKs multiples.
;
; Pré-cond toutes routines : mode N M=X=1, DBR=0.
; ════════════════════════════════════════════════════════════════════

; ─── kernel_console_init : init cursor + INK byte première ligne ───
.export kernel_console_init
kernel_console_init:
        rep #$20
        lda #SCREEN_BASE+1       ; cursor à offset 1 (après attribute byte)
        sta CURSOR_ADDR
        sep #$20
        lda #$01                 ; CURSOR_X = 1 (col 1, après attribute)
        sta CURSOR_X
        ; Écrit attribute byte INK 7 (blanc) à $BB80
        lda #$07
        sta SCREEN_BASE
        rts

; ─── kernel_print_char : args A 8-bit = char ASCII ─────────────────
; Gère LF (\n = $0A) et char normal. Préserve : Y. Modifie : A, X.
.export kernel_print_char
kernel_print_char:
        sta DP_TMP               ; sauve char
        cmp #$0A
        beq pc_lf
        cmp #$0D                 ; CR (\r) → début de ligne courante
        beq pc_cr
        ; Char normal : store at CURSOR_ADDR (bank DBR=0 par défaut)
        ; Setup pointer 16-bit DP_PCPTR ← CURSOR_ADDR ; DBR fournit bank 0.
        rep #$20
        lda CURSOR_ADDR
        sta DP_PCPTR             ; DP+$0C/$0D = low/high (16-bit)
        sep #$20
        lda DP_TMP
        sta (DP_PCPTR)           ; opcode $92 — STA dp indirect, écrit DBR:CURSOR_ADDR
        ; Advance cursor
        rep #$20
        lda CURSOR_ADDR
        inc a
        sta CURSOR_ADDR
        sep #$20
        lda CURSOR_X
        inc a
        sta CURSOR_X
        cmp #SCREEN_COLS         ; 40
        bcc pc_done
        ; CURSOR_X = 40 → reset (CURSOR_ADDR déjà au début ligne suivante)
        lda #$00
        sta CURSOR_X
        bra pc_check_end
pc_lf:
        ; CURSOR_ADDR += (40 - CURSOR_X). CURSOR_X = 0.
        sec
        lda #SCREEN_COLS
        sbc CURSOR_X             ; A = 40 - CURSOR_X (8-bit)
        rep #$20
        and #$00FF               ; zero-extend high
        clc
        adc CURSOR_ADDR
        sta CURSOR_ADDR
        sep #$20
        lda #$00
        sta CURSOR_X
        bra pc_check_end
pc_cr:
        ; CR : CURSOR_ADDR -= CURSOR_X (retour col 0), CURSOR_X = 0.
        lda CURSOR_X
        rep #$20
        and #$00FF               ; CURSOR_X zero-étendu (16-bit)
        sta DP_PCPTR             ; scratch 16-bit
        lda CURSOR_ADDR
        sec
        sbc DP_PCPTR
        sta CURSOR_ADDR
        sep #$20
        lda #$00
        sta CURSOR_X
        bra pc_done              ; CR ne peut pas dépasser le bas d'écran
pc_check_end:
        ; Si CURSOR_ADDR >= SCREEN_END → scroll up d'une ligne (OS-2.e.2).
        rep #$20
        lda CURSOR_ADDR
        cmp #SCREEN_END
        sep #$20
        bcc pc_done
        jsr kernel_scroll_up
        rep #$20
        lda #SCREEN_LAST_ROW     ; curseur sur la dernière ligne (col 0)
        sta CURSOR_ADDR
        sep #$20
        lda #$00
        sta CURSOR_X
pc_done:
        rts

; ─── kernel_scroll_up : scroll écran vers le haut d'une ligne ──────
; Copie lignes 1..27 → 0..26 (40 octets décalage), remplit la dernière
; ligne d'espaces, restaure l'attribut INK 7 en $BB80. La cellule
; ligne0/col0 étant réservée à l'attribut, le car. ligne1/col0 est perdu
; (artefact mineur du modèle console à attribut unique). Modifie A, X.
; Pré-cond : mode N M=X=1, DBR=0.
.export kernel_scroll_up
kernel_scroll_up:
        rep #$10                 ; X 16-bit (compteur > 255)
        ldx #$0000
scrl_copy:
        lda SCREEN_BASE+SCREEN_COLS,X   ; src = ligne+1 (abs long,X)
        sta SCREEN_BASE,X               ; dst = ligne
        inx
        cpx #(SCREEN_END - SCREEN_BASE - SCREEN_COLS)  ; 1080 octets
        bcc scrl_copy
        ; Efface la dernière ligne (40 espaces).
        ldx #$0000
scrl_clear:
        lda #SCREEN_FILL
        sta SCREEN_LAST_ROW,X
        inx
        cpx #SCREEN_COLS
        bcc scrl_clear
        sep #$10                 ; X repasse en 8-bit
        ; Restaure l'attribut INK 7 en tête d'écran.
        lda #$07
        sta SCREEN_BASE
        rts

; ─── kernel_print_string : args DP+$08/$09 = ptr 16-bit en bank 1 ──
; String null-terminée. Préserve : X. Modifie : A, Y.
.export kernel_print_string
kernel_print_string:
        ldy #$00
ps_loop:
        lda [DP_PTR],Y           ; opcode $B7 — DP indirect long Y
        beq ps_done
        jsr kernel_print_char
        iny
        bra ps_loop
ps_done:
        rts

; ─── kernel_print_banner : utilise print_string ────────────────────
.export kernel_print_banner
kernel_print_banner:
        ; Setup DP_PTR (24-bit long indirect) → banner_str en bank 1
        lda #$01
        sta DP_PTR+2             ; DP+$0A = bank 1
        lda #<banner_str
        sta DP_PTR
        lda #>banner_str
        sta DP_PTR+1
        jsr kernel_print_string
        rts

banner_str:
        .byte "OricOS B3 Demo", $0A
        .byte "CPU : 65C816 MODE N", $0A
        .byte "MEM : 256KiB (BK0-3)", $0A, $00
str_b3_guest_in:
        .byte "GUEST: MODE E RUN...", $0A, $00
str_b3_guest_out:
        .byte "GUEST: BACK N OK", $0A, $00

; ─── Bundle hello (Sprint 2.m.1) ────────────────────────────────────
; Première app standalone OricOS, source asm dans `apps/hello/hello.s`,
; buildée par ld65 + tool oricos-bundle.py → format .oosobj.
; Embarquée ici via .incbin pour démontrer le pipeline build d'apps
; externes au kernel.
.export bundle_test
bundle_test:
        .incbin "../apps/hello/build/hello.oosobj"

; ════════════════════════════════════════════════════════════════════
;  Driver clavier (Sprint 2.d)
; ════════════════════════════════════════════════════════════════════
;
; ── psg_set_reg : sélectionne registre PSG (A = numéro reg) ─────────
psg_set_reg:
        sta VIA_ORA
        lda #PCR_LATCH_ADDR
        sta VIA_PCR
        lda #PCR_INACTIVE
        sta VIA_PCR
        rts

; ── psg_write_data : écrit data au registre sélectionné (A = val) ──
psg_write_data:
        sta VIA_ORA
        lda #PCR_WRITE_DATA
        sta VIA_PCR
        lda #PCR_INACTIVE
        sta VIA_PCR
        rts

; ── psg_read_data : lit data du registre sélectionné (retour A) ────
psg_read_data:
        lda #PCR_READ_DATA
        sta VIA_PCR
        lda VIA_ORA              ; IRA reflète le PSG en mode read
        pha
        lda #PCR_INACTIVE
        sta VIA_PCR
        pla
        rts

; ── kernel_kbd_init : init driver clavier Oric 2 (ADR-22) ──────────
; Pré-cond : mode N M=X=1, DBR=0. Vide le ring + active l'IRQ KBD2.
; Le scan matriciel Oric 1 est remplacé par la FIFO IRQ-driven du
; contrôleur KBD2 (la keymap est faite côté contrôleur, plus dans le kernel).
.export kernel_kbd_init
kernel_kbd_init:
        ; Ring buffer vide.
        lda #$00
        sta KBD_RING_HEAD
        sta KBD_RING_TAIL
        sta KBD_RING_COUNT
        sta KBD_GETKEY_RES
        ; Active l'IRQ du contrôleur KBD2 (FIFO non vide → IRQ).
        lda #KBD2_CT_IRQ_EN
        sta KBD2_CTRL
        rts

; ── kernel_kbd_poll : draine la FIFO KBD2 → ring buffer ────────────
; Appelé par l'IRQ handler à chaque tick (et lisible directement).
; Lit KBD2_DATA tant que data_ready, push chaque keycode dans le ring.
; Vider la FIFO déasserte l'IRQ KBD2 (level-triggered). Modifie A, X. Préserve Y.
.export kernel_kbd_poll
kernel_kbd_poll:
kpoll_loop:
        lda KBD2_STATUS
        and #KBD2_ST_READY
        beq kpoll_done           ; FIFO vide → terminé
        lda KBD2_DATA            ; pop keycode ASCII
        jsr kernel_kbd_ring_push
        bra kpoll_loop
kpoll_done:
        rts

; ── kernel_kbd_ring_push : push A (keycode) dans le ring ───────────
; Drop silencieux si plein (16). Modifie A, X. Préserve Y.
; NB : LDX/INC/DEC n'ont pas de mode absolu long sur 65C816 → on passe
; par LDA (abs long) + A pour les variables ring en bank 1.
kernel_kbd_ring_push:
        sta DP_KBD_TMP           ; sauve keycode
        lda KBD_RING_COUNT
        cmp #KBD_RING_SIZE
        bcs kpush_full           ; plein → drop
        lda KBD_RING_TAIL
        tax
        lda DP_KBD_TMP           ; A = keycode
        sta KBD_RING,X           ; store au tail (abs long,X = $9F)
        lda KBD_RING_TAIL
        inc a
        and #KBD_RING_MASK       ; wrap 16
        sta KBD_RING_TAIL
        lda KBD_RING_COUNT
        inc a
        sta KBD_RING_COUNT
kpush_full:
        rts

; ── kernel_kbd_ring_pop : pop → A = keycode, ou A=$00 si vide ──────
; Modifie A, X. Préserve Y. Convention ADR-17 SYS_GET_KEY (A=keycode/0).
.export kernel_kbd_ring_pop
kernel_kbd_ring_pop:
        lda KBD_RING_COUNT
        beq kpop_empty
        lda KBD_RING_HEAD
        tax
        lda KBD_RING,X           ; A = keycode
        sta DP_KBD_TMP           ; sauve keycode
        lda KBD_RING_HEAD
        inc a
        and #KBD_RING_MASK
        sta KBD_RING_HEAD
        lda KBD_RING_COUNT
        dec a
        sta KBD_RING_COUNT
        lda DP_KBD_TMP           ; A = keycode
        rts
kpop_empty:
        lda #$00
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_alloc_bank / kernel_free_bank (Sprint 2.b/2.h)
; ════════════════════════════════════════════════════════════════════
;
; alloc : pop free list si non vide, sinon bump BANK_NEXT.
; free  : push sur free list (drop silencieux si pleine).
;
; Convention :
;   alloc : retourne A = bank num, ou 0 si épuisé.
;   free  : A = bank num à libérer. Préserve X, Y.
;
; Pré-conditions : appelé en mode N M=X=1, DBR=0.
; ════════════════════════════════════════════════════════════════════
.export kernel_alloc_bank
kernel_alloc_bank:
        ; Try free list first (LIFO pop)
        lda BANK_FREE_TOP
        beq alloc_bump          ; vide → bump
        dec a
        sta BANK_FREE_TOP
        tax
        lda BANK_FREE_LIST,X    ; A = bank libéré
        rts
alloc_bump:
        lda BANK_NEXT
        cmp #BANK_POOL_END
        bcs alloc_none
        pha                     ; sauve valeur à retourner
        inc a
        sta BANK_NEXT
        pla
        rts
alloc_none:
        ; OS-2.i.v2 : journalise l'épuisement du pool de banks.
        lda #ERR_BANK_EXHAUSTED
        ldx #LOG_ERROR
        jsr kernel_log_write
        lda #$00                ; pool épuisé (convention retour)
        rts

.export kernel_free_bank
kernel_free_bank:
        ; A = bank à libérer. Push sur free list si possible.
        pha                     ; sauve bank num
        lda BANK_FREE_TOP
        cmp #$10                ; full ?
        bcs free_drop
        tax
        pla                     ; A = bank num
        sta BANK_FREE_LIST,X    ; push at TOP
        inx
        txa
        sta BANK_FREE_TOP       ; TOP++
        rts
free_drop:
        pla                     ; pop sauve
        rts                     ; silently drop si plein

; ════════════════════════════════════════════════════════════════════
;  kernel_alloc_live_bank / kernel_free_live_bank (Sprint VRAM-3, ADR-19)
; ════════════════════════════════════════════════════════════════════
;
; Pool LIVE : banks 129-159 (BRAM ECP5 selon ADR-19). Bank 128
; réservé au framebuffer principal HIRES Oric 2 (ADR-12).
;
; Convention identique au pool système :
;   alloc_live : retourne A = bank num (129..159), ou 0 si épuisé.
;   free_live  : A = bank num à libérer. Préserve X, Y.
;
; Pré-conditions : appelé en mode N M=X=1, DBR=0.
; ════════════════════════════════════════════════════════════════════
.export kernel_alloc_live_bank
kernel_alloc_live_bank:
        ; Try free list first (LIFO pop)
        lda BANK_LIVE_FREE_TOP
        beq alloc_live_bump
        dec a
        sta BANK_LIVE_FREE_TOP
        tax
        lda BANK_LIVE_FREE_LIST,X
        rts
alloc_live_bump:
        lda BANK_LIVE_NEXT
        cmp #BANK_LIVE_POOL_END
        bcs alloc_live_none
        pha
        inc a
        sta BANK_LIVE_NEXT
        pla
        rts
alloc_live_none:
        lda #$00                ; pool épuisé
        rts

.export kernel_free_live_bank
kernel_free_live_bank:
        pha                     ; sauve bank num
        lda BANK_LIVE_FREE_TOP
        cmp #$10                ; full ?
        bcs free_live_drop
        tax
        pla
        sta BANK_LIVE_FREE_LIST,X
        inx
        txa
        sta BANK_LIVE_FREE_TOP
        rts
free_live_drop:
        pla
        rts

; ─── task_a_entry : boucle qui incrémente TASK_A_CTR ────────────────
.export task_a_entry
task_a_entry:
        lda TASK_A_CTR
        inc a                   ; INC A 65C816
        sta TASK_A_CTR
        bra task_a_entry

; ─── task_b_entry : boucle qui incrémente TASK_B_CTR ────────────────
.export task_b_entry
task_b_entry:
        lda TASK_B_CTR
        inc a
        sta TASK_B_CTR
        bra task_b_entry

; kernel_hires2_clear et pattern_table retirés en PH-cleanup-zombie
; (2026-05-09). Code legacy ADR-19 v2, plus visible côté compositor.
; Rendu desktop = GPU blitter (ADR-21) via kernel_gfx_*.

; Source pour test write_block (Sprint VRAM-2 boot kernel).
vram_test_str:
        .byte 'V', 'R', 'A', 'M'

; ─── Mini-fonte 8×8 pour Sprint GPU-3 v0.3 (chars 'O' et 'S') ─────
mini_font_O:
        .byte $7E       ; 01111110
        .byte $E7       ; 11100111
        .byte $C3       ; 11000011
        .byte $C3       ; 11000011
        .byte $C3       ; 11000011
        .byte $E7       ; 11100111
        .byte $7E       ; 01111110
        .byte $00       ; 00000000

mini_font_S:
        .byte $7E       ; 01111110
        .byte $C0       ; 11000000
        .byte $E0       ; 11100000
        .byte $7E       ; 01111110
        .byte $07       ; 00000111
        .byte $03       ; 00000011
        .byte $7E       ; 01111110
        .byte $00       ; 00000000

mini_text_OS:
        .byte 'O', 'S', $00

; SP-3.d : chaînes démo toolkit (bank 1, ASCII null-term).
tk_demo_label:
        .byte "OricOS Toolkit", $00
tk_demo_ok:
        .byte "OK", $00
tk_demo_os:
        .byte "OricOS", $00

; kernel_fill_rect_aligned retiré en PH-cleanup-zombie (2026-05-09).
; Code legacy ADR-19 v2 (écrivait bank $80, plus visible compositor).
; Rendu rectangles = SYS_GFX_FILL_RECT (ADR-17/21) via GPU blitter.

; ════════════════════════════════════════════════════════════════════
;  kernel_vram_write_block — RAM banking → VRAM cold (Sprint VRAM-2)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP_PCPTR (24-bit) = source en RAM banking.
;        VRAM_OP_ADDR_LO/MID/HI ($60-$62) = destination SDRAM 24-bit.
;        VRAM_OP_LEN_LO/HI ($63-$64) = nombre d'octets (16-bit, 1..65535
;        ; len=0 → no-op, contrairement au DMA qui interprète 0=64K).
; Effets : copie len octets via I/O port VRAM_DATA (auto-inc côté HW).
; Modifie : A, X, Y, $63 (write 0). Préserve DP_PCPTR.
; Pré-cond : mode N M=1 X=1, DBR=0, vram_device présent.
;
; Latence : ~10 cycles/byte. Pour transferts massifs, kernel_vram_dma
; est ~10× plus rapide (DMA HW v0.1 synchrone "instantané" simulé).
; ════════════════════════════════════════════════════════════════════
.export kernel_vram_write_block
kernel_vram_write_block:
        ; Set VRAM_ADDR via I/O ports (long absolute writes).
        lda VRAM_OP_ADDR_LO
        sta VRAM_ADDR_LO_IO
        lda VRAM_OP_ADDR_MID
        sta VRAM_ADDR_MID_IO
        lda VRAM_OP_ADDR_HI
        sta VRAM_ADDR_HI_IO
        ; Loop : Y 16-bit pour offset.
        rep #$10
        ldy #$0000
vwb_loop:
        cpy VRAM_OP_LEN_LO              ; cpy zp en X=0 lit 16-bit $63-$64
        bcs vwb_done
        lda [DP_PCPTR],Y
        sta VRAM_DATA_IO
        iny
        bra vwb_loop
vwb_done:
        sep #$10
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_vram_read_block — VRAM cold → RAM banking (Sprint VRAM-2)
; ════════════════════════════════════════════════════════════════════
;
; Args : VRAM_OP_ADDR_LO/MID/HI = source SDRAM 24-bit.
;        DP_PCPTR (24-bit) = destination en RAM banking.
;        VRAM_OP_LEN_LO/HI = nombre d'octets.
; Effets : lit len octets via I/O port VRAM_DATA (auto-inc).
; ════════════════════════════════════════════════════════════════════
.export kernel_vram_read_block
kernel_vram_read_block:
        lda VRAM_OP_ADDR_LO
        sta VRAM_ADDR_LO_IO
        lda VRAM_OP_ADDR_MID
        sta VRAM_ADDR_MID_IO
        lda VRAM_OP_ADDR_HI
        sta VRAM_ADDR_HI_IO
        rep #$10
        ldy #$0000
vrb_loop:
        cpy VRAM_OP_LEN_LO
        bcs vrb_done
        lda VRAM_DATA_IO
        sta [DP_PCPTR],Y
        iny
        bra vrb_loop
vrb_done:
        sep #$10
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_vram_dma — DMA HW SDRAM↔bank (Sprint VRAM-2)
; ════════════════════════════════════════════════════════════════════
;
; Args ZP :
;   VRAM_DMA_SRC_LO/MID/HI ($65-$67) = adresse source 24-bit.
;   VRAM_DMA_DST_LO/MID/HI ($68-$6A) = adresse destination 24-bit.
;   VRAM_DMA_LEN_LO/HI     ($6B-$6C) = longueur 16-bit (LEN=0 → 65536).
;   VRAM_DMA_DIR_ZP        ($6D)     = $00 (SDRAM→bank) ou $02 (bank→SDRAM).
; Effets : trigger DMA HW. v0.1 synchrone (instantané), busy=0 immédiat.
; Pré-cond : mode N M=1 X=1, DBR=0.
; ════════════════════════════════════════════════════════════════════
.export kernel_vram_dma
kernel_vram_dma:
        ; Setup DMA registers via I/O ports.
        lda VRAM_DMA_SRC_LO_ZP
        sta VRAM_DMA_SRC_LO_IO
        lda VRAM_DMA_SRC_MID_ZP
        sta VRAM_DMA_SRC_MID_IO
        lda VRAM_DMA_SRC_HI_ZP
        sta VRAM_DMA_SRC_HI_IO
        lda VRAM_DMA_DST_LO_ZP
        sta VRAM_DMA_DST_LO_IO
        lda VRAM_DMA_DST_MID_ZP
        sta VRAM_DMA_DST_MID_IO
        lda VRAM_DMA_DST_HI_ZP
        sta VRAM_DMA_DST_HI_IO
        lda VRAM_DMA_LEN_LO_ZP
        sta VRAM_DMA_LEN_LO_IO
        lda VRAM_DMA_LEN_HI_ZP
        sta VRAM_DMA_LEN_HI_IO
        ; Trigger : DIR | TRIG bit.
        lda VRAM_DMA_DIR_ZP
        ora #VRAM_DMA_TRIG
        sta VRAM_DMA_CTRL_IO
        ; Wait busy clear avec timeout 256 polls (robustesse : si
        ; vram_device absent ou stuck, ne bloque pas indéfiniment).
        ldx #$00
vdma_wait:
        lda VRAM_DMA_CTRL_IO
        and #VRAM_DMA_BUSY
        beq vdma_done
        inx
        bne vdma_wait
vdma_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_clear — exec GPU CLEAR via I/O (Sprint GPU-3, ADR-21)
; ════════════════════════════════════════════════════════════════════
;
; Args ZP :
;   GFX_BASE_LO/MID/HI ($70-$72) = base SDRAM 24-bit (offset).
;   GFX_ARG2_LO/MID/HI ($73-$75) = size 24-bit (octets).
;   GFX_COLOR ($78)              = couleur (0..15).
; Effets : remplit `size` octets en SDRAM[base] avec pattern
;          (color << 4) | color (= 2 pixels même couleur par byte).
;          v0.1 synchrone : poll busy avec timeout 256.
; Modifie : A, X. Préserve : Y.
; Pré-cond : mode N M=1 X=1, DBR=0, gpu_device présent.
; ════════════════════════════════════════════════════════════════════
.export kernel_gfx_clear
kernel_gfx_clear:
        ; ARG1 = base
        lda GFX_BASE_LO
        sta GPU_ARG1_LO_IO
        lda GFX_BASE_MID
        sta GPU_ARG1_MID_IO
        lda GFX_BASE_HI
        sta GPU_ARG1_HI_IO
        ; ARG2 = size
        lda GFX_ARG2_LO
        sta GPU_ARG2_LO_IO
        lda GFX_ARG2_MID
        sta GPU_ARG2_MID_IO
        lda GFX_ARG2_HI
        sta GPU_ARG2_HI_IO
        ; ARG3.LO = color
        lda GFX_COLOR
        sta GPU_ARG3_LO_IO
        ; CMD_OP = CLEAR
        lda #GPU_OP_CLEAR
        sta GPU_CMD_OP_IO
        ; Trigger
        sta GPU_TRIGGER_IO
        ; Poll busy (timeout 256 itérations)
        ldx #$00
gfx_clear_wait:
        lda GPU_STATUS_IO
        and #GPU_STATUS_BUSY
        beq gfx_clear_done
        inx
        bne gfx_clear_wait
gfx_clear_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_fill_rect — exec GPU FILL_RECT via I/O (Sprint GPU-3)
; ════════════════════════════════════════════════════════════════════
;
; Args ZP :
;   GFX_BASE_LO/MID/HI ($70-$72) = base SDRAM 24-bit du framebuffer.
;   GFX_ARG2_LO        ($73)     = x (8-bit, 0..255).
;   GFX_ARG2_MID       ($74)     = y (8-bit, 0..255).
;   GFX_ARG3_LO        ($76)     = w (8-bit).
;   GFX_ARG3_MID       ($77)     = h (8-bit).
;   GFX_COLOR          ($78)     = couleur (0..15).
; Effets : remplit le rectangle [x..x+w-1] × [y..y+h-1] dans le
;          framebuffer avec pixel = color. BPL hardcodé GPU côté HW
;          (= 512 pour XVGA 1024×768×4bpp ADR-20 v3).
;          v0.1 synchrone : poll busy avec timeout 256.
; Modifie : A, X. Préserve : Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_gfx_fill_rect
kernel_gfx_fill_rect:
        ; ARG1 = base
        lda GFX_BASE_LO
        sta GPU_ARG1_LO_IO
        lda GFX_BASE_MID
        sta GPU_ARG1_MID_IO
        lda GFX_BASE_HI
        sta GPU_ARG1_HI_IO
        ; ARG2.LO = x, ARG2.MID = y
        lda GFX_ARG2_LO
        sta GPU_ARG2_LO_IO
        lda GFX_ARG2_MID
        sta GPU_ARG2_MID_IO
        lda #$00
        sta GPU_ARG2_HI_IO
        ; ARG3.LO = w, ARG3.MID = h
        lda GFX_ARG3_LO
        sta GPU_ARG3_LO_IO
        lda GFX_ARG3_MID
        sta GPU_ARG3_MID_IO
        lda #$00
        sta GPU_ARG3_HI_IO
        ; ARG4.LO = color
        lda GFX_COLOR
        sta GPU_ARG4_LO_IO
        ; CMD_OP = FILL_RECT
        lda #GPU_OP_FILL_RECT
        sta GPU_CMD_OP_IO
        ; Trigger
        sta GPU_TRIGGER_IO
        ; Poll busy (timeout 256)
        ldx #$00
gfx_fill_wait:
        lda GPU_STATUS_IO
        and #GPU_STATUS_BUSY
        beq gfx_fill_done
        inx
        bne gfx_fill_wait
gfx_fill_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_blit — exec GPU BLIT via I/O (Sprint GPU-3 v0.2)
; ════════════════════════════════════════════════════════════════════
;
; Args ZP (sémantique pour BLIT) :
;   GFX_BASE_LO/MID/HI ($70-$72) = src 24-bit (SDRAM source).
;   GFX_ARG2_LO/MID/HI ($73-$75) = dst 24-bit (SDRAM destination).
;   GFX_ARG3_LO        ($76)     = byte_w (octets/ligne, 1..255).
;   GFX_ARG3_MID       ($77)     = byte_h (lignes, 1..255).
; Effets : copie un bloc rectangulaire src → dst dans la SDRAM.
;          v0.1 limites HW : src/dst byte-alignés, pas d'overlap, pas
;          de transparency. BPL hardcodé GPU=512 (XVGA).
;          v0.1 sync : poll busy timeout 256.
; Modifie : A, X. Préserve : Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_gfx_blit
kernel_gfx_blit:
        ; ARG1 = src (= GFX_BASE)
        lda GFX_BASE_LO
        sta GPU_ARG1_LO_IO
        lda GFX_BASE_MID
        sta GPU_ARG1_MID_IO
        lda GFX_BASE_HI
        sta GPU_ARG1_HI_IO
        ; ARG2 = dst (= GFX_ARG2)
        lda GFX_ARG2_LO
        sta GPU_ARG2_LO_IO
        lda GFX_ARG2_MID
        sta GPU_ARG2_MID_IO
        lda GFX_ARG2_HI
        sta GPU_ARG2_HI_IO
        ; ARG3.LO = byte_w, ARG3.MID = byte_h
        lda GFX_ARG3_LO
        sta GPU_ARG3_LO_IO
        lda GFX_ARG3_MID
        sta GPU_ARG3_MID_IO
        lda #$00
        sta GPU_ARG3_HI_IO
        ; CMD_OP = BLIT, trigger
        lda #GPU_OP_BLIT
        sta GPU_CMD_OP_IO
        sta GPU_TRIGGER_IO
        ldx #$00
gfx_blit_wait:
        lda GPU_STATUS_IO
        and #GPU_STATUS_BUSY
        beq gfx_blit_done
        inx
        bne gfx_blit_wait
gfx_blit_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_line — exec GPU LINE Bresenham via I/O (Sprint GPU-3 v0.2)
; ════════════════════════════════════════════════════════════════════
;
; Args ZP (sémantique pour LINE) :
;   GFX_BASE_LO/MID/HI ($70-$72) = base SDRAM framebuffer.
;   GFX_ARG2_LO        ($73)     = x1 (8-bit).
;   GFX_ARG2_MID       ($74)     = y1 (8-bit).
;   GFX_ARG3_LO        ($76)     = x2 (8-bit).
;   GFX_ARG3_MID       ($77)     = y2 (8-bit).
;   GFX_COLOR          ($78)     = couleur (4-bit, 0..15).
; Effets : trace une ligne Bresenham 4bpp de (x1,y1) à (x2,y2).
;          BPL hardcodé GPU=512 (XVGA).
; Modifie : A, X. Préserve : Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_gfx_line
kernel_gfx_line:
        ; ARG1 = base
        lda GFX_BASE_LO
        sta GPU_ARG1_LO_IO
        lda GFX_BASE_MID
        sta GPU_ARG1_MID_IO
        lda GFX_BASE_HI
        sta GPU_ARG1_HI_IO
        ; ARG2.LO = x1, ARG2.MID = y1
        lda GFX_ARG2_LO
        sta GPU_ARG2_LO_IO
        lda GFX_ARG2_MID
        sta GPU_ARG2_MID_IO
        lda #$00
        sta GPU_ARG2_HI_IO
        ; ARG3.LO = x2, ARG3.MID = y2
        lda GFX_ARG3_LO
        sta GPU_ARG3_LO_IO
        lda GFX_ARG3_MID
        sta GPU_ARG3_MID_IO
        lda #$00
        sta GPU_ARG3_HI_IO
        ; ARG4.LO = color
        lda GFX_COLOR
        sta GPU_ARG4_LO_IO
        ; CMD_OP = LINE, trigger
        lda #GPU_OP_LINE
        sta GPU_CMD_OP_IO
        sta GPU_TRIGGER_IO
        ldx #$00
gfx_line_wait:
        lda GPU_STATUS_IO
        and #GPU_STATUS_BUSY
        beq gfx_line_done
        inx
        bne gfx_line_wait
gfx_line_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_text — exec GPU TEXT via I/O (Sprint GPU-3 v0.3)
; ════════════════════════════════════════════════════════════════════
;
; Args ZP :
;   GFX_BASE_LO/MID/HI ($70-$72) = base SDRAM framebuffer.
;   GFX_FONT_LO/MID/HI ($79-$7B) = font_addr 24-bit (256 chars × 8B).
;   GFX_STR_LO/MID/HI  ($7C-$7E) = string_addr 24-bit (null-term).
;   GFX_ARG2_LO        ($73)     = x (8-bit).
;   GFX_ARG2_MID       ($74)     = y (8-bit).
;   GFX_COLOR          ($78)     = couleur fg (4-bit).
; Effets : rendu fonte 8×8 monochrome via GPU TEXT. Pixels OFF du
;          bitmap = laissés intacts (pas de color_bg en v0.1).
;          Max 255 caractères.
; Modifie : A, X. Préserve : Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_gfx_text
kernel_gfx_text:
        ; ARG1 = base
        lda GFX_BASE_LO
        sta GPU_ARG1_LO_IO
        lda GFX_BASE_MID
        sta GPU_ARG1_MID_IO
        lda GFX_BASE_HI
        sta GPU_ARG1_HI_IO
        ; ARG2 = font_addr
        lda GFX_FONT_LO
        sta GPU_ARG2_LO_IO
        lda GFX_FONT_MID
        sta GPU_ARG2_MID_IO
        lda GFX_FONT_HI
        sta GPU_ARG2_HI_IO
        ; ARG3 = string_addr
        lda GFX_STR_LO
        sta GPU_ARG3_LO_IO
        lda GFX_STR_MID
        sta GPU_ARG3_MID_IO
        lda GFX_STR_HI
        sta GPU_ARG3_HI_IO
        ; ARG4.LO = x, .MID = y, .HI = color
        lda GFX_ARG2_LO
        sta GPU_ARG4_LO_IO
        lda GFX_ARG2_MID
        sta GPU_ARG4_MID_IO
        lda GFX_COLOR
        sta GPU_ARG4_HI_IO
        ; CMD_OP = TEXT, trigger
        lda #GPU_OP_TEXT
        sta GPU_CMD_OP_IO
        sta GPU_TRIGGER_IO
        ldx #$00
gfx_text_wait:
        lda GPU_STATUS_IO
        and #GPU_STATUS_BUSY
        beq gfx_text_done
        inx
        bne gfx_text_wait
gfx_text_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  SP-3.d — Toolkit minimal (label / frame / button) sur XVGA
; ════════════════════════════════════════════════════════════════════

; ── kernel_tk_font_init : upload la fonte ASCII (CHARSET_SRC, 1024 o) en
;    SDRAM TK_FONT_ADDR pour le GPU TEXT/TEXT16. Appelé une fois au boot.
.export kernel_tk_font_init
kernel_tk_font_init:
        lda #<CHARSET_SRC
        sta DP_PCPTR
        lda #>CHARSET_SRC
        sta DP_PCPTR+1
        lda #^CHARSET_SRC
        sta DP_PCPTR+2
        lda #<TK_FONT_ADDR
        sta VRAM_OP_ADDR_LO
        lda #>TK_FONT_ADDR
        sta VRAM_OP_ADDR_MID
        lda #^TK_FONT_ADDR
        sta VRAM_OP_ADDR_HI
        lda #$00
        sta VRAM_OP_LEN_LO
        lda #$04                 ; LEN = $0400 = 1024
        sta VRAM_OP_LEN_HI
        jsr kernel_vram_write_block
        rts

; ── kernel_gfx_text16 : GPU TEXT coords 16-bit (ADR-21, SP-3.d) ────────
; Args : GFX_BASE/FONT/STR (24-bit SDRAM), WM_ARG_X/Y (16-bit ≤1023),
;        GFX_COLOR (4-bit). ARG4 packé = color<<20 | y<<10 | x. Modifie A.
.export kernel_gfx_text16
kernel_gfx_text16:
        lda GFX_BASE_LO
        sta GPU_ARG1_LO_IO
        lda GFX_BASE_MID
        sta GPU_ARG1_MID_IO
        lda GFX_BASE_HI
        sta GPU_ARG1_HI_IO
        lda GFX_FONT_LO
        sta GPU_ARG2_LO_IO
        lda GFX_FONT_MID
        sta GPU_ARG2_MID_IO
        lda GFX_FONT_HI
        sta GPU_ARG2_HI_IO
        lda GFX_STR_LO
        sta GPU_ARG3_LO_IO
        lda GFX_STR_MID
        sta GPU_ARG3_MID_IO
        lda GFX_STR_HI
        sta GPU_ARG3_HI_IO
        ; ARG4_LO = x[7:0]
        lda WM_ARG_X
        sta GPU_ARG4_LO_IO
        ; ARG4_MID = (y[5:0]<<2) | x[9:8]
        lda WM_ARG_X+1
        and #$03
        sta DP_TMP
        lda WM_ARG_Y
        asl a
        asl a
        ora DP_TMP
        sta GPU_ARG4_MID_IO
        ; ARG4_HI = (color<<4) | y[9:6]
        lda WM_ARG_Y             ; y[7:0] >> 6 → bits0,1 = y[6],y[7]
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a
        sta DP_TMP
        lda WM_ARG_Y+1          ; y[9:8] → <<2 = bits2,3
        and #$03
        asl a
        asl a
        ora DP_TMP              ; y[9:6]
        sta DP_TMP
        lda GFX_COLOR
        asl a
        asl a
        asl a
        asl a                   ; color<<4
        ora DP_TMP
        sta GPU_ARG4_HI_IO
        lda #GPU_OP_TEXT16
        sta GPU_CMD_OP_IO
        sta GPU_TRIGGER_IO
        ldx #$00
gfx_t16_wait:
        lda GPU_STATUS_IO
        and #GPU_STATUS_BUSY
        beq gfx_t16_done
        inx
        bne gfx_t16_wait
gfx_t16_done:
        rts

; ── _tk_upload_str : copie la chaîne null-term [DP_PCPTR] (bank1) → SDRAM
;    TK_STR_SCRATCH via VRAM_DATA (auto-inc). Garde-fou 255 octets. ─────
_tk_upload_str:
        lda #<TK_STR_SCRATCH
        sta VRAM_ADDR_LO_IO
        lda #>TK_STR_SCRATCH
        sta VRAM_ADDR_MID_IO
        lda #^TK_STR_SCRATCH
        sta VRAM_ADDR_HI_IO
        rep #$10
        ldy #$0000
_tus_loop:
        lda [DP_PCPTR],Y
        sta VRAM_DATA_IO         ; écrit l'octet (null inclus) + auto-inc
        beq _tus_done            ; Z = octet lu == 0 → terminateur écrit
        iny
        cpy #$00FF
        bcc _tus_loop
        lda #$00                 ; garde-fou : force terminateur
        sta VRAM_DATA_IO
_tus_done:
        sep #$10
        rts

; ── kernel_tk_label : texte à (WM_ARG_X,Y), GFX_COLOR, chaîne [DP_PCPTR]
;    (bank1, null-term). Base framebuffer = $100000. Modifie A,X,Y.
.export kernel_tk_label
kernel_tk_label:
        jsr _tk_upload_str
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #<TK_FONT_ADDR
        sta GFX_FONT_LO
        lda #>TK_FONT_ADDR
        sta GFX_FONT_MID
        lda #^TK_FONT_ADDR
        sta GFX_FONT_HI
        lda #<TK_STR_SCRATCH
        sta GFX_STR_LO
        lda #>TK_STR_SCRATCH
        sta GFX_STR_MID
        lda #^TK_STR_SCRATCH
        sta GFX_STR_HI
        jsr kernel_gfx_text16
        rts

; ── kernel_tk_frame : cadre 2px autour de (WM_ARG_X/Y/W/H), GFX_COLOR. ─
; Base = $100000. Modifie A,X,Y + TKF_*.
.export kernel_tk_frame
kernel_tk_frame:
        rep #$20
        lda WM_ARG_X
        sta TKF_X
        lda WM_ARG_Y
        sta TKF_Y
        lda WM_ARG_W
        sta TKF_W
        lda WM_ARG_H
        sta TKF_H
        sep #$20
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        ; bord haut : (x, y, w, 2)
        rep #$20
        lda TKF_X
        sta WM_ARG_X
        lda TKF_Y
        sta WM_ARG_Y
        lda TKF_W
        sta WM_ARG_W
        lda #2
        sta WM_ARG_H
        sep #$20
        jsr kernel_gfx_fill_rect16
        ; bord bas : (x, y+h-2, w, 2)
        rep #$20
        lda TKF_X
        sta WM_ARG_X
        lda TKF_Y
        clc
        adc TKF_H
        sec
        sbc #2
        sta WM_ARG_Y
        lda TKF_W
        sta WM_ARG_W
        lda #2
        sta WM_ARG_H
        sep #$20
        jsr kernel_gfx_fill_rect16
        ; bord gauche : (x, y, 2, h)
        rep #$20
        lda TKF_X
        sta WM_ARG_X
        lda TKF_Y
        sta WM_ARG_Y
        lda #2
        sta WM_ARG_W
        lda TKF_H
        sta WM_ARG_H
        sep #$20
        jsr kernel_gfx_fill_rect16
        ; bord droit : (x+w-2, y, 2, h)
        rep #$20
        lda TKF_X
        clc
        adc TKF_W
        sec
        sbc #2
        sta WM_ARG_X
        lda TKF_Y
        sta WM_ARG_Y
        lda #2
        sta WM_ARG_W
        lda TKF_H
        sta WM_ARG_H
        sep #$20
        jsr kernel_gfx_fill_rect16
        rts

; ── kernel_tk_button : bouton (face + cadre + label centré gauche) ─────
; Args : WM_ARG_X/Y/W/H, chaîne [DP_PCPTR] (bank1). Modifie A,X,Y,TK_*,TKF_*.
.export kernel_tk_button
kernel_tk_button:
        rep #$20
        lda WM_ARG_X
        sta TK_X
        lda WM_ARG_Y
        sta TK_Y
        lda WM_ARG_W
        sta TK_W
        lda WM_ARG_H
        sta TK_H
        sep #$20
        ; 1. face lightgray (WM_ARG_* = rect du bouton, encore en place)
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        ; v0.3 : face selon état pressé.
        lda TK_BTN_PRESSED
        beq _tkb_face_normal
        lda #TK_COL_BTN_PRESS
        bra _tkb_face_set
_tkb_face_normal:
        lda #TK_COL_BTN_FACE
_tkb_face_set:
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; 2. cadre blanc
        rep #$20
        lda TK_X
        sta WM_ARG_X
        lda TK_Y
        sta WM_ARG_Y
        lda TK_W
        sta WM_ARG_W
        lda TK_H
        sta WM_ARG_H
        sep #$20
        lda #TK_COL_BORDER
        sta GFX_COLOR
        jsr kernel_tk_frame
        ; 3. label noir à (x+4, y+2) — DP_PCPTR inchangé depuis l'appel.
        rep #$20
        lda TK_X
        clc
        adc #4
        sta WM_ARG_X
        lda TK_Y
        clc
        adc #2
        sta WM_ARG_Y
        sep #$20
        lda #TK_COL_BTN_TEXT
        sta GFX_COLOR
        jsr kernel_tk_label
        rts

; ── kernel_wm_add_widget : enregistre un widget managé (SP-3.d v0.2) ───
; Args : WG_PARENT (id fenêtre), WG_TYPE (0=label,1=button),
;        WM_ARG_X/Y/W/H (rect RELATIF à la fenêtre), GFX_COLOR (label),
;        DP_PCPTR lo/hi (offset chaîne bank1). Append à WIDGET_COUNT.
.export kernel_wm_add_widget
kernel_wm_add_widget:
        lda WIDGET_COUNT
        cmp #WIDGET_MAX
        bcs _waw_full
        asl a
        asl a
        asl a
        asl a                    ; offset = COUNT*16
        tax
        lda #$01
        sta WIDGET_TABLE+0,X
        lda WG_PARENT
        sta WIDGET_TABLE+1,X
        lda WG_TYPE
        sta WIDGET_TABLE+2,X
        lda GFX_COLOR
        sta WIDGET_TABLE+3,X
        rep #$20
        lda WM_ARG_X
        sta WIDGET_TABLE+4,X
        lda WM_ARG_Y
        sta WIDGET_TABLE+6,X
        lda WM_ARG_W
        sta WIDGET_TABLE+8,X
        lda WM_ARG_H
        sta WIDGET_TABLE+10,X
        sep #$20
        lda DP_PCPTR
        sta WIDGET_TABLE+12,X
        lda DP_PCPTR+1
        sta WIDGET_TABLE+13,X
        lda WIDGET_COUNT
        inc a
        sta WIDGET_COUNT
_waw_full:
        rts

; ── _wm_draw_all_widgets : redessine tous les widgets à leur position
;    absolue (fenêtre parente + offset relatif). Appelé après les fenêtres
;    → widgets persistent et suivent leur fenêtre au drag. Modifie A,X,Y.
_wm_draw_all_widgets:
        lda #$00
        sta WG_I
_wdw_loop:
        lda WG_I
        cmp WIDGET_COUNT
        bcc _wdw_go
        rts                      ; plus de widget → fin
_wdw_go:
        asl a
        asl a
        asl a
        asl a
        tax                      ; offset entrée
        lda WIDGET_TABLE+0,X
        and #$01
        bne _wdw_used            ; slot occupé → dessiner
        jmp _wdw_next            ; libre (branche longue)
_wdw_used:
        lda WIDGET_TABLE+1,X
        sta WG_PARENT
        lda WIDGET_TABLE+2,X
        sta WG_TYPE
        lda WIDGET_TABLE+3,X
        sta GFX_COLOR
        rep #$20
        lda WIDGET_TABLE+4,X
        sta WG_RELX
        lda WIDGET_TABLE+6,X
        sta WG_RELY
        lda WIDGET_TABLE+8,X
        sta WG_RELW
        lda WIDGET_TABLE+10,X
        sta WG_RELH
        sep #$20
        lda WIDGET_TABLE+12,X
        sta DP_PCPTR
        lda WIDGET_TABLE+13,X
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        ; fenêtre parente visible ?
        lda WG_PARENT
        jsr kernel_wm_offset     ; X = parent*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #(WM_F_USED | WM_F_VISIBLE)
        cmp #(WM_F_USED | WM_F_VISIBLE)
        beq _wdw_vis
        jmp _wdw_next            ; fenêtre absente/invisible (branche longue)
_wdw_vis:
        ; abs = win.xy + rel.xy
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        clc
        adc WG_RELX
        sta WM_ARG_X
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc WG_RELY
        sta WM_ARG_Y
        lda WG_RELW
        sta WM_ARG_W
        lda WG_RELH
        sta WM_ARG_H
        sep #$20
        lda WG_TYPE
        bne _wdw_btn
        jsr kernel_tk_label
        bra _wdw_next
_wdw_btn:
        ; v0.3 : pressé si ce widget est le bouton actif.
        lda WG_I
        cmp WIDGET_ACTIVE
        bne _wdw_btn_normal
        lda #$01
        sta TK_BTN_PRESSED
        bra _wdw_btn_draw
_wdw_btn_normal:
        lda #$00
        sta TK_BTN_PRESSED
_wdw_btn_draw:
        jsr kernel_tk_button
_wdw_next:
        lda WG_I
        inc a
        sta WG_I
        jmp _wdw_loop
_wdw_done:
        rts

; ── _wm_widget_hit : cherche un widget BOUTON sous (MOUSE_X,MOUSE_Y) ───
; Position absolue = fenêtre parente + offset relatif. Écrit WIDGET_ACTIVE
; = index du bouton touché, ou $FF. Modifie A,X,Y,WG_*. (SP-3.d v0.3)
_wm_widget_hit:
        lda #$FF
        sta WIDGET_ACTIVE
        lda #$00
        sta WG_I
_wh_loop:
        lda WG_I
        cmp WIDGET_COUNT
        bcc _wh_go
        rts
_wh_go:
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+0,X
        and #$01
        bne _wh_used
        jmp _wh_next
_wh_used:
        lda WIDGET_TABLE+2,X
        cmp #WG_TYPE_BUTTON
        beq _wh_isbtn
        jmp _wh_next             ; seuls les boutons sont cliquables
_wh_isbtn:
        lda WIDGET_TABLE+1,X
        sta WG_PARENT
        rep #$20
        lda WIDGET_TABLE+4,X
        sta WG_RELX
        lda WIDGET_TABLE+6,X
        sta WG_RELY
        lda WIDGET_TABLE+8,X
        sta WG_RELW
        lda WIDGET_TABLE+10,X
        sta WG_RELH
        sep #$20
        lda WG_PARENT
        jsr kernel_wm_offset     ; X = parent*10
        rep #$20
        ; abs_x = win.x + rel_x  (réutilise WG_RELX)
        lda WM_TABLE+WM_OFF_X,X
        clc
        adc WG_RELX
        sta WG_RELX
        lda MOUSE_X
        cmp WG_RELX
        bcc _wh_miss             ; MOUSE_X < abs_x
        lda WG_RELX
        clc
        adc WG_RELW
        sta WG_RELW              ; abs_x2
        lda MOUSE_X
        cmp WG_RELW
        bcs _wh_miss             ; MOUSE_X >= abs_x2
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc WG_RELY
        sta WG_RELY              ; abs_y
        lda MOUSE_Y
        cmp WG_RELY
        bcc _wh_miss
        lda WG_RELY
        clc
        adc WG_RELH
        sta WG_RELH              ; abs_y2
        lda MOUSE_Y
        cmp WG_RELH
        bcs _wh_miss
        ; HIT
        sep #$20
        lda WG_I
        sta WIDGET_ACTIVE
        rts
_wh_miss:
        sep #$20
_wh_next:
        lda WG_I
        inc a
        sta WG_I
        jmp _wh_loop

; ════════════════════════════════════════════════════════════════════
;  kernel_window_draw — dessine 1 fenêtre rectangulaire (Sprint 3.c)
; ════════════════════════════════════════════════════════════════════
;
; Dessine une fenêtre via GPU (3 étapes) :
;   1. Body (FILL_RECT entier W×H avec WIN_COLOR_BODY).
;   2. Title bar (FILL_RECT W×TITLEBAR_H en haut avec WIN_COLOR_TITLE).
;   3. Cadre (4 LINEs avec WIN_COLOR_FRAME).
;
; Args ZP :
;   WIN_BASE_LO/MID/HI ($88-$8A) = base SDRAM framebuffer.
;   WIN_X ($80), WIN_Y ($81)     = coordonnées coin haut-gauche.
;   WIN_W ($82), WIN_H ($83)     = dimensions (8-bit chacun).
;   WIN_TITLEBAR_H ($84)         = hauteur title bar.
;   WIN_COLOR_FRAME ($85)        = couleur cadre 4-bit.
;   WIN_COLOR_TITLE ($86)        = couleur title bar.
;   WIN_COLOR_BODY ($87)         = couleur corps.
; Modifie : A, X, Y, $70-$78 (utilisés par les helpers GFX), $8B-$8C.
; Pré-cond : mode N M=1 X=1, gpu_device présent, fb base valide.
; ════════════════════════════════════════════════════════════════════
.export kernel_window_draw
kernel_window_draw:
        ; Pré-calcul X+W-1 et Y+H-1 (utilisés par les LINE du cadre)
        lda WIN_X
        clc
        adc WIN_W
        sec
        sbc #$01
        sta WIN_TMP_X_END               ; X+W-1
        lda WIN_Y
        clc
        adc WIN_H
        sec
        sbc #$01
        sta WIN_TMP_Y_END               ; Y+H-1

        ; Copie BASE → GFX_BASE (partagée par tous les helpers)
        lda WIN_BASE_LO
        sta GFX_BASE_LO
        lda WIN_BASE_MID
        sta GFX_BASE_MID
        lda WIN_BASE_HI
        sta GFX_BASE_HI

        ; ── Étape 1 : zone body (FILL_RECT entier) ──────────────────
        lda WIN_X
        sta GFX_ARG2_LO
        lda WIN_Y
        sta GFX_ARG2_MID
        lda WIN_W
        sta GFX_ARG3_LO
        lda WIN_H
        sta GFX_ARG3_MID
        lda WIN_COLOR_BODY
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect

        ; ── Étape 2 : title bar (FILL_RECT haut) ────────────────────
        lda WIN_X
        sta GFX_ARG2_LO
        lda WIN_Y
        sta GFX_ARG2_MID
        lda WIN_W
        sta GFX_ARG3_LO
        lda WIN_TITLEBAR_H
        sta GFX_ARG3_MID
        lda WIN_COLOR_TITLE
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect

        ; ── Étape 3a : LINE top (X, Y) → (X+W-1, Y) ─────────────────
        lda WIN_X
        sta GFX_ARG2_LO
        lda WIN_Y
        sta GFX_ARG2_MID
        lda WIN_TMP_X_END
        sta GFX_ARG3_LO
        lda WIN_Y
        sta GFX_ARG3_MID
        lda WIN_COLOR_FRAME
        sta GFX_COLOR
        jsr kernel_gfx_line

        ; ── Étape 3b : LINE bottom (X, Y+H-1) → (X+W-1, Y+H-1) ──────
        lda WIN_X
        sta GFX_ARG2_LO
        lda WIN_TMP_Y_END
        sta GFX_ARG2_MID
        lda WIN_TMP_X_END
        sta GFX_ARG3_LO
        lda WIN_TMP_Y_END
        sta GFX_ARG3_MID
        ; (color frame déjà set)
        jsr kernel_gfx_line

        ; ── Étape 3c : LINE left (X, Y) → (X, Y+H-1) ────────────────
        lda WIN_X
        sta GFX_ARG2_LO
        lda WIN_Y
        sta GFX_ARG2_MID
        lda WIN_X
        sta GFX_ARG3_LO
        lda WIN_TMP_Y_END
        sta GFX_ARG3_MID
        jsr kernel_gfx_line

        ; ── Étape 3d : LINE right (X+W-1, Y) → (X+W-1, Y+H-1) ───────
        lda WIN_TMP_X_END
        sta GFX_ARG2_LO
        lda WIN_Y
        sta GFX_ARG2_MID
        lda WIN_TMP_X_END
        sta GFX_ARG3_LO
        lda WIN_TMP_Y_END
        sta GFX_ARG3_MID
        jsr kernel_gfx_line

        rts

; ════════════════════════════════════════════════════════════════════
;  Souris MOU2 + Window manager (SP-3.e v0.1, ADR-24)
; ════════════════════════════════════════════════════════════════════
; Pré-cond toutes routines : mode N M=X=1, DBR=0.

; ── kernel_mouse_init : reset état + active l'IRQ MOU2 ─────────────
; SP-3.e v0.2 : event-driven. Le handler IRQ (kernel_irq_handler) traite
; l'event MOU2 (lit + clear) → kernel_wm_mouse_step. clear+IRQ enable.
.export kernel_mouse_init
kernel_mouse_init:
        lda #$00
        sta MOUSE_BTN
        sta MOUSE_PREV_BTN
        lda #(MOU2_CT_IRQ_EN | $02)  ; IRQ enable + clear event initial
        sta MOU2_CTRL
        rts

; ── kernel_mouse_read : MOU2 → MOUSE_X/Y/BTN, clear event ──────────
; Les registres X_LO/X_HI (resp Y) sont consécutifs → lecture 16-bit
; directe. Modifie A. Préserve X, Y.
.export kernel_mouse_read
kernel_mouse_read:
        lda MOUSE_BTN
        sta MOUSE_PREV_BTN
        rep #$20
        lda MOU2_X_LO            ; 16-bit : X_LO | X_HI<<8 = X absolu
        sta MOUSE_X
        lda MOU2_Y_LO
        sta MOUSE_Y
        sep #$20
        lda MOU2_BUTTONS
        sta MOUSE_BTN
        ; Lit (et clear) les deltas par événement → MOUSE_DX/DY.
        lda MOU2_DX
        sta MOUSE_DX
        lda MOU2_DY
        sta MOUSE_DY
        lda #(MOU2_CT_IRQ_EN | $02)  ; clear event (deassert IRQ) + IRQ reste enable
        sta MOU2_CTRL
        rts

; ── kernel_wm_offset : A = id → X = id*WM_ENTSZ (offset). Modifie A,X.
kernel_wm_offset:
        asl a                    ; 2·id
        sta WM_DP_TMP
        asl a
        asl a                    ; 8·id
        clc
        adc WM_DP_TMP            ; 10·id
        tax
        rts

; ── kernel_wm_init : vide la table ─────────────────────────────────
.export kernel_wm_init
kernel_wm_init:
        lda #$00
        sta WM_COUNT
        sta WIDGET_COUNT         ; SP-3.d v0.2 : aucune widget au départ
        lda #$FF
        sta WM_FOCUS
        sta WIDGET_ACTIVE        ; SP-3.d v0.3 : aucun bouton actif
        ldx #$00
wm_init_lp:
        lda #$00
        sta WM_TABLE+WM_OFF_FLAGS,X   ; flags = 0 (slot libre)
        txa
        clc
        adc #WM_ENTSZ
        tax
        cpx #(WM_MAX*WM_ENTSZ)
        bcc wm_init_lp
        rts

; ── kernel_wm_add : args WM_ARG_X/Y/W/H (16-bit) → A = id ou $FF ────
.export kernel_wm_add
kernel_wm_add:
        lda WM_COUNT
        cmp #WM_MAX
        bcs wm_add_full
        sta DP_TMP               ; id = WM_COUNT
        jsr kernel_wm_offset     ; X = id*10
        lda #(WM_F_USED | WM_F_VISIBLE)
        sta WM_TABLE+WM_OFF_FLAGS,X
        lda DP_TMP
        sta WM_TABLE+WM_OFF_ID,X
        rep #$20
        lda WM_ARG_X
        sta WM_TABLE+WM_OFF_X,X
        lda WM_ARG_Y
        sta WM_TABLE+WM_OFF_Y,X
        lda WM_ARG_W
        sta WM_TABLE+WM_OFF_W,X
        lda WM_ARG_H
        sta WM_TABLE+WM_OFF_H,X
        sep #$20
        lda WM_COUNT
        inc a
        sta WM_COUNT
        lda DP_TMP               ; retourne id
        rts
wm_add_full:
        lda #$FF
        rts

; ── kernel_wm_hit_test : args WM_ARG_X/Y (point) → A = id topmost ou $FF
.export kernel_wm_hit_test
kernel_wm_hit_test:
        lda #$FF
        sta DP_TMP               ; résultat
        ldy #$00
wm_ht_loop:
        tya
        cmp WM_COUNT             ; CMP abs long (CPY ne supporte pas le long)
        bcs wm_ht_done
        jsr kernel_wm_offset     ; A=id → X = id*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #(WM_F_USED | WM_F_VISIBLE)
        cmp #(WM_F_USED | WM_F_VISIBLE)
        bne wm_ht_next
        rep #$20
        lda WM_ARG_X             ; px >= x ?
        cmp WM_TABLE+WM_OFF_X,X
        bcc wm_ht_next16
        lda WM_TABLE+WM_OFF_X,X  ; px < x+w ?
        clc
        adc WM_TABLE+WM_OFF_W,X
        sta WM_DP_TMP
        lda WM_ARG_X
        cmp WM_DP_TMP
        bcs wm_ht_next16
        lda WM_ARG_Y             ; py >= y ?
        cmp WM_TABLE+WM_OFF_Y,X
        bcc wm_ht_next16
        lda WM_TABLE+WM_OFF_Y,X  ; py < y+h ?
        clc
        adc WM_TABLE+WM_OFF_H,X
        sta WM_DP_TMP
        lda WM_ARG_Y
        cmp WM_DP_TMP
        bcs wm_ht_next16
        sep #$20                 ; hit → result = id (topmost = dernier match)
        tya
        sta DP_TMP
        bra wm_ht_next
wm_ht_next16:
        sep #$20
wm_ht_next:
        iny
        bra wm_ht_loop
wm_ht_done:
        lda DP_TMP
        rts

; ── kernel_wm_set_focus : A = id ───────────────────────────────────
.export kernel_wm_set_focus
kernel_wm_set_focus:
        sta DP_TMP               ; nouvel id
        lda WM_FOCUS
        cmp #$FF
        beq wm_sf_new
        jsr kernel_wm_offset     ; X = ancien focus *10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #(<~WM_F_FOCUS)      ; clear bit focus
        sta WM_TABLE+WM_OFF_FLAGS,X
wm_sf_new:
        lda DP_TMP
        jsr kernel_wm_offset
        lda WM_TABLE+WM_OFF_FLAGS,X
        ora #WM_F_FOCUS
        sta WM_TABLE+WM_OFF_FLAGS,X
        lda DP_TMP
        sta WM_FOCUS
        rts

; ── kernel_wm_move_focused : args WM_ARG_DX/DY (signé 16-bit) ───────
.export kernel_wm_move_focused
kernel_wm_move_focused:
        lda WM_FOCUS
        cmp #$FF
        beq wm_mv_done
        jsr kernel_wm_offset     ; X = focus*10
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        clc
        adc WM_ARG_DX
        sta WM_TABLE+WM_OFF_X,X
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc WM_ARG_DY
        sta WM_TABLE+WM_OFF_Y,X
        sep #$20
wm_mv_done:
        rts

; ── kernel_gfx_fill_rect16 : FILL_RECT16 GPU (coords 16-bit, ADR-21 v0.2) ──
; Args : WM_ARG_X/Y/W/H (16-bit), GFX_BASE (24-bit), GFX_COLOR. Packing 12-bit :
; ARG2 = y<<12|x, ARG3 = h<<12|w. Modifie A. Préserve X, Y.
.export kernel_gfx_fill_rect16
kernel_gfx_fill_rect16:
        lda GFX_BASE_LO
        sta GPU_ARG1_LO_IO
        lda GFX_BASE_MID
        sta GPU_ARG1_MID_IO
        lda GFX_BASE_HI
        sta GPU_ARG1_HI_IO
        ; ARG2 = pack(x, y)
        lda WM_ARG_X            ; x_lo
        sta GPU_ARG2_LO_IO
        lda WM_ARG_X+1          ; x[11:8]
        and #$0F
        sta DP_TMP
        lda WM_ARG_Y            ; y[3:0]<<4
        asl a
        asl a
        asl a
        asl a
        ora DP_TMP
        sta GPU_ARG2_MID_IO
        lda WM_ARG_Y            ; y[7:4]
        lsr a
        lsr a
        lsr a
        lsr a
        sta DP_TMP
        lda WM_ARG_Y+1          ; y[11:8]<<4
        asl a
        asl a
        asl a
        asl a
        ora DP_TMP
        sta GPU_ARG2_HI_IO
        ; ARG3 = pack(w, h)
        lda WM_ARG_W            ; w_lo
        sta GPU_ARG3_LO_IO
        lda WM_ARG_W+1
        and #$0F
        sta DP_TMP
        lda WM_ARG_H
        asl a
        asl a
        asl a
        asl a
        ora DP_TMP
        sta GPU_ARG3_MID_IO
        lda WM_ARG_H
        lsr a
        lsr a
        lsr a
        lsr a
        sta DP_TMP
        lda WM_ARG_H+1
        asl a
        asl a
        asl a
        asl a
        ora DP_TMP
        sta GPU_ARG3_HI_IO
        lda GFX_COLOR
        sta GPU_ARG4_LO_IO
        lda #GPU_OP_FILL_RECT16
        sta GPU_CMD_OP_IO
        sta GPU_TRIGGER_IO
        rts

; ── kernel_wm_redraw : efface le desktop + dessine toutes les fenêtres ──
; (peinture back-to-front via FILL_RECT16, coords 16-bit). Framebuffer XVGA
; à SDRAM $000000 (ADR-20). Modifie A, X, Y.
.export kernel_wm_redraw
kernel_wm_redraw:
        ; Clear desktop (bleu 1) : gfx_clear(base=$100000, size=$060000, color=1).
        ; Base $100000 (1 MiB) : hors des démos GPU legacy ($004000-$00C000).
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #$00
        sta GFX_ARG2_LO         ; size_lo
        lda #$00
        sta GFX_ARG2_MID
        lda #$06
        sta GFX_ARG2_HI         ; size = $060000 (393216)
        lda #$01
        sta GFX_COLOR           ; desktop bleu
        jsr kernel_gfx_clear
        ; fall-through : dessine les fenêtres.

; ── _wm_draw_windows : dessine toutes les fenêtres visibles (corps + titre).
;    Réutilisé par kernel_wm_redraw (clear plein) et kernel_wm_redraw_drag
;    (efface seulement l'ancien rect). Modifie A, X, Y.
_wm_draw_windows:
        ldy #$00
wm_rd_loop:
        tya
        cmp WM_COUNT
        bcs wm_rd_done
        jsr kernel_wm_offset    ; X = id*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #(WM_F_USED | WM_F_VISIBLE)
        cmp #(WM_F_USED | WM_F_VISIBLE)
        bne wm_rd_next
        phy                     ; sauve compteur id
        ; v0.8 : couleur titlebar selon focus (Y = id, encore valide ici car
        ; kernel_gfx_fill_rect16 clobbera Y plus bas).
        tya
        cmp WM_FOCUS
        bne wm_rd_unfocus
        lda #WIN_TITLE_FOCUS
        bra wm_rd_setcol
wm_rd_unfocus:
        lda #WIN_TITLE_NORMAL
wm_rd_setcol:
        sta WM_TITLE_COL
        ; Copie x/y/w/h (16-bit) de la fenêtre → WM_ARG_*.
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        sta WM_ARG_X
        lda WM_TABLE+WM_OFF_Y,X
        sta WM_ARG_Y
        lda WM_TABLE+WM_OFF_W,X
        sta WM_ARG_W
        lda WM_TABLE+WM_OFF_H,X
        sta WM_ARG_H
        sep #$20
        ; base $100000 + corps lightgray (7).
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #$07
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; Title bar : même x/y/w, h=12, couleur selon focus (v0.8).
        rep #$20
        lda #12
        sta WM_ARG_H
        sep #$20
        lda WM_TITLE_COL        ; lightblue (focus) ou darkgray (non focus)
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ply
wm_rd_next:
        iny
        bra wm_rd_loop
wm_rd_done:
        jmp _wm_draw_all_widgets   ; SP-3.d v0.2 : widgets après les fenêtres

; ── kernel_wm_redraw_drag : redraw incrémental pour le drag ────────────
; Efface seulement l'ancien rect de la fenêtre (WM_DRAG_OLD_*) en bleu,
; puis redessine toutes les fenêtres. Évite le clear plein écran (393 Ko).
; Modifie A, X, Y.
.export kernel_wm_redraw_drag
kernel_wm_redraw_drag:
        rep #$20
        lda WM_DRAG_OLD_X
        sta WM_ARG_X
        lda WM_DRAG_OLD_Y
        sta WM_ARG_Y
        lda WM_DRAG_OLD_W
        sta WM_ARG_W
        lda WM_DRAG_OLD_H
        sta WM_ARG_H
        sep #$20
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #$01                 ; desktop bleu
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        jmp _wm_draw_windows

; ── _wm_capture_focused_rect : copie le rect de la fenêtre focus dans
;    WM_DRAG_OLD_* (avant déplacement). No-op si pas de focus. Modifie A,X.
_wm_capture_focused_rect:
        lda WM_FOCUS
        cmp #$FF
        beq _wcr_done
        jsr kernel_wm_offset     ; X = focus*10
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        sta WM_DRAG_OLD_X
        lda WM_TABLE+WM_OFF_Y,X
        sta WM_DRAG_OLD_Y
        lda WM_TABLE+WM_OFF_W,X
        sta WM_DRAG_OLD_W
        lda WM_TABLE+WM_OFF_H,X
        sta WM_DRAG_OLD_H
        sep #$20
_wcr_done:
        rts

; ── kernel_wm_mouse_step : 1 itération event loop (clic → focus,
;    bouton tenu + mouvement → drag fenêtre focus). Lit MOUSE_*. ─────
; Pré-cond : kernel_mouse_read appelé juste avant (MOUSE_X/Y/BTN à jour).
.export kernel_wm_mouse_step
kernel_wm_mouse_step:
        ; Bouton gauche pressé ?
        lda MOUSE_BTN
        and #MOU2_BTN_LEFT
        bne wm_step_pressed
        ; Motion seule (pas de bouton) → désarme le drag + curseur léger
        ; (backing-store : PAS de full-redraw du desktop).
        lda #$00
        sta WM_DRAG_ARMED
        jsr kernel_wm_cursor_blit
        rts
wm_step_pressed:
        ; bouton gauche tenu. Était-il déjà tenu (drag) ou nouveau clic ?
        lda MOUSE_PREV_BTN
        and #MOU2_BTN_LEFT
        bne wm_step_drag         ; déjà tenu → drag (si armé)
        ; Nouveau clic → focus la fenêtre sous le curseur.
        rep #$20
        lda MOUSE_X
        sta WM_ARG_X
        lda MOUSE_Y
        sta WM_ARG_Y
        sep #$20
        jsr kernel_wm_hit_test   ; A = id ou $FF
        cmp #$FF
        bne wm_step_hit
        ; Clic sur le vide → pas de focus ni changement desktop → curseur léger.
        lda #$00
        sta WM_DRAG_ARMED
        jsr kernel_wm_cursor_blit
        rts
wm_step_hit:
        jsr kernel_wm_set_focus
        lda #$01                 ; clic sur une fenêtre → arme le drag
        sta WM_DRAG_ARMED
        ; v0.3 : bouton sous le curseur → WIDGET_ACTIVE (sinon $FF).
        jsr _wm_widget_hit
        ; Focus changé → desktop modifié → full-redraw + curseur.
        jsr kernel_wm_redraw
        jsr kernel_wm_draw_cursor
        rts
wm_step_drag:
        ; Drag autorisé seulement si le clic initial a touché une fenêtre.
        lda WM_DRAG_ARMED
        bne wm_step_do_drag
        ; bouton tenu hors fenêtre → curseur léger uniquement.
        jsr kernel_wm_cursor_blit
        rts
wm_step_do_drag:
        ; v0.7 : drag incrémental (pas de clear plein écran).
        ; 1. capture le rect actuel (avant déplacement) = dirty rect à effacer.
        jsr _wm_capture_focused_rect
        ; 2. efface l'ancien curseur (restaure le fond) avant repaint.
        jsr kernel_wm_cursor_restore
        ; 3. déplace la fenêtre focus du delta de l'événement (MOUSE_DX/DY).
        lda MOUSE_DX
        jsr _sext8_to16          ; WM_ARG_DX = sign-extend(MOUSE_DX)
        sta WM_ARG_DX
        stx WM_ARG_DX+1
        lda MOUSE_DY
        jsr _sext8_to16
        sta WM_ARG_DY
        stx WM_ARG_DY+1
        jsr kernel_wm_move_focused
        ; 4. redraw incrémental : efface l'ancien rect + redessine les fenêtres.
        jsr kernel_wm_redraw_drag
        ; 5. curseur : backing périmé après repaint → invalide, sauve, dessine.
        jsr kernel_wm_draw_cursor
        rts

; ── kernel_wm_draw_cursor : après un full-redraw du desktop ────────────
; Le fond sous le curseur a été repeint → l'ancien backing est périmé.
; Invalide, capture le nouveau fond, dessine le curseur. Modifie A,X,Y.
.export kernel_wm_draw_cursor
kernel_wm_draw_cursor:
        lda #$00
        sta CURSOR_VALID         ; ancien backing périmé (desktop repeint)
        jsr _cursor_save_and_draw
        rts

; ── kernel_wm_cursor_blit : déplacement léger du curseur (motion) ──────
; Restaure le fond sous l'ancien curseur, capture le nouveau, dessine.
; PAS de redraw desktop. Modifie A,X,Y.
.export kernel_wm_cursor_blit
kernel_wm_cursor_blit:
        jsr kernel_wm_cursor_restore
        jsr _cursor_save_and_draw
        rts

; clampe MOUSE_X/Y → CUR_DRAW_X/Y dans [0,1016]×[0,760], sauve le fond,
; dessine le curseur. Met CURSOR_OLD/VALID à jour. Modifie A,X,Y.
_cursor_save_and_draw:
        jsr _cursor_clamp
        jsr kernel_wm_cursor_save
        jsr _cursor_draw
        rts

; clampe MOUSE → CUR_DRAW (zone 8×8 toujours dans l'écran).
_cursor_clamp:
        rep #$20
        lda MOUSE_X
        cmp #1017
        bcc _cc_x_ok
        lda #1016
_cc_x_ok:
        sta CUR_DRAW_X
        lda MOUSE_Y
        cmp #761
        bcc _cc_y_ok
        lda #760
_cc_y_ok:
        sta CUR_DRAW_Y
        sep #$20
        rts

; dessine le curseur 6×8 blanc à CUR_DRAW via FILL_RECT16.
_cursor_draw:
        rep #$20
        lda CUR_DRAW_X
        sta WM_ARG_X
        lda CUR_DRAW_Y
        sta WM_ARG_Y
        lda #6
        sta WM_ARG_W
        lda #8
        sta WM_ARG_H
        sep #$20
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #$0F                 ; blanc
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        rts

; calcule l'adresse SDRAM de la 1re ligne de la zone curseur (8px×8) à
; partir de CUR_DRAW_X/Y → VRAM_OP_ADDR_LO/MID/HI.
;   addr = $100000 + y*512 + (x>>1)   (BPL XVGA = 512, 4bpp 2px/octet)
; Astuce : y*512 = (y*2)<<8 → octet0=0, (mid,hi)16 = y*2. base ajoute $1000
; aux (mid,hi). x>>1 ≤ 508 : octet0 = lo, retenue (≤1) ajoutée aux (mid,hi).
_cursor_calc_addr:
        rep #$20
        lda CUR_DRAW_X
        lsr a                    ; xb = x>>1
        sta CUR_XB
        lda CUR_DRAW_Y
        asl a                    ; y*2
        clc
        adc #$1000               ; + contribution base $100000 aux (mid,hi)
        sta CUR_MIDHI
        lda CUR_XB
        xba                      ; octets échangés → low = xb>>8 (0 ou 1)
        and #$00FF
        clc
        adc CUR_MIDHI
        sta CUR_MIDHI
        sep #$20
        lda CUR_XB               ; octet bas de xb
        sta VRAM_OP_ADDR_LO
        lda CUR_MIDHI            ; octet bas = mid
        sta VRAM_OP_ADDR_MID
        lda CUR_MIDHI+1          ; octet haut = hi
        sta VRAM_OP_ADDR_HI
        rts

; sauve la zone 8×8 (4 octets × 8 lignes) sous CUR_DRAW → CURSOR_SAVE,
; met CURSOR_OLD = CUR_DRAW, VALID = 1.
.export kernel_wm_cursor_save
kernel_wm_cursor_save:
        jsr _cursor_calc_addr
        lda #<CURSOR_SAVE
        sta DP_PCPTR
        lda #>CURSOR_SAVE
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        ldx #$08
_csv_row:
        lda #$04
        sta VRAM_OP_LEN_LO
        stz VRAM_OP_LEN_HI
        phx
        jsr kernel_vram_read_block
        plx
        jsr _cursor_next_row
        dex
        bne _csv_row
        rep #$20
        lda CUR_DRAW_X
        sta CURSOR_OLD_X
        lda CUR_DRAW_Y
        sta CURSOR_OLD_Y
        sep #$20
        lda #$01
        sta CURSOR_VALID
        rts

; restaure le fond sous l'ancien curseur (CURSOR_OLD) depuis CURSOR_SAVE.
; No-op si CURSOR_VALID = 0.
.export kernel_wm_cursor_restore
kernel_wm_cursor_restore:
        lda CURSOR_VALID
        bne _crst_go
        rts
_crst_go:
        rep #$20
        lda CURSOR_OLD_X
        sta CUR_DRAW_X
        lda CURSOR_OLD_Y
        sta CUR_DRAW_Y
        sep #$20
        jsr _cursor_calc_addr
        lda #<CURSOR_SAVE
        sta DP_PCPTR
        lda #>CURSOR_SAVE
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        ldx #$08
_crst_row:
        lda #$04
        sta VRAM_OP_LEN_LO
        stz VRAM_OP_LEN_HI
        phx
        jsr kernel_vram_write_block
        plx
        jsr _cursor_next_row
        dex
        bne _crst_row
        rts

; avance VRAM_OP_ADDR d'une ligne (+512 = mid+=2, carry hi) et DP_PCPTR de
; 4 octets (ligne suivante du buffer CURSOR_SAVE).
_cursor_next_row:
        lda VRAM_OP_ADDR_MID
        clc
        adc #$02
        sta VRAM_OP_ADDR_MID
        bcc _cnr_nc
        inc VRAM_OP_ADDR_HI
_cnr_nc:
        lda DP_PCPTR
        clc
        adc #$04
        sta DP_PCPTR
        bcc _cnr_np
        inc DP_PCPTR+1
_cnr_np:
        rts

; helper : A = octet signé → A=low, X=high (sign-extension). Modifie A,X.
_sext8_to16:
        ldx #$00
        cmp #$80                 ; bit7 ? (négatif)
        bcc _sext_pos
        ldx #$FF
_sext_pos:
        rts

; ════════════════════════════════════════════════════════════════════
;  Syscall handlers v0.2 — implémentent les 18 syscalls ADR-17
; ════════════════════════════════════════════════════════════════════
;
; Appelés via JSR depuis kernel_cop_handler (table dispatch v0.2).
; Convention : retournent via RTS. A = valeur de retour ($FF = erreur).
; X arg1 est lu depuis DP_SYS_ARG_X (sauvé par le dispatcher).
; Y arg2 est lu depuis le registre Y (intact, non touché par dispatcher).
;
; ════════════════════════════════════════════════════════════════════

; $00 — sys_invalid : syscall réservé ou hors-table (aussi fin de table) ─
sys_invalid:
        lda #$FF
        rts

; $01 — SYS_PRINT_CHAR : arg X = char ────────────────────────────────
sys_print_char:
        ldx DP_SYS_ARG_X        ; récupère l'arg X original
        txa
        jsr kernel_print_char
        rts

; $02 — SYS_PRINT_STRING : X=lo, Y=hi du pointeur (bank = DBR appelant) ─
sys_print_string:
        phb
        pla                     ; A = DBR de l'appelant
        sta DP_PTR+2
        lda DP_SYS_ARG_X        ; A = arg X = lo ptr
        sta DP_PTR
        tya                     ; A = arg Y = hi ptr
        sta DP_PTR+1
        jsr kernel_print_string
        rts

; $03 — SYS_READ_CHAR : bloquant → A = keycode (OS-2.d, ADR-22) ──────
; v0.1 : spin-poll le ring (les autres tâches tournent via préemption
; timer). Blocage vrai (task BLOCKED + wake) reporté à OS-2.g (TCB states).
sys_read_char:
sread_wait:
        jsr kernel_kbd_ring_pop
        cmp #$00
        beq sread_wait          ; vide → attend une touche
        rts                     ; A = keycode

; $04 — SYS_EXIT : X = exit_code ─────────────────────────────────────
sys_exit:
        stp                     ; v0.1 : arrêt (pas de task cleanup OS-2.g.v2)
        bra *

; $05 — SYS_YIELD : cède le CPU ───────────────────────────────────────
sys_yield:
        rts                     ; no-op : scheduler est IRQ-driven (ADR-03)

; $06 — SYS_GET_KEY : non-bloquant → A = keycode ou $00 (OS-2.d) ─────
sys_get_key:
        jsr kernel_kbd_ring_pop ; A = keycode, ou $00 si ring vide
        rts

; $07 — SYS_FAT_OPEN : DP_FILENAME (11B) posé par l'appelant ──────────
; Retourne A=$00 si trouvé (fd=0 v0.1), A=$FF si non trouvé.
sys_fat_open:
        jsr kernel_fat_open
        lda FS_OPEN_RESULT
        bne sfop_err
        lda #$00                ; A=$00 = fd 0 (single file v0.1)
        rts
sfop_err:
        lda #$FF
        rts

; $08 — SYS_FAT_READ : args dans ZP kernel_fat_read_file ──────────────
sys_fat_read:
        jsr kernel_fat_read_file
        rts

; $09 — SYS_FAT_CLOSE : stub v0.2 ─────────────────────────────────────
sys_fat_close:
        lda #$00
        rts

; $0A — SYS_PANIC : X = code ──────────────────────────────────────────
sys_panic:
        lda DP_SYS_ARG_X        ; récupère le code (arg X)
        jsr kernel_panic
        rts

; $0B — SYS_ALLOC_BANK : ret A = bank ou $FF ──────────────────────────
sys_alloc_bank:
        jsr kernel_alloc_bank
        cmp #$00
        bne sab_ok
        lda #$FF                ; pool épuisé → erreur ADR-17
sab_ok: rts

; $0C — SYS_FREE_BANK : X = bank ──────────────────────────────────────
sys_free_bank:
        lda DP_SYS_ARG_X        ; récupère numéro bank (arg X)
        jsr kernel_free_bank
        rts

; $0D — SYS_GFX_CLEAR : args via I/O ZP (ADR-21 convention) ──────────
sys_gfx_clear:
        jsr kernel_gfx_clear
        lda #$00
        rts

; $0E — SYS_GFX_FILL_RECT ─────────────────────────────────────────────
sys_gfx_fill_rect:
        jsr kernel_gfx_fill_rect
        lda #$00
        rts

; $0F — SYS_GFX_BLIT ──────────────────────────────────────────────────
sys_gfx_blit:
        jsr kernel_gfx_blit
        lda #$00
        rts

; $10 — SYS_GFX_LINE ──────────────────────────────────────────────────
sys_gfx_line:
        jsr kernel_gfx_line
        lda #$00
        rts

; $11 — SYS_GFX_TEXT ──────────────────────────────────────────────────
sys_gfx_text:
        jsr kernel_gfx_text
        lda #$00
        rts

; $12 — SYS_SLEEP_MS : X/Y = ms16 (stub v0.2) ────────────────────────
sys_sleep_ms:
        rts                     ; stub : pas de timer ms précis

; ════════════════════════════════════════════════════════════════════
;  NMI_HANDLER — bank 1 $5500
; ════════════════════════════════════════════════════════════════════
;
; Sprint 1.c : NMI réservé pour le futur (panic, debug). Pour l'instant
; un simple RTI no-op.
;
; ════════════════════════════════════════════════════════════════════
        .segment "NMI_HANDLER"

.export kernel_nmi_handler
kernel_nmi_handler:
        rti

; ════════════════════════════════════════════════════════════════════
;  COP_HANDLER — syscall dispatcher v0.2 (bank 1 $5700, ADR-13/17)
; ════════════════════════════════════════════════════════════════════
;
; Convention v0.2 (ADR-17) : cop #$AA → A=num syscall, X=arg1, Y=arg2.
; Table dispatch : SYSCALL_TABLE à $01:5750, 64 entrées × 2B (ADR-17).
; Le dispatcher sauve X dans DP_SYS_ARG_X avant de l'utiliser comme
; index. Les handlers lisent X arg depuis DP_SYS_ARG_X. Y est intact.
; Retour : A = valeur ($FF = erreur, ADR-17).
;
; ════════════════════════════════════════════════════════════════════
        .segment "COP_HANDLER"

.export kernel_cop_handler
kernel_cop_handler:
        sep #$30                ; sécurité M=X=1 (mode N native)
        stx DP_SYS_ARG_X       ; sauve X (arg1) — sera écrasé par l'index
        cmp #$40               ; num < 64 ?
        bcs cop_invalid
        asl a                   ; A = num × 2 (offset bytes dans la table)
        tax                     ; X = index table (DP_SYS_ARG_X contient l'arg1)
        jsr (syscall_table,x)  ; appel handler via table (ADR-17)
        rti                     ; retour caller — A = valeur de retour

cop_invalid:
        ; OS-2.i.v2 : journalise le syscall invalide (num ≥ 64).
        lda #ERR_BAD_SYSCALL
        ldx #LOG_WARN
        jsr kernel_log_write
        lda #$FF                ; convention erreur ADR-17
        rti

; ════════════════════════════════════════════════════════════════════
;  SYSCALL_TABLE — table 64 entrées × 2B (bank 1 $5750, ADR-17)
; ════════════════════════════════════════════════════════════════════
        .segment "SYSCALL_TABLE"

.export syscall_table
syscall_table:
        .word sys_invalid       ; $00 réservé
        .word sys_print_char    ; $01 SYS_PRINT_CHAR
        .word sys_print_string  ; $02 SYS_PRINT_STRING
        .word sys_read_char     ; $03 SYS_READ_CHAR  (stub — OS-2.d)
        .word sys_exit          ; $04 SYS_EXIT
        .word sys_yield         ; $05 SYS_YIELD
        .word sys_get_key       ; $06 SYS_GET_KEY    (stub — OS-2.d)
        .word sys_fat_open      ; $07 SYS_FAT_OPEN
        .word sys_fat_read      ; $08 SYS_FAT_READ
        .word sys_fat_close     ; $09 SYS_FAT_CLOSE  (stub)
        .word sys_panic         ; $0A SYS_PANIC
        .word sys_alloc_bank    ; $0B SYS_ALLOC_BANK
        .word sys_free_bank     ; $0C SYS_FREE_BANK
        .word sys_gfx_clear     ; $0D SYS_GFX_CLEAR
        .word sys_gfx_fill_rect ; $0E SYS_GFX_FILL_RECT
        .word sys_gfx_blit      ; $0F SYS_GFX_BLIT
        .word sys_gfx_line      ; $10 SYS_GFX_LINE
        .word sys_gfx_text      ; $11 SYS_GFX_TEXT
        .word sys_sleep_ms      ; $12 SYS_SLEEP_MS   (stub)
        .repeat 45
        .word sys_invalid       ; $13-$3F réservés
        .endrep

; ════════════════════════════════════════════════════════════════════
;  IRQ_HANDLER — scheduler préemptif (bank 1 $5600)
; ════════════════════════════════════════════════════════════════════
;
; Sprint 1.c : le scheduler est désormais sur la ligne IRQ — déclenchée
; par VIA T1 (Sprint 2 ; pour Sprint 1.c le test inject IRQF_VIA en
; pattern set/step/clear pour mimer un timer).
;
; Entrée hw mode N : PB/PC/P pushés sur la stack courante.
; L'ack de la source IRQ (lecture VIA registre) est implicite ici —
; le test côté Phosphoric clear cpu->irq juste après inject.
;
; ════════════════════════════════════════════════════════════════════
        .segment "IRQ_HANDLER"

.export kernel_irq_handler
kernel_irq_handler:
        sep #$30                ; M=1, X=1 (sécurité)

        ; ── Save A/X/Y de la tâche courante sur sa stack ───────────
        pha
        phx
        phy

        ; ── SP-3.e v0.2 : souris MOU2 event-driven (ADR-24) ────────
        ; Si event souris en attente : lit + traite (clic→focus, drag).
        ; kernel_mouse_read clear l'event (deassert IRQF_MOU2).
        lda MOU2_STATUS
        and #$80                ; bit7 = event
        beq irq_no_mou
        jsr kernel_mouse_read
        jsr kernel_wm_mouse_step
irq_no_mou:
        ; ── OS-2.d (ADR-22) : draine la FIFO KBD2 → ring ───────────
        jsr kernel_kbd_poll

        ; ── VIA T1 présent ? (sinon IRQ MOU2/KBD2 seule : pas de tick) ──
        lda VIA_IFR
        and #$40                ; bit6 = T1
        bne irq_t1
        ; Pas de T1 : restaure la MÊME tâche (aucun tick/context switch).
        ply
        plx
        pla
        rti
irq_t1:
        ; ── Ack VIA T1 IRQ (lecture T1C-L clear T1 IFR) ────────────
        lda VIA_T1CL

        ; ── Increment tick counter ─────────────────────────────────
        lda TICK_COUNTER
        inc a
        sta TICK_COUNTER
        cmp #TICK_GOAL
        bcc do_switch
        ; ≥ TICK_GOAL. SP-3.e v0.4 : mode persistant (live) vs STP (tests).
        ; Si NO_STP_FLAG == magic $A5 (posé par --kernel), on continue le
        ; scheduler à l'infini (GUI interactive). Sinon STP (signal boot OK tests).
        lda NO_STP_FLAG
        cmp #$A5
        beq do_switch
        stp
        bra *

do_switch:
        ; ── ADR-14 : sauve S dans TCB[CUR].saved_S, charge TCB[NEXT] ──
        ; v0.1 : 2 tasks fixes. CUR ∈ {1, 2}. NEXT = 3 - CUR.
        lda TASK_CUR
        cmp #$01                ; CUR == 1 (task A) ?
        bne switch_from_2

        ; CUR=1 → save TCB_1, load TCB_2
        rep #$20
        tsc
        sta TCB_1_S
        lda TCB_2_S
        tcs
        sep #$20
        lda #TASK_STATE_READY
        sta TCB_1_STATE
        lda #TASK_STATE_RUNNING
        sta TCB_2_STATE
        lda #$02
        sta TASK_CUR
        bra restore_and_return

switch_from_2:
        ; CUR=2 → save TCB_2, load TCB_1
        rep #$20
        tsc
        sta TCB_2_S
        lda TCB_1_S
        tcs
        sep #$20
        lda #TASK_STATE_READY
        sta TCB_2_STATE
        lda #TASK_STATE_RUNNING
        sta TCB_1_STATE
        lda #$01
        sta TASK_CUR

restore_and_return:
        ; ── Pull Y/X/A depuis la nouvelle stack ────────────────────
        ply
        plx
        pla
        rti

; ════════════════════════════════════════════════════════════════════
;  CHARSET — fonte char Oric 1 (1024 octets) embedded à bank 1 $5800
; ════════════════════════════════════════════════════════════════════
; Extraite de roms/basic11b.rom offset $3B78 (= ROM $FB78). 128 chars
; × 8 lignes. Le kernel copie ce blob vers bank 0 $B400 au boot.
; ════════════════════════════════════════════════════════════════════
        .segment "CHARSET"
.export kernel_charset
kernel_charset:
        .incbin "../data/charset.bin"
