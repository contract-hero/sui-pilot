---
name: sui-e2e
description: Run end-to-end browser tests against a Sui dapp, driving the Slush wallet hands-free
---

Invoke the `sui-e2e` skill to drive a full end-to-end test of a Sui dapp, including every wallet approval.

## What This Command Does

- **Phase A** — brings up Google Chrome for Testing on port 9222 with the wallet profile, then checks that the debugged browser is the one holding Slush and that `chrome-devtools-mcp` attached to it rather than spawning its own. Slush is an MV3 worker that can be dormant, so the definitive wallet check is functional and happens in Phase B
- **Phase B** — drives the dapp through `chrome-devtools-mcp` and every Slush approval popup through the bundled `scripts/cdp.py`
- Handles connect, sign-in message, and transaction signing without manual clicks
- Verifies each approval on the **dapp** side, not just that the click landed
- Works around `chrome-devtools-mcp` being unable to see `chrome-extension://` pages at all — wallet popups never reach `list_pages`, so a bundled raw-CDP client drives them instead

## When to Use

- Testing a Sui dapp end to end with a real wallet in the loop
- An automated browser flow is blocked on a Slush popup
- Verifying a connect-then-sign login works after a change

## When NOT to Use

- The toolchain is not installed yet — run `/sui-setup` first
- You only need to check Move code compiles — that needs no browser

## Limitations

- The hosted Slush web wallet cannot sign against a private localnet; the skill routes localnet runs to a faucet-funded local keypair instead.
- Wallet state is report-only — a locked wallet or a wiped profile stops the run and asks you.

## Related Commands

- `/sui-setup` — Install and verify everything this command needs
