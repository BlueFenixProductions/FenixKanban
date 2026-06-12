# FenixKanban Development Makefile
#
# This Makefile wraps the common iOS development commands so you don't have
# to remember xcodebuild invocations and device UUIDs. Override variables on
# the command line as needed, e.g. `make run DEVICE_ID=<uuid>`.
#
# To find a device UDID: plug it in, run `make devices`, and copy the
# Identifier column. Or open Xcode > Window > Devices and Simulators.

PROJECT       = FenixKanban.xcodeproj
SCHEME        = FenixKanban
SIMULATOR    ?= iPhone 17
BUNDLE_ID     = com.bluefenixproductions.FenixKanban
APP_NAME      = FenixKanban.app
DERIVED_DATA  = $(HOME)/Library/Developer/Xcode/DerivedData
APP_GLOB      = $(DERIVED_DATA)/FenixKanban-*/Build/Products/Debug-iphoneos/$(APP_NAME)

# Set these to your physical device UDIDs, e.g.:
#   export DEVICE_1=00008110-001234567890001E
#   export DEVICE_2=00008110-001234567890002E
# Or pass them on the command line: make run-device-1 DEVICE_1=<udid>
DEVICE_1     ?= $(error Set DEVICE_1 to your device UDID (run 'make devices' to list connected devices))
DEVICE_2     ?= $(error Set DEVICE_2 to your device UDID (run 'make devices' to list connected devices))

# Default device for single-device targets (overridable with DEVICE_ID=<uuid>)
DEVICE_ID    ?= $(DEVICE_1)

SIM_DEST      = 'platform=iOS Simulator,name=$(SIMULATOR)'
DEVICE_DEST   = 'platform=iOS,id=$(DEVICE_ID)'
GENERIC_DEST  = 'generic/platform=iOS'

.DEFAULT_GOAL := help
.PHONY: help generate build build-device test integration-test install launch run \
        run-device-1 run-device-2 run-all _deploy-one clean devices icon

help:
	@echo "FenixKanban development targets:"
	@echo ""
	@echo "  make generate      Regenerate Xcode project from project.yml"
	@echo "  make build         Build for iOS Simulator ($(SIMULATOR))"
	@echo "  make build-device  Build for physical device (generic iOS)"
	@echo "  make test          Run unit tests on simulator"
	@echo "  make integration-test  Run live-API tests (loads .env if present)"
	@echo "  make install       Install built app on DEVICE_ID (runs build-device)"
	@echo "  make launch        Launch installed app on DEVICE_ID"
	@echo "  make run           build-device + install + launch on DEVICE_ID"
	@echo ""
	@echo "Multi-device convenience targets:"
	@echo "  make run-device-1  Deploy to DEVICE_1"
	@echo "  make run-device-2  Deploy to DEVICE_2"
	@echo "  make run-all       Deploy to BOTH DEVICE_1 and DEVICE_2"
	@echo ""
	@echo "  make clean         Clean build products and DerivedData"
	@echo "  make devices       List available physical devices"
	@echo "  make icon          Regenerate app icon from scripts/ sources"
	@echo ""
	@echo "Variables (override with VAR=value):"
	@echo "  SIMULATOR   $(SIMULATOR)"
	@echo "  DEVICE_ID   $(DEVICE_ID)"
	@echo "  DEVICE_1    your first device UDID (export or pass on CLI)"
	@echo "  DEVICE_2    your second device UDID (export or pass on CLI)"
	@echo "  BUNDLE_ID   $(BUNDLE_ID)"

generate:
	xcodegen generate
	ruby scripts/patch-widget-platform-filter.rb

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

# Pinned by UDID per the two-iPhone-17 flake rule (never use name=).
INTEGRATION_SIM_DEST = 'platform=iOS Simulator,id=1CCA4B1C-2345-4642-A29C-237D8BE5B9EB'

# Run the live-API test suite against the real Fizzy server.
# Loads .env if present (set -a exports all vars; TEST_RUNNER_ prefix is how
# xcodebuild forwards env vars into the test-runner process).
# Credentials are intentionally absent in CI — the suite self-skips cleanly.
integration-test:
	@if [ -f .env ]; then \
	    echo "Loading .env..."; \
	    set -a; . ./.env; set +a; \
	fi; \
	xcodebuild test \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -destination $(INTEGRATION_SIM_DEST) \
	  -only-testing:FenixKanbanTests/LiveSmokeTests \
	  TEST_RUNNER_FIZZY_TOKEN=$${FIZZY_TOKEN:-} \
	  TEST_RUNNER_FIZZY_ACCOUNT=$${FIZZY_ACCOUNT:-} \
	  TEST_RUNNER_FIZZY_BASE_URL=$${FIZZY_BASE_URL:-} \
	  TEST_RUNNER_FIZZY_EXPECTED_CARDS=$${FIZZY_EXPECTED_CARDS:-} \
	  TEST_RUNNER_FIZZY_ALLOW_MUTATION=$${FIZZY_ALLOW_MUTATION:-}

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

run-device-1:
	$(MAKE) run DEVICE_ID=$(DEVICE_1)

run-device-2:
	$(MAKE) run DEVICE_ID=$(DEVICE_2)

# Build once, deploy to both devices.
run-all: build-device
	$(MAKE) _deploy-one TARGET=$(DEVICE_1)
	$(MAKE) _deploy-one TARGET=$(DEVICE_2)

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf $(DERIVED_DATA)/FenixKanban-*

devices:
	xcrun devicectl list devices

icon:
	./scripts/generate-icon.sh
