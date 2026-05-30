/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * score.c — App OricOS « Score Keeper » (capstone ADR-30, 2026-05-30).
 *
 * Première vraie app utilisateur écrite *après* la clôture d'ADR-30 :
 * combine GU_FIELD (affichage value), 3 GU_BUTTON (actions +1 / +10 /
 * Reset), GU_MENU + GU_MENU_ITEM (Quit) et le set_value côté SDK pour
 * rafraîchir le field. But : valider que la toolbox toolbox suffit à
 * écrire une app simple en moins de 60 LOC C, sans toucher de coords
 * XVGA ni de syscall hors API SDK.
 *
 * Layout déclaratif :
 *   - Window (400, 200, 200, 130) titre "Score"
 *   - GU_FIELD "Score" rel(10, 20, 180, 18)   ← widget id 2
 *   - GU_BUTTON "+1"   rel(10, 50, 50, 22)    ← widget id 3
 *   - GU_BUTTON "+10"  rel(70, 50, 55, 22)    ← widget id 4
 *   - GU_BUTTON "Reset" rel(135, 50, 55, 22)  ← widget id 5
 *   - GU_MENU "Game" + GU_MENU_ITEM "Quit"
 *
 * Logique : MSG_CONTROL avec id 3/4/5 → +1 / +10 / reset ; cap à 99
 * (FIELD affiche 2 digits). MSG_MENU avec item valide ≠ $FF → break
 * (App > Quit). MSG_CLOSE direct (case X) → break.
 */

#include <oricos.h>

static const unsigned char score_def[] = {
    GU_TITLE,    'S','c','o','r','e', 0,
    GU_WINDOW,   400 & 255, 400 >> 8,  200 & 255, 200 >> 8,  200, 0,  130, 0,
    GU_FIELD,     10, 0,  20, 0, 180, 0,  18, 0,
                  'S','c','o','r','e', 0,                /* widget id 2 */
    GU_BUTTON,    10, 0,  50, 0,  50, 0,  22, 0,
                  '+','1', 0,                            /* widget id 3 */
    GU_BUTTON,    70, 0,  50, 0,  55, 0,  22, 0,
                  '+','1','0', 0,                        /* widget id 4 */
    GU_BUTTON,   135, 0,  50, 0,  55, 0,  22, 0,
                  'R','e','s','e','t', 0,                /* widget id 5 */
    GU_MENU,      'G','a','m','e', 0,
    GU_MENU_ITEM, 'Q','u','i','t', 0,
    GU_END
};

#define FIELD_ID    2
#define BTN_PLUS1   3
#define BTN_PLUS10  4
#define BTN_RESET   5
#define MAX_SCORE   99

int main(void) {
    oricos_print_string("score: start\r\n");
    oricos_ui_define(score_def);
    unsigned char score = 0;
    oricos_ctl_set_value(FIELD_ID, score);

    for (;;) {
        unsigned char msg = oricos_main_loop();
        if (msg == MSG_CONTROL) {
            unsigned char id = oricos_msg_id();
            if (id == BTN_PLUS1) {
                if (score < MAX_SCORE) score++;
            } else if (id == BTN_PLUS10) {
                score = (score + 10 > MAX_SCORE) ? MAX_SCORE : score + 10;
            } else if (id == BTN_RESET) {
                score = 0;
            }
            oricos_ctl_set_value(FIELD_ID, score);
        } else if (msg == MSG_MENU) {
            unsigned char packed = oricos_msg_id();
            if (packed == 0xFF) continue;     /* bar-click, ignorer */
            /* item 0 du menu 0 = Quit */
            if (packed == 0x00) break;
        } else if (msg == MSG_CLOSE) {
            break;
        }
    }
    oricos_print_string("score: bye\r\n");
    return 0;
}
