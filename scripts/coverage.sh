#!/bin/sh
# Line coverage per module from the last `swift test --enable-code-coverage`
# run, as a Markdown table on stdout. Used by `make coverage` and the
# coverage workflow (which appends the output to $GITHUB_STEP_SUMMARY).
#
# Only code linked into the test bundle is measured: the CLI tests start the
# `hexwerk` binary as a separate process, so Sources/hexwerk and
# Sources/HexwerkApp do not show up.
set -eu
cd "$(dirname "$0")/.."

# SwiftPM's bin path differs between build systems; .build/debug is the
# classic location (a symlink with the newer one).
bin=""
for dir in "$(swift build --show-bin-path 2>/dev/null || true)" .build/debug; do
    if [ -n "$dir" ] && [ -f "$dir/codecov/default.profdata" ]; then bin=$dir; break; fi
done
if [ -z "$bin" ]; then
    echo "no coverage data: run 'swift test --enable-code-coverage' first" >&2
    exit 1
fi
tests=$(find "$bin" -maxdepth 1 -name '*.xctest' | head -n 1)
[ -n "$tests" ] || { echo "no test bundle in $bin" >&2; exit 1; }
exe="$tests/Contents/MacOS/$(basename "$tests" .xctest)"

echo "| Module | Lines | Missed | Line coverage |"
echo "|---|---:|---:|---:|"
# llvm-cov report columns: Filename Regions Missed Cover Functions Missed
# Executed Lines Missed Cover ... ($8 = lines, $9 = missed lines).
xcrun llvm-cov report "$exe" -instr-profile "$bin/codecov/default.profdata" |
    awk '$1 ~ /^Sources\// {
            split($1, p, "/"); m = p[2]
            if (!(m in lines)) order[++n] = m
            lines[m] += $8; missed[m] += $9
        }
        END {
            for (i = 1; i <= n; i++) {
                m = order[i]; tl += lines[m]; tm += missed[m]
                printf "| %s | %d | %d | %.1f %% |\n", m, lines[m], missed[m], lines[m] ? 100 * (lines[m] - missed[m]) / lines[m] : 0
            }
            printf "| **Total** | %d | %d | **%.1f %%** |\n", tl, tm, tl ? 100 * (tl - tm) / tl : 0
        }'
