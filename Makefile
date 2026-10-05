APP_NAME := DriveSweep
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
SIGNING_MODE ?= local
SIGNING_IDENTITY ?=
SIGNING_DIR ?= $(HOME)/Library/Application Support/DriveSweep/Signing

.PHONY: build sign run clean dmg test cleanup-harness v3-harness cli-harness

build:
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	clang -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -fobjc-arc -framework Cocoa -framework UserNotifications -o "$(APP)/Contents/MacOS/$(APP_NAME)" Sources/main.m
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp Scripts/drivesweep "$(APP)/Contents/Resources/drivesweep"
	chmod 755 "$(APP)/Contents/Resources/drivesweep"
	/usr/sbin/dot_clean -m "$(APP)"
	$(MAKE) sign
	/usr/sbin/dot_clean -m "$(APP)"
	codesign --verify --deep --strict "$(APP)"

sign:
	python3 Scripts/sign_app.py "$(APP)" --mode "$(SIGNING_MODE)" --identity "$(SIGNING_IDENTITY)" --directory "$(SIGNING_DIR)"
	codesign --verify --deep --strict "$(APP)"

run: build
	open "$(APP)"

dmg: build
	set -e; stage="$$(mktemp -d /private/tmp/drivesweep.XXXXXX)"; \
	trap 'rm -rf "$$stage"' EXIT; \
	ditto --norsrc --noextattr "$(APP)" "$$stage/$(APP_NAME).app"; \
	ln -s /Applications "$$stage/Applications"; \
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$$stage" -ov -format UDZO "$(BUILD_DIR)/$(APP_NAME).dmg"

cleanup-harness:
	mkdir -p "$(BUILD_DIR)"
	clang -fobjc-arc -framework Cocoa -framework UserNotifications -o "$(BUILD_DIR)/cleanup-harness" Tests/cleanup_harness.m

v3-harness:
	mkdir -p "$(BUILD_DIR)"
	clang -fobjc-arc -framework Cocoa -framework UserNotifications -o "$(BUILD_DIR)/v3-harness" Tests/v3_harness.m

cli-harness:
	mkdir -p "$(BUILD_DIR)"
	clang -fobjc-arc -framework Cocoa -framework UserNotifications -o "$(BUILD_DIR)/cli-harness" Tests/cli_harness.m

test: build cleanup-harness v3-harness cli-harness
	plutil -lint "$(APP)/Contents/Info.plist"
	test "$$(plutil -extract LSUIElement raw "$(APP)/Contents/Info.plist")" = false
	codesign --verify --deep --strict --verbose=2 "$(APP)"
	"$(BUILD_DIR)/cleanup-harness"
	"$(BUILD_DIR)/v3-harness"
	"$(BUILD_DIR)/cli-harness"
	python3 Tests/cli_integration.py
	python3 Tests/signing_integration.py

clean:
	rm -rf "$(BUILD_DIR)"
