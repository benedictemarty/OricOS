; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : log.s — inclus depuis kernel.s
;
        .segment "CODE"

; ════════════════════════════════════════════════════════════════════
; ── kernel_log_init : vide le log ring buffer ─────────────────────
; Pré-cond : mode N M=X=1, DBR=0. Modifie A.
.export kernel_log_init
kernel_log_init:
        lda #$00
        sta LOG_HEAD
        sta LOG_TAIL
        sta LOG_COUNT
        rts

; ── kernel_log_write : ajoute une entrée (A=code, X=level) ─────────
; Ring circulaire : si plein, écrase l'entrée la plus ancienne.
; Modifie A, X, Y. Pré-cond : mode N M=X=1, DBR=0.
.export kernel_log_write
kernel_log_write:
        sta DP_LOG_TMP          ; sauve code
        txa
        pha                     ; sauve level
        lda LOG_TAIL
        asl a                   ; offset octet = tail × 2
        tax
        pla                     ; A = level
        sta LOG_RING,X          ; ring[tail].level (abs long,X)
        inx
        lda DP_LOG_TMP          ; code
        sta LOG_RING,X          ; ring[tail].code
        ; tail = (tail+1) & mask
        lda LOG_TAIL
        inc a
        and #LOG_MASK
        sta LOG_TAIL
        ; count++ si non plein, sinon head suit tail (drop le plus ancien)
        lda LOG_COUNT
        cmp #LOG_SIZE
        bcs lw_full
        inc a
        sta LOG_COUNT
        rts
lw_full:
        lda LOG_HEAD
        inc a
        and #LOG_MASK
        sta LOG_HEAD
        rts

.export kernel_panic
kernel_panic:
        sta PANIC_CODE
        pha                     ; sauve code (A inchangé par pha)
        ; OS-2.i.v2 : journalise l'événement panic (A=code, X=level).
        ldx #LOG_PANIC
        jsr kernel_log_write
        ; Setup DP_PTR pour panic_msg en bank 1
        lda #$01
        sta DP_PTR+2
        lda #<panic_msg
        sta DP_PTR
        lda #>panic_msg
        sta DP_PTR+1
        jsr kernel_print_string
        pla                     ; restore code
        jsr kernel_print_hex8
        stp
        bra *

panic_msg:
        .byte "PANIC ", $00

; ════════════════════════════════════════════════════════════════════
;  kernel_print_hex8 / kernel_print_nibble (Sprint 2.i)
; ════════════════════════════════════════════════════════════════════
;
; print_hex8 : args A = byte → écrit 2 chars hex via print_char.
; print_nibble : args A 0..15 → écrit 1 char hex.
; Préserve : Y. Modifie : A, X.
; ════════════════════════════════════════════════════════════════════
.export kernel_print_hex8
kernel_print_hex8:
        pha                     ; save byte
        lsr a
        lsr a
        lsr a
        lsr a                   ; high nibble (0..15)
        jsr kernel_print_nibble
        pla                     ; restore
        and #$0F                ; low nibble
        ; tail-call print_nibble (sa rts retourne au caller de print_hex8)

.export kernel_print_nibble
kernel_print_nibble:
        cmp #$0A
        bcc nib_digit
        clc
        adc #$07                ; 'A'-'0'-10 = 7 → 'A'..'F'
nib_digit:
        clc
        adc #'0'
        jmp kernel_print_char   ; tail-call

; ════════════════════════════════════════════════════════════════════
;  kernel_install_charset — copie 1024 oct. fonte $015800 → $00B400
; ════════════════════════════════════════════════════════════════════
;
; Sprint 2.c+ : la ROM Oric 1 historique installe la fonte char en RAM
; bank 0 $B400-$B7FF lors du boot. OricOS boot sans la ROM, donc le
; kernel installe lui-même sa fonte (embedded via .incbin). Sans cela,
; le rendu mode TEXT affiche du noir partout (fonte tout-zéro).
;
; Pré-condition : mode N, M=X=1, DBR=0.
; Modifie : A, X, Y, DBR (=0 après). Préserve P (php/plp).
; OS-perf : copie via MVN (block move 65C816) au lieu d'une boucle
; octet-par-octet (~18K cycles → ~2K). MVN copie C+1 octets de
; src_bank:X vers dst_bank:Y en ascendant ; DBR finit = dst_bank.
