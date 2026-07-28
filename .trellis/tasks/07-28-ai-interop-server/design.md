# Design — AI interop local server

## 1. Shape

```
Settings ▸ AI Access                    AI client
  ┌──────────────────────┐                 │
  │ ☑ Enable             │                 │ GET /diagnose
  │ http://127.0.0.1:7845│                 │ Authorization: Bearer …
  │ Token  ••••  Copy ⟳  │                 ▼
  │ Skills:              │        ┌─────────────────────┐
  │  · machine.state     │        │ BridgeServer        │  NWListener, loopback
  │  · power.wakes       │        │  ├ RequestParser    │  hand-rolled HTTP subset
  │  · metrics.history   │        │  ├ TokenGuard       │  constant-time compare
  └──────────────────────┘        │  └ Router           │  routes carry their own docs
                                  └─────────┬───────────┘
                                            │ reads only
                                  ┌─────────▼───────────┐
                                  │ existing services   │  metrics, power, storage
                                  └─────────────────────┘
```

The server is a **reader**. It holds no state of its own beyond the listener and never
calls a mutating method on any service.

## 2. Transport

`NWListener` on `NWEndpoint.Host("127.0.0.1")` with `NWParameters.tcp`. Loopback is
enforced by the bind address, and asserted in a test that connects from the LAN address
and expects failure — a comment claiming "loopback only" is not evidence.

**Why not URLSession/Vapor/Swifter:** no new dependencies is a stated constraint, and
`Network.framework` ships with the OS.

**What that costs:** a hand-rolled HTTP parser is a real attack surface, reachable by
any local process before the token is checked. That is not hand-waved away — see §4.

## 3. Route declaration carries its own documentation

A route cannot exist without docs, because they are the same value:

```swift
struct Route {
  let method: HTTPMethod
  let path: String
  let skill: Skill?              // nil = infrastructure, not offered to an AI
  let summary: String
  let responseSchema: JSONSchema
  let handler: (Request) throws -> Response
}
```

`/openapi.json` and `/skills` are both generated from the route table, and the UI's
skill list reads the same table. There is no second place to update, so docs cannot
drift from behaviour.

## 4. Parsing untrusted input

The parser is the security-relevant part, so it is written to fail closed:

| Guard | Limit | Reason |
|---|---|---|
| Request line | 8 KB | A missing newline must not buffer forever |
| Header block | 16 KB total, 100 headers | Header flooding |
| Body | 64 KB | Nothing here takes a large body |
| Idle timeout | 10 s | A slow client must not hold a connection open |
| Concurrent connections | 8 | Trivial exhaustion |
| Method | Exact match against a known set | No fall-through |

Anything violating a limit closes the connection after a minimal error. Malformed input
is a **first-class test target**, not an afterthought: truncated request lines, absent
method, no `Host`, duplicated headers, `Content-Length` disagreeing with the body,
a body sent without `Content-Length`, split-packet delivery, and a connection that
opens and sends nothing.

## 5. Authentication

- 32 bytes from `SecRandomCopyBytes`, base64url.
- Stored in the Keychain as a generic password under
  `com.tagzxia.app.menucue.bridge-token`, matching the identity namespace the branding
  spec fixes. **Not** `UserDefaults` — that file is world-readable within the account.
- Compared in **constant time**. A short-circuiting `==` leaks the token a byte at a
  time to a local timing attack, which is exactly the attacker this design assumes.
- `GET /health` is the only unauthenticated route and returns `{"ok":true}` with no
  machine data — enough for a client to find the port, useless to anyone else.
- Regenerating replaces the Keychain item; in-flight connections are dropped.

## 6. Payload conventions

```json
{
  "capturedAt": "2026-07-28T01:12:33+08:00",
  "memory": {
    "usedBytes": 46170898432,
    "usedText": "46.2 GB",
    "totalBytes": 51539607552,
    "pressure": "warning"
  },
  "gpu": { "utilization": null }
}
```

- ISO 8601 with offset. Raw integers **and** a formatted string, so the AI never parses
  "46.2 GB" and never re-derives a unit.
- Unavailable is `null` and documented as such. This is the same rule the UI follows —
  an AI handed a `0` for an unreadable sensor will confidently report a wrong diagnosis,
  which is worse than a UI showing a wrong number to a human who can see it is odd.

### `/diagnose`

One call returning current state, notable recent changes, and anything the app judges
abnormal — high memory pressure, thermal headroom, a process holding a sleep assertion
for hours, a disk near full. Each finding carries `severity`, a plain sentence, and the
evidence that produced it, so an AI can quote the reason rather than inventing one.

The judgement thresholds live in one place and are unit-tested, because "abnormal" is
product opinion and must not be scattered across handlers.

## 7. Lifecycle and cost

- Off by default, persisted through `AppModel` like every other setting.
- Enabling starts the listener; it does **not** start sampling. Handlers read the last
  snapshot, or take a one-shot reading. This keeps the promise that the API is a window
  onto work already being done.
- Idle cost is an `NWListener` with no connections — nothing periodic. Measured and
  recorded rather than asserted.

## 8. Cross-child contract

`/power/wakes` and `/power/processes` serialize the model from
`07-28-power-wake-insight`: `WakeEvent`, `WakeCause`, `SleepAssertion`. Written here and
in that task's PRD so the dependency is explicit rather than implied by tree position.

If that task has not landed, these two routes are absent from the route table — and
therefore absent from `/skills` and `/openapi.json` too, with no special-casing.

## 9. What is deliberately not built

- **Write access.** Every route is a `GET`. A control channel is a different product
  decision with a different threat model.
- **TLS.** Meaningless on loopback and would add certificate handling.
- **Discovery.** No Bonjour. The user copies the URL and token.
- **MCP.** It would remove the port surface entirely and is the likely successor once
  the read API settles. Building both now would mean two surfaces to secure.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Hand-rolled HTTP has a hole | Strict limits, fail-closed parsing, malformed input as a primary test target, no write routes so a parser bug reads at worst what the UI already shows |
| A browser page reaches the server | Token required; no CORS headers, so a page cannot read cross-origin responses even if it can send |
| Token leaks via the UI | Masked by default, revealed on demand, regenerable |
| Port already in use | Reported plainly with a suggested alternative; never silently binds elsewhere |
| Feature exposes more than the UI | Route table reviewed against what the panes show; the check is written into the acceptance criteria |
