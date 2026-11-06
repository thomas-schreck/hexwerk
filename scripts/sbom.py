#!/usr/bin/env python3
"""Generate the SPDX 2.3 SBOM of a hexwerk release.

Usage: scripts/sbom.py <version> [--yara-x <checkout>] [-o <output>]
       scripts/sbom.py --check <sbom.spdx.json>

Lists what the app and the command line tool contain: the Swift packages of
Package.resolved, YARA-X (`yara-x-capi`) with every Rust crate of its
dependency tree for aarch64-apple-darwin (as in THIRD_PARTY_NOTICES.md), and
libmagic. Without --yara-x the YARA-X source is cloned at the version of
THIRD_PARTY_NOTICES.md into a temporary directory; a given checkout must
have that version. The libmagic version is read from `magic.h` under
HOMEBREW_PREFIX (the prefix the build links from, see Package.swift) unless
--libmagic-version is given.

The output is deterministic: sorted, the namespace derived from the version,
the creation time from SOURCE_DATE_EPOCH, else the date of the commit of tag
v<version>, else of HEAD. The document is checked structurally before it is
written; --check runs only that check on an existing file.
"""
import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

from yara_x import REPO, ROOT, TARGET, checkout_version, crate_graph, lock_checksums, notices_version

PROJECT = "thomas-schreck/hexwerk"
# Licenses of the Swift packages, as in THIRD_PARTY_NOTICES.md.
SWIFT_LICENSES = {
    "swift-argument-parser": "Apache-2.0 WITH Swift-exception",
    "yams": "MIT",
}
CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"
RELATIONSHIPS = {"DESCRIBES", "DEPENDS_ON", "STATIC_LINK", "CONTAINS"}
SPDX_ID = re.compile(r"^SPDXRef-[A-Za-z0-9.-]+$")
PURL = re.compile(r"^pkg:[a-z]+/[^@\s]+@[^@\s]+$")
LICENSE_TOKEN = re.compile(r"^(\(|\)|AND|OR|WITH|[A-Za-z0-9.+-]+)$")


def spdx_id(*parts):
    return "SPDXRef-" + "-".join(re.sub(r"[^A-Za-z0-9.]+", "-", p) for p in parts)


def license_expr(cargo_license):
    """Cargo's license field as an SPDX expression (old `MIT/Apache-2.0` syntax included)."""
    if not cargo_license:
        return "NOASSERTION"
    return re.sub(r"\s*/\s*", " OR ", cargo_license.strip())


def package(ident, name, version, license, purl, download, supplier=None, checksum=None, comment=None):
    p = {
        "SPDXID": ident,
        "name": name,
        "versionInfo": version,
        "supplier": supplier or "NOASSERTION",
        "downloadLocation": download,
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": license,
        "copyrightText": "NOASSERTION",
    }
    if version is None:
        del p["versionInfo"]
    if purl:
        p["externalRefs"] = [{"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl",
                              "referenceLocator": purl}]
    if checksum:
        p["checksums"] = [{"algorithm": "SHA256", "checksumValue": checksum}]
    if comment:
        p["comment"] = comment
    return p


def creation_time(version):
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if not epoch:
        for ref in (f"v{version}^{{commit}}", "HEAD"):
            r = subprocess.run(["git", "-C", str(ROOT), "log", "-1", "--format=%ct", ref],
                               capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip():
                epoch = r.stdout.strip()
                break
    t = datetime.datetime.fromtimestamp(int(epoch or 0), datetime.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def libmagic_version():
    prefix = os.environ.get("HOMEBREW_PREFIX") or subprocess.check_output(["brew", "--prefix"], text=True).strip()
    header = pathlib.Path(prefix) / "include" / "magic.h"
    m = re.search(r"^#define\s+MAGIC_VERSION\s+(\d+)", header.read_text(), re.M)
    if not m:
        sys.exit(f"error: no MAGIC_VERSION in {header}")
    v = int(m.group(1))
    return f"{v // 100}.{v % 100:02d}"


def swift_packages():
    pins = json.loads((ROOT / "Package.resolved").read_text())["pins"]
    out = []
    for pin in sorted(pins, key=lambda p: p["identity"]):
        ident = pin["identity"]
        if ident not in SWIFT_LICENSES:
            sys.exit(f"error: no license known for Swift package {ident}; add it to SWIFT_LICENSES")
        url = pin["location"].removesuffix(".git")
        host_path = re.sub(r"^https://", "", url)
        owner, repo = host_path.split("/")[1:3]
        version = pin["state"]["version"]
        out.append((pin, package(
            spdx_id("Swift", ident), repo, version, SWIFT_LICENSES[ident],
            f"pkg:swift/{host_path}@{version}",
            f"git+{pin['location']}@{pin['state']['revision']}",
            supplier=f"Organization: {owner}")))
    return out


def crate_package(p, yara_x_version, checksums):
    source = p["source"]
    if source is None:      # YARA-X workspace crate
        download = f"git+{REPO}.git@v{yara_x_version}"
        supplier = "Organization: VirusTotal"
    elif source == CRATES_IO:
        download = f"https://crates.io/api/v1/crates/{p['name']}/{p['version']}/download"
        supplier = None
    else:
        download = source
        supplier = None
    return package(
        spdx_id("Crate", p["name"], p["version"]), p["name"], p["version"], license_expr(p["license"]),
        f"pkg:cargo/{p['name']}@{p['version']}", download, supplier=supplier,
        checksum=checksums.get((p["name"], p["version"], source)))


def build(version, yara_x, magic_version):
    root_id = "SPDXRef-Package-hexwerk"
    yara_x_version = checkout_version(yara_x)
    capi_id, crates, edges = crate_graph(yara_x)
    checksums = lock_checksums(yara_x)

    packages = [package(
        root_id, "hexwerk", version, "MIT", f"pkg:github/{PROJECT}@{version}",
        f"git+https://github.com/{PROJECT}.git@v{version}",
        supplier="Person: Thomas Schreck",
        comment="The hexwerk app (DMG, ZIP) and the hexwerk command line tool (tarball).")]
    rels = [("SPDXRef-DOCUMENT", "DESCRIBES", root_id)]

    for pin, p in swift_packages():
        packages.append(p)
        rels.append((root_id, "STATIC_LINK", p["SPDXID"]))
        if pin["identity"] == "yams":
            # The bundled copy has no version of its own, hence no purl.
            libyaml = package(
                "SPDXRef-Swift-yams-libyaml", "libyaml", None, "MIT", None, "NOASSERTION",
                comment=f"Bundled in Yams {p['versionInfo']} (Sources/CYaml).")
            packages.append(libyaml)
            rels.append((p["SPDXID"], "CONTAINS", libyaml["SPDXID"]))

    magic_id = spdx_id("Generic", "libmagic", magic_version)
    packages.append(package(
        magic_id, "libmagic", magic_version, "BSD-2-Clause", f"pkg:generic/libmagic@{magic_version}",
        f"https://astron.com/pub/file/file-{magic_version}.tar.gz", supplier="Organization: file project",
        comment="Statically linked; the compiled database magic.mgc is bundled."))
    rels.append((root_id, "STATIC_LINK", magic_id))

    ids = {}
    for c in crates:
        p = crate_package(c, yara_x_version, checksums)
        if c["id"] == capi_id:
            p["comment"] = (f"YARA-X {yara_x_version} C API, statically linked as libyara_x_capi.a "
                            f"(pkg:github/VirusTotal/yara-x@v{yara_x_version}).")
        ids[c["id"]] = p["SPDXID"]
        packages.append(p)
    for c in crates:
        for dep in edges[c["id"]]:
            rels.append((ids[c["id"]], "DEPENDS_ON", ids[dep]))
    rels.append((root_id, "STATIC_LINK", ids[capi_id]))

    if len({p["SPDXID"] for p in packages}) != len(packages):
        sys.exit("error: duplicate SPDX identifiers")
    head = packages[:1]
    packages = head + sorted(packages[1:], key=lambda p: p["SPDXID"])
    rels = [{"spdxElementId": a, "relationshipType": t, "relatedSpdxElement": b}
            for a, t, b in sorted(set(rels))]
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"hexwerk-{version}",
        "documentNamespace": f"https://github.com/{PROJECT}/releases/v{version}/hexwerk-{version}.spdx.json",
        "creationInfo": {
            "created": creation_time(version),
            "creators": ["Tool: hexwerk-scripts/sbom.py", "Person: Thomas Schreck"],
            "comment": f"Components of the hexwerk {version} release artifacts for {TARGET}. "
                       "Rust crates are the normal dependencies of yara-x-capi.",
        },
        "documentDescribes": [root_id],
        "packages": packages,
        "relationships": rels,
    }


def check(doc):
    """Structural check of the fields SPDX 2.3 requires and the conventions used here."""
    errors = []

    def need(cond, msg):
        if not cond:
            errors.append(msg)

    need(doc.get("spdxVersion") == "SPDX-2.3", "spdxVersion")
    need(doc.get("dataLicense") == "CC0-1.0", "dataLicense")
    need(doc.get("SPDXID") == "SPDXRef-DOCUMENT", "document SPDXID")
    need(bool(doc.get("name")), "document name")
    need(re.match(r"^https?://\S+$", doc.get("documentNamespace", "")) and "#" not in doc["documentNamespace"],
         "documentNamespace")
    info = doc.get("creationInfo", {})
    need(re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", info.get("created", "")), "creationInfo.created")
    need(info.get("creators") and all(re.match(r"^(Tool|Person|Organization): \S", c) for c in info["creators"]),
         "creationInfo.creators")
    ids = set()
    for p in doc.get("packages", []):
        pid = p.get("SPDXID", "")
        where = f"package {pid or p.get('name')}"
        need(SPDX_ID.match(pid), f"{where}: SPDXID")
        need(pid not in ids, f"{where}: duplicate SPDXID")
        ids.add(pid)
        for field in ("name", "downloadLocation", "licenseConcluded", "licenseDeclared", "copyrightText"):
            need(p.get(field), f"{where}: {field}")
        need(p.get("filesAnalyzed") is False, f"{where}: filesAnalyzed")
        for field in ("licenseConcluded", "licenseDeclared"):
            expr = p.get(field, "")
            need(expr in ("NOASSERTION", "NONE") or
                 all(LICENSE_TOKEN.match(t) for t in expr.replace("(", " ( ").replace(")", " ) ").split()),
                 f"{where}: {field} {expr!r}")
        for ref in p.get("externalRefs", []):
            if ref.get("referenceType") == "purl":
                need(PURL.match(ref.get("referenceLocator", "")), f"{where}: purl")
        for c in p.get("checksums", []):
            need(c.get("algorithm") == "SHA256" and re.match(r"^[0-9a-f]{64}$", c.get("checksumValue", "")),
                 f"{where}: checksum")
    need(len(ids) > 1, "packages")
    described = doc.get("documentDescribes", [])
    need(described and all(d in ids for d in described), "documentDescribes")
    known = ids | {"SPDXRef-DOCUMENT"}
    for r in doc.get("relationships", []):
        need(r.get("relationshipType") in RELATIONSHIPS, f"relationship type {r.get('relationshipType')}")
        need(r.get("spdxElementId") in known and r.get("relatedSpdxElement") in known,
             f"relationship {r.get('spdxElementId')} -> {r.get('relatedSpdxElement')}")
    related = {r["relatedSpdxElement"] for r in doc.get("relationships", [])}
    need(all(i in related for i in ids), "every package is reachable from a relationship")
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("version", nargs="?")
    ap.add_argument("--yara-x", type=pathlib.Path, help="YARA-X source checkout (default: clone it)")
    ap.add_argument("--libmagic-version", help="default: MAGIC_VERSION from $HOMEBREW_PREFIX/include/magic.h")
    ap.add_argument("-o", "--output", type=pathlib.Path)
    ap.add_argument("--check", type=pathlib.Path, metavar="SBOM", help="only check an existing SBOM")
    args = ap.parse_args()

    if args.check:
        errors = check(json.loads(args.check.read_text()))
        for e in errors:
            print(f"error: {args.check}: {e}", file=sys.stderr)
        sys.exit(1 if errors else 0)
    if not args.version:
        ap.error("version required")

    want = notices_version()
    magic = args.libmagic_version or libmagic_version()
    with tempfile.TemporaryDirectory() as tmp:
        yara_x = args.yara_x
        if yara_x is None:
            yara_x = pathlib.Path(tmp) / "yara-x"
            subprocess.check_call(["git", "clone", "--quiet", "--depth", "1", "--branch", f"v{want}",
                                   f"{REPO}.git", str(yara_x)])
        yara_x = yara_x.resolve()
        if checkout_version(yara_x) != want:
            sys.exit(f"error: {yara_x} is YARA-X {checkout_version(yara_x)}, THIRD_PARTY_NOTICES.md is for {want}")
        doc = build(args.version, yara_x, magic)

    errors = check(doc)
    if errors:
        sys.exit("error: invalid SBOM:\n  " + "\n  ".join(errors))
    out = args.output or ROOT / "dist" / f"hexwerk-{args.version}.spdx.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    crates = sum(1 for p in doc["packages"] if p["SPDXID"].startswith("SPDXRef-Crate-"))
    print(f"{out}: {len(doc['packages'])} packages ({crates} Rust crates), {len(doc['relationships'])} relationships")


if __name__ == "__main__":
    main()
