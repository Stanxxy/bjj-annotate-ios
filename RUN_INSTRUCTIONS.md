# BJJAnnotate — Run Instructions (Phase 0)

These steps walk through everything Stan and the PM need to verify Phase 0 on
device. Simulator builds + tests run in CI / via `xcodebuild`; the on-device
checks below need a paired iPhone 13 and iPad 10th gen with a free Apple Dev
team configured in Xcode.

## 0. Prerequisites

- macOS with Xcode 26.2+ installed.
- XcodeGen: `brew install xcodegen`.
- (For device runs) An Apple ID added under Xcode → Settings → Accounts, with
  a free personal team. iPhone 13 + iPad paired and trusted.

## 1. Generate the Xcode project

```sh
cd bjj-annotate-ios
xcodegen generate
open BJJAnnotate.xcodeproj
```

For the first device run, select the `BJJAnnotate` target → Signing & Capabilities →
choose your personal team. The project is configured with `CODE_SIGN_STYLE = Automatic`
and no hardcoded `DEVELOPMENT_TEAM`, so Xcode's "Automatically manage signing" UI
drives team selection without conflict.

On-device builds via the Xcode IDE require codesigning enabled (the default).
The `CODE_SIGNING_ALLOWED=NO` flag belongs **only** on the simulator-only
`xcodebuild test` command below; it is a CLI-level concern for sandboxed CI
runs and is intentionally **not** baked into `project.yml` / `project.pbxproj`.
Baking it into the project caused iOS to reject the device binary with
`LaunchExecutableValidationErrorDomain` code 1 ("The executable is not
codesigned"), even though the simulator (sandboxed) launched it fine.

## 2. Simulator build + tests

```sh
xcodebuild test \
  -project BJJAnnotate.xcodeproj \
  -scheme BJJAnnotate \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

The `CODE_SIGNING_ALLOWED=NO` override on the CLI keeps the simulator test run
working in sandboxed environments without provisioning profiles. Do **not**
add this flag to device builds.

Expected: `Executed 35 tests, with 0 failures` (BJJAnnotateTests) and
`Executed 4 tests, with 0 failures` (BJJAnnotateUITests).

## 3. Phase 0 PM verification — device-only criteria

These can NOT be validated in the simulator; they appear in the PM verification
plan (`working_log/knowledge-base/scratch/2026-05-25-bjj-annotate-ios-phase-0-acceptance.md`
§Verification Plan).

| AC | What to capture | Tool |
|----|-----------------|------|
| #2 | iPhone 13 cold-launch ≤ 2s | Xcode → Product → Profile → App Launch template |
| #3 | iPad 10th gen launches and renders without overflow | Xcode device-run + manual rotation |
| #12 | 1000-image folder, 10s scroll, ≥ 55 fps mean, < 2% animation hitches | Instruments → Animation Hitches template; record while scrolling |
| #13 | Accessibility Inspector: zero Critical / Serious | Xcode → Open Developer Tool → Accessibility Inspector → Audit |

To prepare the 1000-image fixture for AC #12: drop 1000 small JPEGs into a
folder on iCloud Drive, then open it via the in-app picker. (You can generate
sample JPGs with `for i in {1..1000}; do cp seed.jpg "frame_$(printf %04d $i).jpg"; done`.)

## 4. Known Phase 0 limitations (expected to surface in PM verification)

- **App icon**: Xcode's default empty icon set. Phase 5 ships the real icon.
- **Launch screen**: SwiftUI default (blank). Phase 5 ships the branded launch
  screen.
- **PrivacyInfo.xcprivacy**: deferred to Phase 5 (App Store readiness).
- **Free signing 7-day re-sign**: on-device builds expire every 7 days until
  Stan activates the paid Apple Developer Program (Phase 5 prerequisite).
- **Cells are non-interactive**: PM Designer Resolution #1; navigation to the
  Annotator arrives in Phase 1.

## 5. Reset XCUITest state

The app accepts `--uitest-reset` as a launch argument to allocate a private
`UserDefaults` suite for every UI test run. This is wired automatically in
`BJJAnnotateUITests/SmokeUITests.swift`. To reproduce from Xcode:

1. Edit scheme → Run → Arguments → Arguments Passed On Launch.
2. Add `--uitest-reset`.
3. Run. App boots into the empty state regardless of previously-saved
   bookmarks.

Remove the flag before normal device usage.

### Additional UI-test seed flags (evaluator findings #1 / #2)

These are additive with `--uitest-reset` and pre-populate the in-memory
`BookmarkStore` with one synthesized bookmark so XCUITests can land directly
on a non-empty state without driving `UIDocumentPickerViewController`:

| Flag | Effect |
|------|--------|
| `--uitest-seed-empty-folder` | Creates a fresh tmp directory, saves a bookmark to it. List shows one row; tapping into the grid lands on the empty-folder state. Used by `EmptyGridUITests` and `PopulatedListNoBottomCTAUITests`. |
| `--uitest-seed-missing-bookmark` | Saves a bookmark, then deletes the underlying directory. List renders the locked relocate row. Used by `BookmarkErrorRowUITests`. |

Both seed flags are wired in `BJJAnnotate/App/BJJAnnotateApp.swift` →
`Self.applyUITestSeeds(args:into:)`. They are no-ops outside of UI-test
runs (no production code path references them).

## 6. TDD authoring-order attestation (evaluator finding #8, process)

Phase 0 evaluator finding #8 noted that the first-pass commits bundled tests
and implementations in the same `feat:` commit, so the red-green sequence
could not be audited from `git log`. The fix commits for findings #1–#7
restored the discipline:

- Commit `79ee570 test(phase-0): add failing red tests for evaluator findings 1-7`
  introduces six new test files that reference symbols
  (`BookmarkResolving`, `BookmarkStore.lastError`, `ProjectGridViewModel.displayName`,
  the two seed launch-arg branches) that **do not yet exist**. The commit
  was verified to fail at build time before being landed.
- Subsequent `feat:` / `fix:` commits make the red tests green.

Going forward (Phase 1+), every test commit lands BEFORE the implementation
commit that satisfies it. The evaluator validates by diffing commit order.
