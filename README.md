# Broom for macOS

A native macOS junk cleaner built from scratch (Swift + SwiftUI). Scan → review → clean,
with safety as the core design constraint.

> Not affiliated with or endorsed by MacPaw/CleanMyMac, OnyX, DaisyDisk, or CCleaner.
> "Broom" is an original name for this project (PLAN.md §11).

## What it does

- Scans (read-only, parallel): user/browser caches, app & system logs, Trash, Xcode
  junk (DerivedData/Archives/DeviceSupport), Homebrew cache, Mail downloads, iOS device
  backups, leftover files of uninstalled apps, large files, duplicates (SHA-256, local).
- Shows **exactly** what would be removed — path, size, last-modified, risk tier — before
  touching anything.
- Deletes **only to the Trash** (never `rm`/`unlink`), with risk-tiered confirmation
  (high-risk items require typing `DELETE`), per-item undo log, and an in-app
  "Undo last clean".
- Hard denylist: `/System`, `/bin`, `/sbin`, `/usr`, `/Library/Extensions`,
  Desktop/Documents/Pictures/Movies can never be deleted regardless of scanner output.
- Symlink/TOCTOU re-validation immediately before every delete.

See [PLAN.md](PLAN.md) for the full specification,
[docs/SECURITY.md](docs/SECURITY.md) and [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md)
for the safety model.

## Requirements

- macOS 13+ (developed against the macOS 27 / Xcode 27 SDK; Liquid Glass materials are
  used automatically on macOS 26+ with material fallbacks below).
- Xcode 15+ (`xcodegen`, `swiftlint` via Homebrew for the full workflow).

## Build

```sh
# Generate the Xcode project (idempotent)
xcodegen generate

# Build + run all tests (app tests)
xcodebuild -project Broom.xcodeproj -scheme Broom test

# Core package tests only (fast)
cd Core && swift test

# Lint
swiftlint lint

# Run the app
open build/  # or just Cmd+R in Xcode after `xcodegen generate`
```

## Project layout (PLAN.md §2)

```
├── App/            # SwiftUI app target (views, view models, resources)
├── Core/           # Pure-Swift package: Scanning/, Deletion/, RulesEngine/, Diagnostics/
├── AppTests/       # App-target unit tests
├── docs/           # PLAN.md companion living documents
├── project.yml     # xcodegen spec
└── .swiftlint.yml
```

The privileged XPC helper (PLAN.md §6/Phase 6) is intentionally **not** in v1: every v1
feature operates inside user-owned paths. See docs/SECURITY.md.

## Distribution decision

Direct, notarized DMG (Developer ID), **not** the Mac App Store — App Sandbox is
incompatible with whole-disk cleaning (PLAN.md §10).
