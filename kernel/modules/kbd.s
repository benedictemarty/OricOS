; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : kbd.s — inclus depuis kernel.s
;
        .segment "CODE"

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

; ── kernel_kbd_init : init driver clavier Oric 2 (ADR-22) ──────────
; Pré-cond : mode N M=X=1, DBR=0. Vide le ring + active l'IRQ KBD2.
; Le scan matriciel Oric 1 est remplacé par la FIFO IRQ-driven du
; contrôleur KBD2 (la keymap est faite côté contrôleur, plus dans le kernel).
.export kernel_kbd_init
kernel_kbd_init:
        ; Ring buffer vide.
        lda #$00
        sta KBD_RING_HEAD
        sta KBD_RING_TAIL
        sta KBD_RING_COUNT
        sta KBD_GETKEY_RES
        ; Active l'IRQ du contrôleur KBD2 (FIFO non vide → IRQ).
        lda #KBD2_CT_IRQ_EN
        sta KBD2_CTRL
        rts

; ── kernel_kbd_poll : draine la FIFO KBD2 → ring buffer ────────────
; Appelé par l'IRQ handler à chaque tick (et lisible directement).
; Lit KBD2_DATA tant que data_ready, push chaque keycode dans le ring.
; Vider la FIFO déasserte l'IRQ KBD2 (level-triggered). Modifie A, X. Préserve Y.
.export kernel_kbd_poll
kernel_kbd_poll:
kpoll_loop:
        lda KBD2_STATUS
        and #KBD2_ST_READY
        beq kpoll_done           ; FIFO vide → terminé
        lda KBD2_DATA            ; pop keycode ASCII
        jsr kernel_kbd_ring_push
        bra kpoll_loop
kpoll_done:
        rts

; ── kernel_kbd_ring_push : push A (keycode) dans le ring ───────────
; Drop silencieux si plein (16). Modifie A, X. Préserve Y.
; NB : LDX/INC/DEC n'ont pas de mode absolu long sur 65C816 → on passe
; par LDA (abs long) + A pour les variables ring en bank 1.
kernel_kbd_ring_push:
        sta DP_KBD_TMP           ; sauve keycode
        lda KBD_RING_COUNT
        cmp #KBD_RING_SIZE
        bcs kpush_full           ; plein → drop
        lda KBD_RING_TAIL
        tax
        lda DP_KBD_TMP           ; A = keycode
        sta KBD_RING,X           ; store au tail (abs long,X = $9F)
        lda KBD_RING_TAIL
        inc a
        and #KBD_RING_MASK       ; wrap 16
        sta KBD_RING_TAIL
        lda KBD_RING_COUNT
        inc a
        sta KBD_RING_COUNT
kpush_full:
        rts

; ── kernel_kbd_ring_pop : pop → A = keycode, ou A=$00 si vide ──────
; Modifie A, X. Préserve Y. Convention ADR-17 SYS_GET_KEY (A=keycode/0).
;
; Section critique (php/sei…plp) : depuis que le handler COP fait cli
; (cf. handlers.s, fix deadlock SYS_READ_CHAR), l'IRQ KBD2 peut préempter
; un syscall et appeler kernel_kbd_poll → kernel_kbd_ring_push EN PLEIN POP.
; Sans masquage, le RMW partagé sur KBD_RING_COUNT (push inc / pop dec) perd
; une mise à jour, et le scratch DP_KBD_TMP serait écrasé par le push. Le
; producteur étant uniquement l'IRQ, masquer l'IRQ pendant le pop le rend
; atomique. plp restaure le I de l'appelant (=0 en contexte COP, d'où WAI OK).
.export kernel_kbd_ring_pop
kernel_kbd_ring_pop:
        lda KBD_RING_COUNT
        beq kpop_empty
        php                      ; sauve I
        sei                      ; ── début section critique vs IRQ producteur ──
        lda KBD_RING_HEAD
        tax
        lda KBD_RING,X           ; A = keycode
        sta DP_KBD_TMP           ; sauve keycode
        lda KBD_RING_HEAD
        inc a
        and #KBD_RING_MASK
        sta KBD_RING_HEAD
        lda KBD_RING_COUNT
        dec a
        sta KBD_RING_COUNT
        lda DP_KBD_TMP           ; reload keycode SOUS masque (sinon clobber par push)
        plp                      ; ── fin section critique : restaure I ──
        rts
kpop_empty:
        lda #$00
        rts

