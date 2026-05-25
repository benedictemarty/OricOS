/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * test_libc.c — App de validation TC-libc (liboricos)
 *
 * Vérifie : printf, malloc, strlen, strcpy, strcmp, memset.
 * Affiche les résultats sur la console OricOS.
 */

#include <oricos.h>
#include <liboricos.h>

/* Compteur de tests */
static int _passed = 0;
static int _failed = 0;

static void _check(const char *name, int ok) {
    if (ok) {
        printf("[OK] %s\r\n", name);
        _passed++;
    } else {
        printf("[KO] %s\r\n", name);
        _failed++;
    }
}

int main(void) {
    printf("=== TC-libc OricOS ===\r\n");

    /* printf : entiers */
    printf("  printf(42)  = ");
    printf("%d\r\n", 42);
    printf("  printf(-7)  = ");
    printf("%d\r\n", -7);
    printf("  printf(0xAB)= ");
    printf("%x\r\n", 0xAB);

    /* strlen */
    _check("strlen(\"OricOS\") == 6", strlen("OricOS") == 6);
    _check("strlen(\"\") == 0",       strlen("") == 0);

    /* strcmp */
    _check("strcmp(\"abc\",\"abc\") == 0", strcmp("abc", "abc") == 0);
    _check("strcmp(\"a\",\"b\") < 0",     strcmp("a", "b") < 0);
    _check("strcmp(\"b\",\"a\") > 0",     strcmp("b", "a") > 0);

    /* strcpy */
    char buf[16];
    strcpy(buf, "hello");
    _check("strcpy → strcmp OK", strcmp(buf, "hello") == 0);

    /* memset */
    memset(buf, 'X', 4); buf[4] = '\0';
    _check("memset XXXX", strcmp(buf, "XXXX") == 0);

    /* malloc */
    char *p = (char *)malloc(8);
    _check("malloc != NULL", p != NULL);
    if (p) {
        strcpy(p, "alloc");
        _check("malloc data OK", strcmp(p, "alloc") == 0);
    }

    /* calloc */
    char *q = (char *)calloc(8, 1);
    _check("calloc != NULL", q != NULL);
    if (q) {
        int zero_ok = 1;
        for (int i = 0; i < 8; i++) if (q[i] != 0) zero_ok = 0;
        _check("calloc zeroed", zero_ok);
    }

    /* sprintf */
    char sbuf[32];
    sprintf(sbuf, "val=%d hex=%x", 123, 0xFF);
    _check("sprintf val=123 hex=ff", strcmp(sbuf, "val=123 hex=ff") == 0);

    /* heap_available */
    int ha = (int)heap_available();
    _check("heap_available > 0", ha > 0);
    printf("  heap libre : %d bytes\r\n", ha);

    printf("=== %d/%d tests OK ===\r\n", _passed, _passed + _failed);
    return (_failed == 0) ? 0 : 1;
}
