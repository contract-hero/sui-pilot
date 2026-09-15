#!/usr/bin/env bash
# smoke-test-skills.sh — Verify bundled skills have valid frontmatter.
# Each skill must have non-empty 'name' and 'description' fields.
# Exits non-zero if any skill fails validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Discovered, not hardcoded — a roster listed by hand drifts from the tree every
# time a skill is added or removed.
[ -d "${PLUGIN_ROOT}/skills" ] || { echo "FAIL: ${PLUGIN_ROOT}/skills/ does not exist"; exit 1; }
SKILLS=()
shopt -s nullglob
for d in "${PLUGIN_ROOT}"/skills/*/; do
  SKILLS+=("$(basename "$d")")
done
shopt -u nullglob
[ ${#SKILLS[@]} -gt 0 ] || { echo "FAIL: no skills found under ${PLUGIN_ROOT}/skills/"; exit 1; }

PASS=0
FAIL=0

# Parse the value of a frontmatter key from a file.
parse_frontmatter_key() {
  local file="$1"
  local key="$2"
  awk '/^---/{n++; if(n==2) exit; next} n==1{print}' "$file" \
    | grep -E "^${key}:" \
    | sed -E "s/^${key}:[[:space:]]*//; s/[[:space:]]+$//" \
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
    # YAML block/folded headers — | |- |+ |2 > >- >+ >2 and combinations, with an
    # optional trailing comment — all mean "the body is on the following indented
    # lines". The marker itself proves nothing, so the body must be read. Matching
    # only '|' let a folded '>-' description pass as the two-character string,
    # never checking whether any description existed.
    #
    # Test a comment-stripped COPY: an inline description may legitimately contain
    # '#', and truncating it there would hide a real emptiness.
    marker="${desc_val%%#*}"
    marker="${marker%"${marker##*[![:space:]]}"}"         # rtrim what the strip left
    if [[ "$marker" =~ ^[|\>]([0-9]|[-+]){0,2}$ ]]; then
      block_body=$(awk '/^description:[[:space:]]*[|>]([0-9]|[-+]){0,2}[[:space:]]*$/{f=1; next} f{if(NF==0) next; if(/^[[:space:]]/){print; exit} exit}' "$skill_file")
      assert_nonempty "description (block)" "$block_body"
    else
      # A quoted empty string is two characters of text, not a description.
      desc_val="${desc_val%\"}"; desc_val="${desc_val#\"}"
      desc_val="${desc_val%\'}"; desc_val="${desc_val#\'}"
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
