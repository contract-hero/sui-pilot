---
name: verify
description: "Re-verifies the formal specifications that `/specify` authored — the consumer half of the FV split. Reads the `spec-context.json` manifest, detects drift (source changed under a bound spec, deps/toolchain moved, new externally-reachable functions left uncovered), re-runs sui-prover on every spec package with its recorded flags, and reports which guarantees still hold, which were violated, and which went stale. Use this skill when the user invokes `/verify`, asks to 're-verify', 'check the specs still hold', 'is this proof still valid', 'run the prover against current code', or wires FV into CI. `/verify --strict` is the thing CI runs (refuse-on-drift, non-zero exit on any failure or staleness). Does NOT author or edit specs — that is `/specify`'s job; when `/verify` finds uncovered functions it points the user at `/specify`, never writes the spec itself. Skip when sui-prover isn't installed or the package has no specs at all."
---

# Verify — re-check Sui Move formal specifications against current code

> **Doc-First Requirement.** The spec language is the Sui Prover's, not legacy MSL. When interpreting `prove_package` findings, use the shared `../specify/references/failure-taxonomy.md` and `.sui-prover-docs/guide/spec-reference.md`. `/verify` reads and re-proves specs — it never emits new spec syntax.

## What `/verify` is (and is not)

`/specify` and `/verify` are the two halves of the FV workflow (design doc `docs/specify-deliverable-design.html`, Q4):

- **`/specify` authors.** It writes `#[spec(prove, target = …)]` twins into a sibling `<pkg>_specs/` package and emits a `spec-context.json` manifest binding each spec to the exact state it was proved against.
- **`/verify` checks.** It is **read-mostly** — it re-proves the existing specs against *current* source/deps/toolchain and reports drift. It writes only a report (and optionally refreshes drift badges in `/specify`'s report). It never authors, edits, or deletes a spec.

A spec is a claim of the form *"this code, at this state, against these deps, satisfies this property."* `/verify`'s job is to answer **"is that claim still true, and is it still about the current code?"** Those are two different questions — a spec can still *pass* yet no longer *describe* the code (source drifted), and a spec can *fail* on unchanged code (a real regression). `/verify` distinguishes them (Phase 4).

## Inputs and modes

- **Manifest-driven (full).** When `spec-context.json` exists (a package `/specify` produced), `/verify` does drift-aware verification: per-function source-hash comparison, dep/toolchain reproducibility checks, coverage drift, then re-prove.
- **Degraded (no manifest).** When there is no `spec-context.json` (hand-written specs, e.g. `~/workspace/integer-library`, or specs predating the manifest), `/verify` still works: it discovers the spec package(s), re-proves them, and reports verdicts — but **announces that drift detection is unavailable** (no bound state to compare against) and suggests running `/specify` once to mint a manifest.

## Flags

- `--strict` — **refuse-on-drift, CI posture.** Any staleness, context drift, coverage gap, or spec failure makes `/verify` exit non-zero. This is exactly what the `prover.yml` stub `/specify --audit` emits runs. Default (no flag) is **warn-and-run**: report everything, exit zero unless a spec hard-fails.
- `--report <path>` — where to write the HTML report (default `.verify-report.html` at the package root).
- `--package <name>` — verify only one spec package (e.g. `<pkg>_specs_bv`); default verifies all packages in the manifest.

## Phase 0 — Validate (single shot)

Same hard gate as `/specify` Phase 0 — do not duplicate the logic, follow it:

1. **Binary probe.** `mcp__sui-prover__prover_capabilities` with `move_toml_path` at the package root. Capture `binary.found`, `binary.version`, `binary.sui_prover_flags`, `setup_warnings`, `git_dependencies`, and the toolchain versions (needed for Phase 2c).
2. **Binary missing.** If `binary.found === false`: in `--strict` exit non-zero with a clear "prover unavailable" verdict; interactive, ask the user to `brew install asymptotic-code/sui-prover/sui-prover`. `/verify` cannot run degraded without the binary (unlike `/specify`'s discovery-only mode — there is nothing to discover here).
3. **Compile-health + private-dep gates.** Identical to `/specify` Phase 0 steps 2–3. A package that won't resolve its deps can't be re-proved; surface the blocker and exit (non-zero in `--strict`).

## Phase 1 — Load verification context

1. Find `spec-context.json` at the package root. If absent → **degraded mode** (announce it; skip Phase 2a/2c hash+context comparison, keep 2b coverage and Phase 3 re-prove).
2. Parse the manifest: `production_package.source_hashes` (per `<mod>::<fn>`), `hash_method`, `spec_packages[]` (name + `flags`), `deps[]` (name + rev + `pinned_to_branch`), `toolchain`.
3. Resolve each spec package directory on disk. If a manifest-listed spec package is missing, that is itself drift — record it and (in `--strict`) fail.
4. `mcp__sui-prover__list_specs` on each spec package → the live set of `#[spec(...)]` twins and their `target =` mappings. Cross-check against the manifest's specified set (feeds Phase 2b).

## Phase 2 — Detect drift

Three independent drift axes. Collect all; don't short-circuit.

### 2a — Source drift (per-function hash)

For each `<mod>::<fn>` with a bound hash in the manifest:

1. Recompute the current hash **using the manifest's `hash_method`** (bytecode hash if it says `bytecode`, else normalized-source hash — strip comments/whitespace over the function span). Mirroring the method is essential; a different method produces false drift.
2. Compare to the bound hash. Equal → **fresh**. Different → **stale** (the production function changed since the spec was proved).

Staleness is structural, not heuristic: a stale spec's pass/fail verdict (Phase 3) no longer describes the code the user is shipping.

### 2b — Coverage drift (new uncovered functions)

Re-run `/specify`'s Phase 1 discovery (the visibility regex in `specify/references/spec-patterns.md` §1) over current source → the set of externally-reachable functions (`public` non-package + `entry`). Compare to the manifest's specified set:

- A current function with **no spec** → **uncovered** (likely added since `/specify` ran). Report it and **point the user at `/specify`** to author a spec — `/verify` never writes one.
- A manifest spec whose target no longer exists in source → **orphaned** (function renamed/removed). Report it; the spec is dead.

### 2c — Context drift (reproducibility)

Compare current environment to the manifest:

- **Toolchain**: `binary.version` and the Sui/Boogie/Z3 versions from Phase 0 vs `toolchain`. A prover-version change can flip a proof — warn.
- **Deps**: each `git_dependencies` rev vs the manifest's `deps[].rev`. A moved dep changes what called functions do; mid-flight upstream drift silently invalidates proofs (design doc Q4). Warn per changed dep; a dep `pinned_to_branch` is a standing warning regardless.

## Phase 3 — Re-prove

For each spec package in scope (respecting `--package`):

1. `mcp__sui-prover__prove_package` with `move_toml_path` at the spec package and `extra_args` set to that package's manifest `flags` (e.g. `["--no-bv-int-encoding"]` for a `_bv` package). No `target_function` — verify the whole package in one run unless iterating a single failure.
2. Trust `summary.overall` (`verified_all` / `failed_some` / `no_specs` / `compile_failure` / `timeout` / `error`) as the verdict. Collect per-spec `findings[]`.
3. On `compile_failure` / `timeout` / `error`, consult the shared `failure-taxonomy.md`. `/verify` does **not** auto-tune `boogie_opt` or rewrite specs to chase a green — that is authoring. It reports the failure and, for a timeout, surfaces the taxonomy's escalation as a *suggestion to run `/specify`*.

## Phase 4 — Classify every spec into a verdict bucket

Join each spec's Phase 3 prover result with its Phase 2a freshness. This join is the whole point — it turns two booleans into an actionable verdict:

| Source (2a) | Prover (3) | Verdict | Meaning / action |
|---|---|---|---|
| fresh | verified | **holds** | Guarantee intact against current code. |
| fresh | failed | **violated** | Real regression — code changed elsewhere (or a dep moved) and now breaks a still-valid spec. Highest-signal finding; investigate the code, not the spec. |
| stale | verified | **stale-passing** | Spec passes but describes *old* code. The pass is not a guarantee about what ships — re-run `/specify` to rebind, or confirm the change is spec-irrelevant. |
| stale | failed | **stale-failing** | Source changed and the spec no longer holds. Expected after a refactor; re-author via `/specify`. |
| (no spec) | — | **uncovered** | New externally-reachable function (2b) — needs `/specify`. |
| (orphaned) | — | **orphaned** | Spec targets a function that no longer exists (2b) — dead spec. |

The design's feedback loop (Q4 insight): a **violated** verdict means *"you broke a property you committed to"*; an **uncovered** verdict means *"you entered territory the specs never described."* Different failures, different fixes — name which one each spec is.

## Phase 5 — Report and exit

1. **HTML report** at `--report` path (default `.verify-report.html`) — self-contained semantic HTML5, inline CSS, house style matching `docs/*.html`. Sections: verdict summary (counts per bucket), the holds/violated/stale table, context-drift warnings (toolchain + deps), coverage drift (uncovered + orphaned), and a "next steps" block routing each non-`holds` verdict to its fix (`/specify` for stale/uncovered, code investigation for violated).
2. **Refresh `/specify`'s report badges (if present).** If `.specify-report.html` (or per-module `*.spec.html`) exists, update only its `specify:auto:freshness` / drift-badge zones to reflect current verdicts — never touch `specify:human:*` zones. This keeps the authored report's staleness badges live.
3. **Chat summary** — one screen: "N specs: H hold, V violated, S stale, U uncovered. Context: <toolchain/dep drift one-liner>. Report at `<path>`."
4. **Exit semantics.**
   - Default (warn-and-run): exit zero unless a spec **hard-fails to prove** (`failed_some` / `compile_failure` / `error`). Staleness and coverage gaps are warnings.
   - `--strict` (CI): exit **non-zero** on *any* of — a spec failure, *any* stale spec, *any* uncovered function, missing spec package, or context drift (moved dep / changed prover version). CI must catch "the proof is no longer about the current code," not just "a spec failed."

## Resumability & idempotency

`/verify` holds no per-run state of its own — it is a pure function of (current source + spec packages + manifest). Re-running it is always safe and always recomputes from scratch. The only artifacts it writes are the report and (optionally) refreshed badges in `/specify`'s report. It never edits source, specs, or `Move.toml`.

## Operating rules

- **Read-mostly. Never author, edit, or delete a spec.** When `/verify` finds an uncovered function or a stale/failing spec that needs new clauses, it routes the user to `/specify` — it does not write the spec itself. This is the load-bearing boundary between the two skills.
- **Never edit any `Move.toml`** — neither the production package's nor a spec package's.
- **Never auto-tune to force green.** `boogie_opt`, `--split-paths`, `no_opaque`, prelude axioms are authoring decisions (they change what is being proved); `/verify` reports the failure and defers to `/specify`.
- **`--strict` is the CI contract.** Refuse-on-drift, non-zero exit. Keep its triggers (failure / stale / uncovered / context drift / missing package) stable so the emitted `prover.yml` stays meaningful.
- **Mirror the manifest's hash method exactly** in Phase 2a — a mismatched method manufactures false drift and destroys trust in the freshness signal.
- **Degraded mode is honest, not silent.** With no manifest, announce that drift detection is off and recommend `/specify` to mint one; still re-prove and report verdicts.
- **For document deliverables outside chat, prefer self-contained HTML** — the verify report is the user's record.
