# Library Format

**English** | [简体中文](LIBRARY_FORMAT.zh-CN.md)

`.franphotoslibrary` is FranPhotos' library bundle. The entire folder is a complete, self-contained, portable photo library: **copying the whole folder = a complete backup**, with no dependency on any file outside the library.

This document corresponds strictly to the implementation. Primary sources: `FranPhotos/Library/LibraryPaths.swift`, `FranPhotos/Library/Manifest.swift`, `FranPhotos/Library/LibraryStore.swift`.

---

## Directory Tree

```
My Photos.franphotoslibrary/
├── library.json                    # Library manifest (LibraryManifest, plain JSON)
├── database/
│   └── library.sqlite              # Authoritative metadata database (WAL mode, FTS5)
├── parquet/
│   ├── timeline/
│   │   ├── _index.parquet          # Timeline index: one row per month
│   │   └── YYYY/YYYY-MM.parquet    # Timeline snapshots partitioned by month
│   └── albums/
│       ├── _index.parquet          # Album index: one row per album
│       └── <albumUUID>.parquet     # One asset snapshot per album
├── originals/
│   └── YYYY/MM/<assetUUID>.<ext>   # Original media (entity copies, partitioned by capture year/month)
├── derivatives/                    # Derived caches (rebuildable at any time)
│   ├── thumbs/<uuid>.jpg           # Grid thumbnails (longest edge 288pt × screen scale)
│   ├── screen/<uuid>.jpg           # Screen-size previews (longest edge 1456pt × screen scale)
│   └── edits/<uuid>/v<version>.jpg # Edit renders (one per edit version)
├── faces/<faceUUID>.jpg            # Face thumbnails (flat, named by face UUID)
├── temp/                           # Reserved temporary directory
└── exports/                        # Reserved export staging directory
```

The 10 directories above (`database`, `parquet/timeline`, `parquet/albums`, `originals`, `derivatives/thumbs`, `derivatives/screen`, `derivatives/edits`, `faces`, `temp`, `exports`) are defined by `LibraryPaths.requiredDirectories` and created when the library is created; when the library is opened, `LibraryStore.validate(repair:)` fills in any missing directories and reports `.repaired`.

Notes (implementation facts):

- **faces/** is a flat structure, `faces/<faceUUID>.jpg` (see `thumbRel = "faces/\(faceUUID.uuidString).jpg"` in `PeopleStore.scanLibrary()`); the association between faces and people lives only in the database, not in the directory hierarchy.
- **temp/ and exports/** are currently reserved directories: the export feature (`ExportEngine.export(..., destination:)`) writes to a folder chosen by the user, not to the in-library `exports/`.

---

## library.json Manifest

The single source of truth for library identity. The file is tiny and human-readable, and can be inspected and repaired with any text editor. It corresponds to the `LibraryManifest` type (Codable), encoded as prettyPrinted + sortedKeys, with ISO8601 dates (second precision, rounded down before encoding to guarantee lossless round-trips).

| Field | Type | Meaning |
|---|---|---|
| `formatVersion` | Int | Bundle on-disk layout version, currently `1` (`currentFormatVersion`). If `formatVersion > currentFormatVersion` at open time, the library is refused (`LibraryError.unsupportedFormatVersion`) |
| `libraryUUID` | UUID | Stable identity of the library, used for parquet files and exports |
| `name` | String | User-visible library name (defaults to the bundle filename minus its extension) |
| `createdAt` | Date(ISO8601) | Creation time |
| `appVersion` | String | App version that created / most recently migrated this library |
| `schemaVersion` | Int | Informational SQLite schema version field (written as `currentSchemaVersion` (currently 2)). **At runtime the `schema_migrations` table inside the database is authoritative** (see SCHEMA.md); this field is manifest information only |

Example:

```json
{
  "appVersion" : "0.1.0",
  "createdAt" : "2025-03-01T08:00:00Z",
  "formatVersion" : 1,
  "libraryUUID" : "…",
  "name" : "My Photos",
  "schemaVersion" : 1
}
```

The manifest is rewritten atomically via `LibraryStore.saveManifest` (`.atomic` write option).

---

## originals/: Media-Entity Rule

**Ironclad rule: all media are entity copies inside the library; the library never references external files.** `Asset.original_relpath` always points to a path inside the bundle. On import (`ImportEngine`), files are copied into the library, and the source files can then be deleted safely.

Path rule (`LibraryPaths.originalRelativePath(uuid:capturedAt:fileExtension:)`, using the Gregorian calendar):

```
originals/YYYY/MM/<assetUUID>.<ext>     # e.g. originals/2025/03/<uuid>.heic
```

- Year/month come from the **capture time** `captured_at` (EXIF DateTimeOriginal, falling back to the file modification time when missing).
- Extensions are always lowercase.
- **Live Photo pairing**: the still frame and the video component share the same asset UUID, each in its own file, differing only in extension (e.g. `<uuid>.heic` + `<uuid>.mov`). In the database `is_live_photo = 1`; the video path is stored in `live_photo_video_relpath`, and the still-frame time point in `live_photo_still_time_ms` (milliseconds).
- Deduplication: `assets.sha256` has a UNIQUE constraint; the SHA-256 is computed at import time, and if it already exists the item is counted as a duplicate and not copied again.

---

## parquet/: Regenerable Query Snapshots

Parquet files are **regenerable snapshots** of SQLite, designed for fast library opening and reading by external tools. Layout:

| File | kind | Contents |
|---|---|---|
| `parquet/timeline/_index.parquet` | `timeline_index` | One row per month: `month, row_count, first_captured, last_captured, cover_uuid, sha256`, in descending month order |
| `parquet/timeline/YYYY/YYYY-MM.parquet` | `asset` | All assets of that month (40 columns, including deleted/hidden flags; the UI filters them out after reading) |
| `parquet/albums/_index.parquet` | `album_index` | One row per album: `album_uuid, name, album_type, row_count, cover_uuid, sha256` |
| `parquet/albums/<albumUUID>.parquet` | `asset` | Assets of that album; the `album_sort_index` column is the in-album order |

Month-partition relative paths are generated by `LibraryPaths.timelineParquetRelativePath(monthKey:)`: `monthKey "2025-03" → parquet/timeline/2025/2025-03.parquet`.

All parquet files are written by the built-in Go helper `fpparquet`: **Snappy compression**, written to a temporary file in the same directory (`.fpparquet-*.tmp`), fsynced, then atomically renamed into place. Any standard parquet reader can open them directly:

```sql
-- DuckDB
SELECT * FROM 'parquet/timeline/2025/2025-03.parquet';
```

```python
# pandas
import pandas as pd
df = pd.read_parquet("My Photos.franphotoslibrary/parquet/timeline/2025/2025-03.parquet")
```

### Authority and Consistency Model

- **SQLite is authoritative**: every write lands in `database/library.sqlite` first.
- Every asset change marks the affected months as dirty (the in-memory `dirtyMonths` set) and sets `timeline_dirty` to `"1"` in the `library_meta` table; `ParquetSync.syncTimeline()` then regenerates the dirty month partitions from the database and rewrites `_index.parquet`, clearing `timeline_dirty` to `"0"` when done.
- The content hash of each partition is stored in SQLite's `partition_checksums` table (`partition_key` looks like `'timeline:2025-03'` or `'album:<uuid>'`).
- After the library is opened, `ParquetSync.validateAndRepair()` runs in the background: it recomputes each month's content hash from SQLite, rebuilds every partition whose file is missing or whose hash mismatches, deletes month partitions that no longer have any assets, and finally rewrites the index as needed and clears the dirty flags. **Therefore the entire `parquet/` directory can heal itself even if deleted** (in that case all read paths fall back to SQLite).
- Read paths prefer parquet: `timelineIndex()` / `monthAssets(_:)` try parquet first, and fall back to SQLite queries when the file is missing, unreadable, or empty (see ARCHITECTURE.md for details).

---

## derivatives/: Derived Caches (Disposable)

The disk tier of the three-level cache (`DerivativeCache`): in-memory NSCache → on-disk JPEG → decode the original and rebuild. Keys include the edit version (`…-e<editVersion>`), so they are invalidated automatically after edits.

- `thumbs/<uuid>.jpg`: grid thumbnails, longest edge 288 pt × screen backingScaleFactor, JPEG quality 0.82.
- `screen/<uuid>.jpg`: fast placeholder large image for the detail view, longest edge 1456 pt × scale, JPEG quality 0.88.
- `edits/<uuid>/v<version>.jpg`: render result after applying the edit recipe (sRGB); `editVersion` is incremented by 1 on every edit save.

All derived images are **tone-mapped SDR** (HDR sources have their gain map applied at headroom 1 and are output as sRGB JPEG), so the grid never looks washed out. The entire `derivatives/` directory can be deleted; it is rebuilt automatically on demand.

## faces/

Face thumbnails cropped by face scanning (`PeopleStore.scanLibrary` → `FaceScanner`), stored as `faces/<faceUUID>.jpg` (JPEG quality 0.85). The database column `faces.thumbnail_relpath` records the relative path. Scanned assets are marked with `assets.faces_scanned = 1` (a column added in schema migration v2).

## temp/ and exports/

Reserved directories, created and validated along with `requiredDirectories`. In the current implementation, exports are written to the destination folder chosen by the user and do not use the in-library directory.

---

## Portability Guarantees

1. **Whole folder = complete backup**: metadata (SQLite), snapshots (parquet), originals, faces, and edit recipes are all inside the bundle; losing `derivatives/` only makes things slower.
2. **No external references**: the entire bundle can be copied/moved to another Mac, an external drive, or a NAS and opened directly.
3. **Open formats**: `library.json` is plain JSON; `database/library.sqlite` is standard SQLite (inspectable directly with `sqlite3`); `parquet/` is standard Snappy parquet, readable by DuckDB / pandas / Arrow.
4. **Self-healing**: missing directories are recreated automatically; missing or stale parquet files are rebuilt from SQLite automatically.
