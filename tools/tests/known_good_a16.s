; Known-good fixture : même pattern que known_bad_rep30, MAIS le label
; ouvre avec `.a16` explicite. audit-smart NE doit PAS le signaler.

        .setcpu "65816"
        .smart  +
        .segment "CODE"

start:
        rep #$30
        lda #$1234
        cmp #$5678
        bcc good_label
        sep #$30
        bra exit

good_label:
        .a16                    ; ← convention CLAUDE.md, fix du pattern
        lda #$ABCD              ; correctement encodé 3 bytes
        rts

exit:
        sep #$30
        rts
