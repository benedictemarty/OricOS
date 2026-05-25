# SPDX-License-Identifier: EUPL-1.2
# Makefile — app hello_c OricOS (TC-poc-hello-c)

LLVM_MOS   ?= $(HOME)/llvm-mos
SDK_DIR    := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))../../tools/oricos-sdk
BUILD      := build

CLANG      := $(LLVM_MOS)/bin/clang
BUNDLE     := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))../../tools/oricos-bundle.py
PYTHON     := python3

TARGET     := --target=mos-oricos
# -I (et non -isystem) pour le SDK : les chemins -I sont cherchés AVANT
# les includes de plateforme (mos-platform/oricos/include) que le driver
# ajoute automatiquement. Sinon le oricos.h plateforme (hors repo, non
# versionné) shadowe le SDK → build non reproductible.
CFLAGS     := $(TARGET) \
              -I $(SDK_DIR)/include \
              -isystem $(LLVM_MOS)/mos-platform/common/include \
              -L$(LLVM_MOS)/mos-platform/oricos/lib \
              -L$(LLVM_MOS)/mos-platform/common/lib \
              -T $(LLVM_MOS)/mos-platform/oricos/lib/link.ld \
              -mcpu=mosw65816 -flto

.PHONY: all clean

all: $(BUILD)/hello.oos

$(BUILD):
	mkdir -p $@

$(BUILD)/hello.bin: hello.c | $(BUILD)
	$(CLANG) $(CFLAGS) $< -lcrt0 -o $@

$(BUILD)/hello.oos: $(BUILD)/hello.bin
	$(PYTHON) $(BUNDLE) $< $@

clean:
	rm -rf $(BUILD)
