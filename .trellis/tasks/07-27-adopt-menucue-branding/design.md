# Design: Complete MenuCue identity migration

## Identity Map

| Surface | Old | New |
| --- | --- | --- |
| Product/package/app | TouchMacer | MenuCue |
| Main bundle ID | com.touchmacer.clock | com.tagzxia.app.menucue |
| Helper executable/module | TouchMacerHelper | MenuCueHelper |
| Helper protocol module | TouchMacerHelperProtocol | MenuCueHelperProtocol |
| Helper daemon/XPC ID | com.touchmacer.clock.helper | com.tagzxia.app.menucue.helper |
| Repository | TalexDreamSoul/touch-macer | TalexDreamSoul/menucue |
| Homebrew cask | touchmacer | menucue |

## Migration Order

1. Turn technical-identity contract tests red against the current names.
2. Rename local directories/resources/files with filesystem moves that preserve dirty and untracked user work.
3. Update code, package manifests, scripts, identifiers, persistence namespaces, signing checks, docs, and metadata.
4. Run repository audits, tests, debug/release builds, app packaging, plist/entitlement/daemon inspection, and signing verification.
5. After local green, rename the GitHub repository and update origin/release URLs.
6. Publish or select a valid MenuCue release artifact, then rename/update/audit the Homebrew cask and push only the tap change explicitly required for distribution.

## Compatibility

No migration aliases or legacy preference import are required because the user confirmed there are no users. Old bundle IDs, preference keys, Helper registrations, update identities, artifact names, and cask tokens are intentionally abandoned.

## Guardrails

- Do not reset or discard the dirty working tree.
- Do not publish a cask pointing to an archive that still contains `TouchMacer.app`.
- Do not force-push, rewrite history, or alter unrelated GitHub/Homebrew resources.
- Do not publish a release whose source cannot be tied to the intended code state without explicit approval.
