# Remaining work — deferred 2026-08-05

Two of the four children are done and shipping. The other two are parked here on the
developer's call, so the state is explicit rather than inferred from task status.

## Done

- `08-05-status-clock-push-transition` — implemented, 435 tests green.
- `08-05-calendar-permission-recovery` — implemented, 435 tests green.

## TODO

### `08-05-fan-control-spike`

Blocked on the developer, not on design. The probe writes SMC keys as root, so it needs a
`sudo` password that an agent cannot supply, and it should be run with the developer present:
a probe that fails to restore `F{n}Md = 0` leaves the machine's fans forced and is a thermal
hazard.

Prerequisite before any fan feature is designed. `prd.md` in that task holds the key map, the
encoding, and the safety contract.

### `08-05-meeting-join-countdown`

Complex task — needs `design.md` and `implement.md` before `task.py start`, per the workflow.
Nothing blocks writing those.

This is where the Lark request actually lands: link detection over EventKit data covers Lark,
Tencent Meeting, DingTalk, Zoom, Meet, Teams, and Webex at once, with no per-provider auth.

## Not scheduled

See `notes.md` § 4 for the product comparison backlog. The largest single gap is menu bar
monitoring widgets — the thing Stats and iStat Menus lead with, and the one MenuCue has no
answer to. That is a product-line decision, not a follow-up, so it is deliberately not filed
as a task here.
