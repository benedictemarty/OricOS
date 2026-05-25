; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : boot.s — inclus depuis kernel.s
;
        .segment "CODE"

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
        sta TASK_C_CTR
        sta TASK_D_CTR
        sta SCHED_ACTIVE        ; scheduler pas encore démarré (g.4)
        sta FORBID_COUNT        ; g.6 : pas de section critique au boot
        sta TASK_E_KEY          ; g.5 : touche lue par task_e (init 0)
        sta KBD_WAITER          ; g.5 : aucune tâche en attente clavier
        sta IDLE_PID            ; idle : pas encore créée (0)
        sta IDLE_CTR            ; idle : compteur 0
        ; OS-2.g v2.a g.3 : 1re page de pile dynamique = $04 (page 1 = pile
        ; système/task A, page 2 = frame task B, page 3 = I/O → on saute à 4).
        lda #$04
        sta STACK_NEXT_PAGE
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

        ; ── OS-2.g v2.a g.3 : crée une 3e tâche dynamiquement ──────────
        ; Valide kernel_task_create (alloc slot+pile, forge frame) et le
        ; round-robin N-tâches. task_c → pid 3, pile page $04.
        lda #$01
        sta TC_CODE_BANK        ; tâches kernel démo → bank 1
        ldx #<task_c_entry
        ldy #>task_c_entry
        lda #$00                ; priorité 0
        jsr kernel_task_create
        ; OS-2.g v2.a g.4 : tâche éphémère task_d (pid 4) — s'incrémente une
        ; fois puis SYS_EXIT → valide le teardown + reschedule.
        ldx #<task_d_entry
        ldy #>task_d_entry
        lda #$00
        jsr kernel_task_create
        ; OS-2.g v2.b g.5 : task_e (pid 5) bloque sur SYS_READ_CHAR → valide le
        ; blocage réel + réveil par l'IRQ KBD2.
        ldx #<task_e_entry
        ldy #>task_e_entry
        lda #$00
        jsr kernel_task_create
        ; OS-2.g v2.b : tâche idle (créée en DERNIER → pid suivant). Toujours
        ; READY, dépriorisée par find_next ; fallback quand rien d'autre n'est
        ; runnable (ferme le trou « dernière tâche »). On mémorise son pid.
        ldx #<idle_entry
        ldy #>idle_entry
        lda #$07                ; priorité la plus basse (info ; find_next gère via IDLE_PID)
        jsr kernel_task_create
        sta IDLE_PID            ; A = pid alloué pour l'idle

        ; ── Sprint 2.c/2.e : install charset + clear + console init + banner ──
        jsr kernel_install_charset
        ; ── SP-3.d : upload la fonte (charset ASCII, 1024 o) en SDRAM pour le
        ;    GPU TEXT/TEXT16 (toolkit). DP_PCPTR = bank1:CHARSET_SRC. ──────
        jsr kernel_tk_font_init

        ; ── SP-3.f : upload string "X\0" en SDRAM WM_CLOSE_STR ($011080) ──
        ; Utilisé par _wm_draw_title_and_close pour le bouton fermer.
        lda #<str_close_x
        sta DP_PCPTR
        lda #>str_close_x
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2           ; bank 1 (segment CODE)
        lda #<WM_CLOSE_STR
        sta VRAM_OP_ADDR_LO
        lda #>WM_CLOSE_STR
        sta VRAM_OP_ADDR_MID
        lda #$01
        sta VRAM_OP_ADDR_HI      ; SDRAM $011080
        lda #$02                 ; len = 2 ("X" + null)
        sta VRAM_OP_LEN_LO
        lda #$00
        sta VRAM_OP_LEN_HI
        jsr kernel_vram_write_block

        ; ── SP-3.h : upload "O\0" en SDRAM WM_MAX_STR ($011090) ──────────
        lda #<str_max_o
        sta DP_PCPTR
        lda #>str_max_o
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        lda #<WM_MAX_STR
        sta VRAM_OP_ADDR_LO
        lda #>WM_MAX_STR
        sta VRAM_OP_ADDR_MID
        lda #$01
        sta VRAM_OP_ADDR_HI      ; SDRAM $011090
        lda #$02
        sta VRAM_OP_LEN_LO
        lda #$00
        sta VRAM_OP_LEN_HI
        jsr kernel_vram_write_block

        ; ── SP-3.h : upload "_\0" en SDRAM WM_MIN_STR ($0110A0) ──────────
        lda #<str_min_und
        sta DP_PCPTR
        lda #>str_min_und
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        lda #<WM_MIN_STR
        sta VRAM_OP_ADDR_LO
        lda #>WM_MIN_STR
        sta VRAM_OP_ADDR_MID
        lda #$01
        sta VRAM_OP_ADDR_HI      ; SDRAM $0110A0
        lda #$02
        sta VRAM_OP_LEN_LO
        lda #$00
        sta VRAM_OP_LEN_HI
        jsr kernel_vram_write_block

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
        ; fenêtre 0 @ (100,100, 80×60) — titre "OricOS" (SP-3.f)
        rep #$20
        lda #100
        sta WM_ARG_X
        sta WM_ARG_Y
        lda #80
        sta WM_ARG_W
        lda #60
        sta WM_ARG_H
        sep #$20
        lda #<str_win0_title     ; SP-3.f : titre fenêtre 0 = "OricOS"
        sta WM_ARG_TITLE_LO
        lda #>str_win0_title
        sta WM_ARG_TITLE_HI
        jsr kernel_wm_add
        sta WM_TEST_RES+0       ; id0 = 0
        ; fenêtre 1 @ (300,300, 80×60) — titre "Editor" (SP-3.f)
        rep #$20
        lda #300
        sta WM_ARG_X
        sta WM_ARG_Y
        lda #80
        sta WM_ARG_W
        lda #60
        sta WM_ARG_H
        sep #$20
        lda #<str_win1_title     ; SP-3.f : titre fenêtre 1 = "Editor"
        sta WM_ARG_TITLE_LO
        lda #>str_win1_title
        sta WM_ARG_TITLE_HI
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
        sta CB_FLAG                     ; v0.4 : compteur clics démo
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
        lda #0
        sta WG_CB                       ; label : pas de callback
        sep #$20
        lda #$00                        ; label noir sur corps lightgray
        sta GFX_COLOR
        lda #<tk_demo_os
        sta DP_PCPTR
        lda #>tk_demo_os
        sta DP_PCPTR+1
        jsr kernel_wm_add_widget
        ; bouton "OK" rel(6,34, 44×18), callback = demo_ok_cb
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
        lda #<demo_ok_cb                ; v0.4 : callback du bouton
        sta WG_CB
        lda #>demo_ok_cb
        sta WG_CB+1
        lda #<tk_demo_ok
        sta DP_PCPTR
        lda #>tk_demo_ok
        sta DP_PCPTR+1
        jsr kernel_wm_add_widget

        ; ── SP-3.k : icônes desktop démo (SP-3.k) ───────────────────────
        ; Icône 0 "Files" : x=20, y=20, couleur cyan (3), callback=0
        rep #$20
        lda #20
        sta WM_ARG_X
        sta WM_ARG_Y
        lda #$00
        sta WM_ARG_DX            ; callback = 0
        sep #$20
        lda #$03                 ; cyan
        sta GFX_COLOR
        lda #<str_icon_files
        sta DP_PCPTR
        lda #>str_icon_files
        sta DP_PCPTR+1
        jsr kernel_icon_add
        sta ICON_K_TEST_RES+0    ; doit être 0
        ; Icône 1 "Prefs" : x=20, y=80, couleur yellow (14), callback=0
        rep #$20
        lda #20
        sta WM_ARG_X
        lda #80
        sta WM_ARG_Y
        lda #$00
        sta WM_ARG_DX            ; callback = 0
        sep #$20
        lda #$0E                 ; yellow
        sta GFX_COLOR
        lda #<str_icon_settings
        sta DP_PCPTR
        lda #>str_icon_settings
        sta DP_PCPTR+1
        jsr kernel_icon_add
        sta ICON_K_TEST_RES+1    ; doit être 1
        ; hit-test icône 0 (clic dans zone [20..51, 20..51])
        rep #$20
        lda #30
        sta MOUSE_X
        sta MOUSE_Y
        sep #$20
        jsr _icon_hit
        sta ICON_K_TEST_RES+2    ; doit être 0
        ; hit-test hors zone → $FF
        rep #$20
        lda #200
        sta MOUSE_X
        sta MOUSE_Y
        sep #$20
        jsr _icon_hit
        sta ICON_K_TEST_RES+3    ; doit être $FF

        ; ── SP-3.h : sentinelle init (WM_STATES[0] = normal après init) ──
        ; Pas d'appel à kernel_wm_maximize ici — trop coûteux pour le boot,
        ; testé séparément dans test_oricos_boot.c (test_wm_maximize etc.).
        lda WM_STATES+0
        sta WM_H_TEST_RES+0      ; doit être $00 (normal)
        lda WM_STATES+1
        sta WM_H_TEST_RES+1      ; doit être $00 (normal)
        lda WM_STATES+2
        sta WM_H_TEST_RES+2      ; doit être $00 (normal)
        lda WM_STATES+3
        sta WM_H_TEST_RES+3      ; doit être $00 (normal)
        ; WM_H_TEST_RES+4 : réservé pour test_wm_maximize (laissé à $00)
        lda #$00
        sta WM_H_TEST_RES+4

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

        ; ── TC-poc-hello-c : exec conditionnel (TC_HELLOC_FLAG=$01EF10 == $A5) ─
        ; Le test Phosphoric pose $A5 à $01EF10 avant le boot pour activer ce
        ; chemin. Permet de valider l'exécution d'une app userland C (llvm-mos)
        ; sans perturber les tests existants (qui laissent $01EF10=$00).
        lda TC_HELLOC_FLAG
        cmp #$A5
        bne _skip_helloc
        ; Plus de pré-injection clavier : SYS_READ_CHAR se débloque via l'IRQ
        ; KBD2 réelle (le handler COP fait cli ; cf. handlers.s / sys_read_char).
        ; Le test livre la touche via le device KBD2 quand l'app bloque.
        ; Exec bundle_hello_c (bank 1, adresse absolue).
        lda #<bundle_hello_c
        sta DP_PTR
        lda #>bundle_hello_c
        sta DP_PTR+1
        lda #$01
        sta DP_PTR+2
        jsr kernel_app_exec
_skip_helloc:

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

        ; ── OS-2.g v2.b : spawn hello_c comme TÂCHE schedulée (gated) ──
        ; TC_HELLOC_TASK_FLAG=$A5 → l'app C tourne comme une vraie tâche
        ; préemptive (kernel_app_spawn), pas via JSL boot-context. Placé ICI
        ; (après l'init de l'allocateur de banks) car app_spawn → kernel_alloc_bank.
        lda TC_HELLOC_TASK_FLAG
        cmp #$A5
        bne _skip_helloc_task
        lda #<bundle_hello_c
        sta DP_PTR
        lda #>bundle_hello_c
        sta DP_PTR+1
        lda #$01
        sta DP_PTR+2
        jsr kernel_app_spawn    ; A = pid de l'app (≠0 succès)
_skip_helloc_task:

        ; ── Active interruptions et démarre task A ─────────────────
        ; g.4 : marque le scheduler actif → SYS_EXIT fait désormais teardown
        ; (et non STP). En deçà de ce point, les apps boot-context STP à l'exit.
        lda #$A5
        sta SCHED_ACTIVE
        cli                     ; I=0 → IRQ enabled
        jmp task_a_entry        ; same bank, JMP suffit

