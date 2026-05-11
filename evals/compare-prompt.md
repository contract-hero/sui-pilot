You are scoring a 3-way A/B/C comparison of sui-pilot architectures against a fixed task suite. Each version was given the same prompt against the same fixture; the only difference is which sui-pilot version was active.

Arms (subset depending on what the runner was asked to do):

- `bare` — `claude -p --bare`. No plugin, no CLAUDE.md, no skills, no LSP. Pure model behaviour.
- `v1` — `claude -p` with sui-pilot at `V1_REF` (default `main`): pipe-delimited preamble + skills + MCP.
- `v2` — `claude -p` with sui-pilot at `V2_REF` (default `feat/v2-graph-port`): slim doc-first preamble + skills + MCP, no matcher pipeline.

Inputs:

- Tasks file: `TASKS_FILE_PLACEHOLDER` (JSON array; each entry has `id`, `title`, `fixturePath`, `prompt`, optional `category`, `passCriteria`, `rubric`)
- Results root: `RESULTS_DIR_PLACEHOLDER`
  - `<version>.sha` — git SHA recorded for that arm (literal `bare` for the bare arm)
  - `<version>/<task-id>.out` — model text (extracted from claude -p JSON)
  - `<version>/<task-id>.err` — model stderr
  - `<version>/<task-id>.diff` — `diff -ruN` of fixture vs post-run tmpdir; the canonical "what the model did" artefact
  - `<version>/<task-id>.tokens` — JSON usage block from `claude -p --output-format json`
  - `<version>/<task-id>.compile-exit` — present only when task's `passCriteria.compileAfter` is true; contents are `0` (compiled), a non-zero exit code, or the literal `skipped` (sui not installed)
  - `<version>/<task-id>.build.{out,err}` — `sui move build` output when the compile gate ran
- `tokens.csv` — pre-aggregated per-task per-version usage in CSV form. Columns: `version,task_id,input_tokens,output_tokens,cache_creation_input_tokens,cache_read_input_tokens`.
- Versions actually run: `VERSIONS_PLACEHOLDER` (comma-separated subset of `bare,v1,v2`).

## Scoring procedure

For each task in the tasks file, for each arm that was actually run, decide PASS / FAIL by applying these criteria **in order** (the first failing criterion is the reason; otherwise PASS):

1. **Target file present in diff.** If the task names a `passCriteria.file` that doesn't appear in `<version>/<id>.diff` as a modified file, FAIL with reason "no edit to target file".
2. **Content criteria** on the target file's post-state (reconstructable from the right-hand side of the diff):
   - If `passCriteria.containsRegex` is present, the regex must match (Perl-compatible). Comments are fine — the regex is the source of truth.
   - Else, if `passCriteria.containsString` is present, it must appear as a substring. **BUT**: reject the match if the only occurrence is inside a Move comment (`//` or `/* */`) — comment-only mentions are not implementations.
   - If `passCriteria.doesNotContainString` is present, that substring must NOT appear in the post-state (excluding comments).
   - If `passCriteria.alsoContainsString` is present, it must appear (same comment-exclusion rule).
3. **`additionalFiles`** (multi-file tasks): each entry in the array must satisfy its own `containsString` / `containsRegex` (same comment-exclusion rule).
4. **Compile gate** (`passCriteria.compileAfter: true`): the `<version>/<id>.compile-exit` file must contain `0`. A non-zero exit, missing file, or `skipped` value means: skipped → ignore (don't penalise — note in methodology); non-zero → FAIL with the first line of `<id>.build.err` as the reason.
5. **Rubric** (only when task has a `rubric` block): score each criterion 1-5 on the model's post-state diff using the rubric description as the lens. Sum the scores. If `sum >= rubric.passThreshold`, PASS; else FAIL with `"rubric: <sum>/<max>"`.

If multiple criteria fail, report the *first* failing one — that's the proximate cause.

## Output

Emit a single self-contained HTML document to stdout (semantic HTML5, inline `<style>` only — no external CSS or fonts). Structure:

```html
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>sui-pilot eval comparison</title>
<style>/* tasteful inline CSS — system font, restrained palette, table-friendly */</style>
</head><body>
<h1>sui-pilot eval comparison</h1>
<p><strong>Versions run:</strong> ...  <strong>Tasks:</strong> N  <strong>Date:</strong> ...</p>
<p><strong>SHAs:</strong> bare=<code>bare</code>, v1=<code>...</code>, v2=<code>...</code></p>

<h2>Headline</h2>
<table>
  <thead><tr><th></th><th>bare</th><th>v1</th><th>v2</th></tr></thead>
  <tbody>
    <tr><th>Pass rate</th><td>N/M</td><td>N/M</td><td>N/M</td></tr>
    <tr><th>Total input tokens</th><td>...</td><td>...</td><td>...</td></tr>
    <tr><th>Total output tokens</th><td>...</td><td>...</td><td>...</td></tr>
  </tbody>
</table>

<h2>Per-task results</h2>
<table>
  <thead><tr><th>Task</th><th>Category</th><th>bare</th><th>v1</th><th>v2</th><th>Notes</th></tr></thead>
  <tbody>
    <!-- one row per task; ✓ / ✗ cell with short reason on ✗ -->
  </tbody>
</table>

<h2>Differentiators</h2>
<p><strong>Plugin net value</strong> (tasks where v1 or v2 passes but bare fails): ...</p>
<p><strong>Architectural value</strong> (tasks where v1 and v2 disagree): ...</p>
<p><strong>All-pass</strong>: ...</p>
<p><strong>All-fail</strong>: ...</p>

<h2>Per-category breakdown</h2>
<!-- table grouping by task.category (tier-1, multi-file, ambiguous, stale-training, token-pressure) -->

<h2>Token economics</h2>
<!-- per-version totals, per-task averages, cache-hit ratio -->

<h2>Verdict</h2>
<p>One paragraph in plain English. Does v2 deliver measurable productivity gain over v1, or just token savings? Does the plugin (either shape) deliver value over bare? Name the specific tasks that drove the call.</p>

<h2>Methodology notes</h2>
<ul>
  <li>Skipped compile gates, grader edge cases, ambiguous rubric scores, anything unusual.</li>
</ul>
</body></html>
```

## Output rules

- Self-contained HTML only — no external CSS, no `<script>`, no images, no link tags pointing off-document. Inline `<style>` is required.
- Keep the body under ~1,200 words excluding the per-task table.
- The aggregate Pass rate row in **Headline** uses literal pass/fail from the scoring procedure above — no adjudication. If the rubric, compile gate, or comment-exclusion rule changes a verdict from the "literal substring" view, mention it in **Methodology notes** but trust the procedure.
- Per-version columns appear only for arms that were actually run (per `VERSIONS_PLACEHOLDER`). If only `v1,v2` ran, drop the `bare` column.
- Write the HTML directly to stdout. Do NOT save to a file. Do NOT call any tool other than reading the inputs.
