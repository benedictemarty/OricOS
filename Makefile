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

# ── SDK userland (liboricos.a + crt0 + header + linker script) ─────
# install.sh recompile liboricos.a depuis le source SDK et l'installe
# dans $(LLVM_MOS)/mos-platform/oricos/. Sans ce câblage, le SDK source
# et la .a installée peuvent diverger silencieusement (les apps linkent
# contre une .a fossile, les tests passent par erreur) — c'est ce qui a
# causé la régression diagnostiquée 2026-05-31 (cf. CHANGELOG).
#
# Stamp file : recommence install.sh ssi un fichier SDK source plus
# récent. La marque est gitignorée. Les apps dépendent du stamp → make
# garantit que l'image SDK installée correspond au source courant.
LLVM_MOS    ?= $(HOME)/llvm-mos
SDK_DIR     = tools/oricos-sdk
SDK_SRCS    = $(SDK_DIR)/include/oricos.h \
              $(SDK_DIR)/lib/liboricos.c \
              $(SDK_DIR)/lib/malloc.c \
              $(SDK_DIR)/lib/crt0.S \
              $(SDK_DIR)/lib/link.ld \
              $(SDK_DIR)/mos-oricos.cfg \
              $(SDK_DIR)/install.sh
SDK_STAMP   = $(SDK_DIR)/.installed-stamp

.PHONY: all clean info apps audit-smart audit-rep-x test-libc-fmt test-libc-calloc sdk-install $(APPS)

all: $(SDK_STAMP) apps audit-smart audit-rep-x $(KERNEL_BIN)

# Détecte les labels suspects type bug taskbar 2026-05-30 (cf. CLAUDE.md §5
# « `.smart` ca65 — convention obligatoire »). Exit 1 sur suspect → bloque
# le build. À lancer aussi en local avant commit.
audit-smart:
	@python3 tools/tests/test_audit_smart.py >/dev/null \
	  || { echo "audit-smart: corpus de regression FAILED — voir tools/tests/test_audit_smart.py"; exit 1; }
	@python3 tools/audit-smart.py kernel

# IRQ_CONFORMITE §3.3 A : détecte les nouveaux sites `rep #$10/#$30` (X 16-bit)
# qui pourraient corrompre Y.hi si T1 fire pendant. Compte vs baseline auditée
# (cf. handlers.s tableau du §3.3 A). Échoue si nouveau site non documenté.
AUDIT_REP_X_BASELINE := 20
audit-rep-x:
	@count=$$(grep -rnE 'rep #\$$[13][0-9a-fA-F]' kernel/modules/ kernel/kernel.s 2>/dev/null | grep -v '\.assert\|asize\|isize' | grep -v ':;' | wc -l); \
	if [ "$$count" != "$(AUDIT_REP_X_BASELINE)" ]; then \
	    echo "audit-rep-x : $$count sites rep #\$$1x/#\$$3x trouvés (baseline = $(AUDIT_REP_X_BASELINE))."; \
	    echo "  → nouveau site potentiellement à risque IRQ_CONFORMITE §3.3 A."; \
	    echo "  → auditer + annoter en commentaire, puis MAJ AUDIT_REP_X_BASELINE dans Makefile."; \
	    grep -rnE 'rep #\$$[13][0-9a-fA-F]' kernel/modules/ kernel/kernel.s 2>/dev/null | grep -v '\.assert\|asize\|isize' | grep -v ':;'; \
	    exit 1; \
	else \
	    echo "audit-rep-x : $$count sites, conforme baseline (tous annotés handlers.s §3.3 A)."; \
	fi

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

# ── SDK install : refresh liboricos.a + crt0 + header si source change ──
# La cible `sdk-install` force la réinstallation. Le stamp est utilisé
# en interne pour gater les apps. Si LLVM_MOS introuvable, install.sh
# error-out proprement.
sdk-install:
	@bash $(SDK_DIR)/install.sh $(LLVM_MOS)
	@touch $(SDK_STAMP)

$(SDK_STAMP): $(SDK_SRCS)
	@bash $(SDK_DIR)/install.sh $(LLVM_MOS)
	@touch $@
	@# Les Makefile sous apps/ ne déclarent PAS la .a installée comme dep
	@# de leur .bin. Pour garantir que les apps soient recompilées contre
	@# la nouvelle liboricos.a, on supprime ici leurs artefacts → le
	@# prochain `make apps` les régénère. Sans ça, divergence garantie
	@# entre SDK source et apps linkées (cf. CHANGELOG 2026-05-31 P0).
	@rm -f apps/*/build/*.bin apps/*/build/*.oos apps/*/build/*.oosobj

apps: $(SDK_STAMP) $(APPS)

$(APPS):
	$(MAKE) -C apps/$@

$(BUILD):
	@mkdir -p $(BUILD)

# SP-3.p F.1 : table de largeurs de fonte (proportionnel), générée depuis
# le charset XVGA. Consommée par tk.s (.incbin data/font_widths.bin).
data/font_widths.bin: data/charset-xvga.bin tools/gen-font-widths.py
	python3 tools/gen-font-widths.py

$(KERNEL_O): $(KERNEL_SRC) $(KERNEL_DEPS) $(APP_BUNDLES) data/font_widths.bin | $(BUILD)
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
