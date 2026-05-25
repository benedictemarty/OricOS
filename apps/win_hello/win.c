/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * win.c — App OricOS démo fenêtrée en C (SP-3.m G.6)
 *
 * Démontre la chaîne GUI × multitâche complète depuis du C userland :
 *   - G.2 : crée sa propre fenêtre (SYS_WIN_CREATE), qui prend le focus.
 *   - G.4 : dessine dedans en coordonnées LOCALES (SYS_GFX_FILL_RECT) sans
 *           connaître l'adresse physique XVGA (modèle GrafPort).
 *   - G.4bis : composite son backing store sur l'écran (SYS_WIN_FLUSH).
 *   - G.3 : reçoit le clavier au focus (SYS_READ_CHAR, bloquant).
 *   - G.5 : sa fenêtre se ferme à la sortie (return → SYS_EXIT → teardown).
 */

#include <oricos.h>

int main(void) {
    oricos_print_string("win_hello: creation fenetre\r\n");
    oricos_win_create(100, 80, 200, 120);     /* G.2 : fenêtre + focus */
    oricos_gfx_fill_rect(0, 0, 8, 8, 15);     /* G.4 : dessin local (blanc) */
    oricos_win_flush();                       /* G.4bis : composite → écran */
    oricos_print_string("win_hello: attente touche\r\n");
    oricos_read_char();                       /* G.3 : clavier au focus */
    oricos_print_string("win_hello: sortie\r\n");
    return 0;                                 /* G.5 : exit → fenêtre fermée */
}
