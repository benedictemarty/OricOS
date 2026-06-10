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
; Pré-cond push (RÉVISÉE 2026-06-10, ADR-32 §10.12) : la section critique
; [test COUNT → _evt_tail_offset (EVT_TMP) → écriture record →
; _evt_advance_tail (RMW TAIL/COUNT)] doit s'exécuter avec I=1.
;   - Pushers IRQ-only (push_key/mouse/timer) : I=1 par contexte (pas de
;     nesting IRQ) — pas de garde supplémentaire.
;   - Pushers TÂCHE-callable (push_menu — hit menu dyn ADR-30 ; push_verbatim
;     — task_wm ADR-28) : php/sei … plp obligatoire (sinon un pusher IRQ
;     s'insère : EVT_TMP clobbé + deux records au même slot, count faux).
;   - TOUT NOUVEAU pusher appelable hors IRQ suit la même règle. Invariant
;     gardé mécaniquement : test_oricos_evt_push_atomic (Phosphoric, dans
;     make tests) rougit si _evt_advance_tail est atteint avec I=0.
; La ZP basse ($00-$88) est disjointe de la ZP app llvm-mos ($89-$CF) →
; l'IRQ ne corrompt pas l'app courante.
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
        sta TEXT_FOCUS_ID        ; SP-3.o S.4b : aucun champ texte focalisé
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
        ; forge la resume frame 16-bit [Y16][X16][A16][P][PCL][PCH][PBR] (ADR-32 §10.9) → kew_resume
        lda #$01
        pha                     ; PBR
        lda #>kew_resume
        pha                     ; PCH
        lda #<kew_resume
        pha                     ; PCL
        lda #$30                ; P : mode N M=X=1, I=0
        pha
        rep #$30                ; ADR-32 §10.9 : frame 16-bit (A/X/Y x 2 octets)
        lda #$0000
        pha                     ; A (16-bit)
        pha                     ; X
        pha                     ; Y
        sep #$30
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
; [TEST-INFRA] Exposé pour test_oricos_evt_push_atomic (ADR-32 §10.12) :
; le test vérifie l'invariant « jamais atteint avec I=0 » (tous les pushers
; de nouveaux slots passent ici — point d'ancrage de la section critique).
.export _evt_advance_tail
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
        ; ADR-28 Étape 2 : si serveur WM actif → route vers RAW_RING (tail-call).
        ; Le serveur (task_wm_entry) repousse en EVENT_RING (passe-plat transparent).
        tax                      ; X = keycode (préservé pendant le test)
        lda TC_WM_FLAG
        cmp #$A5
        bne kepk_legacy
        txa
        jmp kernel_raw_push_key
kepk_legacy:
        txa                      ; A = keycode
        pha                      ; sauve keycode
        ; ADR-28 §6.7 : réserver 2 slots pour les transitions EV_MOUSE_DOWN/UP
        ; (déclencheur du gel scroll si droppées). Limite keys à ENTRIES-2.
        lda EVENT_RING_COUNT
        cmp #(EVENT_ENTRIES - 2)
        bcc ekpk_ok
        pla                      ; pleine (>=14) → drop key, préserver place transitions
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
        ; ADR-28 Étape 2 : si serveur WM actif → route vers RAW_RING (tail-call).
        tax                      ; X = type
        lda TC_WM_FLAG
        cmp #$A5
        bne kepm_legacy
        txa
        jmp kernel_raw_push_mouse
kepm_legacy:
        txa                      ; A = type
        pha                      ; sauve type
        ; ── Coalescing MOUSE_MOVED : si le dernier event en file est déjà un
        ;    MOVED, on met à jour sa position EN PLACE au lieu d'en empiler un.
        ;    Sinon un drag long inonde le ring (16) de moves → le button-UP
        ;    suivant serait droppé → SCROLL_DRAG_ID resterait armé → le WM reste
        ;    bloqué en mode drag et n'accepte plus aucun clic. ──
        cmp #EV_MOUSE_MOVED
        bne ekpm_enqueue
        lda EVENT_RING_COUNT
        beq ekpm_enqueue         ; file vide → rien à coalescer
        lda EVENT_RING_TAIL      ; offset du dernier event = (TAIL-1)&15 ×10
        dec a
        and #(EVENT_ENTRIES - 1)
        asl a                    ; ×2
        sta EVT_TMP
        asl a
        asl a                    ; ×8
        clc
        adc EVT_TMP              ; ×10
        tax
        lda EVENT_RING + EVT_WHAT,x
        cmp #EV_MOUSE_MOVED
        bne ekpm_enqueue         ; dernier ≠ MOVED → enqueue normal
        pla                      ; coalesce : jette le type (slot reste MOVED)
        lda MOUSE_BTN
        sta EVENT_RING + EVT_MODS,x
        jmp _evt_fill_where_when ; maj WHERE/WHEN à X (puis rts)
ekpm_enqueue:
        ; ADR-28 §6.7 : MOVED limité à ENTRIES-2 ; DOWN/UP autorisés jusqu'à
        ; ENTRIES (réserver 2 slots aux transitions de bouton).
        pla                      ; type
        pha                      ; remettre sur pile
        cmp #EV_MOUSE_MOVED
        bne ekpm_check_trans
        lda EVENT_RING_COUNT
        cmp #(EVENT_ENTRIES - 2)
        bcc ekpm_ok
        pla                      ; MOVED + ring saturé (>=14) → drop
        rts
ekpm_check_trans:                ; DOWN/UP : limite normale ENTRIES
        lda EVENT_RING_COUNT
        cmp #EVENT_ENTRIES
        bcc ekpm_ok
        pla                      ; vraiment plein → drop (rare)
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
;  ADR-30 Étape 2b : kernel_event_push_menu — poste EV_MENU_CLICK
; ════════════════════════════════════════════════════════════════════
; Entrée : A = menu_id (4 bits high) | item_id (4 bits low). Drop si plein.
; Payload : MSG_LO = item_id, MSG_HI = menu_id. mods = MOUSE_BTN, where=souris.
; Clobbe A, X. Préserve Y.
; ════════════════════════════════════════════════════════════════════
;  Pattern GEOS InitProcesses : kernel_event_push_timer — poste EV_TIMER
; ════════════════════════════════════════════════════════════════════
; Entrée : A = timer_id. Drop si plein. Payload MSG_LO = timer_id.
; Clobbe A, X. Préserve Y.
.export kernel_event_push_timer
kernel_event_push_timer:
        pha
        lda EVENT_RING_COUNT
        cmp #EVENT_ENTRIES
        bcc keptm_ok
        pla
        rts
keptm_ok:
        jsr _evt_tail_offset
        lda #EV_TIMER
        sta EVENT_RING + EVT_WHAT,x
        pla
        sta EVENT_RING + EVT_MSG_LO,x
        lda #$00
        sta EVENT_RING + EVT_MSG_HI,x
        sta EVENT_RING + EVT_MODS,x
        jsr _evt_fill_where_when
        jmp _evt_advance_tail

.export kernel_event_push_menu
kernel_event_push_menu:
        ; ADR-32 §10.12 : appelé depuis le hit-test menu en contexte TÂCHE
        ; (main loop classify, I=0) — même section critique que push_verbatim.
        php
        sei
        pha                      ; sauve packed id
        lda EVENT_RING_COUNT
        cmp #EVENT_ENTRIES
        bcc kepmen_ok
        pla                      ; plein → drop
        plp
        rts
kepmen_ok:
        jsr _evt_tail_offset     ; X = offset slot
        lda #EV_MENU_CLICK
        sta EVENT_RING + EVT_WHAT,x
        pla                      ; packed id
        pha
        and #$0F                 ; item_id low nibble
        sta EVENT_RING + EVT_MSG_LO,x
        pla                      ; packed id
        lsr a
        lsr a
        lsr a
        lsr a                    ; menu_id high nibble → low
        sta EVENT_RING + EVT_MSG_HI,x
        lda MOUSE_BTN
        sta EVENT_RING + EVT_MODS,x
        jsr _evt_fill_where_when
        jsr _evt_advance_tail
        plp
        rts

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

; ════════════════════════════════════════════════════════════════════
;  ADR-28 Étape 0 — RAW input ring (scaffolding, NON câblé)
; ════════════════════════════════════════════════════════════════════
; File brute pour la future tâche serveur WM (ADR-28 §7). Mêmes géométrie et
; convention que EVENT_RING (record 10 o, bloc ZP $D0..$D9), mais transport
; VERBATIM : pas de where/when/coalescing (le serveur, pas l'IRQ, fera la
; politique). raw_wait/raw_wake (block/wake) viendront en Étape 2 (testables
; seulement avec la tâche serveur). Ici : init + push + pop, testés en isolation.

; ── kernel_raw_init — vide la file (head=tail=count=waiter=0) ──
.export kernel_raw_init
kernel_raw_init:
        lda #$00
        sta RAW_RING_HEAD
        sta RAW_RING_TAIL
        sta RAW_RING_COUNT
        sta RAW_WAITER
        rts

; ── kernel_raw_push — copie le record ZP $D0..$D9 en queue de RAW_RING ──
; Drop silencieux si pleine. Clobbe A, X, Y. Convention identique au futur
; producteur IRQ (qui remplira $D0..$D9 avant d'appeler).
.export kernel_raw_push
kernel_raw_push:
        lda RAW_RING_COUNT
        cmp #EVENT_ENTRIES
        bcc krp_ok
        rts                      ; pleine → drop
krp_ok:
        ; offset octet = tail × 10
        lda RAW_RING_TAIL
        asl a                    ; ×2
        sta EVT_TMP
        asl a
        asl a                    ; ×8
        clc
        adc EVT_TMP              ; ×10
        tax                      ; X = offset du slot écrit
        ldy #$00
krp_copy:
        lda $D0,y
        sta RAW_RING,x
        inx
        iny
        cpy #EVENT_SIZE
        bcc krp_copy
        ; tail = (tail+1) mod 16 ; count++
        lda RAW_RING_TAIL
        inc a
        and #(EVENT_ENTRIES - 1)
        sta RAW_RING_TAIL
        lda RAW_RING_COUNT
        inc a
        sta RAW_RING_COUNT
        rts

; ── ADR-28 Étape 2 : helpers + pushers RAW (clones fidèles de event_push_*) ──
; Helper interne : remplit where_x/y (MOUSE_X/Y) + when (TICK) dans RAW_RING[X..X+9].
; X = offset octet (préservé). Format identique à _evt_fill_where_when.
_raw_fill_ww:
        rep #$20
.a16
        lda MOUSE_X
        sta RAW_RING + EVT_WHERE_X,x
        lda MOUSE_Y
        sta RAW_RING + EVT_WHERE_Y,x
        sep #$20
.a8
        lda TICK_COUNTER
        sta RAW_RING + EVT_WHEN,x
        lda #$00
        sta RAW_RING + EVT_WHEN + 1,x
        rts

; ── kernel_raw_push_mouse — A = type → poste un event souris dans RAW_RING ──
; Clone fidèle de kernel_event_push_mouse (coalescing MOVED inclus) écrivant
; dans RAW_RING. Appelé par kernel_event_push_mouse via tail-call si serveur WM
; actif (TC_WM_FLAG=$A5). Drop silencieux si plein. Clobbe A, X. Préserve Y.
.export kernel_raw_push_mouse
kernel_raw_push_mouse:
        pha                      ; sauve type sur stack
        ; Fix B (BUG_drag_v2_fragments) : en WM_TASKMODE=$A5, désactive le
        ; coalescing MOVED. Préserve chaque event individuel → delta event
        ; petit (≤ MOU2 IRQ rate) → wm_step_do_drag erase OLD rect couvre le
        ; déplacement, plus de fragments. Risque : RAW_RING (16 slots) overflow
        ; sous burst mouse — acceptable v1 (drop = pas de regression visible,
        ; mouse_step lit l'event poppé event-source). EVENT_RING côté app
        ; conserve son coalescing dans kernel_event_push_mouse.
        lda WM_TASKMODE          ; clobbe A (sauvegardé sur stack)
        cmp #$A5
        beq krpm_enqueue         ; taskmode : tjs enqueue (pas de coalesce)
        pla                      ; restore type pour le test MOVED
        pha                      ; re-sauve pour la suite (modèle original)
        ; Coalescing MOUSE_MOVED (cf. kernel_event_push_mouse).
        cmp #EV_MOUSE_MOVED
        bne krpm_enqueue
        lda RAW_RING_COUNT
        beq krpm_enqueue
        lda RAW_RING_TAIL
        dec a
        and #(EVENT_ENTRIES - 1)
        asl a
        sta EVT_TMP
        asl a
        asl a
        clc
        adc EVT_TMP
        tax
        lda RAW_RING + EVT_WHAT,x
        cmp #EV_MOUSE_MOVED
        bne krpm_enqueue
        pla                      ; coalesce : jette le type
        lda MOUSE_BTN
        sta RAW_RING + EVT_MODS,x
        jsr _raw_fill_ww
        jmp krpm_done
krpm_enqueue:
        lda RAW_RING_COUNT
        cmp #EVENT_ENTRIES
        bcc krpm_ok
        pla
        rts                      ; plein → drop
krpm_ok:
        lda RAW_RING_TAIL
        asl a
        sta EVT_TMP
        asl a
        asl a
        clc
        adc EVT_TMP
        tax                      ; X = offset slot
        pla                      ; type
        sta RAW_RING + EVT_WHAT,x
        lda #$00
        sta RAW_RING + EVT_MSG_LO,x
        sta RAW_RING + EVT_MSG_HI,x
        lda MOUSE_BTN
        sta RAW_RING + EVT_MODS,x
        jsr _raw_fill_ww
        ; advance tail + count
        lda RAW_RING_TAIL
        inc a
        and #(EVENT_ENTRIES - 1)
        sta RAW_RING_TAIL
        lda RAW_RING_COUNT
        inc a
        sta RAW_RING_COUNT
krpm_done:
        jmp kernel_raw_wake      ; tail-call : réveille task_wm si elle attend

; ── kernel_raw_push_key — A = keycode → poste un EV_KEY_DOWN dans RAW_RING ──
; Clone fidèle de kernel_event_push_key. Clobbe A, X. Préserve Y.
.export kernel_raw_push_key
kernel_raw_push_key:
        pha
        lda RAW_RING_COUNT
        cmp #EVENT_ENTRIES
        bcc krpk_ok
        pla
        rts                      ; plein → drop
krpk_ok:
        lda RAW_RING_TAIL
        asl a
        sta EVT_TMP
        asl a
        asl a
        clc
        adc EVT_TMP
        tax
        lda #EV_KEY_DOWN
        sta RAW_RING + EVT_WHAT,x
        pla                      ; keycode
        sta RAW_RING + EVT_MSG_LO,x
        lda #$00
        sta RAW_RING + EVT_MSG_HI,x
        lda KBD2_MOD
        sta RAW_RING + EVT_MODS,x
        jsr _raw_fill_ww
        lda RAW_RING_TAIL
        inc a
        and #(EVENT_ENTRIES - 1)
        sta RAW_RING_TAIL
        lda RAW_RING_COUNT
        inc a
        sta RAW_RING_COUNT
        jmp kernel_raw_wake      ; tail-call : réveille task_wm si elle attend

; ── kernel_raw_wait — bloque la tâche courante jusqu'à un raw event (Étape 2) ──
; Clone de kernel_event_wait, opère sur RAW_RING_COUNT/RAW_WAITER. Destiné à la
; tâche serveur WM (task_wm_entry) qui consomme RAW. Mode boot-context : spin+WAI.
.export kernel_raw_wait
kernel_raw_wait:
        lda SCHED_ACTIVE
        cmp #$A5
        beq krw_block_mode
krw_spin:
        lda RAW_RING_COUNT
        bne krw_ret
        wai
        bra krw_spin
krw_ret:
        rts
krw_block_mode:
krw_loop:
        sei
        lda RAW_RING_COUNT
        bne krw_got
        lda TASK_CUR
        sta RAW_WAITER
        ; forge la resume frame 16-bit [Y16][X16][A16][P][PCL][PCH][PBR] (ADR-32 §10.9) → krw_resume
        lda #$01
        pha                      ; PBR
        lda #>krw_resume
        pha                      ; PCH
        lda #<krw_resume
        pha                      ; PCL
        lda #$30                 ; P : mode N M=X=1, I=0
        pha
        rep #$30                 ; ADR-32 §10.9 : frame 16-bit (A/X/Y x 2 octets)
        lda #$0000
        pha                      ; A (16-bit)
        pha                      ; X
        pha                      ; Y
        sep #$30
        lda #$00
        sta FORBID_COUNT
        jmp kernel_block_switch
krw_resume:                      ; rti atterrit ici au réveil
        lda #$01
        sta FORBID_COUNT
        bra krw_loop
krw_got:
        cli
        rts

; ── kernel_raw_wake — réveille la tâche bloquée sur RAW (depuis l'IRQ, Étape 2) ──
; Symétrique de kernel_event_wake. Clobbe A, Y (restaurés par le handler IRQ).
;
; BUG §10 (NON RÉSOLU au 2026-06-01) : task_wm starve avec --ctl-demo
; --wm-taskmode. RAW_WAITER=0 + STATE=BLOCKED observé. Causes RÉFUTÉES :
; lost-wakeup (B)→(C) [sei tenu, pas d'IRQ possible], préemption T1 dans
; block_switch [sous sei], coalescing qui saute raw_wake [jmp krpm_done
; → raw_wake OK], corruption SCHED_PTR [save/restore en place, sans effet].
; Piste ouverte : autre écrivain de tcb[8].STATE (do_switch handlers.s:283
; écrit READY inconditionnel). À INSTRUMENTER (watchpoint tcb8.STATE,
; côté Phosphoric memory_write24). Réf : BUG_task_wm_starve(1).md §2/§3.
.export kernel_raw_wake
kernel_raw_wake:
        lda RAW_WAITER
        beq rwake_done
        lda RAW_RING_COUNT
        beq rwake_done
        ; Save/restore SCHED_PTR conservé par défense en profondeur (cf. note
        ; ci-dessus) — n'est pas la cause racine mais ne nuit pas.
        lda SCHED_PTR
        pha
        lda SCHED_PTR+1
        pha
        lda SCHED_PTR+2
        pha
        lda RAW_WAITER
        jsr kernel_tcb_ptr
        lda #TASK_STATE_READY
        ldy #TCB_STATE
        sta [SCHED_PTR],Y
        pla
        sta SCHED_PTR+2
        pla
        sta SCHED_PTR+1
        pla
        sta SCHED_PTR
        lda #$00
        sta RAW_WAITER
rwake_done:
        rts

; ── kernel_event_push_verbatim — copie $D0..$D9 → EVENT_RING (Étape 2, serveur WM) ──
; Le serveur WM repousse en EVENT_RING le record RAW qu'il vient de pop ($D0..$D9).
; Drop silencieux si EVENT_RING plein. Pas de coalescing (serveur peut le gérer en amont).
.export kernel_event_push_verbatim
kernel_event_push_verbatim:
        ; ADR-32 §10.12 : appelé depuis task_wm (TÂCHE, I=0) — section
        ; critique vs pushers IRQ (T1 timer, KBD2, MOU2) : COUNT/TAIL/slot
        ; RMW + EVT_TMP partagés. php/sei couvre [test COUNT → advance_tail].
        php
        sei
        lda EVENT_RING_COUNT
        cmp #EVENT_ENTRIES
        bcc kepv_ok
        plp
        rts                      ; plein → drop
kepv_ok:
        jsr _evt_tail_offset     ; X = offset du slot écrit
        ldy #$00
kepv_copy:
        lda $D0,y
        sta EVENT_RING,x
        inx
        iny
        cpy #EVENT_SIZE
        bcc kepv_copy
        jsr _evt_advance_tail
        plp
        rts

; ── kernel_raw_pop — extrait le record de tête vers $D0..$D9 ──
; Sortie A = octet 0 du record ($D0), ou EV_NULL si file vide. Clobbe A, X, Y.
; SEI court contre le futur producteur IRQ (comme kernel_event_pop).
.export kernel_raw_pop
kernel_raw_pop:
        lda RAW_RING_COUNT
        bne krpop_have
        lda #EV_NULL             ; file vide
        rts
krpop_have:
        php
        sei
        ; offset octet = head × 10
        lda RAW_RING_HEAD
        asl a
        sta EVT_TMP
        asl a
        asl a
        clc
        adc EVT_TMP
        tax                      ; X = offset du slot tête
        ldy #$00
krpop_copy:
        lda RAW_RING,x
        sta $D0,y
        inx
        iny
        cpy #EVENT_SIZE
        bcc krpop_copy
        ; head = (head+1) mod 16 ; count--
        lda RAW_RING_HEAD
        inc a
        and #(EVENT_ENTRIES - 1)
        sta RAW_RING_HEAD
        lda RAW_RING_COUNT
        dec a
        sta RAW_RING_COUNT
        plp
        lda $D0                  ; A = octet 0 du record extrait
        rts

; ════════════════════════════════════════════════════════════════════
;  task_wm_entry — serveur WM passe-plat RAW→EVENT_RING (ADR-28 Étape 2)
; ════════════════════════════════════════════════════════════════════
; Tâche kernel résidente créée par boot si TC_WM_FLAG=$A5. Boucle simple :
;   raw_wait (bloque)  →  raw_pop ($D0..$D9)  →  event_push_verbatim  →
;   event_wake (réveille l'app si elle attend EVENT_RING)  →  boucle.
; À ce stade, le comportement net pour l'app est **identique** au câblage IRQ
; direct (passe-plat) — valide la chaîne IRQ→RAW→serveur→EVENT_RING + le block/
; wake de la tâche AVANT de migrer la politique (Étape 3). L'IRQ qui pousse
; dans RAW (au lieu de EVENT_RING) est conditionné par TC_WM_FLAG (handlers.s).
.export task_wm_entry
task_wm_entry:
        jsr kernel_raw_wait              ; bloque jusqu'à un record dispo
        jsr kernel_raw_pop               ; $D0..$D9 = record (A = what)
        ; BUG_drag_glitch_taskmode (2026-06-02) : en taskmode, mouse_step
        ; ne doit JAMAIS lire le device MOUSE_DX/DY/BTN read-clear (déjà
        ; désynchronisé par les IRQ intermédiaires). On copie l'état event
        ; → MOUSE_* AVANT l'appel. Tout le code downstream (resize_hit,
        ; do_drag, point_in_rect16, etc.) lit MOUSE_* → voit
        ; automatiquement l'état cohérent avec l'event poppé.
        lda WM_TASKMODE
        cmp #$A5
        bne _twe_skip_install
        jsr task_wm_install_event_state
_twe_skip_install:
        ; ADR-32 §3 : si WM_TASKMODE=$A5, task_wm est le SEUL appelant de
        ; mouse_step (l'IRQ a sauté son appel — atomicité). Default $00 →
        ; pas d'appel ici, comportement legacy (mouse_step en IRQ).
        ; Pré-requis pour activer ($A5) : Étape 4 ADR-32 (migration curseur)
        ; non encore livrée → ne PAS flipper le défaut.
        lda WM_TASKMODE
        cmp #$A5
        bne task_wm_skip_mstep
        jsr kernel_wm_mouse_step
task_wm_skip_mstep:
        jsr kernel_event_push_verbatim   ; → EVENT_RING (drop si plein, OK v1)
        jsr kernel_event_wake            ; réveille l'app si elle attend
        bra task_wm_entry

; ════════════════════════════════════════════════════════════════════
;  task_wm_install_event_state — copie event ($D0..$D9) → MOUSE_* (taskmode)
; ════════════════════════════════════════════════════════════════════
; BUG_drag_glitch_taskmode (2026-06-02) — fix Option A.
; Pré-cond : record RAW dans $D0..$D9 (juste après raw_pop). WM_TASKMODE=$A5.
;
; Copie event → MOUSE_BTN/PREV_BTN/X/Y, dérive DX/DY = WHERE - WM_LAST.
; mouse_step et toute sa chaîne (resize_hit, _wm_do_drag, point_in_rect16…)
; lisent MOUSE_* et voient automatiquement l'état EVENT (pas device read-clear).
;
; Premier event (WM_LAST_INIT != $A5) : DX/DY=0 (pas d'apply), init WM_LAST.
; Suivants : DX/DY = WHERE - WM_LAST (low byte, sat8 implicite via truncation).
; TODO v2 : sat8 propre (clamp [-128..127]) si deltas > 127 deviennent réels.
;
; Clobbe : A. Préserve X, Y. Mode runtime non garanti → force M=8 X=8 + restore.

; ── _install_sat8 : sature A 16-bit signé vers [-128, +127] dans low byte. ──
; Pré : M=16. Sortie : A 16-bit, low byte = sat8(input), high byte non garanti.
; Préserve X, Y. Modifie seulement A et flags. Coût : 4-8 cycles selon branche.
_install_sat8:
        .a16
        bmi _is8_neg
        cmp #$0080
        bcc _is8_done            ; A < 128 → in range, garde low byte
        lda #$007F               ; A >= 128 → clamp à +127
        rts
_is8_neg:
        cmp #$FF80
        bcs _is8_done            ; A >= $FF80 (= -128 signed) → in range
        lda #$0080               ; A < -128 → clamp à -128 ($80 low)
_is8_done:
        rts

task_wm_install_event_state:
        ; v2 (TICK_COUNTER pushed $5420 → CODE budget OK) : full event state
        ; install. Position + delta dérivé + bouton avec edge-detect via WM_LAST_*.
        php
        ; ── Bouton : PREV ← WM_LAST_BTN ; BTN ← EVT_MODS ; update LAST ──
        sep #$20
        .a8
        lda f:WM_LAST_BTN
        sta f:MOUSE_PREV_BTN
        lda $D3                          ; EVT_MODS = bouton de l'event
        sta f:MOUSE_BTN
        sta f:WM_LAST_BTN
        ; ── Position (16-bit) + delta 16-bit complet (Fix A) + sat8 propre ──
        ; MOUSE_DX16/DY16 : 16-bit signé complet → consommé par _wm_do_drag/
        ; _wm_do_resize (corrige bug saut > 127 px qui inversait le signe).
        ; MOUSE_DX/DY : sat8 PROPRE clamp [-128, +127] (et non plus troncature
        ; trompeuse « sat8 implicite ») → reflète correctement « delta non nul ? »
        ; pour les consommateurs IRQ legacy 8-bit (skip-zero test wm_step_do_drag).
        ; §5ter : sans sat8, delta = +256 → low byte 0 → faux skip.
        rep #$20
        .a16
        lda $D4                          ; WHERE_X
        sta f:MOUSE_X
        sec
        sbc f:WM_LAST_X                  ; A = delta X 16-bit signé complet
        sta f:MOUSE_DX16
        jsr _install_sat8                ; A (16-bit) → A (8-bit dans low) sat8
        sep #$20
        .a8
        sta f:MOUSE_DX                   ; sat8 propre (non plus truncation)
        rep #$20
        .a16
        lda $D4
        sta f:WM_LAST_X
        lda $D6                          ; WHERE_Y
        sta f:MOUSE_Y
        sec
        sbc f:WM_LAST_Y
        sta f:MOUSE_DY16
        jsr _install_sat8
        sep #$20
        .a8
        sta f:MOUSE_DY
        rep #$20
        .a16
        lda $D6
        sta f:WM_LAST_Y
        sep #$20
        .a8
        plp
        rts
