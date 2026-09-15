---
name: sui-e2e
description: >-
  Runs end-to-end browser tests against a Sui dapp with Claude driving both the
  page and the wallet. Brings up Google Chrome for Testing on the debug port
  with the wallet profile, verifies chrome-devtools-mcp attached to THAT browser
  and not a spawned wallet-less one, then drives every Slush approval popup —
  connect, sign-in message, transaction signing — hands-free via a bundled raw
  CDP client. Use this skill when the user says "/sui-e2e", "run e2e", "test the
  dapp end to end", "connect the wallet", "approve the wallet", "sign in with
  Slush", "prueba la dapp", "aprueba la wallet", "firma con Slush", or whenever
  an automated browser flow against a Sui dapp stalls on a wallet popup. The
  reason this skill exists — chrome-devtools-mcp CANNOT see `chrome-extension://`
  pages, so the Slush popup never appears in `list_pages` and `click`/
  `take_snapshot` are blind to it; every wallet E2E stalls there. If the
  toolchain is missing (no Chrome for Testing, no Slush, chrome-devtools-mcp not
  registered), run /sui-setup first — this skill assumes provisioning is done.
allowed-tools: Bash, Read, mcp__chrome-devtools__*
---

# sui-e2e — end-to-end dapp testing with wallet automation

Two phases. Phase A guarantees the browser is the right one. Phase B drives the
dapp and its wallet popups. Do not start Phase B until Phase A's verification
passes — almost every confusing e2e failure is a Phase A problem that surfaces
much later as "the connect modal is empty".

**Provisioning is out of scope.** If Chrome for Testing, the `~/dev-chrome`
profile, Slush, or chrome-devtools-mcp is missing, stop and run `/sui-setup`.
This skill assumes all of it is installed.

Slush extension id, matched constantly below: `opcgpfmipidbgpenhmajoajpbobppdil`

---

# Phase A — get a debuggable wallet browser

## The two traps

Both end the same way: automation drives a Chrome with no wallet in it, while
every check you might casually run still reports success.

**The profile-lock trap.** A `--user-data-dir` can be owned by only ONE Chrome
process. If a Chrome-for-Testing already holds `~/dev-chrome` *without* the
debug port, launching a second instance with that same profile plus
`--remote-debugging-port=9222` cannot lock it, so Chrome silently falls back to
a fresh, **extension-less** profile. The port comes up. MCP attaches. There is
no wallet. Checking "is 9222 up?" does not catch this.

**The attach trap.** Even with a perfect wallet Chrome on 9222, if
chrome-devtools-mcp was registered without `--browser-url`, it **spawns its own**
regular Chrome (profile `~/.cache/chrome-devtools-mcp/chrome-profile`, no
extensions) and every MCP call lands there. Symptom: two Chrome windows.
`list_pages` succeeds against the wrong one.

## A1 — assess what is running

```bash
curl -sS -m 1 http://127.0.0.1:9222/json/version >/dev/null 2>&1 && echo "port:up" || echo "port:down"
ps aux | grep -i "Chrome for Testing" | grep -v grep | grep -vE 'Helper|--type=' \
  | grep -oE -- '--(user-data-dir|remote-debugging-port)=[^ ]+' | sort -u
```

- **port:down, nothing holds `~/dev-chrome`** → clean launch (A2).
- **port:down, a Chrome-for-Testing already holds `~/dev-chrome`** → the
  profile-lock trap is armed. Clean restart (A2).
- **port:up** → still verify the profile (A3) before trusting it.

## A2 — clean restart

Exactly one Chrome-for-Testing must own the profile, and it must be the
debuggable one. Kill first. The profile persists on disk — **wallets are not
lost by this** — but ask the user before killing if they may have unsaved work
in that browser.

```bash
pkill -f "Google Chrome for Testing" 2>/dev/null; sleep 1
"/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" \
  --remote-debugging-port=9222 \
  --user-data-dir="$HOME/dev-chrome" \
  > /dev/null 2>&1 &
sleep 2
```

## A3 — verify the wallet profile is the debugged one

Port-up is necessary, not sufficient.

```bash
curl -sS -m 2 http://127.0.0.1:9222/json/version | head -2
curl -s http://127.0.0.1:9222/json \
  | grep -oE 'chrome-extension://opcgpfmipidbgpenhmajoajpbobppdil' | sort -u
```

- Extension line present → real profile loaded. Continue.
- **No extension line** → extension-less fallback. Re-run A2. If it is still
  empty, check `ls ~/dev-chrome/Default/Extensions` for the Slush id. If the id
  is absent the profile was wiped — **STOP and ask the user. Do not reinstall;
  they onboarded the wallet with a seed phrase.**

Slush is an MV3 service worker and can be **dormant**, so it may not appear as a
target until a dapp first requests the wallet. An empty list here is therefore
not proof of absence. The definitive check is functional: open the dapp's
connect modal and see Slush listed. Do that as the first action of Phase B.

## A4 — confirm MCP attached to this browser

```bash
ps aux | grep -i "Google Chrome.app" | grep -v "Chrome for Testing" | grep -v grep \
  | grep -oE -- '--user-data-dir=[^ ]*chrome-devtools-mcp[^ ]*' | sort -u
```

- **Output present** → MCP spawned its own Chrome; the attach trap fired.
  `--browser-url` is missing from the chrome-devtools-mcp registration. Fix it
  via `/sui-setup` (check E4), restart the MCP connection — config changes do
  not hot-reload — then kill the stray:
  `pkill -f "chrome-devtools-mcp/chrome-profile"`.
- **No output** → MCP is attaching to the 9222 Chrome. Phase A passes.

---

# Phase B — drive the dapp and its wallet

## The two worlds

| What you drive | Tool |
|---|---|
| The **dapp** page (`https://…`) — buttons, modals, post-login checks | chrome-devtools-mcp (`navigate_page`, `take_snapshot`, `click`, `evaluate_script`) |
| The **Slush popup** (`chrome-extension://…`) — Approve / Reject / Sign / Confirm | `scripts/cdp.py` |

chrome-devtools-mcp attaches only to http(s) page targets. Extension pages never
appear in `list_pages` and `new_page` will not surface them. The DevTools
endpoint on `:9222` exposes every target over WebSocket, extension pages
included — MCP just declines to. `scripts/cdp.py` talks that protocol directly.
It is Python 3 standard library only: no `pip install`, no Node, no `ws` module.

The handoff is always the same: click something on the dapp that needs the
wallet → a Slush popup opens → leave MCP, drive the popup with `cdp.py`, press
the button → control returns to the dapp.

## The core loop — discover, inspect, click, verify

### B1 — discover the popup

```bash
python3 scripts/cdp.py targets opcgpfmipidbgpenhmajoajpbobppdil
```

Popup URLs are `chrome-extension://<id>/index.html#<action>?…`. The hash says
what is being asked:

- `#approve-connection` — dapp wants to connect and learn your address
- `#sign-personal-message` — a string signature, e.g. a login message; the
  `bytes=` query param is **base64 of the exact message** — decode it
- `#approve-transaction` / `#sign-transaction` — a PTB to sign or execute; this
  moves value or changes on-chain state
- `#unlock`, or any popup with a password field — the wallet is locked

The URL also carries `appName`, `appUrl`, `accountAddress`, `network`. Do not
hardcode hash names; they can change. Always inspect to confirm.

Match on the **extension id or the action hash**, never on the dapp domain — the
dapp origin is embedded in `appUrl=`, so a substring like `myapp.com` also
matches popup URLs. When several targets match, pass the specific target id.

### B2 — inspect before touching

```bash
python3 scripts/cdp.py inspect <id-or-#action-or-ws-url>
```

Prints title, visible body text, every clickable label, and `hasPasswordField`.
Use it to confirm the request is what you expect and to learn the exact button
label. Slush uses **Approve / Reject** for connections and **Sign / Confirm /
Reject** for signatures — read the actual labels rather than assuming.

### B3 — click

```bash
python3 scripts/cdp.py click <target> "Approve"
```

Matches a button by trimmed text or aria-label, case-insensitive, with a
contains-fallback. On no match it prints the available labels.

### B4 — verify on the dapp side

The popup closes itself once resolved. The click succeeding is **not** the
proof — the dapp reflecting the new state is. Back through MCP:

```js
() => {
  const txt = document.body.innerText;
  return JSON.stringify({
    signedIn: ![...document.querySelectorAll('button')].some(b => /sign in|connect wallet/i.test(b.innerText)),
    address: (txt.match(/0x[a-fA-F0-9]{4}[….]{1,3}[a-fA-F0-9]{4}/) || [])[0] || null,
  });
}
```

For a transaction, verify the dapp shows success, or that the balance or object
changed, and that the digest landed on-chain if that matters.

## Worked example — connect then sign in

Most Sui dapps log in with connect-then-sign. Both steps are popups.

1. **Dapp (MCP):** click Sign In / Connect, pick **Slush** in the dapp's wallet
   modal. This wakes the service worker and opens the popup.
2. **Popup (cdp.py):** `targets` → `inspect #approve-connection` → confirm the
   `appName` and account → `click #approve-connection "Approve"`.
3. The dapp immediately requests the login signature → `#sign-personal-message`
   opens. `inspect` it, decode `bytes=` to read the message, confirm it is a
   benign login string → `click … "Sign"`.
4. **Dapp (MCP):** verify `signedIn: true` and the address in the header.

## Network choice — localnet needs a different signer

A correct debuggable wallet browser is still not enough for a **localnet** dapp.

The hosted **Slush web / zkLogin wallet** (`my.slush.app`, where the in-modal
"Slush" entry routes) submits through its own mainnet/testnet backend and
**cannot sign or execute against a private localnet** (`127.0.0.1:9000`).
Symptom: after connecting, the account reads `$0` / "Acquire SUI to begin
transacting" on mainnet, and any localnet mint or sign fails. This is unrelated
to either trap above.

- **Localnet, hands-free** → prefer a **local dev keypair** in the dapp: a
  faucet-funded Ed25519 key signing PTBs directly through the JSON-RPC client.
  No wallet, no popups, fully automatable. Localnet's JSON-RPC rejects the
  automatic `simulateTransaction` gas estimation, so set an explicit
  `tx.setGasBudget(...)`.
- **Localnet with a wallet** → the Slush **extension** this skill drives can
  sign localnet, provided its active network points at the localnet RPC. Check
  the `network=` param in the popup URL.
- **Testnet / mainnet** → the hosted path works; approvals arrive as
  `my.slush.app/dapp-request` pages you can drive through chrome-devtools.

## Timing and lifecycle gotchas

- **Popups auto-close** on focus loss or timeout. Discover, inspect and click in
  one go. If the target vanished, re-trigger the request from the dapp.
- **The service worker sleeps.** Between requests, `targets` for the Slush id
  may be empty. That is normal. An empty list right after a dapp action usually
  means the popup did not open, not that the wallet is gone.
- **Duplicate targets.** Two page targets can share one `requestId`. They back
  the same pending request; driving either resolves it.
- **Not yet mounted.** A fresh popup can briefly return an empty body — React
  has not mounted. Re-inspect before concluding anything.
- **Do not try to make MCP attach to the popup.** Re-running Phase A, calling
  `new_page` on the extension URL, or restarting the MCP connection will not
  make chrome-devtools-mcp list an extension page. The CDP path is the route.

## Safety — what to refuse

- **Locked wallet.** If `inspect` reports `hasPasswordField: true` or an Unlock
  screen, **stop and ask the user to unlock Slush**. Never type, request, or
  guess a wallet password. Never touch a seed phrase.
- **Wiped profile.** Never reinstall a wallet extension or recreate
  `~/dev-chrome`. Report and stop.
- **Signing moves value.** Approving a connection only shares an address and is
  low-risk. `#sign-transaction` / `#approve-transaction` can move funds or
  mint and transfer objects. Always inspect first, and for anything beyond a
  benign personal-message login, confirm with the user what they intend to sign
  before clicking — unless they already authorized this specific automated flow.

## The bundled tool

`scripts/cdp.py` — Python 3 stdlib only. Commands: `targets [substr]`,
`inspect <target>`, `click <target> <text>`, `eval <target> <js>`. `<target>` is
a `ws://` debugger URL, a target id, or a URL substring resolving to a single
page target. Override the endpoint with `CDP_HOST` / `CDP_PORT` (defaults
`127.0.0.1:9222`). `eval` runs JS in any target and works on normal pages too,
which is handy for a quick read without going through MCP. The script's header
docstring has the details.

## Common failures

- **Two Chrome windows, connect modal empty** — attach trap (A4).
- **One window, connect modal empty** — profile-lock trap (A2).
- **Connected, but localnet sign fails, account reads $0 mainnet** — hosted
  wallet cannot do localnet. Switch signer.
- **"ProfileInUse" / Chrome refuses to start** — another instance holds the
  profile. `pkill -f "Google Chrome for Testing"`, then A2.
- **Port 9222 up but `list_pages` empty** — call `new_page` on the app URL or
  `about:blank` to surface a tab.
- **`~/dev-chrome/Default/Extensions` empty** — profile wiped. Ask the user. Do
  not reinstall.
