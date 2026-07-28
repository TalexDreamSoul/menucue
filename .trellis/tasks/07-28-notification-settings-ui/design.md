# Design: Notifications settings UI

## Placement

Add `SettingsPane.notifications` between Quick Actions and iCloud-adjacent device settings, with `bell.badge` and a dedicated `NotificationSettingsView`. Reuse the existing `NavigationSplitView`, `SettingsPaneHeader`, `SettingsGroup`, control sizes, and spacing.

## View model boundaries

`AppSettings` contains only non-secret `NotificationSettings`: device-name override, non-secret channel fields/enablement, and rule definitions/templates. `AppModel.updateSettings` remains the mutation path. A `NotificationConfigurationService: ObservableObject` owns Keychain draft/write/delete operations plus per-channel validation/test state.

The template parser/renderer and metric catalog are shared model code from the alert-rules child. SwiftUI asks them for fields, units, supported variables, validation, and preview; it does not duplicate switch logic.

## Information architecture

- Identity: one text field and Reset to Mac Name.
- Channels: four rows. Status and primary actions remain visible; Configure reveals channel-specific fields inline. Use `SecureField` for entered secrets and never repopulate a saved secret into visible text.
- Rules: selectable list with add/delete and status. The editor is a full-width unframed section below/alongside the list depending on available width.
- Conditions: native pickers, steppers/text fields, and unit labels generated from catalog metadata.
- Templates: Alert/Recovery segmented mode, title/body editors, variable `Menu`, inline validation, and preview. Event rules show Alert only.

## Interaction states

Channel state is independent: unconfigured, ready, testing, success, failure, disabled. Rule state is disabled, unavailable target/metric, monitoring, pending threshold, active, recovering, cooldown. Errors stay adjacent to the owning control and never include raw API responses containing credentials.

At 720x540 the content uses one column and scrolls. At 900x680 the rule list/editor may use a stable split. Do not nest cards; `SettingsGroup` is an unframed layout primitive.

## Localization/accessibility

Localize all labels, default templates, variable descriptions, metric/unit names, validation text, and state summaries in English and Simplified Chinese. Icon-only row actions have `.help` and accessibility labels. Secure fields announce whether a saved secret exists without reading it.
