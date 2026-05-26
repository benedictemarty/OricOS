/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * ctl.c — App OricOS démo contrôles déclaratifs (SP-3.o S.6, capstone)
 *
 * Déclare une fenêtre avec plusieurs contrôles via une table GenUI (checkbox,
 * ascenseur vertical, champ texte), tourne le MainLoop, et sur chaque
 * MSG_CONTROL lit la valeur du contrôle touché (SYS_CTL_GET_VALUE) et l'imprime.
 * Modèle GeoWorks : l'app déclare son UI et réagit aux messages sémantiques.
 * MSG_CLOSE → sortie.
 */

#include <oricos.h>

/* Table GenUI : titre + fenêtre (200,200,170,130) + checkbox + ascenseur V +
 * champ texte. Chaînes inline ; valeurs 16-bit en (lo, hi). */
static const unsigned char ui[] = {
    GU_TITLE, 'C','t','r','l', 0,
    GU_WINDOW,   200 & 255, 200 >> 8,  200 & 255, 200 >> 8,  170, 0,  130, 0,
    GU_CHECK,     12, 0,  14, 0,  18, 0,  18, 0,   0,           /* value = 0 */
    GU_SCROLL_V, 140, 0,  14, 0,  12, 0, 100, 0,  40,           /* max = 40 */
    GU_TEXT,      12, 0,  44, 0, 120, 0,  18, 0,  10,           /* maxlen = 10 */
    GU_END
};

int main(void) {
    oricos_print_string("ctl: ui_define\r\n");
    oricos_ui_define(ui);

    for (;;) {
        unsigned char msg = oricos_main_loop();
        if (msg == MSG_CONTROL) {
            unsigned char id = oricos_msg_id();
            unsigned char v  = oricos_ctl_get_value(id);
            oricos_print_string("ctl: v=");
            oricos_print_char('0' + (v / 10) % 10);
            oricos_print_char('0' + v % 10);
            oricos_print_string("\r\n");
        } else if (msg == MSG_CLOSE) {
            break;
        }
    }
    oricos_print_string("ctl: sortie\r\n");
    return 0;
}
