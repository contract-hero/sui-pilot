#!/usr/bin/env bash
# Doc-count gate, companion to check-graph-pointers.sh.
#
# The bundled-doc counts are embedded by hand in five user-facing surfaces
# (README.md, llms.txt, CLAUDE.md, site/index.html, site/classic.html),
# but the authoritative numbers live in
# .last-sync, which sync-docs.sh rewrites on every corpus refresh. Nothing
# else ties the two together, and count drift has produced repeated fix-up
# commits (11e8008, 515039e, 813729f). This script fails when an embedded
# count is missing from its surface OR a stale count survives beside a
# correct one (every occurrence of a count-bearing phrase must carry the
# current number).
#
# SUI_PILOT_TOUR.html and EVAL_FRAMEWORK.html are exempt on purpose: they
# document past eval runs.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v jq >/dev/null || { echo "MISS: jq is required" >&2; exit 2; }
[ -r .last-sync ] || { echo "MISS: cannot read .last-sync" >&2; exit 2; }
jq -e '.fileCounts | type == "object" and length > 0' .last-sync >/dev/null 2>&1 \
  || { echo "MISS: .last-sync has no non-empty fileCounts object" >&2; exit 2; }

SURFACES=(README.md llms.txt CLAUDE.md site/index.html site/classic.html)
for f in "${SURFACES[@]}"; do
  [ -r "$f" ] || { echo "MISS: cannot read $f — update check-doc-counts.sh if the surface moved" >&2; exit 2; }
done

sui=$(jq -r '.fileCounts.sui' .last-sync)
walrus=$(jq -r '.fileCounts.walrus' .last-sync)
seal=$(jq -r '.fileCounts.seal' .last-sync)
tssdk=$(jq -r '.fileCounts["ts-sdks"]' .last-sync)
movebook=$(jq -r '.fileCounts["move-book"]' .last-sync)
prover=$(jq -r '.fileCounts["sui-prover"]' .last-sync)
total=$(jq -r '[.fileCounts[] | numbers] | add' .last-sync)
corpora=$(jq -r '.fileCounts | length' .last-sync)

for pair in "sui:$sui" "walrus:$walrus" "seal:$seal" "ts-sdks:$tssdk" \
            "move-book:$movebook" "sui-prover:$prover" "total:$total" "corpora:$corpora"; do
  key=${pair%%:*}; val=${pair#*:}
  case "$val" in
    ''|null|*[!0-9]*|0)
      echo "MISS: .last-sync fileCounts[\"$key\"] is \"$val\", not a positive integer — was the key renamed by sync-docs.sh?" >&2
      exit 2 ;;
  esac
done

# The CLAUDE.md Nautilus row counts a subdirectory, not a corpus, so
# .last-sync does not carry it — compute it the way sync-docs.sh would.
nautilus=$(find .sui-docs/sui-stack/nautilus -type f \( -name '*.mdx' -o -name '*.md' \) 2>/dev/null | wc -l | tr -d ' ')
[ "$nautilus" -gt 0 ] || { echo "MISS: .sui-docs/sui-stack/nautilus/ is empty or missing" >&2; exit 2; }

fail=0
check() { # file, exact-literal, label
  # Every occurrence of the phrase (digits generalized) must carry the
  # current number: n_loose counts lines matching the phrase with ANY
  # number, n_exact counts lines carrying the expected literal. A missing
  # phrase or a stale twin both fail.
  local file=$1 exact=$2 label=$3 loose n_exact n_loose
  loose=$(printf '%s' "$exact" | sed -E -e 's/[][^$.*+?(){}|\\]/\\&/g' -e 's/[0-9]+/[0-9]+/g')
  n_exact=$(grep -cF "$exact" "$file" || true)
  n_loose=$(grep -cE "$loose" "$file" || true)
  if [ "$n_exact" -gt 0 ] && [ "$n_exact" -eq "$n_loose" ]; then
    echo "OK   $file: $label ($n_exact occurrence(s))"
  else
    echo "FAIL $file: $label — $n_loose line(s) carry the phrase, $n_exact carry \"$exact\""
    fail=1
  fi
}

check README.md "**$total documentation files**" "total (intro)"
check README.md "($total files, $corpora corpora)" "total (header)"
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
check CLAUDE.md "| \`.sui-docs/sui-stack/nautilus/\` | $nautilus |" "nautilus"

check site/index.html "$total bundled docs" "total (meta+og)"
check site/index.html "'$total docs'" "total (hero tag)"
check site/index.html "$total files · $corpora corpora" "total (eyebrow)"
check site/index.html "'Sui · $sui'" "sui tag"
check site/index.html "'Move Book · $movebook'" "move-book tag"
check site/index.html "'TS SDK · $tssdk'" "ts-sdk tag"

check site/classic.html "$total bundled docs" "total (meta)"
check site/classic.html "$total documentation files" "total (lede)"
check site/classic.html "$total files &middot; $corpora sources" "total (diagram)"
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
