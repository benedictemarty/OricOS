/* SPDX-License-Identifier: EUPL-1.2
 * Copyright (c) 2026 Bénédicte Marty
 *
 * oricos.h — API publique OricOS pour applications userland C (ADR-17 v1)
 *
 * Utilisation :
 *   #include <oricos.h>
 *   int main(void) { oricos_print_char('A'); return 0; }
 *
 * Compilateur : llvm-mos target mos-oricos (ADR-05 v2)
 *   clang --target=mos-oricos hello.c -lcrt0 -o hello.bin
 *
 * Mode CPU : 65C816 mode N, M=1, X=1 (8-bit registers).
 * Convention : A = syscall num, X/Y = args, retour A (0xFF = erreur).
 *
 * Note asm : les numéros de syscall sont littéraux dans le template asm
 * via stringification du #define (macro _ORICOS_LDA_SYS), et non passés via
 * contrainte "i" + %[sym]. Avec llvm-mos LTO, la contrainte "i" peut être
 * hoistée en variable ZP (a5 $N) qui écrase la ZP kernel — la stringification
 * force LDA immediate (a9) tout en gardant les #define SYS_* comme source
 * unique de vérité (pas de numéro magique dupliqué dans l'asm).
 */

#ifndef ORICOS_H
#define ORICOS_H

#include <stdint.h>

/* ── Numéros de syscalls (ADR-17) ────────────────────────────────── */
#define SYS_PRINT_CHAR      0x01
#define SYS_PRINT_STRING    0x02
#define SYS_READ_CHAR       0x03
#define SYS_EXIT            0x04
#define SYS_YIELD           0x05
#define SYS_GET_KEY         0x06
#define SYS_FAT_OPEN        0x07
#define SYS_FAT_READ        0x08
#define SYS_FAT_CLOSE       0x09
#define SYS_PANIC           0x0A
#define SYS_ALLOC_BANK      0x0B
#define SYS_FREE_BANK       0x0C
#define SYS_GFX_CLEAR       0x0D
#define SYS_GFX_FILL_RECT   0x0E
#define SYS_GFX_BLIT        0x0F
#define SYS_GFX_LINE        0x10
#define SYS_GFX_TEXT        0x11
#define SYS_SLEEP_MS        0x12
#define SYS_WIN_CREATE      0x13
#define SYS_WIN_FLUSH       0x14
#define SYS_EVENT_AVAIL     0x15
#define SYS_GET_NEXT_EVENT  0x16
#define SYS_MAIN_LOOP       0x17
#define SYS_UI_DEFINE       0x18
#define SYS_DO_DLGBOX       0x19
#define SYS_ALERT           0x1A
#define SYS_CTL_GET_VALUE   0x1B
#define SYS_CTL_SET_VALUE   0x1C
#define SYS_GET_TICKS       0x1D

/* ── Messages du MainLoop (SP-3.n) ───────────────────────────────── */
#define MSG_NULL            0
#define MSG_KEY             1
#define MSG_CONTENT         2
#define MSG_CLOSE           3
#define MSG_MENU            4
#define MSG_CONTROL         5

/* ── Tags table GenUI (SYS_UI_DEFINE) ────────────────────────────── */
#define GU_END              0
#define GU_WINDOW           1   /* + x16 y16 w16 h16 */
#define GU_TITLE            2   /* + ptr16 (AVANT GU_WINDOW) */
#define GU_BUTTON           3   /* + relx16 rely16 relw16 relh16 */
#define GU_VIEW             4   /* + relx16 rely16 relw16 relh16 max8 (GenView) */
#define GU_CHECK            5   /* + relx16 rely16 relw16 relh16 value8 (checkbox) */
#define GU_SCROLL_V         6   /* + relx16 rely16 relw16 relh16 max8 (ascenseur V) */
#define GU_SCROLL_H         7   /* + relx16 rely16 relw16 relh16 max8 (ascenseur H) */
#define GU_RADIO            8   /* + relx16 rely16 relw16 relh16 value8 group8 (radio) */
#define GU_TEXT             9   /* + relx16 rely16 relw16 relh16 maxlen8 (champ texte) */

/* ADR-29 Étape 2 : hint déclaratif (alignement GeoWorks GenValueClass).
 * Placé AVANT un widget value-type (GU_SCROLL_V/H, GU_VIEW) pour basculer ce
 * widget seul en mode IMMEDIATE (notification continue pendant le drag).
 * Default sans hint = DELAYED (notification UNIQUE à la release). Tag seul,
 * pas de payload. À utiliser avec parcimonie (par défaut DELAYED protège
 * l'app contre la saturation par flux d'events). Aligné
 * HINT_VALUE_IMMEDIATE_DRAG_NOTIFICATION de PC/GEOS gValueC.def. */
#define GU_HINT_IMMEDIATE_DRAG_NOTIFY  10

/* ── Types d'alerte (SYS_ALERT) ──────────────────────────────────── */
#define ALERT_OK            0
#define ALERT_OKCANCEL      1
#define ALERT_YESNO         2

/* ── Sentinelle d'erreur ─────────────────────────────────────────── */
#define ORICOS_ERR          ((uint8_t)0xFF)
#define ORICOS_OK           ((uint8_t)0x00)

/* ── Macro COP #$AA : appel noyau (ADR-13) ───────────────────────── */
#define _ORICOS_COP() __asm__ volatile(".byte 0x02, 0xAA" ::: "a", "x", "y")

/* Stringification : transforme le #define SYS_* (ex. 0x01) en "lda #0x01\n".
 * _ORICOS_STR force l'expansion de la macro avant le #. Le résultat est un
 * littéral immédiat dans le template asm → LDA #imm (a9), jamais hoistable
 * par LTO, tout en gardant SYS_* comme source unique de vérité. */
#define _ORICOS_STR2(x) #x
#define _ORICOS_STR(x)  _ORICOS_STR2(x)
#define _ORICOS_LDA_SYS(n) "lda #" _ORICOS_STR(n) "\n"

/* ── Primitives de sortie console ────────────────────────────────── */

static __attribute__((always_inline)) inline
void oricos_print_char(uint8_t c) {
    __asm__ volatile (
        _ORICOS_LDA_SYS(SYS_PRINT_CHAR)
        "ldx %[ch]\n"
        ".byte 0x02, 0xAA\n"
        :
        : [ch] "r" (c)
        : "a", "x"
    );
}

static __attribute__((always_inline)) inline
void oricos_print_string(const char *s) {
    for (; *s; ++s)
        oricos_print_char((uint8_t)*s);
}

/* ── Contrôle du processus ───────────────────────────────────────── */

static __attribute__((always_inline)) inline
void oricos_yield(void) {
    __asm__ volatile (
        _ORICOS_LDA_SYS(SYS_YIELD)
        ".byte 0x02, 0xAA\n"
        :
        :
        : "a"
    );
}

static __attribute__((noreturn, always_inline)) inline
void oricos_exit(uint8_t code) {
    __asm__ volatile (
        _ORICOS_LDA_SYS(SYS_EXIT)
        "ldx %[code]\n"
        ".byte 0x02, 0xAA\n"
        :
        : [code] "r" (code)
        : "a", "x"
    );
    __builtin_unreachable();
}

/* ── Lecture clavier ─────────────────────────────────────────────── */

/* Non-bloquant : retourne 0 si pas de touche. */
static __attribute__((always_inline)) inline
uint8_t oricos_get_key(void) {
    uint8_t key;
    __asm__ volatile (
        _ORICOS_LDA_SYS(SYS_GET_KEY)
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (key)
        :
        : "a"
    );
    return key;
}

/* Bloquant : attend une touche. */
static __attribute__((always_inline)) inline
uint8_t oricos_read_char(void) {
    uint8_t key;
    __asm__ volatile (
        _ORICOS_LDA_SYS(SYS_READ_CHAR)
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (key)
        :
        : "a"
    );
    return key;
}

/* ── Allocation mémoire (banks) ──────────────────────────────────── */

/* Retourne le numéro du bank alloué, ou ORICOS_ERR si plus de banks. */
static __attribute__((always_inline)) inline
uint8_t oricos_alloc_bank(void) {
    uint8_t bank;
    __asm__ volatile (
        _ORICOS_LDA_SYS(SYS_ALLOC_BANK)
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (bank)
        :
        : "a"
    );
    return bank;
}

static __attribute__((always_inline)) inline
void oricos_free_bank(uint8_t bank) {
    __asm__ volatile (
        _ORICOS_LDA_SYS(SYS_FREE_BANK)
        "ldx %[b]\n"
        ".byte 0x02, 0xAA\n"
        :
        : [b] "r" (bank)
        : "a", "x"
    );
}

/* ── GUI : fenêtres et dessin fenêtré (SP-3.m) ───────────────────── */

/* SYS_WIN_CREATE : crée une fenêtre {x,y,w,h} (coords écran XVGA, 16-bit) et
 * retourne son handle (slot 0..7), ou ORICOS_ERR si plus de slots. La fenêtre
 * prend le focus (son propriétaire reçoit le clavier). Args passés via le bloc
 * ZP syscall réservé $D0-$D7 (ABI ADR-17, D=0 garanti pour les apps). */
static __attribute__((always_inline)) inline
uint8_t oricos_win_create(uint16_t x, uint16_t y, uint16_t w, uint16_t h) {
    uint8_t handle;
    __asm__ volatile (
        "lda %[xl]\n sta $D0\n lda %[xh]\n sta $D1\n"
        "lda %[yl]\n sta $D2\n lda %[yh]\n sta $D3\n"
        "lda %[wl]\n sta $D4\n lda %[wh]\n sta $D5\n"
        "lda %[hl]\n sta $D6\n lda %[hh]\n sta $D7\n"
        _ORICOS_LDA_SYS(SYS_WIN_CREATE)
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (handle)
        : [xl] "r" ((uint8_t)x),  [xh] "r" ((uint8_t)(x >> 8)),
          [yl] "r" ((uint8_t)y),  [yh] "r" ((uint8_t)(y >> 8)),
          [wl] "r" ((uint8_t)w),  [wh] "r" ((uint8_t)(w >> 8)),
          [hl] "r" ((uint8_t)h),  [hh] "r" ((uint8_t)(h >> 8))
        : "a"
    );
    return handle;
}

/* SYS_GFX_FILL_RECT : remplit un rectangle en coordonnées LOCALES à la fenêtre
 * du caller (le kernel résout le backing store via WM_OWNER). L'app ignore
 * l'adresse physique XVGA (modèle GrafPort). Coords/dimensions 8-bit (v0.1).
 * Args via la ZP gfx kernel $73-$78. color : index palette 0..15. */
static __attribute__((always_inline)) inline
void oricos_gfx_fill_rect(uint8_t x, uint8_t y, uint8_t w, uint8_t h, uint8_t color) {
    __asm__ volatile (
        "lda %[x]\n sta $73\n"
        "lda %[y]\n sta $74\n"
        "lda %[w]\n sta $76\n"
        "lda %[h]\n sta $77\n"
        "lda %[c]\n sta $78\n"
        _ORICOS_LDA_SYS(SYS_GFX_FILL_RECT)
        ".byte 0x02, 0xAA\n"
        :
        : [x] "r" (x), [y] "r" (y), [w] "r" (w), [h] "r" (h), [c] "r" (color)
        : "a"
    );
}

/* SYS_WIN_FLUSH : composite les backing stores des fenêtres sur le framebuffer
 * XVGA. À appeler après les SYS_GFX_* pour rendre le dessin visible. */
static __attribute__((always_inline)) inline
void oricos_win_flush(void) {
    __asm__ volatile (
        _ORICOS_LDA_SYS(SYS_WIN_FLUSH)
        ".byte 0x02, 0xAA\n"
        :
        :
        : "a"
    );
}

/* ── GUI déclarative + événementielle (SP-3.n) ───────────────────── */

/* SYS_UI_DEFINE : construit une fenêtre (+ contrôles) depuis une table GenUI
 * (const dans le bank de l'app). Retourne le handle de la fenêtre. Le bank est
 * pris du PBR courant (phk/pla) → la table est lue dans le bank de l'app. */
static __attribute__((always_inline)) inline
uint8_t oricos_ui_define(const void *table) {
    uint8_t handle;
    __asm__ volatile (
        "lda %[lo]\n sta $D0\n"
        "lda %[hi]\n sta $D1\n"
        "phk\n pla\n sta $D2\n"   /* bank courant = bank de l'app */
        _ORICOS_LDA_SYS(SYS_UI_DEFINE)
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (handle)
        : [lo] "r" ((uint8_t)(unsigned)table), [hi] "r" ((uint8_t)((unsigned)table >> 8))
        : "a"
    );
    return handle;
}

/* SYS_MAIN_LOOP : bloque jusqu'à un message sémantique. Retourne MSG_* (le
 * détail — id contrôle/fenêtre, keycode — est dans le bloc ZP $D0-$DF). */
static __attribute__((always_inline)) inline
uint8_t oricos_main_loop(void) {
    uint8_t msg;
    __asm__ volatile (
        _ORICOS_LDA_SYS(SYS_MAIN_LOOP)
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (msg)
        :
        : "a"
    );
    return msg;
}

/* SYS_ALERT : alerte pré-câblée (ALERT_OK / ALERT_OKCANCEL / ALERT_YESNO).
 * Retourne 1 (bouton gauche : OK/Yes) ou 0 (droite : Cancel/No). Modal. */
static __attribute__((always_inline)) inline
uint8_t oricos_alert(uint8_t type) {
    uint8_t res;
    __asm__ volatile (
        "ldx %[t]\n"
        _ORICOS_LDA_SYS(SYS_ALERT)
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (res)
        : [t] "r" (type)
        : "a", "x"
    );
    return res;
}

/* SYS_DO_DLGBOX : dialogue modal défini par une command table DB_* (const
 * dans le bank de l'app). Retourne 1 (OK) ou 0 (Cancel). */
static __attribute__((always_inline)) inline
uint8_t oricos_do_dlgbox(const void *table) {
    uint8_t res;
    __asm__ volatile (
        "lda %[lo]\n sta $D0\n"
        "lda %[hi]\n sta $D1\n"
        "phk\n pla\n sta $D2\n"
        _ORICOS_LDA_SYS(SYS_DO_DLGBOX)
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (res)
        : [lo] "r" ((uint8_t)(unsigned)table), [hi] "r" ((uint8_t)((unsigned)table >> 8))
        : "a"
    );
    return res;
}

/* SYS_CTL_GET_VALUE : valeur d'un contrôle (checkbox 0/1, scroll/view offset). */
static __attribute__((always_inline)) inline
uint8_t oricos_ctl_get_value(uint8_t id) {
    uint8_t v;
    __asm__ volatile (
        "ldx %[id]\n"
        _ORICOS_LDA_SYS(SYS_CTL_GET_VALUE)
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (v)
        : [id] "r" (id)
        : "a", "x"
    );
    return v;
}

/* Détail du dernier message MainLoop (bloc ZP $DA) : id contrôle pour MSG_CONTROL,
 * id fenêtre pour MSG_CONTENT/MSG_CLOSE. À lire juste après oricos_main_loop(). */
static __attribute__((always_inline)) inline
uint8_t oricos_msg_id(void) {
    uint8_t v;
    __asm__ volatile (
        "lda $DA\n"
        "sta %[out]\n"
        : [out] "=r" (v)
        :
        : "a"
    );
    return v;
}

/* SYS_GET_TICKS : compteur de ticks scheduler 8-bit (libre, wrap à 256). Pour
 * mesurer un délai sans souci de wrap : (uint8_t)(oricos_get_ticks() - t0) >= K. */
static __attribute__((always_inline)) inline
uint8_t oricos_get_ticks(void) {
    uint8_t t;
    __asm__ volatile (
        _ORICOS_LDA_SYS(SYS_GET_TICKS)
        ".byte 0x02, 0xAA\n"
        "sta %[out]\n"
        : [out] "=r" (t)
        :
        : "a", "x", "y"   /* le COP ne préserve pas X/Y (cf. kernel_cop_handler) */
    );
    return t;
}

#endif /* ORICOS_H */
