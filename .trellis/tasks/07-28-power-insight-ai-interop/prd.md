# MenuCue power insight and AI interop

Parent task. Owns the source requirements and the cross-child acceptance criteria;
each child is planned, implemented and checked on its own.

## Source requirements

Verbatim intent from the request, split into three deliverables:

1. **Popover trackpad swipe is broken.** The suggestion was to look at accessibility
   permissions and trackpad settings.
2. **Power monitoring.** Continuously watch which processes keep running, and identify
   *who woke the Mac* during sleep. The current detection "has problems". The result
   should be a very plain-language interface or prompt — not raw diagnostics.
3. **AI interop ("AI 互联互通", final name TBD).** On launch, the app runs a local
   server. An AI calls it through skills the app displays. Publish API docs so an AI
   can fetch what the app knows about this Mac plus past logs, to diagnose machine
   state quickly. This is stated as the *point* of collecting the metrics at all.

## Task map

| Child | Deliverable |
|---|---|
| `07-28-popover-swipe-tracking` | A two-finger sideways flick over the popover changes tab, confirmed on a real trackpad |
| `07-28-power-wake-insight` | Continuous power monitoring with a plain-language answer to "what woke my Mac" and "what keeps running" |
| `07-28-ai-interop-server` | Loopback HTTP server, token auth, skill catalog and API docs over the collected metrics and history |

Ordering is not implied by the tree. The AI server child depends on the power child
only for the *shape* of the wake/process history it exposes; that contract is written
into both children rather than left implicit.

## Constraints (all children)

- macOS 14+, SwiftUI, Swift 5.9. No new package dependencies without calling it out.
- Every user-visible string goes through `L10n.string(...)` with a static literal key,
  added to both `en.lproj` and `zh-Hans.lproj`. `scripts/verify-localizations.swift`
  and `LocalizationResourceTests` enforce this.
- Views do not touch `UserDefaults`; settings mutations go through `AppModel`.
- Readings never fabricate: an unavailable metric shows an explicit unsupported state,
  never a zero that reads as a measurement.
- Anything that cannot be verified before shipping is called out as unverified rather
  than reported as done.

## Security decision (fixed by the user)

The AI server binds **loopback only** and requires a **token**. The token is generated
by the app and shown in its UI; requests without it are rejected. The server is **off
by default** and the user turns it on. This was chosen over an unauthenticated
loopback server precisely because any local process — including a web page — could
otherwise read this Mac's system information and history.

## Cross-child acceptance criteria

- [ ] `swift build` clean, `swift test` green, `verify-localizations` passes, on the
      merged result of all three children.
- [ ] No child regresses the popover or the Dashboard.
- [ ] The AI server exposes nothing that the app does not already show the user in its
      own UI, and nothing at all until the user turns it on.
- [ ] Every claim of "works" is backed by an observation, not by reasoning alone.

## Out of scope

- Remote (non-loopback) access, any cloud component, telemetry.
- Shipping a release; that is a separate decision after the children land.
