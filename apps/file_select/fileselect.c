/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * fileselect.c — App OricOS : file selector dialog (pattern GeoWorks
 *   GenFileSelectorClass).
 *
 * Pattern : dialog modal qui présente une liste de fichiers + OK/Cancel.
 * MVP : liste statique 5 fichiers hardcodés (intégration vraie FAT32 SD =
 * Sprint suivant). À la sélection, imprime "fileselect: chose N <name>".
 * À cancel : "fileselect: cancelled".
 *
 * Layout :
 *   - GU_TITLE "Open File"
 *   - GU_WINDOW à (250, 150), 280×180 (modal, taille moyenne)
 *   - GU_LIST 5 items hardcoded (rel 10, 20, 200, 100) — id 1
 *   - GU_BUTTON "OK" (rel 210, 25, 60, 22) — id 2
 *   - GU_BUTTON "Cancel" (rel 210, 55, 60, 22) — id 3
 *
 * Le main loop attend MSG_CONTROL :
 *   - id 2 (OK)     → lit oricos_ctl_get_value(LIST_ID), prints choix, quit
 *   - id 3 (Cancel) → prints "cancelled", quit
 *   - MSG_CLOSE (titlebar X) → "cancelled", quit
 */

#include <oricos.h>

#define LIST_ID    1
#define BTN_OK     2
#define BTN_CANCEL 3

/* Liste fichiers MVP (hardcoded). 5 items, GU_LIST hauteur 100 px =
 * ~10 lignes visibles (10 px/ligne), donc tout est visible sans scroll. */
static const unsigned char ui[] = {
    GU_TITLE,    'O','p','e','n',' ','F','i','l','e', 0,
    GU_WINDOW,   250 & 255, 250 >> 8,  150 & 255, 150 >> 8,
                 280 & 255, 280 >> 8,  180 & 255, 180 >> 8,
    GU_LIST,      10, 0,  20, 0, 190, 0, 100, 0,   5,         /* id 1, 5 items */
                  'r','e','a','d','m','e', 0,                 /* MVP : items ≤7c */
                  's','c','o','r','e', 0,
                  'c','l','o','c','k', 0,
                  'c','t','l', 0,
                  'h','e','l','l','o', 0,
    GU_BUTTON,   210, 0,  25, 0,  60, 0,  22, 0,
                  'O','K', 0,                                  /* id 2 */
    GU_BUTTON,   210, 0,  55, 0,  60, 0,  22, 0,
                  'C','a','n','c','e','l', 0,                  /* id 3 */
    GU_END
};

/* Noms en clair pour print confirmation (parallèle au GU_LIST). */
static const char* files[] = {
    "readme", "score", "clock", "ctl", "hello"
};

int main(void) {
    oricos_print_string("fileselect: start\r\n");
    oricos_ui_define(ui);

    for (;;) {
        unsigned char msg = oricos_main_loop();
        if (msg == MSG_CONTROL) {
            unsigned char id = oricos_msg_id();
            if (id == BTN_OK) {
                unsigned char idx = oricos_ctl_get_value(LIST_ID);
                if (idx >= 5) idx = 0;          /* clamp défensif */
                oricos_print_string("fileselect: chose ");
                oricos_print_char('0' + idx);
                oricos_print_char(' ');
                oricos_print_string(files[idx]);
                oricos_print_string("\r\n");
                break;
            } else if (id == BTN_CANCEL) {
                oricos_print_string("fileselect: cancelled\r\n");
                break;
            }
            /* id == LIST_ID : sélection change, le widget gère son visuel.
             * Pas de message côté app jusqu'à OK. */
        } else if (msg == MSG_CLOSE) {
            oricos_print_string("fileselect: cancelled\r\n");
            break;
        }
    }
    oricos_print_string("fileselect: done\r\n");
    return 0;
}
