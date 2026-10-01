CONFIG ?= Debug
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/$(CONFIG)/Shell.app

.PHONY: bootstrap project build test coverage release dist dmg-preview install run clean

bootstrap:
	./scripts/bootstrap.sh

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project Shell.xcodeproj -scheme Shell -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -destination 'platform=macOS' build -quiet

test: project
	xcodebuild -project Shell.xcodeproj -scheme Shell -derivedDataPath $(DERIVED) -destination 'platform=macOS' test -quiet

# Unit tests with line coverage per file and in total (scripts/coverage.sh).
coverage: project
	./scripts/coverage.sh

release:
	$(MAKE) build CONFIG=Release

# Signed + notarized .dmg in build/dist (see scripts/release.sh).
dist:
	./scripts/release.sh

# Unsigned .dmg from the Debug build, to check the installer window layout.
dmg-preview: build
	./scripts/make-dmg.sh "$(APP)" build/dmg-preview/Shell-preview.dmg
	open build/dmg-preview/Shell-preview.dmg

install:
	./scripts/release.sh --install

run: build
	open "$(APP)"

clean:
	rm -rf build
