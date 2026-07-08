#!/usr/bin/env bash
# Verify every "📖 docs:" pointer in the agent knowledge graph resolves to a
# real file or directory in the bundled corpora. Exit 1 on any miss.
set -euo pipefail
cd "$(dirname "$0")/.."
FILE="${1:-agents/sui-pilot-agent.md}"
fail=0
while IFS= read -r p; do
  if [ -e "$p" ]; then
    echo "OK   $p"
  else
    echo "MISS $p"
    fail=1
  fi
done < <(grep -oE '📖 docs: [^ ,)]+' "$FILE" | sed 's/📖 docs: //' | sort -u)
exit $fail
