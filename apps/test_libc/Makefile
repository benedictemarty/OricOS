# SPDX-License-Identifier: EUPL-1.2
# Makefile — app test_libc OricOS (validation TC-libc)

LLVM_MOS   ?= $(HOME)/llvm-mos
SDK_DIR    := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))../../tools/oricos-sdk
BUILD      := build

CLANG      := $(LLVM_MOS)/bin/clang
BUNDLE     := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))../../tools/oricos-bundle.py
PYTHON     := python3

CFLAGS     := --target=mos-oricos \
              -isystem $(SDK_DIR)/include \
              -isystem $(LLVM_MOS)/mos-platform/common/include \
              -L$(LLVM_MOS)/mos-platform/oricos/lib \
              -L$(LLVM_MOS)/mos-platform/common/lib \
              -T $(LLVM_MOS)/mos-platform/oricos/lib/link.ld \
              -mcpu=mosw65816 -flto

LIBS       := $(LLVM_MOS)/mos-platform/oricos/lib/liboricos.a

.PHONY: all clean

all: $(BUILD)/test_libc.oos

$(BUILD):
	mkdir -p $@

$(BUILD)/test_libc.bin: test_libc.c | $(BUILD)
	$(CLANG) $(CFLAGS) $< $(LIBS) -lcrt0 -o $@

$(BUILD)/test_libc.oos: $(BUILD)/test_libc.bin
	$(PYTHON) $(BUNDLE) $< $@

clean:
	rm -rf $(BUILD)
