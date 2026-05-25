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

# Compiler crt0.S et créer libcrt0.a
echo "Compilation crt0.S..."
"$LLVM_MOS/bin/clang" --target=mos-oricos -fno-lto \
    -c "$SDK_DIR/lib/crt0.S" \
    -o "$LLVM_MOS/mos-platform/oricos/lib/crt0.o"
"$LLVM_MOS/bin/llvm-ar" rcs \
    "$LLVM_MOS/mos-platform/oricos/lib/libcrt0.a" \
    "$LLVM_MOS/mos-platform/oricos/lib/crt0.o"
rm "$LLVM_MOS/mos-platform/oricos/lib/crt0.o"

echo "Installation terminée."
echo "Utilisation : clang --target=mos-oricos hello.c -lcrt0 -o hello.bin"
