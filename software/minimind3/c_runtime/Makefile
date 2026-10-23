.DEFAULT_GOAL := all
PRECISION ?= fp32
MODEL_STORAGE ?= embed
MAX_SEQ_LEN ?= 2048
MAX_NEW_TOKENS ?= 256
CROSS_COMPILE ?=
ifeq ($(origin CC),default)
CC := $(CROSS_COMPILE)gcc
endif
CC ?= $(CROSS_COMPILE)gcc
PYTHON ?= python3
CFLAGS ?= -O3 -Wall -Wextra -Wpedantic
CPPFLAGS ?=
LDFLAGS ?=
ifeq ($(filter $(PRECISION),fp32 w8a16_int),)
$(error Unsupported PRECISION=$(PRECISION); supported: fp32 w8a16_int)
endif
ifeq ($(filter $(MODEL_STORAGE),embed file),)
$(error MODEL_STORAGE must be embed or file)
endif
ifeq ($(PRECISION),fp32)
LDLIBS ?= -lm
CORE := weights tokenizer platform_host backend_cpu model
MODEL_ASSET := assets/model_fp32.bin
else
LDLIBS ?=
CORE := integer_io tokenizer platform_integer integer_math integer_ops integer_model
MODEL_ASSET := assets/model_w8a16_int.bin
endif
CONFIG_ID := $(shell printf '%s' '$(CC)|$(CFLAGS)|$(CPPFLAGS)|$(LDFLAGS)|$(LDLIBS)' | cksum | cut -d' ' -f1)
BUILD := build/$(MODEL_STORAGE)-$(PRECISION)-s$(MAX_SEQ_LEN)-g$(MAX_NEW_TOKENS)-$(CONFIG_ID)
BIN := $(BUILD)/minimind3
OBJECTS := $(addprefix $(BUILD)/,$(addsuffix .o,$(CORE)))
DEFINES := -DMAX_SEQ_LEN=$(MAX_SEQ_LEN) -DMAX_NEW_TOKENS=$(MAX_NEW_TOKENS)
ifeq ($(PRECISION),w8a16_int)
DEFINES += -DMM3_INTEGER_RUNTIME
endif
ifeq ($(MODEL_STORAGE),embed)
DEFINES += -DMODEL_EMBED
OBJECTS += $(BUILD)/params.o
endif
INCLUDES := -Iinclude -Iassets
FIXED_FLAGS := -std=c11 -fno-fast-math -ffp-contract=off
.PHONY: all run export export-integer hex clean path
all: $(BIN)
	ln -sfn '$(BIN)' minimind3.elf
	@printf 'Executable: ./minimind3.elf (%s)\n' '$(PRECISION)'
path:
	@printf '%s\n' '$(BIN)'
run: $(BIN)
	$(BIN) $(ARGS)
$(BUILD):
	mkdir -p $@
assets/model_fp32.bin assets/tokenizer.bin assets/model_config.h:
	@echo 'Missing FP32/tokenizer parameters. Run make export.' >&2
	@exit 1
assets/model_w8a16_int.bin:
	@echo 'Missing integer parameters. Run make export-integer.' >&2
	@exit 1
$(BUILD)/%.o: src/%.c include/mm3.h include/integer.h assets/model_config.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(INCLUDES) $(DEFINES) $(CFLAGS) $(FIXED_FLAGS) -MMD -MP -c $< -o $@
$(BUILD)/main.o: main.c integer_main.inc include/mm3.h include/integer.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(INCLUDES) $(DEFINES) $(CFLAGS) $(FIXED_FLAGS) -MMD -MP -c $< -o $@
$(BUILD)/params.S: $(MODEL_ASSET) assets/tokenizer.bin | $(BUILD)
	@printf '%s\n' '.section .rodata.mm3,"a"' '.balign 64' '.global mm3_model_start, mm3_model_end' 'mm3_model_start:' '.incbin "$(abspath $(MODEL_ASSET))"' 'mm3_model_end:' '.balign 64' '.global mm3_tokenizer_start, mm3_tokenizer_end' 'mm3_tokenizer_start:' '.incbin "$(abspath assets/tokenizer.bin)"' 'mm3_tokenizer_end:' '.section .note.GNU-stack,"",@progbits' > $@
$(BUILD)/params.o: $(BUILD)/params.S
	$(CC) $(CPPFLAGS) -c $< -o $@
$(BIN): $(BUILD)/main.o $(OBJECTS)
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o $@
export:
	$(PYTHON) tools/export.py
export-integer: assets/model_fp32.bin
	$(PYTHON) tools/export_integer.py --capacity $(MAX_SEQ_LEN)
$(BUILD)/tohex: tools/tohex.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(FIXED_FLAGS) $< -o $@
hex: $(BUILD)/tohex $(MODEL_ASSET) assets/tokenizer.bin
	$(BUILD)/tohex $(MODEL_ASSET) $(MODEL_ASSET:.bin=.hex)
	$(BUILD)/tohex assets/tokenizer.bin assets/tokenizer.hex
clean:
	rm -rf build
	rm -f minimind3.elf
-include $(wildcard $(BUILD)/*.d)
