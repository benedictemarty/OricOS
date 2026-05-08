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

; ─── Bank allocator (Sprint 2.b/2.h) ────────────────────────────────
BANK_NEXT       = $015450       ; prochain bank libre via bump (uint8)
BANK_DEMO       = $015460       ; 3 octets : résultats de l'alloc démo
BANK_POOL_BASE  = $04            ; premier bank du pool
BANK_POOL_END   = $80            ; dernier bank du pool + 1 (= $80, banks 4-127)

; Sprint 2.h : free list LIFO 16 entries. alloc pop d'abord, sinon bump.
BANK_FREE_LIST  = $0154A0       ; 16 bytes stack (banks libérés)
BANK_FREE_TOP   = $0154B0       ; 1 byte (count 0..16)

; ─── Modèle erreur kernel (Sprint 2.i) ──────────────────────────────
PANIC_CODE      = $015495       ; 1 byte : dernier code panic (0 = OK)

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
KBD_MATRIX      = $015470       ; 8 octets bank 1 (col 0..7 active low)

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
HIRES2_BANK     = $80           ; bank du framebuffer
HIRES2_FB_SIZE  = 18000         ; total bytes (90 × 200) = $4650
; ZP tmp pour kernel_hires2_clear (libres au moment du boot)
HIRES2_PAT_PTR  = $20           ; 3 bytes : DP indirect long → pattern_table
HIRES2_FB_PTR   = $24           ; 3 bytes : DP indirect long → $80:0000
HIRES2_PB0      = $34           ; pattern byte 0
HIRES2_PB1      = $35           ; pattern byte 1
HIRES2_PB2      = $36           ; pattern byte 2

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

        ; ── Sprint 3.b : init framebuffer HIRES Oric 2 (bank 128) ──
        ; Efface en blue (color 4) pour validation visuelle. La 1ère
        ; écriture déclenche le lazy alloc B1.8 du bank 128.
        lda #$04                ; blue
        jsr kernel_hires2_clear

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
        jsr kernel_clear_screen
        jsr kernel_console_init
        jsr kernel_print_banner

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

        ; ── Sprint 2.d : init clavier (DDR + PSG R7) ───────────────
        jsr kernel_kbd_init

        ; ── Sprint 2.b/2.h : init bank allocator (bump + free list) ──
        lda #BANK_POOL_BASE
        sta BANK_NEXT
        lda #$00
        sta BANK_FREE_TOP

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
.export kernel_panic
kernel_panic:
        sta PANIC_CODE
        pha                     ; sauve code
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
; Modifie : A, X. Préserve Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_install_charset
kernel_install_charset:
        rep #$10                ; X 16-bit
        ldx #$0000
charset_loop:
        cpx #CHARSET_SIZE
        bcs charset_done
        lda CHARSET_SRC,X       ; long $lll,X
        sta CHARSET_DST,X       ; long $lll,X
        inx
        bra charset_loop
charset_done:
        sep #$10                ; X 8-bit retour
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
; Non-implémenté v0.1 (reporté OS-2.e.2) : CR (\r), scroll up,
; attribut couleur, gestion de plusieurs INKs simultanés.
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
pc_check_end:
        ; Si CURSOR_ADDR >= SCREEN_END, reste à la dernière ligne
        ; (scroll non implémenté v0.1 — clamp simple).
        rep #$20
        lda CURSOR_ADDR
        cmp #SCREEN_END
        sep #$20
        bcc pc_done
        rep #$20
        lda #SCREEN_LAST_ROW     ; clamp à dernière ligne (start)
        sta CURSOR_ADDR
        sep #$20
pc_done:
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
        .byte "OricOS v0.7", $0A, $00

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

; ── kernel_kbd_init : DDR + PSG R7 + matrice initiale ──────────────
; Pré-cond : mode N M=X=1, DBR=0.
.export kernel_kbd_init
kernel_kbd_init:
        ; DDRA = $FF (port A en sortie pour PSG bus)
        lda #$FF
        sta VIA_DDRA
        ; DDRB = $F7 (bits 0-2 col select output, bit 3 input scan, 4-7 output)
        lda #$F7
        sta VIA_DDRB
        ; PSG R7 = $FF : tones 0-2 enabled, port A en input mode (bit 6=1
        ;                dans la convention Phosphoric/Oricutron Oric 1).
        lda #$07
        jsr psg_set_reg
        lda #$FF
        jsr psg_write_data
        ; Init KBD_MATRIX à $FF (= no key pressed, active low)
        ldx #$00
kbd_init_loop:
        lda #$FF
        sta KBD_MATRIX,X
        inx
        cpx #$08
        bcc kbd_init_loop
        rts

; ── kernel_kbd_scan : scan 8 colonnes → KBD_MATRIX ─────────────────
; Pré-cond : mode N M=X=1, DBR=0. Modifie A, X. Préserve Y.
.export kernel_kbd_scan
kernel_kbd_scan:
        ldx #$00
kbd_scan_loop:
        ; Sélectionne col X via VIA ORB bits 0-2 (bits 3-7 forcés à 0
        ; — OricOS ne pilote ni cassette ni printer ; à étendre plus
        ; tard si besoin).
        txa
        and #$07
        sta VIA_ORB
        ; Demande PSG R14 (port A input → rangées clavier)
        lda #$0E
        jsr psg_set_reg
        jsr psg_read_data        ; A = état des 8 rangées de la col X
        sta KBD_MATRIX,X
        inx
        cpx #$08
        bcc kbd_scan_loop
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
        lda #$00                ; pool épuisé
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

; ════════════════════════════════════════════════════════════════════
;  kernel_hires2_clear — efface framebuffer HIRES Oric 2 (Sprint 3.b)
; ════════════════════════════════════════════════════════════════════
;
; Args : A = color (0..7).
; Effets : remplit bank $80 (HIRES Oric 2) avec une couleur uniforme.
;          18 000 octets écrits avec le pattern 24-bit color × $249249,
;          répété 6000 fois (90 octets/ligne × 200 lignes).
; Modifie : A, X, Y, $20-$22, $24-$26, $34-$36.
; Pré-cond : mode N M=1 X=1, DBR=0. Bank 128 lazy-alloc à 1ère écriture.
; ════════════════════════════════════════════════════════════════════
.export kernel_hires2_clear
kernel_hires2_clear:
        and #$07                ; color &= 7
        sta HIRES2_PB0          ; tmp save color
        ; index = color × 3 (offset dans pattern_table 8 entries × 3B)
        asl                     ; ×2
        clc
        adc HIRES2_PB0          ; +color = ×3
        ; HIRES2_PAT_PTR = pattern_table + index (bank 1)
        clc
        adc #<pattern_table
        sta HIRES2_PAT_PTR
        lda #>pattern_table
        adc #$00                ; +carry
        sta HIRES2_PAT_PTR+1
        lda #$01                ; segment CODE = bank 1
        sta HIRES2_PAT_PTR+2
        ; Lit 3 octets pattern via [HIRES2_PAT_PTR],Y
        ldy #$00
        lda [HIRES2_PAT_PTR],Y
        sta HIRES2_PB0
        iny
        lda [HIRES2_PAT_PTR],Y
        sta HIRES2_PB1
        iny
        lda [HIRES2_PAT_PTR],Y
        sta HIRES2_PB2
        ; HIRES2_FB_PTR = $80:0000 (dest framebuffer)
        lda #$00
        sta HIRES2_FB_PTR
        sta HIRES2_FB_PTR+1
        lda #HIRES2_BANK
        sta HIRES2_FB_PTR+2
        ; Loop 6000 itérations (= 18000/3) écrivant 3 bytes à chaque step.
        rep #$10                ; X/Y 16-bit
        ldy #$0000
hr2c_loop:
        cpy #HIRES2_FB_SIZE
        bcs hr2c_done
        lda HIRES2_PB0
        sta [HIRES2_FB_PTR],Y
        iny
        lda HIRES2_PB1
        sta [HIRES2_FB_PTR],Y
        iny
        lda HIRES2_PB2
        sta [HIRES2_FB_PTR],Y
        iny
        bra hr2c_loop
hr2c_done:
        sep #$10                ; X/Y 8-bit retour
        rts

; pattern_table — pattern 24-bit color × $249249 par color (8 × 3B).
; Calculé : color * $249249 (= 8 pixels même couleur sur 24 bits).
;   color 0 = $000000 → octets $00 $00 $00
;   color 1 = $249249 → octets $24 $92 $49
;   color 2 = $492492 → octets $49 $24 $92
;   color 3 = $6DB6DB → octets $6D $B6 $DB
;   color 4 = $924924 → octets $92 $49 $24
;   color 5 = $B6DB6D → octets $B6 $DB $6D
;   color 6 = $DB6DB6 → octets $DB $6D $B6
;   color 7 = $FFFFFF → octets $FF $FF $FF
pattern_table:
        .byte $00, $00, $00     ; 0 black
        .byte $24, $92, $49     ; 1 red
        .byte $49, $24, $92     ; 2 green
        .byte $6D, $B6, $DB     ; 3 yellow
        .byte $92, $49, $24     ; 4 blue
        .byte $B6, $DB, $6D     ; 5 magenta
        .byte $DB, $6D, $B6     ; 6 cyan
        .byte $FF, $FF, $FF     ; 7 white

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
;  COP_HANDLER — syscall dispatcher (bank 1 $5700, ADR-13)
; ════════════════════════════════════════════════════════════════════
;
; Convention v0.1 (ADR-13 minimal) : `cop #$AA` (signature OricOS).
; Le numéro de syscall est passé en A. Args en X/Y selon syscall.
;
; v0.1 supporte un seul syscall hardcoded :
;   SYS_PRINT_CHAR ($01) : A=$01 → X = char (oui, A non utilisable car
;     contient le numéro). Convention v0.1bis : si A=$01, X = char.
;
; Plus tard : table de pointers en bank 1 indexée par A*2.
;
; ════════════════════════════════════════════════════════════════════
        .segment "COP_HANDLER"

.export kernel_cop_handler
kernel_cop_handler:
        sep #$30                ; sécurité M=X=1
        cmp #$01                ; SYS_PRINT_CHAR ?
        bne cop_unknown
        ; SYS_PRINT_CHAR : char est en X (8-bit), passé via X.
        txa                     ; A = char
        jsr kernel_print_char
cop_unknown:
        ; v0.1 : ignore syscalls inconnus
        rti

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

        ; ── Ack VIA T1 IRQ (lecture T1C-L clear T1 IFR) ────────────
        lda VIA_T1CL

        ; ── Sprint 2.d : scan clavier à chaque tick ────────────────
        jsr kernel_kbd_scan

        ; ── Increment tick counter ─────────────────────────────────
        lda TICK_COUNTER
        inc a
        sta TICK_COUNTER
        cmp #TICK_GOAL
        bcc do_switch
        ; ≥ TICK_GOAL → arrêt propre
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
