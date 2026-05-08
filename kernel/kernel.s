; ============================================================
; OricOS — Kernel hello world (Sprint 0)
; ============================================================
; Auteur : bmarty (benedicte) <bmarty@mailo.com>
; Date   : 2026-05-08
;
; Démontre le boot OricOS sur Phosphoric --machine oric2 :
;   1. Le CPU démarre en mode E (RESET force E=1, PC=$00FFFC vector).
;   2. Le vecteur RESET pointe sur un stub bank 0 (configuré côté
;      Phosphoric par le test d'intégration ; CLC ; XCE ; JML kernel).
;   3. Le kernel s'exécute en bank 1 mode N. Il :
;      - Configure D, S, DBR pour un fonctionnement propre.
;      - Écrit le sentinel "ORIOS\x00" à $015000 (bank 1, signature
;        ROM système — signe que OricOS a bien booté).
;      - Écrit version et build info à $015010.
;      - STP pour arrêter proprement la simulation.
;
; Note : ce code est un démonstrateur Sprint 0. Le vrai kernel Sprint 1+
; installera les vecteurs, le scheduler et IRQ handler.
;
; Convention asm : ca65 syntaxe WDC, --cpu 65816.
; ============================================================

        .setcpu "65816"
        .feature labels_without_colons
        .smart  +

        .segment "CODE"

; ─── kernel_entry : entry point en bank 1 $0200 ─────────────────────
;
; Préconditions :
;   - PBR = $01, PC = $0200
;   - mode N (E=0). Le stub trampoline en bank 0 a déjà fait CLC ; XCE.
;   - DBR = inconnu, D = inconnu.
; ────────────────────────────────────────────────────────────────────
.export kernel_entry
kernel_entry:
        ; ── Setup state ────────────────────────────────────────────
        ; DBR = 0 par défaut pour les accès "abs" — mais on utilisera
        ; le long addressing pour écrire en bank 1 (depuis bank 1 PBR=1
        ; mais DBR peut être différent).
        sec
        xce                     ; → mode E (force M=X=1, S high=$01)
        clc
        xce                     ; → mode N à nouveau, mais maintenant
                                ; M=1 et X=1 sont *certifiés* dans P.
                                ; (ADR-05 : kernel asm reste 8-bit pour
                                ; cette v0.1.)

        ; D = 0 : direct page en bank 0. Future : D pointe vers la DP
        ; kernel en $01:0000.
        rep #$20                ; M=0 pour LDA 16-bit
        lda #$0000
        tcd                     ; D = 0
        sep #$20                ; M=1 retour 8-bit

        ; S = $01FF : stack en bank 0 page 1 (mode E compatible).
        ; En mode N S est 16-bit. Pour Sprint 0 on reste avec S small
        ; en bank 0 page 1 (compat E).
        sep #$30                ; M=1, X=1 (8-bit)
        ldx #$FF
        txs                     ; S = $01FF

        ; ── Écrit le sentinel "ORIOS\x00" à $015000 ───────────────
        ; Long addressing pour pointer en bank 1.
        lda #'O'
        sta $015000
        lda #'R'
        sta $015001
        lda #'I'
        sta $015002
        lda #'O'
        sta $015003
        lda #'S'
        sta $015004
        lda #$00
        sta $015005

        ; ── Écrit version "v0.1" à $015010 ────────────────────────
        lda #'v'
        sta $015010
        lda #'0'
        sta $015011
        lda #'.'
        sta $015012
        lda #'1'
        sta $015013
        lda #$00
        sta $015014

        ; ── Halt (Sprint 0 : pas de scheduler encore) ─────────────
        stp                     ; Stop : simulation arrêtée proprement

        ; Si on reprend (impossible sans RESET), boucle infinie.
        bra *

; ─── kernel_panic : appelé sur erreur fatale (Sprint 1+) ────────────
.export kernel_panic
kernel_panic:
        ; v0.1 : juste STP. Sprint 1+ : screen panic, dump registres.
        stp
        bra *
