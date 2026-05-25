; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : gfx.s — inclus depuis kernel.s
;
        .segment "CODE"

; ── kernel_gfx_window_base : GFX_BASE ← backing store de la fenêtre du caller ──
; SP-3.m G.4. Cherche le slot possédé par TASK_CUR (WM_OWNER) et pose GFX_BASE
; = ($06+slot):$0000 (backing store SDRAM implicite par slot, cf. G.2). Les apps
; dessinent ainsi en coords LOCALES dans leur fenêtre, sans connaître l'adresse
; XVGA. Si la tâche ne possède pas de fenêtre → GFX_BASE inchangé (no-op).
; Pré-cond : mode N M=X=1. Clobbers A, X.
.export kernel_gfx_window_base
kernel_gfx_window_base:
        ldx #$00
gwb_loop:
        lda f:WM_OWNER,X
        cmp TASK_CUR            ; (cmp abs-long ; pas de scratch)
        beq gwb_found
        inx
        cpx #WM_MAX
        bcc gwb_loop
        rts                     ; pas de fenêtre → GFX_BASE inchangé
gwb_found:
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        txa
        clc
        adc #$06                ; bank SDRAM du backing store = $06 + slot
        sta GFX_BASE_HI
        rts

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

