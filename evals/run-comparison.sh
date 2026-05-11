#!/usr/bin/env bash
# evals/run-comparison.sh — run the eval suite against bare claude (sui-pilot
# disabled + @-import masked, OAuth retained), v1 (main, full sui-pilot with
# pipe-delimited preamble) and v2 (feat/v2-graph-port, slim sui-pilot), then
# auto-invoke `claude -p` to score the delta and emit a self-contained HTML
# report.
#
# Bare-arm mechanics: `claude --bare` rejects OAuth/keychain auth and demands
# ANTHROPIC_API_KEY, which is billed separately from Claude Max plans. To stay
# on the user's existing OAuth, the "bare" arm instead:
#   1. Disables the sui-pilot plugin via `claude plugin disable sui-pilot`
#   2. Backs up + masks the `@~/.claude/sui-pilot/agents/sui-pilot-agent.md`
#      line in ~/.claude/CLAUDE.md
#   3. Runs tasks via plain `claude -p --output-format json` (NOT --bare)
#   4. Restores both via EXIT trap — even on Ctrl-C or crash
# Other installed plugins remain active during the bare arm — this is "no
# sui-pilot" not "no plugins", which is the actually-useful counterfactual.
#
# Usage:
#   bash evals/run-comparison.sh                       # bare,v1,v2 + auto-score
#   bash evals/run-comparison.sh --versions v1,v2      # skip bare
#   bash evals/run-comparison.sh --no-score            # run, skip auto-score
#   bash evals/run-comparison.sh --v1-ref X --v2-ref Y # custom refs
#   bash evals/run-comparison.sh --resume DIR          # reuse DIR, skip captured tasks
#
# Output:
#   evals/results/<UTC-ts>/<version>/<task-id>.out         model text (extracted from JSON)
#   evals/results/<UTC-ts>/<version>/<task-id>.err         model stderr
#   evals/results/<UTC-ts>/<version>/<task-id>.diff        post-state diff vs fixture
#   evals/results/<UTC-ts>/<version>/<task-id>.tokens      claude -p usage block (JSON)
#   evals/results/<UTC-ts>/<version>/<task-id>.raw.json    full claude -p JSON envelope
#   evals/results/<UTC-ts>/<version>/<task-id>.compile-exit (only if task.passCriteria.compileAfter)
#   evals/results/<UTC-ts>/<version>/<task-id>.build.{out,err} (only if compile gate ran)
#   evals/results/<UTC-ts>/tokens.csv                      aggregated token usage
#   evals/results/<UTC-ts>/score.html                      self-contained HTML report

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUI_PILOT_DIR="${SUI_PILOT_DIR:-$HOME/.claude/sui-pilot}"
TASKS_FILE="$SCRIPT_DIR/tasks.json"
COMPARE_PROMPT="$SCRIPT_DIR/compare-prompt.md"

V1_REF="main"
V2_REF="feat/v2-graph-port"
SCORE=true
RESUME_DIR=""
VERSIONS="bare,v1,v2"

usage() {
    cat <<'USAGE'
Usage: bash run-comparison.sh [options]

Options:
  --v1-ref REF        git ref for v1 (default: main)
  --v2-ref REF        git ref for v2 (default: feat/v2-graph-port)
  --versions LIST     comma-separated subset of {bare,v1,v2} (default: bare,v1,v2)
                      "bare" = sui-pilot temporarily disabled + @-import masked
                      "v1"   = claude -p with sui-pilot at V1_REF
                      "v2"   = claude -p with sui-pilot at V2_REF
  --resume DIR        reuse DIR as the results directory; tasks whose .diff
                      already exists in DIR/<version>/ are skipped. Combined
                      with --versions lets you backfill new arms without
                      re-spending API credits on already-captured ones.
  --no-score          skip the auto-scoring claude -p turn at the end
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --v1-ref)    V1_REF="$2"; shift 2 ;;
        --v2-ref)    V2_REF="$2"; shift 2 ;;
        --versions)  VERSIONS="$2"; shift 2 ;;
        --resume)    RESUME_DIR="$2"; shift 2 ;;
        --no-score)  SCORE=false; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -n "$RESUME_DIR" ]]; then
    [[ -d "$RESUME_DIR" ]] || { echo "ERROR: --resume $RESUME_DIR not a directory" >&2; exit 1; }
    RESULTS_DIR="$RESUME_DIR"
else
    RESULTS_DIR="$SCRIPT_DIR/results/$(date -u +%Y-%m-%dT%H-%M-%SZ)"
fi

# ---- Pre-flight ----------------------------------------------------------
for cmd in claude jq git diff mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' not on PATH." >&2
        echo "       claude:  npm i -g @anthropic-ai/claude-code" >&2
        echo "       jq:      brew install jq" >&2
        exit 1
    fi
done

if command -v sui >/dev/null 2>&1; then
    HAVE_SUI=true
else
    HAVE_SUI=false
    echo "NOTE: 'sui' not on PATH; tasks with passCriteria.compileAfter will skip the compile gate." >&2
fi

[[ -f "$TASKS_FILE" ]]    || { echo "ERROR: $TASKS_FILE missing" >&2; exit 1; }
[[ -d "$SUI_PILOT_DIR" ]] || { echo "ERROR: \$SUI_PILOT_DIR=$SUI_PILOT_DIR not a directory" >&2; exit 1; }

# Save the user's current branch so we can restore it on exit (success OR fail).
ORIGINAL_BRANCH=$(git -C "$SUI_PILOT_DIR" rev-parse --abbrev-ref HEAD)

# Bare-arm state: filled in by bare_setup, drained by bare_teardown.
BARE_BACKUP_DIR=""
BARE_PLUGIN_WAS_ENABLED="false"

cleanup() {
    local exit_code=$?
    # Restore bare-arm mutations first (most fragile state — must always restore).
    bare_teardown || true
    # Restore git branch.
    echo "Restoring $SUI_PILOT_DIR to $ORIGINAL_BRANCH"
    git -C "$SUI_PILOT_DIR" checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true
    return $exit_code
}
trap cleanup EXIT

bare_setup() {
    # Stop my-process from clobbering an in-progress restore: nest-guard.
    if [[ -n "$BARE_BACKUP_DIR" ]]; then
        echo "ERROR: bare_setup called twice without teardown" >&2
        return 1
    fi
    BARE_BACKUP_DIR=$(mktemp -d -t sui-pilot-bare-backup.XXXXXX)
    echo "=== [bare] disabling sui-pilot + masking @-import ==="
    echo "      backup dir: $BARE_BACKUP_DIR"
    # 1. Snapshot ~/.claude/CLAUDE.md and strip the sui-pilot @-import line.
    if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
        cp "$HOME/.claude/CLAUDE.md" "$BARE_BACKUP_DIR/CLAUDE.md.bak"
        # Remove any line containing the literal @-import path. Use a portable
        # sed invocation (BSD sed on macOS, GNU sed on Linux).
        sed -i.tmp '/@~\/\.claude\/sui-pilot\/agents\/sui-pilot-agent\.md/d' \
            "$HOME/.claude/CLAUDE.md"
        rm -f "$HOME/.claude/CLAUDE.md.tmp"
    fi
    # 2. Disable sui-pilot. Capture the result so teardown only re-enables
    #    what was originally on.
    if claude plugins list 2>/dev/null | grep -qE 'sui-pilot.*enabled'; then
        BARE_PLUGIN_WAS_ENABLED="true"
        claude plugin disable sui-pilot >/dev/null 2>&1 || \
            echo "WARN: claude plugin disable sui-pilot failed; continuing anyway" >&2
    fi
}

bare_teardown() {
    [[ -z "$BARE_BACKUP_DIR" ]] && return 0
    echo "=== [bare] restoring CLAUDE.md + re-enabling sui-pilot ==="
    if [[ -f "$BARE_BACKUP_DIR/CLAUDE.md.bak" ]]; then
        cp "$BARE_BACKUP_DIR/CLAUDE.md.bak" "$HOME/.claude/CLAUDE.md"
    fi
    if [[ "$BARE_PLUGIN_WAS_ENABLED" == "true" ]]; then
        claude plugin enable sui-pilot >/dev/null 2>&1 || \
            echo "WARN: claude plugin enable sui-pilot failed; restore manually" >&2
    fi
    rm -rf "$BARE_BACKUP_DIR"
    BARE_BACKUP_DIR=""
    BARE_PLUGIN_WAS_ENABLED="false"
}

mkdir -p "$RESULTS_DIR"
echo "Results directory: $RESULTS_DIR"

# Cache tasks.json + fixtures BEFORE any branch switch (the runner may live
# inside $SUI_PILOT_DIR; switching branches could erase $SCRIPT_DIR mid-run).
CACHE_DIR="$RESULTS_DIR/.cache"
mkdir -p "$CACHE_DIR"
cp -a "$TASKS_FILE" "$CACHE_DIR/tasks.json"
rm -rf "$CACHE_DIR/fixtures"
cp -a "$SCRIPT_DIR/fixtures" "$CACHE_DIR/fixtures"
TASKS_FILE="$CACHE_DIR/tasks.json"
FIXTURES_ROOT="$CACHE_DIR"

# ---- Run one task (for any version) -------------------------------------
# Extracts result text + usage from the claude -p JSON envelope, captures
# the diff, and runs the compile gate when task.passCriteria.compileAfter
# is true. Caller provides the claude_cmd array (e.g. "claude -p" or
# "claude -p --bare").
run_one_task() {
    local version="$1"
    local id="$2"
    local fixture="$3"
    local prompt="$4"
    local compile_after="$5"   # "true" or "false"
    shift 5
    local claude_cmd=("$@")

    # Skip if already captured (supports --resume).
    if [[ -s "$RESULTS_DIR/$version/$id.diff" ]]; then
        echo "[$version] $id  (skip: already in resume dir)"
        return 0
    fi

    echo "[$version] $id  ($(date -u +%H:%M:%S))"

    local tmpdir
    tmpdir=$(mktemp -d -t "sui-pilot-eval.XXXXXX")
    cp -a "$FIXTURES_ROOT/$fixture/." "$tmpdir/"

    # CRITICAL: stdin must be /dev/null. claude -p reads stdin in addition
    # to the positional prompt; inside a `while read` loop fed by process
    # substitution it would consume the remaining JSON.
    local exit_code=0
    (cd "$tmpdir" && CLAUDE_PROJECT_ROOT="$tmpdir" "${claude_cmd[@]}" --output-format json "$prompt" < /dev/null) \
        > "$RESULTS_DIR/$version/$id.raw.json" \
        2> "$RESULTS_DIR/$version/$id.err" || exit_code=$?

    echo "[$version/$id] end $(date -u +%H:%M:%S) exit=$exit_code" >> "$RESULTS_DIR/run.log"

    # Extract result text + usage from the JSON envelope. Fields may vary
    # by claude-code version; fall back to the raw file if parsing fails.
    jq -r '.result // .text // (.messages[] | select(.role=="assistant") | .content) // ""' \
        "$RESULTS_DIR/$version/$id.raw.json" 2>/dev/null \
        > "$RESULTS_DIR/$version/$id.out" \
        || cp "$RESULTS_DIR/$version/$id.raw.json" "$RESULTS_DIR/$version/$id.out"

    jq -c '.usage // {}' "$RESULTS_DIR/$version/$id.raw.json" 2>/dev/null \
        > "$RESULTS_DIR/$version/$id.tokens" \
        || echo '{}' > "$RESULTS_DIR/$version/$id.tokens"

    # Compile gate: optional, only when task asks for it AND sui is available.
    if [[ "$compile_after" == "true" ]]; then
        if [[ "$HAVE_SUI" == "true" ]]; then
            local build_exit=0
            (cd "$tmpdir" && sui move build) \
                > "$RESULTS_DIR/$version/$id.build.out" \
                2> "$RESULTS_DIR/$version/$id.build.err" || build_exit=$?
            echo "$build_exit" > "$RESULTS_DIR/$version/$id.compile-exit"
        else
            echo "skipped" > "$RESULTS_DIR/$version/$id.compile-exit"
        fi
    fi

    # Diff post-state vs initial fixture.
    diff -ruN "$FIXTURES_ROOT/$fixture" "$tmpdir" \
        > "$RESULTS_DIR/$version/$id.diff" 2>/dev/null || true

    rm -rf "$tmpdir"
}

# ---- Run one version ----------------------------------------------------
run_one_version() {
    local version="$1"   # "bare" | "v1" | "v2"
    local ref="${2:-}"   # optional; empty for "bare"

    echo ""
    if [[ "$version" == "bare" ]]; then
        bare_setup
        echo "=== [$version] Running with sui-pilot disabled ==="
        # SHA reflects whatever the user was on when bare ran — sui-pilot is
        # disabled, so the working tree is unchanged from $ORIGINAL_BRANCH.
        git -C "$SUI_PILOT_DIR" rev-parse HEAD > "$RESULTS_DIR/$version.sha"
    else
        echo "=== [$version] Switching $SUI_PILOT_DIR to $ref ==="
        git -C "$SUI_PILOT_DIR" fetch origin "$ref" 2>&1 | tail -2 || true
        git -C "$SUI_PILOT_DIR" checkout "$ref" 2>&1 | tail -2
        git -C "$SUI_PILOT_DIR" pull --ff-only origin "$ref" 2>&1 | tail -2 || true
        git -C "$SUI_PILOT_DIR" rev-parse HEAD > "$RESULTS_DIR/$version.sha"
    fi

    mkdir -p "$RESULTS_DIR/$version"

    # All three arms use plain `claude -p` (the bare arm gets its
    # "bare-ness" from the prior disable + @-import mask). Stay on OAuth.
    local claude_cmd=(claude -p)

    local n=$(jq 'length' "$TASKS_FILE")
    local i=0
    while IFS= read -r task; do
        i=$((i+1))
        local id=$(echo "$task" | jq -r .id)
        local fixture=$(echo "$task" | jq -r .fixturePath)
        local prompt=$(echo "$task" | jq -r .prompt)
        local compile_after=$(echo "$task" | jq -r '.passCriteria.compileAfter // false')

        echo "[$version] [$i/$n] $id"
        echo "[$version/$id] start $(date -u +%H:%M:%S) prompt=\"${prompt:0:80}...\"" \
            >> "$RESULTS_DIR/run.log"

        run_one_task "$version" "$id" "$fixture" "$prompt" "$compile_after" "${claude_cmd[@]}"
    done < <(jq -c '.[]' "$TASKS_FILE")
}

# Run only the versions requested via --versions.
IFS=',' read -ra REQUESTED_VERSIONS <<< "$VERSIONS"
for v in "${REQUESTED_VERSIONS[@]}"; do
    case "$v" in
        bare)
            run_one_version "bare"
            # Restore eagerly so v1/v2 see the normal plugin + CLAUDE.md state.
            bare_teardown
            ;;
        v1)   run_one_version "v1" "$V1_REF" ;;
        v2)   run_one_version "v2" "$V2_REF" ;;
        *)    echo "ERROR: unknown version '$v' (must be bare, v1, or v2)" >&2; exit 1 ;;
    esac
done

# ---- Aggregate token usage into tokens.csv ------------------------------
echo ""
echo "=== Aggregating token usage ==="
{
    echo "version,task_id,input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens"
    for v in "${REQUESTED_VERSIONS[@]}"; do
        if [[ -d "$RESULTS_DIR/$v" ]]; then
            for tfile in "$RESULTS_DIR/$v"/*.tokens; do
                [[ -e "$tfile" ]] || continue
                local_id=$(basename "$tfile" .tokens)
                # Best-effort field extraction; absent fields render as 0.
                jq -r --arg v "$v" --arg id "$local_id" \
                    '[$v, $id,
                      (.input_tokens // 0),
                      (.output_tokens // 0),
                      (.cache_creation_input_tokens // 0),
                      (.cache_read_input_tokens // 0)
                     ] | @csv' "$tfile" 2>/dev/null || true
            done
        fi
    done
} > "$RESULTS_DIR/tokens.csv"
echo "Token usage written to $RESULTS_DIR/tokens.csv"

echo ""
echo "=== Eval runs complete ==="
echo "Results: $RESULTS_DIR"

# ---- Auto-score with Claude ---------------------------------------------
if [[ "$SCORE" == "true" ]]; then
    if [[ ! -f "$COMPARE_PROMPT" ]]; then
        echo "WARN: $COMPARE_PROMPT missing; skipping auto-score." >&2
    else
        echo ""
        echo "=== Scoring delta with claude -p ==="
        scoring_prompt=$(cat "$COMPARE_PROMPT")
        scoring_prompt="${scoring_prompt//RESULTS_DIR_PLACEHOLDER/$RESULTS_DIR}"
        scoring_prompt="${scoring_prompt//TASKS_FILE_PLACEHOLDER/$TASKS_FILE}"
        scoring_prompt="${scoring_prompt//VERSIONS_PLACEHOLDER/$VERSIONS}"
        # Restore original branch BEFORE the scoring run so the scorer reads
        # whatever the user normally develops on (avoids confusion if v2 is buggy).
        git -C "$SUI_PILOT_DIR" checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true

        claude -p "$scoring_prompt" > "$RESULTS_DIR/score.html"
        echo "Scored report: $RESULTS_DIR/score.html"
    fi
fi

echo ""
echo "Done."
