; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : event.s — inclus depuis kernel.s
;
; File d'événements unifiée (SP-3.n G.1, ADR-26 draft : modèle GUI déclaratif
; GeoWorks-like). Les drivers IRQ (KBD2 clavier, MOU2 souris) postent des
; records de 10 octets (cf. kernel.s : EVENT_RING, EVT_*). Consommée plus tard
; par SYS_MAIN_LOOP (G.2).
;
; Migration PROGRESSIVE : KBD_RING et MOUSE_* restent alimentés en parallèle →
; les consommateurs actuels ne changent pas (aucune régression).
;
; Pré-cond push : appelé depuis l'IRQ handler (mode N M=X=1, DBR=0, I=1 → pas
; de nesting IRQ). EVT_TMP ($6E) est un scratch dédié IRQ-only (jamais touché
; par du code interruptible) → pas de race. La ZP basse ($00-$88) est disjointe
; de la ZP app llvm-mos ($89-$CF) → l'IRQ ne corrompt pas l'app courante.
        .segment "CODE"

.a8
.i8

; ════════════════════════════════════════════════════════════════════
;  kernel_event_init — vide la file (head=tail=count=0)
; ════════════════════════════════════════════════════════════════════
.export kernel_event_init
kernel_event_init:
        lda #$00
        sta EVENT_RING_HEAD
        sta EVENT_RING_TAIL
        sta EVENT_RING_COUNT
        sta EVENT_WAITER         ; G.2 : aucune tâche en attente
        sta WM_APP_DRIVEN        ; G.3c : 0 = shell (auto-close) ; $A5 si une app
                                 ;        pilote SYS_MAIN_LOOP
        lda #$FF
        sta SCROLL_DRAG_ID       ; SP-3.o S.2 : aucun ascenseur en drag
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_event_wait — bloque la tâche courante jusqu'à un événement (G.5)
; ════════════════════════════════════════════════════════════════════
; Helper réutilisable : attend qu'un événement soit disponible (NE le pop PAS).
; Mode tâche : block/wake (EVENT_WAITER + réveil IRQ kernel_event_wake), rend le
; CPU. Mode boot-context : spin + WAI. Utilisé par la boucle modale DoDlgBox.
; Retourne à l'appelant (jsr) avec EVENT_RING_COUNT > 0. Clobbers A.
.export kernel_event_wait
kernel_event_wait:
        lda SCHED_ACTIVE
        cmp #$A5
        beq kew_block_mode
kew_spin:
        lda EVENT_RING_COUNT
        bne kew_ret
        wai
        bra kew_spin
kew_ret:
        rts
kew_block_mode:
kew_loop:
        sei
        lda EVENT_RING_COUNT
        bne kew_got
        ; file vide sous sei → enregistre l'attente + bloque (pas de lost-wakeup)
        lda TASK_CUR
        sta EVENT_WAITER
        ; forge la resume frame [Y][X][A][P][PCL][PCH][PBR] → kew_resume
        lda #$01
        pha                     ; PBR
        lda #>kew_resume
        pha                     ; PCH
        lda #<kew_resume
        pha                     ; PCL
        lda #$30                ; P : mode N M=X=1, I=0
        pha
        lda #$00
        pha                     ; A
        pha                     ; X
        pha                     ; Y
        lda #$00
        sta FORBID_COUNT
        jmp kernel_block_switch
kew_resume:                     ; rti atterrit ici au réveil (frame déroulée)
        lda #$01
        sta FORBID_COUNT
        bra kew_loop            ; re-vérifie (puis rts vers l'appelant)
kew_got:
        cli
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_event_wake — réveille la tâche bloquée sur SYS_GET_NEXT_EVENT (G.2)
; ════════════════════════════════════════════════════════════════════
; Appelé par le handler IRQ après avoir posté les événements (clavier/souris).
; Si une tâche attend (EVENT_WAITER≠0) ET la file est non vide, la passe READY
; et efface EVENT_WAITER. Pas d'éligibilité focus : la file est globale (tous
; les événements vont au MainLoop de l'app). Clobbers A, Y (restaurés par l'IRQ).
.export kernel_event_wake
kernel_event_wake:
        lda EVENT_WAITER
        beq ewake_done                  ; personne n'attend
        lda EVENT_RING_COUNT
        beq ewake_done                  ; file vide → pas de réveil
        lda EVENT_WAITER
        jsr kernel_tcb_ptr              ; SCHED_PTR = &tcb[EVENT_WAITER]
        lda #TASK_STATE_READY
        ldy #TCB_STATE
        sta [SCHED_PTR],Y               ; débloque la tâche
        lda #$00
        sta EVENT_WAITER
ewake_done:
        rts

; ── _evt_tail_offset : X = EVENT_RING_TAIL × 10 (offset octet du slot écrit) ──
; ×10 = ×8 + ×2. Clobbe A. EVT_TMP utilisé.
_evt_tail_offset:
        lda EVENT_RING_TAIL
        asl a                    ; ×2
        sta EVT_TMP
        asl a
        asl a                    ; ×8
        clc
        adc EVT_TMP              ; ×8 + ×2 = ×10
        tax
        rts

; ── _evt_advance_tail : tail = (tail+1) mod 16 ; count++ (déjà non plein) ──
_evt_advance_tail:
        lda EVENT_RING_TAIL
        inc a
        and #(EVENT_ENTRIES - 1) ; wrap 16
        sta EVENT_RING_TAIL
        lda EVENT_RING_COUNT
        inc a
        sta EVENT_RING_COUNT
        rts

; ── _evt_fill_where_when : remplit where_x/y (MOUSE_X/Y) + when (TICK) ──
; X = offset octet du slot (préservé). where en 16-bit, when en 8-bit (low+0).
_evt_fill_where_when:
        rep #$20                 ; A 16-bit (X reste 8-bit)
.a16
        lda MOUSE_X
        sta EVENT_RING + EVT_WHERE_X,x
        lda MOUSE_Y
        sta EVENT_RING + EVT_WHERE_Y,x
        sep #$20
.a8
        lda TICK_COUNTER         ; when : tick courant (8-bit, high=0 v1)
        sta EVENT_RING + EVT_WHEN,x
        lda #$00
        sta EVENT_RING + EVT_WHEN + 1,x
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_event_push_key — A = keycode ASCII → poste un EV_KEY_DOWN
; ════════════════════════════════════════════════════════════════════
; message = keycode, mods = KBD2_MOD, where = souris courante, when = tick.
; Drop silencieux si file pleine. Clobbe A, X. Préserve Y.
.export kernel_event_push_key
kernel_event_push_key:
        pha                      ; sauve keycode
        lda EVENT_RING_COUNT
        cmp #EVENT_ENTRIES
        bcc ekpk_ok
        pla                      ; pleine → drop
        rts
ekpk_ok:
        jsr _evt_tail_offset     ; X = offset du slot
        lda #EV_KEY_DOWN
        sta EVENT_RING + EVT_WHAT,x
        pla                      ; keycode
        sta EVENT_RING + EVT_MSG_LO,x
        lda #$00
        sta EVENT_RING + EVT_MSG_HI,x
        lda KBD2_MOD
        sta EVENT_RING + EVT_MODS,x
        jsr _evt_fill_where_when
        jmp _evt_advance_tail

; ════════════════════════════════════════════════════════════════════
;  kernel_event_push_mouse — A = type (EV_MOUSE_DOWN/UP/MOVED)
; ════════════════════════════════════════════════════════════════════
; message = 0, mods = MOUSE_BTN, where = souris courante, when = tick.
; Drop silencieux si file pleine. Clobbe A, X. Préserve Y.
.export kernel_event_push_mouse
kernel_event_push_mouse:
        pha                      ; sauve type
        lda EVENT_RING_COUNT
        cmp #EVENT_ENTRIES
        bcc ekpm_ok
        pla                      ; pleine → drop
        rts
ekpm_ok:
        jsr _evt_tail_offset     ; X = offset du slot
        pla                      ; type
        sta EVENT_RING + EVT_WHAT,x
        lda #$00
        sta EVENT_RING + EVT_MSG_LO,x
        sta EVENT_RING + EVT_MSG_HI,x
        lda MOUSE_BTN
        sta EVENT_RING + EVT_MODS,x
        jsr _evt_fill_where_when
        jmp _evt_advance_tail

; ════════════════════════════════════════════════════════════════════
;  kernel_event_pop — extrait le prochain record dans EVT_OUT (ZP), ou EV_NULL
; ════════════════════════════════════════════════════════════════════
; Sortie : copie le record en tête vers le bloc de 10 octets pointé par
; EVT_OUT_PTR... v1 simplifié : A = what du record extrait (EV_NULL si vide) ;
; le record complet est copié au début du bloc ZP kernel $D0 (réutilisé comme
; sortie syscall en G.2). Consommé hors-IRQ → SEI court contre le producteur.
; Clobbe A, X. Préserve Y. (Sera la base de SYS_MAIN_LOOP/EVENT_AVAIL en G.2.)
.export kernel_event_pop
kernel_event_pop:
        lda EVENT_RING_COUNT
        bne epop_have
        lda #EV_NULL             ; file vide
        rts
epop_have:
        php
        sei                      ; section critique vs IRQ producteur
        ; offset octet = head × 10
        lda EVENT_RING_HEAD
        asl a
        sta EVT_TMP
        asl a
        asl a
        clc
        adc EVT_TMP
        tax                      ; X = offset du slot tête
        ; copie 10 octets EVENT_RING[X..X+9] → bloc ZP $D0..$D9
        ldy #$00
epop_copy:
        lda EVENT_RING,x
        sta $D0,y
        inx
        iny
        cpy #EVENT_SIZE
        bcc epop_copy
        ; head = (head+1) mod 16 ; count--
        lda EVENT_RING_HEAD
        inc a
        and #(EVENT_ENTRIES - 1)
        sta EVENT_RING_HEAD
        lda EVENT_RING_COUNT
        dec a
        sta EVENT_RING_COUNT
        plp
        lda $D0                  ; A = what du record extrait
        rts
