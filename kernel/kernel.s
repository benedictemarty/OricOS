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
TASK_CUR        = $015432
TASK_A_S        = $015434
TASK_B_S        = $015436
TASK_A_CTR      = $015440
TASK_B_CTR      = $015444
TICK_GOAL       = $0A           ; 10 ticks → STP

; ─── Bank allocator (Sprint 2.b) ────────────────────────────────────
BANK_NEXT       = $015450       ; prochain bank libre (uint8)
BANK_DEMO       = $015460       ; 3 octets : résultats de l'alloc démo
BANK_POOL_BASE  = $04            ; premier bank du pool
BANK_POOL_END   = $80            ; dernier bank du pool + 1 (= $80, banks 4-127)

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
; print_char utilise DP_PCPTR (long indirect [dp] → bank 0 screen RAM).
; Séparés pour éviter conflit lors de print_char appelé depuis print_string.
DP_PTR          = $08            ; DP+$08/$09/$0A : pointer 24-bit
DP_PCPTR        = $0C            ; DP+$0C/$0D/$0E : pointer 24-bit
DP_TMP          = $10            ; DP+$10 : char temp

; Note : Phosphoric (golden model 65C816) n'implémente PAS l'opcode $92
; (STA (dp), DP indirect 16-bit). Trou identifié — à fixer côté
; Phosphoric. En attendant, on utilise [dp] long indirect ($87) qui
; est implémenté, avec bank explicite en DP+$0E.

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
        sep #$20
        sep #$30                ; M=1, X=1
        ldx #$FF
        txs                     ; S = $01FF (stack task A initiale)

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
        sta TASK_CUR            ; current = 0 (task A)

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

        ; task_b_S = $02F4 (16-bit store)
        rep #$20
        lda #$02F4
        sta TASK_B_S
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

        ; ── Sprint 2.d : init clavier (DDR + PSG R7) ───────────────
        jsr kernel_kbd_init

        ; ── Sprint 2.b : init bank allocator ───────────────────────
        lda #BANK_POOL_BASE
        sta BANK_NEXT

        ; Démo : alloue 3 banks, stocke à BANK_DEMO+0..2.
        jsr kernel_alloc_bank
        sta BANK_DEMO+0
        jsr kernel_alloc_bank
        sta BANK_DEMO+1
        jsr kernel_alloc_bank
        sta BANK_DEMO+2

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

; ─── kernel_panic (Sprint 2+) ───────────────────────────────────────
.export kernel_panic
kernel_panic:
        stp
        bra *

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
        ; Char normal : store at CURSOR_ADDR (bank 0)
        ; Setup pointer 24-bit DP_PCPTR : low/high = CURSOR_ADDR, bank = $00
        rep #$20
        lda CURSOR_ADDR
        sta DP_PCPTR             ; DP+$0C/$0D = low/high
        sep #$20
        lda #$00
        sta DP_PCPTR+2           ; DP+$0E = bank 0 (screen RAM)
        lda DP_TMP
        sta [DP_PCPTR]           ; opcode $87 — STA dp indirect long, écrit bank0:CURSOR_ADDR
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
;  kernel_alloc_bank — allocateur de bank simple (Sprint 2.b)
; ════════════════════════════════════════════════════════════════════
;
; Convention : retourne le numéro de bank dans A (8-bit). Retourne 0
; si le pool est épuisé. Pas de free list dans cette version v0.1 —
; allocation incrémentale stricte. La libération viendra avec un
; allocator bitmap en Sprint 2.b/v2.
;
; Pré-conditions : appelé en mode N M=X=1, DBR=0.
; Modifie : A. Préserve X, Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_alloc_bank
kernel_alloc_bank:
        lda BANK_NEXT
        cmp #BANK_POOL_END
        bcs alloc_none
        ; Réserve le bank courant et avance le compteur.
        pha                     ; sauve la valeur à retourner
        inc a                   ; A = current + 1
        sta BANK_NEXT           ; BANK_NEXT advance
        pla                     ; A = ancienne valeur (le bank alloué)
        rts
alloc_none:
        lda #$00                ; convention : 0 = no free
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
        ; ── Sauve S courant dans task_X_S, charge l'autre ──────────
        lda TASK_CUR
        bne switch_to_a

        ; current = 0 (A) → sauve dans TASK_A_S, charge TASK_B_S
        rep #$20
        tsc                     ; C = S (16-bit)
        sta TASK_A_S
        lda TASK_B_S
        tcs                     ; S = C
        sep #$20
        lda #$01
        sta TASK_CUR
        bra restore_and_return

switch_to_a:
        rep #$20
        tsc
        sta TASK_B_S
        lda TASK_A_S
        tcs
        sep #$20
        lda #$00
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
