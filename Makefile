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

# Modules .include'és dans kernel.s : prérequis de la recompilation.
# Sans ça, éditer un module ne déclenche pas de rebuild → kernel obsolète
# testé silencieusement.
KERNEL_DEPS = $(wildcard kernel/modules/*.s)

APPS        = hello hello_c win_hello gui_demo view_demo ctl_demo clock score file_select
APP_BUNDLES = apps/hello/build/hello.oosobj \
              apps/hello_c/build/hello.oos \
              apps/win_hello/build/win.oos \
              apps/gui_demo/build/gui.oos \
              apps/view_demo/build/view.oos \
              apps/ctl_demo/build/ctl.oos \
              apps/clock/build/clock.oos \
              apps/score/build/score.oos \
              apps/file_select/build/fileselect.oos

.PHONY: all clean info apps audit-smart test-libc-fmt test-libc-calloc $(APPS)

all: apps audit-smart $(KERNEL_BIN)

# Détecte les labels suspects type bug taskbar 2026-05-30 (cf. CLAUDE.md §5
# « `.smart` ca65 — convention obligatoire »). Exit 1 sur suspect → bloque
# le build. À lancer aussi en local avant commit.
audit-smart:
	@python3 tools/tests/test_audit_smart.py >/dev/null \
	  || { echo "audit-smart: corpus de regression FAILED — voir tools/tests/test_audit_smart.py"; exit 1; }
	@python3 tools/audit-smart.py kernel

# Test natif (host gcc) du formatage liboricos — verrouille le fix %u
# (bug : itoa((int)v, …, 10) → "-25536" pour 40000 en env int=16-bit).
test-libc-fmt:
	@cd tools/oricos-sdk/lib && gcc -std=c99 -Wall -Wextra -Wno-unused-function \
	  -Itests/stubs -o /tmp/test_liboricos_fmt tests/test_liboricos_fmt.c \
	  && /tmp/test_liboricos_fmt 2>&1 \
	  | tail -1 \
	  || { echo "test-libc-fmt: FAILED"; exit 1; }

# Test natif du fix overflow calloc (bug : nmemb*size wrap en 16-bit).
test-libc-calloc:
	@cd tools/oricos-sdk/lib && gcc -std=c99 -Wall -Wextra -Wno-unused-function \
	  -o /tmp/test_liboricos_calloc tests/test_liboricos_calloc.c \
	  && /tmp/test_liboricos_calloc 2>&1 \
	  | tail -1 \
	  || { echo "test-libc-calloc: FAILED"; exit 1; }

apps: $(APPS)

$(APPS):
	$(MAKE) -C apps/$@

$(BUILD):
	@mkdir -p $(BUILD)

$(KERNEL_O): $(KERNEL_SRC) $(KERNEL_DEPS) $(APP_BUNDLES) | $(BUILD)
	$(AS) $(ASFLAGS) -l $(KERNEL_LST) -o $@ $<

$(KERNEL_BIN): $(KERNEL_O) $(KERNEL_CFG)
	$(LD) -C $(KERNEL_CFG) -m $(KERNEL_MAP) -Ln $(BUILD)/kernel.lbl -o $@ $<
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
