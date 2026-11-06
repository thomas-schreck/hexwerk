# Contributing to hexwerk

Thanks for helping! Please read [GOVERNANCE.md](GOVERNANCE.md) first — in
short: **every change starts with an issue and arrives as a pull request.**

## Build and test

Requirements: macOS with the Swift 6 toolchain (Command Line Tools or Xcode)
and Homebrew.

```sh
brew install yara-x libmagic
swift build          # debug build of library, CLI and app
swift test           # run the test suite (also needs `swift build` first for CLI tests)
make app             # assemble dist/hexwerk.app
make formats         # download the Kaitai Struct format collection
```

See the README for details and known build limitations.

## Workflow

1. Find or open an issue and say that you are working on it.
2. Fork the repository and create a branch from `main`, named after the issue,
   e.g. `fix/12-stale-search-results`.
3. Make focused commits. Commit messages: short imperative summary line
   (≤ 72 characters), blank line, explanation of *why*. Reference the issue.
4. Add or update tests. Bug fixes need a regression test that fails without
   the fix.
5. Run `swift test` locally.
6. Open a pull request using the template. Start the description with
   `Closes #<issue>`.

## Code guidelines

- Swift 6 with strict concurrency; keep the code warning-free.
- Treat every input file as hostile: no traps on malformed data (use checked
  arithmetic, bounds checks, depth limits) and no unbounded memory or time.
- Keep the UI responsive: long work runs off the main thread and can be
  cancelled.
- Code comments explain *why*, not *what*.
- User-facing texts in the app and CLI are currently German; keep new texts
  consistent with the surrounding UI.

## Licensing

By submitting a contribution you agree that it is licensed under the
project's MIT License. Do not add code or data under incompatible licenses.
New bundled or linked dependencies must be added to `THIRD_PARTY_NOTICES.md`
(regenerate with `scripts/third-party-notices.py`) and discussed in an issue
first.
