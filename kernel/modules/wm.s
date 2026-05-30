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
        sta f:GFX_BPL_SHADOW     ; ADR-27 Étape A : shadow bpl = 0 (stride par défaut 512)
        sta f:GFX_BPL_SHADOW+1
        ; ADR-27 Étape B2 : init WM_COMPACT_FLAGS = 0 pour les 8 slots.
        sta f:WM_COMPACT_FLAGS+0
        sta f:WM_COMPACT_FLAGS+1
        sta f:WM_COMPACT_FLAGS+2
        sta f:WM_COMPACT_FLAGS+3
        sta f:WM_COMPACT_FLAGS+4
        sta f:WM_COMPACT_FLAGS+5
        sta f:WM_COMPACT_FLAGS+6
        sta f:WM_COMPACT_FLAGS+7
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
        ; SP-3.m G.1 : enregistre le propriétaire = tâche courante (créatrice).
        ldx DP_TMP               ; slot id
        lda TASK_CUR
        sta f:WM_OWNER,X         ; WM_OWNER[id] = pid créateur (abs-long,X)
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
        ; G.3 : le focus a changé → réévalue le clavier (réveille le nouveau
        ; propriétaire focus s'il attendait une touche déjà bufferisée).
        jsr kernel_kbd_wake
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
; ── kernel_wm_close_owner : ferme la fenêtre possédée par pid (SP-3.m G.5) ──
; In : A = pid. Scanne WM_OWNER ; si un slot lui appartient, le ferme
; (kernel_wm_close) et efface WM_OWNER[slot]. v1 : 0..1 fenêtre par tâche.
; Appelé par sys_exit (teardown). No-op si la tâche ne possède aucune fenêtre.
.export kernel_wm_close_owner
kernel_wm_close_owner:
        sta WCO_PID
        ldx #$00
wco_loop:
        lda f:WM_OWNER,X
        cmp WCO_PID
        beq wco_found
        inx
        cpx #WM_MAX
        bcc wco_loop
        rts                     ; aucune fenêtre pour ce pid
wco_found:
        lda #$00
        sta f:WM_OWNER,X        ; efface l'owner du slot
        txa                     ; A = slot id
        jsr kernel_wm_close     ; ferme (flags/titre/count/zorder/focus)
        ; ADR-30 Étape 2b suite : redessine SEULEMENT si app-driven (= app C
        ; appelle sys_exit après MSG_MENU/MSG_CLOSE). Évite le surcoût IRQ
        ; pour les tests boot self-test qui n'attendent pas le redraw.
        lda WM_APP_DRIVEN
        cmp #$A5
        bne wco_done
        jsr kernel_wm_redraw
wco_done:
        rts

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
        php                     ; OS-gpu-race : commande GPU atomique vs IRQ
        sei
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
        ; Poll busy (timeout 256, cohérent avec les autres helpers GPU — prérequis v0.2 async)
        ldx #$00
gfx_fr16_wait:
        lda GPU_STATUS_IO
        and #GPU_STATUS_BUSY
        beq gfx_fr16_done
        inx
        bne gfx_fr16_wait
gfx_fr16_done:
        plp
        rts

; ── kernel_wm_compose : composite les backing stores → framebuffer XVGA (G.4bis) ──
; Itère WM_ZORDER (fond→premier plan) pour respecter le Z-order lors du BLIT.
; Seules les fenêtres USED|VISIBLE sont composées (les fenêtres minimisées sont skippées).
; WCMP_SLOT = index ZORDER (0..WM_ZORDER_N-1). WCMP_XB = slot id temporaire avant x/2.
; dst = $100000 + y*512 + (x>>1) (BPL 512, 4bpp). byte_w = w>>1, byte_h = h.
; Modèle GrafPort : l'app dessine dans son backing store (coords locales), le
; compositor le place à l'écran. Pré-cond : mode N M=X=1, DBR=0. Clobbers A, X, Y.
.export kernel_wm_compose
kernel_wm_compose:
        lda #$00
        sta WCMP_SLOT                   ; index dans WM_ZORDER (0..WM_ZORDER_N-1)
wcmp_loop:
        lda WCMP_SLOT
        cmp WM_ZORDER_N                 ; index >= N → terminé
        bcc wcmp_not_done
        jmp wcmp_done
wcmp_not_done:
        tax
        lda f:WM_ZORDER,X              ; A = slot id (depuis ZORDER, long,X)
        sta WCMP_XB                     ; sauvegarde slot id avant overwrite par x/2
        jsr kernel_wm_offset           ; X = slot*10 (A = slot id en entrée)
        lda WM_TABLE+WM_OFF_FLAGS,X
        and #(WM_F_USED | WM_F_VISIBLE)
        cmp #(WM_F_USED | WM_F_VISIBLE)
        beq wcmp_visible
        jmp wcmp_next                   ; fenêtre cachée/minimisée → skip (jmp : portée étendue B2.b)
wcmp_visible:
        ; src = backing store = ($06+slot):$0000
        lda #$00
        sta GFX_BASE_LO
        sta GFX_BASE_MID
        lda WCMP_XB                     ; slot id
        sta f:WCMP_SLOT_ID              ; ADR-27 B2.b : mémorise slot avant écrasement
        clc
        adc #$06
        sta GFX_BASE_HI
        ; dst = $100000 + y*512 + (x>>1) (ADR-20 : framebuffer XVGA base $100000) → GFX_ARG2
        rep #$20
        lda WM_TABLE+WM_OFF_X,X
        lsr a                           ; xb = x>>1
        sta WCMP_XB                     ; WCMP_XB = xb (slot id no longer needed)
        lda WM_TABLE+WM_OFF_Y,X
        asl a                           ; y*2 = (mid,hi) de y*512
        sta WCMP_MIDHI
        lda WCMP_XB
        xba                             ; retenue xb>>8 (0/1) en octet bas
        and #$00FF
        clc
        adc WCMP_MIDHI
        sta WCMP_MIDHI
        sep #$20
        lda WCMP_XB
        sta GFX_ARG2_LO
        lda WCMP_MIDHI
        sta GFX_ARG2_MID
        lda WCMP_MIDHI+1
        clc
        adc #$10                        ; +$100000 : base framebuffer XVGA (ADR-20)
        sta GFX_ARG2_HI
        ; byte_w = w>>1 (16-bit), byte_h = h (16-bit)  — v0.2 : stores 16-bit
        rep #$20
        lda WM_TABLE+WM_OFF_W,X
        lsr a                           ; byte_w = w>>1 (4bpp : pixels→octets)
        sta GFX_ARG3_LO                 ; 16-bit store → $76 (LO) et $77 (MID)
        lda WM_TABLE+WM_OFF_H,X         ; byte_h = h (déjà en octets ligne/ligne)
        sta GFX_ARG4_LO                 ; 16-bit store → $6E (LO) et $6F (MID)
        sep #$20
        ; ADR-27 B2.b : si le slot est en mode compact, stride source = byte_w
        ; (déjà dans GFX_ARG3_LO/HI). Sinon : laisse la stride par défaut 512.
        lda f:WCMP_SLOT_ID              ; LDX abs-long non supporté → via A+TAX
        tax                             ; X = slot id (consommé jusqu'au BLIT)
        lda f:WM_COMPACT_FLAGS,X
        cmp #WM_COMPACT_MAGIC
        bne wcmp_default_stride
        lda GFX_ARG3_LO                 ; byte_w (LO)
        sta GFX_BPL_LO
        lda GFX_ARG3_MID                ; byte_w (HI)
        sta GFX_BPL_HI
        jsr kernel_gfx_set_bpl
        bra wcmp_do_blit
wcmp_default_stride:
        ; Stride par défaut : ne touche bpl que si shadow != 0 (cas usuel : déjà 0).
        lda f:GFX_BPL_SHADOW
        ora f:GFX_BPL_SHADOW+1
        beq wcmp_do_blit
        lda #$00
        sta GFX_BPL_LO
        sta GFX_BPL_HI
        jsr kernel_gfx_set_bpl
wcmp_do_blit:
        jsr kernel_gfx_blit             ; BLIT backing store → framebuffer
wcmp_next:
        lda WCMP_SLOT
        inc a
        sta WCMP_SLOT
        jmp wcmp_loop           ; bra hors de portée → JMP absolu (même bank)
wcmp_done:
        ; ADR-27 B2.b : restaure bpl=0 (stride par défaut 512) — invariant ADR-27
        ; §0ter : `bpl` ne doit pas leak hors de compose (kernel_wm_redraw qui suit
        ; éventuellement dessine framebuffer XVGA en stride 512).
        lda f:GFX_BPL_SHADOW
        ora f:GFX_BPL_SHADOW+1
        beq wcmp_really_done
        lda #$00
        sta GFX_BPL_LO
        sta GFX_BPL_HI
        jsr kernel_gfx_set_bpl
wcmp_really_done:
        rts

; ── kernel_wm_redraw : efface le desktop + dessine toutes les fenêtres ──
; (peinture back-to-front via FILL_RECT16, coords 16-bit). Framebuffer XVGA
; à SDRAM $100000 (ADR-20). Modifie A, X, Y.
.export kernel_wm_redraw
kernel_wm_redraw:
        ; ADR-27 B2.b : peinture framebuffer XVGA direct → stride par défaut 512.
        ; Garde idempotente (no-op si shadow déjà 0, cas usuel).
        lda f:GFX_BPL_SHADOW
        ora f:GFX_BPL_SHADOW+1
        beq wmr_stride_ok
        lda #$00
        sta GFX_BPL_LO
        sta GFX_BPL_HI
        jsr kernel_gfx_set_bpl
wmr_stride_ok:
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
        ; Pattern GEOS DoIcons : visualisation hot-zones SI flag debug posé.
        ; Hors debug : hotzones invisibles par design.
        lda HOTZONE_DEBUG_FLAG
        cmp #$A5
        bne _wdo_done
        lda WIN_SLOT
        jsr _wm_draw_hotzones_for_slot
_wdo_done:
        rts

; ── _wm_draw_hotzones_for_slot : cadre 1px pour chaque hotzone active du
; slot A. Appelé uniquement quand HOTZONE_DEBUG_FLAG = $A5.
_wm_draw_hotzones_for_slot:
        sta WIN_SLOT
        ldx #$00
hzd_loop:
        lda f:HOTZONE_TABLE+0,x
        cmp #HOTZONE_F_ACTIVE
        beq hzd_check_slot
        jmp hzd_next
hzd_check_slot:
        lda f:HOTZONE_TABLE+1,x
        cmp WIN_SLOT
        beq hzd_draw
        jmp hzd_next
hzd_draw:
        phx
        rep #$20
        lda f:HOTZONE_TABLE+2,x
        sta WG_RELX
        lda f:HOTZONE_TABLE+4,x
        sta WG_RELY
        lda f:HOTZONE_TABLE+6,x
        sta WG_RELW
        lda f:HOTZONE_TABLE+8,x
        sta WG_RELH
        sep #$20
        lda WIN_SLOT
        jsr kernel_wm_offset
        rep #$20
        lda WM_TABLE+WM_OFF_X,x
        clc
        adc WG_RELX
        sta WM_ARG_X
        lda WM_TABLE+WM_OFF_Y,x
        clc
        adc WG_RELY
        sta WM_ARG_Y
        lda WG_RELW
        sta WM_ARG_W
        lda WG_RELH
        sta WM_ARG_H
        sep #$20
        lda #$08                 ; darkgray
        sta GFX_COLOR
        jsr kernel_tk_frame
        plx
hzd_next:
        txa
        clc
        adc #HOTZONE_ENTSZ
        tax
        cpx #(HOTZONE_N * HOTZONE_ENTSZ)
        bcs hzd_done
        jmp hzd_loop
hzd_done:
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
        ; FIX bug taskbar (2026-05-30) : ca65 .smart perd l'état M=16 à ce
        ; label (atteint via bcc/bcs depuis le bounds check M=16), ce qui
        ; faisait encoder `adc #TB_BTN_STRIDE` en immédiat 8-bit. En M=16
        ; runtime, le décodeur consommait alors le `8D` du `sta` suivant
        ; comme high byte → TB_BTN_X devenait $8D80 au lieu de $0080.
        ; Résultat : tous les slots > 0 considérés hors-bounds → bouton
        ; non-cliquable. .a16 force l'encodage 16-bit explicite.
        .a16
        lda TB_BTN_X
        clc
        adc #TB_BTN_STRIDE
        sta TB_BTN_X
        sep #$20
        .a8
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

; ── kernel_wm_mouse_step : wrapper IRQ (ADR-27 Étape B1) ─────────────
; Garde transparente du registre GPU `bpl` : si le syscall interrompu a
; posé `bpl ≠ 512` (compact backing-store), force `bpl = 512` le temps
; du dessin IRQ (curseur + redraws framebuffer XVGA), puis restaure.
; Fast-path : shadow == 0 (cas par défaut, aucun appelant ne touche
; encore `bpl`) → saute direct au body, surcoût ~10 cycles.
.export kernel_wm_mouse_step
kernel_wm_mouse_step:
        ; Lit le shadow kernel (mode arbitraire → sortie M=8).
        jsr kernel_gfx_get_bpl_shadow
        lda GFX_BPL_LO
        ora GFX_BPL_HI
        bne _wms_save_and_force          ; shadow ≠ 0 → save+force+restore
        jmp _wm_mouse_step_body          ; fast-path (cas par défaut)
_wms_save_and_force:
        ; Pousse le shadow courant (LO puis HI ; pop ordre inverse).
        lda GFX_BPL_LO
        pha
        lda GFX_BPL_HI
        pha
        ; Force bpl = 0 (stride par défaut 512 — framebuffer XVGA).
        lda #$00
        sta GFX_BPL_LO
        sta GFX_BPL_HI
        jsr kernel_gfx_set_bpl
        jsr _wm_mouse_step_body
        ; Restore le shadow d'avant l'IRQ.
        pla
        sta GFX_BPL_HI
        pla
        sta GFX_BPL_LO
        jsr kernel_gfx_set_bpl
        rts

; ── _wm_mouse_step_body : 1 itération event loop (clic → focus,
;    bouton tenu + mouvement → drag fenêtre focus). Lit MOUSE_*. ─────
; Pré-cond : kernel_mouse_read appelé juste avant (MOUSE_X/Y/BTN à jour).
_wm_mouse_step_body:
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
        ; SP-3.n G.3c : en mode app-driven, le shell NE ferme PAS — l'app reçoit
        ; MSG_CLOSE via le MainLoop et décide (modèle GeoWorks). Sinon (desktop
        ; sans app) : auto-close conservé (SP-3.f, test_wm_close_button).
        lda WM_APP_DRIVEN
        cmp #$A5
        beq wm_step_close_appdriven
        ; Clic sur le bouton X → ferme la fenêtre
        lda WIN_SLOT
        jsr kernel_wm_close
        lda #$00
        sta WM_DRAG_ARMED        ; désarme le drag
        jsr kernel_wm_redraw
        jsr kernel_wm_draw_cursor
        rts
wm_step_close_appdriven:
        lda #$00
        sta WM_DRAG_ARMED        ; désarme le drag (pas de fermeture : app décide)
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
        lda #$00
        sta WM_RESIZE_ARMED
        ; SP-3.o : tester d'abord si un contrôle est sous le curseur. Si oui, le
        ; clic est POUR le contrôle (toggle/scroll/bouton) → on N'ARME PAS le drag
        ; de fenêtre (sinon un drag de scrollbar déplacerait la fenêtre entière).
        jsr _wm_widget_hit       ; WIDGET_ACTIVE = contrôle touché ou $FF
        lda WIDGET_ACTIVE
        cmp #$FF
        bne wm_step_on_control
        lda #$01                 ; clic intérieur (pas un contrôle) → arme le drag
        sta WM_DRAG_ARMED
        bra wm_step_arm_done
wm_step_on_control:
        lda #$00
        sta WM_DRAG_ARMED        ; clic sur un contrôle → pas de drag fenêtre
        jsr _wm_invoke_active_cb ; action shell : bouton cb / checkbox toggle
wm_step_arm_done:
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
        tax                      ; offset entrée du widget actif
        ; SP-3.o : dispatch par type. CHECK → toggle (value en +14, PAS un
        ; callback) ; BUTTON → callback. Garde indispensable : sans elle, un clic
        ; sur une checkbox ferait jsr (value) → crash.
        lda WIDGET_TABLE+2,X
        cmp #WG_TYPE_CHECK
        beq _iac_check
        cmp #WG_TYPE_RADIO       ; SP-3.o S.4a : radio cliquable depuis le desktop
        beq _iac_radio
        cmp #WG_TYPE_TEXT        ; SP-3.o S.4b : champ texte → focus clavier
        beq _iac_text
        cmp #WG_TYPE_LIST        ; SP-3.o S.4c : liste → sélection d'item
        beq _iac_list
        cmp #WG_TYPE_BUTTON
        beq _iac_button
        rts                      ; autre type → rien
_iac_check:
        lda WIDGET_ACTIVE
        jsr kernel_ctl_toggle    ; bascule value + couleur + redraw
        rts
_iac_radio:
        lda WIDGET_ACTIVE
        jsr kernel_ctl_radio_select
        rts
_iac_text:
        lda WIDGET_ACTIVE
        sta TEXT_FOCUS_ID
        jsr kernel_wm_redraw
        rts
_iac_list:
        lda WIDGET_ACTIVE
        jsr kernel_ctl_list_select
        rts
_iac_button:
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

; ── kernel_ctl_toggle : A = id widget checkbox → bascule sa value (0↔1) ──────
; (SP-3.o S.1). Met aussi à jour la couleur (+3) pour refléter l'état coché, puis
; repeint le desktop. Clobbe A, X.
.export kernel_ctl_toggle
kernel_ctl_toggle:
        asl a
        asl a
        asl a
        asl a
        tax                      ; X = id*16
        lda WIDGET_TABLE+WG_OFF_VALUE,x
        eor #$01                 ; toggle 0↔1
        sta WIDGET_TABLE+WG_OFF_VALUE,x
        ; couleur selon l'état (coché = lightblue, décoché = lightgray)
        beq _ctog_unchecked
        lda #WG_COL_CHECKED
        bra _ctog_setcol
_ctog_unchecked:
        lda #WG_COL_UNCHECKED
_ctog_setcol:
        sta WIDGET_TABLE+3,x     ; couleur du widget
        jsr kernel_wm_redraw     ; reflète visuellement le nouvel état
        rts

; ── kernel_ctl_radio_select : A = id radio → sélection exclusive dans son groupe ─
; (SP-3.o S.4a). Le groupe = champ +15 (WG_OFF_MAX). Désélectionne tous les autres
; radios du même groupe (value=0, couleur décochée), puis sélectionne celui-ci
; (value=1, couleur cochée) et repeint. Clobbe A, X, WG_I, WG_CB.
.export kernel_ctl_radio_select
kernel_ctl_radio_select:
        sta WG_CB                ; mémorise l'id cliqué
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+WG_OFF_MAX,x
        sta WG_CB+1              ; group id du radio cliqué
        lda #$00
        sta WG_I
_crs_loop:
        lda WG_I
        cmp WIDGET_COUNT
        bcs _crs_done
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+0,x
        and #$01
        beq _crs_next            ; slot inutilisé
        lda WIDGET_TABLE+2,x
        cmp #WG_TYPE_RADIO
        bne _crs_next
        lda WIDGET_TABLE+WG_OFF_MAX,x
        cmp WG_CB+1              ; même groupe ?
        bne _crs_next
        lda #$00
        sta WIDGET_TABLE+WG_OFF_VALUE,x   ; désélectionne
        lda #WG_COL_UNCHECKED
        sta WIDGET_TABLE+3,x
_crs_next:
        lda WG_I
        inc a
        sta WG_I
        bra _crs_loop
_crs_done:
        lda WG_CB                ; sélectionne le radio cliqué
        asl a
        asl a
        asl a
        asl a
        tax
        lda #$01
        sta WIDGET_TABLE+WG_OFF_VALUE,x
        lda #WG_COL_CHECKED
        sta WIDGET_TABLE+3,x
        jsr kernel_wm_redraw
        rts

; ── _wm_text_edit : édite le buffer du champ texte focalisé (SP-3.o S.4b) ─────
; Touche ASCII en $D1. Backspace ($08/$7F) supprime le dernier caractère ;
; caractère imprimable ($20-$7E) ajouté en fin si length < maxlen. Met à jour
; length (+14) et repeint. Pointeur 24-bit DP_PTR = $01:buffer. Clobbe A,X,Y.
.export _wm_text_edit
_wm_text_edit:
        lda TEXT_FOCUS_ID
        asl a
        asl a
        asl a
        asl a
        tax                      ; X = id*16
        lda WIDGET_TABLE+12,x
        sta DP_PTR
        lda WIDGET_TABLE+13,x
        sta DP_PTR+1
        lda #$01
        sta DP_PTR+2             ; $01:buffer
        lda WIDGET_TABLE+14,x
        sta TEXT_TMP_LEN
        lda WIDGET_TABLE+15,x
        sta TEXT_TMP_MAX
        lda $D1                  ; keycode ASCII
        cmp #$08
        beq _wte_back
        cmp #$7F
        beq _wte_back
        cmp #$20
        bcc _wte_done            ; non imprimable
        cmp #$7F
        bcs _wte_done            ; >= DEL
        ; A = char imprimable. Insertion si length < maxlen.
        pha                      ; sauve char
        lda TEXT_TMP_LEN
        cmp TEXT_TMP_MAX
        bcs _wte_full            ; plein
        lda TEXT_TMP_LEN
        tay                      ; Y = length
        pla                      ; char
        sta [DP_PTR],y           ; buffer[length] = char
        iny
        lda #$00
        sta [DP_PTR],y           ; buffer[length+1] = 0
        lda TEXT_TMP_LEN
        inc a
        sta TEXT_TMP_LEN
        bra _wte_store
_wte_full:
        pla                      ; jette le char (champ plein)
        bra _wte_done
_wte_back:
        lda TEXT_TMP_LEN
        beq _wte_done            ; déjà vide
        dec a
        sta TEXT_TMP_LEN
        tay
        lda #$00
        sta [DP_PTR],y           ; buffer[length-1] = 0
_wte_store:
        lda TEXT_FOCUS_ID
        asl a
        asl a
        asl a
        asl a
        tax
        lda TEXT_TMP_LEN
        sta WIDGET_TABLE+14,x    ; length mise à jour
        lda TEXT_FOCUS_ID        ; SP-3.o S.7 : redraw ciblé du seul champ + curseur
        jsr _wm_redraw_ctl
_wte_done:
        rts

; ── kernel_ctl_list_select : A = id liste → sélectionne l'item sous la souris ─
; (SP-3.o S.4c). row = (MOUSE_Y - abs_y) / LIST_ITEM_H, clampé à [0, count-1].
; Stocke selected (+14) et repeint. abs_y = fenêtre parente + rel_y. Clobbe A,X,Y.
.export kernel_ctl_list_select
kernel_ctl_list_select:
        sta WG_CB                ; mémorise l'id
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+1,X
        sta WG_PARENT
        lda WIDGET_TABLE+15,X
        sta TEXT_TMP_MAX         ; count
        rep #$20
        lda WIDGET_TABLE+6,X
        sta WG_RELY              ; rel_y
        sep #$20
        lda WG_PARENT
        jsr kernel_wm_offset     ; X = parent*10
        rep #$20
        lda WM_TABLE+WM_OFF_Y,X
        clc
        adc WG_RELY
        sta WG_RELY              ; abs_y
        lda MOUSE_Y
        sec
        sbc WG_RELY              ; delta = MOUSE_Y - abs_y (16-bit)
        bmi _cls_zero
        lsr a                    ; / LIST_ITEM_H (16)
        lsr a
        lsr a
        lsr a
        sep #$20
        cmp TEXT_TMP_MAX         ; row >= count ?
        bcc _cls_store
        lda TEXT_TMP_MAX
        dec a                    ; clamp à count-1
        bra _cls_store
_cls_zero:
        sep #$20
        lda #$00
_cls_store:
        pha                      ; row
        lda WG_CB
        asl a
        asl a
        asl a
        asl a
        tax
        pla                      ; row
        sta WIDGET_TABLE+14,X    ; selected
        jsr kernel_wm_redraw
        rts

; ── _wm_scroll_update : met à jour la value de l'ascenseur SCROLL_DRAG_ID ─────
; (SP-3.o S.2). value = clamp(position souris - début de la gouttière, 0, max).
; V : MOUSE_Y - abs_y ; H : MOUSE_X - abs_x. Stocke value (+14), redraw.
; Temps : WG_RELX/Y (abs), WG_RELW (offset 16-bit), WG_RELH (max). Clobbe A,X,Y.
.export _wm_scroll_update          ; ADR-28 : exposé pour mesure (test scroll-cost)
_wm_scroll_update:
        ; Section critique : WG_RELX/Y/W/H sont des scratch partagés avec l'IRQ
        ; (kernel_wm_mouse_step → redraw → _wm_draw_widget_body écrit WG_RELH).
        ; Sans masquage, un mouse IRQ corrompt la COURSE (WG_RELH) entre son calcul
        ; et le clamp → la value plafonnait à mi-course (~50 %, observé interactif).
        ; Appelée uniquement depuis le MainLoop (I=0) → sei/cli (pas php/plp :
        ; éviter la désync .smart sur plp). Redraw HORS sei (cli avant) pour ne pas
        ; affamer le cursor_blit IRQ (sinon traces curseur).
        sei
        lda SCROLL_DRAG_ID
        asl a
        asl a
        asl a
        asl a
        tax                      ; X = id*16
        lda WIDGET_TABLE+2,x
        sta WG_TYPE              ; orientation
        ; SP-3.o S.7 v2 : plafond = COURSE de la gouttière (dim le long de l'axe
        ; − taille du thumb), pas le max logique → le thumb atteint le bas. Calcul
        ; 8-bit pur (dim ≤ 255, pas de rep/sep ni immédiat 16-bit ici).
        cmp #WG_TYPE_SCROLL_H
        beq _scu_dimh
        lda WIDGET_TABLE+10,x    ; V : hauteur gouttière (octet bas)
        bra _scu_dimd
_scu_dimh:
        lda WIDGET_TABLE+8,x     ; H : largeur gouttière (octet bas)
_scu_dimd:
        sec
        sbc #SCROLL_THUMB_SZ     ; course = dim − thumb
        bcs _scu_dims            ; pas d'emprunt → ≥ 0
        lda #$00                 ; dim < thumb → course nulle
_scu_dims:
        sta WG_RELH              ; course (ceiling 8-bit)
        lda WIDGET_TABLE+1,x
        sta WG_PARENT
        rep #$20
        lda WIDGET_TABLE+4,x
        sta WG_RELX
        lda WIDGET_TABLE+6,x
        sta WG_RELY
        sep #$20
        lda WG_PARENT
        jsr kernel_wm_offset     ; X = parent*10 (clobbe X)
        rep #$20
        lda WM_TABLE+WM_OFF_X,x
        clc
        adc WG_RELX
        sta WG_RELX              ; abs_x
        lda WM_TABLE+WM_OFF_Y,x
        clc
        adc WG_RELY
        sta WG_RELY              ; abs_y
        ; offset = (V) MOUSE_Y - abs_y  |  (H) MOUSE_X - abs_x   (16-bit signé)
        sep #$20
        lda WG_TYPE
        cmp #WG_TYPE_SCROLL_H
        beq _scu_h
        rep #$20
        lda MOUSE_Y
        sec
        sbc WG_RELY
        sta WG_RELW              ; offset
        sep #$20
        bra _scu_clamp
_scu_h:
        rep #$20
        lda MOUSE_X
        sec
        sbc WG_RELX
        sta WG_RELW              ; offset
        sep #$20
_scu_clamp:
        ; clamp offset [0, max] → A = value
        lda WG_RELW+1
        bmi _scu_zero            ; offset négatif (souris avant la gouttière)
        bne _scu_max             ; offset > 255 → max
        lda WG_RELW              ; 0..255
        cmp WG_RELH              ; >= max ?
        bcc _scu_store
_scu_max:
        lda WG_RELH              ; clamp à max
        bra _scu_store
_scu_zero:
        lda #$00
_scu_store:
        pha                      ; value
        lda SCROLL_DRAG_ID
        asl a
        asl a
        asl a
        asl a
        tax
        pla
        sta WIDGET_TABLE+WG_OFF_VALUE,x
        cli                      ; fin section critique (WG_* + value posés) ; I=0
                                 ; (appelée depuis le MainLoop) → redraw avec IRQ actif.
        ; SP-3.o S.7 : redraw CIBLÉ du seul ascenseur (pas de clear desktop) →
        ; plus de scintillement plein écran pendant le drag.
        lda SCROLL_DRAG_ID
        jsr _wm_redraw_ctl
        rts

; ── _wm_redraw_ctl : redraw ciblé d'un contrôle (A=index) + curseur (S.7 v2) ──
; Repeint UNIQUEMENT le contrôle puis redessine le curseur PAR-DESSUS (son fond
; sous-jacent a changé). Sous sei : le backing-store curseur (CURSOR_SAVE) est
; partagé avec l'IRQ souris (kernel_wm_cursor_blit) → section critique.
.export _wm_redraw_ctl             ; ADR-28 : exposé pour mesure (test scroll-cost)
_wm_redraw_ctl:
        php
        sei
        jsr kernel_wm_redraw_widget   ; A = index du widget
        ; ADR-29 (révèle bug §6.6) : cursor_blit (restore+save+draw) au lieu de
        ; draw_cursor (invalidate+save+draw). En §6.6 l'IRQ skip cursor_blit
        ; pendant drag widget → le curseur à l'ancienne position N'EST PAS effacé.
        ; draw_cursor invalide le backing donc ne restaure rien → trace visible.
        ; cursor_blit restaure le fond sous l'ancien curseur → trace effacée.
        jsr kernel_wm_cursor_blit
        plp
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
        ; ADR-28 §6.6 : si un drag de widget est armé (ascenseur/view), le main
        ; loop va redessiner le curseur via _wm_redraw_ctl → l'IRQ peut skipper
        ; cursor_blit (gain ≈ 3320 cyc/event ≈ 16,6 % budget frame, cf. §1.2ter).
        ; Latence curseur : ≤ 1 frame (main loop consomme 1 event/frame).
        lda SCROLL_DRAG_ID
        cmp #$FF
        beq wm_step_drag_cursor  ; pas de drag widget → cursor_blit normal
        rts                      ; drag widget actif → main loop dessine le curseur
wm_step_drag_cursor:
        jsr kernel_wm_cursor_blit
        rts
wm_step_do_drag:
        ; ADR-28 Étape 1 (D3) : skip si delta nul. Un MOVED sans déplacement réel
        ; (DX=DY=0) ne change rien à l'écran → éviter le redraw_drag (≈ 53 % du
        ; budget frame, cf. ADR-28 §1.2bis). Le curseur n'a pas bougé non plus →
        ; rien à repeindre. Allège l'IRQ sans toucher l'architecture.
        lda MOUSE_DX
        ora MOUSE_DY
        bne wm_drag_moved
        rts                      ; delta nul → no-op
wm_drag_moved:
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
        ; ADR-28 Étape 1 (D3) : skip si delta nul (cf. wm_step_do_drag).
        lda MOUSE_DX
        ora MOUSE_DY
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
; Deux modes (gate SCHED_ACTIVE, comme SYS_EXIT) :
;  - scheduler inactif (app boot-context, ex. hello_c qui n'est pas une tâche) :
;    poll + WAI (le COP a fait cli ; WAI dort jusqu'à l'IRQ KBD2). v1.
;  - scheduler actif (vraie tâche) : BLOCAGE réel (g.5) — la tâche passe BLOCKED
;    et rend le CPU ; l'IRQ KBD2 la réveille (kernel_kbd_wake). Plus de spin.
sys_read_char:
        lda SCHED_ACTIVE
        cmp #$A5
        beq sread_block_mode
        ; ── mode boot-context : spin + WAI (v1, préserve hello_c) ──
sread_wait:
        jsr kernel_kbd_ring_pop
        cmp #$00
        bne sread_done
        wai
        bra sread_wait
sread_done:
        rts                     ; A = keycode

        ; ── mode tâche : blocage réel (g.5) ───────────────────────────
sread_block_mode:
sread_loop:
        sei                     ; section critique : check ring + décision de bloc
        jsr kernel_kbd_ring_pop ; (nested sei/plp OK)
        cmp #$00
        bne sread_got           ; touche dispo
        ; ring vide ET sous sei → enregistre l'attente + bloque (pas de lost-wakeup)
        lda TASK_CUR
        sta KBD_WAITER
        ; forge la resume frame [Y][X][A][P][PCL][PCH][PBR] → reprise à sread_resume
        lda #$01
        pha                     ; PBR
        lda #>sread_resume
        pha                     ; PCH
        lda #<sread_resume
        pha                     ; PCL
        lda #$30                ; P : mode N M=X=1, I=0
        pha
        lda #$00
        pha                     ; A
        pha                     ; X
        pha                     ; Y
        lda #$00
        sta FORBID_COUNT        ; tâche suivante préemptible (on quitte le syscall le temps du bloc)
        jmp kernel_block_switch ; sauve SP→tcb[CUR].S (BLOCKED), bascule
sread_resume:                   ; rti atterrit ici au réveil (FORBID=0)
        lda #$01
        sta FORBID_COUNT        ; de retour dans le syscall
        bra sread_loop          ; re-check (la touche est là)
sread_got:
        cli                     ; libère notre sei
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
        jsr kernel_wm_close_owner ; G.5 : ferme la fenêtre de la tâche qui sort
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

; $13 — SYS_WIN_CREATE : une app ouvre sa fenêtre (SP-3.m G.2) ────────
; Args (bloc ZP ADR-17) : $D0/$D1=x, $D2/$D3=y, $D4/$D5=w, $D6/$D7=h (16-bit).
; Crée une fenêtre via kernel_wm_add (qui pose WM_OWNER[slot]=TASK_CUR appelant).
; Retour : A = handle (slot id 0..7) ou $FF si plein. Backing store SDRAM
; implicite par slot : base = ($06+slot):$0000 (64 KiB/slot ; utilisé G.4/G.4bis).
; NB : sous Forbid (pas de préemption) ; WM_ARG_* partagé avec l'IRQ souris →
; clobber possible si event souris pendant l'appel (rare ; partition ZP = polish).
sys_win_create:
        rep #$20
        lda $D0
        sta WM_ARG_X
        lda $D2
        sta WM_ARG_Y
        lda $D4
        sta WM_ARG_W
        lda $D6
        sta WM_ARG_H
        sep #$20
        lda #$00                ; v1 : pas de titre fourni par l'app
        sta WM_ARG_TITLE_LO
        sta WM_ARG_TITLE_HI
        jsr kernel_wm_add       ; A = slot id (handle) ou $FF
        cmp #$FF
        beq swc_done            ; échec → pas de focus
        ; SP-3.m G.6 : la fenêtre nouvellement créée prend le focus (comportement
        ; GUI standard) → son propriétaire reçoit le clavier (chaîne G.3).
        pha                     ; sauve le handle (valeur de retour)
        jsr kernel_wm_set_focus ; A = id
        pla                     ; restaure A = handle
swc_done:
        rts

; $14 — SYS_WIN_FLUSH : composite les backing stores → framebuffer XVGA (G.4bis)
; Après le BLIT, invalide CURSOR_VALID : le framebuffer sous le curseur a changé,
; le backing curseur (CURSOR_SAVE) est périmé. La prochaine opération curseur
; sauvegarde du contenu frais. Évite la corruption curseur stationnaire post-flush.
sys_win_flush:
        jsr kernel_wm_compose
        lda #$00
        sta CURSOR_VALID         ; invalide backing curseur (framebuffer modifié sous curseur)
        lda #$00
        rts

; $15 — SYS_EVENT_AVAIL : non-bloquant → A = 1 si un événement est dispo, 0 sinon
; (SP-3.n G.2). Permet à une app de sonder la file sans bloquer.
sys_event_avail:
        lda EVENT_RING_COUNT
        beq sea_none
        lda #$01
        rts
sea_none:
        lda #$00
        rts

; $16 — SYS_GET_NEXT_EVENT : extrait le prochain événement (SP-3.n G.2) ──
; Bloquant si la file est vide (block/wake ADR-25, réveil par IRQ via
; kernel_event_wake). Sortie : A = what (EV_*), record 10 o copié dans le bloc
; ZP $D0-$D9 (what/msg/mods/where_x/where_y/when). Calqué sur sys_read_char.
sys_get_next_event:
        lda SCHED_ACTIVE
        cmp #$A5
        beq sgne_block_mode
        ; ── mode boot-context : spin + WAI (v1) ──
sgne_wait:
        jsr kernel_event_pop    ; A = what (EV_NULL si vide), record → $D0
        cmp #EV_NULL
        bne sgne_done
        wai
        bra sgne_wait
sgne_done:
        rts
        ; ── mode tâche : blocage réel ─────────────────────────────────
sgne_block_mode:
sgne_loop:
        sei                     ; section critique : pop + décision de bloc
        jsr kernel_event_pop
        cmp #EV_NULL
        bne sgne_got            ; événement dispo
        ; file vide sous sei → enregistre l'attente + bloque (pas de lost-wakeup)
        lda TASK_CUR
        sta EVENT_WAITER
        ; forge la resume frame [Y][X][A][P][PCL][PCH][PBR] → sgne_resume
        lda #$01
        pha                     ; PBR
        lda #>sgne_resume
        pha                     ; PCH
        lda #<sgne_resume
        pha                     ; PCL
        lda #$30                ; P : mode N M=X=1, I=0
        pha
        lda #$00
        pha                     ; A
        pha                     ; X
        pha                     ; Y
        lda #$00
        sta FORBID_COUNT        ; tâche suivante préemptible pendant le bloc
        jmp kernel_block_switch
sgne_resume:                    ; rti atterrit ici au réveil (FORBID=0)
        lda #$01
        sta FORBID_COUNT        ; de retour dans le syscall
        bra sgne_loop           ; re-pop (l'événement est là)
sgne_got:
        cli                     ; libère notre sei
        rts                     ; A = what, record dans $D0-$D9

; $17 — SYS_MAIN_LOOP : bloque jusqu'à un MESSAGE sémantique (SP-3.n G.3a) ──
; Modèle GeoWorks : consomme les événements bruts de la file et les traduit en
; messages app (MSG_KEY / MSG_CONTENT / …). Les événements non significatifs
; (mouse moved/up) sont sautés (boucle). Retour : A = MSG_*, détails en $D0-$DF
; (record brut + $DA = id fenêtre pour MSG_CONTENT). `kernel_wm_mouse_step`
; (IRQ) garde focus/drag automatiques — le MainLoop ne fait que traduire.
sys_main_loop:
        lda #$A5
        sta WM_APP_DRIVEN       ; G.3c : une app pilote la boucle → close = MSG_CLOSE
        lda SCHED_ACTIVE
        cmp #$A5
        beq sml_block_mode
        ; ── mode boot-context : spin + WAI ──
sml_spin:
        jsr kernel_event_pop
        cmp #EV_NULL
        beq sml_spin_wai
        jsr _ml_classify
        cmp #MSG_NULL
        bne sml_done
        bra sml_spin
sml_spin_wai:
        wai
        bra sml_spin
sml_done:
        rts
        ; ── mode tâche : blocage réel ─────────────────────────────────
sml_block_mode:
sml_loop:
        sei
        jsr kernel_event_pop
        cmp #EV_NULL
        beq sml_block           ; file vide → bloque
        cli                     ; événement obtenu → classifie (Forbid empêche le switch)
        jsr _ml_classify
        cmp #MSG_NULL
        bne sml_ret             ; message significatif → rends-le
        bra sml_loop            ; non significatif (moved/up) → suivant
sml_block:
        lda TASK_CUR
        sta EVENT_WAITER
        lda #$01
        pha                     ; PBR
        lda #>sml_resume
        pha                     ; PCH
        lda #<sml_resume
        pha                     ; PCL
        lda #$30                ; P : mode N M=X=1, I=0
        pha
        lda #$00
        pha                     ; A
        pha                     ; X
        pha                     ; Y
        lda #$00
        sta FORBID_COUNT
        jmp kernel_block_switch
sml_resume:
        lda #$01
        sta FORBID_COUNT
        bra sml_loop
sml_ret:
        rts                     ; A = MSG_*

; ── _ml_classify : record brut en $D0-$D9 → A = MSG_* (détails en $D0-$DF) ──
; MSG_KEY (keycode en $D1) / MSG_CONTENT ($DA = id fenêtre) / MSG_NULL.
; NB : hit-test via WM_ARG_X/Y (partagé avec l'IRQ souris) — clobber rare possible.
_ml_classify:
        lda $D0                 ; what
        cmp #EV_KEY_DOWN
        bne _mlc_n_key
        jmp mlc_key
_mlc_n_key:
        cmp #EV_MOUSE_DOWN
        bne _mlc_n_md
        jmp mlc_mdown
_mlc_n_md:
        cmp #EV_MOUSE_MOVED
        bne _mlc_n_mv
        jmp mlc_moved
_mlc_n_mv:
        cmp #EV_MOUSE_UP
        bne _mlc_n_mu
        jmp mlc_up
_mlc_n_mu:
        cmp #EV_MENU_CLICK      ; ADR-30 Étape 2b
        bne _mlc_n_mc
        jmp mlc_menu
_mlc_n_mc:
        cmp #EV_TIMER           ; post-clôture ADR-30 (pattern GEOS InitProcesses)
        bne _mlc_null
        jmp mlc_timer
_mlc_null:
        lda #MSG_NULL
        rts
mlc_timer:
        ; $D1 = MSG_LO = timer_id. Expose en $DA pour l'app.
        lda $D1
        sta $DA
        lda #MSG_TIMER
        rts
mlc_menu:
        ; Payload : $D1 = item_id (0..1), $D2 = menu_id (0..1). Packé en $DA
        ; pour l'app : $DA = (menu_id << 4) | item_id (lit via oricos_msg_id).
        lda $D2
        asl a
        asl a
        asl a
        asl a
        ora $D1
        sta $DA
        lda #MSG_MENU
        rts
mlc_key:
        ; SP-3.o S.4b : si un champ texte a le focus, la touche édite son buffer
        ; (insertion / backspace) et l'app reçoit MSG_CONTROL ; sinon MSG_KEY.
        lda TEXT_FOCUS_ID
        cmp #$FF
        beq mlc_key_plain
        jsr _wm_text_edit
        lda TEXT_FOCUS_ID
        sta $DA                ; id du champ modifié
        lda #MSG_CONTROL
        rts
mlc_key_plain:
        lda #MSG_KEY           ; keycode déjà en $D1
        rts
mlc_moved:                      ; SP-3.o S.2 : si drag d'ascenseur en cours → maj value
        lda SCROLL_DRAG_ID
        cmp #$FF
        bne mlc_moved_go
        jmp mlc_null            ; pas de drag → événement ignoré
mlc_moved_go:
        jsr _wm_scroll_update       ; visuel : value + redraw widget (kernel-side, toujours)
        ; ADR-29 Étape 2 : décide DELAYED vs IMMEDIATE par widget (aligné
        ; GeoWorks `GenValueClass`). Override global `WM_DRAG_NOTIFY_HINT=$A5`
        ; force tous les widgets en IMMEDIATE (kill-switch debug). Sinon
        ; consulte `WIDGET_HINTS[id]` (0 = HINT_DRAG_DELAYED default,
        ; 1 = HINT_DRAG_IMMEDIATE opt-in).
        lda WM_DRAG_NOTIFY_HINT
        cmp #$A5
        beq mlc_moved_immediate     ; override global → IMMEDIATE
        lda SCROLL_DRAG_ID          ; abs-long (ldx n'a pas ce mode en 65816)
        tax
        lda f:WIDGET_HINTS,x        ; abs-long (WIDGET_HINTS > $FFFF)
        cmp #HINT_DRAG_IMMEDIATE
        beq mlc_moved_immediate     ; widget opt-in IMMEDIATE
        jmp mlc_null                ; DELAYED (default) → silent pendant le drag
mlc_moved_immediate:
        lda SCROLL_DRAG_ID
        sta $DA
        lda #MSG_CONTROL
        rts
mlc_up:                             ; fin de drag d'ascenseur
        lda SCROLL_DRAG_ID
        cmp #$FF
        beq mlc_up_none
        tax                         ; X = id du widget drag
        lda #$FF
        sta SCROLL_DRAG_ID
        ; ADR-29 Étape 2 : notification finale UNIQUEMENT en mode DELAYED
        ; (en IMMEDIATE, app a déjà été notifiée par le dernier MOVED).
        lda WM_DRAG_NOTIFY_HINT
        cmp #$A5
        beq mlc_up_none             ; override global IMMEDIATE → pas de notif finale
        lda f:WIDGET_HINTS,x        ; abs-long (WIDGET_HINTS > $FFFF)
        cmp #HINT_DRAG_IMMEDIATE
        beq mlc_up_none             ; widget IMMEDIATE → pas de notif finale
        stx $DA                     ; DELAYED : notification finale avec id
        lda #MSG_CONTROL
        rts
mlc_up_none:
        jmp mlc_null                ; relâché → pas de message supplémentaire
mlc_mdown:
        ; G.3c : clic dans la barre de menu (y < MENU_BAR_H) → MSG_MENU.
        lda $D7                 ; where_y high byte
        bne mlc_md_notmenu      ; y >= 256 → pas la barre de menu
        lda $D6                 ; where_y low
        cmp #MENU_BAR_H
        bcs mlc_md_notmenu
        ; ADR-30 Étape 2b polish : sentinelle $FF = bar-click (titre, pas un
        ; item). L'app doit ignorer ce MSG_MENU. L'item-click pose un payload
        ; valide via mlc_menu (path EV_MENU_CLICK, $DA = menu << 4 | item).
        lda #$FF
        sta $DA
        lda #MSG_MENU
        rts
mlc_md_notmenu:
        ; ADR-25 Disable/Enable : WM_ARG_X/Y (et MOUSE_X/Y pour _wm_chrome_hit)
        ; partagés avec l'IRQ souris. On masque l'IRQ le temps du hit-test +
        ; chrome-hit pour éviter un clobber entre l'écriture et la lecture.
        php
        sei
        rep #$20
        lda $D4                 ; where_x (16-bit)
        sta WM_ARG_X
        lda $D6                 ; where_y
        sta WM_ARG_Y
        sep #$20
        jsr kernel_wm_hit_test  ; A = id fenêtre topmost ou $FF
        cmp #$FF
        bne mlc_md_hit
        jmp mlc_md_null_plp
mlc_md_hit:
        sta $DA                 ; id fenêtre cliquée
        sta WIN_SLOT            ; pour _wm_chrome_hit
        jsr _wm_chrome_hit      ; A : 0=non, 1=close, 2=max, 3=min (MOUSE_X/Y)
        cmp #$01                ; G.3c : clic sur la case fermeture → MSG_CLOSE
        beq mlc_md_close_plp
        ; G.4 : clic sur un contrôle (bouton) de la fenêtre → MSG_CONTROL + id.
        jsr _wm_widget_hit      ; WIDGET_ACTIVE = index bouton touché, ou $FF
        plp                     ; ré-autorise l'IRQ souris
        lda WIDGET_ACTIVE
        cmp #$FF
        bne mlc_control
        ; Pattern GEOS DoIcons : avant de retomber sur MSG_CONTENT, teste
        ; les hot-zones de la fenêtre cliquée. Si hit → MSG_CONTROL + $DA
        ; = $80 | hotzone_id (l'app distingue hotzones de widgets par
        ; le bit 7 de l'id).
        lda WIN_SLOT
        jsr _wm_hotzone_hit
        cmp #$FF
        beq mlc_md_no_hotzone
        sta $DA
        lda #MSG_CONTROL
        rts
mlc_md_no_hotzone:
        lda #MSG_CONTENT        ; rien de spécial → contenu (max/min = shell)
        rts
mlc_control:
        sta $DA                 ; $DA = id contrôle (index widget) ; l'app réagit
        ; SP-3.o : action selon le type du contrôle cliqué.
        pha                     ; sauve l'id
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+2,x    ; type
        cmp #WG_TYPE_CHECK
        beq mlc_ctl_check
        cmp #WG_TYPE_SCROLL_V
        beq mlc_ctl_scroll
        cmp #WG_TYPE_SCROLL_H
        beq mlc_ctl_scroll
        cmp #WG_TYPE_VIEW       ; SP-3.o S.3 : GenView → scroll vertical (barre intégrée)
        beq mlc_ctl_scroll
        cmp #WG_TYPE_RADIO      ; SP-3.o S.4a : radio → sélection exclusive
        beq mlc_ctl_radio
        cmp #WG_TYPE_TEXT       ; SP-3.o S.4b : champ texte → prend le focus clavier
        beq mlc_ctl_text
        cmp #WG_TYPE_LIST       ; SP-3.o S.4c : liste → sélection d'item au clic
        beq mlc_ctl_list
        cmp #WG_TYPE_SPIN       ; ADR-30 Étape 4 : spin → +1/-1 selon haut/bas
        beq mlc_ctl_spin
        bra mlc_ctl_ret         ; bouton : rien de plus
mlc_ctl_check:
        pla                     ; id
        pha
        jsr kernel_ctl_toggle   ; bascule value + couleur + redraw
        bra mlc_ctl_ret
mlc_ctl_radio:
        pla                     ; id
        pha
        jsr kernel_ctl_radio_select  ; sélectionne ce radio, désélectionne le groupe
        bra mlc_ctl_ret
mlc_ctl_text:
        pla                     ; id
        pha
        sta TEXT_FOCUS_ID       ; ce champ prend le focus clavier
        jsr _wm_redraw_ctl      ; SP-3.o S.7 : redraw ciblé du champ + curseur
        bra mlc_ctl_ret
mlc_ctl_list:
        pla                     ; id
        pha
        jsr kernel_ctl_list_select  ; sélectionne l'item sous la souris + redraw
        bra mlc_ctl_ret
mlc_ctl_scroll:                 ; S.2 : arme le drag + positionne la value au clic
        pla                     ; id
        pha
        sta SCROLL_DRAG_ID
        jsr _wm_scroll_update
        bra mlc_ctl_ret
mlc_ctl_spin:                   ; ADR-30 Étape 4 : +1/-1 selon haut/bas
        pla                     ; id
        pha
        jsr kernel_ctl_spin_click
mlc_ctl_ret:
        pla                     ; jette l'id sauvé
        lda #MSG_CONTROL
        rts
mlc_md_close_plp:
        plp
        lda #MSG_CLOSE          ; $DA = id fenêtre à fermer (l'app décide)
        rts
mlc_md_null_plp:
        plp
        ; tombe dans mlc_null
mlc_null:
        lda #MSG_NULL
        rts

; $18 — SYS_UI_DEFINE : construit une fenêtre depuis une table GenUI (G.3b) ──
; Modèle déclaratif GeoWorks : l'app passe un pointer 24-bit ($D0/$D1/$D2) vers
; un flux de tags (GU_WINDOW x16 y16 w16 h16 / GU_TITLE ptr16 / GU_END). Le
; kernel parse et crée la fenêtre via kernel_wm_add (qui prend WM_ARG_* + titre).
; Retour : A = handle (slot) ou $FF. La fenêtre prend le focus (cf. sys_win_create).
; v1 : seuls GU_WINDOW/GU_TITLE ; les contrôles déclarés viendront en G.4.
sys_ui_define:
        lda #$00
        sta WM_ARG_TITLE_LO     ; défaut : pas de titre
        sta WM_ARG_TITLE_HI
        sta FIELD_STR_OFF       ; ADR-30 Étape 5 : reset buffer labels GU_FIELD
        lda #$FF
        sta DLG_WIN             ; handle « fenêtre courante » (réutilise DLG_WIN ;
                                ; ui_define et dlgbox ne tournent jamais concurremment)
        ldy #$00
sud_loop:
        lda [$D0],y             ; tag courant (pointer 24-bit en $D0-$D2)
        bne sud_notend
        jmp sud_done            ; GU_END
sud_notend:
        cmp #GU_WINDOW
        bne sud_n1
        jmp sud_window
sud_n1:
        cmp #GU_TITLE
        bne sud_n2
        jmp sud_title
sud_n2:
        cmp #GU_BUTTON
        bne sud_n2b
        jmp sud_button
sud_n2b:
        cmp #GU_VIEW
        bne sud_n2c
        jmp sud_view
sud_n2c:
        cmp #GU_CHECK
        bne sud_n2d
        jmp sud_check
sud_n2d:
        cmp #GU_SCROLL_V
        bne sud_n2e
        jmp sud_scrollv
sud_n2e:
        cmp #GU_SCROLL_H
        bne sud_n2f
        jmp sud_scrollh
sud_n2f:
        cmp #GU_RADIO
        bne sud_n2g
        jmp sud_radio
sud_n2g:
        cmp #GU_TEXT
        bne sud_n2gg
        jmp sud_text
sud_n2gg:
        cmp #GU_LIST            ; ADR-30 Étape 1 : liste déclarative (aligné GenList)
        bne sud_n2h
        jmp sud_list
sud_n2h:
        cmp #GU_HINT_IMMEDIATE_DRAG_NOTIFY    ; ADR-29 Étape 2 : opt-in IMMEDIATE
        bne sud_n2i
        jmp sud_hint_immediate
sud_n2i:
        cmp #GU_HINT_MIN_VALUE  ; ADR-30 Étape 3 : attribut min (GenValue MINIMUM)
        bne sud_n2j
        jmp sud_hint_min_value
sud_n2j:
        cmp #GU_MENU            ; ADR-30 Étape 2 : ouvre un menu
        bne sud_n2k
        jmp sud_menu
sud_n2k:
        cmp #GU_MENU_ITEM       ; ADR-30 Étape 2 : ajoute un item au dernier menu
        bne sud_n2l
        jmp sud_menu_item
sud_n2l:
        cmp #GU_SPIN            ; ADR-30 Étape 4 : incrémenteur (GenValue/SpinClass)
        bne sud_n2m
        jmp sud_spin
sud_n2m:
        cmp #GU_FIELD           ; ADR-30 Étape 5 : champ étiqueté (gFieldC)
        bne sud_n2n
        jmp sud_field
sud_n2n:
        cmp #GU_SUBMENU         ; ADR-30 post-clôture : menu caché
        bne sud_n2o
        jmp sud_submenu
sud_n2o:
        cmp #GU_MENU_OPEN       ; ADR-30 post-clôture : item ouvre submenu
        bne sud_n3
        jmp sud_menu_open
sud_n3:
        jmp sud_done            ; tag inconnu → stop sécurité
sud_hint_immediate:                ; ADR-29 Étape 2 : tag seul, pose hint en attente
        lda #HINT_DRAG_IMMEDIATE
        sta UI_PENDING_HINT     ; sera copié sur le prochain widget par kernel_wm_add_widget
        iny                     ; consomme le tag (pas de data)
        jmp sud_loop
sud_hint_min_value:                ; ADR-30 Étape 3 : tag + 1 byte (min)
        iny                     ; passe tag
        lda [$D0],y             ; A = min
        sta UI_PENDING_MIN_VALUE
        iny                     ; consomme byte payload
        jmp sud_loop
sud_title:                      ; GU_TITLE + chaîne inline (AVANT GU_WINDOW)
        iny                     ; Y → 1er caractère du titre
        jsr _sud_copy_inline    ; copie la chaîne inline → UI_STR_BUF (Y avance après le null)
        lda #<UI_STR_BUF
        sta WM_ARG_TITLE_LO
        lda #>UI_STR_BUF
        sta WM_ARG_TITLE_HI
        jmp sud_loop
sud_window:
        iny                     ; passe le tag → x16 y16 w16 h16
        lda [$D0],y
        sta WM_ARG_X
        iny
        lda [$D0],y
        sta WM_ARG_X+1
        iny
        lda [$D0],y
        sta WM_ARG_Y
        iny
        lda [$D0],y
        sta WM_ARG_Y+1
        iny
        lda [$D0],y
        sta WM_ARG_W
        iny
        lda [$D0],y
        sta WM_ARG_W+1
        iny
        lda [$D0],y
        sta WM_ARG_H
        iny
        lda [$D0],y
        sta WM_ARG_H+1
        iny
        ; crée la fenêtre maintenant (les GU_BUTTON suivants s'y attachent)
        phy
        jsr kernel_wm_add       ; A = handle ou $FF
        ply
        sta DLG_WIN
        cmp #$FF
        bne sud_w_focus
        jmp sud_loop            ; échec création → ignore les boutons
sud_w_focus:
        lda DLG_WIN
        phy
        jsr kernel_wm_set_focus ; la fenêtre déclarée prend le focus (chaîne G.3)
        ply
        jmp sud_loop
sud_button:                     ; GU_BUTTON : relx16 rely16 relw16 relh16 (8 o)
        iny
        lda [$D0],y
        sta WM_ARG_X
        iny
        lda [$D0],y
        sta WM_ARG_X+1
        iny
        lda [$D0],y
        sta WM_ARG_Y
        iny
        lda [$D0],y
        sta WM_ARG_Y+1
        iny
        lda [$D0],y
        sta WM_ARG_W
        iny
        lda [$D0],y
        sta WM_ARG_W+1
        iny
        lda [$D0],y
        sta WM_ARG_H
        iny
        lda [$D0],y
        sta WM_ARG_H+1
        iny
        ; label INLINE du bouton → staging bank 1 (Y avance après le null)
        jsr _sud_copy_inline
        ; attache le bouton à la fenêtre courante
        lda DLG_WIN
        cmp #$FF
        bne sud_b_add
        jmp sud_loop            ; pas de fenêtre → ignore
sud_b_add:
        sta WG_PARENT
        lda #WG_TYPE_BUTTON
        sta WG_TYPE
        lda #$07
        sta GFX_COLOR
        lda #<UI_STR_BUF        ; label inline stagé en bank 1
        sta DP_PCPTR
        lda #>UI_STR_BUF
        sta DP_PCPTR+1
        lda #$00
        sta WG_CB
        sta WG_CB+1
        phy
        jsr kernel_wm_add_widget
        ply
        jmp sud_loop
sud_view:                       ; GU_VIEW : relx16 rely16 relw16 relh16 + max8
        iny
        lda [$D0],y
        sta WM_ARG_X
        iny
        lda [$D0],y
        sta WM_ARG_X+1
        iny
        lda [$D0],y
        sta WM_ARG_Y
        iny
        lda [$D0],y
        sta WM_ARG_Y+1
        iny
        lda [$D0],y
        sta WM_ARG_W
        iny
        lda [$D0],y
        sta WM_ARG_W+1
        iny
        lda [$D0],y
        sta WM_ARG_H
        iny
        lda [$D0],y
        sta WM_ARG_H+1
        iny
        lda [$D0],y
        sta WG_CB+1             ; max scroll (+15)
        iny
        lda DLG_WIN
        cmp #$FF
        bne sud_v_add
        jmp sud_loop
sud_v_add:
        sta WG_PARENT
        lda #WG_TYPE_VIEW
        sta WG_TYPE
        lda #WG_COL_VIEW_BODY
        sta GFX_COLOR
        lda #$00
        sta DP_PCPTR
        sta DP_PCPTR+1          ; pas de label
        sta WG_CB               ; scroll_y init 0 (+14) ; WG_CB+1=max déjà posé
        phy
        jsr kernel_wm_add_widget
        ply
        jmp sud_loop

; ── _sud_rect : lit relx16 rely16 relw16 relh16 → WM_ARG_X/Y/W/H (SP-3.o S.5) ──
; Entrée : Y pointe sur le tag. Sortie : Y → 1er octet extra (après les 8 o rect).
_sud_rect:
        iny
        lda [$D0],y
        sta WM_ARG_X
        iny
        lda [$D0],y
        sta WM_ARG_X+1
        iny
        lda [$D0],y
        sta WM_ARG_Y
        iny
        lda [$D0],y
        sta WM_ARG_Y+1
        iny
        lda [$D0],y
        sta WM_ARG_W
        iny
        lda [$D0],y
        sta WM_ARG_W+1
        iny
        lda [$D0],y
        sta WM_ARG_H
        iny
        lda [$D0],y
        sta WM_ARG_H+1
        iny
        rts

; ── _sud_attach : attache le widget courant à DLG_WIN (si valide) (SP-3.o S.5) ──
; Préserve Y. WG_TYPE/GFX_COLOR/DP_PCPTR/WG_CB/WM_ARG_* doivent être posés.
_sud_attach:
        lda DLG_WIN
        cmp #$FF
        beq _sa_skip
        sta WG_PARENT
        phy
        jsr kernel_wm_add_widget
        ply
_sa_skip:
        rts

; ── sud_check : GU_CHECK relx16 rely16 relw16 relh16 + value8 ────────────────
sud_check:
        jsr _sud_rect           ; Y → value
        lda [$D0],y
        sta WG_CB               ; value (+14)
        iny
        lda #$00
        sta WG_CB+1
        ldx #WG_COL_UNCHECKED
        lda WG_CB
        beq sud_ck_col
        ldx #WG_COL_CHECKED
sud_ck_col:
        stx GFX_COLOR
        lda #WG_TYPE_CHECK
        sta WG_TYPE
        lda #$00
        sta DP_PCPTR
        sta DP_PCPTR+1
        jsr _sud_attach
        jmp sud_loop

; ── sud_radio : GU_RADIO relx16 rely16 relw16 relh16 + value8 + group8 ───────
sud_radio:
        jsr _sud_rect           ; Y → value
        lda [$D0],y
        sta WG_CB               ; value (+14)
        iny
        lda [$D0],y
        sta WG_CB+1             ; group (+15)
        iny
        ldx #WG_COL_UNCHECKED
        lda WG_CB
        beq sud_rd_col
        ldx #WG_COL_CHECKED
sud_rd_col:
        stx GFX_COLOR
        lda #WG_TYPE_RADIO
        sta WG_TYPE
        lda #$00
        sta DP_PCPTR
        sta DP_PCPTR+1
        jsr _sud_attach
        jmp sud_loop

; ── ADR-30 Étape 5 : sud_field — champ étiqueté (gFieldC).
; Format : GU_FIELD relx16 rely16 relw16 relh16 + label inline null-term.
; Label copié bank app → FIELD_STR_BUF (bank 1). Value (+14) init 0. Non
; cliquable, mis à jour via SYS_CTL_SET_VALUE.
sud_field:
        jsr _sud_rect           ; Y → premier byte label
        ; Copie label inline → FIELD_STR_BUF[FIELD_STR_OFF]. Sauve le ptr.
        lda #<FIELD_STR_BUF
        clc
        adc FIELD_STR_OFF
        sta WG_RELX             ; lo du ptr (16-bit dans bank 1)
        lda #>FIELD_STR_BUF
        adc #$00                ; carry propag.
        sta WG_RELX+1
        lda FIELD_STR_OFF
        tax
_sud_fld_loop:
        lda [$D0],y
        sta f:FIELD_STR_BUF,x
        iny
        inx
        cmp #$00
        beq _sud_fld_done
        cpx #127                ; cap buffer 128 octets (laisse 1 pour null)
        bcc _sud_fld_loop
        lda #$00
        sta f:FIELD_STR_BUF,x
        inx
_sud_fld_done:
        txa
        sta FIELD_STR_OFF
        ; Pose strptr = WG_RELX (lo/hi 16-bit bank 1).
        lda WG_RELX
        sta DP_PCPTR
        lda WG_RELX+1
        sta DP_PCPTR+1
        lda #$00
        sta WG_CB               ; value init 0 (+14)
        sta WG_CB+1             ; +15 inutilisé (pas de max)
        lda #$07                ; lightgray
        sta GFX_COLOR
        lda #WG_TYPE_FIELD
        sta WG_TYPE
        jsr _sud_attach
        jmp sud_loop

; ── ADR-30 Étape 4 : sud_spin — incrémenteur (GenValue/SpinClass).
; Format : GU_SPIN relx16 rely16 relw16 relh16 max8. Value (+14) init 0,
; max (+15). Click haut moitié = +1, bas moitié = -1, clamp [min..max].
sud_spin:
        jsr _sud_rect           ; Y → max8
        lda #$00
        sta WG_CB               ; value = 0 (+14)
        lda [$D0],y
        sta WG_CB+1             ; max (+15)
        iny
        lda #$07                ; lightgray (cohérent text/list)
        sta GFX_COLOR
        lda #$00
        sta DP_PCPTR
        sta DP_PCPTR+1
        lda #WG_TYPE_SPIN
        sta WG_TYPE
        jsr _sud_attach
        jmp sud_loop

; ── sud_scrollv / sud_scrollh : GU_SCROLL_* relx16..relh16 + max8 ────────────
sud_scrollv:
        lda #WG_TYPE_SCROLL_V
        bra sud_scroll_common
sud_scrollh:
        lda #WG_TYPE_SCROLL_H
sud_scroll_common:
        sta WG_TYPE
        jsr _sud_rect           ; Y → max
        lda #$00
        sta WG_CB               ; value = 0 (+14)
        lda [$D0],y
        sta WG_CB+1             ; max (+15)
        iny
        lda #WG_COL_TRACK
        sta GFX_COLOR
        lda #$00
        sta DP_PCPTR
        sta DP_PCPTR+1
        jsr _sud_attach
        jmp sud_loop

; ── sud_text : GU_TEXT relx16 rely16 relw16 relh16 + maxlen8 ─────────────────
; ── ADR-30 Étape 1 : GU_LIST déclaratif (alignement GeoWorks GenList/gListC.def)
; Format : GU_LIST relx16 rely16 relw16 relh16 count8 (count strings null-term).
; Items copiés depuis [$D0],Y (bank app) → UI_LIST_BUF (bank 1, 128 octets).
; Items équivalents aux text monikers de GeoWorks (NULL_TERM_TEXT_FPTR).
sud_list:
        jsr _sud_rect           ; Y → count8
        lda [$D0],y             ; A = count
        sta WG_CB+1             ; +15 = count
        sta DP_TMP              ; scratch boucle
        iny                     ; Y → premier byte du blob d'items
        ldx #$00                ; X = offset dans UI_LIST_BUF
        lda DP_TMP
        beq _sul_done           ; count = 0 → rien à copier
_sul_loop:
        lda [$D0],y
        sta f:UI_LIST_BUF,x
        iny
        inx
        cpx #$80                ; 128 octets max → protection débordement buffer
        bcs _sul_done
        cmp #$00
        bne _sul_loop           ; pas le null → continue dans même string
        ; null copié = fin string. Décrémente count.
        dec DP_TMP
        bne _sul_loop           ; encore des strings → continue
_sul_done:
        lda #$00
        sta WG_CB               ; +14 = selected = 0 par défaut
        lda #<UI_LIST_BUF
        sta DP_PCPTR            ; strptr → UI_LIST_BUF en bank 1
        lda #>UI_LIST_BUF
        sta DP_PCPTR+1
        lda #$07                ; couleur lightgray (cohérent task_list_entry)
        sta GFX_COLOR
        lda #WG_TYPE_LIST
        sta WG_TYPE
        jsr _sud_attach
        jmp sud_loop

sud_text:
        jsr _sud_rect           ; Y → maxlen
        lda #$00
        sta WG_CB               ; value (ignoré, mis à 0 par add_widget pour TEXT)
        lda [$D0],y
        sta WG_CB+1             ; maxlen (+15)
        iny
        lda #$0F
        sta GFX_COLOR
        lda #$00
        sta DP_PCPTR
        sta DP_PCPTR+1          ; strptr auto-câblé par kernel_wm_add_widget
        lda #WG_TYPE_TEXT
        sta WG_TYPE
        jsr _sud_attach
        jmp sud_loop

; ── ADR-30 Étape 2 : parsers GU_MENU + GU_MENU_ITEM ─────────────────────
; sud_menu : tag GU_MENU + chaîne titre inline null-term. Ouvre un nouveau
; menu dans `menu_defs` (override le statique au premier appel). Y pointe
; sur le tag GU_MENU à l'entrée. CB = 0 v1 (clic consommé silencieusement).
sud_menu:
        ; Premier GU_MENU rencontré ? Init structures + zéroise menu_defs.
        lda MENU_DYN_ACTIVE
        cmp #$A5
        beq sud_m_ready
        lda #$A5
        sta MENU_DYN_ACTIVE
        lda #$00
        sta MENU_DYN_COUNT
        sta MENU_DYN_COUNT_BAR
        sta MENU_DYN_ITEM_CNT
        sta MENU_DYN_STR_OFF
        ; Zéroise les MENU_TOTAL_N*16 = 64 octets de menu_defs (top + submenus).
        ldx #$00
sud_m_zero:
        lda #$00
        sta f:menu_defs+$10000,x
        inx
        cpx #(MENU_TOTAL_N * MENU_ENTSZ)
        bcc sud_m_zero
sud_m_ready:
        ; Cap : MENU_DYN_COUNT_BAR >= MENU_N → drop silencieux (consomme la chaîne).
        lda MENU_DYN_COUNT_BAR
        cmp #MENU_N
        bcs sud_m_skip
        ; Copie la chaîne inline → MENU_DYN_STR_BUF[STR_OFF], avance STR_OFF.
        iny                     ; passe le tag GU_MENU
        jsr _sud_menu_copy_str  ; entrée str_ptr (low/high) en WG_RELX, Y avance
        ; Compute slot_offset = MENU_DYN_COUNT * MENU_ENTSZ
        lda MENU_DYN_COUNT
        asl a
        asl a
        asl a
        asl a                   ; *16
        tax
        ; Écrit title_ptr (16-bit, dans bank 1) à menu_defs[slot+0/+1]
        lda WG_RELX             ; lo
        sta f:menu_defs+$10000+0,x
        lda WG_RELX+1           ; hi
        sta f:menu_defs+$10000+1,x
        ; bar_x : top menu N = 4 + N*72 (slot top-bar). Submenu = parent_bar_x+64.
        ; Ici top-bar : utilise MENU_DYN_COUNT_BAR (sera 0 ou 1).
        lda MENU_DYN_COUNT_BAR
        bne sud_m_bx_1
        lda #4
        bra sud_m_bx_set
sud_m_bx_1:
        lda #76
sud_m_bx_set:
        sta f:menu_defs+$10000+2,x     ; bar_x à offset +2
        ; Reset item count, bump menu counts (total + bar)
        lda #$00
        sta MENU_DYN_ITEM_CNT
        lda MENU_DYN_COUNT
        inc a
        sta MENU_DYN_COUNT
        lda MENU_DYN_COUNT_BAR
        inc a
        sta MENU_DYN_COUNT_BAR
        jmp sud_loop
sud_m_skip:
        ; Drop : consomme tag + chaîne sans l'enregistrer
        iny
        jsr _sud_skip_inline
        jmp sud_loop

; ── ADR-30 post-clôture : sud_submenu — comme sud_menu mais hors top-bar ───
; (pattern GEOS DoMenu). Crée un menu caché ouvert sur clic d'un GU_MENU_OPEN.
sud_submenu:
        ; Premier menu (top OU submenu) ? Init si nécessaire.
        lda MENU_DYN_ACTIVE
        cmp #$A5
        beq sud_sm_ready
        lda #$A5
        sta MENU_DYN_ACTIVE
        lda #$00
        sta MENU_DYN_COUNT
        sta MENU_DYN_COUNT_BAR
        sta MENU_DYN_ITEM_CNT
        sta MENU_DYN_STR_OFF
        ldx #$00
sud_sm_zero:
        lda #$00
        sta f:menu_defs+$10000,x
        inx
        cpx #(MENU_TOTAL_N * MENU_ENTSZ)
        bcc sud_sm_zero
sud_sm_ready:
        ; Cap : MENU_DYN_COUNT >= MENU_TOTAL_N → drop.
        lda MENU_DYN_COUNT
        cmp #MENU_TOTAL_N
        bcs sud_sm_skip
        iny                     ; passe tag GU_SUBMENU
        jsr _sud_menu_copy_str  ; → WG_RELX = ptr, Y avance
        lda MENU_DYN_COUNT
        asl a
        asl a
        asl a
        asl a                   ; *16
        tax
        lda WG_RELX
        sta f:menu_defs+$10000+0,x
        lda WG_RELX+1
        sta f:menu_defs+$10000+1,x
        ; bar_x submenu : décalage du dernier top menu + 64 (à droite de l'item).
        ; Pour MVP : (MENU_DYN_COUNT - MENU_DYN_COUNT_BAR + 1) * 64 (slots droite).
        lda MENU_DYN_COUNT
        sec
        sbc MENU_DYN_COUNT_BAR
        clc
        adc #1
        asl a
        asl a
        asl a
        asl a
        asl a
        asl a                   ; *64
        clc
        adc #76                 ; offset après les top menus
        sta f:menu_defs+$10000+2,x  ; bar_x submenu
        lda #$00
        sta MENU_DYN_ITEM_CNT
        lda MENU_DYN_COUNT
        inc a
        sta MENU_DYN_COUNT
        jmp sud_loop
sud_sm_skip:
        iny
        jsr _sud_skip_inline
        jmp sud_loop

; ── ADR-30 post-clôture : sud_menu_open — item qui ouvre un sub-menu ────
; Format : GU_MENU_OPEN + label inline + submenu_idx8. cb_lo = idx, cb_hi = $80.
sud_menu_open:
        lda MENU_DYN_COUNT
        beq sud_mo_skip
        lda MENU_DYN_ITEM_CNT
        cmp #2
        bcs sud_mo_skip
        iny                     ; passe le tag
        jsr _sud_menu_copy_str  ; → WG_RELX/+1 = ptr label, Y → submenu_idx
        ; Lit submenu_idx (1 byte) AVANT de clobber les scratch.
        lda [$D0],y
        sta SPIN_ID             ; SPIN_ID = submenu_idx (cb_lo target)
        iny                     ; consomme payload
        ; slot menu : (COUNT-1)*16 → SPIN_TMP
        lda MENU_DYN_COUNT
        sec
        sbc #1
        asl a
        asl a
        asl a
        asl a
        sta SPIN_TMP
        ; item offset : +4 (item0) ou +8 (item1)
        lda MENU_DYN_ITEM_CNT
        bne sud_mo_it1
        lda SPIN_TMP
        clc
        adc #4
        tax
        bra sud_mo_write
sud_mo_it1:
        lda SPIN_TMP
        clc
        adc #8
        tax
sud_mo_write:
        lda WG_RELX             ; ptr label lo (préservé par copy_str)
        sta f:menu_defs+$10000+0,x
        lda WG_RELX+1           ; ptr label hi
        sta f:menu_defs+$10000+1,x
        lda SPIN_ID             ; cb_lo = submenu_idx
        sta f:menu_defs+$10000+2,x
        lda #$80                ; cb_hi = $80 (= flag « submenu link »)
        sta f:menu_defs+$10000+3,x
        lda MENU_DYN_ITEM_CNT
        inc a
        sta MENU_DYN_ITEM_CNT
        jmp sud_loop
sud_mo_skip:
        iny
        jsr _sud_skip_inline
        iny                     ; consomme payload submenu_idx
        jmp sud_loop

; sud_menu_item : tag GU_MENU_ITEM + label inline null-term. Ajoute un item
; au dernier menu déclaré. Cap MENU_DYN_ITEM_CNT < 2 (slots item0/item1 fixes).
sud_menu_item:
        lda MENU_DYN_COUNT
        beq sud_mi_skip         ; pas de menu ouvert → drop
        lda MENU_DYN_ITEM_CNT
        cmp #2
        bcs sud_mi_skip
        iny                     ; passe le tag
        jsr _sud_menu_copy_str  ; → WG_RELX = ptr, Y avancé
        ; slot_offset = (MENU_DYN_COUNT - 1) * MENU_ENTSZ
        lda MENU_DYN_COUNT
        sec
        sbc #1
        asl a
        asl a
        asl a
        asl a                   ; *16
        sta WG_RELY             ; sauve slot offset menu (8-bit)
        ; item offset dans le slot : +4 si item0, +8 si item1
        lda MENU_DYN_ITEM_CNT
        bne sud_mi_it1
        ; item0 : str à +4, cb à +6
        lda WG_RELY
        clc
        adc #4
        tax
        bra sud_mi_write
sud_mi_it1:
        lda WG_RELY
        clc
        adc #8                  ; item1 : str à +8, cb à +10
        tax
sud_mi_write:
        lda WG_RELX             ; str_ptr lo
        sta f:menu_defs+$10000+0,x
        lda WG_RELX+1
        sta f:menu_defs+$10000+1,x
        lda #$00                ; cb = 0 (silencieux v1)
        sta f:menu_defs+$10000+2,x
        sta f:menu_defs+$10000+3,x
        ; Bump item count
        lda MENU_DYN_ITEM_CNT
        inc a
        sta MENU_DYN_ITEM_CNT
        jmp sud_loop
sud_mi_skip:
        iny
        jsr _sud_skip_inline
        jmp sud_loop

; _sud_menu_copy_str : copie [$D0],y (bank app) → MENU_DYN_STR_BUF[STR_OFF].
; Retour : WG_RELX = pointeur 16-bit absolu vers la chaîne (bank 1). STR_OFF
; avancé après le null. Y avance après le null. Trunque à 31 chars + null.
_sud_menu_copy_str:
        ; Capture le ptr du début (MENU_DYN_STR_BUF + STR_OFF).
        lda #<MENU_DYN_STR_BUF
        clc
        adc MENU_DYN_STR_OFF
        sta WG_RELX
        lda #>MENU_DYN_STR_BUF
        adc #$00                ; propage carry
        sta WG_RELX+1
        ; Copie : X = index dans le buffer global = STR_OFF
        lda MENU_DYN_STR_OFF
        tax
_sumcs_loop:
        lda [$D0],y
        sta f:MENU_DYN_STR_BUF,x
        iny
        inx
        cmp #$00
        beq _sumcs_done
        cpx #191
        bcc _sumcs_loop
        lda #$00
        sta f:MENU_DYN_STR_BUF,x
        inx
_sumcs_done:
        txa
        sta MENU_DYN_STR_OFF
        rts

; _sud_skip_inline : avance Y jusqu'APRÈS le null (pour les tags droppés).
_sud_skip_inline:
_susi_loop:
        lda [$D0],y
        iny
        cmp #$00
        bne _susi_loop
        rts

; ── _sud_copy_inline : copie la chaîne inline [$D0],y (bank app) → UI_STR_BUF ──
; (bank 1, null-terminée, max 31 + null). Y avance jusqu'APRÈS le null. Clobbe A,X.
_sud_copy_inline:
        ldx #$00
_sci_loop:
        lda [$D0],y
        sta f:UI_STR_BUF,x
        iny
        cmp #$00                ; le caractère copié était-il le null ?
        beq _sci_done
        inx
        cpx #31
        bcc _sci_loop
        lda #$00                ; tronque + force null à 31
        sta f:UI_STR_BUF,x
_sci_done:
        rts
sud_done:
        ; G.7 : repeint le desktop pour que l'UI déclarée apparaisse tout de suite
        ; (sans attendre un événement souris). Sûr en contexte syscall (Forbid).
        lda DLG_WIN
        cmp #$FF
        beq sud_noredraw
        jsr kernel_wm_redraw
sud_noredraw:
        lda DLG_WIN             ; A = handle de la fenêtre créée ($FF si aucune)
sud_ret:
        rts

; $19 — SYS_DO_DLGBOX : dialogue modal défini par une command table (G.5) ──
; Modèle GEOS : l'app passe un pointer 24-bit ($D0-$D2) vers une table DB_*
; (DB_POSITION x16 y16 w16 h16 / DB_OK / DB_CANCEL / DB_END). Le kernel crée une
; fenêtre modale + les boutons, puis exécute une BOUCLE MODALE (UI-modal : la
; saisie va au dialogue, WM_MODAL ; la tâche appelante bloque et rend le CPU via
; kernel_event_wait). Retour : A = 1 (OK) ou 0 (Cancel). Boutons auto-positionnés.
sys_do_dlgbox:
        lda #$FF
        sta DLG_OK_ID
        sta DLG_CANCEL_ID
        lda #$00
        sta DLG_RESULT
        ldy #$00
ddb_parse:
        lda [$D0],y
        bne ddb_p1
        jmp ddb_show            ; DB_END
ddb_p1:
        cmp #DB_POSITION
        bne ddb_p2
        jmp ddb_pos
ddb_p2:
        cmp #DB_OK
        bne ddb_p3
        jmp ddb_addok
ddb_p3:
        cmp #DB_CANCEL
        bne ddb_p4
        jmp ddb_addcancel
ddb_p4:
        jmp ddb_show            ; tag inconnu → stop
ddb_pos:
        iny
        lda [$D0],y
        sta WM_ARG_X
        iny
        lda [$D0],y
        sta WM_ARG_X+1
        iny
        lda [$D0],y
        sta WM_ARG_Y
        iny
        lda [$D0],y
        sta WM_ARG_Y+1
        iny
        lda [$D0],y
        sta WM_ARG_W
        iny
        lda [$D0],y
        sta WM_ARG_W+1
        iny
        lda [$D0],y
        sta WM_ARG_H
        iny
        lda [$D0],y
        sta WM_ARG_H+1
        iny
        ; crée la fenêtre dialogue (sans titre v1) + la passe modale
        lda #$00
        sta WM_ARG_TITLE_LO
        sta WM_ARG_TITLE_HI
        phy
        jsr kernel_wm_add       ; A = handle
        ply
        sta DLG_WIN
        jsr kernel_wm_set_modal ; A = DLG_WIN → WM_MODAL
        jmp ddb_parse
ddb_addok:
        iny
        lda WIDGET_COUNT        ; id = index du nouveau widget
        sta DLG_OK_ID
        lda #<db_str_ok         ; label "OK"
        sta DP_PCPTR
        lda #>db_str_ok
        sta DP_PCPTR+1
        lda #10                 ; rel x
        ldx #50                 ; rel y
        jsr _ddb_add_button
        jmp ddb_parse
ddb_addcancel:
        iny
        lda WIDGET_COUNT
        sta DLG_CANCEL_ID
        lda #<db_str_cancel     ; label "Cancel"
        sta DP_PCPTR
        lda #>db_str_cancel
        sta DP_PCPTR+1
        lda #60                 ; rel x
        ldx #50                 ; rel y
        jsr _ddb_add_button
        jmp ddb_parse
ddb_show:
        ; ── boucle modale : attend un clic sur un bouton terminant ──
ddb_loop:
        jsr kernel_event_wait   ; bloque jusqu'à un événement (rend le CPU)
        jsr kernel_event_pop    ; A = what, record en $D0
        cmp #EV_MOUSE_DOWN
        bne ddb_loop            ; ignore tout sauf un clic
        php
        sei                     ; _wm_widget_hit lit MOUSE_X/Y (partagé IRQ)
        jsr _wm_widget_hit      ; WIDGET_ACTIVE = index bouton ou $FF
        plp
        lda WIDGET_ACTIVE
        cmp #$FF
        beq ddb_loop            ; rien touché → continue (modal)
        cmp DLG_OK_ID
        beq ddb_hit_ok
        cmp DLG_CANCEL_ID
        beq ddb_hit_cancel
        bra ddb_loop            ; autre widget → continue
ddb_hit_ok:
        lda #$01
        sta DLG_RESULT
        bra ddb_close
ddb_hit_cancel:
        lda #$00
        sta DLG_RESULT
ddb_close:
        jsr kernel_wm_clear_modal
        lda DLG_WIN
        jsr kernel_wm_close
        lda DLG_RESULT
        rts

; $1A — SYS_ALERT : alerte pré-câblée (SP-3.n G.6) ────────────────────
; Arg X (DP_SYS_ARG_X) = type : 0=OK, 1=OK-Cancel, 2=Yes-No. Construit une
; fenêtre modale fixe + 1 ou 2 boutons, puis réutilise la boucle modale de
; DoDlgBox (jmp ddb_show). Retour A = 1 (gauche : OK/Yes) ou 0 (droite : Cancel/No).
; v1 : pas de texte de message (label cosmétique reporté) ; libellés boutons = "OK".
sys_alert:
        lda #$FF
        sta DLG_OK_ID
        sta DLG_CANCEL_ID
        lda #$00
        sta DLG_RESULT
        ; fenêtre d'alerte fixe (280,260,180,70)
        rep #$20
        lda #280
        sta WM_ARG_X
        lda #260
        sta WM_ARG_Y
        lda #180
        sta WM_ARG_W
        lda #70
        sta WM_ARG_H
        sep #$20
        lda #$00
        sta WM_ARG_TITLE_LO
        sta WM_ARG_TITLE_HI
        jsr kernel_wm_add       ; A = handle
        sta DLG_WIN
        jsr kernel_wm_set_modal
        ; bouton gauche (terminant → retour 1) : label "Yes" si YESNO, sinon "OK"
        lda DP_SYS_ARG_X
        cmp #ALERT_YESNO
        beq sa_left_yes
        lda #<db_str_ok
        sta DP_PCPTR
        lda #>db_str_ok
        sta DP_PCPTR+1
        bra sa_left_go
sa_left_yes:
        lda #<db_str_yes
        sta DP_PCPTR
        lda #>db_str_yes
        sta DP_PCPTR+1
sa_left_go:
        lda WIDGET_COUNT
        sta DLG_OK_ID
        lda #10
        ldx #44
        jsr _ddb_add_button
        ; si type != ALERT_OK, bouton droit (retour 0) : "No" si YESNO sinon "Cancel"
        lda DP_SYS_ARG_X
        beq sa_run
        cmp #ALERT_YESNO
        beq sa_right_no
        lda #<db_str_cancel
        sta DP_PCPTR
        lda #>db_str_cancel
        sta DP_PCPTR+1
        bra sa_right_go
sa_right_no:
        lda #<db_str_no
        sta DP_PCPTR
        lda #>db_str_no
        sta DP_PCPTR+1
sa_right_go:
        lda WIDGET_COUNT
        sta DLG_CANCEL_ID
        lda #100
        ldx #44
        jsr _ddb_add_button
sa_run:
        jmp ddb_show            ; réutilise la boucle modale (rts → COP handler)

; ── _ddb_add_button : ajoute un bouton dialogue (DLG_WIN, 44×18). A = rel x,
; X = rel y. Le LABEL est posé par l'appelant dans DP_PCPTR (chaîne bank 1)
; AVANT l'appel → libellés distincts OK/Cancel/Yes/No. Clobbers A, X.
_ddb_add_button:
        sta WM_DP_TMP           ; rel x (8-bit)
        stx WM_DP_TMP+1         ; rel y
        lda DLG_WIN
        sta WG_PARENT
        lda #WG_TYPE_BUTTON
        sta WG_TYPE
        lda #$07
        sta GFX_COLOR
        lda #$00
        sta WG_CB
        sta WG_CB+1
        rep #$20
        lda WM_DP_TMP           ; rel x (le high de WM_DP_TMP+1 = rel y est lu ensuite)
        and #$00FF
        sta WM_ARG_X
        lda WM_DP_TMP+1
        and #$00FF
        sta WM_ARG_Y
        lda #44
        sta WM_ARG_W
        lda #18
        sta WM_ARG_H
        sep #$20
        jsr kernel_wm_add_widget
        rts
db_str_ok:
        .byte "OK", $00
db_str_cancel:
        .byte "Cancel", $00
db_str_yes:
        .byte "Yes", $00
db_str_no:
        .byte "No", $00

; $1B — SYS_CTL_GET_VALUE : X = id contrôle → A = value (SP-3.o S.1) ─────
; $FF si id invalide (≥ WIDGET_COUNT).
sys_ctl_get_value:
        lda DP_SYS_ARG_X
        cmp WIDGET_COUNT
        bcs scgv_bad
        pha                             ; save id pour WIDGET_MIN_VALUES (ADR-30 Étape 3)
        asl a
        asl a
        asl a
        asl a
        tax
        lda WIDGET_TABLE+WG_OFF_VALUE,x ; A = value brute (thumb_pos)
        plx                             ; X = id original (1 byte)
        clc
        adc f:WIDGET_MIN_VALUES,x       ; A = value + min (ADR-30 Étape 3)
        rts
scgv_bad:
        lda #$FF
        rts

; $1C — SYS_CTL_SET_VALUE : X = id contrôle, Y = value (SP-3.o S.1) ──────
sys_ctl_set_value:
        lda DP_SYS_ARG_X
        cmp WIDGET_COUNT
        bcs scsv_done
        pha                     ; sauve id (pour redraw conditionnel)
        asl a
        asl a
        asl a
        asl a
        tax
        tya                     ; value (arg Y)
        sta WIDGET_TABLE+WG_OFF_VALUE,x
        ; ADR-30 Étape 5 : redraw ciblé UNIQUEMENT pour GU_FIELD (les widgets
        ; value classiques comme SCROLL_V/CHECK gardent leur cycle de redraw
        ; standard — éviter de perturber les tests timing-sensibles comme
        ; test_oricos_scroll_cost qui ne s'attendent pas à un redraw extra).
        lda WIDGET_TABLE+2,x    ; type (offset +2)
        cmp #WG_TYPE_FIELD
        bne scsv_skip_redraw
        pla
        jsr kernel_wm_redraw_widget
        rts
scsv_skip_redraw:
        pla
scsv_done:
        rts

; $1D — SYS_GET_TICKS : A = compteur de ticks scheduler 8-bit (Sprint 4 clock) ─
; Compteur libre incrémenté par l'IRQ timer (VIA T1), wrap à 256. Les apps
; mesurent un délai via la soustraction non signée wrap-safe : (now - last) >= K.
sys_get_ticks:
        lda TICK_COUNTER
        rts

; ── Pattern GEOS InitProcesses (post-clôture ADR-30) ───────────────────
;
; $1E — SYS_TIMER_SET : X = timer_id (0..TIMER_N-1), Y = period8 (ticks).
; Installe un timer pour la tâche courante. À chaque expiration (counter → 0),
; le kernel reload counter = period + poste EV_TIMER → MSG_TIMER + $DA = id.
; A = $00 sur succès, $FF si id invalide. Y=0 = équivalent à SYS_TIMER_CLEAR.
sys_timer_set:
        ; Arg1 (id) lu depuis DP_SYS_ARG_X (X register écrasé par le dispatcher
        ; COP, cf. handlers.s : « stx DP_SYS_ARG_X » avant l'index dispatch).
        lda DP_SYS_ARG_X
        cmp #TIMER_N
        bcc sts_ok
        lda #$FF                ; id invalide
        rts
sts_ok:
        ; entry_offset = id * 4
        asl a
        asl a
        tax                     ; X = entry_offset
        tya                     ; A = period (arg2, Y est intact)
        beq sts_clear           ; period = 0 → libère
        sta f:TIMER_TABLE+2,x   ; period
        sta f:TIMER_TABLE+3,x   ; counter init = period
        lda TASK_CUR
        sta f:TIMER_TABLE+1,x   ; owner_pid
        lda #TIMER_F_ACTIVE
        sta f:TIMER_TABLE+0,x   ; flag
        lda #$00
        rts
sts_clear:
        lda #TIMER_F_FREE
        sta f:TIMER_TABLE+0,x
        lda #$00
        rts

; $1F — SYS_TIMER_CLEAR : X (DP_SYS_ARG_X) = timer_id. Libère l'entry. A=$00.
sys_timer_clear:
        lda DP_SYS_ARG_X
        cmp #TIMER_N
        bcc stc_ok
        lda #$FF
        rts
stc_ok:
        asl a
        asl a
        tax
        lda #TIMER_F_FREE
        sta f:TIMER_TABLE+0,x
        lda #$00
        rts

; ── Pattern GEOS DoIcons (post-clôture ADR-30) ─────────────────────────
;
; $20 — SYS_HOTZONE_SET : installe une hot-zone rect pour la fenêtre focus.
; Args : X (via DP_SYS_ARG_X) = hotzone_id (0..7).
;        Bloc ZP : $D0 x_lo, $D1 x_hi, $D2 y_lo, $D3 y_hi, $D4 w_lo,
;                  $D5 w_hi, $D6 h_lo, $D7 h_hi (coords absolues XVGA).
; A = $00 succès, $FF id invalide.
sys_hotzone_set:
        lda DP_SYS_ARG_X
        cmp #HOTZONE_N
        bcc shz_ok
        lda #$FF
        rts
shz_ok:
        ; entry_offset = id * 10 (5×2). Calcule via shift+add.
        sta SPIN_TMP            ; id
        asl a                   ; *2
        sta SPIN_ID             ; *2 sauvé
        asl a
        asl a                   ; *8
        clc
        adc SPIN_ID             ; *8 + *2 = *10
        tax                     ; X = entry offset
        ; flag = active, win_slot = WM_FOCUS
        lda #HOTZONE_F_ACTIVE
        sta f:HOTZONE_TABLE+0,x
        lda WM_FOCUS
        sta f:HOTZONE_TABLE+1,x
        ; x16 (relatif au coin haut-gauche de la fenêtre focus)
        lda $D0
        sta f:HOTZONE_TABLE+2,x
        lda $D1
        sta f:HOTZONE_TABLE+3,x
        lda $D2
        sta f:HOTZONE_TABLE+4,x
        lda $D3
        sta f:HOTZONE_TABLE+5,x
        lda $D4
        sta f:HOTZONE_TABLE+6,x
        lda $D5
        sta f:HOTZONE_TABLE+7,x
        lda $D6
        sta f:HOTZONE_TABLE+8,x
        lda $D7
        sta f:HOTZONE_TABLE+9,x
        lda #$00
        rts

; $21 — SYS_HOTZONE_CLEAR : libère hot-zone X. A = $00 ou $FF.
sys_hotzone_clear:
        lda DP_SYS_ARG_X
        cmp #HOTZONE_N
        bcc shc_ok
        lda #$FF
        rts
shc_ok:
        sta SPIN_TMP
        asl a
        sta SPIN_ID
        asl a
        asl a
        clc
        adc SPIN_ID
        tax
        lda #HOTZONE_F_FREE
        sta f:HOTZONE_TABLE+0,x
        lda #$00
        rts

; ── kernel_hotzone_init : zéroise les flags au boot. ──────────────────
.export kernel_hotzone_init
kernel_hotzone_init:
        ldx #$00
khi_loop:
        lda #HOTZONE_F_FREE
        sta f:HOTZONE_TABLE+0,x
        ; avance X de 10 octets
        txa
        clc
        adc #HOTZONE_ENTSZ
        tax
        cpx #(HOTZONE_N * HOTZONE_ENTSZ)
        bcc khi_loop
        rts

; ── _wm_hotzone_hit : cherche une hot-zone sous (MOUSE_X, MOUSE_Y) pour la
; fenêtre A (slot id). Retour : A = hotzone_id (0..N-1) | $80, ou $FF si miss.
; Modifie A, X, Y, WG_*.
.export _wm_hotzone_hit
_wm_hotzone_hit:
        sta WIN_SLOT             ; slot fenêtre dont on cherche les hotzones
        ldx #$00
hzh_loop:
        lda f:HOTZONE_TABLE+0,x
        cmp #HOTZONE_F_ACTIVE
        beq hzh_check_slot
        jmp hzh_next
hzh_check_slot:
        lda f:HOTZONE_TABLE+1,x
        cmp WIN_SLOT
        beq hzh_check_bounds
        jmp hzh_next
hzh_check_bounds:
        ; Compute abs_x = win.x + rel_x, abs_y = win.y + rel_y.
        ; Lit rect rel hotzone.
        rep #$20
        lda f:HOTZONE_TABLE+2,x
        sta WG_RELX
        lda f:HOTZONE_TABLE+4,x
        sta WG_RELY
        lda f:HOTZONE_TABLE+6,x
        sta WG_RELW
        lda f:HOTZONE_TABLE+8,x
        sta WG_RELH
        sep #$20
        ; X save (besoin pour calcul de l'id)
        phx
        ; abs via parent window
        lda WIN_SLOT
        jsr kernel_wm_offset    ; X = slot*10
        rep #$20
        lda WM_TABLE+WM_OFF_X,x
        clc
        adc WG_RELX
        sta WG_RELX             ; abs_x
        lda WM_TABLE+WM_OFF_Y,x
        clc
        adc WG_RELY
        sta WG_RELY             ; abs_y
        ; hit test
        lda MOUSE_X
        cmp WG_RELX
        bcc hzh_miss16
        lda WG_RELX
        clc
        adc WG_RELW
        sta WG_RELW             ; abs_x2
        lda MOUSE_X
        cmp WG_RELW
        bcs hzh_miss16
        lda MOUSE_Y
        cmp WG_RELY
        bcc hzh_miss16
        lda WG_RELY
        clc
        adc WG_RELH
        sta WG_RELH             ; abs_y2
        lda MOUSE_Y
        cmp WG_RELH
        bcs hzh_miss16
        ; HIT
        sep #$20
        plx                      ; X = entry_offset
        ; id = entry_offset / 10 ; on a stocké id*10 dans X. Pour récupérer
        ; l'id, on cherche : entry_offset / 10. v1 : itérer / soustraire 10.
        txa
        ldy #$00
hzh_to_id:
        cmp #HOTZONE_ENTSZ
        bcc hzh_id_done
        sec
        sbc #HOTZONE_ENTSZ
        iny
        bra hzh_to_id
hzh_id_done:
        tya
        ora #HOTZONE_ID_BASE     ; |= $80
        rts
hzh_miss16:
        sep #$20
        plx
hzh_next:
        ; X += HOTZONE_ENTSZ
        txa
        clc
        adc #HOTZONE_ENTSZ
        tax
        cpx #(HOTZONE_N * HOTZONE_ENTSZ)
        bcs hzh_done
        jmp hzh_loop
hzh_done:
        lda #$FF                 ; miss global
        rts

; ── kernel_timer_init : zéroise les flags TIMER_TABLE au boot. ────────
.export kernel_timer_init
kernel_timer_init:
        ldx #$00
kti_loop:
        lda #TIMER_F_FREE
        sta f:TIMER_TABLE+0,x
        inx
        inx
        inx
        inx
        cpx #(TIMER_N * TIMER_ENTSZ)
        bcc kti_loop
        rts

; ── kernel_timer_tick : appelé par IRQ T1 à chaque tick. ─────────────
; Pour chaque entry active : décrémente counter ; si 0 → poste EV_TIMER
; (owner_pid, id) + reload counter = period. Clobbers A, X, Y.
.export kernel_timer_tick
kernel_timer_tick:
        ldx #$00                ; entry_offset
ktt_loop:
        lda f:TIMER_TABLE+0,x
        cmp #TIMER_F_ACTIVE
        bne ktt_next
        lda f:TIMER_TABLE+3,x
        beq ktt_fire            ; counter déjà 0 (init weird) → fire
        dec a
        sta f:TIMER_TABLE+3,x
        bne ktt_next            ; pas encore 0
ktt_fire:
        ; Reload counter = period
        lda f:TIMER_TABLE+2,x
        sta f:TIMER_TABLE+3,x
        ; Poste EV_TIMER. Calcule id = offset/4 = X >> 2.
        txa
        lsr a
        lsr a
        jsr kernel_event_push_timer
ktt_next:
        ; X += TIMER_ENTSZ. inx 4 fois (X 8-bit).
        inx
        inx
        inx
        inx
        cpx #(TIMER_N * TIMER_ENTSZ)
        bcc ktt_loop
        rts

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
        jsr kernel_gfx_window_base   ; G.4 + ADR-27 B2 : GFX_BASE + bpl du slot
        jsr kernel_gfx_clear
        jsr kernel_gfx_finish        ; ADR-27 B2 : confine bpl au syscall
        lda #$00
        rts

; $0E — SYS_GFX_FILL_RECT ─────────────────────────────────────────────
sys_gfx_fill_rect:
        jsr kernel_gfx_window_base   ; G.4 + ADR-27 B2 : GFX_BASE + bpl du slot
        jsr kernel_gfx_fill_rect
        jsr kernel_gfx_finish        ; ADR-27 B2 : confine bpl au syscall
        lda #$00
        rts

; $0F — SYS_GFX_BLIT ──────────────────────────────────────────────────
sys_gfx_blit:
        jsr kernel_gfx_window_base   ; G.4 + ADR-27 B2 : GFX_BASE + bpl du slot
        jsr kernel_gfx_blit
        jsr kernel_gfx_finish        ; ADR-27 B2 : confine bpl au syscall
        lda #$00
        rts

; $10 — SYS_GFX_LINE ──────────────────────────────────────────────────
sys_gfx_line:
        jsr kernel_gfx_window_base   ; G.4 + ADR-27 B2 : GFX_BASE + bpl du slot
        jsr kernel_gfx_line
        jsr kernel_gfx_finish        ; ADR-27 B2 : confine bpl au syscall
        lda #$00
        rts

; $11 — SYS_GFX_TEXT ──────────────────────────────────────────────────
sys_gfx_text:
        jsr kernel_gfx_window_base   ; G.4 + ADR-27 B2 : GFX_BASE + bpl du slot
        jsr kernel_gfx_text
        jsr kernel_gfx_finish        ; ADR-27 B2 : confine bpl au syscall
        lda #$00
        rts

; $12 — SYS_SLEEP_MS : X/Y = ms16 (stub v0.2) ────────────────────────
; $12 — SYS_SLEEP_MS : X/Y = durée (OS-2.g v2.b) ─────────────────────
; Blocage réel piloté par le timer : la tâche passe BLOCKED, SLEEP_TICKS[CUR]
; = durée, rend le CPU ; l'IRQ T1 décrémente et la réveille à 0. Gate
; SCHED_ACTIVE : en contexte boot (pas de scheduler/timer pour réveiller), no-op.
; v1 : l'argument X est interprété en TICKS (≈0,5 ms/tick) ; conversion ms→ticks
; 16-bit reportée (polish). Reprise = après le COP (l'app continue).
sys_sleep_ms:
        lda SCHED_ACTIVE
        cmp #$A5
        beq ssm_block
        rts                     ; scheduler inactif → sleep = no-op
ssm_block:
        sei                     ; section critique (set SLEEP_TICKS + chirurgie atomiques)
        lda TASK_CUR            ; (LDX n'a pas de mode abs-long → via A+TAX)
        tax
        lda DP_SYS_ARG_X        ; durée (ticks v1) = arg X de l'appelant
        sta f:SLEEP_TICKS,X     ; SLEEP_TICKS[CUR] = durée (abs-long,X)
        jsr kernel_permit       ; fin du syscall côté FORBID (reprise = contexte app)
        pla                     ; jette le retour du jsr (lo)
        pla                     ; jette le retour du jsr (hi) → sommet frame COP
        lda #$00
        pha                     ; A_init (don't care)
        lda DP_SYS_ARG_X
        pha                     ; X_init (préserve l'arg)
        phy                     ; Y_init
        jmp kernel_block_switch ; BLOCKED + bascule ; le timer réveille à 0

; ════════════════════════════════════════════════════════════════════
;  NMI_HANDLER — bank 1 $5500
; ════════════════════════════════════════════════════════════════════
;
; Sprint 1.c : NMI réservé pour le futur (panic, debug). Pour l'instant
; un simple RTI no-op.
;
; ════════════════════════════════════════════════════════════════════
