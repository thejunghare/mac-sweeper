# Mac Cleaner App — Full Build Plan

A native macOS application (Swift + SwiftUI/AppKit) that finds and safely removes junk, cache,
log, and leftover files to free up disk space — similar in spirit to CleanMyMac/OnyX/DaisyDisk,
but built from scratch by you.

> ⚠️ **Naming note**: Do not name or brand the app "CleanMyMac" (or anything confusingly similar)
> — that's a registered trademark of MacPaw. Pick an original name early (see §11).

---

## 1. Goals & Non-Goals

**Goals**
- Scan the filesystem for reclaimable space: caches, logs, temp files, old backups, trash,
  broken login items, leftover app files, large/old files, duplicates.
- Show the user exactly what will be deleted, with size and last-modified info, before touching
  anything.
- Delete safely (Trash by default, not `unlink`), reversibly where possible.
- Be fast (parallel scanning), low memory footprint, native look & feel (SwiftUI + AppKit).
- Be honest and transparent about what it touches — this is a trust-critical category of app.

**Non-goals (v1)**
- No "one-click magic fix" that silently deletes things without a review step.
- No system "optimization" claims that aren't measurable (registry-cleaner-style snake oil).
- No kernel extensions. No disk defragmentation gimmicks (APFS doesn't need it).
- No bundling of unrelated "VPN"/"antivirus" upsells.

---

## 2. Tech Stack

| Layer | Choice | Why |
|---|---|---|
| UI | **SwiftUI** (macOS 13+ target), AppKit interop where needed (NSOpenPanel, NSWorkspace) | Native look, modern, less boilerplate |
| Language | **Swift 5.10+** | Native, safe, first-class Apple API access |
| Concurrency | Swift `async/await`, `TaskGroup` for parallel directory scans | Structured concurrency, cancellable scans |
| File system access | `FileManager`, `URLResourceValues` (for size/dates without full stat cost) | Efficient metadata reads |
| Privileged operations | Separate **XPC helper tool** installed via `SMAppService` (or `SMJobBless` if targeting <13) | Keep the main app unprivileged; isolate risk |
| Persistence | `UserDefaults` + a small on-disk JSON/SQLite "scan history / undo log" | Needed for the safety/undo model (§6) |
| Auto-update (if distributed outside MAS) | **Sparkle** framework with EdDSA-signed appcast | Industry-standard, secure update channel |
| Packaging | Xcode project, notarized `.app` in a signed `.dmg`, and optionally a Mac App Store target | Two distribution paths, see §11 |
| Testing | XCTest (unit) + XCUITest (UI smoke tests) + a synthetic "junk fixture" test volume | See §10 |

Project structure to create in Xcode:

```
CleanerApp/
├── App/                     # SwiftUI app target
│   ├── CleanerApp.swift     # @main entry
│   ├── Views/
│   ├── ViewModels/
│   ├── Models/
│   └── Resources/           # Assets, Localizable.strings
├── Core/                    # Pure Swift package (no UI), reusable + unit-testable
│   ├── Scanning/            # Scanners per category (see §4)
│   ├── Deletion/            # Safe-delete engine, Trash wrapper, undo log
│   ├── RulesEngine/         # Path allow/deny lists, safety checks
│   └── Diagnostics/         # Logging (os_log), crash-safe reporting
├── HelperTool/               # Privileged XPC helper (separate target + separate bundle id)
│   ├── HelperProtocol.swift  # Shared XPC interface (also imported by App)
│   ├── HelperTool.swift
│   └── main.swift
├── CleanerAppTests/
├── CleanerAppUITests/
└── docs/
    ├── PLAN.md               # this file
    ├── SECURITY.md
    └── THREAT_MODEL.md
```

---

## 3. High-Level Architecture

```
┌─────────────────────────────┐
│         SwiftUI App          │  ← runs as normal user, App Sandbox where possible
│  (unprivileged, main bundle)│
└───────────┬──────────────────┘
            │ async calls into Core/ (in-process, same privilege)
            ▼
┌─────────────────────────────┐
│   Core (Scanning/Deletion)   │  ← works entirely within the user's own
│                               │    home directory / user-writable caches
└───────────┬──────────────────┘
            │ XPC (only for the few things that truly need elevation,
            │      e.g. system-level cache dirs owned by root)
            ▼
┌─────────────────────────────┐
│   Privileged Helper (XPC)    │  ← separate signed binary, minimal surface,
│   installed via SMAppService │    validates every request against an
└─────────────────────────────┘    allowlist before acting
```

**Key design principle:** the vast majority of "junk" lives in paths the *logged-in user already
owns* (`~/Library/Caches`, `~/Library/Logs`, `~/.Trash`, `~/Downloads`, app support leftovers).
Those never need root. Only a small, explicit set of system-level items (e.g. some
`/Library/Caches` entries, old system logs) need elevation — and for those, prefer prompting the
user via `NSWorkspace`/Finder-level "Move to Trash" (which triggers the normal authorization UI)
over holding your own root helper whenever possible. Minimize how much code ever runs as root.

---

## 4. Features / Scan Categories (v1 scope)

| Category | Example paths | Risk level |
|---|---|---|
| User caches | `~/Library/Caches/*` | Low — regenerated automatically |
| App logs | `~/Library/Logs/*` | Low |
| Trash | `~/.Trash` | Low (user already deleted it) |
| Browser caches | Safari/Chrome/Firefox cache dirs | Low |
| Xcode junk | `DerivedData`, `Archives` (ask first), device support, simulators | Medium |
| Homebrew cache | `~/Library/Caches/Homebrew` | Low |
| Old iOS device backups | `~/Library/Application Support/MobileSync/Backup` | **High — confirm explicitly** |
| Mail downloads/attachments cache | `~/Library/Containers/com.apple.mail/...` | Medium |
| Language files (localizations you don't use) | inside `.app` bundles | Medium — modifies app bundles, riskier, consider skipping in v1 |
| Leftover app files after uninstall | Support/Preferences/Caches with no owning `.app` | Medium |
| Large files finder | user-wide scan, sortable by size | Informational only, user deletes manually |
| Duplicate file finder | hash-based | Informational only, user deletes manually |
| System logs / diagnostic reports | `/Library/Logs/DiagnosticReports` | Medium — may need elevation |
| Memory "purge" / RAM tool | `purge` equivalent | **Cut from v1** — marginal benefit on modern macOS, often misleading |

Explicitly **out of scope / do not implement**: registry-style "system optimizers", disabling
SIP, modifying `/System`, anything touching `/private/var/db` internals, deleting inside other
users' home directories.

---

## 5. Security Concerns — Full Checklist

This is the most important section. A cleaner app is inherently dangerous software: its entire
job is deleting files, and a bug or bad heuristic can destroy user data or break the OS. Treat
every item below as a hard requirement, not a nice-to-have.

### 5.1 Permission model
- **Full Disk Access (TCC)**: macOS will block reads/deletes in many `~/Library` subfolders,
  Mail, Messages, Time Machine snapshots, etc. without the user granting **Full Disk Access** in
  System Settings → Privacy & Security. Detect this gracefully, explain *why* you need it before
  prompting (don't just crash on `EPERM`), and deep-link the user to the right settings pane via
  `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- **App Sandbox**: if you go Mac App Store, App Sandbox is mandatory and it **fundamentally
  restricts** what you can scan (no arbitrary `~/Library/Caches` access without user-picked
  bookmarks). Decide sandboxed-vs-not *before* writing scanning code — it changes the
  architecture (see §11).
- **Principle of least privilege**: request only the entitlements/permissions actually needed for
  each feature; don't ask for Full Disk Access on first launch before the user has even chosen
  what to scan.

### 5.2 Deletion safety
- **Default to Trash, never `unlink`/`rm`.** Use `FileManager.trashItem(at:resultingItemURL:)` so
  everything is recoverable from the Trash until emptied.
- **Never delete without an explicit review screen.** Show category → file list → sizes → an
  explicit "Clean" button. No "auto-clean on launch."
- **Confirmation tiers**: low-risk categories (caches/logs) can be one confirmation; high-risk
  categories (iOS backups, whole app uninstalls) need a second, more explicit confirmation
  ("Type DELETE to confirm" or similar) with the full path list visible.
- **Dry-run / "what would be deleted" mode** as the default first pass; user opts into deletion.
- **Undo log**: before deleting, write a manifest (JSON) of original paths + Trash destination
  URLs, so you can offer an in-app "Undo last clean" even after Trash-relocation, for at least one
  session.
- **Never follow symlinks outside the scanned root** (TOCTOU / symlink-attack protection) — when
  resolving a path for deletion, re-verify with `URLResourceValues.isSymbolicLink` and refuse to
  traverse links that point outside the expected sandboxed subtree.
- **Skip files currently open/in use** where detectable (best-effort via `lsof`-style checks is
  unreliable — prefer relying on the OS: if delete fails because a file is busy, skip and report,
  don't force).
- **Path allowlist + denylist engine** (`Core/RulesEngine`): every deletion candidate must match
  a category's explicit glob/prefix rule. Maintain a hard denylist that can never be deleted
  regardless of what a scanner returns: `/System`, `/bin`, `/sbin`, `/usr` (except `/usr/local`
  cautiously), `/Library/Extensions`, anything under active code-signing/SIP protection, the
  user's Desktop/Documents/Pictures/Movies root contents (only specific known-junk subpaths
  inside them, never a blanket sweep).
- **Respect SIP** — don't attempt to work around System Integrity Protection; if a path is
  SIP-protected, the OS will refuse the delete anyway, but don't build UI that implies you *can*
  override it.
- **Minimum free-space / safety margin check** before large operations — warn if deleting would
  leave the disk nearly full is irrelevant, but *do* warn before deleting multi-GB items like full
  device backups.

### 5.3 Privileged helper (only if you build one)
- Ship it as a separate, separately-signed executable, installed via `SMAppService.daemon` (macOS
  13+) rather than the deprecated `AuthorizationExecuteWithPrivileges`/`SMJobBless` where
  possible.
- Communicate over **XPC only**, with `NSXPCConnection` and a strict, typed protocol
  (`HelperProtocol`) — never accept arbitrary shell commands or file paths without validating them
  server-side against the same allow/deny rules as the app (never trust the client, even though
  it's your own app — validate as if it weren't).
- Verify the calling app's code signature inside the helper (`SecCodeCheckValidity` /
  `csops`) before honoring requests, to prevent another process from hijacking the XPC service.
- Keep the helper's own entitlements minimal; it should not itself be sandbox-exempt more than
  strictly necessary.
- Log every privileged action to a local audit log the user can inspect.

### 5.4 Injection / execution safety
- **No shelling out to `rm -rf` with string-interpolated paths.** If you must call `Process`,
  build argument arrays (never a single shell string), and validate paths are absolute, contain
  no `..` traversal, and lie under an expected root before use.
- Avoid `NSAppleScript`/`osascript` for filesystem operations; if used for anything (e.g. querying
  Mail), sanitize all interpolated values.
- No `eval`-like dynamic code loading of remote config that decides what to delete — if you ever
  ship "delete rules" as remote JSON (e.g. to add new app-support cleanup rules over time), that
  channel must be **signed and pinned** (see 5.6) so it can't become a remote-delete oracle.

### 5.5 Data privacy / telemetry
- Don't scan or transmit file *contents*, filenames, or paths off-device. If you add crash
  reporting/analytics, make it strictly opt-in, aggregate, and documented in a privacy policy.
- If duplicate-finder hashing is implemented, hashes stay local; never uploaded.
- No silent background scanning/phone-home. Any network call (e.g. update check) should be
  user-visible in the UI (e.g. "Checking for updates...") and documented.

### 5.6 Update channel security
- If distributing outside the Mac App Store, use **Sparkle** with:
  - HTTPS-only appcast URL,
  - **EdDSA signature verification** on every downloaded update (Sparkle 2.x default),
  - pin the public key in the app, never accept unsigned updates,
  - display release notes so users know what changed.
- If any "cleanup rules" are fetched remotely (optional future feature), treat that feed exactly
  like an update channel: HTTPS + signature-verified, with the app refusing to act on unsigned or
  stale (rollback-attack) payloads.

### 5.7 Code signing, hardening, notarization
- Enable **Hardened Runtime** on the app and helper.
- Sign with a **Developer ID Application** certificate (or Mac App Store cert if going that
  route); disable unnecessary entitlements (`com.apple.security.get-task-allow` must be off in
  release builds).
- **Notarize** every release build via `notarytool` and staple the ticket before distribution.
- Turn on **Library Validation** and avoid loading unsigned/third-party dylibs.
- Add entitlements only as needed, e.g. avoid `com.apple.security.cs.disable-library-validation`
  unless there's a concrete, justified reason.

### 5.8 Abuse-resistance / trust UX
- Never present a modal that looks like a fake "system alert" to pressure the user ("Your Mac is
  infected!") — this is the exact dark pattern that gives the whole cleaner-app category a bad
  reputation. Keep language factual ("2.3 GB of cache files found").
- Make "Quit" and "Cancel" always available during a scan or clean; never trap the user in a flow.
- Provide a visible, permanent "What does this app access and why" screen (maps directly to
  §5.1/5.5) — this builds trust and doubles as your privacy policy content.

---

## 6. Deletion / Undo Engine (design detail)

1. **Scan phase** (read-only): each scanner returns `[JunkItem]` (path, size, category, riskLevel,
   lastAccessed). No mutation.
2. **Review phase**: UI groups by category, lets user deselect individual items, shows running
   total size to be freed.
3. **Confirm phase**: risk-tiered confirmation (see 5.2).
4. **Delete phase**:
   - For each selected item, call `FileManager.trashItem` (or the XPC helper equivalent for
     root-owned paths).
   - Record `{originalPath, trashedURL, timestamp, category}` into an append-only
     `undo_log.json` in Application Support.
   - Stream progress back to the UI (item-by-item), so it's cancellable mid-run.
5. **Post-clean**: show summary ("Freed 4.2 GB"), offer "Undo" for the duration of the session
   (restores from `trashedURL` back to `originalPath` if still present in Trash).
6. **Trash emptying** is a *separate, explicit* user action — never auto-empty the Trash.

---

## 7. Threat Model Summary (put full version in `docs/THREAT_MODEL.md`)

| Threat | Mitigation |
|---|---|
| App deletes a file still needed by the OS/another app | Allowlist-only deletion, Trash not unlink, deny-list for system paths |
| Symlink/TOCTOU tricks a scan into deleting outside target dir | Re-resolve + validate real path immediately before each delete |
| Malicious/compromised update replaces app with malware | Sparkle EdDSA signing + notarization + pinned key |
| Another local process impersonates the app to the XPC helper | Helper verifies caller code signature over XPC |
| Remote "cleanup rules" feed used to smuggle a delete-anything payload | Signed feed, local allowlist still authoritative regardless of remote input |
| User tricked into granting more access than needed | Clear, honest just-in-time permission prompts explaining each request |
| Data exfiltration via telemetry | No content/path telemetry; opt-in only, documented |

---

## 8. Development Phases

1. **Phase 0 — Project setup**: Xcode project, package structure from §2, CI (GitHub Actions:
   build + unit tests + swiftlint), app icon/name decided (§11 naming note).
2. **Phase 1 — Core scanning engine** (no UI): implement scanners for caches/logs/trash first,
   with unit tests against a fixture directory tree (never touch a real home dir in tests).
3. **Phase 2 — Safe deletion engine**: Trash-based delete + undo log, fully unit tested including
   symlink-escape and denylist tests.
4. **Phase 3 — SwiftUI review UI**: scan results list, category grouping, selection, sizes,
   progress, permission-explainer screens.
5. **Phase 4 — Full Disk Access / TCC handling UX**.
6. **Phase 5 — Additional scanners**: Xcode junk, Homebrew, large files, duplicates, leftover
   app files, uninstaller.
7. **Phase 6 — Privileged helper** (only if a feature truly needs it) + XPC hardening.
8. **Phase 7 — Signing, hardened runtime, notarization pipeline**.
9. **Phase 8 — Optional Sparkle auto-update** (only for the non-MAS distribution build).
10. **Phase 9 — QA pass**: run full security checklist (§5) as a literal test plan before any
    public release; beta test with real (but backed-up) machines.
11. **Phase 10 — Distribution** (§11).

---

## 9. Testing Strategy

- **Unit tests** for every scanner against synthetic fixture trees (create temp dirs with known
  files, assert exactly the expected junk set is found — no false positives on "real" files).
- **Unit tests** for the rules engine: assert denylisted paths are *never* returned as deletable
  even if a scanner bug tries to include them (defense in depth — test the safety net itself).
- **Symlink escape tests**: construct a symlink pointing outside the scan root and assert it's
  rejected.
- **Undo tests**: delete → undo → assert file restored byte-identical at original path.
- **XCUITest smoke tests**: scan → review → cancel-mid-clean → app remains stable.
- **Manual QA checklist** before each release, mirroring §5 (permissions prompt correctly, Trash
  used not unlink, notarization ticket validates with `spctl -a -vvv`, Sparkle signature check
  rejects a tampered appcast in a manual test).

---

## 10. Distribution Decision (needs your input before Phase 0 in earnest)

| Option | Pros | Cons |
|---|---|---|
| **Direct download (notarized DMG, Developer ID)** | Full filesystem access model above works as designed; can request Full Disk Access freely; Sparkle auto-update | You handle notarization, hosting, update infra yourself; users must approve Gatekeeper once |
| **Mac App Store** | Discoverability, trust, built-in updates | **App Sandbox is mandatory** — most cache/log paths outside the sandbox container need user-driven security-scoped bookmarks (user must pick folders via `NSOpenPanel` each time, no blanket Full Disk Access) — this changes nearly every scanner's design and rules out some features (e.g. cleaning other apps' caches) entirely |

Recommendation: **build for direct/notarized distribution first** (matches how every real
competitor in this category ships, precisely because sandboxing is incompatible with whole-disk
cleaning), and reconsider a heavily-scoped-down MAS build later if desired.

---

## 11. Legal / Naming

- Pick a distinct app name + icon (avoid "CleanMyMac", "OnyX", "DaisyDisk", "CCleaner" etc.).
- Add a clear in-app disclaimer: no warranty, user reviews before delete, links to your privacy
  policy and (if open-source) license.
- If you accept payment (paid app / IAP), ensure App Store Review Guidelines §2.3 (accurate
  metadata) and §3.1 are followed — don't claim unverifiable performance improvements ("Mac runs
  50% faster") without evidence.

---

## 12. Design & Visual Aesthetics — macOS 26/27 ("Liquid Glass") Design Language

The app should look and feel like a first-party macOS app on the **current and next** system
design language (macOS 26 "Tahoe" and its macOS 27 successor), not a dated skin. Target Apple's
current Human Interface Guidelines rather than freezing on an older macOS look.

### 12.1 Materials & surfaces
- Use **Liquid Glass** materials (`.glassEffect()` / `NSGlassEffectView` and system materials via
  `NSVisualEffectView` / SwiftUI `.background(.regularMaterial)` etc.) for sidebars, toolbars,
  inspector panels, and the scan-review sheet — not flat, opaque panels.
- Respect **vibrancy** and let content tint the glass appropriately (e.g. risk-tier colors in
  §5.2 showing through translucent chrome, not painted as solid blocks).
- Support the system's **light, dark, and tinted/clear** appearance modes automatically — never
  hardcode colors; use semantic `Color` / `NSColor` system colors so the app re-tints correctly
  when the user changes accent color or appearance.

### 12.2 Layout & chrome
- Standard **sidebar + detail** window layout (`NavigationSplitView`) matching Finder/System
  Settings: categories (Caches, Logs, Trash, Xcode Junk, …) in the sidebar, scan results + review
  list in the detail pane.
- Modern **toolbar** with SF Symbols-only or symbol+label buttons, a search field where relevant,
  and window title that participates in the unified toolbar (no legacy title-bar-and-toolbar
  separation).
- Adopt the current **concentric corner-radius** convention (controls' corner radii nest cleanly
  inside their container's, matching the system's rounded-rect language) — avoid mismatched or
  overly sharp corners on custom cards/rows.
- Use `Settings` scene (`⌘,`) for preferences, following the current tabbed/segmented Settings
  window style rather than a custom modal.

### 12.3 Iconography & typography
- App icon built with **Icon Composer** (layered, supports light/dark/tinted/clear rendering
  modes), not a single flat PNG — required to look correct in macOS 26+'s adaptive icon system.
- **SF Symbols** (latest version available in the target SDK) for all in-app iconography, using
  variable-color / multicolor rendering where it communicates state (e.g. category icons that tint
  by risk level).
- **SF Pro** system typography via Dynamic Type-aware `Font` text styles (`.title`, `.body`,
  `.caption`, etc.) — no custom fonts, no hardcoded point sizes for primary UI text.

### 12.4 Motion & feedback
- Spring-based, system-standard animations (`Animation.spring(...)` defaults) for
  scan-progress, list insertion/removal, and sheet presentation — avoid custom easing curves that
  feel "off-platform."
- Respect **Reduce Motion** and **Reduce Transparency** accessibility settings — provide opaque,
  static fallbacks for the glass materials in 12.1 when either is enabled.
- Haptic-adjacent feedback where appropriate on trackpad-equipped Macs (e.g. subtle feedback on
  destructive confirmation), and standard system sounds for completion/error, not custom SFX.

### 12.5 Accessibility & polish baseline
- Full VoiceOver labeling for every scan row, category, and action button (this is a
  delete-capable app — accessibility here is also a safety feature, not just compliance).
- Full keyboard navigation (list selection, review, and clean actions all reachable without a
  mouse).
- Support **Increase Contrast** and system accent-color changes without a rebuild.

This section should be revisited each time Apple ships a new major macOS release, since the
underlying materials/APIs (Liquid Glass, Icon Composer, etc.) are actively evolving — treat 12.1–
12.5 as "match current HIG," not a frozen spec.

---

## 13. Containerization (Docker) — Applicability Note

This app is a **native macOS GUI application** (SwiftUI/AppKit, per §2). Docker does **not** apply
to building, packaging, or distributing the app itself, and the app will **not** be dockerized:

- Docker containers on Linux (and the Linux VM that Docker Desktop for Mac runs under) have no
  WindowServer, no AppKit/SwiftUI runtime, and no Aqua — there is no way to run or render a macOS
  `.app` bundle's UI inside a container.
- Apple's licensing and the lack of a macOS base image mean there's no legitimate way to run
  full macOS-the-OS in a standard Docker container either (unlike, say, a Linux server app).
- The actual build/sign/notarize/package pipeline (§8 Phase 7, §11 Distribution) must run on
  real or virtualized **macOS** (local Xcode, or macOS-based CI runners like GitHub Actions'
  `macos-latest`), not in a Docker container.

**Where Docker would be legitimate but is out of scope for v1**: purely headless, non-GUI pieces
that don't touch AppKit/SwiftUI — e.g. running `swiftlint`/unit tests for the platform-agnostic
parts of `Core/` in a Linux Swift container as one extra CI lane, or dockerizing an unrelated
future companion service (e.g. a web-based update/appcast host). None of that is part of this
project's current scope; noted here only so the limitation is explicit and isn't revisited later
as an open question.

---

## 14. Immediate Next Steps

1. Confirm distribution path (§11) — this decides sandbox-or-not before any code is written.
2. `xcodegen`/Xcode: create the project skeleton matching §2's folder layout.
3. Implement Phase 1 (cache/log/trash scanners) + their unit tests first — this validates the
   whole safety model early, before any UI exists.
4. Write `docs/THREAT_MODEL.md` and `docs/SECURITY.md` as living documents, updated every time a
   new scanner or privileged operation is added.
