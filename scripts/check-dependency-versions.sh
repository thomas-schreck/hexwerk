#!/bin/sh
# Fails when the Homebrew YARA-X that would be linked differs from the version
# THIRD_PARTY_NOTICES.md was generated for: a release must ship the notices of
# exactly the crates it contains. Regenerate the notices with
# scripts/third-party-notices.py after a YARA-X update.
set -eu
cd "$(dirname "$0")/.."
want=$(sed -n 's/^## YARA-X \([0-9][0-9.]*\)$/\1/p' THIRD_PARTY_NOTICES.md | head -n 1)
have=$(brew list --versions yara-x | awk '{print $2}' | sed 's/_[0-9]*$//')
echo "YARA-X: notices $want, Homebrew $have"
echo "libmagic: Homebrew $(brew list --versions libmagic | awk '{print $2}')"
if [ -z "$want" ] || [ "$want" != "$have" ]; then
    echo "error: THIRD_PARTY_NOTICES.md is for YARA-X '$want' but Homebrew has '$have'." >&2
    echo "Regenerate it with scripts/third-party-notices.py <yara-x checkout of v$have>." >&2
    exit 1
fi
