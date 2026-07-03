# Makefile for the OpenAudio AudioServerPlugIn (HAL driver).
#
# Produces build/OpenAudioDriver.driver, a universal (arm64 + x86_64) .driver
# bundle, ad-hoc codesigned. Install it under /Library/Audio/Plug-Ins/HAL/ via
# scripts/install-driver.sh.
#
# Distribution (scripts/release.sh): pass CODESIGN_IDENTITY="Developer ID
# Application: ..." — that switches on the hardened runtime + secure timestamp
# flags notarization requires. Run `make clean` first when changing identity;
# the bundle is not re-signed if its inputs are unchanged.

BUNDLE_NAME     := OpenAudioDriver
BUILD_DIR       := build
BUNDLE_DIR      := $(BUILD_DIR)/$(BUNDLE_NAME).driver
CONTENTS_DIR    := $(BUNDLE_DIR)/Contents
MACOS_DIR       := $(CONTENTS_DIR)/MacOS

BINARY          := $(MACOS_DIR)/$(BUNDLE_NAME)
PLIST_SRC       := $(BUNDLE_NAME)-Info.plist
PLIST_DST       := $(CONTENTS_DIR)/Info.plist
SOURCES         := Source/OpenAudioDriver.c

CODESIGN_IDENTITY ?= -
ifeq ($(CODESIGN_IDENTITY),-)
CODESIGN_FLAGS  :=
else
CODESIGN_FLAGS  := --timestamp --options runtime
endif

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
	@# Codesign the finished bundle (NF-SE2): ad-hoc by default, Developer ID
	@# (+ hardened runtime & timestamp) when CODESIGN_IDENTITY is set.
	codesign -s "$(CODESIGN_IDENTITY)" --force $(CODESIGN_FLAGS) $(BUNDLE_DIR)

$(BINARY): $(SOURCES)
	@mkdir -p $(MACOS_DIR)
	$(CC) $(CFLAGS) $(SOURCES) $(LDFLAGS) -o $(BINARY)

$(PLIST_DST): $(PLIST_SRC)
	@mkdir -p $(CONTENTS_DIR)
	cp $(PLIST_SRC) $(PLIST_DST)

clean:
	rm -rf $(BUILD_DIR)
