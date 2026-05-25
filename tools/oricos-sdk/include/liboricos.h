/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * liboricos.h — libc minimale pour apps OricOS userland (TC-libc)
 *
 * Inclure ce fichier dans toutes les apps qui ont besoin de printf,
 * malloc, ou des fonctions string standard.
 *
 * Linker : ajouter liboricos.a avant -lcrt0 dans la ligne de commande.
 *   clang --target=mos-oricos app.c /path/to/liboricos.a -lcrt0 -o app.bin
 *
 * Ou avec le Makefile OricOS standard :
 *   LIBS += $(SDK_DIR)/lib/liboricos.a
 */

#ifndef LIBORICOS_H
#define LIBORICOS_H

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Sortie console ──────────────────────────────────────────────── */
int putchar(int c);
int puts(const char *s);

/* printf : supporte %s %d %u %c %x %% (pas de %f, pas de largeur) */
int printf(const char *fmt, ...);
int sprintf(char *buf, const char *fmt, ...);
int vprintf(const char *fmt, va_list ap);

/* ── Fonctions string ────────────────────────────────────────────── */
size_t strlen(const char *s);
void  *memset(void *dst, int c, size_t n);
void  *memcpy(void *dst, const void *src, size_t n);
char  *strcpy(char *dst, const char *src);
char  *strcat(char *dst, const char *src);
int    strcmp(const char *a, const char *b);

/* Conversion entier → chaîne. buf doit être ≥ 7 bytes. */
char  *itoa(int val, char *buf, int base);

/* ── Allocation mémoire (bump allocator bank-local) ─────────────── */
void  *malloc(size_t n);
void   free(void *p);      /* v1 : no-op */
void  *calloc(size_t nmemb, size_t size);

/* Octets libres restants dans le heap du bank courant. */
size_t heap_available(void);

#ifdef __cplusplus
}
#endif

#endif /* LIBORICOS_H */
