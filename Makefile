# FenixKanban Development Makefile
#
# This Makefile wraps the common iOS development commands so you don't have
# to remember xcodebuild invocations and device UUIDs. Override variables on
# the command line as needed, e.g. `make run DEVICE_ID=<uuid>`.

PROJECT       = FenixKanban.xcodeproj
SCHEME        = FenixKanban
SIMULATOR    ?= iPhone 16
BUNDLE_ID     = com.bluefenixproductions.FenixKanban
APP_NAME      = FenixKanban.app
DERIVED_DATA  = $(HOME)/Library/Developer/Xcode/DerivedData
APP_GLOB      = $(DERIVED_DATA)/FenixKanban-*/Build/Products/Debug-iphoneos/$(APP_NAME)

# Named physical devices (update if device UUIDs change)
SUSANOO       = BA3D11C6-B4A3-5E64-B65F-231B6E607E0F
SHINO         = DAE55153-28D5-5775-B9EF-63D0AC67400F

# Default device for single-device targets (overridable with DEVICE_ID=<uuid>)
DEVICE_ID    ?= $(SUSANOO)

SIM_DEST      = 'platform=iOS Simulator,name=$(SIMULATOR)'
DEVICE_DEST   = 'platform=iOS,id=$(DEVICE_ID)'
GENERIC_DEST  = 'generic/platform=iOS'

.DEFAULT_GOAL := help
.PHONY: help generate build build-device test install launch run \
        run-susanoo run-shino run-all _deploy-one clean devices icon

help:
	@echo "FenixKanban development targets:"
	@echo ""
	@echo "  make generate      Regenerate Xcode project from project.yml"
	@echo "  make build         Build for iOS Simulator ($(SIMULATOR))"
	@echo "  make build-device  Build for physical device (generic iOS)"
	@echo "  make test          Run unit tests on simulator"
	@echo "  make install       Install built app on DEVICE_ID (runs build-device)"
	@echo "  make launch        Launch installed app on DEVICE_ID"
	@echo "  make run           build-device + install + launch on DEVICE_ID"
	@echo ""
	@echo "Multi-device convenience targets:"
	@echo "  make run-susanoo   Deploy to Susanoo (iPhone Air)"
	@echo "  make run-shino     Deploy to Shino (iPhone 13 mini)"
	@echo "  make run-all       Deploy to BOTH Susanoo and Shino"
	@echo ""
	@echo "  make clean         Clean build products and DerivedData"
	@echo "  make devices       List available physical devices"
	@echo "  make icon          Regenerate app icon from scripts/ sources"
	@echo ""
	@echo "Variables (override with VAR=value):"
	@echo "  SIMULATOR   $(SIMULATOR)"
	@echo "  DEVICE_ID   $(DEVICE_ID)"
	@echo "  BUNDLE_ID   $(BUNDLE_ID)"
	@echo ""
	@echo "Named devices:"
	@echo "  SUSANOO     $(SUSANOO)"
	@echo "  SHINO       $(SHINO)"

generate:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination $(SIM_DEST) build | xcbeautify 2>/dev/null || \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination $(SIM_DEST) build

# Use generic iOS destination so the build artifact is reusable across
# multiple connected devices without rebuilding per-device.
build-device:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination $(GENERIC_DEST) \
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
	echo "Installing $$APP on device $(DEVICE_ID)..."; \
	xcrun devicectl device install app --device $(DEVICE_ID) "$$APP"

launch:
	xcrun devicectl device process launch --device $(DEVICE_ID) $(BUNDLE_ID)

run: install launch

# Internal: install+launch on TARGET (assumes build-device already ran).
# Used by run-all to avoid rebuilding between devices.
_deploy-one:
	@APP=$$(ls -d $(APP_GLOB) 2>/dev/null | head -1); \
	if [ -z "$$APP" ]; then \
	    echo "Error: no built app found at $(APP_GLOB)"; \
	    exit 1; \
	fi; \
	echo ""; \
	echo ">> Deploying to $(TARGET)..."; \
	xcrun devicectl device install app --device $(TARGET) "$$APP"; \
	xcrun devicectl device process launch --device $(TARGET) $(BUNDLE_ID)

run-susanoo:
	$(MAKE) run DEVICE_ID=$(SUSANOO)

run-shino:
	$(MAKE) run DEVICE_ID=$(SHINO)

# Build once, deploy to both devices.
run-all: build-device
	$(MAKE) _deploy-one TARGET=$(SUSANOO)
	$(MAKE) _deploy-one TARGET=$(SHINO)

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf $(DERIVED_DATA)/FenixKanban-*

devices:
	xcrun devicectl list devices

icon:
	./scripts/generate-icon.sh
