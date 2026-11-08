#!/bin/sh
# Version of a local build, derived from the nearest release tag (#133).
#
#   v0.2.0 exactly, clean tree        -> 0.2.0
#   v0.2.0 exactly, uncommitted edits -> 0.2.0+dirty
#   5 commits after v0.2.0            -> 0.2.0+5.gabc1234
#   ... with uncommitted edits        -> 0.2.0+5.gabc1234.dirty
#   2 commits after v0.3.0-beta.1     -> 0.3.0-beta.1+2.gabc1234
#
# Commits after a tag go into SemVer build metadata (after "+"), which the
# update check ignores for ordering: a build after v0.2.0 compares equal to
# 0.2.0, so it is neither offered 0.2.0 again nor considered newer than
# 0.2.1, and a build after a stable tag stays on the stable channel.
#
# Without git, without a matching tag (e.g. a shallow CI clone), or with a
# tag that is not SemVer, the version comes from Resources/Info.plist
# (HEXWERK_VERSION_PLIST overrides the path). The release workflow passes
# VERSION from the tag and does not run this script.
#
#   scripts/version.sh                      version of the working tree
#   scripts/version.sh --describe <output>  map one `git describe` output (tests)
set -eu

# `git describe --tags --long --dirty` output -> version; fails (status 1)
# when the tag is not vMAJOR.MINOR.PATCH[-PRERELEASE].
from_describe() {
	d=$1
	dirty=
	case $d in *-dirty) dirty=1 d=${d%-dirty} ;; esac
	hash=${d##*-}
	d=${d%-*}
	count=${d##*-}
	tag=${d%-*}
	version=${tag#v}
	case $hash in g[0-9a-f]*) ;; *) return 1 ;; esac
	case $count in '' | *[!0-9]*) return 1 ;; esac
	printf '%s\n' "$version" | grep -Eq \
		'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$' || return 1
	if [ "$count" -eq 0 ]; then
		meta=
	else
		meta=$count.$hash
	fi
	[ -n "$dirty" ] && meta=${meta:+$meta.}dirty
	printf '%s%s\n' "$version" "${meta:++$meta}"
}

if [ "${1-}" = --describe ]; then
	from_describe "$2"
	exit
fi

if d=$(git describe --tags --long --dirty --abbrev=7 --match 'v[0-9]*' 2>/dev/null) && from_describe "$d"; then
	exit 0
fi
plist=${HEXWERK_VERSION_PLIST:-$(dirname "$0")/../Resources/Info.plist}
echo "version.sh: no release tag in git, version from $plist" >&2
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist"
