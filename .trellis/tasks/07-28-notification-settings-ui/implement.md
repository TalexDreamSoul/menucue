# Implementation plan: Notifications settings UI

## RED

- Add settings-store round-trip/migration tests proving notification data is local and secrets are absent.
- Add device-name fallback/override/reset tests.
- Add template lexer/validation/rendering/default/preview tests, including Unicode and output limits.
- Add settings-pane routing and model tests for channel/rule enablement, validation, test states, target disappearance, and catalog-driven control metadata.

## GREEN

- Add non-secret notification settings models and SettingsStore/AppModel persistence.
- Add configuration service for Keychain intents and channel test delivery.
- Add Notifications pane/sidebar metadata and channel forms.
- Add rule list/editor, metric target/condition/timing controls, and runtime summaries.
- Add alert/recovery template editor, variable menu, preview, reset, and validation.
- Wire app-lifetime monitor and delivery coordinator from application construction.
- Add English and Simplified Chinese strings.

## REFACTOR

- Extract reusable channel-row/form framing without hiding typed field differences.
- Keep parser/catalog/validation out of view bodies.
- Audit compact/default window layouts, focus order, VoiceOver, and long localized text.

## Validation

```sh
swift test --filter NotificationSettings
swift test --filter NotificationTemplate
swift test --filter AlertRuleSettings
./scripts/verify-localizations.swift
swift test
./scripts/build-app.sh
```

## Rollback

Remove the pane and app wiring while preserving stored local settings and Keychain data for downgrade safety. Explicit credential removal remains a user action.
