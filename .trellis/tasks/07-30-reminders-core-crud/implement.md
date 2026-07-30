# Implementation plan: reminder core CRUD and completion

## RED

- [ ] Add draft validation, writable-list, stale-id, dirty-field patch, and observed-result tests.
- [ ] Add create/edit/delete confirmation, complete/reopen, successful undo, missing-item undo, and external-change editor tests.
- [ ] Assert recurrence/alarm setters are never called.

## GREEN

- [ ] Extend injected store with save/remove/fresh-fetch operations and typed results.
- [ ] Add core draft mapper/validator and scalar dirty-field patcher.
- [ ] Build core editor, delete confirmation, completion actions, undo, and failure/adjustment feedback.

## VALIDATE

```bash
swift test --filter ReminderCRUD
swift test --filter ReminderRead
swift test --filter Localization
swift test
swift build
```

Use a disposable reminder list for packaged create/edit/complete/undo/delete smoke tests.
