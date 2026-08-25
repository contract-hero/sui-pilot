#!/usr/bin/env bash
# Doc-count gate, companion to check-graph-pointers.sh.
#
# The bundled-doc counts are embedded by hand in five user-facing surfaces
# (README.md, llms.txt, CLAUDE.md, site/index.html, site/classic.html), but
# the authoritative numbers live in .last-sync, which sync-docs.sh rewrites
# on every corpus refresh. Nothing else ties the two together, and count
# drift has produced repeated fix-up commits (11e8008, 515039e, 813729f).
# This script fails when any embedded count no longer matches .last-sync.
#
# SUI_PILOT_TOUR.html is exempt on purpose: it documents a past eval run.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v jq >/dev/null || { echo "MISS: jq is required" >&2; exit 2; }
[ -r .last-sync ] || { echo "MISS: cannot read .last-sync" >&2; exit 2; }

sui=$(jq -r '.fileCounts.sui' .last-sync)
walrus=$(jq -r '.fileCounts.walrus' .last-sync)
seal=$(jq -r '.fileCounts.seal' .last-sync)
tssdk=$(jq -r '.fileCounts["ts-sdks"]' .last-sync)
movebook=$(jq -r '.fileCounts["move-book"]' .last-sync)
prover=$(jq -r '.fileCounts["sui-prover"]' .last-sync)
total=$(jq -r '[.fileCounts[]] | add' .last-sync)

fail=0
check() { # file, fixed-string pattern, label
  if grep -qF "$2" "$1"; then
    echo "OK   $1: $3"
  else
    echo "FAIL $1: $3 — expected \"$2\""
    fail=1
  fi
}

check README.md "**$total documentation files**" "total (intro)"
check README.md "($total files, 6 corpora)" "total (header)"
check README.md "| **Sui** | $sui |" "sui"
check README.md "| **Move Book** | $movebook |" "move-book"
check README.md "| **Walrus** | $walrus |" "walrus"
check README.md "| **TS SDK** | $tssdk |" "ts-sdk"
check README.md "| **Sui Prover** | $prover |" "sui-prover"
check README.md "| **Seal** | $seal |" "seal"

check llms.txt "~$total documentation files" "total"
check llms.txt "(.sui-docs/): $sui MDX files" "sui"
check llms.txt "(.move-book-docs/): $movebook files" "move-book"
check llms.txt "(.walrus-docs/): $walrus MDX files" "walrus"
check llms.txt "(.seal-docs/): $seal MDX files" "seal"
check llms.txt "(.ts-sdk-docs/): $tssdk MDX files" "ts-sdk"
check llms.txt "(.sui-prover-docs/): $prover files" "sui-prover"

check CLAUDE.md "| \`.sui-docs/\` | $sui |" "sui"
check CLAUDE.md "| \`.move-book-docs/\` | $movebook |" "move-book"
check CLAUDE.md "| \`.walrus-docs/\` | $walrus |" "walrus"
check CLAUDE.md "| \`.seal-docs/\` | $seal |" "seal"
check CLAUDE.md "| \`.ts-sdk-docs/\` | $tssdk |" "ts-sdk"
check CLAUDE.md "| \`.sui-prover-docs/\` | $prover |" "sui-prover"

check site/index.html "$total bundled docs" "total (meta)"
check site/index.html "'$total docs'" "total (hero tag)"
check site/index.html "$total files · 6 corpora" "total (eyebrow)"
check site/index.html "'Sui · $sui'" "sui tag"
check site/index.html "'Move Book · $movebook'" "move-book tag"
check site/index.html "'TS SDK · $tssdk'" "ts-sdk tag"

check site/classic.html "$total bundled docs" "total (meta)"
check site/classic.html "$total documentation files" "total (lede)"
check site/classic.html "$total files &middot; 6 sources" "total (diagram)"
check site/classic.html "<strong>Sui</strong> <span>$sui files" "sui"
check site/classic.html "<strong>Move Book</strong> <span>$movebook files" "move-book"
check site/classic.html "<strong>Walrus</strong> <span>$walrus files" "walrus"
check site/classic.html "<strong>TS SDK</strong> <span>$tssdk files" "ts-sdk"
check site/classic.html "<strong>Sui Prover</strong> <span>$prover files" "sui-prover"
check site/classic.html "<strong>Seal</strong> <span>$seal files" "seal"

if [ "$fail" -ne 0 ]; then
  echo "FAIL embedded doc counts have drifted from .last-sync — update them (see check names above)"
  exit 1
fi
echo "OK   all embedded doc counts match .last-sync (total: $total)"
