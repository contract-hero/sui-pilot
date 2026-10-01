# Runtime guidance

## Locate the installed package

The plugin root is two directories above a loaded `skills/<name>/SKILL.md`,
or three directories above this file. Confirm it contains
`.codex-plugin/plugin.json` or `.claude-plugin/plugin.json` and the bundled
documentation. Resolve relative reference links from the file containing them.
Do not search for plugin resources in the user's project or assume a fixed cache
directory. The user's project remains the target for source edits and builds.

Shell examples use `SUI_PILOT_ROOT` for that resolved absolute plugin path.
Assign it in the same shell invocation as the example, or substitute the quoted
absolute path. Shell variables do not persist between independent tool calls.
Claude's `CLAUDE_PLUGIN_ROOT` may be used when present and verified, but is not
required by these skills. Preserve quoting when paths contain spaces.

## Use the host's tools

The workflow names `Bash`, `Read`, `Glob`, `Grep`, `Write`, `Edit`, and
`AskUserQuestion` describe operations. Use the current host's equivalent shell,
file, editing, and user-input tools. In Codex, use `rg` / `rg --files`, shell
reads, and the available patch tool. Ask interactive questions using the
available user-input tool, or in conversation when none is available. Preserve
required review gates; a missing question tool is not approval.

MCP names in existing procedures use Claude's spelling. Find the currently
exposed tool by its server and operation: `move-lsp` provides `move_*` tools;
`sui-prover` provides `prover_capabilities`, `list_specs`, and `prove_package`.
Host prefixes and hyphen/underscore normalization may differ. Do not invent a
tool call or substitute an unrelated plugin when the required tool is missing.

OpenAI hosts discover these workflows as skills. `/specify`, `/verify`, and the
other slash names in examples also mean the corresponding installed skill in
hosts using `$` or `@` invocation. No Claude agent or command loader is required.

## Execution environment

Both MCP servers communicate over local stdio. Their Node.js processes need
access to the user's project and locally installed toolchain. A browser-only
ChatGPT session cannot launch these binaries on the user's computer just by
installing the plugin. Use a supported local Codex/desktop execution environment.
If local execution is unavailable, explain that limit before starting a
toolchain, prover, or browser workflow.

Follow the user's requested scope and host permissions. Installing dependencies,
changing browser configuration, or signing transactions requires authorization
for that action. For wallet E2E, confirm the intended test network, account, and
transaction scope; stop when a popup exceeds that scope. Do not access or export
wallet secrets or automate wallet onboarding.
