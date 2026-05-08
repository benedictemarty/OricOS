# OricOS Makefile (Sprint 0)
#
# Build kernel asm 65C816 vers binaire flat.
# Toolchain : ca65 + ld65 (cc65 ≥ 2.19). llvm-mos viendra Sprint 4 pour
# le userland C.

AS      = ca65
LD      = ld65
ASFLAGS = --cpu 65816 -t none

BUILD       = build
KERNEL_BIN  = $(BUILD)/kernel.bin
KERNEL_O    = $(BUILD)/kernel.o
KERNEL_LST  = $(BUILD)/kernel.lst
KERNEL_MAP  = $(BUILD)/kernel.map

KERNEL_SRC  = kernel/kernel.s
KERNEL_CFG  = kernel/kernel.cfg

APPS        = hello
APP_BUNDLES = $(foreach a,$(APPS),apps/$(a)/build/$(a).oosobj)

.PHONY: all clean info apps $(APPS)

all: apps $(KERNEL_BIN)

apps: $(APPS)

$(APPS):
	$(MAKE) -C apps/$@

$(BUILD):
	@mkdir -p $(BUILD)

$(KERNEL_O): $(KERNEL_SRC) $(APP_BUNDLES) | $(BUILD)
	$(AS) $(ASFLAGS) -l $(KERNEL_LST) -o $@ $<

$(KERNEL_BIN): $(KERNEL_O) $(KERNEL_CFG)
	$(LD) -C $(KERNEL_CFG) -m $(KERNEL_MAP) -o $@ $<
	@echo
	@echo "  → $(KERNEL_BIN) ($(shell wc -c < $(KERNEL_BIN) 2>/dev/null) bytes)"

clean:
	rm -rf $(BUILD)
	@for a in $(APPS); do $(MAKE) -C apps/$$a clean; done

info:
	@echo "OricOS build info:"
	@echo "  AS       = $(AS) ($(shell $(AS) --version 2>&1 | head -1))"
	@echo "  LD       = $(LD)"
	@echo "  KERNEL   = $(KERNEL_BIN)"
	@echo "  Target   = bank 1 \$$0200 (cf. docs/MEMORY_MAP.md)"
