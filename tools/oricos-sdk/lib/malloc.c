/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * malloc.c — Allocateur bump bank-local pour apps OricOS (TC-libc)
 *
 * Stratégie v1 : bump pointer monotone.
 *   - Heap commence à __heap_start (fin du BSS, défini par link.ld).
 *   - Heap se termine à $FFFF (fin du bank app de 64 KiB).
 *   - free() est un no-op : la mémoire libérée n'est pas récupérée.
 *   - Alignement sur 2 bytes (pointeurs 16-bit).
 *
 * Limitations v1 (explicites, pas de surprises) :
 *   - Pas de réutilisation mémoire après free().
 *   - Fragmentation impossible (bump monotone).
 *   - Taille max allouable = espace restant entre __heap_ptr et $FFFF.
 *   - Toutes les allocations sont dans le bank courant (DBR = PBR).
 *
 * v2 (futur) : free list LIFO ou pool fixe par taille de classe.
 */

#include <stddef.h>
#include <stdint.h>
#include <limits.h>     /* SIZE_MAX pour calloc overflow check */

/* Symboles fournis par link.ld */
extern char __heap_start;   /* adresse de début du heap (fin du BSS) */

/* Pointeur courant dans le heap */
static uint8_t *_heap_ptr = NULL;

/* Adresse de fin du bank ($FFFF en 16-bit) */
#define HEAP_END ((uint8_t *)0xFFFF)

/* Alignement minimal 2 bytes (pointeurs 16-bit) */
#define ALIGN_MASK 1u

static void _heap_init(void) {
    _heap_ptr = (uint8_t *)&__heap_start;
    /* Aligner sur 2 bytes */
    if ((uintptr_t)_heap_ptr & ALIGN_MASK)
        _heap_ptr++;
}

void *malloc(size_t n) {
    if (!_heap_ptr) _heap_init();

    /* Aligner la taille sur 2 bytes */
    if (n & ALIGN_MASK) n++;
    if (n == 0) n = 2;

    /* Vérification overflow 16-bit */
    /* Overflow-safe : vérification via l'espace restant. */
    if ((size_t)(HEAP_END - _heap_ptr) < n) {
        return NULL; /* heap épuisé */
    }

    void *p = _heap_ptr;
    _heap_ptr += n;
    return p;
}

/* v1 : no-op — le bump allocator ne récupère pas la mémoire. */
void free(void *p) {
    (void)p;
}

/* _calloc_overflows : 1 si nmemb*size dépasse SIZE_MAX (sinon 0).
 * Détecte le wrap avant la multiplication — l'ancien calloc faisait le
 * mul direct qui wrappait en 16-bit (env OricOS, size_t = 16-bit).
 * Exemple bug : calloc(256, 256) = 65536 = 0 mod 2^16 → malloc(0) →
 * buffer 2 octets → caller écrit 65536 octets → corruption bank.
 * Helper testable isolément (cf. tests/test_liboricos_calloc.c). */
static int _calloc_overflows(size_t nmemb, size_t size) {
    return size != 0 && nmemb > (size_t)SIZE_MAX / size;
}

void *calloc(size_t nmemb, size_t size) {
    if (_calloc_overflows(nmemb, size)) {
        return NULL;            /* overflow → refus net */
    }
    size_t total = nmemb * size;
    void *p = malloc(total);
    if (p) {
        uint8_t *b = (uint8_t *)p;
        size_t i;
        for (i = 0; i < total; i++) b[i] = 0;
    }
    return p;
}

/* Retourne le nombre d'octets encore disponibles dans le heap. */
size_t heap_available(void) {
    if (!_heap_ptr) _heap_init();
    return (size_t)(HEAP_END - _heap_ptr);
}
