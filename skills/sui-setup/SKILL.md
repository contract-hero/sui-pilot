---
name: sui-setup
description: >-
  Verifies the local machine has everything sui-pilot needs for Sui development
  and offers to install whatever is missing. Checks two tiers — CORE (suiup, the
  sui CLI, a version-matched move-analyzer, Node + pnpm, and the plugin's two
  bundled MCP server builds) and E2E (Google Chrome for Testing, the ~/dev-chrome
  profile, the Slush extension, chrome-devtools-mcp configured to ATTACH, and
  Python 3). Use this skill when the user says "/sui-setup", "set up sui",
  "check my sui setup", "what do I need to install", "is my environment ready",
  "prepara mi entorno", "qué me falta para desarrollar en sui", when a fresh
  clone or a new machine needs provisioning, or when another sui-pilot skill
  fails because a tool is missing (move_diagnostics returns nothing, /sui-e2e
  cannot reach port 9222). Installs only after the user confirms each item, and
  NEVER touches a wallet profile, extension, password, or seed phrase — those
  are always report-only.
allowed-tools: Bash, Read, AskUserQuestion
---

# sui-setup — provision a machine for Sui development

Diagnose first, then offer to fix. Two tiers, checked in order:

| Tier | Covers | Needed for |
|---|---|---|
| **CORE** | suiup, `sui`, `move-analyzer`, Node + pnpm, MCP builds | Writing and compiling Move; LSP diagnostics |
| **E2E** | Chrome for Testing, `~/dev-chrome`, Slush, chrome-devtools-mcp attach, Python 3 | Driving a dapp end-to-end with `/sui-e2e` |

Formal verification (`sui-prover`) is **out of scope** for this skill. Do not
check it, do not offer to install it, do not mention it in the report.

## The iron rule — wallets are never touched

**Report-only, always, no exceptions:** the `~/dev-chrome` profile, the Slush
extension, any wallet password, any seed phrase.

If a wallet is missing or the profile looks wiped, print what the user must do
and **stop**. Never reinstall an extension, never recreate a wiped profile,
never offer to "reset" a wallet. The user onboarded those wallets with seed
phrases; a helpful-looking reinstall destroys keys. Every other item in this
skill may be installed after the user confirms it.

## How to run

1. Run every check in the tier tables below. Collect results — do not fix
   anything mid-scan.
2. Print one status report (format at the bottom).
3. For each FAIL that is installable, ask the user with `AskUserQuestion`
   whether to install it. Batch all installable failures into one call.
4. Run only the confirmed installs. Re-check each one after it runs.
5. Print the final state.

Never chain an install the user did not confirm, even when it is an obvious
dependency of one they did. Ask for both.

---

## CORE tier

### C1 — suiup

```bash
if ! command -v suiup >/dev/null; then
  echo "suiup: MISSING (not on PATH)"
elif OUT=$(suiup --version 2>&1); then
  echo "suiup: OK $OUT"
else
  echo "suiup: BROKEN - found at $(command -v suiup) but it exited non-zero:"; printf '%s\n' "$OUT"
fi
```

Install (needs confirmation): only on `MISSING`.
```bash
curl -sSfL https://raw.githubusercontent.com/MystenLabs/suiup/main/install.sh | sh
```

**`BROKEN` must never trigger an install.** A dyld failure, a Gatekeeper
quarantine, a malformed config or a permission error all mean the binary is
present. Reinstalling would replace a working install to fix a fault nobody
diagnosed. Report the captured error and ask the user. The same rule applies to
every probe below.

### C2 — sui CLI

```bash
if ! command -v sui >/dev/null; then echo "sui: MISSING (not on PATH)"
elif OUT=$(sui --version 2>&1); then echo "sui: OK $OUT"
else echo "sui: BROKEN - exited non-zero:"; printf '%s\n' "$OUT"; fi
```

Install: `suiup install sui` — requires C1 to pass first.

### C3 — move-analyzer, version-matched to sui

```bash
if ! command -v move-analyzer >/dev/null; then echo "move-analyzer: MISSING (not on PATH)"
elif OUT=$(move-analyzer --version 2>&1); then echo "move-analyzer: OK $OUT"
else echo "move-analyzer: BROKEN - exited non-zero:"; printf '%s\n' "$OUT"; fi
```

Install: `suiup install move-analyzer` — requires C1.

**The versions must match `sui`.** A mismatch does not fail loudly; the LSP
just returns degraded or wrong diagnostics, which is worse than no LSP at all.
Compare the semver part of both version strings — ignore any trailing git hash —
and apply the **Version-mismatch policy** below.

### C4 — Node and pnpm

```bash
command -v node >/dev/null && node --version || echo "node: MISSING (not on PATH)"
command -v pnpm >/dev/null && pnpm --version || echo "pnpm: MISSING (not on PATH)"
```

pnpm install (needs confirmation): `npm install -g pnpm`

Only pnpm is acceptable here. Do not suggest npm or yarn as the project's
package manager — they are used for nothing in this repo.

### C5 — bundled MCP server builds

The plugin declares two MCP servers in `.claude-plugin/plugin.json`; both run
from `dist/`. Those bundles are **committed**, so a marketplace install already
has them and this check passes without any action.

```bash
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  echo "SKIP: CLAUDE_PLUGIN_ROOT is unset - cannot locate the plugin tree, so MCP builds are unverifiable"
else
  for s in move-lsp-mcp sui-prover-mcp; do
    if [ -f "${CLAUDE_PLUGIN_ROOT}/mcp/$s/dist/index.js" ]; then echo "$s: built"; else echo "$s: NOT BUILT"; fi
  done
fi
```

Resolve from `${CLAUDE_PLUGIN_ROOT}`, never from the working directory — during a
run the cwd is the user's Move or dapp project, where `mcp/` does not exist. A
relative path would report `NOT BUILT` for every installed user.

**Only offer the build when the user is developing on the plugin repo itself**
— that is, `${CLAUDE_PLUGIN_ROOT}` and the repo root are the same tree:

```bash
pnpm --dir "${CLAUDE_PLUGIN_ROOT}/mcp/move-lsp-mcp" install && pnpm --dir "${CLAUDE_PLUGIN_ROOT}/mcp/move-lsp-mcp" build
pnpm --dir "${CLAUDE_PLUGIN_ROOT}/mcp/sui-prover-mcp" install && pnpm --dir "${CLAUDE_PLUGIN_ROOT}/mcp/sui-prover-mcp" build
```

Never run `pnpm install` in the user's own project to fix this — that writes a
`node_modules/` into a repo that did not ask for one.

Build both even though this skill ignores the prover tier — `plugin.json`
declares the `sui-prover` server unconditionally, so an unbuilt `dist/` makes
the MCP server fail at session start regardless of whether anyone calls it.

---

## E2E tier

Everything here is optional for Move-only work. Report it, but make clear it is
only needed for `/sui-e2e`.

### E1 — Google Chrome for Testing

```bash
[ -x "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" ] \
  && echo "present" || echo "MISSING"
```

Install (needs confirmation, macOS):
```bash
npx -y @puppeteer/browsers install chrome@stable
```

Tell the user where it landed and that it must sit at the `/Applications` path
above, or `/sui-e2e` will not find it.

### E2 — the ~/dev-chrome profile  *(REPORT ONLY)*

```bash
[ -d "$HOME/dev-chrome" ] && echo "present" || echo "MISSING"
```

Missing → tell the user to launch Chrome for Testing once with
`--user-data-dir="$HOME/dev-chrome"` and install Slush into it themselves.
**Do not create, populate or reset this directory.**

### E3 — Slush extension  *(REPORT ONLY)*

Slush extension id: `opcgpfmipidbgpenhmajoajpbobppdil`

```bash
if [ ! -r "$HOME/dev-chrome" ]; then
  echo "UNKNOWN: ~/dev-chrome is not readable - this says nothing about the wallet"
elif compgen -G "$HOME/dev-chrome/*/Extensions/opcgpfmipidbgpenhmajoajpbobppdil" >/dev/null; then
  echo "installed"
else
  echo "MISSING from every profile under ~/dev-chrome"
fi
```

**Skip this check when E2 reported MISSING** and report it as
`[SKIP] — profile absent (see E2)`. Without the profile there is nowhere for the
extension to live, so a second `[FAIL]` line would name one root cause twice.

Missing → print: install Slush from the Chrome Web Store into the
`~/dev-chrome` profile and unlock it. **Stop there.** Do not automate any part
of wallet onboarding.

### E4 — chrome-devtools-mcp configured to ATTACH

This is the check most people miss, and the one that silently ruins an e2e run.

`chrome-devtools-mcp` must be started with
`--browser-url=http://127.0.0.1:9222` so it **attaches** to the wallet Chrome.
Without that flag it **spawns its own** extension-less Chrome, every MCP call
lands in the wrong browser, and the dapp's connect modal comes up empty while
`list_pages` still succeeds. It looks like it is working.

```bash
if ! command -v claude >/dev/null; then
  echo "attach: UNKNOWN - the 'claude' CLI is not on PATH, so the registration cannot be read"
elif ! OUT=$(claude mcp get chrome-devtools 2>&1); then
  echo "attach: NOT REGISTERED (or 'claude mcp get' failed):"; printf '%s\n' "$OUT"
elif printf '%s' "$OUT" | grep -q -- '--browser-url'; then
  echo "attach: OK"
else
  echo "attach: REGISTERED WITHOUT --browser-url"
fi
```

Four states, four remedies. `UNKNOWN` means the check itself is broken — offer
nothing, because `claude mcp add` on a broken check can create a second,
differently-named server while the real registration stays wrong.
`claude mcp get` returns the command and arguments actually in effect. Do not go
hunting through `.mcp.json` / `settings.json` / plugin configs by hand — you can
easily read a file that is not the registration being used.

**If chrome-devtools-mcp came from a plugin rather than `claude mcp add`**, its
tools appear as `mcp__plugin_<plugin>_chrome-devtools__*` and `claude mcp add`
would create a *second*, differently-named server while leaving the plugin's
registration wrong. In that case report it and let the user fix the plugin's own
config — adding a duplicate server hides the problem instead of fixing it.

Fix (needs confirmation) — register it with the attach flag:
```bash
claude mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest --browser-url=http://127.0.0.1:9222
```

If it is already registered **without** the flag, say so and let the user
re-register. Do not rewrite an MCP config entry the user did not ask you to
touch. MCP config changes do not hot-reload — the user must restart the MCP
connection afterwards.

### E5 — Python 3

```bash
command -v python3 >/dev/null && python3 --version || echo "python3: MISSING (not on PATH)"
```

Runs `scripts/cdp.py` in `/sui-e2e`. Standard library only — nothing to
`pip install`. Present on macOS by default; if it is missing, report it and let
the user choose how to install it.

---

## Version-mismatch policy

Applies when C3 finds `sui` and `move-analyzer` both installed at different
versions. The toolchain still works, so this is a `[WARN]`, never a `[FAIL]` —
but it is the highest-value warning this skill produces, so do not let it pass
as one grey line in the report.

1. Mark it `[WARN]` and state both versions explicitly:
   `move-analyzer 1.4x.z — does not match sui 1.5x.y`.
2. Say what it costs in one sentence: diagnostics may be wrong rather than
   absent, so the LSP can report errors that are not real and miss ones that are.
3. Check a matching pair is actually available before offering anything:
   ```bash
   if ! LIST=$(suiup list 2>&1); then
     echo "UNKNOWN: cannot query suiup - the catalogue is unreadable:"; printf '%s\n' "$LIST"
   else
     printf '%s\n' "$LIST" | grep -E 'sui|move-analyzer'
   fi
   ```
   A failed query is **not** the same as "no matching pair exists". When the
   catalogue is unreadable, keep the `[WARN]`, say so, and offer nothing.
4. **If a matching version exists, offer to realign both.** Include it in the
   batched `AskUserQuestion`, and name the target version in the option:
   ```bash
   suiup install sui@<version>
   suiup install move-analyzer@<version>
   ```
   Realign **both**, even when only one is behind — installing one at the
   other's version is the same class of guess that caused the drift.
5. **If no matching pair is available**, do not offer an install that cannot
   work. Report the closest available versions and let the user decide.
6. **If the user declines**, keep the `[WARN]` in the final report and continue.
   Do not re-ask, and do not block the CORE tier — the rest of the toolchain is
   usable.

Realigning replaces working binaries, so it is always confirmed, never implied
by a different answer in the same batch.

---

## Status report format

One table, tier-grouped, no prose padding:

```
CORE
  [OK]   suiup            1.0.x
  [OK]   sui              1.5x.y
  [WARN] move-analyzer    1.4x.z  — does not match sui 1.5x.y
  [OK]   node + pnpm      22.x / 10.x
  [FAIL] MCP builds       sui-prover-mcp not built

E2E  (only needed for /sui-e2e)
  [OK]   Chrome for Testing
  [OK]   ~/dev-chrome profile
  [FAIL] Slush extension   — report only, see note
  [WARN] chrome-devtools-mcp  registered without --browser-url
  [OK]   python3          3.13.x
```

Use `[OK]` / `[WARN]` / `[FAIL]`. Mark every report-only item so the user knows
the skill will not offer to fix it. After the report, ask about the installable
failures in a single `AskUserQuestion` call.

## Common failures

- **`sui` present, `move-analyzer` absent** — the most common state. People
  install the CLI and forget the LSP, then wonder why diagnostics are empty.
- **Both present, versions drift** — happens after `suiup install sui` without
  a matching `move-analyzer` update. Silent degradation.
- **chrome-devtools-mcp registered without `--browser-url`** — the attach trap.
  Two Chrome windows, wallet-less automation, no error message.
