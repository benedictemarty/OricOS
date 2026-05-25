/*
 * SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * link.ld — OricOS userland app linker script (TC-llvmmos-target-oricos)
 *
 * Layout mémoire OricOS (ADR-04, ADR-05 v2) :
 *   - Bank 0 ($0000-$FFFF) : kernel ZP + code/data kernel + I/O
 *   - ZP kernel utilisée : $00-$88 (voir kernel.s REGISTRE ZP)
 *   - ZP libre pour apps : $89-$CF ($D0-$DF = args syscall kernel)
 *   - Code app : $0200-$FFFF dans le bank alloué par kernel_alloc_bank
 *
 * Registres imaginaires llvm-mos (__rc0..__rc31, 32 bytes) :
 *   - Basés à $89 (zone libre ZP, évite conflit kernel $00-$88)
 *   - __rc0=$89, __rc1=$8A, ..., __rc31=$A8
 *   - ZP restante apps : $A9-$CF (38 octets)
 */

/* Registres imaginaires : début à $89 (zone libre ZP kernel) */
__rc0 = 0x89;
INCLUDE imag-regs.ld
ASSERT(__rc31 == 0xa8, "Inconsistent ZP map: imag-regs collision détectée.")

MEMORY {
    /* ZP apps : apres les imag-regs, avant zone args syscall kernel */
    zp  (rw)  : ORIGIN = __rc31 + 1, LENGTH = 0xd0 - (__rc31 + 1)
    /* Code + data : $0200-$FFFF dans le bank app (PBR = bank alloué) */
    ram (rwx) : ORIGIN = 0x0200, LENGTH = 0xfe00
}

REGION_ALIAS("c_readonly", ram)
REGION_ALIAS("c_writeable", ram)

SECTIONS {
    /* _start doit être en premier (= point d'entrée $0200). */
    INCLUDE text.ld
    INCLUDE zp.ld
    INCLUDE rodata.ld
    INCLUDE data.ld
    INCLUDE bss.ld
    INCLUDE noinit.ld
}

OUTPUT_FORMAT {
    TRIM(ram)
}
