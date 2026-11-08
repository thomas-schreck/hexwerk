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
make sandbox-probes  # test-only helper bundle; swift test then probes its App Sandbox
make formats         # download the Kaitai Struct format collection
```

Changes to input parsing should survive a longer fuzz run, e.g.
`HEXWERK_FUZZ_SCALE=100 HEXWERK_FUZZ_SEED=random swift test --filter FuzzTests`
(see "How hexwerk is tested" in [SECURITY.md](SECURITY.md)).

`make build` and `make app` take the version from the nearest release tag
(`scripts/version.sh`): `0.2.0` on the tag itself, `0.2.0+5.gabc1234` five
commits later, `+dirty` with uncommitted changes. Without git or tags (e.g. a
shallow clone, run `git fetch --tags`) it falls back to
`Resources/Info.plist`; `make app VERSION=…` overrides it.
`scripts/version-test.sh` tests the script.

See the README for details and known build limitations.

## Coverage, benchmarks, formatting

```sh
make coverage        # swift test --enable-code-coverage + line coverage per module
make bench           # benchmarks on a generated 256 MiB file vs. the baseline
make bench BENCH_ARGS="--size-mib 64 --runs 1"   # quicker, not compared
make lint            # swift-format check (config in .swift-format)
make format          # swift-format in place
```

- **Coverage** runs in CI on every pull request (workflow *Coverage*); the
  table is in the job summary. It is informational, there is no threshold.
  Only code in the test bundle counts: the CLI and the app are not measured.
- **Benchmarks** (`Benchmarks/main.swift`, executable `hexwerk-bench`) time
  open, hex and regex search, saving in place and with a length change,
  Kaitai parsing of large arrays and hashing. The *Benchmarks* workflow runs
  weekly, by hand and on pull requests that touch `Benchmarks/`. It fails only
  if a benchmark is more than 3× slower than `Benchmarks/baseline.json` *and*
  at least 0.5 s slower. The baseline holds CI runner numbers, so a local
  `make bench` (usually faster) is only a rough comparison. To update the
  baseline after an intended change, download the `bench-results` artifact of
  a workflow run on `main` and commit it as `Benchmarks/baseline.json` in the
  pull request that explains the change.
- **swift-format** uses the `swift format` command of the Swift 6 toolchain
  (Xcode or Command Line Tools); with an older toolchain install it with
  `brew install swift-format` and run `make lint SWIFT_FORMAT=swift-format`.
  The existing sources are not formatted yet; that happens once in a
  separate commit. Until then the CI lint job does not block, and please do
  not reformat code you do not otherwise change.

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
- User-facing texts are English source literals wrapped in `L("…")`, with the
  German translation in `Sources/HexwerkCore/Localization/de*.swift`. Use
  format specifiers instead of interpolation (`L("%ld hits", n)`).
  `LocalizationTests` fails for missing or unused translations and for German
  literals left in code.

## Licensing

By submitting a contribution you agree that it is licensed under the
project's MIT License. Do not add code or data under incompatible licenses.
New bundled or linked dependencies must be added to `THIRD_PARTY_NOTICES.md`
(regenerate with `scripts/third-party-notices.py`) and discussed in an issue
first.
