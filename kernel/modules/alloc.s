; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : alloc.s — inclus depuis kernel.s
;
        .segment "CODE"

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

; ─── task_c_entry : 3e tâche (OS-2.g v2.a g.3), créée par task_create ──
; Démontre la création dynamique + le round-robin N-tâches.
.export task_c_entry
task_c_entry:
        lda TASK_C_CTR
        inc a
        sta TASK_C_CTR
        ; OS-2.g v2.a g.7 : cède coopérativement le CPU via SYS_YIELD ($05).
        ; Exerce sys_yield (chirurgie de pile + do_switch). Si bug → task_c
        ; crashe/hang → tests rouges.
        lda #$05                ; SYS_YIELD
        cop #$AA
        bra task_c_entry

; ─── task_d_entry : tâche éphémère (OS-2.g v2.a g.4) ───────────────────
; S'incrémente une fois puis SYS_EXIT → exerce le teardown. Le bra final est
; un filet : si exit échouait (retour au lieu de switch), task_d boucle
; (counter > 1) au lieu de tomber dans le vide → échec de test propre.
.export task_d_entry
task_d_entry:
        lda TASK_D_CTR
        inc a
        sta TASK_D_CTR
        lda #$04                ; SYS_EXIT
        cop #$AA
        bra task_d_entry        ; filet (ne devrait jamais être atteint)

; ─── task_e_entry : tâche qui BLOQUE sur le clavier (OS-2.g v2.b g.5) ──
; SYS_READ_CHAR (bloque jusqu'à une touche), stocke le keycode, puis SYS_EXIT.
; Valide le blocage réel + le réveil par l'IRQ KBD2.
.export task_e_entry
task_e_entry:
        lda #$03                ; SYS_READ_CHAR (bloquant)
        cop #$AA
        sta TASK_E_KEY          ; A = keycode lu
        lda #$04                ; SYS_EXIT
        cop #$AA
        bra task_e_entry        ; filet

; ─── task_evt_entry : tâche qui BLOQUE sur la file d'événements (SP-3.n G.2) ──
; SYS_GET_NEXT_EVENT ($16, bloquant) → A = what, record en $D0-$D9. Stocke what
; et le message (keycode pour EV_KEY_DOWN, en $D1) puis SYS_EXIT. Valide le pop
; syscall + blocage réel + réveil par kernel_event_wake (IRQ).
.export task_evt_entry
task_evt_entry:
        lda #$16                ; SYS_GET_NEXT_EVENT (bloquant)
        cop #$AA
        sta TASK_EVT_WHAT       ; A = what de l'événement
        lda $D1                 ; message lo (keycode si EV_KEY_DOWN)
        sta TASK_EVT_MSG
        lda #$04                ; SYS_EXIT
        cop #$AA
        bra task_evt_entry      ; filet

; ─── task_ml_entry : tâche qui consomme un MESSAGE du MainLoop (SP-3.n G.3a) ──
; SYS_MAIN_LOOP ($17, bloquant) → A = MSG_*, détails en $D0-$DF. Stocke le
; message et son détail ($DA = id fenêtre pour MSG_CONTENT) puis SYS_EXIT.
; Valide la traduction événement→message sémantique + skip des MSG_NULL.
.export task_ml_entry
task_ml_entry:
        lda #$17                ; SYS_MAIN_LOOP (bloquant)
        cop #$AA
        sta TASK_ML_MSG         ; A = MSG_*
        lda $DA                 ; détail (id fenêtre pour MSG_CONTENT)
        sta TASK_ML_DETAIL
        lda #$04                ; SYS_EXIT
        cop #$AA
        bra task_ml_entry       ; filet

; ─── task_ui_entry : déclare son UI via une table GenUI (SP-3.n G.3b) ─────────
; Passe un pointer 24-bit vers genui_demo à SYS_UI_DEFINE → le kernel crée la
; fenêtre déclarée (300,200,120,90) avec titre "UI". Valide le modèle déclaratif.
.export task_ui_entry
task_ui_entry:
        lda #<genui_demo
        sta $D0
        lda #>genui_demo
        sta $D1
        lda #$01                ; bank 1 (table en bank kernel)
        sta $D2
        lda #$18                ; SYS_UI_DEFINE
        cop #$AA
        sta TASK_UI_HANDLE      ; A = handle (slot) ou $FF
        lda #$04                ; SYS_EXIT
        cop #$AA
        bra task_ui_entry       ; filet

; Table GenUI démo : titre "UI" (inline) + fenêtre (300,200,120,90) + bouton "OK".
; (GU_TITLE AVANT GU_WINDOW ; chaînes INLINE null-terminées.)
genui_demo:
        .byte GU_TITLE
        .byte "UI", $00         ; titre inline
        .byte GU_WINDOW
        .word 300               ; x
        .word 200               ; y
        .word 120               ; w
        .word 90                ; h
        .byte GU_BUTTON
        .word 10                ; rel x
        .word 60                ; rel y
        .word 44                ; rel w
        .word 18                ; rel h
        .byte "OK", $00         ; label inline
        .byte GU_END

; ─── task_dlg_entry : ouvre un dialogue modal via command table (SP-3.n G.5) ──
; SYS_DO_DLGBOX ($19) avec db_demo (dialogue 200,150,160,80 + boutons OK/Cancel).
; Bloque (modal) jusqu'au clic ; stocke le retour (1=OK/0=Cancel) puis SYS_EXIT.
.export task_dlg_entry
task_dlg_entry:
        lda #<db_demo
        sta $D0
        lda #>db_demo
        sta $D1
        lda #$01                ; bank 1
        sta $D2
        lda #$19                ; SYS_DO_DLGBOX
        cop #$AA
        sta TASK_DLG_RES        ; A = 1 (OK) ou 0 (Cancel)
        lda #$04                ; SYS_EXIT
        cop #$AA
        bra task_dlg_entry      ; filet

; Command table DoDlgBox démo : dialogue (200,150,160,80) + OK + Cancel.
db_demo:
        .byte DB_POSITION
        .word 200               ; x
        .word 150               ; y
        .word 160               ; w
        .word 80                ; h
        .byte DB_OK
        .byte DB_CANCEL
        .byte DB_END

; ─── task_alert_entry : alerte pré-câblée OK-Cancel (SP-3.n G.6) ──────────────
; SYS_ALERT ($1A) type ALERT_OKCANCEL (X=1) → fenêtre modale fixe + OK/Cancel.
; Bloque jusqu'au clic ; stocke le retour (1=OK/0=Cancel) puis SYS_EXIT.
.export task_alert_entry
task_alert_entry:
        ldx #ALERT_OKCANCEL     ; type d'alerte (arg X)
        lda #$1A                ; SYS_ALERT
        cop #$AA
        sta TASK_ALERT_RES      ; A = 1 (OK) ou 0 (Cancel)
        lda #$04                ; SYS_EXIT
        cop #$AA
        bra task_alert_entry    ; filet

; ─── task_chk_entry : crée une checkbox + round-trip API valeur (SP-3.o S.1) ──
; Ajoute une checkbox à la fenêtre 0, puis SYS_CTL_SET_VALUE(id,1) +
; SYS_CTL_GET_VALUE(id) → stocke la valeur lue. Valide l'API valeur + le type CHECK.
.export task_chk_entry
task_chk_entry:
        lda #$00                ; parent = fenêtre 0
        sta WG_PARENT
        lda #WG_TYPE_CHECK
        sta WG_TYPE
        lda #WG_COL_UNCHECKED
        sta GFX_COLOR
        lda #<chk_label
        sta DP_PCPTR
        lda #>chk_label
        sta DP_PCPTR+1
        lda #$00                ; value init 0 (via WG_CB/+14)
        sta WG_CB
        sta WG_CB+1
        rep #$20
        lda #6                  ; rel x
        sta WM_ARG_X
        lda #14                 ; rel y
        sta WM_ARG_Y
        lda #50                 ; rel w
        sta WM_ARG_W
        lda #12                 ; rel h
        sta WM_ARG_H
        sep #$20
        lda WIDGET_COUNT        ; id = index du nouveau widget
        sta TASK_CHK_ID
        jsr kernel_wm_add_widget
        ; SYS_CTL_SET_VALUE(id, 1)
        lda TASK_CHK_ID
        tax
        ldy #$01
        lda #$1C
        cop #$AA
        ; SYS_CTL_GET_VALUE(id) → A
        lda TASK_CHK_ID
        tax
        lda #$1B
        cop #$AA
        sta TASK_CHK_VAL        ; doit valoir 1
        lda #$04                ; SYS_EXIT
        cop #$AA
        bra task_chk_entry      ; filet
chk_label:
        .byte "Opt", $00

; ─── task_scr_entry : crée un ascenseur vertical + boucle MainLoop (SP-3.o S.2) ──
; Ajoute un scrollbar V à la fenêtre 0 (rel 60,14,12×60, max=40), puis tourne une
; boucle MainLoop (mode app-driven → le drag du thumb est actif). Le test injecte
; clic+drag et lit la value du widget. Ne sort pas (le test lit l'état).
.export task_scr_entry
task_scr_entry:
        lda #$00                ; parent = fenêtre 0
        sta WG_PARENT
        lda #WG_TYPE_SCROLL_V
        sta WG_TYPE
        lda #WG_COL_TRACK
        sta GFX_COLOR
        lda #$00
        sta DP_PCPTR
        sta DP_PCPTR+1          ; pas de label
        lda #$00
        sta WG_CB               ; value init 0 (+14)
        lda #40
        sta WG_CB+1             ; max = 40 (+15)
        rep #$20
        lda #60                 ; rel x
        sta WM_ARG_X
        lda #14                 ; rel y
        sta WM_ARG_Y
        lda #12                 ; w
        sta WM_ARG_W
        lda #60                 ; h (longueur gouttière)
        sta WM_ARG_H
        sep #$20
        lda WIDGET_COUNT
        sta TASK_SCR_ID         ; id du scrollbar
        jsr kernel_wm_add_widget
scr_loop:
        lda #$17                ; SYS_MAIN_LOOP (bloque ; le drag met à jour la value)
        cop #$AA
        bra scr_loop            ; boucle (le test lit la value du widget)

; ─── task_f_entry : tâche dormeuse (OS-2.g v2.b, test SYS_SLEEP_MS) ────
; Boucle : incrémente TASK_F_CTR puis dort 3 ticks via SYS_SLEEP_MS ($12).
; Exerce le blocage/réveil piloté par le timer. TASK_F_CTR>0 prouve le réveil.
.export task_f_entry
task_f_entry:
        lda TASK_F_CTR
        inc a
        sta TASK_F_CTR
        ldx #$03                ; 3 ticks (v1 : arg ~ ticks)
        ldy #$00
        lda #$12                ; SYS_SLEEP_MS
        cop #$AA
        bra task_f_entry

; ─── task_win_entry : tâche qui ouvre une fenêtre (SP-3.m G.2) ────────
; Remplit le bloc d'args ZP $D0-$D7 (x=100,y=80,w=200,h=120) puis appelle
; SYS_WIN_CREATE ($13). Stocke le handle dans TASK_WIN_HANDLE, puis dort.
.export task_win_entry
task_win_entry:
        lda #100                ; x = 100
        sta $D0
        lda #$00
        sta $D1
        lda #80                 ; y = 80
        sta $D2
        lda #$00
        sta $D3
        lda #200                ; w = 200
        sta $D4
        lda #$00
        sta $D5
        lda #120                ; h = 120
        sta $D6
        lda #$00
        sta $D7
        lda #$13                ; SYS_WIN_CREATE
        cop #$AA
        sta TASK_WIN_HANDLE     ; A = handle (slot) retourné
        ; G.5 : sortie → SYS_EXIT doit fermer la fenêtre (kernel_wm_close_owner).
        lda #$04                ; SYS_EXIT
        cop #$AA
        bra task_win_entry      ; filet

; ─── task_wdraw_entry : crée une fenêtre, DESSINE dedans, sort (SP-3.m G.4) ──
; Crée sa fenêtre (SYS_WIN_CREATE → slot 2), puis FILL_RECT (0,0,8,8 couleur 4)
; en coords LOCALES : le kernel résout GFX_BASE = backing store de la fenêtre
; (slot 2 → $080000), donc l'app dessine sans connaître l'adresse XVGA. Puis exit.
; Couleur 15 ($FF) choisie distincte du fond desktop ($44) pour que la preuve
; de compositing ($00A032) soit non-ambiguë.
.export task_wdraw_entry
task_wdraw_entry:
        lda #100                ; x
        sta $D0
        lda #$00
        sta $D1
        lda #80                 ; y
        sta $D2
        lda #$00
        sta $D3
        lda #200                ; w
        sta $D4
        lda #$00
        sta $D5
        lda #120                ; h
        sta $D6
        lda #$00
        sta $D7
        lda #$13                ; SYS_WIN_CREATE
        cop #$AA
        sta TASK_WIN_HANDLE
        lda #$00
        sta GFX_ARG2_LO         ; x local = 0
        sta GFX_ARG2_MID        ; y local = 0
        lda #$08
        sta GFX_ARG3_LO         ; w = 8
        sta GFX_ARG3_MID        ; h = 8
        lda #$0F
        sta GFX_COLOR           ; couleur 15 (blanc, $FF) — distincte du fond desktop ($44)
        lda #$0E                ; SYS_GFX_FILL_RECT (→ backing store fenêtre)
        cop #$AA
        ; G.4bis : composite les backing stores → framebuffer XVGA (tâche kernel
        ; → appel direct ; en vrai une app passerait par un futur SYS_WIN_FLUSH).
        jsr kernel_wm_compose
        lda #$04                ; SYS_EXIT
        cop #$AA
        bra task_wdraw_entry    ; filet

; ─── idle_entry : tâche idle (OS-2.g v2.b) ────────────────────────────
; Toujours READY, plus basse priorité (find_next ne la choisit qu'en fallback,
; quand aucune autre tâche n'est READY). Dort sur WAI jusqu'à l'IRQ suivante.
; IDLE_CTR s'incrémente seulement si l'idle tourne réellement (test : ==0 tant
; que des tâches réelles sont READY → prouve la dépriorisation).
.export idle_entry
idle_entry:
        lda IDLE_CTR
        inc a
        sta IDLE_CTR
        wai                     ; dort jusqu'à IRQ (économie ; réveil au prochain tick)
        bra idle_entry

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

; SP-3.f : chaînes de titre pour les fenêtres démo (bank 1, ASCII null-term).
str_win0_title:
        .byte "OricOS", $00
str_win1_title:
        .byte "Editor", $00
; SP-3.f : string close button "X\0" (uploadé en SDRAM WM_CLOSE_STR au boot)
str_close_x:
        .byte "X", $00
; SP-3.h : strings boutons maximize et minimize
str_max_o:
        .byte "O", $00           ; bouton □ maximize (O simplifié, fonte 8×8)
str_min_und:
        .byte "_", $00           ; bouton _ minimize
; SP-3.k : labels icônes desktop
str_icon_files:
        .byte "Files", $00
str_icon_settings:
        .byte "Prefs", $00

; kernel_fill_rect_aligned retiré en PH-cleanup-zombie (2026-05-09).
; Code legacy ADR-19 v2 (écrivait bank $80, plus visible compositor).
; Rendu rectangles = SYS_GFX_FILL_RECT (ADR-17/21) via GPU blitter.

