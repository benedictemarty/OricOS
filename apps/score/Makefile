# SPDX-License-Identifier: EUPL-1.2
# Makefile — app score OricOS (ADR-30 capstone : exerce toute la toolbox)

LLVM_MOS   ?= $(HOME)/llvm-mos
SDK_DIR    := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))../../tools/oricos-sdk
BUILD      := build

CLANG      := $(LLVM_MOS)/bin/clang
BUNDLE     := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))../../tools/oricos-bundle.py
PYTHON     := python3

TARGET     := --target=mos-oricos
CFLAGS     := $(TARGET) \
              -I $(SDK_DIR)/include \
              -isystem $(LLVM_MOS)/mos-platform/common/include \
              -L$(LLVM_MOS)/mos-platform/oricos/lib \
              -L$(LLVM_MOS)/mos-platform/common/lib \
              -T $(LLVM_MOS)/mos-platform/oricos/lib/link.ld \
              -mcpu=mosw65816 -flto

.PHONY: all clean

all: $(BUILD)/score.oos

$(BUILD):
	mkdir -p $@

$(BUILD)/score.bin: score.c | $(BUILD)
	$(CLANG) $(CFLAGS) $< -lcrt0 -o $@

$(BUILD)/score.oos: $(BUILD)/score.bin
	$(PYTHON) $(BUNDLE) $< $@

clean:
	rm -rf $(BUILD)
