PROJECT := Kontrol.xcodeproj
SCHEME := Kontrol
CONFIGURATION ?= Debug
DERIVED_DATA ?= /tmp/kontrol-derived
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Kontrol.app

.PHONY: run build test clean

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO build

test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=NO test

# Build first; only restart after a successful build. A cancelled/failed graceful
# quit stops the recipe rather than discarding drafts or opening a second instance.
run: build
	osascript scripts/quit-app.applescript "$(abspath $(APP))"
	open -n "$(APP)"

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) clean
