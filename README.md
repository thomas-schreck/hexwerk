<p align="center"><img src="Resources/icon/README-icon.png" width="96" alt=""></p>

# hexwerk

A native macOS hex editor for reverse engineering and malware analysis —
with Kaitai Struct, YARA-X, JavaScript scripting and a full command line tool.

![hexwerk showing a PNG file with its Kaitai Struct structure tree](docs/screenshot.png)

> **Status:** early, single-maintainer project. See the [open issues](https://github.com/thomas-schreck/hexwerk/issues)
> for known problems — hexwerk is not yet hardened against all hostile input.

## Features

**Editing**
- Opens large files via memory mapping; piece-table editing with undo/redo
- Overwrite and insert mode, hex and text columns (ASCII, Latin-1, UTF-8), Vim key bindings
- Multiple files as tabs, bookmarks, go to offset/value, fill, copy as C/Python/Swift/Base64/hex
- Data inspector with editable values (integers, floats, times, GUID, LEB128, text)
- Intel HEX and Motorola S-Record import with write-back

**Analysis**
- **Kaitai Struct**: parses files with `.ksy` schemas, structure tree linked to colored byte ranges, lazy arrays for millions of elements; format auto-detection
- **YARA-X** rule scanning with hits in the hex view
- In the app, Kaitai parsing, YARA-X scans and scripts run in a sandboxed helper process
  (no network, no file access): a malformed sample that crashes a parser takes down the
  helper, not the app with your unsaved edits
- File type detection (libmagic + signatures) and embedded-file search
- Entropy profile and byte histogram, image view (9 pixel formats)
- Strings finder (ASCII, UTF-8, UTF-16), regex search
- 45 checksums and hashes in one pass (CRC family, Adler, Fletcher, FNV, xxHash, Murmur3, MD2/4/5, SHA-1/2/3, BLAKE2/3, RIPEMD-160, SM3, …)
- Binary diff that detects inserted and deleted bytes
- Number calculator

**Automation**
- JavaScript scripting (JavaScriptCore) with an `hw` API on the open document, run with a time limit and applied as one undo step
- `hexwerk` command line tool for everything above

## Requirements

- macOS 26 or later on Apple silicon
- Swift 6 toolchain (Command Line Tools or Xcode)
- Homebrew packages `yara-x` and `libmagic` (linked statically; set
  `HOMEBREW_PREFIX` if Homebrew is not in its default location)

Notes:
- The static libraries come from Homebrew's bottle for the build machine. A
  build on macOS 27 links bottles made for macOS 27 and prints linker warnings
  about the newer object files; it runs on the build machine, but builds meant
  for macOS 26 should be made on macOS 26 — release builds come from the
  GitHub runner, which uses macOS 26.
- `Package.swift` uses `unsafeFlags` to link the static libraries, so the
  package cannot be used as a dependency of another SwiftPM package. hexwerk
  is an app and a CLI, so this is intended.

## Download

Via Homebrew ([own tap](https://github.com/thomas-schreck/homebrew-tap), Apple silicon):

```sh
brew tap thomas-schreck/tap && brew trust thomas-schreck/tap
brew install --cask thomas-schreck/tap/hexwerk   # app
brew install thomas-schreck/tap/hexwerk          # CLI
```

Or download the app and CLI from the
[releases page](https://github.com/thomas-schreck/hexwerk/releases). The app is
not notarized: on first start allow it under *System Settings → Privacy &
Security → Open Anyway*.

## Build and install

```sh
brew install yara-x libmagic
git clone https://github.com/thomas-schreck/hexwerk.git
cd hexwerk
make install-app     # builds dist/hexwerk.app and copies it to /Applications
make cli             # installs the hexwerk command to ~/.local/bin (PREFIX=… to change)
make formats         # downloads the Kaitai Struct format collection
```

Run the tests with `swift build && swift test`.

## Command line

```sh
hexwerk open firmware.bin             # open in the app
hexwerk dump file.bin --offset 0x100 --length 64   # hexdump -C style
hexwerk type sample.exe               # file type + embedded files
hexwerk parse --format png image.png  # Kaitai Struct, also --ksy my.ksy
hexwerk yara rules.yar sample.bin
hexwerk hash --algo common file.bin
hexwerk diff old.bin new.bin
hexwerk strings -n 6 sample.bin
hexwerk convert firmware.hex firmware.bin
hexwerk script patch.js file.bin --write  # without --write: dry run
```

`hexwerk --help` lists all commands: `dump`, `inspect`, `find`, `diff`, `hash`,
`parse`, `yara`, `entropy`, `export`, `script`, `type`, `strings`,
`convert`, `open`.

## Where hexwerk stores data

| What | Where |
|---|---|
| Kaitai format collection (`make formats`) | `~/.config/hexwerk/formats` |
| Own and translated `.ksy` files (override the collection) | `~/.config/hexwerk/ksy` |
| YARA rules and scripts (suggested folders) | `~/.config/hexwerk/yara`, `~/.config/hexwerk/scripts` |
| Settings | `~/.config/hexwerk/settings.json` |
| Per-file state (bookmarks, format, position) | `<file>.hexwerk` next to the file once it has bookmarks, otherwise `~/.config/hexwerk/projects` |

`$XDG_CONFIG_HOME` is respected. hexwerk makes no network connections.

## Language

The app and the CLI speak **English and German** and follow the system
language. To choose explicitly:

- App: *hexwerk → Language* (takes effect after a restart), stored as
  `"language": "en" | "de"` in `settings.json`
- CLI: `HEXWERK_LANG=en hexwerk …` (otherwise `LC_ALL`, `LC_MESSAGES`, `LANG`)

## Contributing

Every change starts with an issue and arrives as a pull request — see
[GOVERNANCE.md](GOVERNANCE.md) and [CONTRIBUTING.md](CONTRIBUTING.md).
Report security problems privately as described in [SECURITY.md](SECURITY.md).

## License

hexwerk is released under the [MIT License](LICENSE). It statically links
YARA-X, libmagic and their dependencies; their licenses are reproduced in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
