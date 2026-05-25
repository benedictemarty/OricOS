# SPDX-License-Identifier: EUPL-1.2
# Makefile — app win_hello OricOS (SP-3.m G.6 : démo fenêtrée C)

LLVM_MOS   ?= $(HOME)/llvm-mos
SDK_DIR    := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))../../tools/oricos-sdk
BUILD      := build

CLANG      := $(LLVM_MOS)/bin/clang
BUNDLE     := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))../../tools/oricos-bundle.py
PYTHON     := python3

TARGET     := --target=mos-oricos
# -I (et non -isystem) pour le SDK : voir apps/hello_c/Makefile (build reproductible).
CFLAGS     := $(TARGET) \
              -I $(SDK_DIR)/include \
              -isystem $(LLVM_MOS)/mos-platform/common/include \
              -L$(LLVM_MOS)/mos-platform/oricos/lib \
              -L$(LLVM_MOS)/mos-platform/common/lib \
              -T $(LLVM_MOS)/mos-platform/oricos/lib/link.ld \
              -mcpu=mosw65816 -flto

.PHONY: all clean

all: $(BUILD)/win.oos

$(BUILD):
	mkdir -p $@

$(BUILD)/win.bin: win.c | $(BUILD)
	$(CLANG) $(CFLAGS) $< -lcrt0 -o $@

$(BUILD)/win.oos: $(BUILD)/win.bin
	$(PYTHON) $(BUNDLE) $< $@

clean:
	rm -rf $(BUILD)
