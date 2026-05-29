; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : tk.s — inclus depuis kernel.s
;
        .segment "CODE"

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

; ── kernel_tk_text_field : champ texte éditable (SP-3.o S.4b) ────────────────
; In : WM_ARG_X/Y/W/H = rect ABSOLU, DP_PCPTR = buffer (bank1, null-term, posé par
; _wdws_draw), WG_I = index widget. Dessine face blanche + cadre + texte noir +
; un curseur (barre noire) après le texte si ce champ a le focus (TEXT_FOCUS_ID).
.export kernel_tk_text_field
kernel_tk_text_field:
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
        ; 1. face blanche
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #$0F
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; 2. cadre darkgray
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
        lda #$08
        sta GFX_COLOR
        jsr kernel_tk_frame
        ; 3. texte (buffer via DP_PCPTR) noir à (x+4, y+2)
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
        lda #$00
        sta GFX_COLOR
        jsr kernel_tk_label
        ; 4. curseur si focalisé
        lda WG_I
        cmp TEXT_FOCUS_ID
        bne _tktf_done
        lda WG_I
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+14,X    ; length (0..15)
        rep #$20
        and #$00FF
        asl a                    ; *8 (largeur fonte)
        asl a
        asl a
        clc
        adc TK_X
        clc
        adc #4
        sta WM_ARG_X             ; curseur_x = x + 4 + length*8
        lda TK_Y
        clc
        adc #2
        sta WM_ARG_Y
        lda #2
        sta WM_ARG_W             ; curseur 2px de large
        lda TK_H
        sec
        sbc #4
        sta WM_ARG_H
        sep #$20
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #$00
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
_tktf_done:
        rts

; ── kernel_tk_list : liste d'items (SP-3.o S.4c) ─────────────────────────────
; In : WM_ARG_X/Y/W/H = rect ABSOLU, DP_PCPTR = blob d'items (bank1, slots de
; LIST_ITEM_STRIDE octets null-term posé par _wdws_draw), WG_I = index widget
; (relit count en +15, selected en +14). Face lightgray + cadre + 1 ligne par
; item ; la ligne sélectionnée a un fond lightblue. Item i en y = TK_Y + i*16.
; Scratch : TEXT_TMP_LEN = i, TEXT_TMP_MAX = count, WG_RELW = i*8 (16-bit).
.export kernel_tk_list
kernel_tk_list:
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
        ; 1. face lightgray
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #$07
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; 2. cadre darkgray
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
        lda #$08
        sta GFX_COLOR
        jsr kernel_tk_frame
        ; 3. count + boucle items
        lda WG_I
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+15,X    ; count
        sta TEXT_TMP_MAX
        lda #$00
        sta TEXT_TMP_LEN         ; i = 0
_tkl_loop:
        lda TEXT_TMP_LEN
        cmp TEXT_TMP_MAX
        bcc _tkl_go
        rts
_tkl_go:
        ; highlight si i == selected
        lda WG_I
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+14,X    ; selected
        cmp TEXT_TMP_LEN
        bne _tkl_text
        rep #$20
        lda TEXT_TMP_LEN
        and #$00FF
        asl a                    ; i*16
        asl a
        asl a
        asl a
        clc
        adc TK_Y
        sta WM_ARG_Y             ; item_y
        lda TK_X
        inc a
        sta WM_ARG_X             ; x+1
        lda TK_W
        dec a
        dec a
        sta WM_ARG_W             ; w-2
        lda #LIST_ITEM_H
        sta WM_ARG_H
        sep #$20
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #$09
        sta GFX_COLOR            ; lightblue highlight
        jsr kernel_gfx_fill_rect16
_tkl_text:
        ; DP_PCPTR = blob + i*LIST_ITEM_STRIDE
        lda WG_I
        asl a
        asl a
        asl a
        asl a
        tax
        rep #$20
        lda TEXT_TMP_LEN
        and #$00FF
        asl a                    ; i*8
        asl a
        asl a
        sta WG_RELW              ; temp
        lda WIDGET_TABLE+12,X    ; strptr (blob base, 16-bit)
        clc
        adc WG_RELW
        sta DP_PCPTR             ; item ptr lo/hi
        sep #$20
        lda #$01
        sta DP_PCPTR+2
        ; position texte : x = TK_X+4, y = TK_Y + i*16 + 2
        rep #$20
        lda TEXT_TMP_LEN
        and #$00FF
        asl a
        asl a
        asl a
        asl a                    ; i*16
        clc
        adc TK_Y
        clc
        adc #2
        sta WM_ARG_Y
        lda TK_X
        clc
        adc #4
        sta WM_ARG_X
        sep #$20
        lda #$00
        sta GFX_COLOR            ; texte noir
        jsr kernel_tk_label
        ; i++
        lda TEXT_TMP_LEN
        inc a
        sta TEXT_TMP_LEN
        jmp _tkl_loop

; ── kernel_wm_add_widget : enregistre un widget managé (SP-3.d v0.2) ───
; Args : WG_PARENT (id fenêtre), WG_TYPE (0=label,1=button),
;        WM_ARG_X/Y/W/H (rect RELATIF à la fenêtre), GFX_COLOR (label),
;        DP_PCPTR lo/hi (offset chaîne bank1). Append à WIDGET_COUNT.
.export kernel_wm_add_widget
kernel_wm_add_widget:
        lda WIDGET_COUNT
        cmp #WIDGET_MAX
        bcc _waw_ok
        rts                      ; table pleine
_waw_ok:
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
        lda WG_CB                ; v0.4 : callback (offset bank1, 0=aucun)
        sta WIDGET_TABLE+14,X
        lda WG_CB+1
        sta WIDGET_TABLE+15,X
        ; SP-3.o S.4b : champ texte → câble son buffer (TEXT_BUFS + offset widget,
        ; car TEXT_BUF_SZ == WIDGET_ENTSZ == 16) et l'initialise vide (length 0).
        ; +15 (maxlen) reste ce que l'appelant a mis dans WG_CB+1.
        lda WG_TYPE
        cmp #WG_TYPE_TEXT
        bne _waw_count
        txa                      ; X = offset widget = offset buffer
        clc
        adc #<TEXT_BUFS
        sta WIDGET_TABLE+12,X    ; strptr lo = TEXT_BUFS + offset
        lda #$00
        adc #>TEXT_BUFS
        sta WIDGET_TABLE+13,X    ; strptr hi
        lda #$00
        sta WIDGET_TABLE+14,X    ; length = 0
        sta f:TEXT_BUFS,X        ; buffer[0] = 0 (chaîne vide)
_waw_count:
        ; ADR-29 Étape 2 : pose le hint en attente sur ce widget puis reset.
        ; Si aucun GU_HINT_IMMEDIATE_DRAG_NOTIFY n'a précédé, UI_PENDING_HINT = 0
        ; (= HINT_DRAG_DELAYED), default sûr aligné GeoWorks.
        lda WIDGET_COUNT        ; id du widget nouvellement créé
        tax                     ; X = id (1 byte)
        lda UI_PENDING_HINT
        sta f:WIDGET_HINTS,X    ; abs-long (WIDGET_HINTS > $FFFF)
        lda #$00
        sta UI_PENDING_HINT     ; reset pour le prochain widget
        lda WIDGET_COUNT
        inc a
        sta WIDGET_COUNT
_waw_full:
        rts

; ── _wm_draw_widgets_for_slot : dessine uniquement les widgets dont le parent
;    est le slot passé en A. Appelé par wm_rd_loop pour chaque fenêtre → z-order
;    correct (les fenêtres suivantes couvrent les widgets des fenêtres précédentes).
;    Modifie A, X, Y. Préserve rien (appelant sauve Y via phy/ply).
_wm_draw_widgets_for_slot:
        sta WM_DP_TMP           ; WM_DP_TMP = slot cible (1B utilisé)
        sta WIN_SLOT            ; WIN_SLOT = slot cible (stable, non clobbé par kernel_wm_offset)
        lda #$00
        sta WG_I
_wdws_loop:
        lda WG_I
        cmp WIDGET_COUNT
        bcc _wdws_go
        jmp _wdws_done
_wdws_go:
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+0,X
        and #$01
        bne _wdws_check_parent
        jmp _wdws_next          ; slot libre
_wdws_check_parent:
        lda WIDGET_TABLE+1,X    ; parent slot
        cmp WIN_SLOT            ; == slot cible ? (WIN_SLOT stable, WM_DP_TMP serait écrasé par kernel_wm_offset)
        beq _wdws_draw
        jmp _wdws_next
_wdws_draw:
        jsr _wm_draw_widget_body   ; dessine ce widget (X = offset, WG_I/WIN_SLOT posés)
        jmp _wdws_next

; ── kernel_wm_redraw_widget : redraw CIBLÉ d'un seul widget (A = index) ───────
; (SP-3.o S.7) Ne touche QUE la zone du contrôle (pas de clear desktop) → évite
; le scintillement plein écran pendant le drag d'ascenseur / les maj de valeur.
; Le contrôle (scrollbar/view/checkbox…) repeint entièrement sa propre zone.
.export kernel_wm_redraw_widget
kernel_wm_redraw_widget:
        sta WG_I
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+0,X
        and #$01
        beq _wrw_done           ; slot libre → rien
        lda WIDGET_TABLE+1,X
        sta WIN_SLOT
        jsr _wm_draw_widget_body
_wrw_done:
        rts

; ── _wm_draw_widget_body : dessine le widget d'offset X (WG_I/WIN_SLOT posés) ──
; Lit type/couleur/rect rel/strptr, calcule la position absolue, puis dispatch
; vers le rendu du type. Chaque handler se termine par rts. Clobbe A,X,Y,WG_*.
_wm_draw_widget_body:
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
        ; coords absolues = win.xy + rel.xy
        lda WIN_SLOT            ; WIN_SLOT stable (WM_DP_TMP écrasé par kernel_wm_offset)
        jsr kernel_wm_offset    ; X = slot*10
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
        beq _wdws_label          ; 0 = label
        cmp #WG_TYPE_LIST        ; 8 = liste (GenList)
        beq _wdws_list
        cmp #WG_TYPE_TEXT        ; 7 = champ texte éditable
        beq _wdws_text
        cmp #WG_TYPE_RADIO       ; 6 = radio → case colorée (comme checkbox)
        beq _wdws_btn
        cmp #WG_TYPE_VIEW        ; 5 = GenView
        beq _wdws_view
        cmp #WG_TYPE_SCROLL_V    ; 3/4 → ascenseur (SCROLL_V/H)
        bcs _wdws_scroll
        bra _wdws_btn            ; 1 = bouton, 2 = checkbox (dessiné en bouton coloré)
_wdws_label:
        jsr kernel_tk_label
        rts
_wdws_text:
        jsr kernel_tk_text_field ; SP-3.o S.4b : boîte + texte + curseur si focus
        rts
_wdws_list:
        jsr kernel_tk_list       ; SP-3.o S.4c : boîte + items + ligne sélectionnée
        rts
_wdws_scroll:
        jsr kernel_tk_scrollbar  ; SP-3.o S.2 : gouttière + thumb
        rts
_wdws_view:
        jsr kernel_tk_view       ; SP-3.o S.3 : viewport + scrollbar intégré
        rts
_wdws_btn:
        lda WG_I
        cmp WIDGET_ACTIVE
        bne _wdws_btn_normal
        lda #$01
        sta TK_BTN_PRESSED
        bra _wdws_btn_draw
_wdws_btn_normal:
        lda #$00
        sta TK_BTN_PRESSED
_wdws_btn_draw:
        jsr kernel_tk_button
        rts
_wdws_next:
        lda WG_I
        inc a
        sta WG_I
        jmp _wdws_loop
_wdws_done:
        rts

; ── kernel_tk_scrollbar : dessine un ascenseur (SP-3.o S.2) ──────────────────
; In : WM_ARG_X/Y/W/H = rect ABSOLU de la gouttière, WG_TYPE = orientation
; (SCROLL_V/H), WG_I = index widget (pour relire value en +14). Dessine la
; gouttière (track color) puis le thumb (position = value le long de la gouttière)
; sur le framebuffer XVGA ($100000). Clobbe A, X, temps TK_*/DP_TMP.
kernel_tk_scrollbar:
        ; sauve le rect gouttière
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
        ; 1. gouttière (rect complet, couleur track)
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI          ; base = framebuffer XVGA $100000
        lda #WG_COL_TRACK
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; 2. thumb : relit value (+14) du widget WG_I
        lda WG_I
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+WG_OFF_VALUE,x
        sta TK_BTN_PRESSED       ; réutilise comme temp « offset value » (1B)
        lda WG_TYPE
        cmp #WG_TYPE_SCROLL_H
        beq _tks_h
        ; vertical : thumb (TK_X, TK_Y+value, TK_W, THUMB_SZ)
        rep #$20
        lda TK_X
        sta WM_ARG_X
        lda TK_BTN_PRESSED
        and #$00FF
        clc
        adc TK_Y
        sta WM_ARG_Y
        lda TK_W
        sta WM_ARG_W
        lda #SCROLL_THUMB_SZ
        sta WM_ARG_H
        sep #$20
        bra _tks_fill
_tks_h:
        ; horizontal : thumb (TK_X+value, TK_Y, THUMB_SZ, TK_H)
        rep #$20
        lda TK_BTN_PRESSED
        and #$00FF
        clc
        adc TK_X
        sta WM_ARG_X
        lda TK_Y
        sta WM_ARG_Y
        lda #SCROLL_THUMB_SZ
        sta WM_ARG_W
        lda TK_H
        sta WM_ARG_H
        sep #$20
_tks_fill:
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #WG_COL_THUMB
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        rts

; ── kernel_tk_view : dessine un GenView (SP-3.o S.3) ─────────────────────────
; In : WM_ARG = rect ABSOLU du viewport, WG_I = index widget (scroll_y en +14).
; Dessine : corps (lightgray, largeur W-VIEW_SB_W) + barre intégrée bord droit
; (gouttière darkgray + thumb blanc à Y+scroll_y). L'app peint son contenu par
; dessus. Clobbe A, X, temps TK_*.
kernel_tk_view:
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
        ; 1. corps (X, Y, W-VIEW_SB_W, H)
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        rep #$20
        lda TK_X
        sta WM_ARG_X
        lda TK_Y
        sta WM_ARG_Y
        lda TK_W
        sec
        sbc #VIEW_SB_W
        sta WM_ARG_W
        lda TK_H
        sta WM_ARG_H
        sep #$20
        lda #WG_COL_VIEW_BODY
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; 2. gouttière (X+W-VIEW_SB_W, Y, VIEW_SB_W, H)
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        rep #$20
        lda TK_X
        clc
        adc TK_W
        sec
        sbc #VIEW_SB_W
        sta WM_ARG_X
        lda TK_Y
        sta WM_ARG_Y
        lda #VIEW_SB_W
        sta WM_ARG_W
        lda TK_H
        sta WM_ARG_H
        sep #$20
        lda #WG_COL_TRACK
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; 3. thumb (X+W-VIEW_SB_W, Y+scroll_y, VIEW_SB_W, THUMB_SZ)
        lda WG_I
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+WG_OFF_VALUE,x   ; scroll_y (clampé par le drag, 8-bit)
        sta TK_BTN_PRESSED                 ; temp
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        rep #$20
        lda TK_X
        clc
        adc TK_W
        sec
        sbc #VIEW_SB_W
        sta WM_ARG_X
        lda TK_BTN_PRESSED
        and #$00FF
        clc
        adc TK_Y
        sta WM_ARG_Y
        lda #VIEW_SB_W
        sta WM_ARG_W
        lda #SCROLL_THUMB_SZ
        sta WM_ARG_H
        sep #$20
        lda #WG_COL_THUMB
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        rts

; ════════════════════════════════════════════════════════════════════
;  SP-3.d v0.6 — Barre de menu déroulant table-driven (N menus)
; ════════════════════════════════════════════════════════════════════

; ── _menu_setbase : DP_PCPTR = menu_defs + MENU_I*16, bank $01. ───────
_menu_setbase:
        lda MENU_I
        asl a
        asl a
        asl a
        asl a                    ; MENU_I*16 (≤ (N-1)*16)
        clc
        adc #<menu_defs
        sta DP_PCPTR
        lda #>menu_defs
        adc #$00
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        rts

; ── kernel_menu_draw : barre (titres des N menus) + dropdown si ouvert ─
.export kernel_menu_draw
kernel_menu_draw:
        ; barre (0,0,1024,14) darkgray
        rep #$20
        lda #0
        sta WM_ARG_X
        sta WM_ARG_Y
        lda #1024
        sta WM_ARG_W
        lda #MENU_BAR_H
        sta WM_ARG_H
        sep #$20
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #$08
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; titres
        lda #$00
        sta MENU_I
_mdl_title:
        lda MENU_I
        cmp #MENU_N
        bcs _mdl_drop
        jsr _menu_setbase
        ldy #2
        lda [DP_PCPTR],Y         ; bar_x
        rep #$20
        and #$00FF
        sta WM_ARG_X
        lda #3
        sta WM_ARG_Y
        sep #$20
        ldy #0
        lda [DP_PCPTR],Y         ; title ptr lo
        pha
        ldy #1
        lda [DP_PCPTR],Y         ; title ptr hi
        sta DP_PCPTR+1
        pla
        sta DP_PCPTR             ; (DP_PCPTR+2 reste $01)
        lda #$0F
        sta GFX_COLOR
        jsr kernel_tk_label
        lda MENU_I
        inc a
        sta MENU_I
        bra _mdl_title
_mdl_drop:
        lda MENU_OPEN
        cmp #$FF
        bne _mdl_open
        jmp kernel_taskbar_draw  ; SP-3.g : taskbar en dernier
_mdl_open:
        sta MENU_I
        jsr _menu_setbase
        ; lit bar_x → WG_RELX, item0 ptr → WG_RELY, item1 ptr → WG_RELW
        ldy #2
        lda [DP_PCPTR],Y
        rep #$20
        and #$00FF
        sta WG_RELX
        sep #$20
        ldy #4
        lda [DP_PCPTR],Y
        sta WG_RELY
        ldy #5
        lda [DP_PCPTR],Y
        sta WG_RELY+1
        ldy #8
        lda [DP_PCPTR],Y
        sta WG_RELW
        ldy #9
        lda [DP_PCPTR],Y
        sta WG_RELW+1
        ; fond dropdown (bar_x,14,64,24) lightgray
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        rep #$20
        lda WG_RELX
        sta WM_ARG_X
        lda #MENU_BAR_H
        sta WM_ARG_Y
        lda #64
        sta WM_ARG_W
        lda #24
        sta WM_ARG_H
        sep #$20
        lda #$07
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        rep #$20
        lda WG_RELX
        sta WM_ARG_X
        lda #MENU_BAR_H
        sta WM_ARG_Y
        lda #64
        sta WM_ARG_W
        lda #24
        sta WM_ARG_H
        sep #$20
        lda #$0F
        sta GFX_COLOR
        jsr kernel_tk_frame
        ; item0 (bar_x+4, 16) noir
        rep #$20
        lda WG_RELX
        clc
        adc #4
        sta WM_ARG_X
        lda #16
        sta WM_ARG_Y
        sep #$20
        lda #$00
        sta GFX_COLOR
        lda WG_RELY
        sta DP_PCPTR
        lda WG_RELY+1
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_tk_label
        ; item1 (bar_x+4, 26) noir
        rep #$20
        lda WG_RELX
        clc
        adc #4
        sta WM_ARG_X
        lda #26
        sta WM_ARG_Y
        sep #$20
        lda #$00
        sta GFX_COLOR
        lda WG_RELW
        sta DP_PCPTR
        lda WG_RELW+1
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_tk_label
        jmp kernel_taskbar_draw  ; SP-3.g : taskbar en dernier (après dropdown)

; ── kernel_menu_handle_click : ouvre/ferme + invoque l'item. ──────────
; Lit MOUSE_X/Y. A=1 si consommé, A=0 sinon. (SP-3.d v0.6, table-driven)
.export kernel_menu_handle_click
kernel_menu_handle_click:
        lda MENU_OPEN
        cmp #$FF
        bne _mhc_isopen
        ; fermé : clic dans la barre (y<14) ?
        rep #$20
        lda MOUSE_Y
        cmp #MENU_BAR_H
        sep #$20
        bcc _mhc_inbar
        lda #$00
        rts
_mhc_inbar:
        ; quel titre ? (x dans [bar_x, bar_x+64) pour un menu)
        lda #$00
        sta MENU_I
_mhc_tl:
        lda MENU_I
        cmp #MENU_N
        bcc _mhc_tl_go
        lda #$01                 ; barre vide → consommé
        rts
_mhc_tl_go:
        jsr _menu_setbase
        ldy #2
        lda [DP_PCPTR],Y
        rep #$20
        and #$00FF
        sta WG_RELX              ; bar_x
        lda MOUSE_X
        cmp WG_RELX
        bcc _mhc_tl_next
        lda WG_RELX
        clc
        adc #64
        sta WG_RELW
        lda MOUSE_X
        cmp WG_RELW
        bcs _mhc_tl_next
        sep #$20                 ; HIT titre MENU_I → ouvrir
        lda MENU_I
        sta MENU_OPEN
        lda #$01
        rts
_mhc_tl_next:
        sep #$20
        lda MENU_I
        inc a
        sta MENU_I
        bra _mhc_tl
_mhc_isopen:
        sta MENU_I
        jsr _menu_setbase
        ldy #2
        lda [DP_PCPTR],Y
        rep #$20
        and #$00FF
        sta WG_RELX              ; bar_x du menu ouvert
        lda MOUSE_X
        cmp WG_RELX
        bcc _mhc_close
        lda WG_RELX
        clc
        adc #64
        sta WG_RELW
        lda MOUSE_X
        cmp WG_RELW
        bcs _mhc_close
        lda MOUSE_Y
        cmp #MENU_BAR_H
        bcc _mhc_close
        cmp #38
        bcs _mhc_close
        ; item0 (y<26) ou item1
        lda MOUSE_Y
        cmp #26
        sep #$20
        bcs _mhc_it1
        ldy #6                   ; item0 callback
        lda [DP_PCPTR],Y
        sta WG_CB_VEC
        ldy #7
        lda [DP_PCPTR],Y
        sta WG_CB_VEC+1
        bra _mhc_invoke
_mhc_it1:
        ldy #10                  ; item1 callback
        lda [DP_PCPTR],Y
        sta WG_CB_VEC
        ldy #11
        lda [DP_PCPTR],Y
        sta WG_CB_VEC+1
_mhc_invoke:
        lda #$FF
        sta MENU_OPEN            ; ferme
        lda WG_CB_VEC
        ora WG_CB_VEC+1
        beq _mhc_consumed
        ldx #$00
        jsr (.loword(WG_CB_VEC),X)
_mhc_consumed:
        lda #$01
        rts
_mhc_close:
        sep #$20
        lda #$FF
        sta MENU_OPEN
        lda #$01
        rts

; callbacks démo des menus
menu_about_cb:
        lda #$AA
        sta CB_FLAG
        rts
menu_clear_cb:
        lda #$00
        sta CB_FLAG
        rts
menu_tile_cb:
        lda #$11
        sta CB_FLAG
        rts
menu_hide_cb:
        lda #$22
        sta CB_FLAG
        rts

; ── menu_defs : table statique (bank1), MENU_N entrées de 16 octets ────
; +0 title_ptr +2 bar_x +3 pad +4 item0_str +6 item0_cb +8 item1_str
; +10 item1_cb +12 pad
menu_defs:
        .word menu_t_system      ; menu 0 "System"
        .byte 4, 0
        .word menu_i_about
        .word menu_about_cb
        .word menu_i_clear
        .word menu_clear_cb
        .res 4
        .word menu_t_view        ; menu 1 "View"
        .byte 76, 0
        .word menu_i_tile
        .word menu_tile_cb
        .word menu_i_hide
        .word menu_hide_cb
        .res 4

menu_t_system:
        .byte "System", $00
menu_i_about:
        .byte "About", $00
menu_i_clear:
        .byte "Clear", $00
menu_t_view:
        .byte "View", $00
menu_i_tile:
        .byte "Tile", $00
menu_i_hide:
        .byte "Hide", $00

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
        cmp #WG_TYPE_CHECK       ; SP-3.o S.1 : checkbox cliquable
        beq _wh_isbtn
        cmp #WG_TYPE_SCROLL_V    ; SP-3.o S.2 : ascenseurs cliquables
        beq _wh_isbtn
        cmp #WG_TYPE_SCROLL_H
        beq _wh_isbtn
        cmp #WG_TYPE_VIEW        ; SP-3.o S.3 : GenView cliquable (barre intégrée)
        beq _wh_isbtn
        cmp #WG_TYPE_RADIO       ; SP-3.o S.4a : radio cliquable
        beq _wh_isbtn
        cmp #WG_TYPE_TEXT        ; SP-3.o S.4b : champ texte cliquable (prend le focus)
        beq _wh_isbtn
        cmp #WG_TYPE_LIST        ; SP-3.o S.4c : liste cliquable (sélection d'item)
        beq _wh_isbtn
        jmp _wh_next             ; label → non cliquable
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
