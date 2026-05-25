# sui-pilot

<p align="center">
  <img src="sui-pilot.jpg" alt="Sui Pilot" width="600" />
</p>

> A Claude Code plugin that turns Claude into a Sui/Move development expert — grounded in current docs, not stale training data.

sui-pilot bundles **747 documentation files** from six upstream MystenLabs corpora, a **Move LSP** bridge for real-time diagnostics, a **formal verification** wrapper for the Sui Prover, and **five specialized skills** — all wired into a doc-first agent that reads the docs before writing code. Install it and every Sui/Move question Claude answers is grounded in the current state of the ecosystem.

**[Read the full story](https://contract-hero.github.io/sui-pilot/)**

---

## What Ships

### Bundled documentation (747 files, 6 corpora)

All docs are local and searchable. Claude reads them before generating code — no hallucinated APIs, no deprecated patterns.

| Source | Files | Topics |
|---|---|---|
| **Sui** | 369 | Blockchain, objects, transactions, DeFi, framework |
| **Move Book** | 143 | Move language tutorial + reference: syntax, types, abilities, idioms |
| **TS SDK** | 115 | TypeScript SDK, dapp-kit, payment-kit, kiosk, React hooks |
| **Walrus** | 86 | Decentralized blob storage, Walrus Sites, HTTP API |
| **Sui Prover** | 20 | Formal verification: `#[spec(prove)]` specs, Boogie tuning |
| **Seal** | 14 | Secrets management, encryption, key servers, access control |

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
| `/move-code-quality` | Move 2024 Edition compliance (50+ rules) |
| `/move-code-review` | Security and architecture review (40 checks, 6 categories) |
| `/oz-math` | OpenZeppelin math library recommendations |
| `/specify` | Author `#[spec(prove)]` formal specs + verify via `sui-prover` |
| `/verify` | Re-verify that authored specs still hold against current code |

### Specialized agent

The `sui-pilot-agent` enforces a doc-first workflow: consult documentation before writing code, use LSP for real-time validation. Its always-loaded preamble is a topic-to-corpus routing table that navigates the bundled docs via `Glob`/`Grep`.

---

## Install

```
/plugin marketplace add contract-hero/plugin-marketplace
/plugin install sui-pilot@contract-hero
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

---

## Quick Start

```
# Ask about Sui/Move (doc-grounded answer)
What are shared objects in Sui and when should I use them?

# Check code quality
/move-code-quality

# Security review
/move-code-review

# Get compiler diagnostics
Check diagnostics for sources/my_module.move
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
claude --plugin-dir "$(pwd)"
```

See [`CLAUDE.md`](./CLAUDE.md) for architectural invariants and the doc-first workflow.

---

## License

MIT
