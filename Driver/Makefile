# Makefile for the OpenAudio AudioServerPlugIn (HAL driver).
#
# Produces build/OpenAudioDriver.driver, a universal (arm64 + x86_64) .driver
# bundle, ad-hoc codesigned. Install it under /Library/Audio/Plug-Ins/HAL/ via
# scripts/install-driver.sh.

BUNDLE_NAME     := OpenAudioDriver
BUILD_DIR       := build
BUNDLE_DIR      := $(BUILD_DIR)/$(BUNDLE_NAME).driver
CONTENTS_DIR    := $(BUNDLE_DIR)/Contents
MACOS_DIR       := $(CONTENTS_DIR)/MacOS

BINARY          := $(MACOS_DIR)/$(BUNDLE_NAME)
PLIST_SRC       := $(BUNDLE_NAME)-Info.plist
PLIST_DST       := $(CONTENTS_DIR)/Info.plist
SOURCES         := Source/OpenAudioDriver.c

CC              := clang
ARCHS           := -arch arm64 -arch x86_64
MIN_VERSION     := -mmacosx-version-min=14.4
WARNINGS        := -Wall -Wextra
OPT             := -O2
CFLAGS          := $(ARCHS) $(MIN_VERSION) $(WARNINGS) $(OPT) -fno-common
LDFLAGS         := $(ARCHS) $(MIN_VERSION) -bundle \
                   -framework CoreAudio -framework CoreFoundation

.PHONY: all clean

all: $(BUNDLE_DIR)
	@echo "Built $(BUNDLE_DIR)"

$(BUNDLE_DIR): $(BINARY) $(PLIST_DST)
	@# Ad-hoc codesign the finished bundle (F: NF-SE2 minimum).
	codesign -s - --force --deep $(BUNDLE_DIR)

$(BINARY): $(SOURCES)
	@mkdir -p $(MACOS_DIR)
	$(CC) $(CFLAGS) $(SOURCES) $(LDFLAGS) -o $(BINARY)

$(PLIST_DST): $(PLIST_SRC)
	@mkdir -p $(CONTENTS_DIR)
	cp $(PLIST_SRC) $(PLIST_DST)

clean:
	rm -rf $(BUILD_DIR)
