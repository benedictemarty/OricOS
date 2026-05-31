#!/bin/bash
# SPDX-License-Identifier: EUPL-1.2
# install.sh — Installe le target mos-oricos dans llvm-mos
#
# Usage : ./install.sh [LLVM_MOS_DIR]
# Par défaut : LLVM_MOS_DIR=$HOME/llvm-mos

set -e
LLVM_MOS="${1:-$HOME/llvm-mos}"
SDK_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$LLVM_MOS/bin/clang" ]; then
    echo "ERREUR : clang non trouvé dans $LLVM_MOS/bin/" >&2
    echo "Installez llvm-mos depuis https://github.com/llvm-mos/llvm-mos-sdk" >&2
    exit 1
fi

echo "Installation target mos-oricos dans $LLVM_MOS..."

# Platform files
mkdir -p "$LLVM_MOS/mos-platform/oricos/lib" \
         "$LLVM_MOS/mos-platform/oricos/include"

# Config clang
cp "$SDK_DIR/mos-oricos.cfg" "$LLVM_MOS/bin/mos-oricos.cfg"

# Linker script (copié ; crt0.S source → compile puis install)
cp "$SDK_DIR/lib/link.ld" "$LLVM_MOS/mos-platform/oricos/lib/link.ld"

# Header OricOS API
cp "$SDK_DIR/include/oricos.h" "$LLVM_MOS/mos-platform/oricos/include/oricos.h"

# Compiler crt0.S → crt0.o (laissé tel quel + dans libcrt0.a).
#
# ⚠️ CRITIQUE — NE PAS supprimer crt0.o. Le driver clang `--target=mos-*`
# auto-ajoute `-l:crt0.o` au link, qui cherche LITTÉRALEMENT le fichier
# `crt0.o` dans le path de search. Sans notre fichier dans oricos/lib/,
# le linker retombe sur `common/lib/crt0.o` qui contient SON propre
# `.call_main: jsr main`. Concaténé avec NOTRE `.call_main: jsr main`
# (via -lcrt0 → libcrt0.a), le binaire app contient **2 jsr main
# back-to-back** → main() s'exécute deux fois !
#
# Symptôme observé 2026-05-31 : hello_c se ré-exécutait après son
# SYS_EXIT, le 2e run se bloquait sur SYS_READ_CHAR (le test avait
# déjà délivré la touche pour le 1er run) → CPU stuck en WAI →
# 6 tests Phosphoric fail.
#
# Fix : conserver crt0.o en oricos/lib/ pour que `-l:crt0.o`
# (auto-ajouté) trouve LA NÔTRE. La libcrt0.a (via `-lcrt0` user)
# devient redondante mais inoffensive (mêmes symboles).
echo "Compilation crt0.S..."
"$LLVM_MOS/bin/clang" --target=mos-oricos -fno-lto \
    -c "$SDK_DIR/lib/crt0.S" \
    -o "$LLVM_MOS/mos-platform/oricos/lib/crt0.o"
"$LLVM_MOS/bin/llvm-ar" rcs \
    "$LLVM_MOS/mos-platform/oricos/lib/libcrt0.a" \
    "$LLVM_MOS/mos-platform/oricos/lib/crt0.o"
# ⚠️ NE PAS rm crt0.o — cf. commentaire ci-dessus.

# Compiler liboricos.a (libc minimale : printf, malloc, string)
echo "Compilation liboricos.a..."
CFLAGS_LIB="--target=mos-oricos -mcpu=mosw65816 -fno-lto \
    -isystem $SDK_DIR/include \
    -isystem $LLVM_MOS/mos-platform/common/include"

"$LLVM_MOS/bin/clang" $CFLAGS_LIB \
    -c "$SDK_DIR/lib/liboricos.c" \
    -o "$LLVM_MOS/mos-platform/oricos/lib/liboricos.o"
"$LLVM_MOS/bin/clang" $CFLAGS_LIB \
    -c "$SDK_DIR/lib/malloc.c" \
    -o "$LLVM_MOS/mos-platform/oricos/lib/malloc.o"
"$LLVM_MOS/bin/llvm-ar" rcs \
    "$LLVM_MOS/mos-platform/oricos/lib/liboricos.a" \
    "$LLVM_MOS/mos-platform/oricos/lib/liboricos.o" \
    "$LLVM_MOS/mos-platform/oricos/lib/malloc.o"
rm "$LLVM_MOS/mos-platform/oricos/lib/liboricos.o" \
   "$LLVM_MOS/mos-platform/oricos/lib/malloc.o"

echo "Installation terminée."
echo "Utilisation :"
echo "  clang --target=mos-oricos app.c /path/liboricos.a -lcrt0 -o app.bin"
