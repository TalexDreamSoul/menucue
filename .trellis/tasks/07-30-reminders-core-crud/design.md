# Design: reminder core CRUD and completion

`ReminderDraft` contains core editable scalars plus baseline identity/revision metadata. It has no writable recurrence/alarm collections.

Edit flow:

`validate -> resolve current writable list -> fetch fresh item by id -> patch only dirty core fields -> save -> re-fetch -> compare -> publish exact observed result`

Save rejection leaves EventKit unchanged. A successful provider-adjusted scalar result is shown as adjusted, not rolled back. Missing ids cancel and refresh.

New items use `EKReminder(eventStore:)` and an explicit writable list. Completion/reopen saves the completion property; undo keeps only transient identity/action state and never reconstructs a missing item. Delete confirms then removes and refreshes.

The editor is a focused sheet with Basics, Schedule, and Details sections. Advanced recurrence/alerts remain summarized read-only and untouched until the sibling task.
