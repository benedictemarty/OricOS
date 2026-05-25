/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * oricos.h — API publique OricOS pour applications userland C (ADR-17 v1)
 *
 * Utilisation :
 *   #include <oricos.h>
 *   int main(void) { oricos_print_char('A'); return 0; }
 *
 * Compilateur : llvm-mos target mos-oricos (ADR-05 v2)
 *   clang --target=mos-oricos hello.c -lcrt0 -o hello.bin
 *
 * Mode CPU : 65C816 mode N, M=1, X=1 (8-bit registers).
 * Convention : A = syscall num, X/Y = args, retour A (0xFF = erreur).
 *
 * Note asm : les numéros de syscall sont littéraux dans le template asm
 * (ex. "lda #1\n") et non passés via contrainte "i" + %[sym].
 * Avec llvm-mos LTO, la contrainte "i" peut être hoistée en variable ZP
 * (a5 $N) qui écrase la ZP kernel — le littéral force LDA immediate (a9).
 */

#ifndef ORICOS_H
#define ORICOS_H

#include <stdint.h>

/* ── Numéros de syscalls (ADR-17) ────────────────────────────────── */
#define SYS_PRINT_CHAR      0x01
#define SYS_PRINT_STRING    0x02
#define SYS_READ_CHAR       0x03
#define SYS_EXIT            0x04
#define SYS_YIELD           0x05
#define SYS_GET_KEY         0x06
#define SYS_FAT_OPEN        0x07
#define SYS_FAT_READ        0x08
#define SYS_FAT_CLOSE       0x09
#define SYS_PANIC           0x0A
#define SYS_ALLOC_BANK      0x0B
#define SYS_FREE_BANK       0x0C
#define SYS_GFX_CLEAR       0x0D
#define SYS_GFX_FILL_RECT   0x0E
#define SYS_GFX_BLIT        0x0F
#define SYS_GFX_LINE        0x10
#define SYS_GFX_TEXT        0x11
#define SYS_SLEEP_MS        0x12

/* ── Sentinelle d'erreur ─────────────────────────────────────────── */
#define ORICOS_ERR          ((uint8_t)0xFF)
#define ORICOS_OK           ((uint8_t)0x00)

/* ── Macro COP #$AA : appel noyau (ADR-13) ───────────────────────── */
#define _ORICOS_COP() __asm__ volatile(".byte 0x02, 0xAA" ::: "a", "x", "y")

/* ── Primitives de sortie console ────────────────────────────────── */

static __attribute__((always_inline)) inline
void oricos_print_char(uint8_t c) {
    __asm__ volatile (
        "lda #1\n"              /* SYS_PRINT_CHAR — littéral, jamais hoistable */
        "ldx %[ch]\n"
        ".byte 0x02, 0xAA\n"
        :
        : [ch] "r" (c)
        : "a", "x"
    );
}

static __attribute__((always_inline)) inline
void oricos_print_string(const char *s) {
    for (; *s; ++s)
        oricos_print_char((uint8_t)*s);
}

/* ── Contrôle du processus ───────────────────────────────────────── */

static __attribute__((always_inline)) inline
void oricos_yield(void) {
    __asm__ volatile (
        "lda #5\n"              /* SYS_YIELD */
        ".byte 0x02, 0xAA\n"
        :
        :
        : "a"
    );
}

static __attribute__((noreturn, always_inline)) inline
void oricos_exit(uint8_t code) {
    __asm__ volatile (
        "lda #4\n"              /* SYS_EXIT */
        "ldx %[code]\n"
        ".byte 0x02, 0xAA\n"
        :
        : [code] "r" (code)
        : "a", "x"
    );
    __builtin_unreachable();
}

/* ── Lecture clavier ─────────────────────────────────────────────── */

/* Non-bloquant : retourne 0 si pas de touche. */
static __attribute__((always_inline)) inline
uint8_t oricos_get_key(void) {
    uint8_t key;
    __asm__ volatile (
        "lda #6\n"              /* SYS_GET_KEY */
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (key)
        :
        : "a"
    );
    return key;
}

/* Bloquant : attend une touche. */
static __attribute__((always_inline)) inline
uint8_t oricos_read_char(void) {
    uint8_t key;
    __asm__ volatile (
        "lda #3\n"              /* SYS_READ_CHAR */
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (key)
        :
        : "a"
    );
    return key;
}

/* ── Allocation mémoire (banks) ──────────────────────────────────── */

/* Retourne le numéro du bank alloué, ou ORICOS_ERR si plus de banks. */
static __attribute__((always_inline)) inline
uint8_t oricos_alloc_bank(void) {
    uint8_t bank;
    __asm__ volatile (
        "lda #11\n"             /* SYS_ALLOC_BANK */
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (bank)
        :
        : "a"
    );
    return bank;
}

static __attribute__((always_inline)) inline
void oricos_free_bank(uint8_t bank) {
    __asm__ volatile (
        "lda #12\n"             /* SYS_FREE_BANK */
        "ldx %[b]\n"
        ".byte 0x02, 0xAA\n"
        :
        : [b] "r" (bank)
        : "a", "x"
    );
}

#endif /* ORICOS_H */
