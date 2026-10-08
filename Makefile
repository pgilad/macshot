# macshot builds with the Command Line Tools only: `xcode-select --install`.
# Common tasks: make install, make test, make self-test, make app.

SWIFT ?= swift
APP_DIR ?= build/macshot.app
INSTALL_DIR ?= /Applications
VERSION := $(shell tr -d '[:space:]' < VERSION)
DIST_ZIP ?= build/macshot-$(VERSION)-arm64.zip
# Extra flags for swift build and swift test. CI uses -Xswiftc -warnings-as-errors.
SWIFT_FLAGS ?=

# The Command Line Tools ship the Swift Testing macro plugin outside the default search path.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)

.PHONY: build app dist install test self-test snapshots readme-images run clean signing-identity

build: ## Debug build
	$(SWIFT) build $(SWIFT_FLAGS)

app: ## Release build, bundled and signed, in build/macshot.app
	APP_DIR=$(APP_DIR) SWIFT_FLAGS="$(SWIFT_FLAGS)" scripts/bundle.sh

dist: app ## Release build zipped for download, with a SHA-256 file
	rm -f "$(DIST_ZIP)" "$(DIST_ZIP).sha256"
	ditto -c -k --keepParent "$(APP_DIR)" "$(DIST_ZIP)"
	cd "$(dir $(DIST_ZIP))" && shasum -a 256 "$(notdir $(DIST_ZIP))" > "$(notdir $(DIST_ZIP)).sha256"

install: app ## Build, then replace the app in /Applications and start it
	-osascript -e 'tell application id "com.pgilad.macshot" to quit' >/dev/null 2>&1
	rm -rf "$(INSTALL_DIR)/macshot.app"
	cp -R "$(APP_DIR)" "$(INSTALL_DIR)/macshot.app"
	open "$(INSTALL_DIR)/macshot.app"

test: ## Unit tests, one at a time: they share UserDefaults and the pasteboard
	$(SWIFT) test --no-parallel $(SWIFT_FLAGS) $(TEST_FLAGS)

self-test: build ## Editor, tools, text undo, save, history and Settings in real windows
	.build/debug/macshot --self-test

snapshots: build ## Render the editor with sample annotations to PNG files in build/snapshots
	.build/debug/macshot --render-snapshots build/snapshots

readme-images: snapshots ## Update the README screenshots in docs/images
	mkdir -p docs/images
	cp build/snapshots/editor-light.png build/snapshots/editor-dark.png docs/images/

run: app ## Start the bundled build from build/
	open "$(APP_DIR)"

signing-identity: ## Create the "macshot Local Signing" certificate (once per Mac)
	scripts/create-signing-identity.sh

clean:
	rm -rf .build build
