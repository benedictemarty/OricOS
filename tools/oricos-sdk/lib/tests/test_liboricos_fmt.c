/* SPDX-License-Identifier: EUPL-1.2 */
/* Copyright (c) 2026 Bénédicte Marty */

/*
 * test_liboricos_fmt.c — test natif (host gcc) du formatage liboricos.
 *
 * Cible le bug %u (cassé pour val ≥ 32768 quand int=16-bit env OricOS) :
 *   _vfmtcore faisait itoa((int)v, …, 10) → cast unsigned→signed →
 *   itoa voyait val<0 (en 16-bit) → imprimait "-25536" pour 40000.
 *
 * Fix : nouveau primitive _utoa(uint16_t, char*, int), pas de signe.
 *       %u et %x l'appellent directement, itoa wrap pour le signed path.
 *
 * Test technique : compile en native gcc avec stubs syscall. Sur host
 * int=32-bit, le bug original ne se reproduit PAS via sprintf("%u",
 * 40000u) (le cast garde la positivité). On verrouille donc directement
 * la primitive _utoa sur tous les uint16_t critiques.
 *
 * Build : gcc -std=c99 -Wall -Wextra -Itests/stubs \
 *           -o /tmp/test_liboricos_fmt tests/test_liboricos_fmt.c
 * Run   : /tmp/test_liboricos_fmt
 */

#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdarg.h>
#include <stdlib.h>

/* Stubs syscall : satisfont les decls de tests/stubs/oricos.h. Le chemin
 * sprintf qu'on teste n'appelle pas ces stubs (utilise _sbuf_putc en
 * interne via le ctx callback). Présents juste pour le link. */
void oricos_print_char(uint8_t c) { (void)c; }
void oricos_print_string(const char *s) { (void)s; }

/* Include direct du source liboricos — accès à la primitive interne
 * _utoa (static). Build : `gcc -Itests/stubs` fournit un oricos.h stub
 * (extern decls seulement, pas d'inline asm 65816). */
#include "../liboricos.c"

/* ─── Test harness ───
 * liboricos.c REDÉFINIT putchar() → toute la chaîne printf/puts host est
 * détournée vers le stub no-op. On émet via fprintf(stderr) qui utilise
 * write(2) direct (bypass putchar). */
static int tests_passed = 0;
static int tests_failed = 0;

#define ASSERT_STREQ(actual, expected, label) do { \
    if (strcmp((actual), (expected)) != 0) { \
        fprintf(stderr, "  FAIL %s : got \"%s\", expected \"%s\"\n", \
                (label), (actual), (expected)); \
        tests_failed++; \
    } else { \
        fprintf(stderr, "  OK   %s = \"%s\"\n", (label), (actual)); \
        tests_passed++; \
    } \
} while (0)
#define T_PRINT(...) fprintf(stderr, __VA_ARGS__)

int main(void) {
    char buf[16];

    T_PRINT("=== test_liboricos_fmt : _utoa direct ===\n");
    /* Toutes les valeurs uint16_t critiques. Verrouille le bug %u :
     * 32768..65535 sont les valeurs qui en 16-bit signed deviennent
     * négatives → l'ancien itoa((int)v, 10) imprimait "-X". */
    _utoa(0,     buf, 10); ASSERT_STREQ(buf, "0",     "utoa(0)");
    _utoa(1,     buf, 10); ASSERT_STREQ(buf, "1",     "utoa(1)");
    _utoa(9,     buf, 10); ASSERT_STREQ(buf, "9",     "utoa(9)");
    _utoa(10,    buf, 10); ASSERT_STREQ(buf, "10",    "utoa(10)");
    _utoa(99,    buf, 10); ASSERT_STREQ(buf, "99",    "utoa(99)");
    _utoa(100,   buf, 10); ASSERT_STREQ(buf, "100",   "utoa(100)");
    _utoa(32767, buf, 10); ASSERT_STREQ(buf, "32767", "utoa(32767) <=INT16_MAX");
    /* ← région où l'ancien %u plantait : */
    _utoa(32768, buf, 10); ASSERT_STREQ(buf, "32768", "utoa(32768) >INT16_MAX");
    _utoa(40000, buf, 10); ASSERT_STREQ(buf, "40000", "utoa(40000) — bug %u");
    _utoa(65535, buf, 10); ASSERT_STREQ(buf, "65535", "utoa(65535) =UINT16_MAX");

    T_PRINT("\n=== test_liboricos_fmt : _utoa base 16 ===\n");
    _utoa(0,      buf, 16); ASSERT_STREQ(buf, "0",    "utoa(0,16)");
    _utoa(0xAB,   buf, 16); ASSERT_STREQ(buf, "ab",   "utoa(0xAB,16)");
    _utoa(0x1234, buf, 16); ASSERT_STREQ(buf, "1234", "utoa(0x1234,16)");
    _utoa(0xABCD, buf, 16); ASSERT_STREQ(buf, "abcd", "utoa(0xABCD,16)");
    _utoa(0xFFFF, buf, 16); ASSERT_STREQ(buf, "ffff", "utoa(0xFFFF,16)");

    T_PRINT("\n=== test_liboricos_fmt : itoa signed (base 10) ===\n");
    itoa(0,      buf, 10); ASSERT_STREQ(buf, "0",      "itoa(0)");
    itoa(42,     buf, 10); ASSERT_STREQ(buf, "42",     "itoa(42)");
    itoa(-7,     buf, 10); ASSERT_STREQ(buf, "-7",     "itoa(-7)");
    itoa(-32768, buf, 10); ASSERT_STREQ(buf, "-32768", "itoa(INT16_MIN)");

    T_PRINT("\n=== test_liboricos_fmt : sprintf %%u ===\n");
    /* Sur host int=32-bit le bug %u original n'est PAS reproductible via
     * sprintf("%u", 40000) ; on vérifie quand même le chemin %u sur des
     * valeurs où la logique compte. Verrouille la sortie correcte. */
    char sbuf[32];
    sprintf(sbuf, "%u", 0);     ASSERT_STREQ(sbuf, "0",     "sprintf %%u 0");
    sprintf(sbuf, "%u", 12345); ASSERT_STREQ(sbuf, "12345", "sprintf %%u 12345");
    sprintf(sbuf, "%u %x", 100, 0xAB);
    ASSERT_STREQ(sbuf, "100 ab", "sprintf %%u %%x combo");

    T_PRINT("\n=== Résultats : %d passed, %d failed ===\n",
           tests_passed, tests_failed);
    return tests_failed ? 1 : 0;
}
