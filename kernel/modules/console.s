; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : console.s — inclus depuis kernel.s
;
        .segment "CODE"

; ════════════════════════════════════════════════════════════════════
.export kernel_install_charset
kernel_install_charset:
        rep #$30                     ; A/X/Y 16-bit (requis par MVN)
        lda #CHARSET_SIZE-1          ; C = nb octets - 1 ($03FF)
        ldx #.loword(CHARSET_SRC)    ; X = offset source ($5800, bank 1)
        ldy #.loword(CHARSET_DST)    ; Y = offset dest ($B400, bank 0)
        .byte $54, .bankbyte(CHARSET_DST), .bankbyte(CHARSET_SRC)  ; MVN dst,src
        sep #$30                     ; retour M=X=1 (cohérent .smart ; DBR=dst $00)
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
; OS-2.e.2 : CR (\r) → début de ligne, scroll up (lignes 1..27 → 0..26).
; Non-implémenté (reporté) : attribut couleur par ligne, INKs multiples.
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
        cmp #$0D                 ; CR (\r) → début de ligne courante
        beq pc_cr
        ; Char normal : écrit en bank0:CURSOR_ADDR via [DP_PCPTR] (indirect
        ; long, indépendant du DBR). Indispensable : appelé depuis une app
        ; userland, DBR = bank de l'app (≠ 0) ; un STA (dp) DBR-relatif
        ; écrirait dans le mauvais bank au lieu de l'écran bank 0.
        rep #$20
        lda CURSOR_ADDR
        sta DP_PCPTR             ; DP+$0C/$0D = low/high (16-bit)
        sep #$20
        lda #$00
        sta DP_PCPTR+2           ; DP+$0E = bank 0 (écran)
        lda DP_TMP
        sta [DP_PCPTR]           ; opcode $87 — STA long indirect → bank0:CURSOR_ADDR
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
        bra pc_check_end
pc_cr:
        ; CR : CURSOR_ADDR -= CURSOR_X (retour col 0), CURSOR_X = 0.
        lda CURSOR_X
        rep #$20
        and #$00FF               ; CURSOR_X zero-étendu (16-bit)
        sta DP_PCPTR             ; scratch 16-bit
        lda CURSOR_ADDR
        sec
        sbc DP_PCPTR
        sta CURSOR_ADDR
        sep #$20
        lda #$00
        sta CURSOR_X
        bra pc_done              ; CR ne peut pas dépasser le bas d'écran
pc_check_end:
        ; Si CURSOR_ADDR >= SCREEN_END → scroll up d'une ligne (OS-2.e.2).
        rep #$20
        lda CURSOR_ADDR
        cmp #SCREEN_END
        sep #$20
        bcc pc_done
        jsr kernel_scroll_up
        rep #$20
        lda #SCREEN_LAST_ROW     ; curseur sur la dernière ligne (col 0)
        sta CURSOR_ADDR
        sep #$20
        lda #$00
        sta CURSOR_X
pc_done:
        rts

; ─── kernel_scroll_up : scroll écran vers le haut d'une ligne ──────
; Copie lignes 1..27 → 0..26 (40 octets décalage), remplit la dernière
; ligne d'espaces, restaure l'attribut INK 7 en $BB80. La cellule
; ligne0/col0 étant réservée à l'attribut, le car. ligne1/col0 est perdu
; (artefact mineur du modèle console à attribut unique). Modifie A, X.
; Pré-cond : mode N M=X=1, DBR=0.
.export kernel_scroll_up
kernel_scroll_up:
        rep #$10                 ; X 16-bit (compteur > 255)
        ldx #$0000
        ; f: force l'adressage long (bank 0 explicite) : indépendant du DBR
        ; de l'appelant (peut être appelé depuis print_char en contexte app).
scrl_copy:
        lda f:SCREEN_BASE+SCREEN_COLS,X ; src = ligne+1 (long,X → bank 0)
        sta f:SCREEN_BASE,X             ; dst = ligne (long,X → bank 0)
        inx
        cpx #(SCREEN_END - SCREEN_BASE - SCREEN_COLS)  ; 1080 octets
        bcc scrl_copy
        ; Efface la dernière ligne (40 espaces).
        ldx #$0000
scrl_clear:
        lda #SCREEN_FILL
        sta f:SCREEN_LAST_ROW,X
        inx
        cpx #SCREEN_COLS
        bcc scrl_clear
        sep #$10                 ; X repasse en 8-bit
        ; Restaure l'attribut INK 7 en tête d'écran.
        lda #$07
        sta f:SCREEN_BASE
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
        .byte "OricOS B3 Demo", $0A
        .byte "CPU : 65C816 MODE N", $0A
        .byte "MEM : 256KiB (BK0-3)", $0A, $00
str_b3_guest_in:
        .byte "GUEST: MODE E RUN...", $0A, $00
str_b3_guest_out:
        .byte "GUEST: BACK N OK", $0A, $00

; ─── Bundle hello (Sprint 2.m.1) ────────────────────────────────────
; Première app standalone OricOS, source asm dans `apps/hello/hello.s`,
; buildée par ld65 + tool oricos-bundle.py → format .oosobj.
; Embarquée ici via .incbin pour démontrer le pipeline build d'apps
; externes au kernel.
.export bundle_test
bundle_test:
        .incbin "../apps/hello/build/hello.oosobj"

; ─── Bundle hello_c (TC-poc-hello-c) ────────────────────────────────────
; Première app userland C compilée avec llvm-mos (target mos-oricos).
; Produite par apps/hello_c/ → format .oos (même format OOS qu'hello.oosobj).
.export bundle_hello_c
bundle_hello_c:
        .incbin "../apps/hello_c/build/hello.oos"

; ─── Bundle win_hello (SP-3.m G.6) ──────────────────────────────────────
; App C démo fenêtrée : crée sa fenêtre, dessine en local, flush, lit le
; clavier au focus, sort (fenêtre fermée). Valide G.1-G.5 depuis userland C.
.export bundle_win
bundle_win:
        .incbin "../apps/win_hello/build/win.oos"

