---
name: verify
description: Re-verify that formal specifications still hold against current code
---

Invoke the `verify` skill to re-check existing `#[spec(prove)]` formal specifications against the current state of your Move package.

## What This Command Does

- Reads the `spec-context.json` manifest left by `/specify`
- Detects drift: source changed under a bound spec, deps/toolchain moved, new externally-reachable functions left uncovered
- Re-runs `sui-prover` on every spec package with its recorded flags
- Reports which guarantees still hold, which were violated, and which went stale

## When to Use

- After modifying Move code that has existing formal specs
- In CI to gate merges on proof validity (`/verify --strict`)
- Before deploying to mainnet to confirm specs still hold
- When upgrading dependencies or toolchain versions

## When NOT to Use

- When the package has no specs yet — use `/specify` first
- When `sui-prover` is not installed

## Related Commands

- `/specify` — Author new formal specs (this skill only re-verifies existing ones)
- `/move-code-review` — Identifies which functions most need specs (SEC-* findings)
- `/move-code-quality` — Style and idiom analysis
