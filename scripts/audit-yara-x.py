#!/usr/bin/env python3
"""RustSec audit of the Rust crates YARA-X links into hexwerk.

Usage: scripts/audit-yara-x.py <yara-x checkout>

`cargo audit` checks the whole YARA-X workspace (CLI, language server, …).
This keeps only the crates in the dependency tree of `yara-x-capi`, the part
that is linked into hexwerk, and fails on vulnerabilities that are not listed
with a reason in security/audit-ignore.txt. Warnings (unmaintained, yanked,
unsound) are printed but do not fail.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def linked_crates(src):
    out = subprocess.check_output(
        ["cargo", "tree", "--manifest-path", str(src / "capi" / "Cargo.toml"), "--locked",
         "-e", "normal,build", "--target", "aarch64-apple-darwin", "--prefix", "none", "--format", "{p}"],
        text=True)
    crates = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            crates.add((parts[0], parts[1].lstrip("v")))
    return crates


def main():
    src = pathlib.Path(sys.argv[1]).resolve()
    linked = linked_crates(src)
    ignored = {}
    for line in (ROOT / "security" / "audit-ignore.txt").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            ident, _, reason = line.partition(" ")
            ignored[ident] = reason
    report = json.loads(subprocess.run(
        ["cargo", "audit", "--json", "--file", str(src / "Cargo.lock")],
        capture_output=True, text=True).stdout)

    def is_linked(pkg):
        return (pkg["name"], pkg["version"]) in linked

    failed = False
    for v in report.get("vulnerabilities", {}).get("list", []):
        pkg, adv = v["package"], v["advisory"]
        if not is_linked(pkg):
            continue
        if adv["id"] in ignored:
            print(f"accepted  {adv['id']} {pkg['name']} {pkg['version']}: {ignored[adv['id']]}")
        else:
            failed = True
            print(f"VULNERABLE {adv['id']} {pkg['name']} {pkg['version']}: {adv['title']}")
    for kind, items in (report.get("warnings") or {}).items():
        for w in items:
            pkg = w["package"]
            if is_linked(pkg):
                adv = w.get("advisory") or {}
                print(f"warning   {kind} {adv.get('id', '')} {pkg['name']} {pkg['version']}")
    print(f"{len(linked)} linked crates checked")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
