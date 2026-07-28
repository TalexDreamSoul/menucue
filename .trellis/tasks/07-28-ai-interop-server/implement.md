# Implementation Plan — AI interop local server

Built inside-out: the parser and the token guard are the security-relevant parts, so
they exist and are attacked before anything is served.

## Step 1 — HTTP parsing, on its own  ▸ design §4

`BridgeRequestParser` as a pure value type over `Data`, no networking. Incremental:
fed bytes, returns `.needMore`, `.request(_)` or `.malformed(_)`.

Limits from the design table are constants on the parser.

**Validate:** tests come first here, because this is the part a hostile local process
reaches before authentication. Cover: truncated request line, no method, unknown
method, header flood, oversized header, oversized body, `Content-Length` disagreeing
with the body, body without `Content-Length`, request split across packet boundaries at
every offset, bare CR, bare LF, and an empty connection.

**Review gate:** if any malformed input produces `.request` rather than `.malformed`,
stop. Everything downstream trusts this type.

---

## Step 2 — Token store  ▸ design §5

`BridgeTokenStore`: generate with `SecRandomCopyBytes`, persist in the Keychain under
`com.tagzxia.app.menucue.bridge-token`, load, regenerate, delete.

**Validate:** round-trips across a process restart. Regenerating invalidates the old
value. Constant-time comparison is used — asserted by testing the comparison function
against equal-prefix inputs, and by its presence being required at the single call site.

**Watch:** the Keychain prompts if the item is created under a different signing
identity. Confirm behaviour with the ad-hoc signed local build before assuming it is
silent.

---

## Step 3 — Route table and docs  ▸ design §3

`Route` values with schema and summary, and generation of `/openapi.json` and
`/skills` from them.

**Validate:** `/openapi.json` parses as JSON and validates against the OpenAPI 3.1
meta-schema. A test asserts every route has a non-empty summary and schema — a route
that cannot be documented cannot compile.

---

## Step 4 — Listener  ▸ design §2

`NWListener` on 127.0.0.1, connection limit, idle timeout, wiring parser → token guard
→ router.

**Validate:**
- `lsof -iTCP -sTCP:LISTEN` shows nothing before enabling, and `127.0.0.1:<port>` only
  after.
- `curl http://127.0.0.1:<port>/health` succeeds; `curl http://<LAN-IP>:<port>/health`
  fails to connect. **Both** are run — the second is the one that proves the claim.
- No token, wrong token, and a pre-regenerate token each return `401`.

---

## Step 5 — Read routes  ▸ PRD R4

`/system`, `/metrics/current`, `/metrics/history`, `/storage/volumes`, and the two
power routes if that task has landed.

Serialization follows the raw-plus-formatted, `null`-for-unavailable convention.

**Validate:** every response validates against its declared schema. A metric that is
genuinely unavailable on this Mac — GPU counters when idle, fans on a fanless Mac —
serializes as `null`, not `0`. Cross-check one payload by hand against the UI.

---

## Step 6 — `/diagnose`  ▸ design §6

Findings with severity, a plain sentence, and the evidence. Thresholds in one tested
place.

**Validate:** paste the output to an AI and check it gets the machine's state right.
That is the acceptance criterion; a schema-valid document that leads to a wrong
conclusion has failed.

---

## Step 7 — Settings UI  ▸ PRD R1, R2, R3

Toggle, URL, masked token with copy and regenerate, skill list from the route table,
current listening state.

**Validate:** render light and dark via `ImageRenderer`. Toggling starts and stops the
listener immediately, confirmed with `lsof` while the app runs. All strings in both
catalogs.

---

## Step 8 — Quality pass

1. `swift build` — no new warnings.
2. `swift test` — green.
3. `verify-localizations` plus the code→catalog scan.
4. Idle CPU measured with the server enabled and no clients; number recorded.
5. Route table read against the panes: nothing exposed that the UI does not show.
6. Re-read acceptance criteria one by one.
7. Dispatch `trellis-check`.

---

## Rollback points

| After step | State |
|---|---|
| 3 | Docs and routes exist, nothing listens |
| 4 | Server reachable, `/health` only |
| 5 | Read API complete |

Nothing before step 4 opens a socket, so the whole thing can be built and tested with
no network surface at all.

## Validation commands

```bash
swift build && swift test
lsof -iTCP -sTCP:LISTEN | grep MenuCue          # before and after enabling
curl -s http://127.0.0.1:7845/health            # expect 200
curl -s http://$(ipconfig getifaddr en0):7845/health   # expect connection refused
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7845/diagnose | jq .
curl -s http://127.0.0.1:7845/system            # expect 401
```
