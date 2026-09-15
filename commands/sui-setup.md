---
name: sui-setup
description: Check that this machine has everything needed for Sui development, and offer to install what is missing
---

Invoke the `sui-setup` skill to diagnose the local Sui toolchain and offer to install whatever is missing.

## What This Command Does

- Checks the **CORE** tier: `suiup`, the `sui` CLI, a version-matched `move-analyzer`, Node + pnpm, and the plugin's two bundled MCP server builds
- Checks the **E2E** tier: Google Chrome for Testing, the `~/dev-chrome` profile, the Slush extension, `chrome-devtools-mcp` configured to attach, and Python 3
- Prints one tier-grouped status report with `[OK]` / `[WARN]` / `[FAIL]` per item
- Offers to install each failing item — one confirmation per item, nothing chained silently

## When to Use

- On a new machine, or after a fresh clone of a Sui project
- When `move_diagnostics` returns nothing and you suspect the LSP is missing or mismatched
- When `/sui-e2e` cannot reach port 9222 or the dapp's connect modal comes up empty
- Any time you want to know what is missing before you start

## When NOT to Use

- Mid-task, when a specific tool has already failed with a clear error — fix that one thing directly
- To set up formal verification — `sui-prover` is deliberately out of this skill's scope

## Limitations

- Wallet state is report-only and never written — see the skill's iron rule. A missing or wiped profile stops the run instead of being repaired.
- `sui-prover` is out of scope; `/specify` and `/verify` have their own prerequisites.

## Related Commands

- `/sui-e2e` — Run the end-to-end dapp tests this command provisions for
