#!/bin/sh
# Fails when the YARA-X that would be linked (from HOMEBREW_PREFIX, see
# Package.swift) differs from the version THIRD_PARTY_NOTICES.md was
# generated for: a release must ship the notices of exactly the crates it
# contains. Regenerate the notices with scripts/third-party-notices.py after
# a YARA-X update.
set -eu
cd "$(dirname "$0")/.."
prefix=${HOMEBREW_PREFIX:-$(brew --prefix)}
want=$(sed -n 's/^## YARA-X \([0-9][0-9.]*\)$/\1/p' THIRD_PARTY_NOTICES.md | head -n 1)
have=$(sed -n 's/^Version: *//p' "$prefix/lib/pkgconfig/yara_x_capi.pc" 2>/dev/null | head -n 1)
echo "YARA-X: notices $want, linked from $prefix: ${have:-not found}"
if [ -z "$want" ] || [ "$want" != "$have" ]; then
    echo "error: THIRD_PARTY_NOTICES.md is for YARA-X '$want' but $prefix has '${have:-none}'." >&2
    echo "Use scripts/build-yara-x.sh, or regenerate the notices with scripts/third-party-notices.py." >&2
    exit 1
fi
