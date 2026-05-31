; Known-good fixture : pas de caller en M=16 → pas de bug même sans .a16.
; Label atteint uniquement par fall-through (pas de branche).

        .setcpu "65816"
        .smart  +
        .segment "CODE"

start:
        rep #$30
        lda #$1234
        sep #$30
        ; fall-through → safe_label visible en M=8 par .smart
safe_label:
        lda #$12                ; immédiat M=8 (1 byte) — OK
        rts
