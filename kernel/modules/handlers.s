; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : handlers.s — inclus depuis kernel.s
;
        .segment "NMI_HANDLER"

.export kernel_nmi_handler
kernel_nmi_handler:
        rti

; ════════════════════════════════════════════════════════════════════
;  COP_HANDLER — syscall dispatcher v0.2 (bank 1 $5700, ADR-13/17)
; ════════════════════════════════════════════════════════════════════
;
; Convention v0.2 (ADR-17) : cop #$AA → A=num syscall, X=arg1, Y=arg2.
; Table dispatch : SYSCALL_TABLE à $01:5750, 64 entrées × 2B (ADR-17).
; Le dispatcher sauve X dans DP_SYS_ARG_X avant de l'utiliser comme
; index. Les handlers lisent X arg depuis DP_SYS_ARG_X. Y est intact.
; Retour : A = valeur ($FF = erreur, ADR-17).
;
; ════════════════════════════════════════════════════════════════════
        .segment "COP_HANDLER"

.export kernel_cop_handler
kernel_cop_handler:
        sep #$30                ; sécurité M=X=1 (mode N native)
        ; ADR-03 : un syscall ne doit pas masquer les IRQ. Le COP entre avec
        ; I=1 (hardware) ; sans cli, un syscall bloquant (SYS_READ_CHAR) fige
        ; tout le noyau car l'IRQ KBD2 ne peut plus remplir le ring → deadlock.
        ; Le rti final restaure le P (donc I) de l'appelant.
        ; ⚠️ v1 : rend les syscalls interruptibles. Sûr tant qu'une seule
        ; tâche émet des syscalls (pas de réentrance sur la ZP scratch kernel).
        ; À revisiter avec le vrai blocage de tâche (OS-2.g v2).
        cli
        jsr kernel_forbid      ; g.6 : atomicité tâche↔tâche pendant le syscall
                               ; (le timer ne préempte pas tant que FORBID≠0)
        stx DP_SYS_ARG_X       ; sauve X (arg1) — sera écrasé par l'index
        cmp #$40               ; num < 64 ?
        bcs cop_invalid
        asl a                   ; A = num × 2 (offset bytes dans la table)
        tax                     ; X = index table (DP_SYS_ARG_X contient l'arg1)
        jsr (syscall_table,x)  ; appel handler via table (ADR-17)
        ; NB : les handlers qui basculent (yield/exit) jmp ailleurs et ont fait
        ; permit eux-mêmes → ne reviennent pas ici.
        jsr kernel_permit      ; FORBID-- (fin de syscall normal)
        rti                     ; retour caller — A = valeur de retour

cop_invalid:
        ; OS-2.i.v2 : journalise le syscall invalide (num ≥ 64).
        lda #ERR_BAD_SYSCALL
        ldx #LOG_WARN
        jsr kernel_log_write
        jsr kernel_permit
        lda #$FF                ; convention erreur ADR-17
        rti

; ════════════════════════════════════════════════════════════════════
;  SYSCALL_TABLE — table 64 entrées × 2B (bank 1 $5750, ADR-17)
; ════════════════════════════════════════════════════════════════════
        .segment "SYSCALL_TABLE"

.export syscall_table
syscall_table:
        .word sys_invalid       ; $00 réservé
        .word sys_print_char    ; $01 SYS_PRINT_CHAR
        .word sys_print_string  ; $02 SYS_PRINT_STRING
        .word sys_read_char     ; $03 SYS_READ_CHAR  (stub — OS-2.d)
        .word sys_exit          ; $04 SYS_EXIT
        .word sys_yield         ; $05 SYS_YIELD
        .word sys_get_key       ; $06 SYS_GET_KEY    (stub — OS-2.d)
        .word sys_fat_open      ; $07 SYS_FAT_OPEN
        .word sys_fat_read      ; $08 SYS_FAT_READ
        .word sys_fat_close     ; $09 SYS_FAT_CLOSE  (stub)
        .word sys_panic         ; $0A SYS_PANIC
        .word sys_alloc_bank    ; $0B SYS_ALLOC_BANK
        .word sys_free_bank     ; $0C SYS_FREE_BANK
        .word sys_gfx_clear     ; $0D SYS_GFX_CLEAR
        .word sys_gfx_fill_rect ; $0E SYS_GFX_FILL_RECT
        .word sys_gfx_blit      ; $0F SYS_GFX_BLIT
        .word sys_gfx_line      ; $10 SYS_GFX_LINE
        .word sys_gfx_text      ; $11 SYS_GFX_TEXT
        .word sys_sleep_ms      ; $12 SYS_SLEEP_MS
        .word sys_win_create    ; $13 SYS_WIN_CREATE (SP-3.m G.2)
        .word sys_win_flush     ; $14 SYS_WIN_FLUSH  (SP-3.m G.4bis/G.6)
        .word sys_event_avail   ; $15 SYS_EVENT_AVAIL (SP-3.n G.2)
        .word sys_get_next_event ; $16 SYS_GET_NEXT_EVENT (SP-3.n G.2)
        .word sys_main_loop     ; $17 SYS_MAIN_LOOP (SP-3.n G.3a)
        .word sys_ui_define     ; $18 SYS_UI_DEFINE (SP-3.n G.3b)
        .word sys_do_dlgbox     ; $19 SYS_DO_DLGBOX (SP-3.n G.5)
        .word sys_alert         ; $1A SYS_ALERT (SP-3.n G.6)
        .word sys_ctl_get_value ; $1B SYS_CTL_GET_VALUE (SP-3.o S.1)
        .word sys_ctl_set_value ; $1C SYS_CTL_SET_VALUE (SP-3.o S.1)
        .word sys_get_ticks     ; $1D SYS_GET_TICKS (Sprint 4 clock)
        .word sys_timer_set     ; $1E SYS_TIMER_SET (post-clôture ADR-30, pattern GEOS InitProcesses)
        .word sys_timer_clear   ; $1F SYS_TIMER_CLEAR
        .word sys_hotzone_set   ; $20 SYS_HOTZONE_SET (post-clôture ADR-30, pattern GEOS DoIcons)
        .word sys_hotzone_clear ; $21 SYS_HOTZONE_CLEAR
        .repeat 30
        .word sys_invalid       ; $22-$3F réservés
        .endrep

; ════════════════════════════════════════════════════════════════════
;  IRQ_HANDLER — scheduler préemptif (bank 1 $5600)
; ════════════════════════════════════════════════════════════════════
;
; Sprint 1.c : le scheduler est désormais sur la ligne IRQ — déclenchée
; par VIA T1 (Sprint 2 ; pour Sprint 1.c le test inject IRQF_VIA en
; pattern set/step/clear pour mimer un timer).
;
; Entrée hw mode N : PB/PC/P pushés sur la stack courante.
; L'ack de la source IRQ (lecture VIA registre) est implicite ici —
; le test côté Phosphoric clear cpu->irq juste après inject.
;
; ════════════════════════════════════════════════════════════════════
        .segment "IRQ_HANDLER"

.export kernel_irq_handler
kernel_irq_handler:
        sep #$30                ; M=1, X=1 (sécurité)

        ; ── Save A/X/Y de la tâche courante sur sa stack ───────────
        pha
        phx
        phy

        ; ── SP-3.e v0.2 : souris MOU2 event-driven (ADR-24) ────────
        ; Si event souris en attente : lit + traite (clic→focus, drag).
        ; kernel_mouse_read clear l'event (deassert IRQF_MOU2).
        lda MOU2_STATUS
        and #$80                ; bit7 = event
        beq irq_no_mou
        jsr kernel_mouse_read
        ; ADR-28 : Étape 3 (skip mouse_step en mode serveur) REVERTÉE après bug
        ; interactif (curseur figé, widgets non réactifs malgré tests headless verts).
        ; État courant : mouse_step toujours appelé en IRQ ; en mode serveur, le
        ; serveur fait un double appel (idempotent mais pas optimal). Investigation
        ; de la cause racine du bug Étape 3 reportée. Ratification ADR-28 (design C)
        ; tient ; Étape 3 implémentation à reprendre proprement. Cf. §7.4 limites.
        jsr kernel_wm_mouse_step
        ; ── SP-3.n G.1 : poste l'événement souris dans la file (edge-detect ──
        ; bouton gauche : down/up sur transition, moved sinon). Coexiste avec
        ; kernel_wm_mouse_step (qui garde sa logique focus/drag actuelle).
        lda MOUSE_BTN
        and #MOU2_BTN_LEFT
        beq irq_mou_curup        ; bouton gauche relâché maintenant
        lda MOUSE_PREV_BTN
        and #MOU2_BTN_LEFT
        bne irq_mou_moved        ; déjà pressé avant → maintenu = moved
        lda #EV_MOUSE_DOWN       ; transition relâché→pressé
        bra irq_mou_post
irq_mou_curup:
        lda MOUSE_PREV_BTN
        and #MOU2_BTN_LEFT
        beq irq_mou_moved        ; relâché avant et maintenant → moved
        lda #EV_MOUSE_UP         ; transition pressé→relâché
        bra irq_mou_post
irq_mou_moved:
        lda #EV_MOUSE_MOVED
irq_mou_post:
        jsr kernel_event_push_mouse
irq_no_mou:
        ; ── OS-2.d (ADR-22) : draine la FIFO KBD2 → ring ───────────
        jsr kernel_kbd_poll
        ; ── g.5 : réveille la tâche bloquée sur le clavier (si touche dispo) ──
        jsr kernel_kbd_wake
        ; ── SP-3.n G.2 : réveille la tâche bloquée sur la file d'événements ──
        jsr kernel_event_wake
        ; ADR-28 Étape 2 : pas de jsr kernel_raw_wake ici (overhead IRQ
        ; détectable par tests timing-sensibles, e.g. ctl_demo). Le wake est
        ; colocalisé dans kernel_raw_push_mouse/push_key (n'est appelé qu'en
        ; mode serveur WM actif).

        ; ── VIA T1 présent ? (sinon IRQ MOU2/KBD2 seule : pas de tick) ──
        lda VIA_IFR
        and #$40                ; bit6 = T1
        bne irq_t1
        ; Pas de T1 : restaure la MÊME tâche (aucun tick/context switch).
        ply
        plx
        pla
        rti
irq_t1:
        ; ── Ack VIA T1 IRQ (lecture T1C-L clear T1 IFR) ────────────
        lda VIA_T1CL

        ; ── Increment tick counter ─────────────────────────────────
        lda TICK_COUNTER
        inc a
        sta TICK_COUNTER
        ; OS-2.g v2.b : décrémente les sommeils (SYS_SLEEP_MS), réveille à 0.
        jsr kernel_sleep_tick
        ; Pattern GEOS InitProcesses : tick les timers d'app (post-clôture ADR-30).
        jsr kernel_timer_tick
        lda TICK_COUNTER        ; recharge (sleep_tick a clobbé A)
        cmp #TICK_GOAL
        bcc do_switch
        ; ≥ TICK_GOAL. SP-3.e v0.4 : mode persistant (live) vs STP (tests).
        ; Si NO_STP_FLAG == magic $A5 (posé par --kernel), on continue le
        ; scheduler à l'infini (GUI interactive). Sinon STP (signal boot OK tests).
        lda NO_STP_FLAG
        cmp #$A5
        beq do_switch
        stp
        bra *

.export do_switch
do_switch:
        ; ── ADR-14 : scheduler N-tâches round-robin (OS-2.g v2.a) ──────
        ; Entrée IRQ (frame poussée par hw+handler) OU yield coopératif
        ; (sys_yield construit une frame compatible puis jmp ici).
        ; Sauve SP dans tcb[CUR].S, passe CUR à READY, choisit le prochain
        ; slot READY (kernel_sched_find_next), charge son SP. Avec 2 tâches
        ; live, le round-robin reproduit l'alternance 1↔2. Aucun jsr/rts ne
        ; doit traverser le tcs (changement de pile) → helpers appelés AVANT.
        lda FORBID_COUNT
        beq ds_proceed
        jmp restore_and_return          ; g.6 : tâche en syscall → pas de préemption
ds_proceed:
        lda TASK_CUR
        jsr kernel_tcb_ptr              ; SCHED_PTR = &tcb[CUR]
        rep #$20
        tsc                             ; A = SP courant (16-bit)
        ldy #TCB_S_LO
        sta [SCHED_PTR],Y               ; tcb[CUR].S = SP
        sep #$20
        lda #TASK_STATE_READY
        ldy #TCB_STATE
        sta [SCHED_PTR],Y               ; tcb[CUR].STATE = READY
        lda TASK_CUR
        jsr kernel_sched_find_next      ; A = prochain pid READY
        sta TASK_CUR
        jsr kernel_tcb_ptr              ; SCHED_PTR = &tcb[NEXT]
        lda #TASK_STATE_RUNNING
        ldy #TCB_STATE
        sta [SCHED_PTR],Y               ; tcb[NEXT].STATE = RUNNING
        rep #$20
        ldy #TCB_S_LO
        lda [SCHED_PTR],Y               ; A = tcb[NEXT].S
        tcs                             ; ⚠ change de pile — rien après ne doit jsr/rts
        sep #$20

.export restore_and_return
restore_and_return:
        ; ── Pull Y/X/A depuis la nouvelle stack ────────────────────
        ; Cible commune : fin de do_switch, et jmp depuis sys_exit (g.4)
        ; après tcs (la pile a déjà basculé sur la nouvelle tâche).
        ply
        plx
        pla
        rti

; ════════════════════════════════════════════════════════════════════
;  CHARSET — fonte char Oric 1 (1024 octets) embedded à bank 1 $5800
; ════════════════════════════════════════════════════════════════════
; Extraite de roms/basic11b.rom offset $3B78 (= ROM $FB78). 128 chars
; × 8 lignes. Le kernel copie ce blob vers bank 0 $B400 au boot.
; ════════════════════════════════════════════════════════════════════
        .segment "CHARSET"
.export kernel_charset
kernel_charset:
        .incbin "../data/charset.bin"
