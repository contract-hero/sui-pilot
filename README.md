# sui-pilot

<p align="center">
  <img src="sui-pilot.jpg" alt="Sui Pilot" width="600" />
</p>

> A Claude Code plugin that turns Claude into a Sui/Move development expert — grounded in current docs, not stale training data.

sui-pilot bundles **812 documentation files** from six upstream MystenLabs corpora, a **Move LSP** bridge for real-time diagnostics, a **formal verification** wrapper for the Sui Prover, **end-to-end dapp testing** that drives the Slush wallet hands-free, and **five specialized skills** — all wired into a doc-first agent that reads the docs before writing code. Install it and every Sui/Move question Claude answers is grounded in the current state of the ecosystem.

**[Dive into the landing page](https://contract-hero.github.io/sui-pilot/)** · [read the full story](https://contract-hero.github.io/sui-pilot/classic.html)

---

## Install

From inside Claude Code:

```
/plugin marketplace add contract-hero/plugin-marketplace
/plugin install sui-pilot@contract-hero
```

Or straight from the terminal:

```bash
claude plugin marketplace add contract-hero/plugin-marketplace
claude plugin install sui-pilot@contract-hero
```

Then restart Claude Code — MCP servers launch at session start.

### Requirements

| Component | Version | Notes |
|---|---|---|
| suiup | Latest | `curl -sSfL https://raw.githubusercontent.com/MystenLabs/suiup/main/install.sh \| sh` |
| sui + move-analyzer | Same version | **Must match** — install both via suiup |
| Claude Code | Latest | Plugin host environment |

```bash
suiup install sui
suiup install move-analyzer
```

Or let the plugin check for you — `/sui-setup` reports what is present, what is
missing, and whether `sui` and `move-analyzer` versions match, then offers to
install the gaps.

End-to-end testing (`/sui-e2e`) needs more: Google Chrome for Testing, a
`~/dev-chrome` profile with the Slush extension, `chrome-devtools-mcp`
registered with `--browser-url=http://127.0.0.1:9222`, and Python 3.
`/sui-setup` checks all of it.

---

## What Ships

### Bundled documentation (812 files, 6 corpora)

All docs are local and searchable. Claude reads them before generating code — no hallucinated APIs, no deprecated patterns.

| Source | Files | Topics |
|---|---|---|
| **Sui** | 416 | Blockchain, objects, transactions, DeFi, framework |
| **Move Book** | 149 | Move language tutorial + reference: syntax, types, abilities, idioms |
| **Walrus** | 108 | Decentralized blob storage, Walrus Sites, HTTP API |
| **TS SDK** | 104 | TypeScript SDK, dapp-kit, payment-kit, kiosk, React hooks |
| **Sui Prover** | 20 | Formal verification: `#[spec(prove)]` specs, Boogie tuning |
| **Seal** | 15 | Secrets management, encryption, key servers, access control |

### MCP tools

Two MCP servers provide real-time tooling from within Claude Code:

| Server | Tools | What it wraps |
|---|---|---|
| **move-lsp** | `move_diagnostics`, `move_hover`, `move_completions`, `move_goto_definition`, `move_find_references`, `move_document_symbols`, `move_type_definition`, `move_code_actions`, `move_inlay_hints`, `move_rename` | The `move-analyzer` LSP |
| **sui-prover** | `prove_package`, `list_specs`, `prover_capabilities` | The `sui-prover` formal verification binary |

### Slash commands

| Command | Purpose |
|---|---|
| `/sui-pilot` | Doc-first entry point; routes to the sui-pilot agent |
| `/sui-setup` | Check the local toolchain and offer to install what is missing |
| `/sui-e2e` | End-to-end dapp tests with hands-free Slush wallet approval |
| `/oz-math` | OpenZeppelin math library recommendations |
| `/specify` | Author `#[spec(prove)]` formal specs + verify via `sui-prover` |
| `/verify` | Re-verify that authored specs still hold against current code |

### End-to-end dapp testing

`/sui-e2e` runs a full browser test against a Sui dapp with the wallet in the loop. It brings up Chrome for Testing on the debug port with the wallet profile, verifies `chrome-devtools-mcp` attached to *that* browser rather than spawning its own, then drives every Slush approval popup — connect, sign-in message, transaction signing — without a manual click.

This works around a hard limitation: `chrome-devtools-mcp` cannot see `chrome-extension://` pages, so wallet popups never appear in `list_pages` and every wallet e2e stalls at the first approval. The skill bundles a dependency-free CDP client (`scripts/cdp.py`, Python stdlib only) that drives those popups directly.

Wallet state is never touched — a locked wallet or a wiped profile stops the run and asks you.

### Specialized agent

The `sui-pilot-agent` enforces a doc-first workflow: consult documentation before writing code, use LSP for real-time validation. Its always-loaded preamble is a topic-to-corpus routing table that navigates the bundled docs via `Glob`/`Grep`.

---

## Quick Start

```
# Ask about Sui/Move (doc-grounded answer)
What are shared objects in Sui and when should I use them?

# Check the local toolchain before you start
/sui-setup

# Audit arithmetic for safer math
/oz-math

# Get compiler diagnostics
Check diagnostics for sources/my_module.move

# Drive a full dapp test, wallet approvals included
/sui-e2e
```

---

## For Other AI Agents

sui-pilot also works as a standalone documentation source for non-Claude Code environments. Clone the repo, point your agent at `agents/sui-pilot-agent.md`, and it will navigate the bundled `.<source>-docs/` corpora with `Glob` and `Grep`.

---

## Keeping Docs Up to Date

```bash
./sync-docs.sh    # Pull latest from upstream MystenLabs repos
```

A [GitHub Actions workflow](.github/workflows/refresh-docs.yml) runs this weekly and opens a chore PR when upstream docs change.

---

## Links

- **Landing page** — <https://contract-hero.github.io/sui-pilot/>
- **Marketplace** — [`contract-hero/plugin-marketplace`](https://github.com/contract-hero/plugin-marketplace)
- **Release history** — [CHANGELOG.md](./CHANGELOG.md)
- **Eval methodology** — [how we measured context injection](https://contract-hero.github.io/sui-pilot/EVAL_FRAMEWORK.html)

## Contributing

```bash
git clone https://github.com/contract-hero/sui-pilot.git
cd sui-pilot
pnpm --dir mcp/move-lsp-mcp install && pnpm --dir mcp/move-lsp-mcp build
pnpm --dir mcp/sui-prover-mcp install && pnpm --dir mcp/sui-prover-mcp build
claude --plugin-dir "$(pwd)"
```

Then run `/sui-setup` inside that session to confirm the toolchain is complete.

See [`CLAUDE.md`](./CLAUDE.md) for architectural invariants and the doc-first workflow.

---

## License

MIT
