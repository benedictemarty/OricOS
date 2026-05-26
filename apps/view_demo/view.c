/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * view.c — App OricOS démo GenView (SP-3.o S.3c)
 *
 * Déclare une fenêtre + un GenView (viewport scrollable, table GenUI), tourne une
 * boucle MainLoop, et réagit au défilement : sur MSG_CONTROL, lit l'offset
 * scroll_y du contrôle (SYS_CTL_GET_VALUE) et l'imprime. Modèle GeoWorks : le
 * système gère la barre/offset, l'app réagit. MSG_CLOSE → sortie.
 */

#include <oricos.h>

/* Table GenUI : titre + fenêtre (200,200,160,100) + GenView rel(10,14,130,70),
 * max scroll = 60. Chaînes inline. */
static const unsigned char view_def[] = {
    GU_TITLE, 'V','u','e', 0,
    GU_WINDOW, 200 & 255, 200 >> 8,  200 & 255, 200 >> 8,  160, 0,  100, 0,
    GU_VIEW,    10, 0,  14, 0,  130, 0,  70, 0,  60,
    GU_END
};

int main(void) {
    oricos_print_string("view: ui_define\r\n");
    oricos_ui_define(view_def);

    for (;;) {
        unsigned char msg = oricos_main_loop();
        if (msg == MSG_CONTROL) {
            unsigned char id = oricos_msg_id();
            unsigned char sy = oricos_ctl_get_value(id);   /* offset scroll_y */
            oricos_print_string("view: scroll ");
            oricos_print_char('0' + (sy / 10) % 10);
            oricos_print_char('0' + sy % 10);
            oricos_print_string("\r\n");
        } else if (msg == MSG_CLOSE) {
            break;
        }
    }
    oricos_print_string("view: sortie\r\n");
    return 0;
}
