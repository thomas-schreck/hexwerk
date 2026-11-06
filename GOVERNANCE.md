# Governance

hexwerk is a small open-source project with a single maintainer. This document
describes how decisions are made and how changes get into the code.

## Roles

**Maintainer** — Thomas Schreck ([@thomas-schreck](https://github.com/thomas-schreck)).
The maintainer sets the direction, triages issues, reviews and merges pull
requests, cuts releases and handles security reports. The maintainer has the
final say on all decisions.

**Contributors** — anyone who opens an issue, comments, or submits a pull
request. Contributors keep the copyright of their work and license it under
the project's MIT License by submitting it.

Additional maintainers may be added by the maintainer after sustained, high
quality contributions. Changes to roles are recorded in this file.

## Everything starts with an issue

Every change — bug fix, feature, documentation, refactoring, dependency update,
release — is tracked by a GitHub issue **before** work starts. This keeps a
public record of why something changed.

1. **Open an issue** using a template. Describe the problem, not only the
   solution.
2. **Triage.** The maintainer labels the issue:
   - `type: …` — kind of change (bug, security, data-loss, feature, …)
   - `prio: critical | high | medium | low` — urgency
   - `area: …` — affected module
   Issues that will not be addressed are closed with a reason.
3. **Pull request.** One pull request per issue. The description starts with
   `Closes #<issue>` and explains what changed and how it was verified.
4. **Review.** See below.
5. **Merge.** Squash merge into `main` by the maintainer; the branch is deleted.

Small typo fixes may skip the issue; the pull request then serves as the record.

## Review

No change reaches `main` without review — this includes the maintainer's own
changes, which also go through pull requests.

- The maintainer reviews every pull request. Reviews are **agent-assisted**:
  automated code-review agents check the diff for correctness, security and
  regressions against the linked issue. Their findings are input, not a
  verdict.
- **Approval and merge are always a human decision** by the maintainer.
- Required for merge:
  - linked issue,
  - `swift test` passes (CI once available),
  - new behavior is covered by tests where practical; bug fixes include a
    regression test,
  - documentation updated where behavior changes.
- Findings from a review that are not fixed in the pull request become new
  issues.

## AI-assisted contributions

AI coding assistants may be used, including for whole pull requests. The
submitter is responsible for the result exactly as if they had written it:

- disclose substantial AI assistance in the pull request description (a
  `Co-Authored-By` trailer is sufficient),
- understand and be able to explain every change,
- make sure no third-party code with an incompatible license is introduced.

## Decisions

Most decisions happen in issues and pull requests. Larger changes (new
dependencies, file formats, scripting API, minimum macOS version, license
questions) are proposed in an issue labeled `type: feature` or
`type: governance` and stay open for comments for at least one week before the
maintainer decides. The decision and its reasoning are recorded in the issue.

## Releases

- Versions follow [Semantic Versioning](https://semver.org).
- A release is prepared in an issue that lists the included changes, then
  tagged `vX.Y.Z` on `main` with release notes.
- Binary releases must ship `LICENSE` and `THIRD_PARTY_NOTICES.md`
  (`make app` does this). The notices are regenerated with
  `scripts/third-party-notices.py` whenever a bundled dependency changes.

## Security

Security issues are not reported in public issues. See [SECURITY.md](SECURITY.md).

## Conduct

Everyone participating follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Changing this document

Changes to this document follow the same process: an issue labeled
`type: governance`, then a pull request.
