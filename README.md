# sui-pilot

<p align="center">
  <img src="sui-pilot.jpg" alt="Sui Pilot" width="600" />
</p>

> A plugin for Claude Code and local Codex environments, grounded in bundled Sui/Move documentation and local development tools.

sui-pilot bundles **815 documentation files** from six upstream MystenLabs corpora, a **Move LSP** bridge for real-time diagnostics, a **formal verification** wrapper for the Sui Prover, **end-to-end dapp testing** that drives the Slush wallet hands-free, and **five specialized skills** — with a doc-first entry skill for OpenAI hosts and a specialized agent for Claude Code. Both hosts use the same documentation and run the MCP tools on your machine.

**[Dive into the landing page](https://contract-hero.github.io/sui-pilot/)** · [read the full story](https://contract-hero.github.io/sui-pilot/classic.html)

---

## Install

### Codex and local desktop environments

Use a current Codex release with Git-backed plugin source support (validated
with Codex CLI 0.153.4):

```bash
codex plugin marketplace add contract-hero/plugin-marketplace
codex plugin add sui-pilot@contract-hero
```

Start a new session after installation. Invoke `$sui-pilot` or choose a skill
from the host's skill menu; the five specialized skills can also be invoked
directly. In a compatible desktop client, add the same Git marketplace and
install Sui Pilot from its plugin browser.

Both bundled MCP servers use **local stdio**: Node launches `move-lsp` and
`sui-prover` from the installed plugin directory. There is no hosted LSP,
listening HTTP port, plugin service account, or remote project upload. Tool
results still enter the agent conversation under the host's normal data
handling, and toolchain commands may fetch their ordinary dependencies.

This requires execution on the machine containing your project and toolchain.
Installing in browser-only ChatGPT does not grant access to your computer's
files, binaries, Chrome, or wallet. The optional browser setup/E2E workflows
currently document macOS.

**Distribution boundary:** a Git marketplace is separate from OpenAI's public
plugin directory. As checked on 2026-10-01, OpenAI's public-submission guidance
directs local-MCP authors to their OpenAI contact for support. This package does
not claim public-directory approval. See [packaging and marketplaces](https://developers.openai.com/plugins/build/plugins)
and [local MCP submission guidance](https://developers.openai.com/plugins/guides/submit-claude-plugin).

### Claude Code

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
| Node.js | 18+ | Runs both prebuilt MCP bundles; must be visible on the host's PATH |
| Plugin host | Current | Codex with Git plugin sources, a compatible local desktop client, or Claude Code |

`sui-prover` is an additional prerequisite for executing formal proofs; the
prover MCP exposes a capability check when it is missing. pnpm is needed only
for development/builds or optional browser tooling, not to install the two
prebuilt MCP servers.

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

### Bundled documentation (815 files, 6 corpora)

All docs are local and searchable. The skills direct the agent to read the
relevant documentation before generating code.

| Source | Files | Topics |
|---|---|---|
| **Sui** | 408 | Blockchain, objects, transactions, DeFi, framework |
| **Move Book** | 150 | Move language tutorial + reference: syntax, types, abilities, idioms |
| **Walrus** | 117 | Decentralized blob storage, Walrus Sites, HTTP API |
| **TS SDK** | 105 | TypeScript SDK, dapp-kit, payment-kit, kiosk, React hooks |
| **Sui Prover** | 20 | Formal verification: `#[spec(prove)]` specs, Boogie tuning |
| **Seal** | 15 | Secrets management, encryption, key servers, access control |

### MCP tools

Two local MCP servers provide tooling in supported plugin hosts:

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

sui-pilot also works as a standalone documentation source. Clone the repo and
point your agent at `skills/sui-pilot/SKILL.md`. It routes into the bundled
`.<source>-docs/` corpora using the host's file-search tools.

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

The OpenAI manifest is `.codex-plugin/plugin.json`; the Claude manifest stays in
`.claude-plugin/plugin.json`. Keep their local MCP server names and entrypoints
aligned. OpenAI's manifest uses `cwd: "."`, resolved by Codex against the
installed plugin root, so it also works when the user's project is elsewhere.
The OpenAI manifest declares MCP servers inline to avoid introducing a root
`.mcp.json` that would duplicate Claude's existing declarations.

`pnpm --dir mcp/move-lsp-mcp test` includes a packaging integration test that
launches both committed bundles from a relocated installation with spaces in
its path, without `node_modules` or Claude environment variables. It checks
MCP initialization, tool discovery, and local spec-file access. Compiler and
proof integration tests separately require the corresponding binaries.

For a local Codex install test, use a temporary marketplace containing a copy of
this tree under `plugins/sui-pilot`, add it with
`codex plugin marketplace add <marketplace-root>`, and install
`sui-pilot@<temporary-marketplace-name>`. Start a new session to pick up skills
and tools. Remove that test plugin and marketplace after testing. Do not edit
the installed cache or use the user's normal marketplace as a test fixture.

See [`CLAUDE.md`](./CLAUDE.md) for architectural invariants and the doc-first workflow.

---

## License

MIT
