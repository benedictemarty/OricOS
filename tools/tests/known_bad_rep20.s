; Known-bad fixture (classique rep #$20) — verrouille le cas que le
; linter détectait DÉJÀ avant le fix, pour éviter une régression où on
; casserait le tracking #$20 en corrigeant #$30.

        .setcpu "65816"
        .smart  +
        .segment "CODE"

; Pattern bug taskbar (`_tbh_advance`), variante `#$20` au lieu de `#$30`.
; Verrouille le cas déjà détecté avant le fix — anti-régression.

start:
        rep #$20                ; M=16
        lda #$1234
        cmp #$5678
        bcc bad_label
        sep #$20                ; M=8 sur tracker linéaire
        bra exit                ; flow-break

bad_label:
        lda #$ABCD              ; même bug latent que known_bad_rep30.s
        rts

exit:
        sep #$20
        rts
