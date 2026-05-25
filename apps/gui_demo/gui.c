/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * gui.c — App OricOS démo GUI déclarative + événementielle (SP-3.n G.7)
 *
 * Clôt l'arc SP-3.n : une app C
 *   - DÉCLARE son UI comme une table GenUI (fenêtre + bouton) — modèle GeoWorks ;
 *   - tourne une BOUCLE MainLoop (SYS_MAIN_LOOP) et réagit aux MESSAGES
 *     sémantiques (MSG_CONTROL quand son bouton est cliqué, MSG_CLOSE pour sortir).
 * Aucune coordonnée XVGA, aucun callback : l'app déclare et réagit.
 */

#include <oricos.h>

/* Table GenUI déclarative : fenêtre (100,120,140,90) + 1 bouton rel(10,40,60,20).
 * Valeurs 16-bit little-endian (lo, hi). */
static const unsigned char gui_def[] = {
    GU_WINDOW, 100, 0,  120, 0,  140, 0,  90, 0,
    GU_BUTTON,  10, 0,   40, 0,   60, 0,  20, 0,
    GU_END
};

int main(void) {
    oricos_print_string("gui: ui_define\r\n");
    oricos_ui_define(gui_def);          /* déclare fenêtre + bouton (prend le focus) */

    for (;;) {
        unsigned char msg = oricos_main_loop();   /* bloque jusqu'à un message */
        if (msg == MSG_CONTROL) {
            oricos_print_string("gui: bouton\r\n");
        } else if (msg == MSG_CLOSE) {
            break;                       /* l'app décide de fermer */
        }
    }

    oricos_print_string("gui: sortie\r\n");
    return 0;
}
