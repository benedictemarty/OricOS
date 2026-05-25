; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
;
; crt0.S — OricOS userland app startup (TC-llvmmos-target-oricos)
;
; Appelé par kernel_app_exec via JSL BANK:$0200 (mode N, M=1, X=1, D=0).
; Retourne au kernel avec RTL après SYS_EXIT.
;
; Sections llvm-mos utilisées :
;   .init.000  → (init.000) DBR := PBR
;   .init.200  → (init.200) zero BSS
;   .call_main → appel de main() — fourni implicitement par le linker script
;   .after_main → SYS_EXIT + RTL
;
; ADR-05 v2 : mode N 8-bit (M=1/X=1 imposé par kernel), mono-bank.
; ADR-17    : SYS_EXIT = syscall $04 via COP #$AA.

; ── .init.000 : établir DBR = PBR ───────────────────────────────────
; Première section exécutée. PHK/PLB = DBR := PBR (0 net sur le stack).
    .section .init.000,"ax",@progbits
    .global __oricos_init_dbr
__oricos_init_dbr:
    phk
    plb

; ── .init.200 : zero BSS ────────────────────────────────────────────
; Remet à zéro la plage __bss_start .. __bss_start+__bss_size (8-bit max, v1).
; LMA = VMA (tout dans le même bank) → pas de copie .data nécessaire.
    .section .init.200,"ax",@progbits
    .global __oricos_zero_bss
__oricos_zero_bss:
    ; Utilise jsr vers routine dans .text pour économiser les octets init
    jsr     _oricos_do_zero_bss

    .section .text._oricos_do_zero_bss,"ax",@progbits
_oricos_do_zero_bss:
    lda     #0
    ldx     __bss_size
    beq     _zbss_done
    ldy     #0
_zbss_loop:
    sta     __bss_start,y
    iny
    dex
    bne     _zbss_loop
_zbss_done:
    rts

; ── .call_main : appel de main() ────────────────────────────────────
; Le linker script place cette section après les .init.*
    .section .call_main,"ax",@progbits
    .global __call_main
__call_main:
    jsr     main

; ── .after_main : SYS_EXIT puis RTL de secours ──────────────────────
; Exécuté après le retour de main() par le runtime llvm-mos.
    .section .after_main,"ax",@progbits
    .global __after_main
__after_main:
    ; SYS_EXIT : A = $04, X = exit_code = 0 (ADR-17)
    lda     #4
    ldx     #0
    .byte   0x02, 0xAA      ; COP #$AA

    ; RTL de secours si le kernel ne détruit pas la tâche immédiatement
    rtl
