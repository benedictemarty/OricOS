; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : wm.s — inclus depuis kernel.s
;
        .segment "CODE"

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
        sta WM_ZORDER_N          ; SP-3.R S4 : table Z-order vide
        sta WIDGET_COUNT         ; SP-3.d v0.2 : aucune widget au départ
        lda #$FF
        sta WM_FOCUS
        sta WIDGET_ACTIVE        ; SP-3.d v0.3 : aucun bouton actif
        lda #$FF
        sta MENU_OPEN            ; SP-3.d v0.5 : menu fermé ($FF)
        ; SP-3.f : vide la table des flags de titres (WM_MAX=8 × 1B = $00)
        lda #$00
        sta WM_TITLES+0
        sta WM_TITLES+1
        sta WM_TITLES+2
        sta WM_TITLES+3
        sta WM_TITLES+4
        sta WM_TITLES+5
        sta WM_TITLES+6
        sta WM_TITLES+7
        ; SP-3.h : init WM_STATES (8 × 1B = normal) et WM_SAVED_RECTS (8 × 8B = 0)
        sta WM_STATES+0
        sta WM_STATES+1
        sta WM_STATES+2
        sta WM_STATES+3
        sta WM_STATES+4
        sta WM_STATES+5
        sta WM_STATES+6
        sta WM_STATES+7
        ; SP-3.i : init WM_RESIZE_ARMED / WM_RESIZE_EDGE à 0
        sta WM_RESIZE_ARMED
        sta WM_RESIZE_EDGE
        ; SP-3.j : init WM_MODAL à $FF (aucune fenêtre modale)
        lda #$FF
        sta WM_MODAL
        ; SP-3.k : init ICON_COUNT=0, ICON_SELECTED=$FF, table libre
        lda #$00
        sta f:ICON_COUNT
        sta f:ICON_TABLE + 0*ICON_ENTSZ + ICON_OFF_FLAGS
        sta f:ICON_TABLE + 1*ICON_ENTSZ + ICON_OFF_FLAGS
        sta f:ICON_TABLE + 2*ICON_ENTSZ + ICON_OFF_FLAGS
        sta f:ICON_TABLE + 3*ICON_ENTSZ + ICON_OFF_FLAGS
        lda #$FF
        sta f:ICON_SELECTED
        lda #$00
        ldx #$00
wm_init_sr:
        sta WM_SAVED_RECTS,X
        inx
        cpx #64                  ; 8 × 8B (WM_MAX=8)
        bcc wm_init_sr
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

; ── kernel_wm_add : args WM_ARG_X/Y/W/H (16-bit), WM_ARG_TITLE_LO/HI → A = id ou $FF ────
; SP-3.f : WM_ARG_TITLE_LO/HI = pointer 16-bit vers chaîne titre en bank 1 ($0000 = pas de titre).
.export kernel_wm_add
kernel_wm_add:
        lda WM_COUNT
        cmp #WM_MAX
        bcc wm_add_scan_start
        jmp wm_add_full
wm_add_scan_start:
        ; Cherche le premier slot libre (WM_F_USED=0) pour éviter les trous.
        lda #$00
wm_add_scan:
        pha
        jsr kernel_wm_offset     ; X = id*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #WM_F_USED
        bne wm_add_scan_next     ; occupé → suivant
        pla
        sta DP_TMP               ; id = premier slot libre
        jsr kernel_wm_offset     ; X = id*10
        bra wm_add_init
wm_add_scan_next:
        pla
        inc a
        cmp #WM_MAX
        bcc wm_add_scan
        jmp wm_add_full          ; (ne devrait pas arriver si WM_COUNT < WM_MAX)
wm_add_init:
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
        ; SP-3.f : si titre fourni, uploader en SDRAM $012000+slot*$100, set flag.
        ; WM_ARG_TITLE_LO/HI = 0 → pas de titre. != 0 → upload (hors IRQ = safe).
        lda WM_ARG_TITLE_LO
        ora WM_ARG_TITLE_HI
        beq wm_add_notitle       ; pas de titre → flag = 0
        ; Upload du titre (bank 1) vers SDRAM $012000 + id*$100.
        ; DP_PCPTR = pointer titre (bank 1)
        lda WM_ARG_TITLE_LO
        sta DP_PCPTR
        lda WM_ARG_TITLE_HI
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2           ; bank 1
        ; SDRAM addr : LO=$00, MID=$20+id, HI=$01 → $012000+id*$100
        lda #$00
        sta VRAM_OP_ADDR_LO
        lda DP_TMP               ; id
        clc
        adc #WM_SDRAM_TITLE_BASE_MID ; $20 + id = $20/$21/$22/$23
        sta VRAM_OP_ADDR_MID
        lda #$01
        sta VRAM_OP_ADDR_HI      ; bank $01 SDRAM
        lda #24                  ; max 24 chars + null (tronqué si plus long)
        sta VRAM_OP_LEN_LO
        lda #$00
        sta VRAM_OP_LEN_HI
        jsr kernel_vram_write_block
        ; Set flag titre = $01 (présent)
        ldx DP_TMP               ; id
        lda #$01
        sta WM_TITLES,X
        bra wm_add_done
wm_add_notitle:
        ldx DP_TMP               ; id
        lda #$00
        sta WM_TITLES,X          ; flag = $00 (pas de titre)
wm_add_done:
        ; SP-3.R S4 : ajouter le slot en fin de WM_ZORDER (au premier plan).
        lda WM_ZORDER_N
        tax
        lda DP_TMP               ; slot id
        sta f:WM_ZORDER,X        ; ZORDER[N] = nouveau slot (long,X)
        lda WM_ZORDER_N
        inc a
        sta WM_ZORDER_N
        lda WM_COUNT
        inc a
        sta WM_COUNT
        lda DP_TMP               ; retourne id
        rts
wm_add_full:
        lda #$FF
        rts

; ── kernel_wm_hit_test : args WM_ARG_X/Y (point) → A = id topmost ou $FF
; SP-3.R S4 : scan dans l'ordre WM_ZORDER (fond→sommet) ; dernier hit = topmost.
; Y = index ZORDER (préservé par kernel_wm_offset). tyx → X temporaire pour lda f:WM_ZORDER,X.
.export kernel_wm_hit_test
kernel_wm_hit_test:
        lda WM_ZORDER_N
        sta WM_ZN_CACHE          ; CPY/CPX ne font pas le mode long 24-bit
        lda #$FF
        sta DP_TMP               ; résultat
        ldy #$00
wm_ht_loop:
        cpy WM_ZN_CACHE
        bcs wm_ht_done
        tyx                      ; X = Y (index ZORDER) pour lda long,X (long,Y inexistant)
        lda f:WM_ZORDER,X        ; A = slot id
        jsr kernel_wm_offset     ; A=id → X = id*10 (Y préservé)
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
        tyx                      ; X = Y pour lire le slot id
        lda f:WM_ZORDER,X
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
; SP-3.R S4 : déplace aussi le slot au sommet de WM_ZORDER.
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
        ; SP-3.R S4 : remonter le slot au sommet du Z-order.
        ; Cherche DP_TMP dans ZORDER[0..N-1], le retire, le réinsère en fin.
        ; Y = index boucle (long,Y inexistant → tyx avant chaque accès WM_ZORDER).
        lda WM_ZORDER_N
        sta WM_ZN_CACHE          ; CPY ne fait pas le mode long 24-bit
        ldy #$00
wm_sf_zord_find:
        cpy WM_ZN_CACHE
        bcs wm_sf_zord_done      ; pas trouvé → déjà au sommet ou absent
        tyx
        lda f:WM_ZORDER,X
        cmp DP_TMP
        beq wm_sf_zord_found
        iny
        bra wm_sf_zord_find
wm_sf_zord_found:
        ; Y = index trouvé. Décaler ZORDER[Y+1..N-1] → ZORDER[Y..N-2].
        phy                      ; sauve index
wm_sf_zord_shift:
        iny
        cpy WM_ZN_CACHE
        bcs wm_sf_zord_shift_done
        tyx                      ; X = Y (index suivant)
        lda f:WM_ZORDER,X        ; ZORDER[Y]
        dey
        tyx                      ; X = Y-1 (index précédent)
        sta f:WM_ZORDER,X
        iny
        bra wm_sf_zord_shift
wm_sf_zord_shift_done:
        ply                      ; index original (dépile)
        ; Insérer en fin : ZORDER[N-1] = DP_TMP
        lda WM_ZORDER_N
        dec a
        tax
        lda DP_TMP
        sta f:WM_ZORDER,X
wm_sf_zord_done:
        rts

; ── kernel_wm_move_focused : args WM_ARG_DX/DY (signé 16-bit) ───────
; SP-3.h : skip si la fenêtre focus est maximisée (WM_STATE_MAXED).
.export kernel_wm_move_focused
kernel_wm_move_focused:
        lda WM_FOCUS
        cmp #$FF
        beq wm_mv_done
        ; SP-3.h : skip le drag si fenêtre maximisée
        tax
        lda WM_STATES,X
        cmp #WM_STATE_MAXED
        beq wm_mv_done           ; maximisée → pas de déplacement
        lda WM_FOCUS
        jsr kernel_wm_offset     ; X = focus*10
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        clc
        adc WM_ARG_DX
        bpl wm_mv_x_pos          ; résultat >= 0 → pas de wrap négatif
        lda #$0000               ; clamp bord gauche
        bra wm_mv_x_ok
wm_mv_x_pos:
        ; clamp bord droit : x <= 1024 - w
        pha
        lda #1024
        sec
        sbc WM_TABLE+WM_OFF_W,X  ; max_x = 1024 - w
        sta WM_CRH_TMP           ; sauve max_x (2B, WM_CRH_TMP=$25)
        pla
        cmp WM_CRH_TMP           ; x > max_x ?
        bcc wm_mv_x_ok           ; non → ok
        beq wm_mv_x_ok
        lda WM_CRH_TMP           ; clamp bord droit
wm_mv_x_ok:
        sta WM_TABLE+WM_OFF_X,X
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc WM_ARG_DY
        bpl wm_mv_y_pos          ; résultat >= 0 ?
        lda #MENU_BAR_H          ; négatif → clamp au bord haut
        bra wm_mv_y_ok
wm_mv_y_pos:
        cmp #MENU_BAR_H          ; y < barre de menu ?
        bcs wm_mv_y_ok
        lda #MENU_BAR_H          ; clamp au bord haut
wm_mv_y_ok:
        sta WM_TABLE+WM_OFF_Y,X
        sep #$20
wm_mv_done:
        rts

; ── kernel_wm_close : ferme une fenêtre (SP-3.f v0.2) ─────────────────
; A = id de la fenêtre à fermer. Retire le slot (flags=0) et met à jour
; WM_COUNT, WM_FOCUS, WM_TITLES[slot].
; Note v1 : pas de compaction de table — les slots restent en place,
; WM_COUNT décrémenté. Hit-test/redraw sautent les slots sans WM_F_USED.
; Modifie A, X.
.export kernel_wm_close
kernel_wm_close:
        cmp #WM_MAX              ; id >= WM_MAX ? → ignore
        bcc wm_close_go
        jmp wm_close_done
wm_close_go:
        sta DP_TMP               ; sauve id
        jsr kernel_wm_offset     ; X = id*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #WM_F_USED
        beq wm_close_done        ; déjà libre → no-op
        ; Clear slot : flags = 0
        lda #$00
        sta WM_TABLE+WM_OFF_FLAGS,X
        ; Efface le flag titre du slot (SP-3.f : 1B seulement)
        lda DP_TMP
        tax
        lda #$00
        sta WM_TITLES,X
        ; SP-3.j : si la fenêtre fermée était modale → clear WM_MODAL
        lda DP_TMP
        cmp WM_MODAL
        bne wm_close_not_modal
        lda #$FF
        sta WM_MODAL
wm_close_not_modal:
        ; Décrémente WM_COUNT (saturé à 0)
        lda WM_COUNT
        beq wm_close_done
        dec a
        sta WM_COUNT
        ; SP-3.R S4 : retirer le slot fermé de WM_ZORDER (compact).
        ; Cherche l'index du slot dans ZORDER, décale, décrémente N.
        ; Y = index boucle ; long,Y inexistant → tyx avant chaque accès WM_ZORDER.
        lda WM_ZORDER_N
        sta WM_ZN_CACHE          ; CPY ne fait pas le mode long 24-bit
        lda DP_TMP               ; slot à retirer (sauvegardé dans A)
        ldy #$00
wm_close_zord_find:
        cpy WM_ZN_CACHE
        bcs wm_close_zord_done   ; pas trouvé (ne devrait pas arriver)
        tyx                      ; X = Y pour lda long,X
        cmp f:WM_ZORDER,X
        beq wm_close_zord_found
        iny
        bra wm_close_zord_find
wm_close_zord_found:
        ; Y = index trouvé. Compacter : ZORDER[Y..N-2] = ZORDER[Y+1..N-1].
        phy                      ; sauvegarder index trouvé
wm_close_zord_compact:
        iny
        cpy WM_ZN_CACHE
        bcs wm_close_zord_compact_done
        tyx                      ; X = Y (index suivant)
        lda f:WM_ZORDER,X
        dey
        tyx                      ; X = Y-1 (index précédent)
        sta f:WM_ZORDER,X
        iny
        bra wm_close_zord_compact
wm_close_zord_compact_done:
        ply                      ; index (dépile)
        lda WM_ZORDER_N
        dec a
        sta WM_ZORDER_N
wm_close_zord_done:
        ; Mise à jour focus : si la fenêtre fermée avait le focus →
        ; le nouveau focus = sommet du ZORDER (dernier slot restant).
        lda DP_TMP
        cmp WM_FOCUS
        bne wm_close_done        ; pas le focus → fin
        lda #$FF
        sta WM_FOCUS             ; perd le focus par défaut
        lda WM_ZORDER_N
        beq wm_close_done        ; plus aucune fenêtre
        dec a                    ; index du dernier = N-1
        tax
        lda f:WM_ZORDER,X        ; slot id au sommet (long,X)
        sta WM_FOCUS             ; nouveau focus = sommet Z-order
wm_close_done:
        rts

; ── kernel_wm_set_modal : A = slot → WM_MODAL = slot. SP-3.j ────────
; Appeler après kernel_wm_add pour rendre la fenêtre modale.
; Les clics hors de cette fenêtre seront ignorés par le WM.
.export kernel_wm_set_modal
kernel_wm_set_modal:
        cmp #WM_MAX
        bcs _sm_done             ; slot invalide → no-op
        sta WM_MODAL
_sm_done:
        rts

; ── kernel_wm_clear_modal : WM_MODAL = $FF (libère le modal). SP-3.j ──
.export kernel_wm_clear_modal
kernel_wm_clear_modal:
        lda #$FF
        sta WM_MODAL
        rts


; ════════════════════════════════════════════════════════════════════
;  SP-3.k — Icônes desktop
; ════════════════════════════════════════════════════════════════════
;
; Table ICON_TABLE ($015ADA, 4 × 16B). Entrée :
;   +0  flags (1B : 0=libre, 1=utilisé, 3=sélectionné)
;   +1  color (1B : palette 0..15)
;   +2  x (2B)
;   +4  y (2B)
;   +6  cb_lo (1B) + cb_hi (1B) : callback en bank 1 (0=aucun)
;   +8  label (8B : 7 chars + null)
; Labels SDRAM : $011200 + id*$10.
; ════════════════════════════════════════════════════════════════════

; ── kernel_icon_add : ajoute une icône. SP-3.k ───────────────────────
; Args (ZP) :
;   WM_ARG_X ($14, 2B) = x, WM_ARG_Y ($16, 2B) = y
;   GFX_COLOR ($D6, 1B) = color
;   DP_PCPTR ($08, 2B) = pointeur bank-1 vers label string (null-term)
;   WM_ARG_DX ($1C, 2B) = callback (0=aucun)
; Retourne A = id (0..3) ou $FF (table pleine). Modifie A, X, Y.
.export kernel_icon_add
kernel_icon_add:
        ; Chercher un slot libre
        ldx #$00
_kia_find:
        lda ICON_TABLE+ICON_OFF_FLAGS,X
        and #ICON_F_USED
        beq _kia_found           ; flags & 1 == 0 → libre
        txa
        clc
        adc #ICON_ENTSZ
        tax
        cpx #(ICON_MAX * ICON_ENTSZ)
        bcc _kia_find
        lda #$FF                 ; table pleine
        rts
_kia_found:
        ; X = offset du slot libre. Calculer l'id = X / ICON_ENTSZ
        txa
        lsr a
        lsr a
        lsr a
        lsr a                    ; id = X >> 4 (ICON_ENTSZ = 16 = 2^4)
        sta WM_DP_TMP            ; sauve l'id
        ; Remplir l'entrée
        lda #ICON_F_USED
        sta ICON_TABLE+ICON_OFF_FLAGS,X
        lda GFX_COLOR
        sta ICON_TABLE+ICON_OFF_COLOR,X
        lda WM_ARG_DX            ; cb_lo
        sta ICON_TABLE+ICON_OFF_CB_LO,X
        lda WM_ARG_DX+1          ; cb_hi
        sta ICON_TABLE+ICON_OFF_CB_HI,X
        rep #$20
        lda WM_ARG_X
        sta ICON_TABLE+ICON_OFF_X,X
        lda WM_ARG_Y
        sta ICON_TABLE+ICON_OFF_Y,X
        sep #$20
        ; Copier le label (max 7 chars + null) depuis DP_PCPTR vers ICON_TABLE+8,X
        ldy #$00
_kia_lbl:
        lda (DP_PCPTR),Y         ; lit depuis bank-1 RAM
        sta ICON_TABLE+ICON_OFF_LABEL,X
        beq _kia_lbl_done        ; null terminator
        inx
        iny
        cpy #8
        bcc _kia_lbl
        ; Forcer null-terminator (overflow)
        lda #$00
        sta ICON_TABLE+ICON_OFF_LABEL,X  ; écrit nul à ICON_TABLE+8+Y,X (last byte)
        ; Note: X a bougé → restaurer
        lda WM_DP_TMP
        asl a
        asl a
        asl a
        asl a                    ; id * 16 = offset original
        tax
_kia_lbl_done:
        ; Upload label en SDRAM $011200 + id*$10
        ; id = WM_DP_TMP, offset SDRAM = id << 4
        lda WM_DP_TMP
        asl a
        asl a
        asl a
        asl a                    ; id*16 = SDRAM offset low byte
        ; adresse complète = $011200 + id*16
        ; LO = $00 + (id*16)  (toujours < $FF pour id=0..3)
        ; MID = $12 + (id*16 >> 8) ≈ $12 (id≤3, offset≤48 = $30 → MID=$12)
        sta f:VRAM_ADDR_LO_IO
        lda #ICON_SDRAM_BASE_LO  ; $12
        sta f:VRAM_ADDR_MID_IO
        lda #ICON_SDRAM_BASE_HI  ; $01
        sta f:VRAM_ADDR_HI_IO
        ; Écrire le label byte à byte via VRAM_DATA_IO (auto-incr)
        lda WM_DP_TMP
        asl a
        asl a
        asl a
        asl a
        tax                      ; X = offset dans ICON_TABLE
        ldy #$00
_kia_sdram:
        lda ICON_TABLE+ICON_OFF_LABEL,X
        sta f:VRAM_DATA_IO
        beq _kia_sdram_done
        inx
        iny
        cpy #8
        bcc _kia_sdram
        lda #$00
        sta f:VRAM_DATA_IO
_kia_sdram_done:
        ; Incrémenter ICON_COUNT
        lda f:ICON_COUNT
        inc a
        sta f:ICON_COUNT
        ; Retourner l'id
        lda WM_DP_TMP
        rts

; ── kernel_icon_draw_all : dessine toutes les icônes. SP-3.k ─────────
; Chaque icône : boîte FILL_RECT16 (32×32) + TEXT16 (label en dessous).
; Modifie A, X, Y. Base SDRAM framebuffer $100000.
.export kernel_icon_draw_all
kernel_icon_draw_all:
        lda ICON_COUNT
        bne _kid_start
        rts
_kid_start:
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        ldx #$00
_kid_loop:
        lda ICON_TABLE+ICON_OFF_FLAGS,X
        and #ICON_F_USED
        beq _kid_next
        ; Dessine la boîte : FILL_RECT16 (x, y, 32, 32, color)
        rep #$20
        lda ICON_TABLE+ICON_OFF_X,X
        sta WM_ARG_X
        lda ICON_TABLE+ICON_OFF_Y,X
        sta WM_ARG_Y
        lda #ICON_SIZE_PX
        sta WM_ARG_W
        sta WM_ARG_H
        sep #$20
        ; Couleur : sélectionné → lightcyan($0B), sinon couleur de l'icône
        lda ICON_TABLE+ICON_OFF_FLAGS,X
        cmp #ICON_F_SEL
        bne _kid_use_own_color
        lda #$0B                 ; lightcyan = sélectionné
        bra _kid_set_color
_kid_use_own_color:
        lda ICON_TABLE+ICON_OFF_COLOR,X
_kid_set_color:
        sta GFX_COLOR
        ; Sauve X avant jsr (qui peut le modifier via helpers)
        txa
        sta WM_CRH_TMP           ; sauve offset
        jsr kernel_gfx_fill_rect16
        ldx WM_CRH_TMP           ; restaure offset
        ; Dessine le label : TEXT16 (label_sdram, x, y+34, white)
        ; addr SDRAM label = $011200 + id*$10
        ; id = X / 16
        txa
        lsr a
        lsr a
        lsr a
        lsr a                    ; id
        asl a
        asl a
        asl a
        asl a                    ; id * 16
        ; SDRAM addr = $011200 + (id*16)
        sta GFX_STR_LO
        lda #ICON_SDRAM_BASE_LO  ; $12
        sta GFX_STR_MID
        lda #ICON_SDRAM_BASE_HI  ; $01
        sta GFX_STR_HI
        ; Position texte : (icon_x, icon_y + ICON_SIZE_PX + 2)
        rep #$20
        lda ICON_TABLE+ICON_OFF_X,X
        sta WM_ARG_X
        lda ICON_TABLE+ICON_OFF_Y,X
        clc
        adc #(ICON_SIZE_PX + 2)
        sta WM_ARG_Y
        sep #$20
        lda #$0F                 ; white
        sta GFX_COLOR
        txa
        sta WM_CRH_TMP
        jsr kernel_gfx_text16
        ldx WM_CRH_TMP
_kid_next:
        txa
        clc
        adc #ICON_ENTSZ
        tax
        cpx #(ICON_MAX * ICON_ENTSZ)
        bcc _kid_loop
_kid_done:
        rts

; ── _icon_hit : hit-test icônes sous (MOUSE_X, MOUSE_Y). SP-3.k ──────
; Retourne A = id (0..3) ou $FF si aucune. Modifie A, X.
_icon_hit:
        lda ICON_COUNT
        beq _ih_none
        ldx #$00
_ih_loop:
        lda ICON_TABLE+ICON_OFF_FLAGS,X
        and #ICON_F_USED
        beq _ih_next
        rep #$20
        lda ICON_TABLE+ICON_OFF_X,X
        sta WM_DP_TMP            ; icon_x
        clc
        adc #ICON_SIZE_PX
        sta WM_ARG_DX            ; icon_right
        lda MOUSE_X
        cmp WM_DP_TMP            ; mouse_x >= icon_x ?
        bcc _ih_next16
        cmp WM_ARG_DX            ; mouse_x < icon_right ?
        bcs _ih_next16
        lda ICON_TABLE+ICON_OFF_Y,X
        sta WM_DP_TMP            ; icon_y
        clc
        adc #ICON_SIZE_PX
        sta WM_ARG_DX            ; icon_bottom
        lda MOUSE_Y
        cmp WM_DP_TMP            ; mouse_y >= icon_y ?
        bcc _ih_next16
        cmp WM_ARG_DX            ; mouse_y < icon_bottom ?
        bcs _ih_next16
        sep #$20
        txa
        lsr a
        lsr a
        lsr a
        lsr a                    ; id = X / ICON_ENTSZ (16)
        rts
_ih_next16:
        sep #$20
_ih_next:
        txa
        clc
        adc #ICON_ENTSZ
        tax
        cpx #(ICON_MAX * ICON_ENTSZ)
        bcc _ih_loop
_ih_none:
        lda #$FF
        rts

; ── kernel_wm_maximize : bascule maximize/restore d'une fenêtre (SP-3.h) ──
; A = id de la fenêtre. Si normale → maximise. Si maximisée → restore.
; WM_SAVED_RECTS[slot×8] = {x(2),y(2),w(2),h(2)} sauvegardé avant maximize.
; Dimensions maximize : x=0, y=MENU_BAR_H=14, w=1004, h=741 (20px marge bord droit).
; Stratégie adressage WM_SAVED_RECTS : STA/LDA f:WM_SAVED_RECTS,X avec X=slot*8
; (opcode $9F/$BF = long,X — seul mode indexé long valide en 65C816).
; WM_CRH_TMP ($25-$26) : sauvegarde temporaire de l'offset WM_TABLE (slot*10).
; Modifie A, X, Y.
.export kernel_wm_maximize
kernel_wm_maximize:
        cmp #WM_MAX
        bcs kwmax_done           ; id invalide
        sta DP_TMP               ; sauve id (8-bit)
        tax
        lda WM_STATES,X          ; WM_STATES[id]
        cmp #WM_STATE_MAXED
        beq kwmax_restore        ; déjà maximisée → restore

        ; ── maximize : sauvegarde des coords avant agrandissement ─────────
        ; Calcule slot*10 (WM_TABLE offset) → sauve dans WM_CRH_TMP (ZP 2B).
        lda DP_TMP
        jsr kernel_wm_offset     ; X = slot*10
        stx WM_CRH_TMP           ; sauve slot*10 en ZP
        ; Lit x,y,w,h depuis WM_TABLE[slot*10]
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        sta WM_DP_TMP            ; tmp_x = win.x
        lda WM_TABLE+WM_OFF_Y,X
        pha                      ; win.y → stack
        lda WM_TABLE+WM_OFF_W,X
        pha                      ; win.w → stack
        lda WM_TABLE+WM_OFF_H,X
        pha                      ; win.h → stack
        sep #$20
        ; Calcule slot*8 → X (index pour WM_SAVED_RECTS long,X)
        lda DP_TMP
        asl a
        asl a
        asl a                    ; slot × 8
        tax                      ; X = slot*8
        ; Sauve x,y,w,h dans WM_SAVED_RECTS via STA f:WM_SAVED_RECTS,X ($9F = long,X)
        rep #$20
        lda WM_DP_TMP            ; win.x
        sta f:WM_SAVED_RECTS+0,X ; [slot*8+0..+1] = x
        pla                      ; win.h (dépilé en ordre inverse)
        sta f:WM_SAVED_RECTS+6,X ; [slot*8+6..+7] = h
        pla                      ; win.w
        sta f:WM_SAVED_RECTS+4,X ; [slot*8+4..+5] = w
        pla                      ; win.y
        sta f:WM_SAVED_RECTS+2,X ; [slot*8+2..+3] = y
        sep #$20
        ; Restaure X = slot*10 pour écrire les nouvelles coords dans WM_TABLE
        ldx WM_CRH_TMP           ; slot*10 depuis ZP
        rep #$20
        ; Coords maximize : x=0, y=14, w=1004, h=741
        ; 20px réservés à droite (future taskbar verticale + marge boutons chrome)
        lda #$0000
        sta WM_TABLE+WM_OFF_X,X  ; x = 0
        lda #14
        sta WM_TABLE+WM_OFF_Y,X  ; y = 14
        lda #1004
        sta WM_TABLE+WM_OFF_W,X  ; w = 1004 (marge 20px bord droit)
        lda #741
        sta WM_TABLE+WM_OFF_H,X  ; h = 741
        sep #$20
        ; WM_STATES[slot] = WM_STATE_MAXED
        lda DP_TMP
        tax
        lda #WM_STATE_MAXED
        sta WM_STATES,X
        jsr kernel_wm_redraw
kwmax_done:
        rts

kwmax_restore:
        ; ── restore depuis maximisée : recharge coords sauvegardées ───────
        ; Calcule slot*10 → sauve dans WM_CRH_TMP
        lda DP_TMP
        jsr kernel_wm_offset     ; X = slot*10
        stx WM_CRH_TMP           ; sauve slot*10
        ; Calcule slot*8 → X (index long,X pour WM_SAVED_RECTS)
        lda DP_TMP
        asl a
        asl a
        asl a                    ; slot × 8
        tax                      ; X = slot*8
        ; Lit x,y,w,h depuis WM_SAVED_RECTS via LDA f:WM_SAVED_RECTS,X ($BF)
        rep #$20
        lda f:WM_SAVED_RECTS+0,X ; win.x sauvé
        sta WM_DP_TMP            ; tmp = x
        lda f:WM_SAVED_RECTS+2,X ; win.y sauvé
        pha
        lda f:WM_SAVED_RECTS+4,X ; win.w sauvé
        pha
        lda f:WM_SAVED_RECTS+6,X ; win.h sauvé
        pha
        sep #$20
        ; Restaure X = slot*10 pour écrire dans WM_TABLE
        ldx WM_CRH_TMP
        rep #$20
        lda WM_DP_TMP
        sta WM_TABLE+WM_OFF_X,X  ; restore x
        pla
        sta WM_TABLE+WM_OFF_H,X  ; restore h (dépilé en ordre inverse)
        pla
        sta WM_TABLE+WM_OFF_W,X  ; restore w
        pla
        sta WM_TABLE+WM_OFF_Y,X  ; restore y
        sep #$20
        lda DP_TMP
        tax
        lda #WM_STATE_NORMAL
        sta WM_STATES,X
        jsr kernel_wm_redraw
        rts

; ── kernel_wm_minimize : minimise une fenêtre (cache, SP-3.h) ────────
; A = id. Clear WM_F_VISIBLE, état HIDDEN. Focus redistribué si besoin.
; Modifie A, X, Y.
.export kernel_wm_minimize
kernel_wm_minimize:
        cmp #WM_MAX
        bcs kwmin_done
        sta DP_TMP
        jsr kernel_wm_offset     ; X = slot*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #WM_F_USED
        beq kwmin_done           ; slot libre → no-op
        ; Clear WM_F_VISIBLE
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #($FF ^ WM_F_VISIBLE) ; clear bit visible
        sta WM_TABLE+WM_OFF_FLAGS,X
        ; WM_STATES[slot] = HIDDEN ou HIDDEN_MAXED selon l'état courant
        lda DP_TMP
        tax                         ; X = slot
        lda WM_STATES,X
        cmp #WM_STATE_MAXED
        bne kwmin_hidden_normal
        lda #WM_STATE_HIDDEN_MAXED  ; était maximisée → mémorise
        sta WM_STATES,X             ; X = slot encore valide
        bra kwmin_hidden_done
kwmin_hidden_normal:
        lda #WM_STATE_HIDDEN
        sta WM_STATES,X
kwmin_hidden_done:
        ; Si la fenêtre avait le focus → redistribuer
        lda DP_TMP
        cmp WM_FOCUS
        bne kwmin_redraw
        lda #$FF
        sta WM_FOCUS
        ; Cherche premier slot USED+VISIBLE pour le nouveau focus
        ldy #$00
kwmin_find_focus:
        tya
        cmp #WM_MAX
        bcs kwmin_redraw
        jsr kernel_wm_offset     ; X = y*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #(WM_F_USED | WM_F_VISIBLE)
        cmp #(WM_F_USED | WM_F_VISIBLE)
        bne kwmin_next_focus
        tya
        sta WM_FOCUS
        bra kwmin_redraw
kwmin_next_focus:
        iny
        bra kwmin_find_focus
kwmin_redraw:
        jsr kernel_wm_redraw
kwmin_done:
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
        ; SP-3.k : dessine les icônes du desktop (sous les fenêtres).
        jsr kernel_icon_draw_all
        ; fall-through : dessine les fenêtres.

; ── _wm_draw_windows : dessine toutes les fenêtres visibles (corps + titre).
;    SP-3.R S4 : passe unique dans l'ordre WM_ZORDER (fond→premier plan).
;    Réutilisé par kernel_wm_redraw et kernel_wm_redraw_drag.
;    Modifie A, X, Y.
_wm_draw_windows:
        lda WM_ZORDER_N
        sta WM_ZN_CACHE          ; CPX ne fait pas le mode long 24-bit
        ldx #$00
wm_rd_loop:
        cpx WM_ZN_CACHE
        bcs wm_rd_done
        lda f:WM_ZORDER,X        ; slot id depuis ZORDER (long,X = seule forme 24-bit indexée)
        phx                      ; _wm_draw_one clobbe X,Y via GPU → sauvegarder index
        jsr _wm_draw_one
        plx
        inx
        bra wm_rd_loop
wm_rd_done:
        jmp kernel_menu_draw    ; menu par-dessus tout

; ── _wm_draw_one : dessine une fenêtre (corps + titlebar + titre + widgets).
; Entrée : A = slot id. Modifie A, X, Y.
_wm_draw_one:
        sta WIN_SLOT            ; mémorise le slot (stable vis-à-vis de kernel_wm_offset)
        jsr kernel_wm_offset    ; X = slot*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #(WM_F_USED | WM_F_VISIBLE)
        cmp #(WM_F_USED | WM_F_VISIBLE)
        bne _wdo_done
        ; Couleur titlebar selon focus (v0.8)
        lda WIN_SLOT
        cmp WM_FOCUS
        bne _wdo_unfocus
        lda #WIN_TITLE_FOCUS
        bra _wdo_setcol
_wdo_unfocus:
        lda #WIN_TITLE_NORMAL
_wdo_setcol:
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
        ; Corps lightgray (7), base SDRAM $100000.
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #$07
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; Title bar : même x/y/w, h=12, couleur selon focus.
        rep #$20
        lda #12
        sta WM_ARG_H
        sep #$20
        lda WM_TITLE_COL
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; Titre + bouton fermer (SP-3.f) — WIN_SLOT déjà posé.
        jsr _wm_draw_title_and_close
        ; Widgets de ce slot (Z-order : la fenêtre suivante couvrira les siens).
        lda WIN_SLOT
        jsr _wm_draw_widgets_for_slot
_wdo_done:
        rts

; ── _wm_draw_title_and_close : dessine le titre + bouton × dans la titlebar ──
; SP-3.f v0.1 (titre) + v0.2 (bouton fermer).
; Pré-cond : WIN_SLOT = id du slot courant. WM_ARG_X/Y/W posés (window coords).
; GFX_BASE déjà set à $100000. Modifie A, X (Y clobbé par GPU helpers).
_wm_draw_title_and_close:
        ; ── Titre (v0.1) ──────────────────────────────────────────────
        ; Vérifie le flag WM_TITLES[slot] (1B : $01=titre présent, $00=absent).
        ; Le titre est en SDRAM $012000 + slot*$100 (uploadé par kernel_wm_add,
        ; hors IRQ context : pas de corruption de DP_PCPTR depuis l'IRQ handler).
        lda WIN_SLOT
        tax
        lda WM_TITLES,X          ; flag : $01 = titre présent
        beq _wm_dtc_close        ; $00 → pas de titre → bouton X direct

        ; TEXT16 : dessine le titre depuis SDRAM $012000+slot*$100 à (win_x+4, win_y+3).
        ; Calcule l'adresse SDRAM du titre : MID = $20 + slot, LO = $00, HI = $01.
        lda WIN_SLOT
        clc
        adc #WM_SDRAM_TITLE_BASE_MID ; $20 + slot
        sta GFX_STR_MID
        lda #$00
        sta GFX_STR_LO
        lda #$01
        sta GFX_STR_HI           ; str = $012000 + slot*$100

        ; Coords TEXT16 : win_x+4, win_y+3 (lus depuis WM_TABLE)
        lda WIN_SLOT
        jsr kernel_wm_offset     ; X = slot*10
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        clc
        adc #4
        sta WM_ARG_X             ; win_x + 4
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc #3
        sta WM_ARG_Y             ; win_y + 3
        sep #$20
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI          ; base = $100000 (XVGA desktop)
        lda #<TK_FONT_ADDR
        sta GFX_FONT_LO
        lda #>TK_FONT_ADDR
        sta GFX_FONT_MID
        lda #$01
        sta GFX_FONT_HI          ; font = $010000 (bank 1)
        lda #$0F
        sta GFX_COLOR            ; white
        jsr kernel_gfx_text16    ; GPU_OP_TEXT16 (WM_ARG_X/Y = coords 16-bit)

_wm_dtc_close:
        ; ── Bouton fermer "X" (v0.2) ──────────────────────────────────
        ; Position : x = win_x + win_w - 10, y = win_y + 3.
        ; Relit depuis la table.
        lda WIN_SLOT
        jsr kernel_wm_offset     ; X = slot*10
        rep #$20
        lda WM_TABLE+WM_OFF_X,X  ; win_x
        clc
        adc WM_TABLE+WM_OFF_W,X  ; + win_w
        sec
        sbc #10                  ; -10 = bouton x
        sta WM_ARG_X
        lda WM_TABLE+WM_OFF_Y,X  ; win_y
        clc
        adc #3
        sta WM_ARG_Y             ; win_y + 3
        sep #$20
        ; TEXT16 avec string WM_CLOSE_STR "X\0" (uploadé au boot en SDRAM)
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #<TK_FONT_ADDR
        sta GFX_FONT_LO
        lda #>TK_FONT_ADDR
        sta GFX_FONT_MID
        lda #$01
        sta GFX_FONT_HI
        lda #<WM_CLOSE_STR
        sta GFX_STR_LO
        lda #>WM_CLOSE_STR
        sta GFX_STR_MID
        lda #$01
        sta GFX_STR_HI           ; bank $01 → WM_CLOSE_STR = $011080
        lda #$0C                 ; lightred : bouton X distinct du titre blanc
        sta GFX_COLOR
        jsr kernel_gfx_text16    ; SP-3.f v0.2 : dessine "X" bouton fermer

        ; ── SP-3.h : bouton □ maximize (couleur yellow si maxed, white sinon) ──
        ; Position : win_x + win_w - BTN_MAX_OFFSET (22), win_y + 3
        lda WIN_SLOT
        jsr kernel_wm_offset     ; X = slot*10
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        clc
        adc WM_TABLE+WM_OFF_W,X
        sec
        sbc #BTN_MAX_OFFSET      ; win_x + win_w - 22
        sta WM_ARG_X
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc #3
        sta WM_ARG_Y             ; win_y + 3
        sep #$20
        ; Couleur : yellow ($0E) si maximisé, white ($0F) sinon
        lda WIN_SLOT
        tax
        lda WM_STATES,X
        cmp #WM_STATE_MAXED
        bne _wm_dtc_max_white
        lda #$0E                 ; yellow : fenêtre maximisée
        bra _wm_dtc_max_draw
_wm_dtc_max_white:
        lda #$0F                 ; white : normal
_wm_dtc_max_draw:
        sta GFX_COLOR
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #<TK_FONT_ADDR
        sta GFX_FONT_LO
        lda #>TK_FONT_ADDR
        sta GFX_FONT_MID
        lda #$01
        sta GFX_FONT_HI
        lda #<WM_MAX_STR
        sta GFX_STR_LO
        lda #>WM_MAX_STR
        sta GFX_STR_MID
        lda #$01
        sta GFX_STR_HI           ; SDRAM $011090
        jsr kernel_gfx_text16

        ; ── SP-3.h : bouton _ minimize (seulement si non minimisée) ───────
        ; Position : win_x + win_w - BTN_MIN_OFFSET (34), win_y + 3
        ; (Une fenêtre minimisée n'est pas visible dans _wm_draw_windows,
        ; donc ce code ne s'exécute que pour les fenêtres visibles.)
        lda WIN_SLOT
        jsr kernel_wm_offset     ; X = slot*10
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        clc
        adc WM_TABLE+WM_OFF_W,X
        sec
        sbc #BTN_MIN_OFFSET      ; win_x + win_w - 34
        sta WM_ARG_X
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc #3
        sta WM_ARG_Y             ; win_y + 3
        sep #$20
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #<TK_FONT_ADDR
        sta GFX_FONT_LO
        lda #>TK_FONT_ADDR
        sta GFX_FONT_MID
        lda #$01
        sta GFX_FONT_HI
        lda #<WM_MIN_STR
        sta GFX_STR_LO
        lda #>WM_MIN_STR
        sta GFX_STR_MID
        lda #$01
        sta GFX_STR_HI           ; SDRAM $0110A0
        lda #$0F
        sta GFX_COLOR            ; white
        jsr kernel_gfx_text16
        rts

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
        jsr kernel_icon_draw_all ; icônes redessinées lors du drag (sinon disparaissent)
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

; ════════════════��═══════════════════════════════════════════════════
;  SP-3.g — Taskbar : bande bas desktop (y=755..767), boutons par fenêtre.
; ═════════════════════��═══════════════════════════════════��══════════

; ── kernel_taskbar_draw : dessine la taskbar complète. ────────────────
; Appelé en fin de kernel_menu_draw (dernière étape du rendu GUI).
; Base SDRAM $100000 (framebuffer XVGA ADR-20). Modifie A, X, Y.
.export kernel_taskbar_draw
kernel_taskbar_draw:
        ; ── Fond taskbar (0, 755, 1024, 13) darkgray ($08) ────────────
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        rep #$20
        lda #0
        sta WM_ARG_X
        lda #TB_Y_FILL
        sta WM_ARG_Y
        lda #1024
        sta WM_ARG_W
        lda #TB_H
        sta WM_ARG_H
        sep #$20
        lda #$08                 ; darkgray
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; ── Séparateur haut (0, 755, 1024, 1) blanc ($0F) ─────────────
        rep #$20
        lda #0
        sta WM_ARG_X
        lda #TB_Y_SEP
        sta WM_ARG_Y
        lda #1024
        sta WM_ARG_W
        lda #1
        sta WM_ARG_H
        sep #$20
        lda #$0F                 ; white
        sta GFX_COLOR
        jsr kernel_gfx_fill_rect16
        ; ── Boucle slots fenêtres ──────────────────────────────────────
        ; Initialise TB_BTN_X = TB_BTN_SP (4).
        rep #$20
        lda #TB_BTN_SP
        sta TB_BTN_X
        sep #$20
        lda #$00
        sta TB_I
_tb_draw_loop:
        lda TB_I
        cmp #WM_MAX              ; scan tous les slots (pas WM_COUNT : trous après close)
        bcc _tb_draw_check       ; i < WM_MAX → vérifie le slot
        jmp _tb_draw_done
_tb_draw_check:
        ; Offset table = TB_I * WM_ENTSZ
        jsr kernel_wm_offset     ; A = TB_I → X = TB_I*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #WM_F_USED
        bne _tb_draw_slot_used   ; slot occupé → dessine bouton
        jmp _tb_skip_slot        ; slot libre → avance TB_I seulement (pas btn_x)
_tb_draw_slot_used:
        ; Couleur bouton : lightblue ($09) si focus, darkgray ($08) sinon.
        lda TB_I
        cmp WM_FOCUS
        bne _tb_unfocus
        lda #$09                 ; lightblue (focus)
        bra _tb_setcol
_tb_unfocus:
        lda #$08                 ; darkgray (non-focus)
_tb_setcol:
        sta GFX_COLOR
        ; FILL_RECT16 bouton (TB_BTN_X, TB_BTN_Y, TB_BTN_W, TB_BTN_H).
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        rep #$20
        lda TB_BTN_X
        sta WM_ARG_X
        lda #TB_BTN_Y
        sta WM_ARG_Y
        lda #TB_BTN_W
        sta WM_ARG_W
        lda #TB_BTN_H
        sta WM_ARG_H
        sep #$20
        jsr kernel_gfx_fill_rect16
        ; ── Texte titre ────────────────────────────────────────────────
        ; Vérifie WM_TITLES[TB_I] : $01 → titre SDRAM $012000+slot*$100.
        ; $00 → génère "WinN\0" en bank 1 TB_WIN_SCRATCH, upload SDRAM.
        lda TB_I
        tax
        lda WM_TITLES,X
        beq _tb_no_title
        ; Titre présent.
        lda TB_I
        clc
        adc #WM_SDRAM_TITLE_BASE_MID  ; $20 + slot
        sta GFX_STR_MID
        lda #$00
        sta GFX_STR_LO
        lda #$01
        sta GFX_STR_HI           ; STR addr = $01_(20+slot)_00
        bra _tb_do_text
_tb_no_title:
        ; Génère "WinN\0" (5 bytes) dans TB_WIN_SCRATCH (bank 1 RAM).
        lda #'W'
        sta TB_WIN_SCRATCH+0
        lda #'i'
        sta TB_WIN_SCRATCH+1
        lda #'n'
        sta TB_WIN_SCRATCH+2
        lda TB_I
        clc
        adc #'0'
        sta TB_WIN_SCRATCH+3     ; '0'+slot
        lda #$00
        sta TB_WIN_SCRATCH+4
        ; Upload vers SDRAM TB_WIN_SDRAM ($011100).
        lda #<TB_WIN_SCRATCH
        sta DP_PCPTR
        lda #>TB_WIN_SCRATCH
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        lda #<TB_WIN_SDRAM
        sta VRAM_OP_ADDR_LO
        lda #>TB_WIN_SDRAM
        sta VRAM_OP_ADDR_MID
        lda #$00
        sta VRAM_OP_ADDR_HI
        lda #$05
        sta VRAM_OP_LEN_LO
        lda #$00
        sta VRAM_OP_LEN_HI
        jsr kernel_vram_write_block
        lda #<TB_WIN_SDRAM
        sta GFX_STR_LO
        lda #>TB_WIN_SDRAM
        sta GFX_STR_MID
        lda #$00
        sta GFX_STR_HI
_tb_do_text:
        ; TEXT16 à (TB_BTN_X+4, TB_BTN_TY), blanc, fonte TK_FONT_ADDR.
        rep #$20
        lda TB_BTN_X
        clc
        adc #4
        sta WM_ARG_X
        lda #TB_BTN_TY
        sta WM_ARG_Y
        sep #$20
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda #$10
        sta GFX_BASE_HI
        lda #<TK_FONT_ADDR
        sta GFX_FONT_LO
        lda #>TK_FONT_ADDR
        sta GFX_FONT_MID
        lda #$01
        sta GFX_FONT_HI
        lda #$0F                 ; blanc
        sta GFX_COLOR
        jsr kernel_gfx_text16
_tb_draw_advance:
        ; Avance TB_BTN_X uniquement pour les slots UTILISÉS (boutons contigus).
        rep #$20
        lda TB_BTN_X
        clc
        adc #TB_BTN_STRIDE
        sta TB_BTN_X
        sep #$20
_tb_skip_slot:
        ; Incrémente TB_I (slot libre : pas d'avance de btn_x).
        lda TB_I
        inc a
        sta TB_I
        jmp _tb_draw_loop
_tb_draw_done:
        rts

; ── kernel_taskbar_hit : teste clic dans la taskbar. ─────────────────
; Pré-cond : MOUSE_X/Y/BTN à jour (kernel_mouse_read appelé avant).
; Si MOUSE_Y >= TB_Y_SEP et MOUSE_BTN & LEFT : calcule slot = (X-4)/124.
; Si slot valide et WM_F_USED → kernel_wm_set_focus(slot) + redraw.
; Retour : A=1 si consommé (taskbar hit), A=0 sinon. Modifie A, X, Y.
.export kernel_taskbar_hit
kernel_taskbar_hit:
        ; Test MOUSE_BTN & LEFT.
        lda MOUSE_BTN
        and #MOU2_BTN_LEFT
        bne _tbh_btn_ok
        jmp _tbh_miss
_tbh_btn_ok:
        ; Test MOUSE_Y >= TB_Y_SEP (755). Comparaison 16-bit.
        rep #$20
        lda MOUSE_Y
        cmp #TB_Y_SEP
        sep #$20
        bcs _tbh_y_ok
        jmp _tbh_miss            ; y < 755 → pas la taskbar
_tbh_y_ok:
        ; Itère les slots en reproduisant le btn_x du draw (boutons contigus).
        rep #$20
        lda #TB_BTN_SP
        sta TB_BTN_X             ; btn_x courant (même init que draw)
        sep #$20
        lda #$00
        sta TB_I
_tbh_loop:
        lda TB_I
        cmp #WM_MAX
        bcc _tbh_check
        jmp _tbh_miss            ; tous les slots parcourus → miss
_tbh_check:
        jsr kernel_wm_offset     ; X = slot*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #WM_F_USED
        beq _tbh_next_slot       ; slot libre → ne contribue pas à btn_x
        ; Vérifie MOUSE_X ∈ [btn_x .. btn_x+TB_BTN_W[
        rep #$20
        lda MOUSE_X
        cmp TB_BTN_X
        bcc _tbh_advance         ; mouse_x < btn_x → pas ce bouton
        lda TB_BTN_X
        clc
        adc #TB_BTN_W
        sta WM_DP_TMP
        lda MOUSE_X
        cmp WM_DP_TMP
        bcs _tbh_advance         ; mouse_x >= btn_x+w → pas ce bouton
        sep #$20
        lda TB_I                 ; hit → slot trouvé
        bra _tbh_got_slot
_tbh_advance:
        lda TB_BTN_X
        clc
        adc #TB_BTN_STRIDE
        sta TB_BTN_X
        sep #$20
_tbh_next_slot:
        lda TB_I
        inc a
        sta TB_I
        jmp _tbh_loop
_tbh_got_slot:
        sta TB_I                 ; sauve slot pour après kernel_wm_offset
        jsr kernel_wm_offset     ; A = slot → X = slot*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #WM_F_USED
        beq _tbh_miss            ; slot libre → ignore
        ; SP-3.h : si la fenêtre est minimisée, la restaurer à l'état d'avant.
        lda TB_I
        tax
        lda WM_STATES,X
        cmp #WM_STATE_HIDDEN
        beq _tbh_restore_normal
        cmp #WM_STATE_HIDDEN_MAXED
        beq _tbh_restore_maxed
        bra _tbh_focus           ; déjà visible → juste focus
_tbh_restore_normal:
        ; Restore normal : WM_F_VISIBLE + état NORMAL
        lda TB_I
        jsr kernel_wm_offset     ; X = slot*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        ora #WM_F_VISIBLE
        sta WM_TABLE+WM_OFF_FLAGS,X
        lda TB_I
        tax
        lda #WM_STATE_NORMAL
        sta WM_STATES,X
        bra _tbh_focus
_tbh_restore_maxed:
        ; Restore maximisée : WM_F_VISIBLE + état MAXED (dims déjà à 1004×741)
        lda TB_I
        jsr kernel_wm_offset     ; X = slot*10
        lda WM_TABLE+WM_OFF_FLAGS,X
        ora #WM_F_VISIBLE
        sta WM_TABLE+WM_OFF_FLAGS,X
        lda TB_I
        tax
        lda #WM_STATE_MAXED
        sta WM_STATES,X
_tbh_focus:
        ; Focus + redraw + taskbar.
        lda TB_I                 ; slot
        jsr kernel_wm_set_focus
        jsr kernel_wm_redraw
        jsr kernel_wm_draw_cursor
        lda #$01                 ; consommé
        rts
_tbh_miss:
        lda #$00
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
        ; Motion seule (pas de bouton) → désarme drag + resize + curseur léger
        ; (backing-store : PAS de full-redraw du desktop).
        lda #$00
        sta WM_DRAG_ARMED
        sta WM_RESIZE_ARMED
        jsr kernel_wm_cursor_blit
        rts
wm_step_pressed:
        ; bouton gauche tenu. Était-il déjà tenu (drag) ou nouveau clic ?
        lda MOUSE_PREV_BTN
        and #MOU2_BTN_LEFT
        beq wm_step_not_drag     ; pas déjà tenu → nouveau clic
        jmp wm_step_drag         ; déjà tenu → drag (si armé)
wm_step_not_drag:
        ; SP-3.g : la taskbar intercepte le nouveau clic en priorité absolue.
        jsr kernel_taskbar_hit
        cmp #$00
        beq wm_step_no_taskbar   ; non consommé → traitement menu/fenêtre
        ; consommé par la taskbar → déjà redraw+curseur dans kernel_taskbar_hit
        rts
wm_step_no_taskbar:
        ; v0.5 : le menu intercepte le nouveau clic en priorité.
        jsr kernel_menu_handle_click
        cmp #$00
        beq wm_step_newclick     ; non consommé → traitement fenêtre
        ; consommé par le menu → redessine + curseur
        jsr kernel_wm_redraw
        jsr kernel_wm_draw_cursor
        rts
wm_step_newclick:
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
        ; Clic sur le vide → tester les icônes desktop (SP-3.k).
        jsr _icon_hit            ; A = id icône ou $FF
        cmp #$FF
        beq wm_step_no_icon
        ; Icône cliquée → invoque son callback, redraw curseur.
        sta ICON_SELECTED
        tax                      ; id = A
        lda ICON_ENTSZ
        ; calcule X * ICON_ENTSZ via TXA * 16
        txa
        asl a
        asl a
        asl a
        asl a                    ; A = id * 16
        tax
        rep #$20
        lda ICON_TABLE+ICON_OFF_CB_LO,X
        sta WM_DP_TMP            ; vecteur callback
        sep #$20
        lda WM_DP_TMP
        ora WM_DP_TMP+1
        beq wm_step_icon_nocb   ; callback nul → skip
        ldx #$00
        jsr (WM_DP_TMP,X)       ; appel indirect via JSR (abs,X) avec X=0
wm_step_icon_nocb:
        jsr kernel_wm_cursor_blit
        rts
wm_step_no_icon:
        ; Clic sur le vide → pas de focus ni changement desktop → curseur léger.
        lda #$00
        sta WM_DRAG_ARMED
        jsr kernel_wm_cursor_blit
        rts
wm_step_hit:
        ; SP-3.f v0.2 / SP-3.h : avant le focus/drag, tester les boutons chrome.
        ; hit_test a retourné l'id en A. On le sauve et on teste les 3 boutons.
        sta WIN_SLOT             ; sauve id fenêtre hit
        jsr _wm_chrome_hit       ; A : 0=non, 1=close, 2=max, 3=min
        cmp #$00
        beq wm_step_normal_hit   ; non → traitement normal (focus/drag)
        cmp #$01
        beq wm_step_chrome_close
        cmp #$02
        beq wm_step_chrome_max
        ; A=3 → minimize
        lda WIN_SLOT
        jsr kernel_wm_set_focus  ; focus → WIN_SLOT (Z-order correct au redraw)
        lda WIN_SLOT
        jsr kernel_wm_minimize
        lda #$00
        sta WM_DRAG_ARMED
        jsr kernel_wm_draw_cursor
        rts
wm_step_chrome_max:
        lda WIN_SLOT
        jsr kernel_wm_set_focus  ; focus → WIN_SLOT avant maximize (Z-order correct)
        lda WIN_SLOT
        jsr kernel_wm_maximize
        lda #$00
        sta WM_DRAG_ARMED
        jsr kernel_wm_draw_cursor
        rts
wm_step_chrome_close:
        ; Clic sur le bouton X → ferme la fenêtre
        lda WIN_SLOT
        jsr kernel_wm_close
        lda #$00
        sta WM_DRAG_ARMED        ; désarme le drag
        jsr kernel_wm_redraw
        jsr kernel_wm_draw_cursor
        rts
wm_step_normal_hit:
        ; SP-3.j : si une fenêtre modale est active et que le clic n'est pas
        ; sur cette fenêtre → ignorer (curseur léger uniquement).
        lda WM_MODAL
        cmp #$FF
        beq wm_step_modal_ok     ; pas de modal → proceed
        cmp WIN_SLOT             ; WM_MODAL == WIN_SLOT ?
        bne wm_step_modal_block  ; non → bloquer
wm_step_modal_ok:
        lda WIN_SLOT
        jsr kernel_wm_set_focus
        ; SP-3.i : teste d'abord si le clic est sur un bord resize.
        jsr _wm_resize_hit       ; A : 0=non, 1=droit, 2=bas, 3=coin
        cmp #$00
        beq wm_step_arm_drag
        ; Bord resize → arme le resize, pas le drag.
        sta WM_RESIZE_EDGE
        lda #$01
        sta WM_RESIZE_ARMED
        lda #$00
        sta WM_DRAG_ARMED
        jsr kernel_wm_redraw
        jsr kernel_wm_draw_cursor
        rts
wm_step_arm_drag:
        lda #$01                 ; clic intérieur → arme le drag
        sta WM_DRAG_ARMED
        lda #$00
        sta WM_RESIZE_ARMED
        ; v0.3 : bouton sous le curseur → WIDGET_ACTIVE (sinon $FF).
        jsr _wm_widget_hit
        ; v0.4 : si un bouton est actif et a un callback non nul, l'invoquer.
        jsr _wm_invoke_active_cb
        ; Focus changé → desktop modifié → full-redraw + curseur.
        jsr kernel_wm_redraw
        jsr kernel_wm_draw_cursor
        rts
wm_step_modal_block:
        ; SP-3.j : clic hors de la fenêtre modale → ignorer, curseur léger.
        lda #$00
        sta WM_DRAG_ARMED
        sta WM_RESIZE_ARMED
        jsr kernel_wm_cursor_blit
        rts

; ── _wm_invoke_active_cb : appelle le callback du bouton WIDGET_ACTIVE ──
; (offset bank1 stocké à entry+14/+15). No-op si pas de bouton actif ou
; callback nul. Le callback s'exécute en bank 1 (PBR=1). Modifie A,X. v0.4
_wm_invoke_active_cb:
        lda WIDGET_ACTIVE
        cmp #$FF
        bne _iac_go
        rts
_iac_go:
        asl a
        asl a
        asl a
        asl a
        tax                      ; offset entrée du bouton actif
        lda WIDGET_TABLE+14,X
        sta WG_CB_VEC
        lda WIDGET_TABLE+15,X
        sta WG_CB_VEC+1
        ora WG_CB_VEC            ; callback == 0 ?
        bne _iac_call
        rts
_iac_call:
        ldx #$00
        jsr (.loword(WG_CB_VEC),X)  ; appel indirect (opcode $FC, vecteur en PBR=1)
        rts

; ── _wm_chrome_hit : teste si (MOUSE_X,Y) touche un bouton chrome de WIN_SLOT ──
; SP-3.h. Retourne A : 0=pas touché, 1=close (×), 2=maximize (□), 3=minimize (_).
; Zones (largeur 12px chacune, de droite à gauche) :
;   × : [win_x+win_w-12 .. win_x+win_w-1]
;   □ : [win_x+win_w-24 .. win_x+win_w-13]
;   _ : [win_x+win_w-36 .. win_x+win_w-25]
; Y titlebar : [win_y .. win_y+13]
; Modifie A, X.
_wm_chrome_hit:
        lda WIN_SLOT
        cmp #WM_MAX
        bcs _crh_no              ; slot invalide → 0
        jsr kernel_wm_offset     ; X = slot*10
        rep #$20
        ; Vérifie d'abord MOUSE_Y dans la titlebar [win_y .. win_y+13]
        lda MOUSE_Y
        cmp WM_TABLE+WM_OFF_Y,X
        bcc _crh_no16            ; mouse_y < win_y → no
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc #13
        sta WM_DP_TMP
        lda MOUSE_Y
        cmp WM_DP_TMP
        bcs _crh_no16            ; mouse_y > win_y+13 → no
        ; Calcule win_x + win_w (bord droit exclus)
        lda WM_TABLE+WM_OFF_X,X
        clc
        adc WM_TABLE+WM_OFF_W,X
        sta WM_DP_TMP            ; win_right = win_x + win_w
        ; MOUSE_X < win_right ? (à droite totalement → no)
        lda MOUSE_X
        cmp WM_DP_TMP
        bcs _crh_no16
        ; Test zone × : [win_right-12 .. win_right-1]
        lda WM_DP_TMP
        sec
        sbc #12
        sta WM_CRH_TMP           ; close_left = win_right - 12
        lda MOUSE_X
        cmp WM_CRH_TMP
        bcc _crh_test_max        ; mouse_x < close_left → test □
        ; mouse_x >= close_left et < win_right → × hit
        sep #$20
        lda #$01
        rts
_crh_test_max:
        ; Test zone □ : [win_right-24 .. win_right-13]
        ; Note : atteint depuis rep #$20 (M=0) par bcc, mais le sep #$20
        ; juste avant trompe ca65. Forcer 16-bit explicitement.
        rep #$20
        lda WM_CRH_TMP           ; close_left = win_right-12
        sec
        sbc #12
        sta WM_CRH_TMP+2         ; max_left = win_right-24
        lda MOUSE_X
        cmp WM_CRH_TMP+2
        bcc _crh_test_min        ; mouse_x < max_left → test _
        ; mouse_x >= max_left et < close_left → □ hit
        sep #$20
        lda #$02
        rts
_crh_test_min:
        ; Test zone _ : [win_right-36 .. win_right-25]
        rep #$20
        lda WM_CRH_TMP+2         ; max_left = win_right-24
        sec
        sbc #12
        sta WM_CRH_TMP+4         ; min_left = win_right-36
        lda MOUSE_X
        cmp WM_CRH_TMP+4
        bcc _crh_no16            ; mouse_x < min_left → no
        ; mouse_x >= min_left et < max_left → _ hit
        sep #$20
        lda #$03
        rts
_crh_no16:
        sep #$20
_crh_no:
        lda #$00
        rts

; ── _wm_resize_hit : hit-test bords resize de WIN_SLOT. SP-3.i ────────
; Retourne A : 0=non, 1=bord droit, 2=bord bas, 3=coin bas-droit.
; Pré-cond : WIN_SLOT valide. Ne modifie pas WIN_SLOT. Modifie A, X.
; Scratch 16-bit : WM_DP_TMP=win_right, WM_ARG_DX=win_bottom,
;   WM_CRH_TMP+2=right_lo, WM_CRH_TMP+4=bot_lo, WM_CRH_TMP(1B)=right_hit.
_wm_resize_hit:
        ; Fenêtre maximisée → pas de resize
        lda WIN_SLOT
        tax
        lda WM_STATES,X          ; WM_STATES[slot]
        cmp #WM_STATE_MAXED
        bne _rh_skip_max
        jmp _rh_no
_rh_skip_max:
        ; Calculer win_right et win_bottom
        lda WIN_SLOT
        jsr kernel_wm_offset     ; X = slot*10
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        clc
        adc WM_TABLE+WM_OFF_W,X
        sta WM_DP_TMP            ; win_right = win_x + win_w
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc WM_TABLE+WM_OFF_H,X
        sta WM_ARG_DX            ; win_bottom = win_y + win_h
        lda WM_DP_TMP
        sec
        sbc #RESIZE_MARGIN
        sta WM_CRH_TMP+2         ; right_lo = win_right - MARGIN
        lda WM_ARG_DX
        sec
        sbc #RESIZE_MARGIN
        sta WM_CRH_TMP+4         ; bot_lo = win_bottom - MARGIN
        sep #$20
        lda #$00
        sta WM_CRH_TMP           ; right_hit = 0
        rep #$20
        ; ── Test bord droit : mouse_x in [right_lo, win_right), mouse_y in [win_y+14, win_bottom) ─
        lda MOUSE_X
        cmp WM_CRH_TMP+2         ; mouse_x >= right_lo ?
        bcc _rh_test_bottom
        cmp WM_DP_TMP            ; mouse_x < win_right ?
        bcs _rh_test_bottom
        ; Test Y : mouse_y in [win_y+14, win_bottom)
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc #14
        sta WM_CRH_TMP+2         ; win_y+14 (right_lo not needed anymore)
        lda MOUSE_Y
        cmp WM_CRH_TMP+2         ; mouse_y >= win_y+14 ?
        bcc _rh_test_bottom
        cmp WM_ARG_DX            ; mouse_y < win_bottom ?
        bcs _rh_test_bottom
        sep #$20
        lda #$01
        sta WM_CRH_TMP           ; right_hit = 1
        rep #$20
_rh_test_bottom:
        ; ── Test bord bas : mouse_y in [bot_lo, win_bottom), mouse_x in [win_x, win_right) ─
        lda MOUSE_Y
        cmp WM_CRH_TMP+4         ; mouse_y >= bot_lo ?
        bcc _rh_done
        cmp WM_ARG_DX            ; mouse_y < win_bottom ?
        bcs _rh_done
        lda MOUSE_X
        cmp WM_TABLE+WM_OFF_X,X  ; mouse_x >= win_x ?
        bcc _rh_done
        cmp WM_DP_TMP            ; mouse_x < win_right ?
        bcs _rh_done
        sep #$20
        lda WM_CRH_TMP           ; right_hit ?
        beq _rh_bottom_only
        lda #$03                 ; coin bas-droit
        rts
_rh_bottom_only:
        lda #$02                 ; bord bas seul
        rts
_rh_done:
        sep #$20
        lda WM_CRH_TMP           ; right_hit (0 ou 1)
        rts
_rh_no:
        lda #$00
        rts


; ── demo_ok_cb : callback démo du bouton "OK" — incrémente CB_FLAG. ────
demo_ok_cb:
        lda CB_FLAG
        inc a
        sta CB_FLAG
        rts
wm_step_drag:
        ; SP-3.i : si le resize est armé, priorité resize.
        lda WM_RESIZE_ARMED
        bne wm_step_do_resize
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

wm_step_do_resize:
        jsr _wm_do_resize
        rts

; ── _wm_do_resize : SP-3.i — applique le delta souris à w/h fenêtre focus. ──
; WM_RESIZE_EDGE : 1=droit, 2=bas, 3=coin. Clamp min. Modifie A, X.
_wm_do_resize:
        lda WM_FOCUS
        cmp #$FF
        beq _dr_done
        ; Capture rect avant modif (dirty rect pour redraw incrémental)
        jsr _wm_capture_focused_rect
        jsr kernel_wm_cursor_restore
        ; Sign-extend deltas (trashent X)
        lda MOUSE_DX
        jsr _sext8_to16
        sta WM_ARG_DX
        stx WM_ARG_DX+1
        lda MOUSE_DY
        jsr _sext8_to16
        sta WM_ARG_DY
        stx WM_ARG_DY+1
        ; Reload X = focus*10
        lda WM_FOCUS
        jsr kernel_wm_offset     ; X = focus*10
        rep #$20
        ; ── DX → W si bord droit (edge ≠ 2) ─────────────────────────
        sep #$20
        lda WM_RESIZE_EDGE
        cmp #$02
        rep #$20
        beq _dr_skip_dx          ; edge=2 (bas seul) → pas de DX
        lda WM_TABLE+WM_OFF_W,X
        clc
        adc WM_ARG_DX
        cmp #RESIZE_MIN_W
        bcs _dr_w_ok
        lda #RESIZE_MIN_W
_dr_w_ok:
        sta WM_TABLE+WM_OFF_W,X
_dr_skip_dx:
        ; ── DY → H si bord bas (edge ≠ 1) ───────────────────────────
        sep #$20
        lda WM_RESIZE_EDGE
        cmp #$01
        rep #$20
        beq _dr_skip_dy          ; edge=1 (droit seul) → pas de DY
        lda WM_TABLE+WM_OFF_H,X
        clc
        adc WM_ARG_DY
        cmp #RESIZE_MIN_H
        bcs _dr_h_ok
        lda #RESIZE_MIN_H
_dr_h_ok:
        sta WM_TABLE+WM_OFF_H,X
_dr_skip_dy:
        sep #$20
        ; SP-3.R S6 : dirty rect resize — efface ancien rect + redessine (vs full 393Ko).
        ; _wm_capture_focused_rect en tête de _wm_do_resize a peuplé WM_DRAG_OLD_*.
        jsr kernel_wm_redraw_drag
        jsr kernel_wm_draw_cursor
_dr_done:
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
; Largeur M/X : le dispatcher fait `sep #$30` (M=X=1, 8-bit) juste avant
; `jsr (syscall_table,X)`. Mais .smart ne peut PAS propager cette largeur
; à travers un saut INDIRECT → ca65 assumerait la largeur lexicale héritée
; du code wm.s précédent (potentiellement 16-bit). On l'asserte ici pour que
; les `lda #imm` 8-bit (ex. sys_invalid `lda #$FF`) soient encodés en 8-bit
; conformément au runtime. (cf. dette M/X aux dispatch indirects, revue senior.)
; ════════════════════════════════════════════════════════════════════
        .a8
        .i8

; $00 — sys_invalid : syscall réservé ou hors-table (aussi fin de table) ─
sys_invalid:
        lda #$FF
        rts

; $01 — SYS_PRINT_CHAR : arg X = char ────────────────────────────────
; kernel_print_char écrit en bank0 via adressage long ([DP_PCPTR]/f:) :
; indépendant du DBR de l'appelant userland. Aucune gymnastique DBR requise.
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
; v0.1 : poll le ring + WAI entre essais. Le handler COP a fait cli (I=0),
; donc WAI dort jusqu'à l'IRQ KBD2 qui remplit le ring via kernel_kbd_poll,
; au lieu de busy-spinner. Blocage vrai (task BLOCKED + wake) → OS-2.g v2.
sys_read_char:
sread_wait:
        jsr kernel_kbd_ring_pop
        cmp #$00
        bne sread_done          ; touche dispo → retour
        wai                     ; dort jusqu'à IRQ (KBD2 remplit le ring)
        bra sread_wait
sread_done:
        rts                     ; A = keycode

; $04 — SYS_EXIT : X = exit_code (OS-2.g v2.a g.4) ────────────────────
; Détruit la tâche courante et bascule vers la suivante (plus de STP global).
; STATE=DEAD + libère le bit bitmap, puis élit la prochaine READY et restaure
; SON contexte (on NE sauve PAS le contexte de la tâche morte). exit_code ignoré
; en v2.a (pas de wait() parent / zombie reaping — reporté).
; NB : la page de pile de la tâche fuit (pas de free-list de pages v2.a).
; NB : suppose qu'au moins une autre tâche est READY (task A/B permanentes) ;
;      le cas « dernière tâche » (idle task / halt) est reporté.
; Si le scheduler n'est pas actif (SCHED_ACTIVE≠$A5) — app lancée en
; contexte boot via JSL, ex. hello_c (TC-poc) qui n'est pas une vraie tâche —
; on retombe sur STP (sémantique v1 préservée pour le test hello_c).
sys_exit:
        lda SCHED_ACTIVE
        cmp #$A5
        beq se_teardown
        stp                     ; scheduler inactif → halt (app boot-context)
        bra *
se_teardown:
        sei                     ; section critique : teardown + switch atomiques
        jsr kernel_permit       ; g.6 : fin du syscall (FORBID→0 pour la tâche suivante)
        lda TASK_CUR
        jsr kernel_tcb_ptr      ; SCHED_PTR = &tcb[CUR]
        lda #TASK_STATE_DEAD
        ldy #TCB_STATE
        sta [SCHED_PTR],Y       ; tcb[CUR].STATE = DEAD
        lda TASK_CUR
        jsr kernel_bitmap_clear ; libère le slot
        lda TASK_CUR
        jsr kernel_sched_find_next  ; A = prochaine READY (CUR DEAD → ignorée)
        sta TASK_CUR
        jsr kernel_tcb_ptr      ; SCHED_PTR = &tcb[NEXT]
        lda #TASK_STATE_RUNNING
        ldy #TCB_STATE
        sta [SCHED_PTR],Y
        rep #$20
        ldy #TCB_S_LO
        lda [SCHED_PTR],Y       ; A = tcb[NEXT].S
        tcs                     ; bascule sur la pile de la nouvelle tâche
        sep #$20
        jmp restore_and_return  ; ply/plx/pla/rti → exécute la nouvelle tâche

; $05 — SYS_YIELD : cède le CPU coopérativement (OS-2.g v2.a g.7) ──────
; On entre via `jsr (syscall_table,X)` depuis le dispatcher COP. La pile est :
;   [ret_jsr lo][ret_jsr hi][P][PCL][PCH][PBR]  (frame COP en dessous)
; On jette le retour du jsr, puis on reconstruit la frame attendue par
; do_switch : [Y][X][A][P][PCL][PCH][PBR]. Le jmp do_switch sauve alors le SP
; (= point de reprise juste après le COP) dans tcb[CUR].S et bascule. Au réveil,
; ply/plx/pla/rti restaure et reprend après le COP. Même format que la frame
; forgée par kernel_task_create.
sys_yield:
        sei                     ; section critique : pas de préemption pendant la chirurgie de pile
        jsr kernel_permit       ; g.6 : fin du syscall (FORBID→0) ; la reprise = contexte app
        pla                     ; jette le retour du jsr (lo)
        pla                     ; jette le retour du jsr (hi) → SP au sommet de la frame COP
        lda #$00
        pha                     ; A_init (valeur de retour yield = don't care)
        lda DP_SYS_ARG_X
        pha                     ; X_init = X de l'appelant (préservé, ABI)
        phy                     ; Y_init = Y de l'appelant
        jmp do_switch           ; sauve SP→tcb[CUR].S, élit next, bascule (rti)

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
