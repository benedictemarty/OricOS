; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : handlers.s — inclus depuis kernel.s
;
; ════════════════════════════════════════════════════════════════════
;  FRAME IRQ 16-BIT (ADR-32 §10.9, fix 2026-06-10 — « option B » de
;  l'audit IRQ_CONFORMITE §3.3 A, réalisée)
; ════════════════════════════════════════════════════════════════════
;
;  HISTORIQUE. L'ancien `kernel_irq_handler` faisait `sep #$30` AVANT
;  `pha/phx/phy` (8-bit). Conséquences pour tout contexte interrompu en
;  16-bit :
;    - X=0 : octets hauts de X/Y mis à zéro silencieusement (documenté
;      dès 2026-05-31, mitigé par l'invariant « X=1 aux points
;      préemptibles »).
;    - M=0 : octet haut de A (registre B) REMPLACÉ par la valeur que le
;      code IRQ y laissait — CE CAS N'ÉTAIT PAS COUVERT par l'invariant.
;      C'était la cause racine du bug clock Opt-A (kernel_print_char
;      interrompu entre `lda CURSOR_ADDR` et `sta CURSOR_ADDR` en M=16 :
;      C=$BC98 → $5C98 au RTI → prints hors écran). Preuve : trace
;      registres + test Phosphoric `test-oricos-irq-frame-m16` (ROUGE
;      3/5 sur le handler 8-bit, VERT depuis ce fix).
;
;  FIX (frame 16-bit). `rep #$30` AVANT pha/phx/phy : la frame fait
;  TOUJOURS 6 octets (A/X/Y × 2), quel que soit l'état M/X de
;  l'interrompu. Pulls symétriques sous `rep #$30` (sorties no-T1 et
;  restore_and_return). Le RTI restaure le P (donc le M/X) du contexte
;  interrompu.
;
;  FORGEURS DE FRAME (à maintenir au MÊME format 10 octets
;  [Y16][X16][A16][P][PCL][PCH][PBR]) :
;    sched.s   kernel_task_create   (frame initiale page:$F2..$FB, S=$F1)
;    boot.s    frame fake task B    ($02F2..$02FB, S=$02F1)
;    wm.s      sys_yield, sys_sleep_ms, sys_read_char (sread),
;              sys_get_next_event (sgne), sys_main_loop (sml)
;    event.s   kernel_event_wait (kew), raw_wait (krw)
;  Tout NOUVEAU chemin bloquant qui forge une resume frame DOIT pousser
;  A/X/Y en 16-bit (rep #$30) — un push 8-bit décale S de 3 octets et
;  le rti part dans le décor (vu : sys_sleep_ms oublié au premier jet,
;  crash PC=$0000 après ~6 ticks).
;
;  L'ancien invariant « X=1 aux points préemptibles » n'est PLUS requis
;  pour la préservation à travers l'IRQ (couverte par construction).
;  Les régions rep #$10/#$30 longues restent à examiner pour d'autres
;  raisons (latence IRQ, réentrance ZP) — cf. audit-rep-x (baseline
;  Makefile) qui continue de tracer les nouveaux sites.
;
;  Référence : IRQ_CONFORMITE.md §3.3 + docs/adr/0032 §10.9.
; ════════════════════════════════════════════════════════════════════

        .segment "NMI_HANDLER"

; IRQ_CONFORMITE §3.4 hygiène : aucune source NMI câblée v1
; (pas de bouton reset, pas d'overflow VIA, pas de cartridge IRQ). Le
; vecteur NMI bank 1 ($5500) reçoit l'éventuel NMI parasite et `rti`
; immédiat — no-op silencieux. Si une homologation HW exige robustesse,
; ajouter un log minimal (PANIC_NMI_SPURIOUS) avant rti.
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
        ; Exception (Opt-A 2026-06-09) : sys_gfx_fill_rect et sys_win_flush
        ; ajoutent `sei`/`cli` localement pour fermer la fenêtre de réentrance
        ; IRQ↔syscall sur les ZP scratch gfx/wm (cf. docs/CR/).
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
        ; ── ADR-32 §10.9 : frame 16-bit — préserve A/X/Y INTÉGRAUX ──
        ; L'ancien `sep #$30` + pushes 8-bit perdait l'octet haut de A
        ; (registre B) et de X/Y pour tout contexte interrompu en M=16 ou
        ; X=16 (bug clock mesuré : kernel_print_char C=$BC98→$5C98 au RTI).
        ; Le passage 16-bit (M=X=0) AVANT les pushes : la frame fait toujours 6 octets
        ; (A/X/Y × 2), quel que soit l'état M/X de l'interrompu. Le RTI
        ; final restaure son P (donc son M/X) intact.
        rep #$30
        pha
        phx
        phy
        sep #$30                ; le corps du handler travaille en 8-bit

        ; ── SP-3.e v0.2 : souris MOU2 event-driven (ADR-24) ────────
        ; Si event souris en attente : lit + traite (clic→focus, drag).
        ; kernel_mouse_read clear l'event (deassert IRQF_MOU2).
        lda MOU2_STATUS
        and #$80                ; bit7 = event
        bne irq_mou_event
        jmp irq_no_mou
irq_mou_event:
        ; ── ADR-32 §10.11 : sauvegarde des scratch ZP $08-$93 ──────
        ; Le chemin souris (mouse_step → drag → redraw → event_push)
        ; clobbe WM_ARG_*/WM_DP_TMP/GFX_*/EVT_TMP/VRAM_OP_* — un body
        ; syscall préempté (cop_handler fait cli, ADR-03) les relirait
        ; corrompus (rouge test-position-shift v2.2). Save ici, restore
        ; à irq_mou_zp_restore : le body reprend avec ses scratch
        ; intacts. Coût ~2×750 cyc, payé UNIQUEMENT sur IRQ souris
        ; (les IRQ T1 pures ne passent pas ici). Remplace les sei
        ; Opt-A par une protection de classe (tous les syscalls).
        rep #$30
        ldx #$0000
irq_mou_zp_save:
        lda $08,x               ; D=0 : ZP $08+X (16-bit par paire)
        sta f:IRQ_ZP_SAVE,x
        inx
        inx
        cpx #IRQ_ZP_SAVE_LEN
        bcc irq_mou_zp_save
        sep #$30
        jsr kernel_mouse_read
        ; ADR-32 §3 : si WM_TASKMODE=$A5 (anti-revert ADR-28 Étape 3), l'IRQ
        ; ne fait PAS mouse_step — c'est task_wm qui le fait après raw_pop
        ; (atomicité par flag unique). Default $00 → comportement legacy
        ; inchangé (mouse_step en IRQ comme avant).
        lda WM_TASKMODE
        cmp #$A5
        beq irq_taskmode_cursor
        jsr kernel_wm_mouse_step
        bra irq_skip_mouse_step
irq_taskmode_cursor:
        ; Single-writer sprite (fix glitchs 2026-06-11) : le TOP-HALF
        ; positionne le curseur avec MOUSE_X FRAIS (post-mouse_read),
        ; sous I=1 — atomique. task_wm ne touche plus au sprite
        ; (kernel_wm_draw_cursor gate sur WM_TASKMODE).
        jsr kernel_wm_draw_cursor_irq
irq_skip_mouse_step:
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
        ; ── ADR-32 §10.11 : restauration des scratch ZP $08-$93 ────
        rep #$30
        ldx #$0000
irq_mou_zp_restore:
        lda f:IRQ_ZP_SAVE,x
        sta $08,x
        inx
        inx
        cpx #IRQ_ZP_SAVE_LEN
        bcc irq_mou_zp_restore
        sep #$30
irq_no_mou:
        ; Convention .smart (CLAUDE.md OricOS) : label atteint par jmp en
        ; M=8/X=8 ; le sep #$30 ci-dessus couvre aussi le fall-through.
        .a8
        .i8
        ; ── OS-2.d (ADR-22) : draine la FIFO KBD2 → ring ───────────
        ; IRQ_CONFORMITE §3.4 : optimisation envisagée (court-circuit si
        ; KBD2_STATUS bit7 = 0) testée mais cassait des sentinelles
        ; cycle-précises de ctl_demo (drag scrollbar). Gain ~24 cycles/IRQ
        ; trop marginal pour justifier la régression de test. À reconsidérer
        ; quand §3.1 (top-half minimal) sera livrée et que les tests timing
        ; seront rebasés.
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
        rep #$30                ; ADR-32 §10.9 : frame 16-bit
        ply
        plx
        pla
        rti
irq_t1:
        ; Convention .smart (CLAUDE.md OricOS) : label atteint par bne en
        ; M=8/X=8 mais précédé textuellement d'un passage 16-bit + flow-break.
        .a8
        .i8
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
        rep #$30                ; ADR-32 §10.9 : frame 16-bit (A/X/Y × 2 octets)
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

; ════════════════════════════════════════════════════════════════════
;  CHARSET XVGA — fonte 8×8 IBM CGA pour TEXT16 GPU (chrome desktop)
; ════════════════════════════════════════════════════════════════════
; Distincte du charset Atmos (ci-dessus) qui sert au mode TEXT Oric 1
; historique (banner OricOS via ULA). Cette fonte VGA8 IBM CGA donne
; un look « rétro pixel » plus moderne pour le chrome XVGA (titlebar,
; widgets, menus, taskbar). Extraite de Debian
; consolefonts/Arabic-VGA8.psf (Latin 0-127 = IBM CGA héritage,
; domaine public). Uploadée par `kernel_tk_font_init` vers TK_FONT_ADDR.
; ════════════════════════════════════════════════════════════════════
.export kernel_charset_xvga
kernel_charset_xvga:
        .incbin "../data/charset-xvga.bin"

; SP-GUI (fontes multiples) : variante GRASSE (smear, gen-font-bold.py).
; Segment FONTBOLD à l'adresse FIXE $D000 (CHARSET_XVGA_BOLD_SRC) — pas
; dans CHARSET (qui heurterait SENTINEL $6300 écrit avant l'upload).
; Uploadée par kernel_tk_font_init vers TK_FONT_BOLD_ADDR (SDRAM).
        .segment "FONTBOLD"
.export kernel_charset_xvga_bold
kernel_charset_xvga_bold:
        .incbin "../data/charset-xvga-bold.bin"
