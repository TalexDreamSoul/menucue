#!/usr/bin/env python3
"""Guarded client for Pen.app's `pencil` MCP server (stdio).

Why the guard exists
--------------------
`execute` in the Pen MCP has **no document selector**. The tool takes a
`filePath` argument, but that argument is neither validated nor used to route
the call: `execute` always runs its snippet against Pen's *currently active
canvas editor*. Verified on 2026-09-12 against Pen 2.x / MCP server
"pencil 1.0.0": passing `filePath=/…/v1.0.0.pen` while CrosyLink's document was
the active editor returned CrosyLink's node tree.

Pen is also a single shared instance: several agents (or the user) driving one
Pen app will all act on whichever document is frontmost. The only safe way to
edit is therefore:

1. preflight — assert `get_app_state`'s active canvas editor is your file;
2. in-snippet guard — assert a document-identity marker and `throw` otherwise.

A thrown error makes `execute` report
"All operations in this block have been rolled back", so a wrong-document
execution is atomic and harmless. `execute_guarded()` always installs both.

Usage
-----
    python3 pen_mcp.py state
    python3 pen_mcp.py exec FILE --guard 'comp/toggle/on' --code 'Print(1)'
    python3 pen_mcp.py exec FILE --guard MARKER --file-code script.js

As a library:

    from pen_mcp import PenMCP
    pen = PenMCP()
    pen.execute_guarded("/abs/path/design.pen", "comp/toggle/on",
                        'Insert(document, {type:"text", name:"Note", content:"hi"})')

Rules that keep this safe (learned the hard way — see the
`pen-document-programmatic-authoring` skill):

- NEVER drive Pen's GUI (AppleScript menu clicks, `Save As…`) to edit or save.
  That acts on the frontmost window and has already written one project's
  document onto another project's filename.
- ALWAYS pass an absolute `filePath` and a `--guard` marker; a plausible
  filename proves nothing about which document is loaded.
- Re-read `get_app_state` before every mutation batch — the document can change
  under you while you work (multiplayer document, concurrent agents).
"""

from __future__ import annotations

import argparse
import collections
import json
import queue
import subprocess
import sys
import threading
import time

BIN = "/Applications/Pen.app/Contents/Resources/app.asar.unpacked/out/mcp-server-darwin-arm64"

# JSON-RPC / MCP errors raised by the server for a failed snippet. The server
# wraps snippet failures in a tool error, so both shapes surface as strings.
_ACTIVE_PREFIX = "Currently active canvas editor:"


class PenError(RuntimeError):
    """The MCP call failed, or the document guard rejected the active editor."""


class PenMCP:
    """One MCP server process, one stdio session."""

    def __init__(self, agent: str = "claudeCodeCLI", timeout: int = 60):
        self._q: queue.Queue[str] = queue.Queue()
        self._err: collections.deque[str] = collections.deque(maxlen=80)
        self._id = 0
        self.default_timeout = timeout
        self.p = subprocess.Popen(
            [BIN, "--app", "desktop", "--agent", agent],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        threading.Thread(target=self._reader, daemon=True).start()
        # stderr MUST be drained: an undrained 64 KiB pipe buffer blocks the
        # server mid-request, which looks exactly like a hung MCP call.
        threading.Thread(target=self._err_reader, daemon=True).start()
        self.call(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "omp-pen-guard", "version": "1.0"},
            },
            notify_initialized=True,
        )

    # -- plumbing -----------------------------------------------------------
    def _reader(self) -> None:
        for line in self.p.stdout:
            self._q.put(line.rstrip("\n"))

    def _err_reader(self) -> None:
        for line in self.p.stderr:
            self._err.append(line.rstrip("\n"))

    def stderr_tail(self, n: int = 10) -> str:
        return "\n".join(list(self._err)[-n:])

    def _send(self, obj: dict) -> None:
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def call(self, method: str, params: dict | None = None, *,
             notify_initialized: bool = False, timeout: float | None = None):
        """Send one JSON-RPC request; return the result text or raise PenError.

        Returns as soon as the matching response arrives — the timeout is a
        ceiling, not a delay. (Draining the whole window made every call take
        the full timeout, which is what made this server look like it "hangs".)
        """
        self._id += 1
        rid = self._id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        if notify_initialized:
            self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        deadline = time.time() + (timeout or self.default_timeout)
        while True:
            left = deadline - time.time()
            if left <= 0:
                raise PenError(f"no response to {method} within "
                               f"{timeout or self.default_timeout}s")
            try:
                line = self._q.get(timeout=min(left, 0.25))
            except queue.Empty:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") != rid:
                continue
            if "error" in msg:
                err = msg["error"]
                raise PenError(err.get("message") if isinstance(err, dict) else str(err))
            result = msg.get("result")
            if isinstance(result, dict) and "content" in result:
                return "".join(c.get("text", "") for c in result["content"])
            return result

    def tool(self, name: str, args: dict | None = None, *, timeout: float | None = None):
        return self.call("tools/call", {"name": name, "arguments": args or {}}, timeout=timeout)

    # -- transient-failure handling ----------------------------------------
    _TRANSIENT = ("no response to tools/call", "wrong .pen file", "timeout tool=")

    def retry(self, fn, attempts: int = 4, delay: float = 6.0):
        """Retry `fn` while the failure is the app's intermittent timeout.

        Pen answers most agent calls in milliseconds but intermittently lets a
        request die on its own ~62s timeout ("you are probably referencing the
        wrong .pen file"), then serves the identical call fine a moment later.

        Only safe for calls whose effect you can re-establish: reads, and
        guarded mutations, because the guard re-asserts document identity on
        every attempt. A *timed-out mutation's* outcome is unknown, so confirm
        with a read before retrying it.
        """
        last: PenError | None = None
        for attempt in range(attempts):
            try:
                return fn()
            except PenError as exc:
                last = exc
                if not any(marker in str(exc) for marker in self._TRANSIENT):
                    raise
                if attempt + 1 < attempts:
                    time.sleep(delay * (attempt + 1))
        raise last  # type: ignore[misc]

    def close(self) -> None:
        try:
            self.p.terminate()
        except Exception:
            pass

    # -- document identity --------------------------------------------------
    def active_editor(self, retries: int = 3) -> str:
        """Absolute path of Pen's active canvas editor ('' when none).

        The state line is a markdown bullet, so match the label anywhere in the
        line rather than at its start.
        """
        state = self.retry(lambda: self.tool("get_app_state") or "", attempts=retries) or ""
        for line in state.splitlines():
            if _ACTIVE_PREFIX in line:
                return line.split(_ACTIVE_PREFIX, 1)[1].strip().strip("`")
        return ""

    def assert_active(self, file_path: str) -> str:
        """Fail unless `file_path` is the document `execute` would write to."""
        active = self.active_editor()
        if active != file_path:
            raise PenError(
                "refusing to execute: active canvas editor is "
                f"{active or '(none)'!r}, not {file_path!r}. "
                "Bring the target document to the front in Pen first — the MCP "
                "server has no way to switch documents."
            )
        return active

    # -- guarded execution --------------------------------------------------
    def execute_guarded(self, file_path: str, marker: str, code: str, *,
                        timeout: float | None = None, retries: int = 2) -> str:
        """Run `code` only if the active editor both *is* `file_path` and
        *contains* `marker` as a top-level node name.

        `ctx.depth === 0` are the document's top-level nodes (verified against
        a 54-node document); `depth === 1` is their children. Using the wrong
        level makes the guard reject a correct document, which is safe but
        useless — hence the explicit level here.

        The marker check runs inside the snippet and throws, so a mismatch is
        rolled back atomically even if `assert_active` was fooled by a stale
        state read.
        """
        self.assert_active(file_path)
        guard = (
            "let _n=[];Get(document,(n,c)=>{if(c.depth===0)_n.push(n.name||'')});"
            f"if(!_n.includes({json.dumps(marker)}))"
            "{throw new Error('WRONG_DOCUMENT top='+_n.slice(0,4).join('/'))};"
        )
        return self.retry(
            lambda: self.tool("execute", {"filePath": file_path, "input": guard + code},
                              timeout=timeout),
            attempts=retries,
        )

    def marker_for(self, file_path: str) -> str:
        """Suggest a guard marker: the longest top-level node name is the most
        distinctive available identity for a document."""
        code = ("let _n=[];Get(document,(n,c)=>{if(c.depth===0)_n.push(n.name||'')});"
                "Print(_n.join('\\u0001'))")
        self.assert_active(file_path)
        out = self.tool("execute", {"filePath": file_path, "input": code}) or ""
        names = [n for n in out.split("\u0001") if n.strip()]
        if not names:
            raise PenError(f"no top-level node names in {file_path}")
        return max(names, key=len)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("state", help="print Pen's active canvas editor")

    ex = sub.add_parser("exec", help="execute a guarded snippet")
    ex.add_argument("file", help="absolute path of the target .pen")
    ex.add_argument("--guard", required=True,
                    help="top-level node name that must exist in the target document")
    g = ex.add_mutually_exclusive_group(required=True)
    g.add_argument("--code", help="snippet source (JavaScript)")
    g.add_argument("--file-code", help="read the snippet from this file")
    ex.add_argument("--timeout", type=float, default=180)

    sub.add_parser("marker", help="suggest a --guard marker for the active document")

    args = ap.parse_args(argv)
    pen = PenMCP()
    try:
        if args.cmd == "state":
            print(pen.active_editor())
            return 0
        if args.cmd == "marker":
            print(pen.marker_for(pen.active_editor()))
            return 0
        code = args.code if args.code else open(args.file_code, encoding="utf-8").read()
        print(pen.execute_guarded(args.file, args.guard, code, timeout=args.timeout))
        return 0
    except PenError as exc:
        print(f"pen-mcp: {exc}", file=sys.stderr)
        return 2
    finally:
        pen.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
