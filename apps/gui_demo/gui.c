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

/* Table GenUI déclarative : titre + fenêtre (420,420,170,110) + bouton rel(20,50,
 * 90,24) avec libellé. Chaînes INLINE null-terminées (dans le bank de l'app) —
 * pas de pointeur à splitter. Valeurs 16-bit little-endian. */
static const unsigned char gui_def[] = {
    GU_TITLE, 'D','e','m','o',' ','C', 0,
    GU_WINDOW, 420 & 255, 420 >> 8,  420 & 255, 420 >> 8,  170, 0,  110, 0,
    GU_BUTTON,  20, 0,   50, 0,   90, 0,  24, 0,  'C','l','i','c', 0,
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
