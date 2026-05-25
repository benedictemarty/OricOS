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

