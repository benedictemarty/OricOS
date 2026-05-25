; SPDX-License-Identifier: EUPL-1.2
; Copyright (c) 2026 Bénédicte Marty
; Module : fat.s — inclus depuis kernel.s
;
        .segment "CODE"

; ════════════════════════════════════════════════════════════════════
;  kernel_fat_init — vérifie signature FAT32 du boot sector (Sprint 2.j.2)
; ════════════════════════════════════════════════════════════════════
;
; Effets : lit bloc 0 (boot sector) dans FS_BUFFER, vérifie signature
;          "FAT32" à offset $52. FS_INIT_RESULT = $00 (OK) ou $01 (BAD).
; Modifie : A, X, Y, FS_BUFFER, FS_INIT_RESULT, $30/$31, DP_PCPTR.
; Pré-cond : SD device présent et image chargée.
; ════════════════════════════════════════════════════════════════════
.export kernel_fat_init
kernel_fat_init:
        ; Lit LBA 0 dans FS_BUFFER
        lda #$00
        sta $30
        sta $31
        lda #<FS_BUFFER
        sta DP_PCPTR
        lda #>FS_BUFFER
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_sd_read_block

        ; Vérifie "FAT32" à FS_BUFFER+$52..+$56
        lda FS_BUFFER + FS_FAT32_SIG + 0
        cmp #'F'
        bne fat_init_bad
        lda FS_BUFFER + FS_FAT32_SIG + 1
        cmp #'A'
        bne fat_init_bad
        lda FS_BUFFER + FS_FAT32_SIG + 2
        cmp #'T'
        bne fat_init_bad
        lda FS_BUFFER + FS_FAT32_SIG + 3
        cmp #'3'
        bne fat_init_bad
        lda FS_BUFFER + FS_FAT32_SIG + 4
        cmp #'2'
        bne fat_init_bad
        ; Sig OK : parse les champs FAT32
        jsr fat_parse_boot_sector
        lda #$00
        sta FS_INIT_RESULT
        rts
fat_init_bad:
        lda #$01
        sta FS_INIT_RESULT
        rts

; ════════════════════════════════════════════════════════════════════
;  fat_parse_boot_sector — parse champs FAT32 + calcule FDS (interne)
; ════════════════════════════════════════════════════════════════════
;
; Pré-cond : FS_BUFFER contient le boot sector valide.
; Effets : remplit FS_BPS, FS_SPC, FS_RSC, FS_NFAT, FS_SPF, FS_ROOT,
;          FS_FDS (= FS_RSC + FS_NFAT * FS_SPF, 16-bit en v0.1).
; Modifie : A, X, Y.
; ════════════════════════════════════════════════════════════════════
fat_parse_boot_sector:
        ; FS_BPS (2B) ← FS_BUFFER + BS_BPS
        lda FS_BUFFER + BS_BPS
        sta FS_BPS
        lda FS_BUFFER + BS_BPS + 1
        sta FS_BPS+1
        ; FS_SPC (1B)
        lda FS_BUFFER + BS_SPC
        sta FS_SPC
        ; FS_RSC (2B)
        lda FS_BUFFER + BS_RSC
        sta FS_RSC
        lda FS_BUFFER + BS_RSC + 1
        sta FS_RSC+1
        ; FS_NFAT (1B)
        lda FS_BUFFER + BS_NFAT
        sta FS_NFAT
        ; FS_SPF (4B)
        lda FS_BUFFER + BS_SPF
        sta FS_SPF
        lda FS_BUFFER + BS_SPF + 1
        sta FS_SPF+1
        lda FS_BUFFER + BS_SPF + 2
        sta FS_SPF+2
        lda FS_BUFFER + BS_SPF + 3
        sta FS_SPF+3
        ; FS_ROOT (4B)
        lda FS_BUFFER + BS_ROOT
        sta FS_ROOT
        lda FS_BUFFER + BS_ROOT + 1
        sta FS_ROOT+1
        lda FS_BUFFER + BS_ROOT + 2
        sta FS_ROOT+2
        lda FS_BUFFER + BS_ROOT + 3
        sta FS_ROOT+3

        ; FS_FDS = FS_RSC + FS_NFAT * FS_SPF (v0.1 16-bit max).
        ; Init FS_FDS = FS_RSC, puis ajouter FS_SPF NFAT fois.
        rep #$20
        lda FS_RSC
        sta FS_FDS
        sep #$20
        lda #$00
        sta FS_FDS+2
        sta FS_FDS+3
        lda FS_NFAT             ; ldx long-abs n'existe pas → via lda+tax
        tax
fds_loop:
        cpx #$00
        beq fds_done
        rep #$20
        lda FS_FDS
        clc
        adc FS_SPF
        sta FS_FDS
        sep #$20
        dex
        bra fds_loop
fds_done:
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_fat_open — recherche un fichier dans le root dir (Sprint 2.j.4)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP+$40..$4A = filename 11B (8.3 padded espaces, uppercase).
; Effets : si trouvé, FS_FOUND_CLUSTER = first_cluster (4B),
;          FS_FOUND_SIZE = size (4B), FS_OPEN_RESULT = $00.
;          Sinon FS_OPEN_RESULT = $01.
; v0.1 : 1 secteur de root dir (16 entries max). FS_ROOT supposé = 2,
;        donc LBA root = FS_FDS. Cluster chain non parcourue (TODO v0.2).
; Modifie : A, X, Y, FS_BUFFER, FS_FOUND_*, $30/$31, DP_PCPTR, $50-$52.
; Pré-cond : kernel_fat_init OK (FS_INIT_RESULT = 0).
; ════════════════════════════════════════════════════════════════════
.export kernel_fat_open
kernel_fat_open:
        ; LBA = FS_FDS (16-bit, suppose root_cluster = 2)
        rep #$20
        lda FS_FDS
        sta $30
        sep #$20
        ; dest = FS_BUFFER
        lda #<FS_BUFFER
        sta DP_PCPTR
        lda #>FS_BUFFER
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_sd_read_block

        ; Init pointer DP_ENTRY = FS_BUFFER (entry 0)
        lda #<FS_BUFFER
        sta DP_ENTRY
        lda #>FS_BUFFER
        sta DP_ENTRY+1
        lda #$01
        sta DP_ENTRY+2

        ldx #$00                        ; entry counter (max 16 = $0200/$20)
fop_loop:
        cpx #16
        bcs fop_not_found

        ; Lire byte 0 de l'entry
        ldy #DE_NAME
        lda [DP_ENTRY],Y
        cmp #$00
        beq fop_not_found               ; $00 = end of dir
        cmp #$E5
        beq fop_next_entry              ; deleted

        ; Skip LFN ($0F)
        ldy #DE_ATTR
        lda [DP_ENTRY],Y
        cmp #DE_ATTR_LFN
        beq fop_next_entry
        ; Skip volume_label / directory
        and #DE_ATTR_DIR_VOL
        bne fop_next_entry

        ; Compare 11 bytes : entry name vs DP_FILENAME
        ldy #$00
fop_cmp:
        lda [DP_ENTRY],Y
        cmp a:DP_FILENAME,Y             ; cmp abs,Y (D9 abs LE) ; force abs
        bne fop_next_entry
        iny
        cpy #11
        bcc fop_cmp

        ; Match ! Lit cluster_low (offset $1A 2B)
        ldy #DE_CLUS_LO
        lda [DP_ENTRY],Y
        sta FS_FOUND_CLUSTER
        iny
        lda [DP_ENTRY],Y
        sta FS_FOUND_CLUSTER+1
        ; cluster_high (offset $14 2B)
        ldy #DE_CLUS_HI
        lda [DP_ENTRY],Y
        sta FS_FOUND_CLUSTER+2
        iny
        lda [DP_ENTRY],Y
        sta FS_FOUND_CLUSTER+3
        ; size (offset $1C 4B)
        ldy #DE_SIZE
        lda [DP_ENTRY],Y
        sta FS_FOUND_SIZE
        iny
        lda [DP_ENTRY],Y
        sta FS_FOUND_SIZE+1
        iny
        lda [DP_ENTRY],Y
        sta FS_FOUND_SIZE+2
        iny
        lda [DP_ENTRY],Y
        sta FS_FOUND_SIZE+3
        lda #$00
        sta FS_OPEN_RESULT
        rts

fop_next_entry:
        ; Avance pointer de 32 bytes
        rep #$20
        lda DP_ENTRY
        clc
        adc #DE_SIZE_BYTES
        sta DP_ENTRY
        sep #$20
        inx
        bra fop_loop

fop_not_found:
        lda #$01
        sta FS_OPEN_RESULT
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_fat_read_cluster — lit 1 cluster vers dest (Sprint 2.j.5)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP_PCPTR (= $0C-$0E) = pointer 24-bit destination (déjà setup).
;        FS_FOUND_CLUSTER = cluster à lire (4B).
; Effets : copie 1 secteur (SPC * BPS = 512 octets en v0.1) vers dest.
; v0.1 : assume SPC=1, FS_FDS et cluster < 65536 (16-bit arithm).
;        Pour cluster chain réelle, voir OS-2.j.5b/v0.2.
; Modifie : A, X, Y, $30/$31, FS_BUFFER (transitoirement).
; Pré-cond : kernel_fat_open a renseigné FS_FOUND_CLUSTER.
; ════════════════════════════════════════════════════════════════════
.export kernel_fat_read_cluster
kernel_fat_read_cluster:
        ; LBA = FS_FDS + (FS_FOUND_CLUSTER - 2) * FS_SPC
        ; v0.1 simplifié : SPC=1 → LBA = FS_FDS + cluster - 2.
        rep #$20
        lda FS_FOUND_CLUSTER
        sec
        sbc #$0002
        clc
        adc FS_FDS
        sta $30                         ; LBA pour sd_read_block
        sep #$20
        jsr kernel_sd_read_block
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_fat_next_cluster — lit FAT entry (Sprint 2.j v0.2)
; ════════════════════════════════════════════════════════════════════
;
; Args : FS_QUERY_CLUSTER (4B) = cluster courant.
; Effets : FS_NEXT_CLUSTER (4B) = cluster suivant dans la chaîne FAT32.
;          Si FS_NEXT_CLUSTER >= $0FFFFFF8 → EOC (fin de chaîne).
;          High nibble du byte 3 masqué (FAT32 = 28 bits effectifs).
; v0.2 : suppose BPS=512, cluster < 16384 (offset_bytes 16-bit).
;        FAT lookup : LBA = FS_RSC + cluster*4/512,
;                     offset_in_sec = cluster*4 % 512.
; Modifie : A, X, Y, FS_BUFFER (FAT sector), $20-$21, $30-$32, DP_PCPTR,
;           DP_ENTRY ($50-$52).
; Pré-cond : kernel_fat_init OK.
; ════════════════════════════════════════════════════════════════════
.export kernel_fat_next_cluster
kernel_fat_next_cluster:
        ; tmp = FS_QUERY_CLUSTER (low 16) * 4
        rep #$20
        lda FS_QUERY_CLUSTER
        asl                             ; *2
        asl                             ; *4
        sta $20                         ; tmp_offset 16-bit ($20-$21)
        sep #$20

        ; sector_offset = tmp >> 9 = ($21 >> 1) en 8-bit (cluster < 16384)
        lda $21
        lsr a
        ; LBA = FS_RSC + sector_offset (16-bit)
        clc
        adc FS_RSC
        sta $30
        lda FS_RSC+1
        adc #$00
        sta $31
        lda #$00
        sta $32

        ; DP_PCPTR = FS_BUFFER (bank 1)
        lda #<FS_BUFFER
        sta DP_PCPTR
        lda #>FS_BUFFER
        sta DP_PCPTR+1
        lda #$01
        sta DP_PCPTR+2
        jsr kernel_sd_read_block

        ; DP_ENTRY = FS_BUFFER + offset_in_sec
        ; offset_in_sec = ($21 & 1) << 8 | $20 (max $1FF)
        clc
        lda $20
        adc #<FS_BUFFER
        sta DP_ENTRY
        lda $21
        and #$01
        adc #>FS_BUFFER
        sta DP_ENTRY+1
        lda #$01
        sta DP_ENTRY+2

        ; Lire 4 octets FAT entry → FS_NEXT_CLUSTER
        ldy #$00
        lda [DP_ENTRY],y
        sta FS_NEXT_CLUSTER
        iny
        lda [DP_ENTRY],y
        sta FS_NEXT_CLUSTER+1
        iny
        lda [DP_ENTRY],y
        sta FS_NEXT_CLUSTER+2
        iny
        lda [DP_ENTRY],y
        and #$0F                        ; FAT32 = 28 bits effectifs
        sta FS_NEXT_CLUSTER+3
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_fat_read_file — lit fichier complet via cluster chain (v0.3)
; ════════════════════════════════════════════════════════════════════
;
; Args : FS_FOUND_CLUSTER (4B) = first cluster (résultat fat_open).
;        DP_PCPTR (24-bit)     = destination (sera incrémentée).
; Effets : lit cluster par cluster en suivant la chaîne FAT32 jusqu'à
;          EOC (>= $0FFFFFF8). Chaque cluster (= 1 secteur en v0.3,
;          SPC=1) est copié vers DP_PCPTR puis DP_PCPTR avance de 512.
;          FS_FOUND_CLUSTER consommé/écrasé (vaut EOC à la fin).
; v0.3 : SPC=1, fichier < 64 KiB (DP_PCPTR low+mid 16-bit, pas de
;        propagation vers bank). Pour fichier > 64K, voir v0.4.
; Modifie : A, X, Y, FS_BUFFER (transitoirement), FS_FOUND_CLUSTER,
;           FS_QUERY_CLUSTER, FS_NEXT_CLUSTER, DP_PCPTR, $20-$21,
;           $25-$27, $30-$32, DP_ENTRY.
; Pré-cond : kernel_fat_init OK + fat_open a renseigné FS_FOUND_CLUSTER.
; ════════════════════════════════════════════════════════════════════
.export kernel_fat_read_file
kernel_fat_read_file:
        ; Sauvegarde FS_FOUND_CLUSTER initial en zp tmp $28-$2B
        ; (read_file consomme FS_FOUND_CLUSTER en interne mais le restaure
        ;  à la sortie, pour que l'état "fichier ouvert" reste cohérent).
        lda FS_FOUND_CLUSTER
        sta $28
        lda FS_FOUND_CLUSTER+1
        sta $29
        lda FS_FOUND_CLUSTER+2
        sta $2A
        lda FS_FOUND_CLUSTER+3
        sta $2B
rf_loop:
        ; Test EOC : FS_FOUND_CLUSTER >= $0FFFFFF8 ?
        lda FS_FOUND_CLUSTER+3
        and #$0F                        ; FAT32 = 28 bits
        cmp #$0F
        bne rf_not_eoc
        lda FS_FOUND_CLUSTER+2
        cmp #$FF
        bne rf_not_eoc
        lda FS_FOUND_CLUSTER+1
        cmp #$FF
        bne rf_not_eoc
        lda FS_FOUND_CLUSTER
        cmp #$F8
        bcc rf_not_eoc                  ; A < $F8 → pas EOC
        jmp rf_done                     ; cluster >= $0FFFFFF8 → EOC

rf_not_eoc:
        ; Lit cluster courant (FS_FOUND_CLUSTER) vers DP_PCPTR
        jsr kernel_fat_read_cluster

        ; Avance DP_PCPTR += 512 (= $0200)
        rep #$20
        lda DP_PCPTR
        clc
        adc #$0200
        sta DP_PCPTR
        sep #$20
        ; (overflow vers DP_PCPTR+2 ignoré : v0.3 fichier < 64K)

        ; Sauvegarde DP_PCPTR avant next_cluster (qui écrase DP_PCPTR)
        lda DP_PCPTR
        sta $25
        lda DP_PCPTR+1
        sta $26
        lda DP_PCPTR+2
        sta $27

        ; FS_QUERY_CLUSTER = FS_FOUND_CLUSTER (input pour next_cluster)
        lda FS_FOUND_CLUSTER
        sta FS_QUERY_CLUSTER
        lda FS_FOUND_CLUSTER+1
        sta FS_QUERY_CLUSTER+1
        lda FS_FOUND_CLUSTER+2
        sta FS_QUERY_CLUSTER+2
        lda FS_FOUND_CLUSTER+3
        sta FS_QUERY_CLUSTER+3

        jsr kernel_fat_next_cluster

        ; Restaure DP_PCPTR (next_cluster a réutilisé DP_PCPTR pour FAT)
        lda $25
        sta DP_PCPTR
        lda $26
        sta DP_PCPTR+1
        lda $27
        sta DP_PCPTR+2

        ; FS_FOUND_CLUSTER = FS_NEXT_CLUSTER (avance dans la chaîne)
        lda FS_NEXT_CLUSTER
        sta FS_FOUND_CLUSTER
        lda FS_NEXT_CLUSTER+1
        sta FS_FOUND_CLUSTER+1
        lda FS_NEXT_CLUSTER+2
        sta FS_FOUND_CLUSTER+2
        lda FS_NEXT_CLUSTER+3
        sta FS_FOUND_CLUSTER+3

        jmp rf_loop                     ; jmp (pas bra : > 127 bytes)

rf_done:
        ; Restaure FS_FOUND_CLUSTER initial (état "fichier ouvert" cohérent).
        lda $28
        sta FS_FOUND_CLUSTER
        lda $29
        sta FS_FOUND_CLUSTER+1
        lda $2A
        sta FS_FOUND_CLUSTER+2
        lda $2B
        sta FS_FOUND_CLUSTER+3
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_sd_read_block — lit 1 bloc 512 octets (Sprint 2.j.0)
; ════════════════════════════════════════════════════════════════════
;
; Args : LBA dans X 16-bit (low 16 bits — v0.1 supporte 16M blocs).
;        DP_PCPTR ($0C-$0E) = pointer 24-bit destination.
; Effets : copie 512 octets du bloc LBA vers [DP_PCPTR..+511].
; Modifie : A, X, Y. Préserve : nothing.
; Pré-cond : mode N M=1 X=1, DBR=0, SD device présent.
; ════════════════════════════════════════════════════════════════════
.export kernel_sd_read_block
kernel_sd_read_block:
        ; LBA en X 16-bit (mais on est en X=1 8-bit). Utiliser DP zp tmp.
        ; Convention v0.1 : caller stocke LBA 16-bit en $30/$31, bit 16-23 = 0.
        ; (extension future : 24-bit en $32 si besoin de SD > 32 MiB).
        lda $30
        sta SD_LBA_LO
        lda $31
        sta SD_LBA_MID
        lda #$00
        sta SD_LBA_HI

        ; Trigger read (synchrone, busy=0 immédiat dans Phosphoric stub)
        lda #SD_CTRL_READ
        sta SD_CTRL

        ; Wait busy clear (pour cibles asynchrones futures)
sd_wait:
        lda SD_CTRL
        and #SD_CTRL_BUSY
        bne sd_wait

        ; Copy 512 bytes from SD_DATA to [DP_PCPTR],Y
        ; Y 16-bit pour parcourir 512 bytes.
        rep #$10                ; X 16-bit (Y aussi)
        ldy #$0000
sd_copy:
        cpy #$0200              ; 512
        bcs sd_done
        lda SD_DATA             ; auto-increment côté device
        sta [DP_PCPTR],Y
        iny
        bra sd_copy
sd_done:
        sep #$10
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_bundle_find_code — trouve la section CODE (Sprint 2.l)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP_PTR (24-bit) → bundle.
; Out  : A = $00 (OK) ou $03 (NOT_FOUND).
;        Si OK : BUNDLE_FOUND_SIZE = size 16-bit,
;                BUNDLE_FOUND_OFFSET = offset 16-bit.
; Modifie : A, X, Y. Préserve : nothing important.
; ════════════════════════════════════════════════════════════════════
.export kernel_bundle_find_code
kernel_bundle_find_code:
        ; Lit nsec dans DP zero page tmp ($15) pour cpx ZP.
        ldy #BNL_HDR_NSEC
        lda [DP_PTR],Y
        sta BUNDLE_FOUND_NSEC
        sta $15                 ; tmp ZP pour cpx
        ldx #$00                ; section index
fc_loop:
        cpx $15                 ; cpx zp (cpx long abs n'existe pas)
        bcs fc_not_found
        ; entry offset = BNL_HDR_SIZE + X * BNL_SEC_SIZE = 8 + X*8 = (X+1)*8
        txa
        clc
        adc #$01                ; X+1
        asl                     ; (X+1)*2
        asl                     ; (X+1)*4
        asl                     ; (X+1)*8 = BNL_HDR_SIZE + X*BNL_SEC_SIZE (pour BNL_HDR_SIZE=8 et SEC_SIZE=8)
        tay                     ; Y = entry offset (max 8 sections * 8 = 64 bytes)
        ; Read type
        lda [DP_PTR],Y
        cmp #BUNDLE_SEC_CODE
        beq fc_found
        inx
        bra fc_loop
fc_found:
        ; Read size + offset depuis entry. Y = entry start.
        iny
        iny                     ; Y = entry + 2 (size_lo)
        lda [DP_PTR],Y
        sta BUNDLE_FOUND_SIZE
        iny                     ; Y = entry + 3
        lda [DP_PTR],Y
        sta BUNDLE_FOUND_SIZE+1
        iny                     ; Y = entry + 4
        lda [DP_PTR],Y
        sta BUNDLE_FOUND_OFFSET
        iny                     ; Y = entry + 5
        lda [DP_PTR],Y
        sta BUNDLE_FOUND_OFFSET+1
        lda #BUNDLE_OK
        rts
fc_not_found:
        lda #BUNDLE_ERR_NOT_FOUND
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_bundle_validate — vérifie format OricOS bundle (Sprint 2.k)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP_PTR (24-bit) → début bundle.
; Out  : A = 0 (OK), $01 (mauvais magic), $02 (mauvaise version).
;        Préserve : X. Modifie : A, Y.
; ════════════════════════════════════════════════════════════════════
.export kernel_bundle_validate
kernel_bundle_validate:
        ldy #$00
        lda [DP_PTR],Y
        cmp #BUNDLE_MAGIC_0
        bne bv_bad_magic
        iny
        lda [DP_PTR],Y
        cmp #BUNDLE_MAGIC_1
        bne bv_bad_magic
        iny
        lda [DP_PTR],Y
        cmp #BUNDLE_MAGIC_2
        bne bv_bad_magic
        iny
        lda [DP_PTR],Y
        cmp #BUNDLE_MAGIC_3
        bne bv_bad_magic
        ldy #BNL_HDR_VER
        lda [DP_PTR],Y
        cmp #BUNDLE_VERSION
        bne bv_bad_version
        lda #BUNDLE_OK
        rts
bv_bad_magic:
        lda #BUNDLE_ERR_MAGIC
        rts
bv_bad_version:
        lda #BUNDLE_ERR_VERSION
        rts

; ════════════════════════════════════════════════════════════════════
;  kernel_app_exec — load + run une app bundle (Sprint 2.l.1)
; ════════════════════════════════════════════════════════════════════
;
; Args : DP_PTR (24-bit) → bundle.
; Out  : A = $00 OK ou code erreur (validate/find_code/alloc).
;        Bank app conservée allouée (free explicite v0.2).
; Modifie : A, X, Y, BUNDLE_APP_BANK, DP zero page tmp slots.
; ════════════════════════════════════════════════════════════════════
.export kernel_app_exec
kernel_app_exec:
        jsr kernel_bundle_validate
        cmp #BUNDLE_OK
        beq ae_after_validate
        rts
ae_after_validate:
        jsr kernel_bundle_find_code
        cmp #BUNDLE_OK
        beq ae_after_find
        rts
ae_after_find:
        jsr kernel_alloc_bank
        cmp #$00
        bne ae_after_alloc
        rts                             ; A=$00 (pool exhausted)
ae_after_alloc:
        sta BUNDLE_APP_BANK

        ; Setup DP_SRC = DP_PTR + BUNDLE_FOUND_OFFSET (24-bit add)
        rep #$20
        lda DP_PTR
        clc
        adc BUNDLE_FOUND_OFFSET
        sta $18                         ; DP_SRC low/high (16-bit)
        sep #$20
        lda DP_PTR+2
        sta $1A                         ; DP_SRC bank

        ; Setup DP_DEST = APP_BANK : $0200
        lda #$00
        sta $1B
        lda #$02
        sta $1C
        lda BUNDLE_APP_BANK
        sta $1D

        ; Copy section CODE (v0.2 : size 16-bit, supporte jusqu'à 64 KiB)
        rep #$20                        ; M=0 → A 16-bit pour lire size
        lda BUNDLE_FOUND_SIZE           ; 16-bit size (low+high)
        sta $16                         ; $16/$17 = counter 16-bit
        sep #$20                        ; M=1 → A 8-bit
        rep #$10                        ; X=0 → Y 16-bit
        ldy #$0000
ae_copy:
        cpy $16                         ; comparer Y (16-bit) avec count
        bcs ae_copy_done
        lda [$18],Y                     ; byte source (M=1 → 8-bit)
        sta [$1B],Y
        iny
        bra ae_copy
ae_copy_done:
        sep #$10                        ; X=1 → Y 8-bit (restore)

        ; Patch JSL self-modifying. ld65 résout les labels CODE en 16-bit
        ; (bank=0 par défaut dans STA al). Workaround : DP indirect long
        ; avec bank=$01 explicite (CODE segment loaded en bank 1).
        lda #<app_exec_jsl_bank
        sta $20
        lda #>app_exec_jsl_bank
        sta $21
        lda #$01
        sta $22
        lda BUNDLE_APP_BANK
        sta [$20]

        jsr app_exec_call
        lda #BUNDLE_OK
        rts

; Self-modifying JSL : opcode + 3 bytes addr. Le 4e byte (bank) est
; modifié dynamiquement avant l'appel.
app_exec_call:
        .byte $22                       ; JSL al opcode
        .byte $00                       ; addr lo  ($0200)
        .byte $02                       ; addr hi
app_exec_jsl_bank:
        .byte $00                       ; bank — modifié par app_exec
        rts                             ; retour ici quand l'app fait RTL

; ════════════════════════════════════════════════════════════════════
;  kernel_panic — erreur fatale (Sprint 2.i)
; ════════════════════════════════════════════════════════════════════
;
; Args : A = code panic (8-bit). Stocké dans PANIC_CODE pour inspection.
; Affiche "PANIC <hex>" à l'écran via print_string + print_hex8, puis STP.
; Pré-cond : mode N M=X=1, DBR=0, console initialisée (CURSOR_ADDR
; valide en bank 0 screen RAM).
