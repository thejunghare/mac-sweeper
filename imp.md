# Implementation Status — Broom

> Status log for the build described in [PLAN.md](PLAN.md).
> **Last updated: 2026-09-22** — Phases 0–5 complete and verified.

## Decisions made (plan's open questions)

| Question | Decision | Rationale |
|---|---|---|
| App name (§11) | **Broom** | Original; nothing like CleanMyMac/OnyX/DaisyDisk/CCleaner |
| Bundle ID | `app.broom.Broom` | — |
| Distribution (§10) | **Direct / notarized DMG, Developer ID, no App Sandbox** | Plan's own recommendation — App Sandbox is incompatible with whole-disk cleaning |
| Privileged XPC helper (Phase 6) | **Not in v1** | Every v1 feature operates on user-owned paths; system-log delete failures are skipped and reported, never forced (see docs/SECURITY.md) |
| macOS target | 13.0+ (built against macOS 27 SDK) | Liquid Glass APIs auto-used on macOS 26+ with material fallbacks below |

## Phase progress

| Phase | Description | Status |
|---|---|---|
| 0 | Project setup: xcodegen (`project.yml`), SwiftLint (`.swiftlint.yml`, 0 errors), GitHub Actions CI (`.github/workflows/ci.yml`), naming | ✅ |
| 1 | Core scanning engine (no UI) + fixture-based unit tests | ✅ |
| 2 | Safe deletion engine: Trash-only + undo log + symlink/TOCTOU tests | ✅ |
| 3 | SwiftUI review UI: results list, grouping, selection, sizes, progress, confirmation tiers | ✅ |
| 4 | Full Disk Access / TCC handling UX (probe + just-in-time explainer + deep link) | ✅ |
| 5 | Additional scanners: Xcode junk, Homebrew, large files, duplicates, leftover app files, Mail, system logs, iOS backups | ✅ |
| 6 | Privileged helper + XPC hardening | ⏸ deferred — not needed in v1 (documented) |
| 7 | Signing, hardened runtime, notarization pipeline | ⏳ needs Developer ID certificate |
| 8 | Sparkle auto-update (EdDSA) | ⏳ |
| 9 | QA pass: security checklist test plan, XCUITest smoke | ⏳ partial (unit coverage done; UI smoke scaffolded) |
| 10 | Distribution: signed DMG | ⏳ |

## What's in the tree

```
├── App/                     # SwiftUI app target (Broom)
│   ├── BroomApp.swift       # @main, WindowGroup + Settings scene, ⌘R scan shortcut
│   ├── ViewModels/ScanViewModel.swift   # scan/selection/clean/undo state machine
│   ├── Views/               # Welcome, ScanProgress, Review, CleanConfirmationSheet,
│   │                        # CleaningProgress, CleanSummary, Privacy, Settings, ContentView
│   └── Support/GlassEffects.swift       # Liquid Glass (macOS 26+) + material fallback
├── Core/                    # Pure Swift package "CleanerCore" (UI-free, unit-tested)
│   ├── Scanning/            # 12 scanners + ScanEngine (TaskGroup-parallel, cancellable)
│   ├── Deletion/            # SafeDeleter (trashItem only), UndoLog, UndoRestorer
│   ├── RulesEngine/         # per-category allowlist + hard denylist + SymlinkGuard
│   ├── Permissions/         # FullDiskAccess probe + settings deep-link
│   ├── Diagnostics/         # os Logger wrapper, ByteFormat
│   └── Tests/               # 38 unit tests
├── AppTests/                # 3 app-target unit tests
├── docs/SECURITY.md         # living security policy (§5 checklist mapped to code+tests)
├── docs/THREAT_MODEL.md     # assets, trust boundaries, T1–T14 with mitigations
├── project.yml              # xcodegen spec (regenerates Broom.xcodeproj)
├── .swiftlint.yml
├── .github/workflows/ci.yml # Core tests + lint, app build+test lanes
└── README.md
```

## Scanners (12)

| Scanner | Category | Risk | Deletable in-app |
|---|---|---|---|
| `UserCachesScanner` | `~/Library/Caches/*` | low | ✅ |
| `BrowserCachesScanner` | Safari/Chrome/Firefox caches | low | ✅ |
| `AppLogsScanner` | `~/Library/Logs/*` | low | ✅ |
| `TrashScanner` | `~/.Trash` (listing only — never auto-purged) | low | ⛔ skipped by deleter |
| `HomebrewCacheScanner` | Homebrew caches | low | ✅ |
| `XcodeJunkScanner` | DerivedData (low), Archives (medium), DeviceSupport (medium) | var | ✅ |
| `MobileSyncBackupsScanner` | iOS device backups | **high** | ✅ type-DELETE gate |
| `MailDownloadsScanner` | Mail Downloads/Attachments | medium | ✅ |
| `SystemLogsScanner` | `/Library/Logs/DiagnosticReports` | medium | ✅ (failures reported, never forced) |
| `LeftoverAppFilesScanner` | exact bundle-ID orphans in Library | medium | ✅ |
| `LargeFilesScanner` | files over threshold | medium | ✅ user pick only (never preselected) |
| `DuplicatesScanner` | SHA-256 groups (local hashes only) | medium | ✅ user pick only; one copy always kept |
| `DeepestFileFinder` | deepest file under `~` + deletable verdict + removal suggestions | low/medium | ✅ suggestions via Deep Clean (Trash + undo) |

## Safety invariants (§5) — enforced in code, proven by tests

- **Trash, never unlink**: only `FileManager.trashItem`; the Trash is never auto-empted.
  → `testDeletionUsesTrashNotUnlink`, `testTrashCategoryItemsAreNeverAutoPurged`
- **Hard denylist**: `/System`, `/bin`, `/sbin`, `/usr`, `/Library/Extensions`,
  `/private/var/db`, `/Applications`, protected home roots (Desktop/Documents/…) can never
  be deletable regardless of scanner output. → `RulesEngineTests`, `testEngineFiltersDenylistedScannerOutput`
- **Symlink/TOCTOU**: parent chain re-resolved immediately before each delete; escapes
  rejected; scans never follow symlinks. → `SymlinkGuardTests`,
  `testDeleterRefusesItemsEscapingRootViaSymlinkParent`, `testScannersDoNotFollowSymlinkedDirectories`
- **Confirmation tiers**: review screen → one confirm (low/medium) → type `DELETE` (high).
  Informational categories are never selectable.
- **Undo**: append-only `undo_log.json`; restore is byte-identical and refuses to
  overwrite reoccupied paths. → `testDeleteThenUndoRestoresByteIdenticalFile`,
  `testUndoRefusesToOverwriteReoccupiedPath`
- **No shell-outs**: zero `Process`/`rm -rf`/`osascript` usage anywhere.
- **Privacy**: no telemetry, no network I/O in v1; duplicate hashes stay local;
  logs are `privacy: .private`.
- **Trust UX (§5.8)**: factual copy only, no fake system alerts, Cancel always available,
  permanent "What Broom accesses and why" screen.

## Verification (2026-09-22)

```
Core:      swift test              → 38/38 tests, 0 failures
App:       xcodebuild test         → TEST SUCCEEDED (3 tests)
Lint:      swiftlint lint          → 0 errors
Launch:    Debug Broom.app binary  → starts without crash
```

## Next steps

1. **Phase 7**: obtain Developer ID Application cert, enable signing identity in
   `project.yml`/CI secrets, `notarytool` + staple pipeline; verify `spctl -a -vvv`.
2. **Phase 8**: add Sparkle 2 (HTTPS appcast, EdDSA pinned key) for the direct build.
3. **Phase 9**: run the §5 checklist as a literal QA script; add XCUITest smoke
   (scan → review → cancel mid-clean); beta on backed-up machines.
4. **Phase 10**: signed `.dmg` packaging + website/download hosting.
5. Optional: app icon in Icon Composer (layered light/dark/tinted, §12.3) — currently
   uses the default generic icon.
