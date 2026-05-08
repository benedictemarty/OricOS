; ============================================================
; OricOS — Kernel core (Sprint 1.a)
; ============================================================
; Auteur : bmarty (benedicte) <bmarty@mailo.com>
; Date   : 2026-05-08
;
; Sprint 0 → 1.a :
;   - Sentinels boot conservés ("ORIOS\x00" + "v0.1\x00").
;   - Ajout : kernel_nmi_handler en bank 1 $5500.
;   - Boot active CLI ; polling loop sur tick counter ($015400).
;   - STP quand counter atteint 5 (5 NMI injectés par le test).
;
; Le test côté Phosphoric installe :
;   - Trampoline bank 0 $0130  : JML $015500 (vers le NMI handler).
;   - Vecteur NMI mode N $00FFEA → $0130.
;
; Convention : ca65 syntaxe WDC, --cpu 65816.
; ============================================================

        .setcpu "65816"
        .smart  +

; ─── Constantes ─────────────────────────────────────────────────────
TICK_COUNTER    = $015400       ; bank 1 $5400 — incrémenté par NMI
SENTINEL_BASE   = $015000       ; bank 1 $5000 — "ORIOS\x00"
VERSION_BASE    = $015010       ; bank 1 $5010 — "v0.1\x00"
TICK_GOAL       = $05           ; STP après 5 ticks

; ════════════════════════════════════════════════════════════════════
;  CODE — boot + main loop
; ════════════════════════════════════════════════════════════════════
        .segment "CODE"

.export kernel_entry
kernel_entry:
        ; ── Force mode N M=X=1 ─────────────────────────────────────
        sec
        xce                     ; → mode E (force M=X=1, S=$01..)
        clc
        xce                     ; → mode N (M=1 et X=1 certifiés en P)

        ; ── D=0, S=$01FF, DBR=0 (préparation kernel) ──────────────
        rep #$20                ; M=0 pour LDA 16-bit
        lda #$0000
        tcd                     ; D = 0
        sep #$20                ; M=1 retour 8-bit
        sep #$30                ; M=1, X=1 (sécurité)
        ldx #$FF
        txs                     ; S = $01FF
        ; DBR : reste à 0 (par défaut au reset). On utilise long
        ; addressing pour les stores cross-bank.

        ; ── Sentinel "ORIOS\x00" à $015000 ─────────────────────────
        lda #'O'
        sta SENTINEL_BASE+0
        lda #'R'
        sta SENTINEL_BASE+1
        lda #'I'
        sta SENTINEL_BASE+2
        lda #'O'
        sta SENTINEL_BASE+3
        lda #'S'
        sta SENTINEL_BASE+4
        lda #$00
        sta SENTINEL_BASE+5

        ; ── Version "v0.2\x00" à $015010 ───────────────────────────
        lda #'v'
        sta VERSION_BASE+0
        lda #'0'
        sta VERSION_BASE+1
        lda #'.'
        sta VERSION_BASE+2
        lda #'2'
        sta VERSION_BASE+3
        lda #$00
        sta VERSION_BASE+4

        ; ── Initialise le tick counter à 0 ─────────────────────────
        lda #$00
        sta TICK_COUNTER

        ; ── Active les interruptions et entre dans la boucle ───────
        cli                     ; clear I → IRQ enabled (NMI sans masque)

main_loop:
        ; Polling minimal — sera remplacé par WAI en Sprint 1.b
        ; quand on aura un IRQ timer.
        lda TICK_COUNTER
        cmp #TICK_GOAL
        bcc main_loop           ; if counter < goal : loop

        ; ── Halt propre ────────────────────────────────────────────
        stp
        bra *

; ─── kernel_panic : appelé sur erreur fatale (Sprint 2+) ────────────
.export kernel_panic
kernel_panic:
        stp
        bra *

; ════════════════════════════════════════════════════════════════════
;  NMI_HANDLER — service NMI en bank 1 $5500
; ════════════════════════════════════════════════════════════════════
;
; Préconditions :
;   - Le hardware a poussé : PB ($00, le bank 0 du trampoline),
;                            PCH:PCL (retour vers le trampoline),
;                            P (avec B=0, NMI ≠ BRK).
;   - I est positionné à 1, D à 0.
;   - On entre ici via JML $015500 depuis le trampoline bank 0.
;
; Fonction : incrémente le tick counter ($015400). Save A localement.
;
; ════════════════════════════════════════════════════════════════════
        .segment "NMI_HANDLER"

.export kernel_nmi_handler
kernel_nmi_handler:
        ; ── Save A (mode N, P inconnu — assume M=1 pour minimum) ───
        sep #$30                ; sécurité : M=X=1
        pha
        ; ── Increment tick counter ─────────────────────────────────
        lda TICK_COUNTER
        inc a                   ; INC A 65C816-only
        sta TICK_COUNTER
        ; ── Restore A et retour ────────────────────────────────────
        pla
        rti

; ════════════════════════════════════════════════════════════════════
;  IRQ_HANDLER — placeholder (Sprint 1.b)
; ════════════════════════════════════════════════════════════════════
        .segment "IRQ_HANDLER"

.export kernel_irq_handler
kernel_irq_handler:
        rti                     ; v0.2 : no-op
