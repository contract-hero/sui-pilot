#!/usr/bin/env bash
# smoke-test-skills.sh — Verify bundled skills have valid frontmatter.
# Each skill must have non-empty 'name' and 'description' fields.
# Exits non-zero if any skill fails validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Discovered, not hardcoded — a roster listed by hand drifts from the tree every
# time a skill is added or removed.
SKILLS=()
for d in "${PLUGIN_ROOT}"/skills/*/; do
  SKILLS+=("$(basename "$d")")
done
[ ${#SKILLS[@]} -gt 0 ] || { echo "FAIL: no skills found under ${PLUGIN_ROOT}/skills/"; exit 1; }

PASS=0
FAIL=0

# Parse the value of a frontmatter key from a file.
parse_frontmatter_key() {
  local file="$1"
  local key="$2"
  awk '/^---/{n++; if(n==2) exit; next} n==1{print}' "$file" \
    | grep -E "^${key}:" \
    | sed -E "s/^${key}:[[:space:]]*//" \
    | head -1 || true
}

# Assert a value is a non-empty string; print result.
assert_nonempty() {
  local label="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "  FAIL: ${label} is empty"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: ${label} = ${value:0:60}"
    PASS=$((PASS + 1))
  fi
}

echo "==> Smoke-testing bundled skills"
echo ""

for skill in "${SKILLS[@]}"; do
  skill_file="${PLUGIN_ROOT}/skills/${skill}/SKILL.md"
  echo "  [${skill}]"

  # Check the file exists
  if [[ ! -f "$skill_file" ]]; then
    echo "  FAIL: skill file not found: ${skill_file}"
    FAIL=$((FAIL + 1))
    continue
  fi

  # Parse name
  name_val=$(parse_frontmatter_key "$skill_file" "name" || true)
  assert_nonempty "name" "$name_val"

  # Verify 'description:' key exists (may be block scalar)
  if grep -qE "^description:" "$skill_file"; then
    # Inline value, or a scalar marker for block/folded styles.
    desc_val=$(parse_frontmatter_key "$skill_file" "description" || true)
    # YAML block/folded markers: | |- |+ > >- >+ — all mean "the body is on the
    # following indented lines", so the marker itself proves nothing and the body
    # must be read. Matching only '|' let a folded '>-' description pass as the
    # two-character string, never checking whether any description existed.
    if [[ "$desc_val" =~ ^[|\>][-+]?$ ]]; then
      block_body=$(awk '/^description:[[:space:]]*[|>][-+]?[[:space:]]*$/{found=1; next} found{if(/^[[:space:]]/ && NF>0){print; exit} else {exit}}' "$skill_file")
      assert_nonempty "description (block)" "$block_body"
    else
      assert_nonempty "description" "$desc_val"
    fi
  else
    echo "  FAIL: 'description' key missing from frontmatter"
    FAIL=$((FAIL + 1))
  fi

  echo ""
done

echo "==> Results: ${PASS} passed, ${FAIL} failed"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
