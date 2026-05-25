/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * hello.c — Première app OricOS en C (TC-llvmmos-target-oricos / TC-poc-hello-c)
 *
 * Démontre :
 *   - Compilation C → binaire OricOS via llvm-mos target mos-oricos
 *   - API syscalls via oricos.h (ADR-17 : COP #$AA)
 *   - Exécution en mode N 8-bit (ADR-05 v2 : M=1, X=1)
 *   - Entrée/sortie console (SYS_PRINT_STRING, SYS_READ_CHAR)
 */

#include <oricos.h>

int main(void) {
    oricos_print_string("Hello OricOS from C!\r\n");
    oricos_print_string("Appuyez sur une touche...\r\n");
    oricos_read_char();
    oricos_print_string("Au revoir !\r\n");
    return 0;
}
