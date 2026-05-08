# Build app hello : asm → flat binary → bundle .oosobj

BUILD := build
APP := hello

all: $(BUILD)/$(APP).oosobj

$(BUILD)/$(APP).bin: $(APP).s $(APP).cfg
	@mkdir -p $(BUILD)
	ca65 --cpu 65816 -o $(BUILD)/$(APP).o $(APP).s
	ld65 -C $(APP).cfg -o $(BUILD)/$(APP).bin $(BUILD)/$(APP).o

$(BUILD)/$(APP).oosobj: $(BUILD)/$(APP).bin ../../tools/oricos-bundle.py
	python3 ../../tools/oricos-bundle.py $(BUILD)/$(APP).bin $(BUILD)/$(APP).oosobj

clean:
	rm -rf $(BUILD)

.PHONY: all clean
