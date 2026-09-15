---
name: sui-e2e
description: Run end-to-end browser tests against a Sui dapp, driving the Slush wallet hands-free
---

Invoke the `sui-e2e` skill to drive a full end-to-end test of a Sui dapp, including every wallet approval.

## What This Command Does

- **Phase A** — brings up Google Chrome for Testing on port 9222 with the wallet profile, then verifies the debugged browser is the one holding Slush and that `chrome-devtools-mcp` attached to it rather than spawning its own
- **Phase B** — drives the dapp through `chrome-devtools-mcp` and every Slush approval popup through the bundled `scripts/cdp.py`
- Handles connect, sign-in message, and transaction signing without manual clicks
- Verifies each approval on the **dapp** side, not just that the click landed

## Why This Command Exists

`chrome-devtools-mcp` cannot see `chrome-extension://` pages. Slush approval popups never appear in `list_pages`, so `click` and `take_snapshot` are blind to them and every wallet end-to-end test stalls at the first approval. This skill talks raw Chrome DevTools Protocol to those popups instead.

## When to Use

- Testing a Sui dapp end to end with a real wallet in the loop
- An automated browser flow is blocked on a Slush popup
- Verifying a connect-then-sign login works after a change

## When NOT to Use

- The toolchain is not installed yet — run `/sui-setup` first
- You only need to check Move code compiles — that needs no browser

## Network Note

The hosted Slush web wallet cannot sign against a private localnet. For hands-free localnet testing, prefer a faucet-funded local dev keypair signing PTBs directly. The skill covers both paths.

## Related Commands

- `/sui-setup` — Install and verify everything this command needs
