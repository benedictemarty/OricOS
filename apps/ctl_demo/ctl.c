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

/* Table GenUI : titre + fenêtre (élargie pour la liste) + checkbox + ascenseur V +
 * champ texte + GU_LIST (3 items, ADR-30 Étape 1, alignement GeoWorks GenList).
 * Chaînes inline ; valeurs 16-bit en (lo, hi). */
static const unsigned char ui[] = {
    GU_TITLE, 'C','t','r','l', 0,
    GU_WINDOW,   200 & 255, 200 >> 8,  200 & 255, 200 >> 8,  170, 0,  170, 0,
    GU_CHECK,     12, 0,  14, 0,  18, 0,  18, 0,   0,           /* value = 0 */
    GU_HINT_MIN_VALUE, 20,                                       /* ADR-30 Étape 3 */
    GU_SCROLL_V, 140, 0,  14, 0,  12, 0, 100, 0,  40,           /* range = 20..60 */
    GU_TEXT,      12, 0,  44, 0, 120, 0,  18, 0,  10,           /* maxlen = 10 */
    GU_LIST,      12, 0,  72, 0, 120, 0,  48, 0,   3,           /* count = 3 */
                  'I','t','e','m',' ','A',  0,                  /* item 0 */
                  'I','t','e','m',' ','B',  0,                  /* item 1 */
                  'I','t','e','m',' ','C',  0,                  /* item 2 */
    GU_SPIN,     140, 0, 124, 0,  24, 0,  30, 0,  20,           /* ADR-30 Étape 4 : split haut+1/bas-1, max=20 */
    GU_FIELD,     12, 0, 130, 0, 120, 0,  16, 0,                 /* ADR-30 Étape 5 : labeled value */
                  'C','l','i','c','k','s', 0,
    GU_MENU,      'A','p','p', 0,                               /* ADR-30 Étape 2 */
    GU_MENU_ITEM, 'A','b','o','u','t', 0,
    GU_MENU_ITEM, 'Q','u','i','t', 0,
    GU_END
};

int main(void) {
    oricos_print_string("ctl: ui_define\r\n");
    oricos_ui_define(ui);
    unsigned char clicks = 0;          /* ADR-30 Étape 5 : compteur affiché dans GU_FIELD id=7 */

    for (;;) {
        unsigned char msg = oricos_main_loop();
        if (msg == MSG_CONTROL) {
            unsigned char id = oricos_msg_id();
            unsigned char v  = oricos_ctl_get_value(id);
            oricos_print_string("ctl: v=");
            oricos_print_char('0' + (v / 10) % 10);
            oricos_print_char('0' + v % 10);
            oricos_print_string("\r\n");
        } else if (msg == MSG_MENU) {
            /* ADR-30 Étape 2b : id packé = (menu_id << 4) | item_id.
             * Sentinelle $FF = bar-click (titre, pas un item) → ignorer. */
            unsigned char packed = oricos_msg_id();
            if (packed == 0xFF) continue;
            unsigned char menu = packed >> 4;
            unsigned char item = packed & 0x0F;
            oricos_print_string("ctl: menu m=");
            oricos_print_char('0' + menu);
            oricos_print_string(" i=");
            oricos_print_char('0' + item);
            oricos_print_string("\r\n");
            /* ADR-30 Étape 5 : incrémente compteur affiché dans le field. */
            if (clicks < 99) clicks++;
            oricos_ctl_set_value(7, clicks);
            if (menu == 0 && item == 1) break;   /* App > Quit */
        } else if (msg == MSG_CLOSE) {
            break;
        }
    }
    oricos_print_string("ctl: sortie\r\n");
    return 0;
}
