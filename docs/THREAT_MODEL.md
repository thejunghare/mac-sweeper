# Threat Model — Broom

> Living document (PLAN.md §7/§14). Update whenever a scanner, permission, or privileged
> operation is added. Companion: [SECURITY.md](SECURITY.md).

## Assets

| Asset | Why it matters |
|---|---|
| User files (documents, photos, backups) | Irreplaceable data; the app's core risk is deleting them |
| iOS device backups (`MobileSync/Backup`) | Often the only copy of phone data |
| OS integrity (`/System`, `/usr`, SIP-protected paths) | Broken system = unbootable/unusable Mac |
| App integrity (signed binary, update channel) | A compromised cleaner is a mass-delete tool |
| User privacy (file names/paths/hashes) | Sensitive metadata; leak = surveillance surface |
| XPC helper surface (future) | Root-level attack vector if built carelessly |

## Trust boundaries

1. **Filesystem → App**: scanners read attacker-influencable directory structures
   (symlinks, hardlinks, deep nesting, race swaps).
2. **App → Filesystem (write)**: deletion/recovery operations.
3. **Remote → App**: update appcast (Phase 8); optional future rules feed.
4. **Other local processes → Helper (future)**: XPC requests must be authenticated.
5. **UI → Engine**: confirmations are only as good as the risk data shown to the user.

## Threats & mitigations

| # | Threat | Mitigation | Status |
|---|---|---|---|
| T1 | Scanner bug reports a needed OS/user file as junk | Rules engine allowlist per category + hard denylist + engine-level filter of all scanner output; every deletion shown for review before acting | ✅ tested |
| T2 | Symlink/TOCTOU: scan sees safe path, delete follows link elsewhere | `SymlinkGuard` re-resolves parent chain immediately before `trashItem`; refuses escapes; symlinks themselves are never traversed during scans | ✅ tested |
| T3 | Deeply nested paths / `..` traversal in paths | Absolute paths only; `..` components rejected; standardized URLs; root-must-strictly-contain-item check | ✅ tested |
| T4 | Malicious/compromised update replaces app | Sparkle EdDSA + pinned key + notarization (Phase 8); until then, Developer ID + Gatekeeper | ⏳ Phase 8 |
| T5 | Another local process talks to a future privileged helper | No helper in v1; if built: code-signature check of caller + server-side validation of every request + audit log | ✅ documented, N/A v1 |
| T6 | Remote rules feed smuggles delete-anything payload | No remote rules in v1; if added: signed+rollback-protected feed, local allowlist always authoritative | ✅ N/A v1 |
| T7 | User tricked into over-deleting via scary UI | Honest, factual copy only; confirmation tiers (type-DELETE for high risk); cancel always available; no auto-clean | ✅ design rule §5.8 |
| T8 | Data exfiltration via telemetry | Zero network I/O in v1; no content/path/hash transmission by design | ✅ N/A v1 |
| T9 | Undo overwrites newly created data | `UndoRestorer` refuses when original path is occupied | ✅ tested |
| T10 | App auto-empties Trash / permanent deletion | Trash category explicitly skipped by deleter; no unlink anywhere; no auto-empty | ✅ tested |
| T11 | Denial of service via pathological tree (huge dirs, loops) | Enumeration never follows symlinks; result limits on large-file/duplicate scans; cancellable scans; bounded duplicate file count | ✅ design |
| T12 | Stale scan results: file replaced between scan and clean | Size/date not re-verified (contents irrelevant — item still matches path rules); deletion revalidates location; failures reported, not forced | ✅ design |
| T13 | Permission failures mislead user into granting excess access | FDA requested just-in-time with explanation; deep-link straight to the correct pane; never requests unrelated TCC permissions | ✅ design |
| T14 | Supply-chain: build machine / CI compromise | Notarization requires signed CI secrets; CI runs tests+lint only, release signing documented as manual/gated step | ⏳ Phase 7 |

## Out of scope (v1)

- Other users' home directories, `/private/var/db` edits, SIP bypass, disabling security
  mechanisms, kernel-level threats, physical access attackers.
