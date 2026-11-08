# Security policy

hexwerk is built to open untrusted and malicious files. Bugs that let a crafted
input file, Kaitai Struct schema (`.ksy`), YARA
rule or script crash the app, hang it, exhaust memory, corrupt the edited file,
escape the scripting sandbox or attack the terminal are security issues.

## Reporting a vulnerability

Please **do not open a public issue.** Report privately via GitHub:
**Security → Report a vulnerability** in this repository
(private vulnerability reporting).

Include the affected version or commit, a minimal reproducer (input file or
schema), and the observed behavior. You will get an answer within 14 days.
Fixes are developed in a private advisory and published together with the
advisory once a release is available. Reporters are credited unless they
prefer otherwise.

## Supported versions

Only the latest release and `main` receive security fixes.

## Sandboxing

Everything that interprets file content with a large or C/Rust attack surface
runs in a separate, sandboxed process: Kaitai Struct parsing (including
loading `.ksy` files), YARA-X compiling and scanning, JavaScript scripts and
libmagic's file type detection. A crash or hang there ends that process
only; the request fails with a message and the time limits of the request
plus a grace period apply.

- **App:** an XPC service inside the app bundle
  (`Contents/XPCServices/de.schreck-thomas.hexwerk.Parser.xpc`, entitlements
  `Resources/Parser.entitlements`) runs in the App Sandbox with no network
  and no file access. The app passes the document as an open descriptor,
  `magic.mgc` as another one, rule files and scripts as text, and answers the
  helper's requests for `.ksy` files itself (regular `.ksy` files only).
- **CLI:** `parse`, `yara`, `type` and `script` start the `hexwerk`
  executable again as a child process. Before it reads anything, the child
  enters a sandbox profile of its own (`sandbox_init`, see
  `Sources/HexwerkHelper/Sandbox.swift`) with `(deny default)`. Allowed are
  reading sysctl values (wasmtime needs the page size), except the
  `kern.proc*` names (process lists, other processes' arguments and
  environment), and reading ICU's Unicode data (JavaScriptCore). Because
  `deny default` leaves some process and hardware information readable,
  `process-info*` (e.g. `proc_pidpath`/`proc_pidinfo` of other processes)
  and `iokit-get-properties` (e.g. the serial number) are denied
  explicitly. The child inherits only the document and `magic.mgc` as open
  descriptors and two pipes; it has no environment, no network, no mach
  services, cannot fork, start programs or signal other processes, and
  cannot open, create or list files. For `yara` only, it may read and write
  one fresh folder that the parent creates in the temp folder and deletes
  afterwards (the rule files are written there so `include` works, absolute
  includes included); it may read the metadata of the folders above it.
  Rule files and scripts are read by the parent, `.ksy` files are answered
  over the pipe as in the app, and the results come back in the same binary
  formats the app's helper uses, so the output is unchanged. Edits made by a
  script are applied and saved (`--write`) by the parent. The parent bounds
  every read and write on the pipes by the time limit (a child that floods
  requests or stops reading is killed), accepts at most 1 GiB per answer
  (64 KiB for a file request) and allocates as data arrives; the child exits
  when the parent goes away, so a killed CLI leaves no script or scan
  running. YARA rules get a compile budget of 10 minutes before the scan's
  own limit starts (compiling had no limit in-process). `SandboxTests` probe
  all of this from inside the child, with stand-in hostile children for the
  parent's side.
- What stays in the app and CLI processes is plain, bounds-checked Swift:
  hex view, search, signatures and embedded-file search, strings, hashes,
  diff, inspector, Intel HEX/S-Record import, image view.
- JIT: YARA-X (wasmtime) and JavaScriptCore need the JIT entitlements of the
  Hardened Runtime (see below); the sandbox profiles do not widen them.

### Known gaps

- The CLI's sandbox profile is applied with `sandbox_init`, a deprecated
  (but still used, e.g. by Chromium) API; Apple documents no supported
  replacement for command line tools without a bundle.
- Reading sysctl values in general stays allowed (wasmtime needs some; the
  exact set is not documented), so the child can read system information
  such as the OS version, CPU model and boot time, but not process lists or
  other processes' arguments.
- The app's helper relies on the App Sandbox of its entitlements; the
  probes in `SandboxTests` run against the CLI's child only (the helper
  needs the assembled app bundle).
- Signed builds (Hardened Runtime): JavaScriptCore's execution time limit
  does not fire for scripts that loop without calling into hexwerk, so the
  CLI kills such a script only at its time limit plus 15 s grace (exit 3,
  "did not answer in time"); before the CLI sandbox it ran forever.

## How hexwerk is tested

- **Unit and regression tests** (`swift test`, every pull request): every
  hostile-input bug that gets fixed gets a test with its reproducer.
- **Fuzz tests** (`Tests/HexwerkCoreTests/FuzzTests.swift`): seeded,
  mutation-based tests for `.ksy` loading, Kaitai expressions, Kaitai parsing
  of mutated files, Intel HEX/S-Record import, data inspector input, script
  API arguments and file signature detection. A thrown error is fine; a
  crash or hang fails and prints the seed that reproduces it. Every
  `swift test` runs a few seconds of them; the nightly `Fuzz` workflow runs
  them much longer, also under Address Sanitizer. Locally:
  `HEXWERK_FUZZ_SCALE=100 HEXWERK_FUZZ_SEED=random swift test --filter FuzzTests`.
  (Apple's toolchains ship no libFuzzer runtime, so these are plain Swift
  Testing tests rather than libFuzzer targets.)
- **Address Sanitizer** (`Sanitizers` workflow, pull requests and weekly):
  the whole test suite under `swift test --sanitize=address` (except one
  test that checks the stack budget of a 512 KiB thread, which ASan's larger
  stack frames exceed; it runs in the normal CI job).
- **CodeQL** code scanning for Swift (`CodeQL` workflow, pull requests,
  `main` and weekly).

## Known issues

Hostile-input robustness problems found before the first public release are
tracked in public issues labeled `type: security`.

## Supply chain

- **Dependencies:** Dependabot alerts and security updates are on; weekly
  update PRs for GitHub Actions and Swift packages go through CI.
- **Pinned actions:** workflows reference actions by commit SHA and check out
  without persisted credentials.
- **Statically linked code:** CI and release builds compile YARA-X from
  source at exactly the version in `THIRD_PARTY_NOTICES.md`
  (`scripts/build-yara-x.sh`), independent of the Homebrew bottle on the
  runner; `scripts/check-dependency-versions.sh` refuses a mismatch.
- **RustSec audit:** `scripts/audit-yara-x.py` checks the crates YARA-X links
  into hexwerk weekly and before every release. Accepted advisories are
  listed with their reason in `security/audit-ignore.txt`.
- **Hardened Runtime:** the app is signed with the Hardened Runtime without
  exceptions; the parser helper adds only its sandbox and JIT entitlements;
  the CLI, whose sandboxed child process (the same signed binary) runs YARA-X
  and JavaScriptCore, gets exactly the two JIT entitlements in
  `Resources/cli.entitlements`. Builds run on a fixed
  runner (`macos-26`) so the minimum macOS version cannot change silently.
- **Releases:** only the maintainer can create `v*` tags (repository
  ruleset). Release artifacts carry build provenance attestations:

  ```sh
  gh attestation verify hexwerk-<version>.dmg -R thomas-schreck/hexwerk
  ```
- **SBOM:** every release ships `hexwerk-<version>.spdx.json`, an SPDX 2.3
  SBOM generated by `scripts/sbom.py` (`make sbom VERSION=…`): the Swift
  packages, libmagic, YARA-X and every Rust crate it links, with versions,
  licenses, package URLs and Cargo.lock checksums. It is listed in
  `SHA256SUMS` and attested for the DMG, ZIP and CLI tarball:

  ```sh
  gh attestation verify hexwerk-<version>.dmg -R thomas-schreck/hexwerk \
    --predicate-type https://spdx.dev/Document/v2.3
  ```
- **OpenSSF Scorecard:** `.github/workflows/scorecard.yml` scores the
  repository's supply-chain practices weekly and on every push to `main`;
  results are on [scorecard.dev](https://scorecard.dev/viewer/?uri=github.com/thomas-schreck/hexwerk)
  and in code scanning.
