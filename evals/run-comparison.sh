#!/usr/bin/env bash
# evals/run-comparison.sh — run the eval suite against v1 (main, full
# sui-pilot with pipe-delimited preamble) and v2 (feat/v2-graph-port, slim
# sui-pilot), then auto-invoke `claude -p` to score the delta and emit a
# self-contained HTML report.
#
# Usage:
#   bash evals/run-comparison.sh                       # v1,v2 + auto-score
#   bash evals/run-comparison.sh --versions v2         # one version only
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
VERSIONS="v1,v2"
TASKS_FILE_OVERRIDE=""
TASK_IDS_FILTER=""

usage() {
    cat <<'USAGE'
Usage: bash run-comparison.sh [options]

Options:
  --v1-ref REF        git ref for v1 (default: main)
  --v2-ref REF        git ref for v2 (default: feat/v2-graph-port)
  --versions LIST     comma-separated subset of {v1,v2} (default: v1,v2)
                      "v1" = claude -p with sui-pilot at V1_REF
                      "v2" = claude -p with sui-pilot at V2_REF
  --resume DIR        reuse DIR as the results directory; tasks whose .diff
                      already exists in DIR/<version>/ are skipped. Combined
                      with --versions lets you backfill new arms without
                      re-spending API credits on already-captured ones.
  --tasks-file PATH   override the default tasks.json (e.g. tasks-nft.json)
  --task-ids REGEX    only run tasks whose id matches the extended regex
                      (e.g. '^task-nft-' for the NFT-app-only subset)
  --no-score          skip the auto-scoring claude -p turn at the end
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --v1-ref)     V1_REF="$2"; shift 2 ;;
        --v2-ref)     V2_REF="$2"; shift 2 ;;
        --versions)   VERSIONS="$2"; shift 2 ;;
        --resume)     RESUME_DIR="$2"; shift 2 ;;
        --tasks-file) TASKS_FILE_OVERRIDE="$2"; shift 2 ;;
        --task-ids)   TASK_IDS_FILTER="$2"; shift 2 ;;
        --no-score)   SCORE=false; shift ;;
        -h|--help)    usage; exit 0 ;;
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

if [[ -n "$TASKS_FILE_OVERRIDE" ]]; then
    TASKS_FILE="$TASKS_FILE_OVERRIDE"
fi
[[ -f "$TASKS_FILE" ]]    || { echo "ERROR: $TASKS_FILE missing" >&2; exit 1; }
[[ -d "$SUI_PILOT_DIR" ]] || { echo "ERROR: \$SUI_PILOT_DIR=$SUI_PILOT_DIR not a directory" >&2; exit 1; }

# Save the user's current branch so we can restore it on exit (success OR fail).
ORIGINAL_BRANCH=$(git -C "$SUI_PILOT_DIR" rev-parse --abbrev-ref HEAD)
trap 'echo "Restoring $SUI_PILOT_DIR to $ORIGINAL_BRANCH"; git -C "$SUI_PILOT_DIR" checkout "$ORIGINAL_BRANCH" >/dev/null 2>&1 || true' EXIT

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
# is true. Caller provides the claude_cmd array (e.g. `claude -p`).
run_one_task() {
    local version="$1"
    local id="$2"
    local fixture="$3"
    local prompt="$4"
    local compile_after="$5"   # "true" or "false"
    local ts_build_after="$6"  # "true" or "false"
    local ts_build_subdir="$7" # subdir under tmpdir to run pnpm in; "" if none
    shift 7
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
    # The `--build-env mainnet` flag is required — without it sui defaults to
    # `localnet` and refuses to fetch implicit framework deps, failing every
    # task uniformly (see the 2026-05-11T12-12-13Z run's env-wide compile
    # failure for the case study).
    if [[ "$compile_after" == "true" ]]; then
        if [[ "$HAVE_SUI" == "true" ]]; then
            local build_exit=0
            (cd "$tmpdir" && sui move build --build-env mainnet) \
                > "$RESULTS_DIR/$version/$id.build.out" \
                2> "$RESULTS_DIR/$version/$id.build.err" || build_exit=$?
            echo "$build_exit" > "$RESULTS_DIR/$version/$id.compile-exit"
        else
            echo "skipped" > "$RESULTS_DIR/$version/$id.compile-exit"
        fi
    fi

    # TypeScript build gate: optional, only when task asks for it AND pnpm is
    # available. Runs `pnpm install --offline && pnpm tsc --noEmit && pnpm build`
    # in the configured subdir. Each step's exit code is captured separately so
    # the grader can distinguish "won't install" from "won't typecheck".
    if [[ "$ts_build_after" == "true" ]]; then
        local ts_target="$tmpdir"
        [[ -n "$ts_build_subdir" ]] && ts_target="$tmpdir/$ts_build_subdir"
        if [[ -d "$ts_target" ]] && command -v pnpm >/dev/null 2>&1; then
            local install_exit=0 tsc_exit=0 build_exit=0
            (cd "$ts_target" && pnpm install --offline --prefer-offline) \
                > "$RESULTS_DIR/$version/$id.ts-install.out" \
                2> "$RESULTS_DIR/$version/$id.ts-install.err" || install_exit=$?
            if [[ "$install_exit" == "0" ]]; then
                (cd "$ts_target" && pnpm tsc --noEmit) \
                    > "$RESULTS_DIR/$version/$id.ts-typecheck.out" \
                    2> "$RESULTS_DIR/$version/$id.ts-typecheck.err" || tsc_exit=$?
                (cd "$ts_target" && pnpm build) \
                    > "$RESULTS_DIR/$version/$id.ts-build.out" \
                    2> "$RESULTS_DIR/$version/$id.ts-build.err" || build_exit=$?
            else
                tsc_exit="skipped-install-failed"
                build_exit="skipped-install-failed"
            fi
            printf 'install=%s\ntypecheck=%s\nbuild=%s\n' \
                "$install_exit" "$tsc_exit" "$build_exit" \
                > "$RESULTS_DIR/$version/$id.ts-exit"
        else
            echo "skipped" > "$RESULTS_DIR/$version/$id.ts-exit"
        fi
    fi

    # Diff post-state vs initial fixture.
    diff -ruN "$FIXTURES_ROOT/$fixture" "$tmpdir" \
        > "$RESULTS_DIR/$version/$id.diff" 2>/dev/null || true

    rm -rf "$tmpdir"
}

# ---- Run one version ----------------------------------------------------
run_one_version() {
    local version="$1"   # "v1" | "v2"
    local ref="$2"       # git ref to checkout in $SUI_PILOT_DIR

    echo ""
    echo "=== [$version] Switching $SUI_PILOT_DIR to $ref ==="
    git -C "$SUI_PILOT_DIR" fetch origin "$ref" 2>&1 | tail -2 || true
    git -C "$SUI_PILOT_DIR" checkout "$ref" 2>&1 | tail -2
    git -C "$SUI_PILOT_DIR" pull --ff-only origin "$ref" 2>&1 | tail -2 || true
    git -C "$SUI_PILOT_DIR" rev-parse HEAD > "$RESULTS_DIR/$version.sha"

    mkdir -p "$RESULTS_DIR/$version"

    local claude_cmd=(claude -p)

    local n=$(jq 'length' "$TASKS_FILE")
    local i=0
    while IFS= read -r task; do
        i=$((i+1))
        local id=$(echo "$task" | jq -r .id)

        # Optional id-filter (extended regex). Skip non-matching tasks but
        # still advance the counter so the [i/n] index reflects the full file.
        if [[ -n "$TASK_IDS_FILTER" ]] && ! [[ "$id" =~ $TASK_IDS_FILTER ]]; then
            continue
        fi

        local fixture=$(echo "$task" | jq -r .fixturePath)
        local prompt=$(echo "$task" | jq -r .prompt)
        local compile_after=$(echo "$task" | jq -r '.passCriteria.compileAfter // false')
        local ts_build_after=$(echo "$task" | jq -r '.passCriteria.tsBuildAfter // false')
        local ts_build_subdir=$(echo "$task" | jq -r '.passCriteria.tsBuildSubdir // ""')

        echo "[$version] [$i/$n] $id"
        echo "[$version/$id] start $(date -u +%H:%M:%S) prompt=\"${prompt:0:80}...\"" \
            >> "$RESULTS_DIR/run.log"

        run_one_task "$version" "$id" "$fixture" "$prompt" \
            "$compile_after" "$ts_build_after" "$ts_build_subdir" \
            "${claude_cmd[@]}"
    done < <(jq -c '.[]' "$TASKS_FILE")
}

# Run only the versions requested via --versions (default: both).
IFS=',' read -ra REQUESTED_VERSIONS <<< "$VERSIONS"
for v in "${REQUESTED_VERSIONS[@]}"; do
    case "$v" in
        v1) run_one_version "v1" "$V1_REF" ;;
        v2) run_one_version "v2" "$V2_REF" ;;
        *)  echo "ERROR: unknown version '$v' (must be v1 or v2)" >&2; exit 1 ;;
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
