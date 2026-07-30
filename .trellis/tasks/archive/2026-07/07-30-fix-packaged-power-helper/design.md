# Design

The failure had three independent bundle/runtime causes:

1. The managed daemon was packaged under `Contents/Library/HelperTools`, so `SMAppService.daemon` returned `.notFound` despite the files and signatures being present.
2. After moving the Helper, its client-verification code still walked the old directory depth and could not find the main executable.
3. The raw Helper carried `com.apple.developer.service-management.managed-by-main-app` without a matching Helper provisioning profile, so AMFI rejected launch even though codesign and notarization passed.

The corrected contract is:

- `MenuCue` and `MenuCueHelper` are sibling Mach-O executables under `Contents/MacOS`.
- The daemon plist remains in `Contents/Library/LaunchDaemons`, with `BundleProgram=Contents/MacOS/MenuCueHelper` and `AssociatedBundleIdentifiers=[com.tagzxia.app.menucue]`.
- The Helper uses `_NSGetExecutablePath` rather than `argv[0]`, because launchd may supply a relative program argument.
- The Helper is Developer ID signed with hardened runtime but no unprovisioned restricted entitlement.
- `build-update.sh` parses the packaged plist, resolves and verifies that exact Helper, and rejects the invalid entitlement.

The XPC identifiers, protocol, client designated-requirement check, Team ID validation, persistence keys, and protected operations remain unchanged.
