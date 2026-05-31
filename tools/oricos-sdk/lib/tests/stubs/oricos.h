/* Stub minimal d'oricos.h pour les tests natifs (host gcc).
 * Évite l'inline assembly 65816 du SDK réel. Les définitions des stubs
 * sont fournies par le test (test_liboricos_fmt.c).
 */
#ifndef ORICOS_H_STUB
#define ORICOS_H_STUB

#include <stdint.h>
#include <stddef.h>

extern void oricos_print_char(uint8_t c);
extern void oricos_print_string(const char *s);

#endif
