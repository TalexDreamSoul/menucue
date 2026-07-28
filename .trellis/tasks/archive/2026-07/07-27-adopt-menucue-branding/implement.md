# Implementation Plan

1. Extend ProductBrand/packaging tests to require the complete MenuCue technical identity and confirm RED.
2. Rename source/test/resource files and directories while preserving the dirty worktree.
3. Replace module names, app/helper identifiers, bundle IDs, preference namespaces, signing requirements, build/update paths, docs, and metadata.
4. Audit all remaining old-name references and fix non-historical matches.
5. Run focused identity tests, full Swift tests, `swift build`, shell syntax checks, app packaging, plist/entitlement/daemon checks, and signing verification.
6. Rename the GitHub repository, update local origin, and verify releases/URLs under the new repository.
7. Produce or defer a valid MenuCue release according to the approved release decision.
8. Rename/update the Homebrew cask, run `brew audit`/`brew style`, install verification where feasible, and push the tap change.
9. Run final repository and external-resource audits and record evidence.

## Validation Commands

```bash
swift test --filter ProductBrandTests
swift test
swift build
bash -n scripts/build-app.sh scripts/build-update.sh
scripts/build-app.sh
codesign --verify --deep --strict .build/app/MenuCue.app
rg -n --hidden -g '!.git/**' -g '!.build/**' -g '!.trellis/**' -g '!.sparkle-local/**' 'TouchMacer|touchmacer|touch-macer' .
brew audit --cask menucue
brew style --cask menucue
```

## Rollback Points

- Local file moves are reversible before any remote operation, but must preserve user edits.
- GitHub repository rename supports redirects, but origin is updated explicitly after verification.
- Homebrew cask is not pushed until a real MenuCue artifact URL and SHA-256 are verified.
