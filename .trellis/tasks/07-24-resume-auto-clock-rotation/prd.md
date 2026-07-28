# Resume automatic clock rotation after manual scrolling

## Goal

Keep both menu-bar clock interactions available: users can switch clocks manually with a mouse wheel or two-finger trackpad scroll, and timed automatic rotation continues afterward.

## Background

- The menu-bar clock already supports ordered timed rotation through `AppSettings.statusBarSwitchIntervalSeconds`.
- Before this task, wheel and two-finger trackpad scrolling set a persistent manual clock override in `StatusBarController`, which paused timed rotation until the user selected **Auto Rotate** from the context menu.
- The requested behavior is for manual scrolling and automatic rotation to coexist without requiring a context-menu action to resume rotation.

## Requirements

- Preserve the existing wheel and two-finger trackpad gesture behavior, including direction, thresholds, wrapping, and one switch per precise gesture.
- Treat a clock selected by scrolling as a temporary override that lasts for one complete configured rotation interval from the latest successful scroll switch.
- Resume timed automatic rotation from the gesture-selected clock after the temporary override expires, advancing to the next configured clock without requiring the user to open the context menu.
- Keep the configured clock order and rotation interval authoritative.
- Preserve the existing context-menu behavior: selecting a specific clock there remains a persistent manual override until **Auto Rotate** is selected.
- Update user-facing copy that currently says scrolling pauses rotation until **Auto Rotate** is selected.
- Add focused regression coverage for temporary manual selection and automatic resumption.

## Acceptance Criteria

- [x] A wheel or two-finger trackpad gesture still switches to the adjacent configured clock.
- [x] The clock selected by scrolling remains visible for one complete configured rotation interval, measured from the latest successful scroll switch.
- [x] A later successful scroll switch restarts that temporary interval.
- [x] At the end of the temporary interval, the display advances from the gesture-selected clock to the next configured clock and continues timed rotation from there.
- [x] No **Auto Rotate** context-menu action is required after scrolling.
- [x] Selecting a clock from the context menu still pauses automatic rotation until **Auto Rotate** is selected.
- [x] Existing carousel navigation and clock-rendering tests continue to pass.
- [x] README and in-app carousel guidance describe the new behavior accurately.

## Out of Scope

- Changing gesture direction, thresholds, momentum handling, or animation.
- Adding a new setting for automatic-resume behavior.
- Changing the configured rotation interval options.
- Changing persistent context-menu clock selection behavior.
