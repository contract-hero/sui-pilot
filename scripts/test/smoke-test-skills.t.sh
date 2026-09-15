#!/usr/bin/env bash
# smoke-test-skills.t.sh — a test for the test.
#
# scripts/smoke-test-skills.sh once passed VACUOUSLY: it matched only the '|'
# block-scalar marker, so a folded 'description: >-' asserted the two-character
# marker string was non-empty and never read the body. Both skills added in that
# same change used '>-', so the gate silently stopped checking them. It shipped
# green and survived until human review.
#
# That class of bug is invisible by inspection, so it is pinned by mutation
# instead: build a throwaway plugin root per fixture and assert the exit code.
# Every "must FAIL" case below is a description that does not exist; every
# "must PASS" case is a description that does.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/../smoke-test-skills.sh"
[ -r "$GATE" ] || { echo "MISS: cannot read $GATE" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# mk <name> <expected-exit> <SKILL.md content with \n escapes>
mk() {
  local name="$1" want="$2" content="$3"
  local root="$WORK/$name"
  mkdir -p "$root/skills/$name" "$root/scripts"
  printf '%b' "$content" > "$root/skills/$name/SKILL.md"
  cp "$GATE" "$root/scripts/smoke-test-skills.sh"
  bash "$root/scripts/smoke-test-skills.sh" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then
    echo "  PASS  $name (exit $got)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name — wanted exit $want, got $got"
    FAIL=$((FAIL + 1))
  fi
}

echo "==> Gate must REJECT a missing description, in every scalar style"
mk folded-empty        1 '---\nname: folded-empty\ndescription: >-\n---\n\nbody\n'
mk folded-trailspace   1 '---\nname: folded-trailspace\ndescription: >- \n---\n\nbody\n'
mk literal-indent      1 '---\nname: literal-indent\ndescription: |2\n---\n\nbody\n'
mk folded-comment      1 '---\nname: folded-comment\ndescription: >- # folded\n---\n\nbody\n'
mk quoted-empty        1 '---\nname: quoted-empty\ndescription: ""\n---\n\nbody\n'
mk single-quoted-empty 1 "---\nname: single-quoted-empty\ndescription: ''\n---\n\nbody\n"
mk crlf-folded         1 '---\r\nname: crlf-folded\r\ndescription: >-\r\n---\r\n\r\nbody\r\n'
mk no-desc-key         1 '---\nname: no-desc-key\n---\n\nbody\n'
echo ""

echo "==> Gate must ACCEPT a real description, including the awkward-but-legal shapes"
mk inline-ok      0 '---\nname: inline-ok\ndescription: "A real description long enough to be useful."\n---\n\nbody\n'
mk folded-ok      0 '---\nname: folded-ok\ndescription: >-\n  A real folded description spanning\n  two lines of prose.\n---\n\nbody\n'
mk blankline-ok   0 '---\nname: blankline-ok\ndescription: >-\n\n  Body begins after a blank line, which YAML permits.\n---\n\nbody\n'
mk hash-inline-ok 0 '---\nname: hash-inline-ok\ndescription: "Trigger on #sui and #move hashtags in the prompt."\n---\n\nbody\n'
echo ""

echo "==> Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
