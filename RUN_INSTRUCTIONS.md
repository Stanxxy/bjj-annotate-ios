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

Expected (Phase 0): `Executed 35 tests, with 0 failures` (BJJAnnotateTests) and
`Executed 4 tests, with 0 failures` (BJJAnnotateUITests).

Expected (Phase 1 partial, `feature/phase-1-domain-boxes` through T10):
`Executed 110 tests, with 0 failures` (BJJAnnotateTests). No XCUITest
additions on this branch yet (T13–T24 deliver UI surfaces + their
XCUITest coverage; see Phase 1 task graph).

Expected (Phase 1 partial, `feature/phase-1-domain-boxes` through T13 +
evaluator pre-emptions R-UI-1 / R-UI-2 + LOW #1 / LOW #2 cleanup):
~120 tests, with 0 failures. The dispatch added:
  - `CocoIsDiskTruthTests` (1) — AC #33 byte-equality (LOW #2).
  - `UIDeviceUserInterfaceIdiomBanTests` (1) — R-UI-1 grep gate.
  - `DragStagingContractTests` (1) — R-UI-2 store-side contract.
  - `ProjectFolderUbiquityTests` (3) — T11 ubiquity back-apply.
  - `ProjectListErrorBannerTests` (3) — T12 banner surface.
  - `AnnotatorNavigationContractTests` (3) — T13 navigation destination.

Expected (Phase 1 partial, `feature/phase-1-domain-boxes` through T14–T24):
~170 unit tests + 9 UI tests, 0 failures (code-complete, pending local
`xcodebuild test`). The dispatch added:
  - `AnnotatorCanvasGeometryTests` (8) — T14 zoom clamp, pan, double-tap-to-fit, view-to-image.
  - `ProjectListPickerErrorRoutingTests` (4) + `ProjectListLegacyAlertRemovalTests` (1) — T14 L-3 carry-forward.
  - `BoxIntakeTests` (10) — T15 sub-4px gate + clamp + normalization.
  - `ProjectFolderUbiquityLockHardeningTests` (2) — T15 L-1 carry-forward (os_unfair_lock).
  - `BoxHandleTests` (13) — T16 selection + 8 handles + resize/move.
  - `ClassChipRowTests` (4) — T17 chip dispatch + sticky + Ref auto-bind.
  - `AthletePickerTests` (6) — T18 athlete picker model + 8-cap.
  - `InstanceListModelTests` (4) — T19 instance list rows.
  - `ConflictBannerTests` (5) — T20 conflict banner + diff modal.
  - `LifecycleFlushBridgeTests` (3) — T21 willResignActive flush + L-1 hardening.
  - `AnnotatorImagePresenceTests` (2) — T22 zero-image presence.
  - `MobileFirstAuditUITests` (4) — T23 AC #14 tap targets + overflow.
  - `GoldenPathUITests` (1, 8 assertions) — T24 thumbnail → annotator → back → relaunch.

L-1 hardening applied in T15 (`ProjectFolder.applyUbiquityGate`) and T21
(`LifecycleFlushBridge.flushSynchronously`). L-2 left as a Phase 2
diagnostic marker comment per the carry-forward. L-3 consolidation
landed in T14 — `ProjectListView` no longer keeps a parallel `@State
private var lastError` alert; picker errors route through
`bookmarkStore.lastError` (`.pickerFailed` case) and surface via the
same `safeAreaInset` banner.

Expected (Phase 1 complete — I1-I4 integration, `feature/phase-1-domain-boxes`):
~180 unit tests + 9 UI tests, 0 failures. The integration dispatch added:
  - `AnnotatorViewLifecycleTests` (5) — I1 red tests for AnnotatorLifecycleContext.
  - `ProjectLevelConflictTests` (3) — I3 red tests for ProjectAnnotationConflictWatcher.
  - `GoldenPathDiskRoundtripTests` (2) — I4 two-phase disk roundtrip (write+flush, rebuild+reload).

Red test commit `fb21d34` is parent of feat commit `771f530` (Marker G).

Integration changes:
  - `AnnotatorLifecycleContext` (I1): per-project store+coordinator factory. `make(folderURL:imageURL:ubiquity:)` async throws. Bootstrap on first open (3 BJJ COCO categories). `imageId` from sorted `scanImages` position (1-based). Decode failure sets `store.lastError` then continues with bootstrap.
  - `ProjectAnnotationConflictWatcher` (I3): `@Observable @MainActor` project-level conflict watcher. `receive(conflictEvent:)` / `inject(_:)` for test injection. `bannerMessage` uses `LockedCopy.conflictBanner`. `dismiss()` clears conflict.
  - `AnnotatorView` (I2): owns per-project lifecycle via `@State context: AnnotatorLifecycleContext`. `.task` loads context. Back button: `LifecycleFlushBridge.flushSynchronously`. `AdaptiveInstanceListModifier`: uses `Layout.AdaptiveAnchor(compact: { ... }, regular: { ... })` to branch — compact → bottom `.sheet`, regular → right rail `HStack`. `Layout.AdaptiveAnchor` reads `@Environment(\.horizontalSizeClass)` (R-UI-1 compliant, no `UIDevice.userInterfaceIdiom`). `onDelete` wired through both branches. Flag button uses `store.toggleFlag()`. `.onChange(of: store.lastConflict)` mirrors upward to `conflictWatcher`.
  - `ProjectGridView` (I3): `gridConflictBanner` via `.safeAreaInset(edge: .top)` for AC #34.
  - `RootView.NavigationDestination.annotator`: +`folderURL` param.
  - `AnnotationStore.toggleFlag()` (AC #4 single-setter pattern).
  - `ImageStateTracker.toggleFlag(in:imageId:)` static variant + `nowISO8601()` visibility.
  - `InstanceList.onDelete`: swipe-to-delete destructive action.
  - `ProjectGridViewModel.folderURL`: exposes project folder URL for navigation.

Trap #1 verified: `CODE_SIGNING_ALLOWED`=0, `DEVELOPMENT_TEAM`=0 in pbxproj.
Trap #2: pbxproj diff (5 new files, 10 UUIDs) in same commit as source files.

Simulator destination on this machine uses `iPhone 16e,OS=26.2`; iPhone
16 with OS 26.2 is not provisioned in the local simulator runtime.

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

## 7. Phase 1 progress — `feature/phase-1-domain-boxes` (in flight)

Domain + persistence layers landed (T1–T10). UI surfaces (T13–T24) are
pending; the engineer skill checkpointed mid-task-graph to hand back to
the evaluator after the architecturally-load-bearing pieces.

| Task | Status | Tests |
|------|--------|-------|
| T1 LockedCopy (11 strings) | Done | Phase1LockedCopyTests + LockedCopyGrepTests |
| T2 JSONValue | Done | JSONValueTests |
| T3 CocoModel + fixture | Done | CocoModelTests |
| T4 AthletePalette + AthleteRegistry | Done | AthletePaletteTests + AthletePaletteGrepTests + AthleteRegistryTests |
| T5 AnnotationStore | Done | AnnotationStoreTests + DomainSingleSourceGrepTests |
| T6 ImageStateTracker | Done | ImageStateTrackerTests |
| T7 UbiquityResolver + Fake | Done | UbiquityResolverFakeTests |
| T8 + T9 CocoFileCoordinator | Done | CocoFileCoordinatorTests + UbiquityTests + ProductionSourceGrepTests + DebounceImplementationGrepTests |
| T10 ConflictSidecar | Done | CocoFileCoordinatorConflictTests |
| T11 ProjectFolder ubiquity back-apply | Pending | — |
| T12 lastError banner wiring | Pending | — |
| T13–T24 UI + golden-path | Pending | — |

All Phase 0 tests still pass (35 of the 110 are Phase 0). Grep gates in
place: 11 PM-locked strings centralised in `LockedCopy.swift`, 8 palette
hexes centralised in `AthletePalette.swift`, zero `try?` in production
`CocoFileCoordinator.swift` / `AnnotationStore.swift`, zero
`DispatchQueue.asyncAfter` in the debounce path. After every
`xcodegen generate` the `CODE_SIGNING_ALLOWED` + `DEVELOPMENT_TEAM`
greps return 0 (Phase 0 trap #1 not re-triggered).

## 8. Known Limitations (Phase 1)

These limitations are **accepted Phase 1 deferrals** — they are by design and will be
closed in Phase 2. They are disclosed here so the PM can make an informed acceptance call.

### Conflict banner forwarding during an active annotator session

**What works:** Data-safety is live. When a two-device iCloud edit is detected on
`CocoFileCoordinator.persist()`, the loser's bytes are preserved verbatim in
`annotations.conflict-<ISO8601>.json` (AC #34 / AC #36). `AnnotationStore.lastConflict`
is set, causing the `ConflictBanner` in `AnnotatorView` to appear. The end-to-end path
(coordinator → sidecar on disk → `lastConflict` set → banner shown) is covered by
`ConflictWireEndToEndTests`.

**What is deferred (Phase 2):** The `ProjectGridView` conflict banner (`gridConflictBanner`)
is driven by `ProjectAnnotationConflictWatcher`. This watcher is instantiated in `RootView`
and passed into `ProjectGridView`. However, when the user has the `AnnotatorView` open
(NavigationStack child), the `AnnotatorView`'s `onChange(of: store.lastConflict)` can only
forward to the watcher it received at push-time. If a conflict fires while the annotator
is open, the `AnnotatorView`-internal `ConflictBanner` fires correctly, but the
`ProjectGridView` banner (the NavigationStack sibling) does **not** update until the user
navigates back and the grid re-renders against the watcher's updated state.

**Phase 2 fix:** Inject `ProjectAnnotationConflictWatcher` as a shared `@Observable`
environment object so all NavigationStack children can observe it in real time without
requiring back-navigation.

**Risk to user:** No data loss. The conflict sidecar is already on disk; the user sees the
banner on the next grid visit. Acceptable for Phase 1 (single-device testing scenario).

### imageId not-found now throws (behaviour change from prior code)

Previously `AnnotatorLifecycleContext.imageId(for:in:)` silently returned `1` when the
image was not found in the folder scan. It now **throws** `AnnotatorLifecycleError.imageNotFoundInFolder`,
which causes `make()` to throw and `AnnotatorView.loadContext()` to log a warning and show
the loading/error state. The annotator will not open if the imageURL passed from the grid
is not found in the sorted folder scan. This is the correct safe behaviour (M3 fix); any
regression here indicates the grid passed a stale or mismatched URL.

### Decode failure is now read-only (behaviour change from prior code)

Previously `AnnotatorLifecycleContext.make()` on a corrupt `annotations.json` returned a
writable bootstrap store that would clobber the corrupt file on the first mutation. It now
returns a **read-only** error-state store backed by `NullWriteScheduler`. The `lastError`
banner is shown; mutations are silently dropped. The corrupt file is preserved on disk for
external recovery (Files.app, iCloud version history). Phase 2 may add a user-visible
"recover from backup" flow.
