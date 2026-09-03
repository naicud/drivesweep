APP_NAME := DriveSweep
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build run clean dmg test cleanup-harness

build:
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	clang -fobjc-arc -framework Cocoa -framework UserNotifications -o "$(APP)/Contents/MacOS/$(APP_NAME)" Sources/main.m
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	/usr/sbin/dot_clean -m "$(APP)"
	codesign --force --deep --sign - "$(APP)"
	/usr/sbin/dot_clean -m "$(APP)"
	codesign --verify --deep --strict "$(APP)"

run: build
	open "$(APP)"

dmg: build
	set -e; stage="$$(mktemp -d /private/tmp/drivesweep.XXXXXX)"; \
	trap 'rm -rf "$$stage"' EXIT; \
	ditto --norsrc --noextattr "$(APP)" "$$stage/$(APP_NAME).app"; \
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$$stage" -ov -format UDZO "$(BUILD_DIR)/$(APP_NAME).dmg"

cleanup-harness:
	mkdir -p "$(BUILD_DIR)"
	clang -fobjc-arc -framework Cocoa -framework UserNotifications -o "$(BUILD_DIR)/cleanup-harness" Tests/cleanup_harness.m

test: build cleanup-harness
	plutil -lint "$(APP)/Contents/Info.plist"
	test "$$(plutil -extract LSUIElement raw "$(APP)/Contents/Info.plist")" = false
	codesign --verify --deep --strict --verbose=2 "$(APP)"
	"$(BUILD_DIR)/cleanup-harness"

clean:
	rm -rf "$(BUILD_DIR)"
