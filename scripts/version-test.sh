#!/bin/sh
# Tests for scripts/version.sh (#133): the describe mapping and real
# repositories (tag, commits after it, dirty tree, no tag, shallow clone, no git).
set -eu
script=$(cd "$(dirname "$0")" && pwd)/version.sh
failures=0

check() {  # name, expected, actual
	if [ "$2" = "$3" ]; then
		echo "ok   $1"
	else
		echo "FAIL $1: expected '$2', got '$3'"
		failures=$((failures + 1))
	fi
}

describe() { "$script" --describe "$1" 2>/dev/null || echo "<rejected>"; }
check "exact tag" 0.2.0 "$(describe v0.2.0-0-gabc1234)"
check "exact tag, dirty" 0.2.0+dirty "$(describe v0.2.0-0-gabc1234-dirty)"
check "after tag" 0.2.0+5.gabc1234 "$(describe v0.2.0-5-gabc1234)"
check "after tag, dirty" 0.2.0+5.gabc1234.dirty "$(describe v0.2.0-5-gabc1234-dirty)"
check "pre-release tag" 0.3.0-beta.1 "$(describe v0.3.0-beta.1-0-gabc1234)"
check "after pre-release tag" 0.3.0-beta.1+2.gabc1234 "$(describe v0.3.0-beta.1-2-gabc1234)"
check "hyphen in pre-release" 1.0.0-rc-1+12.g0123456 "$(describe v1.0.0-rc-1-12-g0123456)"
check "non-semver tag" "<rejected>" "$(describe v1.2-0-gabc1234)"
check "leading zero" "<rejected>" "$(describe v01.2.3-0-gabc1234)"
check "not a describe output" "<rejected>" "$(describe abc1234)"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/hexwerk-version-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export GIT_CEILING_DIRECTORIES="$tmp"
plist=$tmp/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 9.8.7" "$plist" >/dev/null
export HEXWERK_VERSION_PLIST="$plist"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
version() { (cd "$1" && "$script" 2>/dev/null); }
g() { git -C "$tmp/repo" -c user.name=t -c user.email=t@example.invalid "$@"; }

mkdir "$tmp/nogit"
check "no git: plist" 9.8.7 "$(version "$tmp/nogit")"

git init -q "$tmp/repo"
echo a >"$tmp/repo/f" && g add f && g commit -qm a
check "no tag: plist" 9.8.7 "$(version "$tmp/repo")"
g tag -a v0.2.0 -m 0.2.0
g tag other-tag
check "repo at tag" 0.2.0 "$(version "$tmp/repo")"
echo b >"$tmp/repo/f"
check "repo at tag, dirty" 0.2.0+dirty "$(version "$tmp/repo")"
g commit -qam b && g commit -q --allow-empty -m c
h=$(g rev-parse --short=7 HEAD)
check "repo after tag" "0.2.0+2.g$h" "$(version "$tmp/repo")"
g tag -a not-a-version -m x
check "ignores non-version tags" "0.2.0+2.g$h" "$(version "$tmp/repo")"

# actions/checkout fetches one commit and no tags by default.
git clone -q --depth 1 --no-tags "file://$tmp/repo" "$tmp/shallow"
check "shallow clone without tags: plist" 9.8.7 "$(version "$tmp/shallow")"

[ "$failures" -eq 0 ] || { echo "$failures failure(s)"; exit 1; }
echo "all passed"
