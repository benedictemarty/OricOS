; ============================================================
; hello.s — première app standalone OricOS
; ============================================================
;
; Démontre le pipeline de build apps externes :
;   - Source asm 65C816 mode N.
;   - Linker ld65 → binaire flat chargeable à $BANK:0200.
;   - Tool oricos-bundle.py wrap → format .oosobj OricOS.
;   - Kernel `kernel_app_exec` valide + load + exec.
;
; L'app fait un syscall SYS_PRINT_CHAR ($01) avec X='Z' puis return.
; Code position-independent (lda/ldx/cop/rtl, pas de ref absolue).
;
; Pré-cond entry : mode N M=1 X=1 (préservé du kernel via JSL),
;                  PB=$BANK_APP, DBR=0.
; ============================================================

        .setcpu "65816"
        .smart  +

        .segment "CODE"

.export _start
_start:
        ldx #'Z'                ; arg : char à imprimer
        lda #$01                ; A = syscall num : SYS_PRINT_CHAR
        cop #$AA                ; signature OricOS magic
        rtl                     ; return long → kernel_app_exec
