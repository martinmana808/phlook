# PHLOOK — Curated Library & SSD Vault (merged Phase 1 + 2) — Design

Date: 2026-08-05
Status: design agreed through case-study walkthroughs; supersedes and extends
`2026-07-24-shrink-and-archive-design.md` (Phase 1). Phase 1's per-file
archive pipeline is BUILT and reviewed (branch `phlook-shrink-archive`, 218
tests green) and carries over unchanged as the foundation. This spec adds the
curation/vault/sync layer on top.

## Problem

The library is ~268 GB / ~17,800 files, 92% video, and won't fit on the laptop
(70 GB free). The user wants **one curated library at two resolutions**: full
100% masters on an external SSD (2 TB, space not a near-term concern), and a
browsable ~10% version of the same library locally. Over months they keep
importing new media (100% until archived) and curating (deleting the bad
shots). Reconnecting the SSD reconciles both sides so they always describe the
same curated library.

## Goals

- **Grow:** import new media → back it up to the SSD → keep a 10% version
  locally → reclaim the local full-res.
- **Curate:** delete bad shots on the laptop; the curated library shrinks on
  both sides, with the SSD master preserved (never destroyed by the app).
- **Work on originals:** "claim full size" pulls a master back down to 100%
  locally and protects it from re-shrinking.
- **Survive disaster:** if the laptop dies, rebuild the whole curated library
  from the SSD.

## Foundational invariants (in bold because they define the system)

1. **Delete-safety (built, Phase 1):** a local original is trashed ONLY after
   its byte-perfect master is verified on the SSD (read-back hash) AND its 10%
   version exists locally. Deletion is always the last per-file step.
2. **The SSD is an APPEND-ONLY VAULT. PHLOOK never deletes or moves a file on
   the SSD — ever. "Deletion" is a database flag, not a physical act.** The
   vault holds every master that ever reached it, physically untouched. Only
   the user, manually, ever removes anything from the SSD.
3. **Intent is never inferred from local file absence.** Only an in-app action
   changes curation state. A file merely missing locally (Finder delete, disk
   glitch, wiped proxy folder) is treated as "master safe on the SSD, just not
   downloaded" — a claimable item — never as a deletion.
4. **Media is never hostage to a database.** Masters are plainly-named files in
   `PHLOOK/` on the SSD. If every DB were lost, 100% of the media survives;
   only the curated/not-curated labels would be lost (re-curate to rebuild).

## The item model — three independent facts

Every item is described by three orthogonal facts, not one linear state:

| Fact | Values | Column(s) |
|------|--------|-----------|
| On the SSD? | yes (master present) / no | `archived_hash`, `ssd_rel_path` |
| In the curated library? | curated / not-curated | `curated` |
| Local copy? | none / 10% / 100% | `path` presence, `small_path`, `protected` |

Everything the user described maps onto these:
- "Backed up" = on the SSD.
- "Compressed / 10%" = local copy is the small version.
- "Protected / claimed full size" = local copy is 100% (`protected = true`).
- "Deleted" = `curated = false` (+ local 10% trashed). Master stays on SSD.
- "Not yet backed up" = the recent 707 (see Adoption) — on laptop, not on SSD.

## Data model (extends the built v8 schema)

Built already (v8, on `files`): `archived_hash TEXT`, `archived_at TEXT`,
`small_path TEXT`; plus `archive_config(marker_id, ssd_label)`.

**Add (migration v9):**
```
curated        INTEGER NOT NULL DEFAULT 1   -- 1 = in the curated library
protected      INTEGER NOT NULL DEFAULT 0   -- 1 = keep full-res locally, never shrink
ssd_rel_path   TEXT                         -- master's ACTUAL path on the SSD, relative to PHLOOK/
                                            -- (name-independent; nil = not on SSD)
```
Rationale for `ssd_rel_path`: match local↔master by **content hash**, and store
where the master actually lives, so the SSD never needs renaming/moving and
future naming drift can't break the mapping (invariant 2). In today's drive the
name happens to equal the local name, but the design must not depend on that.

**Add `archive_config` columns for the local-boss / versioned-sync model:**
```
db_version     INTEGER NOT NULL DEFAULT 0   -- monotonic; bumped on every local mutation session
synced_at      TEXT                         -- when the SSD copy was last written
```
The **local DB is authoritative for intent**; the SSD carries a **copy** of the
DB (written at the end of each session, `synced_at` stamped, `db_version`
recorded). On connect, compare `db_version`: local ≥ SSD → local wins silently
(the one-laptop case). SSD strictly newer than the laptop's last-known → PHLOOK
**asks** instead of overwriting newer work (divergence valve for a rebuilt
second machine). Physical presence of masters is always re-derivable by scanning
the SSD, so the SSD's file listing is the authority for "what exists," the DB
for "what it means."

## Adoption — the first run (validated against the real drive, 2026-08-03)

The user already has a prior backup on the SSD. Measured on drive "Extreme SSD":
`/Volumes/Extreme SSD/PHLOOK/` is flat, **17,074 masters**, named in the same
convention as the local library. Filename-set + content comparison vs local
`~/Pictures/PHLOOK` (17,781 media):

- **17,074 already present, byte-identical** (8/8 sampled photos+videos hashed
  equal, incl. the `1904-` unknown-date ones) → **adopt in place, no re-copy**.
- **707 local-only** (recent 2026 `IMG_xxxx` imports) → **copy up + verify**.
- **0 SSD-only orphans.**

**First-run flow (must NOT delete-and-recopy — that is the worst option):**
1. Set up the drive (write/confirm `.phlook_archive` marker; `PHLOOK/` already
   is the vault).
2. **Adopt:** for each local item, find the SSD master by content hash. If a
   byte-identical master exists (whether same-named at `PHLOOK/<name>` or found
   by hash), record `archived_hash` + `ssd_rel_path` and mark archived WITHOUT
   copying. This is a fast verify pass (reads, not transfers). PHLOOK's existing
   collision handling already does the same-name hash-match case; extend it to a
   hash index so name-independent matches work too.
3. **Copy the remainder** (the 707) up to the SSD and verify (Phase 1 pipeline).
4. **Shrink** everything to 10% locally; **reclaim** the local originals.
5. Write the DB copy to the SSD, stamp `synced_at` / `db_version`.

Adoption mismatch policy: if a local file's hash has no SSD match, copy it
fresh. If a same-named SSD file exists with a DIFFERENT hash, never overwrite —
copy the local version to a new name and flag for review (invariant 2).

The drive also holds unrelated backups at its root (music, wedding, "todas las
fotos", ~180k files total) — PHLOOK touches only `PHLOOK/` and leaves the rest
alone.

## The rituals (end-to-end flows)

### Grow (import → back up → shrink)
Plug phone → import new (existing feature) → those items join the "needs
archiving" set → plug SSD → each is adopted-or-copied to the vault, verified,
shrunk to 10%, and the local original reclaimed. Requires the SSD (invariant 1).

### Curate (delete)
Delete in PHLOOK → local 10% goes to macOS Trash → `curated = false` recorded
immediately (works offline; the item leaves the grid at once). On the next SSD
connect, the SSD's DB copy is updated to `curated = false`. **The master file on
the SSD is never touched.** Fully reversible forever: re-curate flips it back and
re-downloads the 10%. Because nothing is destroyed, no confirm-to-destroy is
needed; a "Recently changed / not-curated" view is optional UX, not a safety
net. A file deleted before it ever reached the SSD is simply gone (it only ever
lived locally — expected).

### Claim full size (work on an original)
Viewing a 10% item shows a **"Compressed (10%)"** label and a **"Claim full
size"** button. Button → if SSD present, copy the master down, replace the local
10% with the 100%, set `protected = true`. If SSD absent, the button reads
**"Connect PHLOOK_SSD to restore."** Copy-down only; nothing deleted.

### Protect
Mark an item protected (⌘-something / context menu) → the shrink pass skips it;
it stays 100% locally. `protected` also survives re-shrink passes.

## Disaster recovery
Laptop dies → plug SSD into a new machine → PHLOOK reads the SSD's DB copy →
every `curated` master is physically present at 100% → re-shrink locally to 10%
for items marked 10%, leave `protected` items at 100% → curated library fully
rebuilt from the vault.

## Display & sidebar (the "show me WHICH files, not just a count")

New sidebar scopes so the user can see and act on exact sets, not just counts:
- **Not backed up** — on laptop, not on SSD (`archived_hash IS NULL`). The 707,
  and anything imported since the last archive.
- **Compressed (10%)** — reclaimed items (small version is the local copy).
- **Full size / Protected** — `protected = true`.
- **Not curated** — `curated = false` (normally hidden; a "recently removed"
  style view, fully restorable).

Display already falls back to the 10% version when the original is reclaimed
(built: `MediaItem.bestLocalURL()` wired into thumbnails, viewer, hover). Items
carry a small **"Compressed (10%)"** badge; protected items a **"Full size"**
badge.

## What is already built (Phase 1 foundation, branch `phlook-shrink-archive`)

`FileHasher`, DB v8 (archive columns + `archive_config`), `SSDArchiveTarget`
(marker identity), `SmallVersionEncoder` (native ImageIO/AVFoundation + size
guard), `ArchiveService` (ordered, resumable, verify-by-hash, temp-partial +
atomic rename, per-file marker recheck), `LibraryTrasher.trashFilesOnly`,
`ReclaimStatus`, `IndexingService` wiring, `ReclaimSpaceView`, and the review
fixes (deleteMissing exempts archived rows; resume gap; `bestLocalURL` display).
218 tests green.

## What this spec adds (the merged layer to build)

1. Migration v9: `curated`, `protected`, `ssd_rel_path`; `archive_config`
   `db_version` + `synced_at`.
2. Hash-indexed adoption (name-independent master matching) + first-run
   reconcile flow.
3. Curation: in-app delete → `curated=false`; the SSD DB-copy sync; the
   divergence-detecting versioned DB mirror on the SSD.
4. Claim-full-size (reverse reclaim) + protect flag honored by the shrink pass.
5. Sidebar scopes + badges (Not backed up / Compressed / Full size / Not
   curated) and the per-item "Claim full size" / "Compressed (10%)" affordances.
6. Disaster-recovery rebuild path (read SSD DB copy → rebuild local library).

## Out of scope (for now)

- A second/mirror archive drive.
- Automatic emptying of not-curated masters (always manual, by the user).
- Editing masters in place / re-encoding beyond the 10% pass.
- Bit-rot re-hash sweeps of the SSD (verification is at copy/adopt time).
- Copy / Copy-Image actions on reclaimed items (currently no-op on the missing
  original — follow-up: disable or copy the proxy explicitly).

## Open questions to resolve before/while planning

- Curate-with-SSD-connected: still defer the `curated` flag sync to a batch
  "reconcile" step, or apply immediately? (Nothing is destroyed either way, so
  this is UX, not safety.)
- Do we want the optional "Recently removed" undo view in v1, or ship curation
  as immediate-and-reversible-via-re-curate?
- Adoption performance: hashing ~250 GB of local + verifying against the SSD is
  a long one-time pass — surface progress and make it resumable (the pipeline is
  already resumable per-file).
