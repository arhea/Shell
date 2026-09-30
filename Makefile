CONFIG ?= Debug
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/$(CONFIG)/Shell.app

.PHONY: bootstrap project build release dist install run clean

bootstrap:
	./scripts/bootstrap.sh

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project Shell.xcodeproj -scheme Shell -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build -quiet

release:
	$(MAKE) build CONFIG=Release

# Signed + notarized .dmg in build/dist (see scripts/release.sh).
dist:
	./scripts/release.sh

install:
	./scripts/release.sh --install

run: build
	open "$(APP)"

clean:
	rm -rf build
