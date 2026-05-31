; Known-bad fixture pour audit-smart.py.
;
; Reproduit le pattern exact qui a échappé au linter buggué (pré-filtre
; "20" in operand qui ignorait `rep #$30`). Avec `rep #$30`, le tracker
; m_state doit passer à 0 (M=16) ; sans cette mise à jour, le linter
; voyait m_at_def=1 (M=8) au label `bad_label:` et donc PAS de suspect.
;
; Le label est :
;   - précédé textuellement par un flow-break (`bra exit`)
;   - atteint via `bcc bad_label` depuis une région M=16
;   - 1re instr = `lda #$1234` (immédiat M-dépendant)
;   - sans `.a16` explicite
; → audit-smart DOIT le signaler.

        .setcpu "65816"
        .smart  +
        .segment "CODE"

; Pattern exact du bug taskbar (`_tbh_advance` 2026-05-30) :
; - `rep #$30` → linéaire M=16
; - `sep #$30` plus loin → linéaire M=8
; - `bra exit` flow-break → .smart perd l'état au label suivant
; - `bad_label:` atteint par `bcc` depuis la région M=16 (avant le sep)
; - 1re instr `lda #$ABCD` immédiat M-dépendant, sans `.a16`.
; Le walk linéaire du tracker doit donner m_at_def=1 (8-bit) au label →
; suspect détecté. Sans le fix #$30, le tracker ne basculait JAMAIS à
; M=16 → le test du sep #$30 plus bas devenait no-op → m_at_def restait
; à 1 par défaut MAIS le caller M=16 lui aussi n'était pas marqué (le
; walk au site du bcc voyait m_state=1) → finding raté.

        .setcpu "65816"
        .smart  +
        .segment "CODE"

start:
        rep #$30                ; passe à M=16 ET X=16
        lda #$1234              ; ok ici (M=16 réel et tracé)
        cmp #$5678
        bcc bad_label           ; branche M=16 vers le label suspect
        sep #$30                ; tracker linéaire → m_state=1
        bra exit                ; flow-break textuel

bad_label:
        lda #$ABCD              ; ⚠️ M=16 réel (depuis bcc), mais .smart
                                ; voit M=8 → encode lda #$CD (2 bytes)
                                ; au lieu de lda #$ABCD (3 bytes) →
                                ; corruption silencieuse
        rts

exit:
        sep #$30
        rts
