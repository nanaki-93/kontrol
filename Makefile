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

run: build
	open "$(APP)"

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) clean
