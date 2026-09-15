#!/usr/bin/env python3
"""
cdp.py — dependency-free Chrome DevTools Protocol driver for pages that
chrome-devtools-mcp refuses to attach to (chrome-extension:// popups, most
notably wallet approval windows like Slush / MetaMask).

Why this exists
---------------
chrome-devtools-mcp lists and drives only normal http(s) page targets. Browser
extension pages — including the popup a wallet opens to approve a connection or
a transaction — never appear in its `list_pages`, and `new_page` won't surface
them as a drivable target. So when a Slush popup is the thing standing between
you and a signed login, MCP is blind to it. This script talks the raw CDP
WebSocket directly, which CAN reach those targets.

It uses only the Python standard library (socket + urllib + hashlib), so it
runs anywhere Python 3 does — no `pip install`, no hunting for a stray `ws`
module in some npx cache.

Usage
-----
  cdp.py targets [SUBSTR]
      List page targets from http://HOST:PORT/json, optionally filtered to URLs
      containing SUBSTR (case-insensitive). Shows type, title, url, and the
      target id you can pass to other commands.

  cdp.py inspect <TARGET>
      Dump the target's title, visible body text, and every clickable label
      (buttons, role=button, links). This is how you discover whether a popup
      is asking you to Approve / Reject / Confirm / Sign — or to unlock.

  cdp.py click <TARGET> <TEXT>
      Click the first clickable element whose trimmed text or aria-label equals
      TEXT (case-insensitive), falling back to a contains-match. Prints what it
      matched, or the available labels if nothing matched.

  cdp.py eval <TARGET> <JS_EXPRESSION>
      Evaluate an arbitrary JS expression in the target and print the
      JSON-serializable result. Async expressions (promises) are awaited.

<TARGET> is either a full ws:// debugger URL, a 32-char target id, or a URL
substring (e.g. "approve-connection" or the wallet extension id). A substring
that matches exactly one page target is resolved automatically; if it matches
several, the candidates are printed so you can disambiguate.

Environment
-----------
  CDP_HOST (default 127.0.0.1), CDP_PORT (default 9222)

Examples
--------
  cdp.py targets opcgpfmipidbgpenhmajoajpbobppdil      # all Slush ext targets
  cdp.py inspect approve-connection                     # what's the popup asking?
  cdp.py click approve-connection Approve               # approve the request
  cdp.py eval https://app.example.com "document.title"  # works on normal pages too
"""

import base64
import json
import os
import socket
import struct
import sys
import urllib.request

HOST = os.environ.get("CDP_HOST", "127.0.0.1")
PORT = int(os.environ.get("CDP_PORT", "9222"))


# --------------------------------------------------------------------------- #
# Target discovery (plain HTTP — the /json endpoint is unauthenticated locally)
# --------------------------------------------------------------------------- #
def http_targets():
    url = f"http://{HOST}:{PORT}/json"
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.loads(r.read().decode("utf-8"))


def resolve_ws(target):
    """Turn a ws url / target id / url-substring into a webSocketDebuggerUrl."""
    if target.startswith("ws://") or target.startswith("wss://"):
        return target
    targets = http_targets()
    # exact id match first
    for t in targets:
        if t.get("id") == target and t.get("webSocketDebuggerUrl"):
            return t["webSocketDebuggerUrl"]
    # then url substring, restricted to drivable page targets
    sub = target.lower()
    matches = [
        t for t in targets
        if t.get("type") == "page"
        and t.get("webSocketDebuggerUrl")
        and sub in t.get("url", "").lower()
    ]
    if len(matches) == 1:
        return matches[0]["webSocketDebuggerUrl"]
    if not matches:
        raise SystemExit(
            f"No page target matched {target!r}. Run `cdp.py targets` to list them."
        )
    lines = "\n".join(f"  {t['id']}  {t['url'][:100]}" for t in matches)
    raise SystemExit(
        f"{len(matches)} page targets matched {target!r} — pass an id or ws url:\n{lines}"
    )


# --------------------------------------------------------------------------- #
# Minimal RFC 6455 WebSocket client (text frames only, client-masked)
# --------------------------------------------------------------------------- #
class WS:
    def __init__(self, ws_url, timeout=15):
        # ws://host:port/devtools/page/<id>
        rest = ws_url.split("://", 1)[1]
        hostport, path = rest.split("/", 1)
        path = "/" + path
        host = hostport.split(":")[0]
        port = int(hostport.split(":")[1]) if ":" in hostport else 80
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        handshake = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {hostport}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(handshake.encode())
        self._buf = b""
        # read until end of HTTP headers
        while b"\r\n\r\n" not in self._buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise SystemExit("WebSocket handshake failed (connection closed).")
            self._buf += chunk
        header, self._buf = self._buf.split(b"\r\n\r\n", 1)
        if b"101" not in header.split(b"\r\n", 1)[0]:
            raise SystemExit(f"WebSocket handshake rejected: {header[:120]!r}")

    def _recv_exact(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SystemExit("WebSocket closed mid-frame.")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def send(self, text):
        payload = text.encode("utf-8")
        header = bytearray([0x81])  # FIN + text opcode
        n = len(payload)
        mask_bit = 0x80
        if n < 126:
            header.append(mask_bit | n)
        elif n < (1 << 16):
            header.append(mask_bit | 126)
            header += struct.pack(">H", n)
        else:
            header.append(mask_bit | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def _recv_frame(self):
        b0, b1 = self._recv_exact(2)
        fin = b0 & 0x80
        opcode = b0 & 0x0F
        masked = b1 & 0x80
        length = b1 & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._recv_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._recv_exact(8))[0]
        mask = self._recv_exact(4) if masked else None
        data = self._recv_exact(length)
        if mask:
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        return fin, opcode, data

    def recv_text(self):
        """Reassemble one (possibly fragmented) text message, skipping control frames."""
        chunks = []
        while True:
            fin, opcode, data = self._recv_frame()
            if opcode == 0x8:  # close
                raise SystemExit("WebSocket closed by peer.")
            if opcode in (0x9, 0xA):  # ping/pong — ignore
                continue
            chunks.append(data)
            if fin:
                return b"".join(chunks).decode("utf-8", "replace")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# --------------------------------------------------------------------------- #
# CDP request/response (match responses by id; skip interleaved events)
# --------------------------------------------------------------------------- #
class CDP:
    def __init__(self, ws_url):
        self.ws = WS(ws_url)
        self._id = 0

    def call(self, method, params=None):
        self._id += 1
        mine = self._id
        self.ws.send(json.dumps({"id": mine, "method": method, "params": params or {}}))
        while True:
            msg = json.loads(self.ws.recv_text())
            if msg.get("id") == mine:
                if "error" in msg:
                    raise SystemExit(f"CDP error on {method}: {msg['error']}")
                return msg.get("result", {})
            # otherwise it's an event/other response — keep reading

    def evaluate(self, expression, await_promise=True):
        self.call("Runtime.enable")
        res = self.call(
            "Runtime.evaluate",
            {
                "expression": expression,
                "returnByValue": True,
                "awaitPromise": await_promise,
                "userGesture": True,
            },
        )
        if "exceptionDetails" in res:
            raise SystemExit(f"JS exception: {res['exceptionDetails']}")
        return res.get("result", {}).get("value")

    def close(self):
        self.ws.close()


# --------------------------------------------------------------------------- #
# JS payloads
# --------------------------------------------------------------------------- #
INSPECT_JS = r"""
(() => {
  const sel = 'button, [role="button"], a, input[type="submit"], input[type="button"]';
  const labels = [...document.querySelectorAll(sel)]
    .map(e => (e.innerText || e.value || e.getAttribute('aria-label') || '').trim())
    .filter(Boolean);
  const hasPwd = !!document.querySelector('input[type="password"]');
  return JSON.stringify({
    title: document.title,
    url: location.href,
    body: (document.body ? document.body.innerText : '').slice(0, 1200),
    clickables: labels,
    hasPasswordField: hasPwd,
  });
})()
"""


def CLICK_JS(text):
    t = json.dumps(text)
    return r"""
(() => {
  const want = %s.trim().toLowerCase();
  const sel = 'button, [role="button"], a, input[type="submit"], input[type="button"]';
  const els = [...document.querySelectorAll(sel)];
  const label = e => (e.innerText || e.value || e.getAttribute('aria-label') || '').trim();
  let el = els.find(e => label(e).toLowerCase() === want);
  if (!el) el = els.find(e => label(e).toLowerCase().includes(want));
  if (!el) return JSON.stringify({clicked:false, available: els.map(label).filter(Boolean)});
  el.scrollIntoView({block:'center'});
  el.click();
  return JSON.stringify({clicked:true, matched: label(el)});
})()
""" % t


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def cmd_targets(args):
    sub = (args[0].lower() if args else "")
    for t in http_targets():
        url = t.get("url", "")
        if sub and sub not in url.lower():
            continue
        print(f"[{t.get('type')}] {t.get('title','')[:50]!r}")
        print(f"    id:  {t.get('id')}")
        print(f"    url: {url[:140]}")


def cmd_inspect(args):
    cdp = CDP(resolve_ws(args[0]))
    try:
        print(cdp.evaluate(INSPECT_JS))
    finally:
        cdp.close()


def cmd_click(args):
    target, text = args[0], args[1]
    cdp = CDP(resolve_ws(target))
    try:
        print(cdp.evaluate(CLICK_JS(text)))
    finally:
        cdp.close()


def cmd_eval(args):
    target, expr = args[0], args[1]
    cdp = CDP(resolve_ws(target))
    try:
        val = cdp.evaluate(expr)
        print(val if isinstance(val, str) else json.dumps(val))
    finally:
        cdp.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd, rest = sys.argv[1], sys.argv[2:]
    table = {
        "targets": (cmd_targets, 0),
        "inspect": (cmd_inspect, 1),
        "click": (cmd_click, 2),
        "eval": (cmd_eval, 2),
    }
    if cmd not in table:
        print(f"Unknown command {cmd!r}.\n{__doc__}")
        sys.exit(1)
    fn, need = table[cmd]
    if len(rest) < need:
        print(f"`{cmd}` needs {need} argument(s).\n{__doc__}")
        sys.exit(1)
    fn(rest)


if __name__ == "__main__":
    main()
