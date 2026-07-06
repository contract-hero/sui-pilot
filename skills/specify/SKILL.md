---
name: specify
description: "Walks the user through writing `#[spec(prove)]` formal specifications for every externally reachable function (`public` non-package + `entry`) in their Sui Move package. Emits the specs into a separate sibling `<pkg>_specs/` package (keeping production source pristine), drives sui-prover via the sui-prover-mcp, and produces an invariant-driven HTML report plus a `spec-context.json` reproducibility manifest. Use this skill when the user invokes `/specify`, asks to 'add formal verification', 'write prover specs', 'verify this package with sui-prover', or wants to harden a Move package before mainnet deploy. Skip for `public(package)` or private functions (out of scope), or when sui-prover isn't installed. Complements /move-code-review (SEC-* findings indicate where specs matter most)."
---

# Specify — formal specifications for Sui Move

> **Doc-First Requirement.** Read `.sui-prover-docs/` at the plugin root before drafting any spec. The Sui Prover spec language is **not** the legacy Move Prover MSL — it uses `#[spec(prove)]`, `requires`, `ensures`, `asserts` (positive abort form), and the macros `clone!`, `forall!`, `exists!`, `invariant!`. It does NOT use `aborts_if`, `pragma`, `apply`, `assume`, or free `axiom`. Verify any construct against `.sui-prover-docs/guide/spec-reference.md` before emitting it.

## Deliverable shape (read first)

`/specify` ships **three artifacts**, not one. This is the load-bearing architectural decision (`docs/specify-deliverable-design.html`, learning L1, validated against `~/workspace/integer-library`):

1. **The production package — left pristine.** No `#[spec_only]`, no prover dependency, no marker blocks. Verification scaffolding never touches deployed source.
2. **One or more spec packages.** A sibling `<pkg>_specs/` package holds `#[spec(prove, target = <pkg>::<mod>::<fn>)]` twins, one `<mod>_specs.move` per source module. A function that needs a custom prover invocation (e.g. `--no-bv-int-encoding` for bit-exact semantics) goes in a *second* package `<pkg>_specs_bv/` (Phase 4.6).
3. **The report + manifest.** A self-contained HTML report (invariant-driven, per Phase 5) plus `spec-context.json` binding each spec to its source state, dep pins, toolchain versions, and per-package prover flags.

The legacy inline layout (specs in the production `.move` between markers) is now **opt-in only** via `--inline`, for single-module throwaway packages where a sibling package is overkill. Default is always the separate package.

## Non-interactive (eval) mode

This skill is **interactive by default**. In hosts with a structured user-input tool, use it for decision gates; in Codex sessions without that tool, ask concise plain-text questions and wait. Non-interactive mode activates via **either** of two triggers:

1. **Environment-flag trigger.** Before doing anything else, run `echo "${SPECIFY_AUTO_DEFAULTS:-}"` via Bash. If the output is exactly `1`, this run is in non-interactive mode (typically because `evals/run-comparison.sh` or a similar headless rig is driving it).
2. **Verbal-directive trigger.** The user has explicitly said something like *"don't stop"*, *"don't pause"*, *"work autonomously"*, *"no questions"*, *"proceed without asking"*, or *"no-pause"* in the current conversation. A `Stop` hook with an autonomy-oriented condition counts as such a directive.

When non-interactive mode is active:

- **Skip every interactive gate.** Pick the first option (the suggested default) and announce the choice in plain text instead.
- **Surface a single-line acknowledgement in chat** the first time you enter the non-interactive branch: *"Entering non-interactive mode (trigger: <env-flag | verbal-directive>) — picking defaults at every gate."* The elision must be auditable; never skip a decision gate silently.
- **Abort hard on any `setup_warning` of severity error.** Don't surface "proceed anyway" — write the warning to `.specify-report.html`, exit Phase 0, and return. (Warnings of severity `info` like `private_dependency` advisories surface in the report but don't abort.)
- **Cap iterations at 1.** The Phase 4 loop tries once per function; failures get marked `needs_human` immediately instead of looping. Eval harnesses care about the discovery + draft signal, not multi-attempt convergence.
- **Cap prioritization batch.** Process every pending function in default priority order — no user picks.
- **Persist progress as usual.** `.specify-progress.json` and `.specify-report.html` must still land at the package root so the eval scorer can read them.

Interactive mode (neither trigger active) is the default — every gate runs normally.

## Architecture

This skill is a multi-phase, per-function orchestrator. It uses:

- `mcp__sui-prover__prover_capabilities` — startup probe (binary, toolchain, setup warnings)
- `mcp__sui-prover__list_specs` — idempotency and resume
- `mcp__sui-prover__prove_package` — verification, including `target_function` filter
- `mcp__move-lsp__move_diagnostics` — compile-health gate
- `mcp__move-lsp__move_find_references` — call-cascade traversal
- `mcp__move-lsp__move_goto_definition` — callee inspection
- File search/read tools — visibility classification (the LSP does **not** return visibility on document symbols; see `references/spec-patterns.md` §1 for the regex contract this skill uses). In Codex, prefer `rg --files`, `rg`, and normal file reads; in Claude Code, `Glob` / `Grep` / `Read` are fine.
- Structured user-input tool when available — every gate where intent is human-supplied. In Codex sessions without that tool, ask concise plain-text questions and wait.

## Phase 0 — Validate (single shot)

Phase 0 is a **hard gate**. If any of the four checks below surfaces an error, write the diagnostic to `.specify-progress.json` (with structured `blocker.kind`) and `.specify-report.html`, then exit — do not proceed to Phase 1. The cost of running Phase 1's discovery sweep on an un-buildable package is wasted budget; the LSP and dep-reachability checks here cost <1s and save minutes downstream.

1. **Binary probe.** Call `mcp__sui-prover__prover_capabilities` with `move_toml_path` set to the user's package root. Read the response: `binary.found`, `binary.sui_prover_flags` (the flag list belongs to **sui-prover**, not `sui move build` — don't forward it to the Sui CLI), `setup_warnings`, `git_dependencies`.

2. **Compile-health gate.** Call `mcp__move-lsp__move_diagnostics` with `scope: 'file'` on any one `.move` file under `sources/`. **If it returns any `severity: 'error'` diagnostic referencing `unresolved external module`, `unresolved named address`, `unbound module`, or a git-fetch failure**, the package is un-buildable as-is — record `blocker.kind = "compile_unresolvable"` and exit Phase 0. Do not proceed to function inventory until diagnostics return at least one resolvable file.

3. **Dep-reachability gate** (interactive: prompt; non-interactive: warn + continue). For each entry in `git_dependencies`, run `git ls-remote --exit-code --quiet <url> HEAD` with a 3s timeout. Unreachable URLs (auth failure, repo missing, timeout) are likely private repos the local SSH identity can't access — surface them as `setup_warnings` of kind `private_dependency` and either prompt the user (Option A: grant access, B: substitute a local clone via `[dependencies.NAME]` with `local = "..."`, C: skip the package, D: proceed anyway) or, in non-interactive mode, record the unreachable list in `.specify-progress.json` under `blocker.unreachable_deps[]` and continue with a soft warning. **The single most common /specify blocker on real packages is private-dep unreachability — surface it before Phase 1's inventory sweep.**

4. **Binary missing.** If `binary.found === false`:
   - **Interactive mode**: STOP, ask the user to `brew install asymptotic-code/sui-prover/sui-prover`.
   - **Non-interactive mode** (`SPECIFY_AUTO_DEFAULTS=1` or verbal-directive): enter **discovery-only** mode — Phase 1 still runs and writes `.specify-progress.json` (so eval rigs like `task-28-specify-discovery` get the function set on a runner that lacks the binary); skip the per-function prove loop (Phase 4.6) entirely; mark every discovered function with `status: "discovery_only"` in the progress file; emit a `.specify-report.html` noting the binary was absent; exit cleanly.

5. **setup_warnings.** If `setup_warnings` is non-empty (explicit `Sui`/`MoveStdlib` deps, non-2024 edition, private deps surfaced by step 3):
   - Surface every warning verbatim.
   - Ask the user in one batch: "fix Move.toml myself first / proceed anyway (specs may not compile) / abort". Default suggestion: "fix first".
   - **Non-interactive mode**: abort hard (per the contract at the top of this file); the eval harness needs a deterministic exit.
   - **Never auto-edit the user's Move.toml.** Surface the line to change and let them do it.

## Phase 1 — Discover externally reachable functions

Per the plan, the target set is `public` (non-package) + `entry`. Use the regex contract in `references/spec-patterns.md` §1 — **not** `move_document_symbols`, which collapses all visibilities to `kind: 'function'`.

1. Enumerate `sources/**/*.move` under the package root (`rg --files sources -g '*.move'` in Codex; `Glob` is fine in Claude Code).
2. For each `.move` file:
   - Read the file.
   - Strip line and block comments.
   - Apply the visibility regex (`references/spec-patterns.md` §1). Classify each `fun` declaration as `public`, `public(package)`, `entry`, `macro`, `native`, or private.
   - **Exclude** the immediately-preceding `#[test_only]`, `#[test]`, or `#[allow(...)]` attribute lines from the classifier window (lookback ≤ 1 attribute block, not 200 chars).
3. Build the target list: every `public` (excluding `public(package)`) + every `entry` (including those that are also `public`).
4. Call `mcp__sui-prover__list_specs` with the package root.
5. Mark each target as `verified` (carries `#[spec(prove)]` — a `focus` selector *alongside* `prove`, i.e. `#[spec(prove, focus)]`, is still `verified`; `focus` is an orthogonal debugging selector, not a partial state, though it should be stripped before commit) or `pending` (no spec yet). Mark as `partial` only a `#[spec(skip)]` (opaque axiom needing a real spec) or a **lone `#[spec(focus)]` without `prove`**.
6. Write `.specify-progress.json` at the package root with the initial state. **Add it to `.gitignore` proactively if it's not already excluded** — the file is per-run state, not source.

Report a one-line summary: "N externally-reachable functions: M verified, K pending, P partial".

**Empty target set.** If the target list is empty (no `public`/`entry` functions — everything is private or `public(package)`), there is no external API to specify: write `.specify-progress.json` with `functions: {}`, emit a short report noting "no externally-reachable functions to specify", and exit cleanly — skip Phases 1.5–5's per-function work.

## Phase 1.5 — Scope decision + callee-quality probe

Before launching Phase 2's per-function loop, two cheap checks decide *what* gets specified and *how rigorously*:

**(a) Scope decision.** If `N > 25`, ask the user how to scope:

- Ask in a single decision batch, options: "spec the whole package (large — may take a session) / pick a prioritized subset (recommended, default) / pick a single module to start with / single function".
- **Non-interactive mode**: pick "prioritized subset" using the Phase 3 ranking (invariant > swap > deposit/withdraw > getters > admin caps). Codify the heuristic instead of improvising; the eval harness needs reproducible scope.
- For *math kernel* packages with an `invariant`-named function family, the invariant is almost always the right first target — it's the smallest atomic spec and every downstream swap/deposit/withdraw spec depends on its semantics.

**(b) Callee-quality probe.** Before drafting any spec, sample the callees called inside the target functions:

1. For each external callee not already in the target set, read its source.
2. If every public function body in the callee's module is `abort 0` or `native`, the module is a **stub** — its bytecode interface is published but the real source isn't shipped (common with `published-at` deps and proprietary fixed-point math packages).
3. **If any stub callee is detected**, surface it in `.specify-progress.json` under `callee_quality[]` and warn the user: *"Module `<X>` is a stub (every body is `abort 0`). Specifying functions that call into it requires axiomatic modeling — see `references/spec-patterns.md` §4.10 — or every verification will be vacuous (the prover concludes every caller path aborts)."*

The right escape is the canonical `#[spec(skip, target = <stub_fn>)]` idiom documented in `references/spec-patterns.md` §4.10 and Phase 4.5 below.

## Phase 2 — Build cascade context (lazy, per-function)

For each function the user is about to spec:

1. `mcp__move-lsp__move_find_references` on the function's declaration position → list of callers.
2. For each callee invoked inside the function body (parsed from source reads):
   - `mcp__move-lsp__move_goto_definition` to find the callee's location.
   - Read the callee's source up to 30 lines.
   - Note whether the callee already has a spec via the Phase 1 map.
3. Limit depth to 2 by default. Cycle-detect with a visited set keyed on `<file>:<line>`. If the call graph exceeds 25 nodes for a single function, prompt the user (Phase 4 gate) to confirm before continuing.

The output of this phase is a per-function fact sheet the user sees during Phase 4: signature, abort conditions (extracted from `assert!(...)` lines in the body), state mutations (look for `*<binding> = ...` and `vector::push_back` / `table::add` calls), and callees with their spec status.

## Phase 3 — Prioritize

Order pending functions:

1. `entry` functions first (PTB-callable, highest blast radius).
2. Then `public` functions that take `&mut` references or write to `Table` / `Bag` / dynamic fields (highest mutation risk).
3. Then `public` functions that only read state (lower risk, often simpler specs).

Ask in a single decision batch:
- "Specify all `N` pending functions in the default order"
- "Pick one to start with" (offer the top 5 by priority)
- "Pick a subset" (offer to filter by module or by mutation risk)

## Phase 3.5 — Scaffold the spec package (default layout)

The default deliverable is a **separate sibling spec package**, not inline specs (see "Deliverable shape" above; design doc L1). Scaffold it once, before the per-function loop.

1. **Locate / create `<pkg>_specs/`.** Resolve the production package name from `[package].name` in `Move.toml`. The spec package lives as a sibling directory `<pkg>_specs/` (snake-cased), with this layout:

   ```
   <pkg>_specs/
     Move.toml          # name = "<Pkg>Specs", edition = "2024.beta", dep on the production pkg
     sources/           # one <mod>_specs.move per source module
   ```

   `Move.toml` template — depend on the production package by relative path, declare the spec address:

   ```toml
   [package]
   name = "<Pkg>Specs"
   edition = "2024.beta"

   [dependencies]
   <Pkg> = { local = "../<pkg>" }

   [addresses]
   <pkg>_specs = "0x0"
   ```

   **Addresses resolve through the dep — declare only the spec package's own.** The `[addresses]` block above declares *only* `<pkg>_specs`. The production package's named address (`<pkg>`) is supplied by the `local` dependency; do **not** redeclare it here (a second concrete value for `<pkg>` triggers `dep_address_conflict`). If the production package publishes its address (`published-at` / a fixed `<pkg> = "0x…"`), the dep carries that automatically. If it leaves `<pkg> = "0x0"` (unpublished), that's fine — the prover assigns it at build. A first-prove `unresolved_named_address` (failure-taxonomy) means the dep path is wrong, not that you should add `<pkg>` to the spec package's `[addresses]`. Worked shape:

   ```toml
   # production pkg's own Move.toml has:  [addresses]\n  <pkg> = "0x0"
   # spec pkg declares ONLY its own address; <pkg> flows in via the local dep:
   [dependencies]
   <Pkg> = { local = "../<pkg>" }
   [addresses]
   <pkg>_specs = "0x0"     # NOT <pkg>
   ```

2. **Announce, don't silently create.** Creating the sibling package is the documented default, so it does **not** need a per-run AskUserQuestion gate — but announce it in plain text: *"Scaffolding spec package `<pkg>_specs/` (production source stays untouched)."* In **non-interactive mode**, proceed without prompting. The production package is never modified in the default flow.

3. **`--inline` opt-out.** If the user passed `--inline` (or the package is a single trivial module and the user opted in at Phase 1.5), skip scaffolding and use the legacy in-source marker-block layout (Phase 4.5 "Inline fallback"). Record the chosen layout in `.specify-progress.json` under `layout: "package" | "inline"` so resume is deterministic.

4. **Second package for custom prover configs is lazy.** Do *not* create `<pkg>_specs_bv/` up front. It's created on demand in Phase 4.6 only when a spec is found to need a non-default prover invocation. Most packages never need it.

## Phase 4 — Per-function loop

For each pending function (sequentially — parallelism would race the user-input gates):

### 4.1 Surface (LLM)

Present a compact fact sheet to the user inside the structured question description when available, or immediately before the plain-text question in Codex:

- Module + function name + signature
- Caller list (top 5)
- Callees with spec status
- Detected `assert!(cond, EError)` lines (these become candidate `asserts(cond)` entries)
- Detected state mutations
- Suggested invariants (LLM-derived from the body — explicitly mark as "suggestion, not proof")
- Excerpts from `.sui-prover-docs/examples/` for any pattern that matches (overflow, ghost state, bag/table)

### 4.2 Elicit

**One batched call** with up to 4 sub-questions, each with 3-4 options + Other. Concrete defaults so the user can accept fast:

1. **Abort conditions (`asserts`)** — *ask first; for math/arithmetic kernels the abort contract is the security property* (L2). Present the detected `assert!` mirrors plus any implicit abort paths (div-by-zero, shift-out-of-range, overflow in non-wrapping fns): "use all detected mirrors / use a subset / replace with custom / does not abort". The answer becomes both an `asserts(...)` in the spec **and** the report's required "Abort conditions" line (Phase 5).
2. **Postconditions (`ensures`)** — offer two tiers, recommend the stronger:
   - **Defining-property (recommended, L4)**: the algebraic property that *defines* the result independent of the formula. E.g. floor division: `result*d <= p < (result+1)*d`; `div_mod`: `p*d + r == num && r < d`. Strictly stronger than recomputation — a wrong mental model can't pass against a wrong implementation.
   - **Functional result**: `result == <recompute the formula>` (suggested: `result == x + y`). The weakest useful spec; offer only when no defining property exists.
   - Plus "state-after-call relation / none / Other".
3. **Preconditions (`requires`)**: "none / parameter range check (suggested: `x.to_int().add(y.to_int()).lte(MAX_U64)`) / state precondition / Other"
4. **Invariants**: "none needed / loop invariant / type invariant / ghost-state invariant / Other"

For functions over a **custom numeric type** (a wrapper struct over an integer field — signed ints, fixed-point), the postcondition should be expressed in the `Integer` math domain via the type's `to_int` model (L3) — see `references/spec-patterns.md` §6 and Phase 4.3.

### 4.3 Draft (LLM)

**Emit the math-domain model first (L3).** If the target operates on a custom numeric type (a `struct` wrapping an integer field — signed ints, fixed-point), and the spec module does not yet contain the model, emit it once at the top of the `<mod>_specs.move` file before any spec: a `to_int` conversion into `std::integer::Integer`, a range predicate (`is_<type>`), any helper ops (`int_div_trunc`, `int_abs`, …), and `use fun` aliases so specs read like the math. See `references/spec-patterns.md` §6 for the full template. This is what makes signed-int / fixed-point specs tractable — without it they drown in two's-complement bit-fiddling.

**Render the twin in the separate-package shape (default, L1).** The spec lives in `<pkg>_specs/sources/<mod>_specs.move` and references the production function by `target =`:

```move
module <pkg>_specs::<mod>_specs;

use <pkg>::<mod>::{<fn>, /* types used in the signature */};

#[spec_only]
use prover::prover::{ensures, asserts, requires, clone};

#[spec(prove, target = <fn>)]
public fun <fn>_spec(<params>): <return_type> {
    requires(<preconditions>);
    let __old = clone!(<mutable_state>);     // only if state mutation detected
    asserts(<abort_condition>);              // one per detected mirror + implicit paths
    let <r> = <fn>(<args>);                   // must call the target
    ensures(<defining_property_postcondition>);
    <r>
}
```

The `target = <fn>` attribute binds the spec to the imported production function; the spec body **must call** the target (see failure-taxonomy `spec_target_body_no_call`). The templates use the **bare** `target = <fn>` because the function is in scope via the `use <pkg>::<mod>::{<fn>}` import (the proven integer-library idiom); if it isn't imported, use the qualified `target = <pkg>::<mod>::<fn>` — see `references/spec-patterns.md` §3. Imports of the production functions/types go in a plain `use <pkg>::<mod>::{...}` block; only the `prover::*` imports get `#[spec_only]`.

**Inline shape (`--inline` opt-out only).** When the user chose the inline layout, render the legacy in-source twin (no `target =`, spec named `<fn>_spec`, written between markers in the production `.move`) per `references/spec-patterns.md` §2. Never use the inline shape in the default flow.

### 4.4 Review

Show the drafted spec inline. Single question:
- "Looks good — write it"
- "Refine" (provide feedback in Other field; loop to 4.3)
- "Skip this function" (mark `skipped` in progress file; move on)

### 4.5 Persist (deterministic)

**Default — separate package (L1).** Write the twin into `<pkg>_specs/sources/<mod>_specs.move` (one spec module per source module). If the file doesn't exist yet, create it with the module header, the `use <pkg>::<mod>::{...}` production imports, the `#[spec_only] use prover::prover::{...}` block, and the math-domain model (Phase 4.3, if applicable). The production package is **never touched**.

```move
module <pkg>_specs::<mod>_specs;

use <pkg>::<mod>::{<fn>, /* types */};

#[spec_only]
use prover::prover::{ensures, asserts, requires, clone};

// (math-domain model here, if the module specs a custom numeric type — §6)

#[spec(prove, target = <fn>)]
public fun <fn>_spec(<params>): <return_type> { ... }
```

**Idempotency rule.** Key on the `target = <fn>` attribute. If a spec for that target already exists in the module, never duplicate it — ask the user (4.4-style) whether to refine or overwrite. Splice new imports into the existing `use` blocks, deduplicated.

**Sidecar axiom file** (when the production package has stub callees — every dep body is `abort 0`). Axioms model the stubbed callees of the production package, so they live in the spec package as `<pkg>_specs/sources/specify_axioms.move`:

```move
module <pkg>_specs::specify_axioms;

#[spec_only]
use prover::prover::{fresh};
use utilities::fixed;

// Opaque summaries for stub callees. `skip` tells the prover not to verify
// the body; `target = …` registers this function as the abstract contract
// substituted at call sites of the target.
#[spec(skip, target = fixed::mul_down)]
fun mul_down_spec(_a: u256, _b: u256): u256 { fresh() }

#[spec(skip, target = fixed::ln)]
fun ln_spec(_x: u256): u256 { fresh() }
```

This is the canonical way to axiomatize external/stubbed dependencies — see `references/spec-patterns.md` §4.10. **Every axiom is trusted, not proved** — record each one for the report's "Trusted axioms" disclosure (Phase 5, L6).

**Inline fallback (`--inline` only).** When the user chose the inline layout at Phase 3.5, write the spec at the bottom of the production `.move` between markers, named `<fn>_spec` with no `target =`:

```move
// === sui-pilot specify: generated specs (do not edit between markers) ===
#[spec_only]
use prover::prover::{requires, ensures, asserts, clone};

#[spec(prove)]
fun <name>_spec(...) { ... }
// === end sui-pilot specify ===
```

Idempotency: if the marker block exists, splice into it; never duplicate a `#[spec(...)]` for the same function.

### 4.6 Verify (MCP)

`mcp__sui-prover__prove_package` with `move_toml_path` pointed at the **spec package** (`<pkg>_specs/Move.toml`), `target_function: "<pkg>_specs::<mod>_specs::<fn>_spec"`, and `timeout_seconds: 60` (configurable). In the `--inline` fallback the target is `<pkg>::<mod>::<fn>_spec` against the production `Move.toml`.

**Custom prover config → second spec package (L5).** Some functions can only be proved under a non-default prover invocation — most commonly bit-exact bitwise/shift/wrapping semantics that need `--no-bv-int-encoding` (the integer encoding can't model them). When a spec fails or times out and the diagnosis (Phase 4.7) points at bit-level reasoning:

1. Create `<pkg>_specs_bv/` on demand (same scaffold as Phase 3.5, distinct name `<Pkg>SpecsBV`, address `<pkg>_specs_bv`).
2. Move that one spec there and re-verify with the flag set, e.g. `extra_args: ["--no-bv-int-encoding"]`.
3. Record the function's package + flag set in `.specify-progress.json` under `prover_flags` so Phase 5's manifest and report can show *which encoding each spec needed and why* (itself an audit-relevant fact — it signals the property is bit-level).

Most packages never need a `_bv` package; create it only when a spec actually demands it.

### 4.7 Diagnose failures

If `findings` contains a failure for this spec, consult `references/failure-taxonomy.md` — each `findings[].kind` maps to a documented remediation. Common kinds:

- `ensures_failed` → narrow postcondition or strengthen preconditions
- `asserts_failed` → missing/incorrect mirror of an `assert!`
- `abort_unspecified` → add an `asserts()` for an implicit abort path
- `timeout` → try `--split-paths`, then per-spec `boogie_opt` tuning
- `no_spec` on a callee → spec that callee first, or add `no_opaque` to bypass
- `spec_target_body_no_call` → spec function with `#[spec(target = X)]` must call `X` in its body, or use `#[spec(skip, target = X)]` for an opaque axiom
- `dep_address_conflict` → duplicate `[addresses]` entries; reconcile in `Move.toml`
- `unresolved_named_address` / `unresolved_module` → missing entry in `[addresses]` or `[dependencies]`
- `dep_fetch_failure` → private repo or network failure (rerun Phase 0 step 3)
- `function_not_found` → `target_function` doesn't match any spec in the package (typo, or stale build cache; the spec must follow the `<fn>_spec` naming convention)
- `no_specs_to_prove` → the package compiled but no `#[spec(prove)]` block exists yet (expected on the first run; abnormal after Phase 3)

Use `summary.overall` (one of `verified_all` / `failed_some` / `no_specs` / `compile_failure` / `timeout` / `error`) as the single trustworthy "did this run succeed?" signal — don't try to reconcile `summary.verified === 0` with `findings.length > 0` yourself, the MCP already did it.

### 4.8 Iterate

After surfacing the diagnostic + remediation suggestion:
- "Apply suggested fix" (loop to 4.3 with the suggestion seeded)
- "Try a different angle" (loop to 4.2 with the prior answers preserved)
- "Mark as needs-human" (record in progress file; continue to next function)
- "Skip this function"

Default `attempts ≤ 3` per function. Configurable via Phase 3 batch.

### 4.9 Persist progress

Update `.specify-progress.json` after each iteration. Schema:
```json
{
  "layout": "package" | "inline",
  "spec_packages": ["<pkg>_specs", "<pkg>_specs_bv"],
  "trusted_axioms": [
    { "target": "fixed::mul_down", "file": "<pkg>_specs/sources/specify_axioms.move", "assumption": "unconstrained — no postcondition" }
  ],
  "functions": {
    "<mod>::<fn>": {
      "status": "pending" | "drafted" | "verified" | "skipped" | "needs_human" | "failed" | "discovery_only",
      "attempts": N,
      "last_error": "...",
      "spec_package": "<pkg>_specs",
      "prover_flags": ["--no-bv-int-encoding"],
      "abort_conditions": "aborts unless shift < 128",
      "invariant": "INV-supply-conservation"
    }
  }
}
```
Each function is keyed by its **`function_id` = `<mod>::<fn>`** — the same key form as the manifest's `source_hashes` (Phase 5.1), so progress and manifest align and resume matches reliably. `layout`, `spec_packages`, and per-function `prover_flags` / `spec_package` make resume deterministic and feed Phase 5's manifest. `trusted_axioms` accumulates every `#[spec(skip, target = …)]` for the report's disclosure section. `discovery_only` is the status set in Phase 0 step 4 when the prover binary is absent (discovery ran, no proving).

## Phase 5 — Hand off (deliverable)

When the user pauses, or when all pending functions are processed, emit the full deliverable. Per "Deliverable shape" this is the manifest + the report; the spec packages already exist on disk from Phase 4.

### 5.1 Verification-context manifest (Q4 / L5)

Write `spec-context.json` next to the report. It binds the proof to the state it was proved against, so a reviewer can reproduce it:

```json
{
  "generated_at": "<ISO8601>",
  "hash_method": "bytecode" | "normalized_source",
  "production_package": { "name": "<pkg>", "source_hashes": { "<mod>::<fn>": "<16-hex>" } },
  "spec_packages": [
    { "name": "<pkg>_specs",    "flags": [] },
    { "name": "<pkg>_specs_bv", "flags": ["--no-bv-int-encoding"] }
  ],
  "deps": [ { "name": "...", "rev": "...", "pinned_to_branch": false } ],
  "toolchain": { "sui_prover": "...", "sui_cli": "...", "boogie": "...", "z3": "..." }
}
```

**Hash recipe (exact — `/verify` Phase 2a mirrors this byte-for-byte).** Hashes are **per-function**, keyed `<mod>::<fn>` (the same key form as `.specify-progress.json` `functions`). `hash_method` defaults to `normalized_source` in v1:

- `normalized_source` (default): take the function's full source span — from its first attribute/`fun` line through the matching closing brace — strip line (`//`) and block (`/* */`) comments, then collapse every run of whitespace (including newlines) to a single space and trim. Hash the resulting bytes with `sha2_256` and record the **first 16 hex chars**. Comment/format reflows therefore do not register as drift; any token change does.
- `bytecode` (opt-in, requires a build): hash the function's compiled bytecode slice from `build/<pkg>/bytecode_modules/<mod>.mv`. Closer to what the prover sees, but needs a successful `sui move build`; prefer `normalized_source` unless the user asks for bytecode binding.

Reuse `dep-pins-capture` logic for the `deps` block rather than duplicating it. Toolchain versions come from the Phase 0 `prover_capabilities` probe. **v1 is manifest-only** — capture, no preflight clone, no drift enforcement (those are roadmap v2/v3; design doc Q4).

### 5.2 The report — invariant-driven, hybrid granularity (Q5 / Q1)

Write per-module `<mod>.spec.html` next to each spec module, plus a package-level `index.html`. `--single-file` collapses to one file for tiny packages. Each file is self-contained semantic HTML5 with inline CSS (match the house style in `docs/*.html`).

**Structured sections via markers (Q2).** Machine-derived zones regenerate every run; human-authored prose is preserved. Wrap each:

```html
<!-- specify:auto:begin coverage-matrix -->  ... regenerated ...  <!-- specify:auto:end -->
<!-- specify:human:begin intent-INV-supply-conservation -->  ... preserved ...  <!-- specify:human:end -->
```

On regen, replace only content between `auto:` markers; never touch `human:` zones.

**Module report structure (invariant-driven):**
1. Module overview (`specify:human`).
2. **Invariants** — one entry per property the module guarantees. Each carries: statement (formal + prose), functions involved, and the required sections: **Abort conditions** (L2 — the exact abort set per function, or "does not abort"), **Threat model**, **Proof obligations** (the defining-property `ensures` from Phase 4.2 *are* the obligations), plus the Q2 template (Intent / Alternatives / Limitations / Open questions). Counterexamples appear here under `--audit` only.
3. **Function-local guarantees** — bucket for specs with no cross-cutting invariant.
4. **Function index (appendix, auto)** — every spec'd fn: signature, the two source hashes (production fn + spec), prover-flag set if non-default, → links to the invariant(s) it serves.

Invariants are named human-readable + stable slug (`INV-supply-conservation`); the source→invariant link is an explicit `// invariant: supply-conservation` marker above the `#[spec(prove)]` in the spec module (survives report regen).

**Limitations section must enumerate trusted axioms (L6).** Under a "Trusted axioms — not proved" heading, list every `#[spec(skip, target = …)]` from `.specify-progress.json` `trusted_axioms[]` (target + file + the assumption in prose) **and** every hand-written Boogie axiom from any `extra_bpl` file used (wired via the `#[spec_only(extra_bpl = b"…")]` attribute — see `references/spec-patterns.md` §8.1). These are holes in the verification — a wrong axiom makes the proof vacuous, so they're the auditor's first read.

**Package `index.html`:** package overview + top-level claim; cross-module invariants with proof-obligation mapping (which spec in which module discharges which obligation); coverage matrix (module × invariant, every externally-reachable fn marked specified / deliberately-skipped / known-gap *with a reason* — negative space is first-class, L9); per-module summaries with links; the manifest's toolchain + dep pins.

### 5.3 `--audit` extras (opt-in)

Only when the user passed `--audit`:

- **Counterexample regressions (L7).** When a spec produced a counterexample during Phase 4, persist the failing input + the offending production snippet as a named regression beside the spec (the integer-library pattern: keep the buggy fn so the spec demonstrably fails on it). Leaner than a freeform journal and doubles as a vacuity check.
- **CI stub (L8).** Emit a `.github/workflows/prover.yml` stub that brew-installs sui-prover and runs it once per spec package with that package's flag set (from the manifest). This *is* drift enforcement — frame `/verify --strict` as "the thing CI runs."

### 5.4 Summary

1. Print a one-screen chat summary: "X verified, Y drafted-but-failing, Z needs-human, K skipped. Spec package(s): `<pkg>_specs[, <pkg>_specs_bv]`. Report at `<path>`."
2. Offer to `git diff` the spec package(s) so the user can review (production source is unchanged — call that out explicitly).
3. Point the user at the consumer: once specs are in place, **`/verify`** re-proves them against current code and flags drift using the `spec-context.json` this phase emitted (`/verify --strict` is the CI posture). `/specify` authors; `/verify` checks.

## Resumability

Any run starts at Phase 0 → Phase 1, then loads `.specify-progress.json` and skips entries with `status: "verified"`. Entries with `status` in `{pending, drafted, failed}` resume mid-loop with the prior attempt count preserved. The user can manually edit `.specify-progress.json` to reset a function's state.

## Operating rules

- **Never modify the production package in the default flow.** No `#[spec_only]`, no prover dependency, no marker blocks in the production source; no edits to the production `Move.toml`. Specs go in the sibling `<pkg>_specs/` package, which the skill owns and may create/edit freely. The only exception is the explicit `--inline` opt-out, which writes marker blocks into the production source.
- **Never auto-edit the user's production `Move.toml`.** Surface setup issues (explicit `Sui`/`MoveStdlib` deps, edition) and let the user fix them. The skill *does* author the spec package's own `Move.toml` (Phase 3.5) — that file is a generated deliverable, not the user's.
- **Trusted axioms are disclosed, never hidden.** Every `#[spec(skip, target = …)]` and every `extra_bpl` Boogie axiom must land in the report's "Trusted axioms — not proved" section. An undisclosed axiom is a silent hole in the verification.
- **Never spec a `public(package)` function.** The user's intent (per the plan) is external-API specs only.
- **Never emit legacy MSL syntax.** No `aborts_if`, no `pragma`, no free `axiom`. See `references/spec-patterns.md` for the modern equivalents.
- **Never duplicate a `#[spec(...)]` for the same function.** Idempotency via the marker block.
- **Never strip per-spec `boogie_opt` tokens.** They are load-bearing on hard specs (the AMM `withdraw_spec` uses three).
- **Never delete downstream tasks on a Phase 0 blocker.** If `/specify` hits a hard blocker (unreachable deps, compile failure, missing binary), leave queued Phase 2–4 tasks as `pending` or move them to a `blocked` status — the resumption breadcrumb in `.specify-progress.json` must stay coherent with the session task list so the user can resume cleanly after fixing the blocker.
- **Prefer structured user input when available.** Batch sub-questions by topic. In Codex sessions without structured user input, use concise plain-text questions and wait for the user before proceeding.
- **For document deliverables outside chat, prefer self-contained HTML.** The Phase 5 audit report is the user's record.
