# BJJAnnotate iOS

Native iPad / iPhone app for annotating BJJ frames with COCO Keypoints 1.0
boxes + 17-point poses. Pre-labeled by on-device YOLO26-pose (Phase 3+),
written directly to an iCloud Drive Files folder as `annotations.json`.

## Status

- **Phase 0** (Scaffolding) — in progress on `feature/phase-0-scaffolding`.
- Plan: `../working_log/plans/2026-05-25-bjj-annotate-ios-implementation.md`
  (in the umbrella repo).
- PM acceptance pack + Designer pack + Engineer AIP + task graph: all under
  `../working_log/knowledge-base/scratch/` (umbrella).

## Repository

- Default branch: `develop`
- Remote: `https://github.com/Stanxxy/bjj-annotate-ios`
- Branch model: feature branches off `develop`, named `feature/<name>` or
  `fix/<name>`. PRs target `develop`.

## Generating / opening the project

The Xcode project (`BJJAnnotate.xcodeproj`) is generated from `project.yml`
using [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen        # one-time
xcodegen generate            # regenerates BJJAnnotate.xcodeproj
open BJJAnnotate.xcodeproj
```

Always regenerate after adding / renaming source files. The `.xcodeproj` is
checked in so contributors without XcodeGen can still build, but `project.yml`
is the source of truth.

## Build & test from CLI

```sh
xcodebuild test \
  -project BJJAnnotate.xcodeproj \
  -scheme BJJAnnotate \
  -destination 'platform=iOS Simulator,name=iPad (9th generation),OS=16.0' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

See `RUN_INSTRUCTIONS.md` for on-device signing, performance traces, and
accessibility-audit steps.
