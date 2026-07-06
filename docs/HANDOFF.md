# PHLOOK — Project Handoff / Context Document

*Last updated: 2026-07-02. Paste this whole file into a new conversation to bring a fresh agent up to speed.*

---

## 1. What PHLOOK is (the vision)

PHLOOK is a **native macOS photo/video viewer** — "a rich Finder / media viewer." The pitch in the user's own words:

> "The Photos.app experience you already know, but your media stays as plain files in real folders on disk — no giant proprietary library blob."
>
> "I want to escape the prison of being inside the Photos app and how it always makes massive library files, but at the same time I want a Photos-app clone."

**Core principle:** files stay as **plain files in real folders** on disk (`~/Pictures/PHLOOK`). No proprietary `.photoslibrary` bundle. PHLOOK just indexes and displays them; the files are always yours, movable, backup-able, readable by any other tool.

### Explicitly CUT from the Photos feature set (user doesn't want these)
- Editing
- Faces / people recognition
- Memories
- Cloud / sync (iCloud)
- **Albums** (user says: "ignore albums, I never use albums")

### Wanted (the braindump feature backlog, roughly prioritized)
- 3 grid density views (micro squares → normal → large)
- Fullscreen detail view + metadata panel
- A "VS Code-style" timeline scrubber rail
- Quick Look integration, "Show in Finder", drag-out to Final Cut Pro
- Tree/folder view + sidebar
- Dedup / duplicate finder, quality culling
- Compression, hidden/locked items
- OCR, semantic search, audio search, smart stacking, "context radar", hover-scrub video previews
- Finder tags integration

Most of these are **future** work. v1 is intentionally minimal (see below).

---

## 2. Where we are RIGHT NOW

### ✅ v1 "Foundation" is BUILT, reviewed, and WORKING
The app compiles, launches, and successfully renders the user's **real ~13,985-file photo library** (their actual Buenos Aires / life photos) as a dense grid of thumbnails. Confirmed via screenshot.

- **Location:** `/Users/martinmana/Documents/Projects/phlook`
- **Git branch:** `phlook-v1-foundation` — **kept un-merged** (not yet finished/merged to main).
- **Tests:** 11/11 passing, warning-free.
- **What v1 does:** scans `~/Pictures/PHLOOK` recursively, indexes files into SQLite, generates thumbnails, shows them in a micro-grid. That's it. The user's most recent feedback: *"this is super basic. just squares showing the media. nothing else."* — This is expected; v1 was only the foundation. Richer UI is Plan 2.

### The user's library today
- `~/Pictures/PHLOOK` already contains **~14k files** (migrated earlier by an old `antigravity.py` script), named `YYYY-MM-DD_HH-MM-SS_OriginalName.ext`, flat in the folder.
- The **active Photos.app library** is `~/Pictures/Photos Library 2.photoslibrary` — it holds only **~1,949 originals** (most of the 14k is already out in the PHLOOK folder).
- **There is a verified byte-for-byte backup** of everything on the external **"Extreme SSD"** (now formatted APFS). This is the safety net.

---

## 3. THE ACTIVE TASK — Import (MOVE) originals out of Photos.app

This is what we were doing when the conversation was cut. **User's exact request:**

> "I still don't know how we bring from Photos. I would like to literally REMOVE the originals from Photos and place them in the PHLOOK folder, renamed properly, and everything."

This is a **MOVE**, not a copy — destructive (delete from Photos after export). So it must be done in **safe, verified phases.**

### The tool: `osxphotos`
- Installed at `~/.local/bin/osxphotos` (v0.76.1), via `pipx install --python /opt/anaconda3/bin/python3 osxphotos` (the system `python@3.14` was broken; anaconda's python 3.13.5 works).
- **Key safety fact:** `osxphotos` **exports** originals but **never deletes from Photos** by design. So deletion is always a deliberate, separate, manual step.

### ⚠️ TCC / permissions gotcha (critical)
The agent's shell (cmux host terminal) does **NOT** have Full Disk Access, so **it cannot read the Photos library** — any `osxphotos` command that touches the library fails with a permission error there. **All `osxphotos` commands must be run by the user in their own Terminal.app**, which HAS been granted Full Disk Access. The agent gives the commands; the user runs them and pastes results back.

### The planned 3-phase workflow
1. **Export (non-destructive):** `osxphotos export ~/Pictures/PHLOOK` with a filename template producing `YYYY-MM-DD_HH-MM-SS_name.ext` (to match the existing PHLOOK naming), `--skip-edited`, `--update`, and `--report`. Photos stays untouched. Originals already carry their EXIF, so no `--exiftool` dependency needed (that would require installing exiftool). Consider exporting to a staging subfolder first to avoid mixing with the existing 14k until verified.
2. **Verify:** count exported vs. library total, spot-check files open and have correct dates. (Same rigor we used verifying the SSD backups.)
3. **Remove from Photos (destructive, LAST):** only after verify — select all in Photos.app → Delete → empty "Recently Deleted." Safety net: the SSD backup still holds the originals.

### NEXT CONCRETE STEP
Have the user run this **read-only** command in **Terminal.app** to see the scope, then paste output:
```bash
~/.local/bin/osxphotos info
```
Then build them the tuned `export` command from the result.

---

## 4. Technical architecture (v1 as built)

**Native macOS, SwiftUI/AppKit, Swift Package Manager.** NOT Xcode.

### Why no Xcode
The machine has only **Command Line Tools**, not full Xcode. Can't auto-install Xcode (needs interactive Apple ID + 2FA). Consequences:
- Build with **Swift Package Manager** (`Package.swift`), not `.xcodeproj`.
- Tests use **swift-testing** (`import Testing`, `@Test`, `#expect`, `#require`), NOT XCTest (unavailable on CLT).
- **`swift test` bare silently finds 0 tests** — must run via the Makefile which injects `-Xswiftc -F -Xswiftc <CLT frameworks path>`.

### Package layout
- `PhlookCore` (library/framework) + `Phlook` (executable) + `PhlookCoreTests`.
- swift-tools-version 5.10, macOS 14 min, GRDB.swift 6.29+.

### Key source files (`Sources/`)
| File | Role |
|------|------|
| `PhlookCore/MediaItem.swift` | GRDB record; table `files`; snake_case columns (`date_taken`, `file_type`, `last_scanned`). |
| `PhlookCore/MediaIndex.swift` | SQLite index: `upsert`, `item(forPath:)`, `allItems`, `deleteMissing(keepingPaths:)`, `count`. `CREATE TABLE IF NOT EXISTS files`. |
| `PhlookCore/LibraryScanner.swift` | `scan()` with `.skipsHiddenFiles`; EXIF via ImageIO; `quickHash` = SHA256 of first 1MB + size. Video is classified but **video metadata extraction is deferred** (no AVFoundation). |
| `PhlookCore/ThumbnailCache.swift` | async `thumbnailURL(for:size:)` via QLThumbnailGenerator; returns nil on failure/nil-hash. |
| `PhlookCore/IndexingService.swift` | `reindex()`/`items()`/`thumbnails`; creates root dir before MediaIndex (fresh-install crash fix). |
| `PhlookCore/TestSupport.swift` | `TestFixtures.writeJPEG` via CoreGraphics (exact pixel dims — NSImage doubled them on Retina). |
| `Phlook/PhlookApp.swift` | `@main` App + `AppDelegate` with `setActivationPolicy(.regular)` + `activate()` (SPM executables otherwise show no window). |
| `Phlook/LibraryViewModel.swift` | `load()`: shows cached items instantly, then reindexes in background; `isIndexing` flag. |
| `Phlook/ContentView.swift` | hosts `MicroGridView`, calls `vm.load()` on appear. |
| `Phlook/MicroGridView.swift` | the grid; 80×80 cells; loading/empty states + "Updating…" chip. |

### Build / run
- `Makefile`: `make build`, `make test`, `make test-one NAME=X`, `make app` (bundles `Phlook.app`), `make run-app`.
- `scripts/bundle-app.sh` builds a real double-clickable `Phlook.app` bundle (bundle id `com.martinmana.phlook`, min system 14.0). Launch with `open ./Phlook.app`. (A real bundle is needed — `swift run` opens a stray window that gets lost behind full-screen terminals.)

### Superpowers dev workflow in use
brainstorming → writing-plans → subagent-driven-development → finishing-a-development-branch. Fresh implementer + reviewer subagent per task; ledger at `.superpowers/sdd/progress.md`.

### Design & plan docs
- `docs/superpowers/specs/2026-07-01-phlook-v1-design.md` — v1 design spec.
- `docs/superpowers/plans/2026-07-01-phlook-v1-foundation.md` — the 6-task TDD plan (done).

---

## 5. Bugs already found & fixed (don't re-introduce)
- Switched XcodeGen/xcodebuild → SPM (no Xcode).
- XCTest → swift-testing (CLT).
- NSImage Retina fixture pixel-doubling → CoreGraphics fixtures.
- Deferred video metadata (AVFoundation deprecation noise) — video still classified.
- ThumbnailCache phantom URL on write failure + nil-hash UUID → return nil.
- Scanner was indexing its own `.phlook/thumbnails` on 2nd launch → `.skipsHiddenFiles`.
- Fresh-install crash (missing root dir) → createDirectory before MediaIndex.
- SPM executable no-window → AppDelegate activation policy + real .app bundle.
- Blank grid ("i see nothing") → instant cached load + indexing indicator.

---

## 6. What's NEXT (roadmap)

### Immediate: Plan 3 — Ingest from Photos (ACTIVE, section 3 above)
The MOVE-from-Photos pipeline. This is what the user is prioritizing right now.

### Plan 2 — Views (richer UI; user wants this, current grid is "super basic")
Normal + large grid densities, fullscreen detail view + metadata panel, VS Code-style timeline rail, Quick Look, Show-in-Finder, drag-to-Final-Cut, sidebar.

### v2 backlog / tech debt
- **Incremental scan** — currently re-hashes ~14GB on every launch; skip unchanged files by mtime/size.
- `deleteMissing` bulk DELETE.
- Thumbnail-cache locking.
- Video metadata extraction (duration, dims, date).

---

## 7. Environment quick facts
- Mac-only user. Primary dir `/Users/martinmana`. macOS (Darwin 25.2.0). Not a git repo at home root; PHLOOK project is its own git repo.
- Full Disk Access: **Terminal.app has it; the agent's cmux shell does not.** Anything touching Photos libraries / protected dirs must be run by the user in Terminal.app.
- External **"Extreme SSD"** = APFS, holds verified backups of everything.
- osxphotos at `~/.local/bin/osxphotos`.
- Persistent memory index at `~/.claude/projects/-Users-martinmana/memory/` — see `phlook-app.md`.
