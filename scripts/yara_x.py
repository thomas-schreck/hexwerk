"""Shared helpers for the scripts that inspect the YARA-X source tree.

Used by third-party-notices.py and sbom.py; not a script of its own.
"""
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
TARGET = "aarch64-apple-darwin"
REPO = "https://github.com/VirusTotal/yara-x"


def notices_version():
    """YARA-X version THIRD_PARTY_NOTICES.md was generated for (and that release builds link)."""
    m = re.search(r"^## YARA-X ([0-9][0-9.]*)$", (ROOT / "THIRD_PARTY_NOTICES.md").read_text(), re.M)
    return m.group(1) if m else None


def checkout_version(yara_x):
    """Workspace version of a YARA-X source checkout."""
    return re.search(r'^version = "(.+)"', (yara_x / "Cargo.toml").read_text(), re.M).group(1)


def crate_graph(yara_x):
    """Crates in the dependency tree of `yara-x-capi` for aarch64-apple-darwin.

    `cargo metadata` downloads the crate sources into ~/.cargo/registry; no
    crate code is executed. Only normal (non-dev, non-build) dependencies are
    followed. Returns (root id, packages sorted by name and version, edges)
    where edges maps a package id to the ids of its normal dependencies.
    """
    meta = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--format-version", "1", "--locked",
         "--filter-platform", TARGET,
         "--manifest-path", str(yara_x / "capi" / "Cargo.toml")],
        text=True, stderr=subprocess.DEVNULL))
    pkgs = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    root = next(p["id"] for p in meta["packages"] if p["name"] == "yara-x-capi")
    seen, todo, edges = set(), [root], {}
    while todo:
        i = todo.pop()
        if i in seen:
            continue
        seen.add(i)
        deps = {d["pkg"] for d in nodes[i]["deps"]
                if any(k["kind"] in (None, "normal") for k in d["dep_kinds"])}
        edges[i] = deps
        todo.extend(deps)
    return root, sorted((pkgs[i] for i in seen), key=lambda p: (p["name"], p["version"])), edges


def crates(yara_x):
    return crate_graph(yara_x)[1]


def lock_checksums(yara_x):
    """{(name, version, source): sha256} from the checkout's Cargo.lock (registry crates only)."""
    sums = {}
    for block in (yara_x / "Cargo.lock").read_text().split("[[package]]")[1:]:
        fields = dict(re.findall(r'^(name|version|source|checksum) = "(.*)"$', block, re.M))
        if "checksum" in fields:
            sums[(fields["name"], fields["version"], fields.get("source"))] = fields["checksum"]
    return sums
