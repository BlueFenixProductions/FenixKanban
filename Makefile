# FenixKanban Development Makefile
#
# This Makefile wraps the common iOS development commands so you don't have
# to remember xcodebuild invocations and device UUIDs. Override variables on
# the command line as needed, e.g. `make run DEVICE_ID=<uuid>`.

PROJECT       = FenixKanban.xcodeproj
SCHEME        = FenixKanban
SIMULATOR    ?= iPhone 16
DEVICE_ID    ?= BA3D11C6-B4A3-5E64-B65F-231B6E607E0F
BUNDLE_ID     = com.bluefenixproductions.FenixKanban
APP_NAME      = FenixKanban.app
DERIVED_DATA  = $(HOME)/Library/Developer/Xcode/DerivedData
APP_GLOB      = $(DERIVED_DATA)/FenixKanban-*/Build/Products/Debug-iphoneos/$(APP_NAME)

SIM_DEST      = 'platform=iOS Simulator,name=$(SIMULATOR)'
DEVICE_DEST   = 'platform=iOS,id=$(DEVICE_ID)'

.DEFAULT_GOAL := help
.PHONY: help generate build build-device test install launch run clean \
        devices icon fmt

help:
	@echo "FenixKanban development targets:"
	@echo ""
	@echo "  make generate      Regenerate Xcode project from project.yml"
	@echo "  make build         Build for iOS Simulator ($(SIMULATOR))"
	@echo "  make build-device  Build for physical device ($(DEVICE_ID))"
	@echo "  make test          Run unit tests on simulator"
	@echo "  make install       Install built app on device (runs build-device)"
	@echo "  make launch        Launch installed app on device"
	@echo "  make run           build-device + install + launch"
	@echo "  make clean         Clean build products and DerivedData"
	@echo "  make devices       List available physical devices"
	@echo "  make icon          Regenerate app icon from scripts/ sources"
	@echo ""
	@echo "Variables (override with VAR=value):"
	@echo "  SIMULATOR   $(SIMULATOR)"
	@echo "  DEVICE_ID   $(DEVICE_ID)"
	@echo "  BUNDLE_ID   $(BUNDLE_ID)"

generate:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination $(SIM_DEST) build | xcbeautify 2>/dev/null || \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination $(SIM_DEST) build

build-device:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination $(DEVICE_DEST) \
	  -allowProvisioningUpdates build

test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination $(SIM_DEST) test

install: build-device
	@APP=$$(ls -d $(APP_GLOB) 2>/dev/null | head -1); \
	if [ -z "$$APP" ]; then \
	    echo "Error: no built app found at $(APP_GLOB)"; \
	    exit 1; \
	fi; \
	echo "Installing $$APP on device..."; \
	xcrun devicectl device install app --device $(DEVICE_ID) "$$APP"

launch:
	xcrun devicectl device process launch --device $(DEVICE_ID) $(BUNDLE_ID)

run: install launch

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf $(DERIVED_DATA)/FenixKanban-*

devices:
	xcrun devicectl list devices

icon:
	./scripts/generate-icon.sh
