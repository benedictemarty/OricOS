; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : sched.s — inclus depuis kernel.s
;
; Scheduler N-tâches (OS-2.g v2.a, implémente ADR-14).
; Helpers en segment CODE (place ample) appelés par le context-switch inline
; du handler IRQ (handlers.s). Le switch lui-même reste dans IRQ_HANDLER car
; le tcs (changement de pile) ne doit être traversé par aucun jsr/rts.
;
; Pré-cond : appelés en mode N M=X=1 (sep #$30 du handler IRQ), DBR=0.
        .segment "CODE"

.a8
.i8

; ════════════════════════════════════════════════════════════════════
;  kernel_tcb_ptr — A = pid (1..16) → SCHED_PTR = &tcb[pid] (24-bit, bank 1)
; ════════════════════════════════════════════════════════════════════
; tcb[pid] = TCB_TABLE_BASE + (pid-1)*TCB_SIZE : le tableau est indexé
; (pid-1) (TCB_1/pid 1 à BASE+0, TCB_2/pid 2 à BASE+20). TCB_SIZE=20 = 16+4.
; Clobbers A. Préserve X, Y. SCHED_TMP utilisé.
.export kernel_tcb_ptr
kernel_tcb_ptr:
        rep #$20                ; A 16-bit pour (pid-1)*20 + base
        and #$00FF              ; A = pid (purge l'octet haut)
        dec a                   ; slot 0-based = pid-1
        asl a
        asl a                   ; (pid-1)*4
        sta SCHED_TMP
        asl a
        asl a                   ; (pid-1)*16
        clc
        adc SCHED_TMP           ; (pid-1)*16 + (pid-1)*4 = (pid-1)*20
        clc
        adc #(TCB_TABLE_BASE & $FFFF)   ; + $5C00
        sta SCHED_PTR           ; lo/hi (16-bit)
        sep #$20
        lda #^TCB_TABLE_BASE    ; octet bank ($01)
        sta SCHED_PTR+2
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_sched_find_next — A = pid courant → A = prochain pid READY
; ════════════════════════════════════════════════════════════════════
; Round-robin sur les slots 1..TCB_MAX, en repartant de CUR+1 (wrap à 1).
; Sélectionne le premier slot en état READY. Terminaison garantie : l'appelant
; passe tcb[CUR].STATE à READY avant l'appel → au pire le scan revient sur CUR.
; Clobbers A, Y, SCHED_CAND, SCHED_PTR. Préserve X.
.export kernel_sched_find_next
kernel_sched_find_next:
        sta SCHED_CAND          ; cand = CUR
sfn_loop:
        lda SCHED_CAND
        inc a
        cmp #TCB_MAX+1          ; > 16 ?
        bcc sfn_nowrap
        lda #$01                ; wrap → pid 1 (0 = invalid)
sfn_nowrap:
        sta SCHED_CAND
        jsr kernel_tcb_ptr      ; A=cand → SCHED_PTR = &tcb[cand]
        ldy #TCB_STATE
        lda [SCHED_PTR],Y
        cmp #TASK_STATE_READY
        bne sfn_loop            ; pas READY → continue le scan
        lda SCHED_CAND          ; A = pid sélectionné
        rts
