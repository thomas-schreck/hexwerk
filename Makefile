# hexwerk — Build ohne Xcode (nur Command Line Tools)
PREFIX ?= $(HOME)/.local
# Homebrew prefix (YARA-X, libmagic); Package.swift uses the same variable.
HOMEBREW_PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
export HOMEBREW_PREFIX
APP    := dist/hexwerk.app
# Sandboxed helper for the parsers (#102); the name is its bundle identifier.
XPC    := $(APP)/Contents/XPCServices/de.schreck-thomas.hexwerk.Parser.xpc
# Release version and build number; the release workflow passes them from the tag.
VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
BUILD   ?= 1

.PHONY: test build cli app install-app dist clean formats icon

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
	# Leere .lproj-Ordner: daran wählt AppKit die Sprache seiner eigenen Texte.
	mkdir -p $(APP)/Contents/Resources/en.lproj $(APP)/Contents/Resources/de.lproj
	printf '"Any File" = "Beliebige Datei";\n' > $(APP)/Contents/Resources/de.lproj/InfoPlist.strings
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(BUILD)" $(APP)/Contents/Info.plist
	cp .build/release/HexwerkApp $(APP)/Contents/MacOS/HexwerkApp
	cp $(HOMEBREW_PREFIX)/share/misc/magic.mgc $(APP)/Contents/Resources/magic.mgc
	cp THIRD_PARTY_NOTICES.md LICENSE $(APP)/Contents/Resources/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	# XPC service: signed first and with its own sandbox entitlements, then
	# the app around it.
	mkdir -p $(XPC)/Contents/MacOS
	cp Resources/Parser-Info.plist $(XPC)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(BUILD)" $(XPC)/Contents/Info.plist
	cp .build/release/HexwerkParser $(XPC)/Contents/MacOS/HexwerkParser
	codesign --force --sign - --options runtime --entitlements Resources/Parser.entitlements $(XPC)
	codesign --force --sign - $(APP)
	@echo "→ $(APP)"

# Ersetzt /Applications/hexwerk.app (alte Version in den Papierkorb).
install-app: app
	@if [ -d /Applications/hexwerk.app ]; then \
		osascript -e 'tell application "Finder" to delete POSIX file "/Applications/hexwerk.app"' >/dev/null; fi
	cp -R $(APP) /Applications/hexwerk.app
	@echo "→ /Applications/hexwerk.app"

# Release artifacts: app as DMG and ZIP, CLI as tarball, SHA256SUMS.
dist: app
	rm -rf .build/dist && mkdir -p .build/dist/dmg .build/dist/cli/hexwerk-cli-$(VERSION)
	rm -f dist/hexwerk-*.dmg dist/hexwerk-*.zip dist/hexwerk-cli-*.tar.gz dist/SHA256SUMS
	ditto -c -k --keepParent $(APP) dist/hexwerk-$(VERSION).zip
	cp -R $(APP) .build/dist/dmg/ && ln -s /Applications .build/dist/dmg/Applications
	hdiutil create -quiet -volname "hexwerk $(VERSION)" -srcfolder .build/dist/dmg -ov -format UDZO dist/hexwerk-$(VERSION).dmg
	cp .build/release/hexwerk $(HOMEBREW_PREFIX)/share/misc/magic.mgc LICENSE THIRD_PARTY_NOTICES.md \
		.build/dist/cli/hexwerk-cli-$(VERSION)/
	tar -C .build/dist/cli -czf dist/hexwerk-cli-$(VERSION)-arm64.tar.gz hexwerk-cli-$(VERSION)
	cd dist && shasum -a 256 hexwerk-$(VERSION).dmg hexwerk-$(VERSION).zip hexwerk-cli-$(VERSION)-arm64.tar.gz > SHA256SUMS
	@cat dist/SHA256SUMS

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
