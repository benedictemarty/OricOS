/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * clock.c — Première vraie app userland C OricOS (Sprint 4)
 *
 * Démontre une app C pilotée par le temps : crée une fenêtre, puis à chaque
 * intervalle de STEP_TICKS ticks scheduler (lus via SYS_GET_TICKS, mesure
 * wrap-safe, CPU cédé via SYS_YIELD), dessine une barre de progression qui
 * grandit dans sa fenêtre (SYS_GFX_FILL_RECT + SYS_WIN_FLUSH). Après N_STEPS,
 * l'app sort. Valide get_ticks + yield + dessin fenêtré depuis du C.
 */

#include <oricos.h>

#define STEP_TICKS  4    /* ticks scheduler entre deux pas d'affichage */
#define N_STEPS     4    /* nombre de pas avant sortie */

int main(void) {
    oricos_win_create(180, 150, 210, 80);
    oricos_print_string("clock: start\r\n");

    unsigned char last = oricos_get_ticks();
    for (unsigned char s = 0; s < N_STEPS; s++) {
        /* attend STEP_TICKS ticks (soustraction non signée wrap-safe) */
        while ((unsigned char)(oricos_get_ticks() - last) < STEP_TICKS) {
            oricos_yield();
        }
        last = oricos_get_ticks();
        /* barre de progression (coords locales à la fenêtre) */
        oricos_gfx_fill_rect(8, 30, 190, 16, 0);                          /* efface */
        oricos_gfx_fill_rect(8, 30, (unsigned char)((s + 1) * 46), 16, 10);  /* vert */
        oricos_win_flush();
        oricos_print_string("clock: tick\r\n");
    }
    oricos_print_string("clock: done\r\n");
    return 0;
}
