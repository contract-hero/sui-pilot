#!/usr/bin/env bash
# Knowledge-graph doc-pointer gate, two phases:
#
#   1. RESOLUTION — every "📖 docs:" pointer in the agent knowledge graph must
#      resolve to a real file or directory in the bundled corpora.
#   2. COVERAGE (the iron rule) — every doc file in the corpora must be ON the
#      graph: reachable via an exact file pointer or an ancestor DIRECTORY
#      pointer. Corpus roots (.sui-docs/ etc.) earn no coverage credit, so the
#      rule can't be trivially satisfied by six root pointers.
#
# Exempt from coverage (transcluded partials / boilerplate, not routable docs):
#   */snippets/*, */legal/*, _-prefixed partials, 404.md, TermsOfService.md
#
# Also enforces the graph line ceiling (raised from 800 on 2026-07-22 when the
# iron rule landed).
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="${1:-agents/sui-pilot-agent.md}"
[ -r "$FILE" ] || { echo "MISS: cannot read $FILE" >&2; exit 2; }

MAX_LINES=1200
CORPORA=(.sui-docs .move-book-docs .walrus-docs .seal-docs .ts-sdk-docs .sui-prover-docs)
fail=0

# ── Phase 0: line ceiling ────────────────────────────────────────────────────
lines=$(wc -l < "$FILE" | tr -d ' ')
if [ "$lines" -gt "$MAX_LINES" ]; then
  echo "FAIL $FILE is $lines lines (ceiling: $MAX_LINES)"
  fail=1
else
  echo "OK   line count: $lines/$MAX_LINES"
fi

# ── Phase 1: every pointer resolves ──────────────────────────────────────────
# The regex also captures ", .path" continuations so comma-separated pointer
# lists check every path, not just the first; tr splits them back apart.
ptrs=$(grep -oE '📖 docs: [^ ,)]+(, \.[^ ,)]+)*' "$FILE" | sed 's/📖 docs: //' | tr ',' '\n' | sed 's/^ *//' | sort -u || true)
if [ -z "$ptrs" ]; then
  echo "FAIL no '📖 docs:' pointers found in $FILE"
  exit 1
fi
dir_ptrs=()
file_ptrs=()
while IFS= read -r p; do
  if [ -d "${p%/}" ]; then
    echo "OK   $p"
    dir_ptrs+=("${p%/}/")
  elif [ -e "$p" ]; then
    echo "OK   $p"
    file_ptrs+=("$p")
  else
    echo "MISS $p"
    fail=1
  fi
done <<< "$ptrs"

# ── Phase 2: every corpus doc is covered ─────────────────────────────────────
# Fail closed if a corpus root is missing — otherwise find silently scans
# nothing and coverage passes vacuously.
for c in "${CORPORA[@]}"; do
  [ -d "$c" ] || { echo "FAIL corpus dir missing: $c"; exit 1; }
done
# Empty-array expansions use the ${arr[@]+...} guard: macOS's default bash 3.2
# treats "${arr[@]}" of an empty array as unbound under `set -u`.
# Build the coverage prefix list: directory pointers minus bare corpus roots.
cover_dirs=()
for d in ${dir_ptrs[@]+"${dir_ptrs[@]}"}; do
  root_hit=false
  for c in "${CORPORA[@]}"; do
    [ "$d" = "$c/" ] && root_hit=true
  done
  $root_hit || cover_dirs+=("$d")
done

# NUL-delimited so a crafted path containing a newline can't split into
# fragments that each dodge the coverage check.
uncovered=0
while IFS= read -r -d '' f; do
  case "$f" in
    */snippets/*|*/legal/*|*/_*|*/404.md|*/TermsOfService.md) continue ;;
  esac
  covered=false
  for p in ${file_ptrs[@]+"${file_ptrs[@]}"}; do
    [ "$f" = "$p" ] && { covered=true; break; }
  done
  if ! $covered; then
    for d in ${cover_dirs[@]+"${cover_dirs[@]}"}; do
      [[ "$f" == "$d"* ]] && { covered=true; break; }
    done
  fi
  if ! $covered; then
    echo "UNCOVERED $f"
    uncovered=$((uncovered + 1))
    fail=1
  fi
done < <(find "${CORPORA[@]}" -type f \( -name '*.mdx' -o -name '*.md' -o -name '*.move' \) -print0 | sort -z)

if [ "$uncovered" -gt 0 ]; then
  echo "FAIL $uncovered corpus docs are not on the graph (iron rule: all docs on the graph)"
else
  echo "OK   coverage: all corpus docs are on the graph"
fi

exit $fail
