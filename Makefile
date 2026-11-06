# hexwerk — Build ohne Xcode (nur Command Line Tools)
PREFIX ?= $(HOME)/.local
# Homebrew prefix (YARA-X, libmagic); Package.swift uses the same variable.
HOMEBREW_PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
export HOMEBREW_PREFIX
APP    := dist/hexwerk.app

.PHONY: test build cli app install-app clean formats icon

test:
	swift test

build:
	swift build -c release

# CLI nach ~/.local/bin (Konvention aus ~/src/Makefile)
cli: build
	mkdir -p $(PREFIX)/bin
	install -m 755 .build/release/hexwerk $(PREFIX)/bin/hexwerk

# App-Bundle von Hand zusammensetzen und ad-hoc signieren (wie OscarWatch).
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/HexwerkApp $(APP)/Contents/MacOS/HexwerkApp
	cp $(HOMEBREW_PREFIX)/share/misc/magic.mgc $(APP)/Contents/Resources/magic.mgc
	cp THIRD_PARTY_NOTICES.md LICENSE $(APP)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(APP)
	@echo "→ $(APP)"

# Ersetzt /Applications/hexwerk.app (alte Version in den Papierkorb).
install-app: app
	@if [ -d /Applications/hexwerk.app ]; then \
		osascript -e 'tell application "Finder" to delete POSIX file "/Applications/hexwerk.app"' >/dev/null; fi
	cp -R $(APP) /Applications/hexwerk.app
	@echo "→ /Applications/hexwerk.app"

clean:
	swift package clean
	rm -rf dist

# Kaitai-Formatsammlung nach ~/.config/hexwerk/formats
FORMATS := $(or $(XDG_CONFIG_HOME),$(HOME)/.config)/hexwerk/formats
formats:
	@if [ -d "$(FORMATS)/.git" ]; then git -C "$(FORMATS)" pull -q --ff-only; \
	else mkdir -p "$(dir $(FORMATS))" && git clone -q --depth 1 https://github.com/kaitai-io/kaitai_struct_formats.git "$(FORMATS)"; fi
	@echo "→ $(FORMATS)"

# App icon from Resources/icon/logo.swift (only needed after changing it).
icon:
	rm -rf .build/icon && mkdir -p .build/icon/AppIcon.iconset
	swiftc -O Resources/icon/logo.swift -o .build/icon/logo
	for s in 16 32 128 256 512; do \
		.build/icon/logo A $$s .build/icon/AppIcon.iconset/icon_$${s}x$${s}.png; \
		.build/icon/logo A $$((s*2)) .build/icon/AppIcon.iconset/icon_$${s}x$${s}@2x.png; \
	done
	iconutil -c icns .build/icon/AppIcon.iconset -o Resources/AppIcon.icns
