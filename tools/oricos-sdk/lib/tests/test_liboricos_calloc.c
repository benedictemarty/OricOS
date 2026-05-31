/* SPDX-License-Identifier: EUPL-1.2 */
/* Copyright (c) 2026 Bénédicte Marty */

/*
 * test_liboricos_calloc.c — test natif du fix overflow calloc.
 *
 * Bug : `nmemb * size` wrappait en size_t (16-bit env OricOS) →
 * calloc(256, 256) = 65536 = 0 → malloc(0) → buffer 2 octets →
 * caller écrit 65536 octets → corruption silencieuse du bank entier.
 *
 * Fix : helper `_calloc_overflows(nmemb, size)` qui détecte le wrap
 * AVANT la multiplication, via `nmemb > SIZE_MAX / size`. Marche à
 * n'importe quelle largeur size_t.
 *
 * Stratégie test : on inclut malloc.c en renommant malloc/free/calloc
 * pour éviter le clash libc host, et on teste DIRECTEMENT le helper
 * `_calloc_overflows` (static). Indépendant du heap, indépendant de
 * la largeur size_t (vérifie la logique pour SIZE_MAX du host).
 *
 * Limite : sur host (size_t=32-bit), la valeur exacte qui déclenche
 * le bug OricOS (calloc(256, 256)) ne overflow PAS. On verrouille
 * donc la logique sur SIZE_MAX scalé au host, ce qui est équivalent.
 *
 * Build : gcc -std=c99 -Wall -Wextra -o /tmp/test_liboricos_calloc \
 *           tests/test_liboricos_calloc.c
 */

#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <limits.h>

/* Rename pour éviter le clash avec libc host malloc/free/calloc. */
#define malloc          oricos_malloc
#define free            oricos_free
#define calloc          oricos_calloc
#define heap_available  oricos_heap_available

/* Stub __heap_start (référencé par malloc.c via extern). On ne teste
 * PAS calloc end-to-end ici (le heap host est cassé pour le HEAP_END
 * = $FFFF hardcoded) — on teste uniquement _calloc_overflows. */
char __heap_start = 0;

#include "../malloc.c"

#undef malloc
#undef free
#undef calloc
#undef heap_available

/* ─── Test harness ─── */
static int tests_passed = 0;
static int tests_failed = 0;

#define ASSERT_EQ(label, actual, expected) do { \
    if ((long)(actual) != (long)(expected)) { \
        fprintf(stderr, "  FAIL %s : got %ld, expected %ld\n", \
                (label), (long)(actual), (long)(expected)); \
        tests_failed++; \
    } else { \
        fprintf(stderr, "  OK   %s = %ld\n", (label), (long)(actual)); \
        tests_passed++; \
    } \
} while (0)

int main(void) {
    fprintf(stderr, "=== _calloc_overflows : overflow yes/no ===\n");

    /* Cas zéro : pas d'overflow par construction. */
    ASSERT_EQ("overflows(0, 0)",        _calloc_overflows(0, 0), 0);
    ASSERT_EQ("overflows(0, 100)",      _calloc_overflows(0, 100), 0);
    ASSERT_EQ("overflows(100, 0)",      _calloc_overflows(100, 0), 0);

    /* Petites valeurs : safe. */
    ASSERT_EQ("overflows(10, 20)",      _calloc_overflows(10, 20), 0);
    ASSERT_EQ("overflows(100, 100)",    _calloc_overflows(100, 100), 0);

    /* Limites exactes : a*b == SIZE_MAX → pas d'overflow. */
    ASSERT_EQ("overflows(SIZE_MAX, 1)", _calloc_overflows(SIZE_MAX, 1), 0);
    ASSERT_EQ("overflows(1, SIZE_MAX)", _calloc_overflows(1, SIZE_MAX), 0);

    /* Overflow trivial. */
    ASSERT_EQ("overflows(SIZE_MAX, 2)", _calloc_overflows(SIZE_MAX, 2), 1);
    ASSERT_EQ("overflows(2, SIZE_MAX)", _calloc_overflows(2, SIZE_MAX), 1);

    /* Overflow non-trivial : (SIZE_MAX/2 + 1) * 3 wraps. */
    ASSERT_EQ("overflows(SIZE_MAX/2+1, 3)",
              _calloc_overflows(SIZE_MAX / 2 + 1, 3), 1);

    /* Extrême. */
    ASSERT_EQ("overflows(SIZE_MAX, SIZE_MAX)",
              _calloc_overflows(SIZE_MAX, SIZE_MAX), 1);

    /* Cas spécifique env OricOS : sur 16-bit size_t, calloc(256, 256)
     * = 65536 = wrap. Sur host 32-bit, 256*256 = 65536 < SIZE_MAX donc
     * PAS d'overflow ici. Documente — vérifie via simulation 16-bit
     * dans la fonction inline ci-dessous. */
    fprintf(stderr, "\n=== Simulation 16-bit (env OricOS) ===\n");
    /* Réplique du check, typé uint16_t : */
    #define U16_OVERFLOWS(a, b) ((b) != 0 && (uint16_t)(a) > (uint16_t)(0xFFFFu) / (uint16_t)(b))
    ASSERT_EQ("u16_overflows(256, 256) [bug exact]",  U16_OVERFLOWS(256, 256), 1);
    ASSERT_EQ("u16_overflows(255, 256) [borderline]", U16_OVERFLOWS(255, 256), 0);
    ASSERT_EQ("u16_overflows(257, 256) [overflow]",   U16_OVERFLOWS(257, 256), 1);
    ASSERT_EQ("u16_overflows(100, 100)",              U16_OVERFLOWS(100, 100), 0);

    fprintf(stderr, "\n=== Résultats : %d passed, %d failed ===\n",
            tests_passed, tests_failed);
    return tests_failed ? 1 : 0;
}
