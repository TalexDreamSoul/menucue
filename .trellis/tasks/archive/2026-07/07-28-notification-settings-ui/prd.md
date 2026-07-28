# Notification settings and template editor

## Goal

Give users one native Notifications settings pane for device identity, four independently enabled channels, catalog-driven alert rules, and variable-aware alert/recovery templates.

## Requirements

- Add a Notifications sidebar pane consistent with the existing settings shell and localization patterns.
- Default device display name from the Mac name/hostname and allow local override/reset.
- Persist non-secret channel metadata, enablement, rules, and templates through `AppModel`/`SettingsStore`; use the notification configuration service for Keychain intents and runtime validation/test status. Feishu webhook URL, generic Webhook endpoint/bearer token, Bark device key, and Telegram bot token are always Keychain values.
- Show Feishu, Webhook, Bark, and Telegram rows with configure, credential removal, enable, validation, and test actions.
- Prevent channel enablement until required non-secret/secret fields validate.
- Provide a rule list with add/edit/delete/enable actions and readable condition/runtime summaries.
- Build the editor from metric catalog metadata: metric/event, optional target, operator, threshold/severity, sustained duration, recovery boundary/duration, cooldown, and enabled state.
- Give each rule alert title/body templates and each metric rule recovery title/body templates.
- Integrate the shared fixed `{{variable}}` parser/renderer with an allowed-variable insertion menu, field-level errors, representative preview, output limits, and reset defaults.
- Keep secrets masked, transient drafts out of `AppSettings`, and all notification settings out of portable iCloud fields.
- Cover keyboard navigation, VoiceOver names, minimum/default window sizes, loading/testing/success/failure/unavailable states, and English/Simplified Chinese strings.

## Acceptance Criteria

- [ ] Device-name fallback, override, reset, persistence, and rendered test-message identity are covered.
- [ ] All four channel forms expose exactly their typed fields; no secret appears in plain labels, local settings, or sync envelopes.
- [ ] A configured channel can test independently and one test state does not overwrite another.
- [ ] The rule editor adapts controls/units/variables to catalog metadata and rejects unsupported combinations.
- [ ] Template tests cover insertion, unknown variables, repeated variables, Unicode, missing optional context, size limits, preview, and reset.
- [ ] Event rules omit meaningless recovery controls; metric rules expose alert and recovery templates.
- [ ] The pane remains usable at 720x540 and 900x680 without overlapping text, nested cards, or clipped controls.
- [ ] Focused UI/model tests, localization verification, full `swift test`, and app build pass.

## Dependencies

Depends on stable transport/configuration contracts from `07-28-notification-transport` and catalog/rule contracts from `07-28-metric-alert-rules`.
