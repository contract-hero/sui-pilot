# sui-pilot

<p align="center">
  <img src="sui-pilot.jpg" alt="Sui Pilot" width="600" />
</p>

> A Claude Code and Codex plugin that turns an agent into a Sui/Move development expert — grounded in current docs, not stale training data.

sui-pilot bundles **753 documentation files** from six upstream MystenLabs corpora, a **Move LSP** bridge for real-time diagnostics, a **formal verification** wrapper for the Sui Prover, and specialized skills — all wired into a doc-first workflow that reads the docs before writing code. Install it and every Sui/Move answer is grounded in the current state of the ecosystem.

**[Read the full story](https://contract-hero.github.io/sui-pilot/)**

---

## What Ships

### Bundled documentation (753 files, 6 corpora)

All docs are local and searchable. The host agent reads them before generating code — no hallucinated APIs, no deprecated patterns.

| Source | Files | Topics |
|---|---|---|
| **Sui** | 369 | Blockchain, objects, transactions, DeFi, framework |
| **Move Book** | 145 | Move language tutorial + reference: syntax, types, abilities, idioms |
| **TS SDK** | 115 | TypeScript SDK, dapp-kit, payment-kit, kiosk, React hooks |
| **Walrus** | 86 | Decentralized blob storage, Walrus Sites, HTTP API |
| **Sui Prover** | 24 | Formal verification: `#[spec(prove)]` specs, Boogie tuning |
| **Seal** | 14 | Secrets management, encryption, key servers, access control |

### MCP tools

Two MCP servers provide real-time tooling from within Claude Code or Codex:

| Server | Tools | What it wraps |
|---|---|---|
| **move-lsp** | `move_diagnostics`, `move_hover`, `move_completions`, `move_goto_definition`, `move_find_references`, `move_document_symbols`, `move_type_definition`, `move_code_actions`, `move_inlay_hints`, `move_rename` | The `move-analyzer` LSP |
| **sui-prover** | `prove_package`, `list_specs`, `prover_capabilities` | The `sui-prover` formal verification binary |

### Claude slash commands / Codex skills

| Claude command / Codex skill | Purpose |
|---|---|
| `/sui-pilot` / `sui-pilot` | Doc-first entry point |
| `/move-code-quality` / `move-code-quality` | Move 2024 Edition compliance (50+ rules) |
| `/move-code-review` / `move-code-review` | Security and architecture review (40 checks, 6 categories) |
| `/oz-math` / `oz-math` | OpenZeppelin math library recommendations |
| `/specify` / `specify` | Author `#[spec(prove)]` formal specs + verify via `sui-prover` |
| `/verify` / `verify` | Re-verify that authored specs still hold against current code |

### Specialized agent

The `sui-pilot-agent` enforces a doc-first workflow: consult documentation before writing code, use LSP for real-time validation. Its always-loaded preamble is a topic-to-corpus routing table that navigates the bundled docs via `Glob`/`Grep`.

---

## Install

### Claude Code

```
/plugin marketplace add contract-hero/plugin-marketplace
/plugin install sui-pilot@contract-hero
```

Then restart Claude Code — MCP servers launch at session start.

### Codex

The repo ships a native Codex manifest at `.codex-plugin/plugin.json`, MCP config at `.mcp.json`, and a single-plugin Codex marketplace at `.agents/plugins/marketplace.json`.

```bash
codex plugin marketplace add contract-hero/sui-pilot
codex plugin add sui-pilot@sui-pilot
```

During local development, point Codex at the repo or adapter worktree instead:

```bash
codex plugin marketplace add /path/to/sui-pilot
codex plugin add sui-pilot@sui-pilot
```

Codex 0.142 indexes marketplace entries from local plugin paths inside the marketplace snapshot. The multi-plugin Contract Hero marketplace can expose `sui-pilot@contract-hero` once it vendors or syncs this repo under `plugins/sui-pilot`.

### Requirements

| Component | Version | Notes |
|---|---|---|
| suiup | Latest | `curl -sSfL https://raw.githubusercontent.com/MystenLabs/suiup/main/install.sh \| sh` |
| sui + move-analyzer | Same version | **Must match** — install both via suiup |
| Claude Code or Codex | Latest | Plugin host environment |

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

sui-pilot also works as a standalone documentation source. Clone the repo, point your agent at `agents/sui-pilot-agent.md` or the Codex `sui-pilot` skill, and navigate the bundled `.<source>-docs/` corpora with the host's file-search tools (`rg` in Codex, `Glob`/`Grep` in Claude Code).

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

See [`CLAUDE.md`](./CLAUDE.md) for architectural invariants and the doc-first workflow.

---

## License

MIT
