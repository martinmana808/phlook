# PHLOOK — Shrink & Archive ("10% library") — Design

Date: 2026-07-24
Status: approved, awaiting implementation plan

## Problem

The PHLOOK library is ~268 GB across ~17,300 files, of which **92% is video**
(6,577 clips, 247 GB). It is too large to keep on the laptop (70 GB free). The
user wants to keep browsing the whole library locally, but at a fraction of the
size, with the full-resolution masters living on an external SSD.

Measured breakdown (`~/Pictures/PHLOOK`, 2026-07-24):

| kind | files | size | share |
|------|-------|------|-------|
| video (mov, mp4) | 6,577 | 247 GB | 92% |
| photos (jpeg, heic, png, jpg, heif) | 10,694 | 20 GB | 8% |

## Goal

After the process runs, the user has:
- **On the SSD:** every original, byte-perfect ("the actual thing", not a backup).
- **On the laptop:** a ~10% "small version" of every original, that they can
  browse, recognise, pick from, and (for video) watch.
- **Certainty they lost nothing:** everything present locally as a 10% version
  exists 1-to-1, verified, on the SSD.

## The core invariant (the whole point of the design)

> **A local original is deleted only after (a) its byte-perfect copy is verified
> on the SSD, and (b) its 10% version exists locally. Deletion is always the
> last step, done per file, and never runs while the SSD is absent.**

If any step fails, the local original is left untouched. Loss is impossible
because deletion is the final action and only follows proven archival.

## Accepted tradeoff — SSD is a single point of failure (READ THIS)

**Once local originals are deleted, the SSD holds the only copy of each master.
A dead or lost SSD means the masters are gone forever.** The 10% versions on the
laptop survive, so the user never loses the *memory* of any shot — but the
full-resolution master would be unrecoverable. This is a deliberate, accepted
tradeoff (the user cannot keep 268 GB locally). It is stated here, in bold, so
it is a decision on the record and not a surprise. A future "second archive
drive / mirror" is out of scope for this spec but compatible with the design.

## Terminology

- **Original / master** — the full-resolution file as it exists today.
- **10% version / small version** — the shrunk stand-in kept on the laptop.
  (Called a "proxy" in editing tools; this spec says "10% version".)

## Data model

Three new columns on the existing `files` table, plus one config table. Follows
the established `PRAGMA user_version` + `ALTER TABLE ADD COLUMN` migration
pattern in `MediaIndex.swift` (next version gate: **8**).

```
archived_hash  TEXT   -- sha256 of the master, set ONLY after read-back verification on the SSD
archived_at    TEXT   -- ISO8601; when the SSD copy was verified
small_path     TEXT   -- absolute path to the 10% version in ~/Pictures/PHLOOK_proxy (nil = not made yet)
```

New table for the archive drive's identity:

```
CREATE TABLE IF NOT EXISTS archive_config (
    id INTEGER PRIMARY KEY CHECK (id = 1),   -- single row
    marker_id TEXT NOT NULL,                  -- uuid written into the SSD marker file
    ssd_label TEXT                            -- last-seen volume name, for display only
);
```

The three user-facing states are **derived**, never stored redundantly:

- **local original present** — a file exists at `files.path`.
- **on SSD (archived)** — `archived_hash` is non-null.
- **has 10% version** — `small_path` is non-null and that file exists.

"Needs archiving" = local original present AND `archived_hash` is null.
"Reclaimable" = archived AND has 10% version AND local original still present.

## Layout on disk

```
~/Pictures/PHLOOK/                 originals (deleted last, after archival)
    2026-03-04_11-20-08_IMG_4471.HEIC
~/Pictures/PHLOOK_proxy/           10% versions (mirror base names)
    2026-03-04_11-20-08_IMG_4471.jpg
    2026-03-04_11-21-55_IMG_4472.mp4
/Volumes/<SSD>/PHLOOK/             verified masters (the archive of record)
    .phlook_archive                marker file { id: <uuid>, created: ... }
    2026-03-04_11-20-08_IMG_4471.HEIC
```

Sibling proxy tree chosen (over in-place swap or a hidden cache) so that: a
proxy is always distinguishable from a master on disk; an original and its 10%
version can coexist during verification; and deleting the whole proxy tree
loses nothing.

## Components

### `PhlookCore/SSDArchiveTarget.swift` — drive identity (pure)
- Resolves the archive SSD by **marker file**, not volume name. First-time
  setup writes `.phlook_archive` containing a fresh uuid at the drive root and
  stores that uuid in `archive_config`.
- `resolve() -> ArchiveTarget?` scans mounted volumes for a `.phlook_archive`
  whose `id` matches the stored `marker_id`. Returns nil (feature disabled) when
  no matching drive is mounted. A same-named drive without the matching marker
  is refused.
- Exposes the target `PHLOOK/` root path for the archive writer.

### `PhlookCore/SmallVersionEncoder.swift` — the 10% encoders (pure, native)
No external binaries (no dependency on homebrew ffmpeg). In-process macOS APIs:
- **Photos** — ImageIO (`CGImageSource`/`CGImageDestination`), long-edge
  2048px, JPEG quality tuned to land ~5–10% of source. Output `.jpg`.
- **Video** — AVFoundation (`AVAssetWriter`/`AVAssetReader` or
  `AVAssetExportSession` at 720p), H.264, quality-based encode. Output `.mp4`.
- **Size guard:** if a video's 10% version comes out larger than ~15% of the
  source, the source is already small/efficient — keep the original bytes as the
  "small version" (copy, no re-encode) rather than spending time for no gain.
- Honest target: **~8–12%, watchable** — not exactly 10.00%. Video output size
  depends on motion, so an exact percentage is not a settable dial.

### `PhlookCore/ArchiveService.swift` — the orchestrator (pure, testable)
Per file, strictly ordered. Any failure aborts THIS file and leaves its local
original untouched; the run continues to the next file.

```
1. h = sha256(original)
2. copy original → SSD/PHLOOK/<name>          (skip-if-exists guarded, see below)
3. sha256(SSD copy) == h ?                     else: delete partial SSD file, abort file
4. DB: archived_hash = h, archived_at = now    (commit — survives a crash)
5. make 10% version → PHLOOK_proxy/<name>, confirm it re-opens/decodes
6. DB: small_path = <proxy path>               (commit — survives a crash)
7. delete local original via LibraryTrasher    (recoverable Trash)
```

- **Resumable:** steps 4 and 6 commit progress, so a crash or unplug mid-run
  resumes cleanly on the next pass (already-archived files skip to step 5;
  already-shrunk files skip to step 7).
- **Serial, one file at a time.** With only ~70 GB free, the run must never
  stage many originals on the SSD before deleting locals. copy→verify→shrink→
  delete→next keeps peak extra disk to a single file.
- **Cancellable between files, never mid-file.**

### UI (`Sources/Phlook/…`)
- **"Reclaim space" panel** (sidebar entry / toolbar). Shows live derived counts:
  *"6,577 not yet archived · ~240 GB reclaimable"*, *"11,000 have 10% versions"*.
  Primary button **"Archive & shrink"**, greyed with *"Connect PHLOOK_SSD"* when
  `SSDArchiveTarget.resolve()` is nil. First run offers **"Set up archive drive"**
  (writes the marker).
- **Phone-import view gains a second line:** after the existing "N new to import"
  it adds *"…and M items still need archiving."* Same "what's missing" question,
  two sources.
- **Right-click a 10% item → "Show original on SSD"** reveals the master in
  Finder (`NSWorkspace.activateFileViewerSelecting`). Greyed when SSD absent.
  PHLOOK does not copy it back; the user drags it themselves. ("Restore original
  locally" is explicitly out of scope for v1.)
- **Progress:** live count during the run; Cancel stops after the current file.

## Edge cases (all designed in)

- **Wrong / unmarked drive** — marker `id` must equal stored `marker_id`; a
  same-named drive without it is refused. No archiving to an unverified drive.
- **SSD unplugged mid-run** — the in-flight file finishes or aborts cleanly;
  nothing is deleted without its verified twin. Next file sees `resolve()` nil
  and the run stops.
- **Name collision on the SSD** (a file already at the target path) — if its
  hash already equals `h`, treat as already-archived (idempotent, proceed to
  shrink/delete). If the hash differs, **never overwrite**: flag, skip, and
  report — mirroring the ingest airlock's "collision = leave it, tell the user".
- **Proxy already exists** — if `small_path` is set and the file decodes, skip
  re-encoding (idempotent).
- **Encode failure / undecodable output** — abort the file at step 5; original
  kept, `small_path` left null, reported in the run summary.
- **Disk full while writing a proxy** — abort the file; original kept.

## Testing

Pure-core units (no SSD hardware, tmp dirs stand in for the volume):
- `SmallVersionEncoder` — a photo shrinks and re-decodes; a tiny/efficient video
  hits the size-guard passthrough; a normal video shrinks and re-decodes.
- `ArchiveService` — happy path reaches all 3 states in order; a hash-mismatch
  on read-back leaves the original and clears the partial SSD file; a
  differing-hash name collision is flagged and skipped; a crash simulated
  between steps 4 and 6 resumes without re-copying; SSD-absent mid-run stops
  without deleting.
- `SSDArchiveTarget` — matching marker resolves; missing/mismatched marker
  returns nil; volume rename with intact marker still resolves.
- Derived-count queries (`needsArchiving`, `reclaimable`, `hasSmall`) over a
  seeded index.

## Out of scope (v1)

- Restore-original-locally (copy master back into the library).
- A second/mirror archive drive.
- Re-generating masters or editing originals in place.
- Bit-rot re-hash sweeps of the SSD (verification is at copy time only).
