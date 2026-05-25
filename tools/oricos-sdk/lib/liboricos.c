/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * liboricos.c — libc minimale pour apps OricOS userland (TC-libc)
 *
 * Fonctions : putchar, puts, strlen, memset, memcpy, strcpy, strcat,
 *             strcmp, itoa, printf (%s/%d/%u/%c/%x/%%), sprintf.
 *
 * Types (llvm-mos mos-oricos) :
 *   char  = 8-bit unsigned, int = 16-bit, long = 32-bit, void* = 16-bit.
 *
 * Pas de dépendances externes (syscalls via oricos.h uniquement).
 */

#include <oricos.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

/* ── Sortie bas-niveau ───────────────────────────────────────────── */

int putchar(int c) {
    oricos_print_char((uint8_t)c);
    return c;
}

int puts(const char *s) {
    oricos_print_string(s);
    oricos_print_char('\n');
    return 0;
}

/* ── Fonctions string ────────────────────────────────────────────── */

size_t strlen(const char *s) {
    size_t n = 0;
    while (*s++) n++;
    return n;
}

void *memset(void *dst, int c, size_t n) {
    uint8_t *p = (uint8_t *)dst;
    while (n--) *p++ = (uint8_t)c;
    return dst;
}

void *memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    while (n--) *d++ = *s++;
    return dst;
}

char *strcpy(char *dst, const char *src) {
    char *d = dst;
    while ((*d++ = *src++));
    return dst;
}

char *strcat(char *dst, const char *src) {
    char *d = dst;
    while (*d) d++;
    while ((*d++ = *src++));
    return dst;
}

int strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

/* ── Conversion entier → chaîne ─────────────────────────────────── */

/* itoa : base 10 ou 16. buf doit être ≥ 7 bytes (16-bit max = 65535). */
char *itoa(int val, char *buf, int base) {
    static const char digits[] = "0123456789abcdef";
    char tmp[8];
    uint8_t i = 0;
    uint16_t u;
    uint8_t neg = 0;

    if (base == 10 && val < 0) {
        neg = 1;
        u = (uint16_t)(-(int16_t)val);
    } else {
        u = (uint16_t)val;
    }

    if (u == 0) {
        tmp[i++] = '0';
    } else {
        while (u) {
            tmp[i++] = digits[u % (uint16_t)base];
            u = u / (uint16_t)base;
        }
    }
    if (neg) tmp[i++] = '-';

    /* Reverse */
    char *p = buf;
    while (i--) *p++ = tmp[i];
    *p = '\0';
    return buf;
}

/* ── printf / sprintf minimaux ───────────────────────────────────── */

/* Formatage interne vers une fonction de sortie générique. */
typedef void (*_putc_fn)(char c, void *ctx);

/* Contexte pour sprintf */
typedef struct {
    char *buf;
    size_t pos;
    size_t max;
} _sbuf_ctx;

static void _putc_char(_putc_fn fn __attribute__((unused)),
                       char c, void *ctx) {
    (void)fn;
    (void)ctx;
    putchar(c);
}

static void _puts_str(_putc_fn pfn, const char *s, void *ctx) {
    (void)pfn; (void)ctx;
    while (*s) putchar(*s++);
}

static void _sbuf_putc(char c, void *ctx) {
    _sbuf_ctx *sb = (_sbuf_ctx *)ctx;
    if (sb->pos + 1 < sb->max) {
        sb->buf[sb->pos++] = c;
        sb->buf[sb->pos] = '\0';
    }
}

/* Noyau commun printf/sprintf.
 * out_char : callback d'émission d'un caractère (NULL = putchar).
 * ctx      : contexte passé au callback.
 */
static int _vfmtcore(void (*out_char)(char, void *), void *ctx,
                     const char *fmt, va_list ap) {
    int count = 0;
    char nbuf[8];

    while (*fmt) {
        if (*fmt != '%') {
            if (out_char) out_char(*fmt, ctx); else putchar(*fmt);
            fmt++; count++;
            continue;
        }
        fmt++; /* saute '%' */

        switch (*fmt++) {
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            while (*s) {
                if (out_char) out_char(*s, ctx); else putchar(*s);
                s++; count++;
            }
            break;
        }
        case 'd': {
            int v = va_arg(ap, int);
            itoa(v, nbuf, 10);
            const char *p = nbuf;
            while (*p) {
                if (out_char) out_char(*p, ctx); else putchar(*p);
                p++; count++;
            }
            break;
        }
        case 'u': {
            unsigned int v = va_arg(ap, unsigned int);
            itoa((int)v, nbuf, 10);
            const char *p = nbuf;
            while (*p) {
                if (out_char) out_char(*p, ctx); else putchar(*p);
                p++; count++;
            }
            break;
        }
        case 'x': {
            unsigned int v = va_arg(ap, unsigned int);
            itoa((int)v, nbuf, 16);
            const char *p = nbuf;
            while (*p) {
                if (out_char) out_char(*p, ctx); else putchar(*p);
                p++; count++;
            }
            break;
        }
        case 'c': {
            int c = va_arg(ap, int);
            if (out_char) out_char((char)c, ctx); else putchar(c);
            count++;
            break;
        }
        case '%':
            if (out_char) out_char('%', ctx); else putchar('%');
            count++;
            break;
        default:
            /* spécificateur inconnu — ignore */
            break;
        }
    }
    return count;
}

int printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int n = _vfmtcore(NULL, NULL, fmt, ap);
    va_end(ap);
    return n;
}

int sprintf(char *buf, const char *fmt, ...) {
    _sbuf_ctx ctx = { buf, 0, (size_t)0xFFFF };
    buf[0] = '\0';
    va_list ap;
    va_start(ap, fmt);
    int n = _vfmtcore(_sbuf_putc, &ctx, fmt, ap);
    va_end(ap);
    return n;
}

int vprintf(const char *fmt, va_list ap) {
    return _vfmtcore(NULL, NULL, fmt, ap);
}
