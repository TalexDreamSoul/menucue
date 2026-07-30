# Design

## Navigation

Collapse `SettingsPane.dateAndEvents`, `.menuBarTimeZones`, and `.calendars` into a new `.dateAndTime` case. Rename `.languageAndRegion` to `.language`. No pane selection is persisted, so no stored navigation migration is required. Update all internal deep links to the new cases.

## View Composition

`SettingsContentView` remains the composition owner because it already owns bindings to `AppModel` settings and all three existing setting sections. Build `dateAndTimeSection` by composing existing controls into three titled `SettingsGroup` blocks separated by dividers.

Move the reusable system time-zone editor out of `LanguageRegionSettingsView` into its own view. `Date & Time` embeds it with the existing `PowerHelperManager`. `LanguageRegionSettingsView` becomes `LanguageSettingsView` and retains only app-language and macOS-language controls.

## Data and Compatibility

Do not rename or move fields in `AppSettings`, `SettingsStore`, or `PortableSettingField`. View relocation must continue using the existing mutation boundaries:

- Persisted settings mutate through `AppModel.updateSettings` bindings.
- Calendar runtime state and permissions remain owned by `AppModel` / `CalendarService`.
- The macOS system time zone remains authoritative runtime state owned by `PowerHelperManager`.

## UX Rules

- Use visible section headings rather than nested navigation or hidden tabs.
- Label the system time-zone group as macOS-wide and explain its impact.
- Preserve native SwiftUI controls, density, and existing settings width.
- Keep the page scrollable because calendar and time-zone lists can be long.

## Rollback

The change is view-only. Reverting the pane enum, view composition, and localization changes restores the old information architecture without data migration.
