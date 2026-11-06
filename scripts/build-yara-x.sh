#!/bin/sh
# Builds the YARA-X C API from source at the version THIRD_PARTY_NOTICES.md
# was generated for and installs it, together with Homebrew's libmagic, into
# one prefix that Package.swift and the Makefile use via HOMEBREW_PREFIX.
# Release builds therefore never depend on which bottle Homebrew offers.
#   scripts/build-yara-x.sh <prefix>
set -eu
prefix=$1
cd "$(dirname "$0")/.."
version=$(sed -n 's/^## YARA-X \([0-9][0-9.]*\)$/\1/p' THIRD_PARTY_NOTICES.md | head -n 1)
if [ ! -f "$prefix/lib/libyara_x_capi.a" ]; then
    src=$(mktemp -d)
    git clone --quiet --depth 1 --branch "v$version" https://github.com/VirusTotal/yara-x.git "$src/yara-x"
    command -v cargo-cinstall >/dev/null || cargo install cargo-c --locked --quiet
    (cd "$src/yara-x" && cargo cinstall --locked --release -p yara-x-capi --prefix "$prefix" --libdir "$prefix/lib")
    rm -rf "$src"
fi
brew_prefix=$(brew --prefix)
mkdir -p "$prefix/include" "$prefix/lib" "$prefix/share/misc"
ln -sf "$brew_prefix/include/magic.h" "$prefix/include/magic.h"
ln -sf "$brew_prefix/lib/libmagic.a" "$prefix/lib/libmagic.a"
ln -sf "$brew_prefix/share/misc/magic.mgc" "$prefix/share/misc/magic.mgc"
echo "YARA-X $version and libmagic in $prefix"
