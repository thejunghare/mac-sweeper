# Security Policy & Design — Broom

> Living document (PLAN.md §8/§14). Update this every time a scanner or privileged
> operation is added. Companion document: [THREAT_MODEL.md](THREAT_MODEL.md).

## Scope

Broom is a macOS junk cleaner distributed **outside** the Mac App Store (notarized DMG,
Developer ID — PLAN.md §10). It is therefore **not App Sandboxed** and instead relies on:

1. A strict **allowlist/denylist rules engine** (`Core/Sources/CleanerCore/RulesEngine/`)
   that every deletion candidate must pass — *at scan time and again immediately before
   each delete*.
2. **Trash-only deletion** (`FileManager.trashItem`), never `unlink`/`rm`. The Trash is
   never emptied by the app.
3. **Full Disk Access** as the only TCC permission sought, requested just-in-time with an
   explanation screen (no prompts on first launch).
4. **No network I/O** in v1 other than (future, opt-in) Sparkle update checks. No file
   names, paths, sizes, or contents ever leave the device. Duplicate hashes are computed
   and discarded locally.

## Hard rules (enforced in code + tests)

| Rule | Where enforced | Test |
|---|---|---|
| Never delete outside per-category allowed roots | `RulesEngine.validate` | `RulesEngineTests` |
| Never delete denylisted system paths (`/System`, `/bin`, `/sbin`, `/usr`, `/Library/Extensions`, `/private/var/db`, …) | `RulesEngine.hardDenylist` | `testHardDenylistedSystemPathsAreAlwaysDenied` |
| Never delete the user's Desktop/Documents/Pictures/Movies contents | `RulesEngine.protectedHomeRoots` | `testProtectedHomeRootsNeverDeletable` |
| Never follow symlinks out of a scan root (TOCTOU) | `SymlinkGuard` at delete time | `SymlinkGuardTests`, `testDeleterRefusesItemsEscapingRootViaSymlinkParent` |
| Never auto-purge Trash contents | `SafeDeleter` skips `.trash` category | `testTrashCategoryItemsAreNeverAutoPurged` |
| Informational categories (large files, duplicates) are never deletable | `JunkCategory.isDeletable` + `SafeDeleter` | `testDeleterRefusesInformationalCategories` |
| Never overwrite a reoccupied path during undo | `UndoRestorer` | `testUndoRefusesToOverwriteReoccupiedPath` |
| Scanner bugs cannot surface denylisted paths | `ScanEngine` filters all results through `RulesEngine` | `testEngineFiltersDenylistedScannerOutput` |
| No `rm -rf`, no shell string interpolation | Code contains no `Process` calls | grep in review |
| Storage screen: user-chosen items only, Trash only, flag recomputed from disk at delete time; never system paths, SIP-restricted items, the Trash, Photos/Mail libraries, other apps' containers, or the folders that hold everything (home, Library, Documents, …) | `StorageAnalyzer.flag(for:)` + `StorageDeleter` | `StorageAnalyzerTests` |
| No fake system alerts / scare copy | Copy review in `WelcomeView`, `PrivacyView` | manual QA checklist |

### User-directed deletion (Storage screen)

The rules above govern what *scanners* may propose. The Storage screen is different: the
user picks one item (or "Delete All Safe") themselves, like Finder's Move to Trash, so their
own files and apps under `/Applications` and `~/Documents` can be deleted there. The
safeguards: only one item per click (bulk only for "Safe to delete" items), a confirmation
for anything flagged "Check first", Trash instead of unlink, the flag recomputed by
`StorageDeleter` immediately before each move, `SymlinkGuard`, and Undo.

## Permission model

- **Full Disk Access (TCC)**: detected by probing TCC-gated, user-owned directories
  (`~/Library/Safari`, …) — `Core/Permissions/FullDiskAccess.swift`. The app explains why
  before linking to
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- **No other TCC prompts** are used (no camera, mic, contacts, accessibility, automation).
- **No App Sandbox** (direct distribution decision, PLAN.md §10).

## Privileged helper

**v1 ships no privileged helper.** All v1 features operate on user-owned paths. System
log deletion (`/Library/Logs/DiagnosticReports`) is attempted as the logged-in user; on
permission failure the item is *skipped and reported* — never forced (§5.3 principle:
minimize code running as root). If a future feature truly requires elevation:

- separate, separately-signed binary installed via `SMAppService.daemon` (macOS 13+);
- strict typed XPC protocol — no arbitrary paths/commands;
- helper re-validates every request against the same `RulesEngine` (never trust the client);
- helper verifies the caller's code signature (`SecCodeCheckValidity`) before acting;
- every privileged action appended to a user-inspectable audit log.

## Code signing, hardening, notarization (§5.7)

- Hardened Runtime enabled (`ENABLE_HARDENED_RUNTIME = YES` in `project.yml`).
- Developer ID Application signing; `get-task-allow` off in release.
- Notarize + staple via `notarytool` before distribution; verify with
  `spctl -a -vvv`.
- No third-party dylib loading; Library Validation stays on.

## Update channel (§5.6, Phase 8)

When Sparkle is added: HTTPS-only appcast, EdDSA signatures pinned in the app, unsigned
updates rejected, release notes displayed. Remote "cleanup rules" feeds (if ever added)
must use the same signed+rollback-protected channel **and** remain advisory — the local
allowlist is always authoritative.

## Reporting

Report security issues privately to the maintainers; do not open public issues for
deletion-safety bugs.
