---
name: sui-pilot
description: Doc-first guidance and a Move LSP editing loop (diagnostics, hover, references) for Sui Move, Walrus, Seal, the Sui TypeScript SDK, dapp-kit, and Sui Prover. Use when writing, building or reviewing Sui Move code or Sui applications, or when the user invokes Sui Pilot.
---

# Sui Pilot

Read [runtime guidance](references/runtime.md) before resolving bundled files or
calling tools. Use the installed plugin's documentation to ground answers and
implementation decisions; training-memory APIs and syntax may be outdated.

## Documentation

Resolve these directories under the plugin root, not the user's project:

| Topic | Corpus |
|---|---|
| Move syntax, abilities, generics, modules, idioms | `.move-book-docs/` |
| Sui objects, transactions, framework, on-chain finance | `.sui-docs/` |
| Walrus storage and Sites | `.walrus-docs/` |
| Seal encryption and access policies | `.seal-docs/` |
| TypeScript SDK, dapp-kit, kiosk, payment-kit, SDK migrations | `.ts-sdk-docs/` |
| Sui Prover specifications and examples | `.sui-prover-docs/` |

Search filenames with `rg --files` and content with `rg`, then read the relevant
pages before writing or reviewing code. For cross-stack questions, consult the
ecosystem knowledge graph in `../../agents/sui-pilot-agent.md`; its Claude agent
frontmatter is host metadata, not a requirement to launch a subagent.

If the bundled documentation does not settle the question, state what remains
uncertain. Check the SDK migration guides before changing an existing project's
SDK major version; preserve intentional dependency pins.

## Workflows

- `sui-setup`: inspect the local toolchain and help provision missing components.
- `oz-math`: analyze arithmetic and identify applicable OpenZeppelin libraries.
- `specify`: author formal specifications when requested by the user.
- `verify`: check existing specifications and source/toolchain drift.
- `sui-e2e`: test a dapp in a locally configured Chrome with a test wallet.

## Move editing loop

When you write or change Move code, use the `move-lsp` tools as part of each
edit, not only after a build fails. Every path is absolute (see the runtime
guidance).

1. Before you call an unfamiliar function or use an unfamiliar type, run
   `move_hover` on an existing use of it to read its signature and abilities
   instead of recalling them from memory. `move_find_references` shows how the
   package already calls it.
2. After each edit to a `.move` file, call `move_diagnostics` on that file and
   fix every `error` before you move on. It points at the exact line. To check a
   draft before you write it, pass the draft as `content`.
3. Before you finish, run the project's `sui move build` and `sui move test`.
   Diagnostics do not replace them: they run no tests, and cross-package lookups
   can be incomplete.

If the LSP is unavailable, say so once and use the shell checks alone. Never
claim a successful proof when `sui-prover` is unavailable or has not been run.

Skills can also be invoked directly; the host's skill menu determines whether
the invocation uses `$`, `@`, or `/`.
