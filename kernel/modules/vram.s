; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : vram.s — inclus depuis kernel.s
;
        .segment "CODE"

; ════════════════════════════════════════════════════════════════════
;  kernel_vram_write_block — RAM banking → VRAM cold (Sprint VRAM-2)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP_PCPTR (24-bit) = source en RAM banking.
;        VRAM_OP_ADDR_LO/MID/HI ($60-$62) = destination SDRAM 24-bit.
;        VRAM_OP_LEN_LO/HI ($63-$64) = nombre d'octets (16-bit, 1..65535
;        ; len=0 → no-op, contrairement au DMA qui interprète 0=64K).
; Effets : copie len octets via I/O port VRAM_DATA (auto-inc côté HW).
; Modifie : A, X, Y, $63 (write 0). Préserve DP_PCPTR.
; Pré-cond : mode N M=1 X=1, DBR=0, vram_device présent.
;
; Latence : ~10 cycles/byte. Pour transferts massifs, kernel_vram_dma
; est ~10× plus rapide (DMA HW v0.1 synchrone "instantané" simulé).
; ════════════════════════════════════════════════════════════════════
.export kernel_vram_write_block
kernel_vram_write_block:
        ; Set VRAM_ADDR via I/O ports (long absolute writes).
        lda VRAM_OP_ADDR_LO
        sta VRAM_ADDR_LO_IO
        lda VRAM_OP_ADDR_MID
        sta VRAM_ADDR_MID_IO
        lda VRAM_OP_ADDR_HI
        sta VRAM_ADDR_HI_IO
        ; Loop : Y 16-bit pour offset.
        rep #$10
        ldy #$0000
vwb_loop:
        cpy VRAM_OP_LEN_LO              ; cpy zp en X=0 lit 16-bit $63-$64
        bcs vwb_done
        lda [DP_PCPTR],Y
        sta VRAM_DATA_IO
        iny
        bra vwb_loop
vwb_done:
        sep #$10
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_vram_read_block — VRAM cold → RAM banking (Sprint VRAM-2)
; ════════════════════════════════════════════════════════════════════
;
; Args : VRAM_OP_ADDR_LO/MID/HI = source SDRAM 24-bit.
;        DP_PCPTR (24-bit) = destination en RAM banking.
;        VRAM_OP_LEN_LO/HI = nombre d'octets.
; Effets : lit len octets via I/O port VRAM_DATA (auto-inc).
; ════════════════════════════════════════════════════════════════════
.export kernel_vram_read_block
kernel_vram_read_block:
        lda VRAM_OP_ADDR_LO
        sta VRAM_ADDR_LO_IO
        lda VRAM_OP_ADDR_MID
        sta VRAM_ADDR_MID_IO
        lda VRAM_OP_ADDR_HI
        sta VRAM_ADDR_HI_IO
        rep #$10
        ldy #$0000
vrb_loop:
        cpy VRAM_OP_LEN_LO
        bcs vrb_done
        lda VRAM_DATA_IO
        sta [DP_PCPTR],Y
        iny
        bra vrb_loop
vrb_done:
        sep #$10
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_vram_dma — DMA HW SDRAM↔bank (Sprint VRAM-2)
; ════════════════════════════════════════════════════════════════════
;
; Args ZP :
;   VRAM_DMA_SRC_LO/MID/HI ($65-$67) = adresse source 24-bit.
;   VRAM_DMA_DST_LO/MID/HI ($68-$6A) = adresse destination 24-bit.
;   VRAM_DMA_LEN_LO/HI     ($6B-$6C) = longueur 16-bit (LEN=0 → 65536).
;   VRAM_DMA_DIR_ZP        ($6D)     = $00 (SDRAM→bank) ou $02 (bank→SDRAM).
; Effets : trigger DMA HW. v0.1 synchrone (instantané), busy=0 immédiat.
; Pré-cond : mode N M=1 X=1, DBR=0.
; ════════════════════════════════════════════════════════════════════
.export kernel_vram_dma
kernel_vram_dma:
        ; Setup DMA registers via I/O ports.
        lda VRAM_DMA_SRC_LO_ZP
        sta VRAM_DMA_SRC_LO_IO
        lda VRAM_DMA_SRC_MID_ZP
        sta VRAM_DMA_SRC_MID_IO
        lda VRAM_DMA_SRC_HI_ZP
        sta VRAM_DMA_SRC_HI_IO
        lda VRAM_DMA_DST_LO_ZP
        sta VRAM_DMA_DST_LO_IO
        lda VRAM_DMA_DST_MID_ZP
        sta VRAM_DMA_DST_MID_IO
        lda VRAM_DMA_DST_HI_ZP
        sta VRAM_DMA_DST_HI_IO
        lda VRAM_DMA_LEN_LO_ZP
        sta VRAM_DMA_LEN_LO_IO
        lda VRAM_DMA_LEN_HI_ZP
        sta VRAM_DMA_LEN_HI_IO
        ; Trigger : DIR | TRIG bit.
        lda VRAM_DMA_DIR_ZP
        ora #VRAM_DMA_TRIG
        sta VRAM_DMA_CTRL_IO
        ; Wait busy clear avec timeout 256 polls (robustesse : si
        ; vram_device absent ou stuck, ne bloque pas indéfiniment).
        ldx #$00
vdma_wait:
        lda VRAM_DMA_CTRL_IO
        and #VRAM_DMA_BUSY
        beq vdma_done
        inx
        bne vdma_wait
vdma_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_gfx_clear — exec GPU CLEAR via I/O (Sprint GPU-3, ADR-21)
; ════════════════════════════════════════════════════════════════════
;
; Args ZP :
;   GFX_BASE_LO/MID/HI ($70-$72) = base SDRAM 24-bit (offset).
;   GFX_ARG2_LO/MID/HI ($73-$75) = size 24-bit (octets).
;   GFX_COLOR ($78)              = couleur (0..15).
; Effets : remplit `size` octets en SDRAM[base] avec pattern
;          (color << 4) | color (= 2 pixels même couleur par byte).
;          v0.1 synchrone : poll busy avec timeout 256.
; Modifie : A, X. Préserve : Y.
; Pré-cond : mode N M=1 X=1, DBR=0, gpu_device présent.
; ════════════════════════════════════════════════════════════════════
