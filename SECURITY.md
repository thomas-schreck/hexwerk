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

## Known issues

Hostile-input robustness problems found before the first public release are
tracked in public issues labeled `type: security`.
