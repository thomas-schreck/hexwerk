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
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null)
# The CLI has no bundle; this Info.plist is linked into its __TEXT,__info_plist
# section so `hexwerk --version` can read it (BuildInfo.swift).
CLI_PLIST := .build/cli-Info.plist

.PHONY: test build sign-cli cli cli-docs appinstall-app dist sbom clean formats icon coverage bench format lint

test:
	swift test

# The second step relinks only the CLI, now with its Info.plist.
build: $(CLI_PLIST)
	swift build -c release
	swift build -c release --product hexwerk \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(CLI_PLIST)

# Rewritten on every run so version and commit are never stale.
.PHONY: $(CLI_PLIST)
$(CLI_PLIST):
	mkdir -p .build && rm -f $@
	/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string de.schreck-thomas.hexwerk.cli" \
		-c "Add :CFBundleName string hexwerk" \
		-c "Add :CFBundleShortVersionString string $(VERSION)" \
		-c "Add :CFBundleVersion string $(BUILD)" \
		-c "Add :HexwerkCommit string $(COMMIT)" $@ >/dev/null

# Tests with line coverage per module (Markdown table).
coverage:
	swift test --enable-code-coverage
	@scripts/coverage.sh

# Benchmarks on a generated 256 MiB file (BENCH_ARGS e.g. --size-mib 64 --runs 1),
# compared against the checked-in baseline.
BENCH_ARGS ?=
bench:
	swift run -c release hexwerk-bench --baseline Benchmarks/baseline.json $(BENCH_ARGS)

# swift-format from the toolchain (Swift 6+); config in .swift-format.
SWIFT_FORMAT ?= swift format
FORMAT_PATHS := Package.swift Sources Tests Benchmarks
format:
	$(SWIFT_FORMAT) format --in-place --recursive --parallel $(FORMAT_PATHS)

lint:
	$(SWIFT_FORMAT) lint --strict --recursive --parallel $(FORMAT_PATHS)

# CLI signed with the Hardened Runtime; its sandboxed child process (the same
# binary, #129) runs YARA-X and JavaScriptCore and needs the two JIT entitlements.
sign-cli: build
	codesign --force --sign - --options runtime --entitlements Resources/cli.entitlements .build/release/hexwerk

# Shell completions and man page for the CLI tarball, generated in English from
# the release binary. generate-manual is the tool behind argument-parser's
# GenerateManual plugin, built directly so the plugin cannot relink the CLI
# without its Info.plist. The man page names the build machine's format
# folder, so $HOME becomes ~ again. generate-manual silently drops non-ASCII
# characters (0x… became 0x), so English help texts must be ASCII.
CLI_DOCS := .build/cli-docs
MAN_DATE ?= $(shell git log -1 --format=%cd --date=format:%Y-%m-%d 2>/dev/null)
cli-docs: sign-cli
	swift build -c release --product generate-manual
	rm -rf $(CLI_DOCS) && mkdir -p $(CLI_DOCS)/completions $(CLI_DOCS)/man
	HEXWERK_LANG=en .build/release/hexwerk --generate-completion-script zsh > $(CLI_DOCS)/completions/_hexwerk
	HEXWERK_LANG=en .build/release/hexwerk --generate-completion-script bash > $(CLI_DOCS)/completions/hexwerk.bash
	HEXWERK_LANG=en .build/release/hexwerk --generate-completion-script fish > $(CLI_DOCS)/completions/hexwerk.fish
	@if HEXWERK_LANG=en .build/release/hexwerk --experimental-dump-help | LC_ALL=C grep -o '.\{0,40\}[^ -~]'; then \
		echo "CLI help text has non-ASCII characters; generate-manual would drop them" >&2; exit 1; fi
	HEXWERK_LANG=en .build/release/generate-manual .build/release/hexwerk \
		$(if $(MAN_DATE),--date $(MAN_DATE)) --output-directory $(CLI_DOCS)/man
	sed -i '' "s#$(HOME)/#~/#g" $(CLI_DOCS)/man/hexwerk.1

# CLI nach ~/.local/bin (Konvention aus ~/src/Makefile)
cli: sign-cli
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
		-c "Set :CFBundleVersion $(BUILD)" -c "Add :HexwerkCommit string $(COMMIT)" $(APP)/Contents/Info.plist
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
	# The app itself runs no JIT any more (parsers, YARA and scripts live in
	# the XPC service), so it gets the Hardened Runtime without exceptions.
	codesign --force --sign - --options runtime $(APP)
	@echo "→ $(APP)"

# Ersetzt /Applications/hexwerk.app (alte Version in den Papierkorb).
install-app: app
	@if [ -d /Applications/hexwerk.app ]; then \
		osascript -e 'tell application "Finder" to delete POSIX file "/Applications/hexwerk.app"' >/dev/null; fi
	cp -R $(APP) /Applications/hexwerk.app
	@echo "→ /Applications/hexwerk.app"

# Release artifacts: app as DMG and ZIP, CLI as tarball (with completions and
# man page), SHA256SUMS.
dist: app sign-cli cli-docs
	rm -rf .build/dist && mkdir -p .build/dist/dmg .build/dist/cli/hexwerk-cli-$(VERSION)
	rm -f dist/hexwerk-*.dmg dist/hexwerk-*.zip dist/hexwerk-cli-*.tar.gz dist/SHA256SUMS
	ditto -c -k --keepParent $(APP) dist/hexwerk-$(VERSION).zip
	cp -R $(APP) .build/dist/dmg/ && ln -s /Applications .build/dist/dmg/Applications
	hdiutil create -quiet -volname "hexwerk $(VERSION)" -srcfolder .build/dist/dmg -ov -format UDZO dist/hexwerk-$(VERSION).dmg
	cp .build/release/hexwerk $(HOMEBREW_PREFIX)/share/misc/magic.mgc LICENSE THIRD_PARTY_NOTICES.md \
		.build/dist/cli/hexwerk-cli-$(VERSION)/
	cp -R $(CLI_DOCS)/completions $(CLI_DOCS)/man .build/dist/cli/hexwerk-cli-$(VERSION)/
	tar -C .build/dist/cli -czf dist/hexwerk-cli-$(VERSION)-arm64.tar.gz hexwerk-cli-$(VERSION)
	cd dist && shasum -a 256 hexwerk-$(VERSION).dmg hexwerk-$(VERSION).zip hexwerk-cli-$(VERSION)-arm64.tar.gz > SHA256SUMS
	@cat dist/SHA256SUMS

# SPDX SBOM of a release (dist/hexwerk-$(VERSION).spdx.json). Clones YARA-X at
# the version of THIRD_PARTY_NOTICES.md unless YARA_X_SRC names a checkout.
YARA_X_SRC ?=
sbom:
	scripts/sbom.py "$(VERSION)" $(if $(YARA_X_SRC),--yara-x "$(YARA_X_SRC)") -o dist/hexwerk-$(VERSION).spdx.json

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
