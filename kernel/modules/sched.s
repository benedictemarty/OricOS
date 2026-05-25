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
; Round-robin BORNÉ (≤ TCB_MAX essais) depuis CUR+1 (wrap à 1). Saute l'idle
; (IDLE_PID) dans la passe normale ; si AUCUNE tâche normale READY → retombe sur
; IDLE_PID (toujours runnable). Ferme le trou « dernière tâche / tout bloqué »
; (plus de boucle infinie). Clobbers A, X, Y, SCHED_CAND, SCHED_PTR.
.export kernel_sched_find_next
kernel_sched_find_next:
        sta SCHED_CAND          ; cand = CUR
        ldx #TCB_MAX            ; bornage du scan (au plus TCB_MAX essais)
sfn_loop:
        lda SCHED_CAND
        inc a
        cmp #TCB_MAX+1          ; > 16 ?
        bcc sfn_nowrap
        lda #$01                ; wrap → pid 1 (0 = invalid)
sfn_nowrap:
        sta SCHED_CAND
        cmp IDLE_PID            ; idle ? (cmp abs-long) → sauté en passe normale
        beq sfn_dec
        jsr kernel_tcb_ptr      ; A=cand → SCHED_PTR (préserve X = compteur)
        ldy #TCB_STATE
        lda [SCHED_PTR],Y
        cmp #TASK_STATE_READY
        beq sfn_found           ; READY (≠ idle) → sélectionnée
sfn_dec:
        dex
        bne sfn_loop
        lda IDLE_PID            ; aucune tâche normale READY → fallback idle
        rts
sfn_found:
        lda SCHED_CAND          ; A = pid sélectionné
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_task_create — crée une tâche dynamiquement (OS-2.g v2.a / g.3)
; ════════════════════════════════════════════════════════════════════
; In : X = entry PC lo, Y = entry PC hi, A = priorité (0..7).
; Out: A = pid alloué (1..TCB_MAX-1), ou $00 si plus de slot libre.
; Alloue : slot TCB (bitmap), page de pile bank 0 (STACK_NEXT_PAGE bump),
; initialise le TCB et forge une frame d'interruption initiale (Y/X/A=0,
; P=$30 mode N M=X=1 I=0, PC=entry, PB=1) — même format que la pré-init de
; task B au boot — pour que le 1er context-switch « entre » à `entry`.
; Pré-cond : mode N M=X=1, DBR=0 (appelé hors IRQ : boot, ou plus tard syscall).
.export kernel_task_create
kernel_task_create:
        .a8
        .i8
        stx TC_ENTRY_LO
        sty TC_ENTRY_HI
        sta TC_PRIO
        ; ── 1. scan bitmap : 1er slot libre (pids 1..TCB_MAX-1) ──
        rep #$20
        lda #$0002              ; masque = bit 1
        sta SCHED_TMP
        sep #$20
        ldx #$01                ; pid candidat
tcc_scan:
        rep #$20
        lda TCB_BITMAP
        and SCHED_TMP
        bne tcc_next            ; bit set → slot occupé
        lda TCB_BITMAP          ; libre → réserve le bit
        ora SCHED_TMP
        sta TCB_BITMAP
        sep #$20
        bra tcc_slot
tcc_next:
        asl SCHED_TMP           ; masque <<= 1
        sep #$20
        inx
        cpx #TCB_MAX
        bcc tcc_scan
        lda #$00                ; plus de slot
        rts
tcc_slot:
        stx TC_PID              ; X = pid alloué
        ; ── 2. alloue une page de pile (bump) ──
        lda STACK_NEXT_PAGE
        sta TC_PAGE             ; page courante
        inc a
        sta STACK_NEXT_PAGE     ; prochaine
        ; ── 3. init TCB[pid] ──
        lda TC_PID
        jsr kernel_tcb_ptr      ; SCHED_PTR = &tcb[pid]
        lda TC_PID
        ldy #TCB_PID
        sta [SCHED_PTR],Y
        lda #TASK_STATE_READY
        ldy #TCB_STATE
        sta [SCHED_PTR],Y
        lda TC_PRIO
        ldy #TCB_PRIO
        sta [SCHED_PTR],Y
        lda TASK_CUR            ; parent = tâche courante
        ldy #TCB_PARENT
        sta [SCHED_PTR],Y
        lda TC_CODE_BANK        ; PB = bank de code (1 = kernel ; app = son bank)
        ldy #TCB_PB
        sta [SCHED_PTR],Y
        lda #$00
        ldy #TCB_DB
        sta [SCHED_PTR],Y       ; DB = 0
        ldy #TCB_STACK_BANK
        sta [SCHED_PTR],Y       ; stack_bank = 0
        ldy #TCB_FLAGS
        sta [SCHED_PTR],Y       ; flags = 0
        lda TC_ENTRY_LO
        ldy #TCB_PC_LO
        sta [SCHED_PTR],Y
        lda TC_ENTRY_HI
        ldy #TCB_PC_HI
        sta [SCHED_PTR],Y
        ; saved_S = page:$F4 (la frame occupe $F5..$FB ; ply reprend à $F5)
        lda #$F4
        ldy #TCB_S_LO
        sta [SCHED_PTR],Y
        lda TC_PAGE
        ldy #TCB_S_HI
        sta [SCHED_PTR],Y
        ; ── 4. forge la frame à page:$F5..$FB (bank 0, adressage long) ──
        lda #$F5
        sta TC_FPTR
        lda TC_PAGE
        sta TC_FPTR+1
        lda #$00
        sta TC_FPTR+2           ; bank 0 (frame en bank 0, indép. du DBR)
        ldy #$00
        lda #$00
        sta [TC_FPTR],Y         ; +0 Y_init = 0
        iny
        sta [TC_FPTR],Y         ; +1 X_init = 0
        iny
        sta [TC_FPTR],Y         ; +2 A_init = 0
        iny
        lda #$30                ; +3 P_init = M=1 X=1 (mode N), I=0 (IRQ on)
        sta [TC_FPTR],Y
        iny
        lda TC_ENTRY_LO
        sta [TC_FPTR],Y         ; +4 PCL
        iny
        lda TC_ENTRY_HI
        sta [TC_FPTR],Y         ; +5 PCH
        iny
        lda TC_CODE_BANK
        sta [TC_FPTR],Y         ; +6 PB = bank de code
        lda TC_PID              ; retour A = pid
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_forbid / kernel_permit — sections critiques tâche↔tâche (g.6)
; ════════════════════════════════════════════════════════════════════
; ADR-25 Exec-classique. Forbid suspend le context-switch préemptif (le timer
; vérifie FORBID_COUNT dans do_switch) ; les IRQ continuent de tourner.
; FORBID_COUNT en bank 1 → LDA/STA long (INC n'a pas de mode abs-long sur 65816).
; Préservent A, X, Y (A porte le num syscall à l'entrée COP et la valeur de
; retour à la sortie → NE PAS le clobber). Nestable (inc/dec).
.export kernel_forbid
kernel_forbid:
        pha
        lda FORBID_COUNT
        inc a
        sta FORBID_COUNT
        pla
        rts
.export kernel_permit
kernel_permit:
        pha
        lda FORBID_COUNT
        beq kp_skip             ; déjà 0 → ne descend pas sous zéro
        dec a
        sta FORBID_COUNT
kp_skip:
        pla
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_block_switch — bascule en bloquant la tâche courante (g.5)
; ════════════════════════════════════════════════════════════════════
; Comme do_switch mais marque CUR BLOCKED (au lieu de READY). Une resume frame
; valide doit déjà être au sommet de la pile (forgée par l'appelant). Entré par
; jmp (pas via le timer → pas de garde FORBID). Aucun jsr/rts ne traverse le tcs.
.export kernel_block_switch
kernel_block_switch:
        lda TASK_CUR
        jsr kernel_tcb_ptr
        rep #$20
        tsc
        ldy #TCB_S_LO
        sta [SCHED_PTR],Y               ; tcb[CUR].S = SP (resume frame)
        sep #$20
        lda #TASK_STATE_BLOCKED
        ldy #TCB_STATE
        sta [SCHED_PTR],Y               ; tcb[CUR].STATE = BLOCKED
        lda TASK_CUR
        jsr kernel_sched_find_next      ; next READY (CUR BLOCKED → ignorée)
        sta TASK_CUR
        jsr kernel_tcb_ptr
        lda #TASK_STATE_RUNNING
        ldy #TCB_STATE
        sta [SCHED_PTR],Y
        rep #$20
        ldy #TCB_S_LO
        lda [SCHED_PTR],Y
        tcs
        sep #$20
        jmp restore_and_return

; ════════════════════════════════════════════════════════════════════
;  kernel_sleep_tick — décrémente les sommeils, réveille à 0 (SYS_SLEEP_MS)
; ════════════════════════════════════════════════════════════════════
; Appelé par le handler IRQ T1 à chaque tick. Pour chaque pid 1..TCB_MAX-1 dont
; SLEEP_TICKS[pid] > 0 : décrémente ; si atteint 0 → tcb[pid].STATE = READY.
; Clobbers A, X, Y (restaurés par le handler IRQ).
.export kernel_sleep_tick
kernel_sleep_tick:
        ldx #$01                ; pid = 1
slt_loop:
        lda f:SLEEP_TICKS,X     ; SLEEP_TICKS[pid] (abs-long,X)
        beq slt_next            ; 0 → pas endormi
        dec a
        sta f:SLEEP_TICKS,X
        bne slt_next            ; pas encore 0 → reste endormi
        ; atteint 0 → réveille tcb[pid] (kernel_tcb_ptr préserve X)
        txa
        jsr kernel_tcb_ptr      ; SCHED_PTR = &tcb[pid]
        lda #TASK_STATE_READY
        ldy #TCB_STATE
        sta [SCHED_PTR],Y
slt_next:
        inx
        cpx #TCB_MAX            ; pids 1..TCB_MAX-1 (SLEEP_TICKS[16] = CURSOR_ADDR)
        bcc slt_loop
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_kbd_wake — réveille la tâche bloquée sur le clavier (g.5)
; ════════════════════════════════════════════════════════════════════
; Appelé par le handler IRQ après kernel_kbd_poll. Si une tâche attend le
; clavier (KBD_WAITER≠0) ET une touche est dispo (ring non vide), la passe
; READY et efface KBD_WAITER. Clobbers A, Y (restaurés par le handler IRQ).
.export kernel_kbd_wake
kernel_kbd_wake:
        lda KBD_WAITER
        beq kwake_done                  ; personne n'attend
        lda KBD_RING_COUNT
        beq kwake_done                  ; ring vide → pas de réveil
        lda KBD_WAITER
        jsr kernel_tcb_ptr              ; SCHED_PTR = &tcb[KBD_WAITER]
        lda #TASK_STATE_READY
        ldy #TCB_STATE
        sta [SCHED_PTR],Y               ; débloque la tâche
        lda #$00
        sta KBD_WAITER
kwake_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_bitmap_clear — libère le slot pid dans TCB_BITMAP (OS-2.g g.4)
; ════════════════════════════════════════════════════════════════════
; In : A = pid (1..15). Efface le bit pid (bitmap &= ~(1<<pid)).
; Clobbers A, X, SCHED_TMP.
.export kernel_bitmap_clear
kernel_bitmap_clear:
        tax                     ; X = pid (compteur de décalage)
        rep #$20
        lda #$0001              ; masque = 1
        sta SCHED_TMP
        sep #$20
bmc_shift:
        rep #$20
        asl SCHED_TMP           ; masque <<= 1
        sep #$20
        dex
        bne bmc_shift           ; pid décalages → masque = 1<<pid
        rep #$20
        lda SCHED_TMP
        eor #$FFFF              ; ~masque
        and TCB_BITMAP
        sta TCB_BITMAP          ; bitmap &= ~(1<<pid)
        sep #$20
        rts
