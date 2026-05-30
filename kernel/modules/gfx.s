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
        txa                     ; A = slot
        clc
        adc #$06                ; bank SDRAM du backing store = $06 + slot
        sta GFX_BASE_HI
        ; ADR-27 Étape B2 : pose la stride GPU selon le flag compact du slot.
        ; X = slot encore valide (préservé depuis gwb_loop).
        lda f:WM_COMPACT_FLAGS,X
        cmp #WM_COMPACT_MAGIC
        bne gwb_set_default     ; flag != $A5 → stride par défaut 512
        ; Compact : byte_w = WM_TABLE[slot].W >> 1.
        phx                     ; sauve slot (X consommé par kernel_wm_offset)
        txa                     ; A = slot
        jsr kernel_wm_offset    ; X = slot*WM_ENTSZ
        lda f:WM_TABLE+WM_OFF_W,X
        sta GFX_BPL_LO
        lda f:WM_TABLE+WM_OFF_W+1,X
        sta GFX_BPL_HI
        lsr GFX_BPL_HI          ; byte_w = W >> 1 (8 bits par 2 px = 1 byte/2px)
        ror GFX_BPL_LO
        plx                     ; restore slot
        jsr kernel_gfx_set_bpl
        rts
gwb_set_default:
        ; Stride par défaut : pose bpl=0 si shadow != 0 ; sinon no-op
        ; (évite un round-trip GPU gratuit dans le cas usuel).
        lda f:GFX_BPL_SHADOW
        ora f:GFX_BPL_SHADOW+1
        beq gwb_default_done
        lda #$00
        sta GFX_BPL_LO
        sta GFX_BPL_HI
        jsr kernel_gfx_set_bpl
gwb_default_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_set_bpl — fixe la stride GPU persistante (ADR-27 opt.b)
; ════════════════════════════════════════════════════════════════════
; Args ZP : GFX_BPL_LO/HI ($89-$8A) = stride 16-bit (octets/ligne). 0 → 512.
; Effets : toutes les ops de dessin suivantes (FILL_RECT*, LINE, TEXT*, et la
;          SOURCE du BLIT) utilisent cette stride jusqu'au prochain SET_BPL.
;          Permet un backing store compact (stride = largeur fenêtre).
; ⚠️ État global GPU : repasser à 512 (GFX_BPL=0) avant tout dessin direct dans
;    le framebuffer XVGA (kernel_wm_redraw, etc.). Cf. ADR-27 §hazard.
; Modifie : A. Préserve : X, Y.
; ════════════════════════════════════════════════════════════════════
; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_set_bpl — fixe la stride GPU persistante (ADR-27 opt.b)
; ════════════════════════════════════════════════════════════════════
; Args ZP : GFX_BPL_LO/HI ($90-$91) = stride 16-bit (octets/ligne). 0 → 512.
; Effets : toutes les ops de dessin suivantes (FILL_RECT*, LINE, TEXT*, et la
;          SOURCE du BLIT) utilisent cette stride jusqu'au prochain SET_BPL.
;          Permet un backing store compact (stride = largeur fenêtre).
; ⚠️ État global GPU : repasser à 512 (GFX_BPL=0) avant tout dessin direct dans
;    le framebuffer XVGA (kernel_wm_redraw, etc.). Cf. ADR-27 §hazard.
; Pré-cond : mode N. `sep #$20` force A 8-bit (cohérent .smart + I/O 8-bit).
; Modifie : A. Préserve : X, Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_gfx_set_bpl
kernel_gfx_set_bpl:
        php                     ; OS-gpu-race : section critique GPU atomique
        sei                     ; (un mouse IRQ ne doit pas clobber ARG/CMD entre setup et trigger)
        sep #$20                ; A 8-bit (I/O ports) ; informe .smart
        lda GFX_BPL_LO
        sta GPU_ARG1_LO_IO
        sta f:GFX_BPL_SHADOW    ; ADR-27 Étape A : maintien du shadow kernel (low)
        lda GFX_BPL_HI
        sta GPU_ARG1_MID_IO
        sta f:GFX_BPL_SHADOW+1  ; ADR-27 Étape A : maintien du shadow kernel (high)
        lda #$00
        sta GPU_ARG1_HI_IO
        lda #GPU_OP_SET_BPL
        sta GPU_CMD_OP_IO
        sta GPU_TRIGGER_IO
        plp                     ; restaure I (cli si syscall, sei si IRQ)
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_finish — restaure bpl=0 si le slot du caller est compact
; ════════════════════════════════════════════════════════════════════
; ADR-27 Étape B2 point §0ter 2 : confine `byte_w` au syscall gfx.
; À appeler après tout `kernel_gfx_*` dans les wrappers `sys_gfx_*`.
; Invariant cible : `bpl = 512` hors d'un dessin backing-store compact.
; Modifie : A, X. Préserve : Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_gfx_finish
kernel_gfx_finish:
        ldx #$00
gfin_loop:
        lda f:WM_OWNER,X
        cmp TASK_CUR
        beq gfin_found
        inx
        cpx #WM_MAX
        bcc gfin_loop
        rts                     ; pas de fenêtre → rien à restaurer
gfin_found:
        lda f:WM_COMPACT_FLAGS,X
        cmp #WM_COMPACT_MAGIC
        bne gfin_done           ; non compact → bpl déjà à 0 par window_base
        ; Slot compact : on a posé bpl=byte_w au début du syscall, on remet 0.
        lda #$00
        sta GFX_BPL_LO
        sta GFX_BPL_HI
        jsr kernel_gfx_set_bpl
gfin_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_get_bpl_shadow — lit le shadow kernel de gpu->bpl
; ════════════════════════════════════════════════════════════════════
; Le GPU n'a pas de port de lecture pour bpl (ADR-27 §0bis option 4) ;
; cette routine renvoie la dernière valeur posée par kernel_gfx_set_bpl.
; Args   : aucun.
; Retour : GFX_BPL_LO/HI (ZP) ← shadow ; 0 ↔ stride par défaut (512).
; Modifie : A (8-bit). Préserve : X, Y.
; Pré-cond : entrée arbitraire (mode M libre) ; sortie en M=8.
; ════════════════════════════════════════════════════════════════════
.export kernel_gfx_get_bpl_shadow
kernel_gfx_get_bpl_shadow:
        php
        sep #$20                ; A 8-bit ; informe .smart
        lda f:GFX_BPL_SHADOW
        sta GFX_BPL_LO
        lda f:GFX_BPL_SHADOW+1
        sta GFX_BPL_HI
        plp
        rts

.export kernel_gfx_clear
kernel_gfx_clear:
        php                     ; OS-gpu-race : commande GPU atomique vs IRQ
        sei
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
        plp
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
        php                     ; OS-gpu-race : commande GPU atomique vs IRQ
        sei
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
        plp
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_blit — exec GPU BLIT via I/O (Sprint GPU-3 v0.2)
; ════════════════════════════════════════════════════════════════════
;
; Args ZP (sémantique pour BLIT) :
;   GFX_BASE_LO/MID/HI ($70-$72) = src 24-bit (SDRAM source).
;   GFX_ARG2_LO/MID/HI ($73-$75) = dst 24-bit (SDRAM destination).
;   GFX_ARG3_LO/MID    ($76-$77) = byte_w 16-bit (octets/ligne, 1..65535). ; v0.2
;   GFX_ARG4_LO/MID    ($92-$93) = byte_h 16-bit (lignes, 1..65535).       ; v0.2
; Effets : copie un bloc rectangulaire src → dst dans la SDRAM.
;          v0.2 limites HW : src/dst byte-alignés, pas d'overlap, pas
;          de transparency. BPL hardcodé GPU=512 (XVGA).
;          v0.2 sync : poll busy timeout 256.
; Modifie : A, X. Préserve : Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_gfx_blit
kernel_gfx_blit:
        php                     ; OS-gpu-race : commande GPU atomique vs IRQ
        sei
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
        ; ARG3[15:0] = byte_w, ARG4[15:0] = byte_h  (v0.2 : 16-bit)
        lda GFX_ARG3_LO
        sta GPU_ARG3_LO_IO
        lda GFX_ARG3_MID
        sta GPU_ARG3_MID_IO
        lda #$00
        sta GPU_ARG3_HI_IO
        lda GFX_ARG4_LO
        sta GPU_ARG4_LO_IO
        lda GFX_ARG4_MID
        sta GPU_ARG4_MID_IO
        lda #$00
        sta GPU_ARG4_HI_IO
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
        plp
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
        php                     ; OS-gpu-race : commande GPU atomique vs IRQ
        sei
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
        plp
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
        php                     ; OS-gpu-race : commande GPU atomique vs IRQ
        sei
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
        plp
        rts

