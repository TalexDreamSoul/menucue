# AI interop local server

## Goal

Let an AI assistant answer "what is wrong with this Mac?" by reading what MenuCue has
already measured. The app runs a local server; the AI calls it; the app publishes the
skills and API docs that describe what can be asked.

This was stated as the reason the metrics are collected at all, so the API is the
product here — not an afterthought bolted onto the UI.

## Naming

Working name **MenuCue Bridge**, surfaced to the user as "AI Access". The final name is
open; keep it in one place so renaming is a single edit.

## Requirements

### R1 — The server

- HTTP/JSON over TCP, bound to **127.0.0.1 only**. Never `0.0.0.0`, no Bonjour
  advertisement.
- **Off by default.** The user turns it on in Settings; nothing listens until then.
- A default port with an override, and the effective URL shown in the UI.
- Starting and stopping take effect immediately, and the UI always states plainly
  whether it is listening right now.

### R2 — Authentication

- A token is generated when the feature is first enabled, stored in the **Keychain**
  (not `UserDefaults`), and shown in the UI with copy and regenerate.
- Every request except `GET /health` requires `Authorization: Bearer <token>`.
- A missing or wrong token returns `401` and reveals nothing about the machine.
- Regenerating invalidates the previous token immediately.

Rationale for the decision taken on this task: a loopback server with no auth is
readable by *any* local process, including a page in a browser. The token is what stops
a visited site from reading this Mac's history.

### R3 — Skills and documentation

- The app displays the skill catalog: for each skill a name, one line on what it
  answers, and its endpoint. This is the surface the user shows an AI.
- `GET /skills` returns that same catalog as JSON.
- `GET /openapi.json` returns a valid OpenAPI 3.1 document covering every endpoint, so
  an AI client can consume the API without being told about it.
- Docs are generated from the same route declarations, so a route that is not
  documented cannot exist.

### R4 — What is exposed

Nothing the app does not already show its own user.

| Endpoint | Answers |
|---|---|
| `GET /health` | is it up (no auth, no machine data) |
| `GET /system` | chip, cores, memory size, macOS version, uptime |
| `GET /metrics/current` | latest CPU / memory / disk / network / sensor snapshot |
| `GET /metrics/history?window=` | recorded series over a window |
| `GET /power/wakes?since=` | wake events with cause, in plain language |
| `GET /power/processes` | what has been running, and what has been using energy |
| `GET /storage/volumes` | mounted volumes and capacity |
| `GET /diagnose` | one digest an AI can read in a single call: current state, notable recent changes, anything the app considers abnormal |

- Timestamps are ISO 8601 with offset. Byte counts are raw integers *plus* a formatted
  string, so an AI never has to parse "12.4 GB".
- Every field that can be unavailable is nullable and documented as such. An AI must
  never be handed a zero that means "unknown" — the same rule the UI already follows.

### R5 — Cost

- Enabling the server starts no sampling. It reads what is already collected, or takes
  a one-shot reading on request.
- An idle enabled server costs no measurable CPU.

## Constraints

- **No new package dependencies.** The server is built on `Network.framework`
  (`NWListener`) with the HTTP subset parsed in-app. This is a real cost, not a free
  choice: hand-rolled HTTP is an attack surface, so the parser is written defensively
  and tested against malformed input rather than assumed correct.
- History has to survive relaunch to be worth querying. Storage must be bounded, and
  its size disclosed in the UI.

## Acceptance criteria

- [ ] Off by default: nothing listening after a fresh launch, confirmed with
      `lsof -iTCP -sTCP:LISTEN`.
- [ ] When enabled, bound to loopback only — confirmed by a connection to the machine's
      LAN address failing while a loopback connection succeeds.
- [ ] Every endpoint returns JSON that matches `/openapi.json`.
- [ ] Missing token, wrong token, and a token from before a regenerate all return `401`.
- [ ] Malformed requests — oversized headers, absent method, truncated body, wrong verb,
      slow client — return an error instead of crashing or hanging. Covered by tests.
- [ ] `/diagnose` output, pasted to an AI, gets the machine's state right.
- [ ] Enabling the server does not raise idle CPU.
- [ ] All new UI strings localized in both catalogs.

## Out of scope

- Non-loopback binding, TLS, multi-user auth.
- **Write access.** This release is read-only: no endpoint changes a system setting.
  A control surface is a separate decision, because it turns a diagnostic reader into a
  remote-control channel.
- MCP transport. It would remove the port surface entirely and is the likely next step
  once the read API has settled, but it is not this task.
