# Database Schema and the fpparquet Protocol

**English** | [简体中文](SCHEMA.zh-CN.md)

This document describes the authoritative metadata schema (SQLite) of a FranPhotos library and the parquet exchange protocol. Corresponding source code:

- `FranPhotos/Library/Database/SchemaV1.swift` — the complete v1 DDL (**never modified; later versions only append migrations**)
- `FranPhotos/Library/Database/Migrations.swift` — the ordered, append-only migration list
- `go/fpparquet/schema.go`, `go/fpparquet/main.go` — parquet row structures and the JSON-lines protocol
- `FranPhotos/Parquet/ParquetBridge.swift`, `ParquetRowCodec.swift`, `ParquetSync.swift` — Swift-side implementation

---

## Migration Mechanism

The migration runner first creates its bookkeeping table (idempotent):

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
```

`Migrations.all` is an ordered array; each unapplied migration runs in **its own transaction** (the migration SQL plus the `schema_migrations` insert). `Migrations.currentVersion` is `SELECT COALESCE(MAX(version), 0) FROM schema_migrations`.

| version | name | contents |
|---|---|---|
| 1 | `initial schema` | full `SchemaV1.sql` DDL (all tables below) |
| 2 | `faces_scanned flag` | `ALTER TABLE assets ADD COLUMN faces_scanned INTEGER NOT NULL DEFAULT 0;` |

Pragmas set when the database opens (`Database.init`): `journal_mode = WAL`, `foreign_keys = ON`, `synchronous = NORMAL`, `busy_timeout = 5000`; the connection is opened with `SQLITE_OPEN_FULLMUTEX`.

---

## Tables

### library_meta

Key-value table holding library-level state.

```sql
CREATE TABLE library_meta (
    key TEXT PRIMARY KEY,
    value TEXT
);
```

Known keys: `timeline_dirty` (`"1"` = timeline parquet needs rebuilding), `memories_generated_at` (when Memories were last generated, as a unix epoch string).

### assets

Core asset table; one row per photo or video.

```sql
CREATE TABLE assets (
    uuid TEXT PRIMARY KEY,
    media_type TEXT NOT NULL CHECK (media_type IN ('photo','video')),
    captured_at REAL NOT NULL,             -- unix epoch seconds
    captured_at_tz_offset INTEGER,         -- capture time zone: seconds east of GMT (v1 column name)
    added_at REAL NOT NULL,
    duration_ms INTEGER,                   -- video (including the live photo video component)
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    file_size INTEGER NOT NULL,
    sha256 TEXT NOT NULL UNIQUE,           -- import dedup key
    original_relpath TEXT NOT NULL,        -- e.g. originals/2025/03/<uuid>.heic
    filename TEXT NOT NULL,
    uti TEXT,
    title TEXT,
    caption TEXT,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    is_hidden INTEGER NOT NULL DEFAULT 0,
    is_deleted INTEGER NOT NULL DEFAULT 0, -- 1 = recently deleted (physically purged after 30 days)
    deleted_at REAL,
    rating INTEGER NOT NULL DEFAULT 0,
    camera_make TEXT,
    camera_model TEXT,
    lens_model TEXT,
    iso INTEGER,
    aperture REAL,
    shutter_speed REAL,
    focal_length REAL,
    latitude REAL,
    longitude REAL,
    altitude REAL,
    hdr_type TEXT NOT NULL DEFAULT 'sdr' CHECK (hdr_type IN ('sdr','gainmap','hlg','pq')),
    is_live_photo INTEGER NOT NULL DEFAULT 0,
    live_photo_video_relpath TEXT,
    live_photo_still_time_ms INTEGER,
    video_codec TEXT,
    color_space TEXT,
    has_audio INTEGER,
    frame_rate REAL,
    edit_recipe_json TEXT,                 -- edit recipe JSON; lives only in the main database, never in parquet
    edit_version INTEGER NOT NULL DEFAULT 0
);
-- added by migration v2:
ALTER TABLE assets ADD COLUMN faces_scanned INTEGER NOT NULL DEFAULT 0;
```

Indexes:

```sql
CREATE INDEX idx_assets_captured ON assets(captured_at);
CREATE INDEX idx_assets_library_view ON assets(is_deleted, is_hidden, captured_at DESC);
CREATE INDEX idx_assets_sha256 ON assets(sha256);
CREATE INDEX idx_assets_geo ON assets(latitude, longitude) WHERE latitude IS NOT NULL;
CREATE INDEX idx_assets_live ON assets(is_live_photo) WHERE is_live_photo = 1;
```

`idx_assets_library_view` backs the main timeline query (excludes deleted/hidden, ordered by capture time descending); the two partial indexes (`WHERE` clauses) cover only rows with geolocation and live photo rows.

### albums / album_assets

```sql
CREATE TABLE albums (
    uuid TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('manual','smart','builtin')),
    smart_rules_json TEXT,                 -- smart album rules (SmartRuleSet)
    sort_index INTEGER NOT NULL DEFAULT 0,
    cover_asset_uuid TEXT,
    created_at REAL NOT NULL DEFAULT (unixepoch('now'))
);

CREATE TABLE album_assets (
    album_uuid TEXT NOT NULL REFERENCES albums(uuid) ON DELETE CASCADE,
    asset_uuid TEXT NOT NULL REFERENCES assets(uuid) ON DELETE CASCADE,
    sort_index INTEGER NOT NULL DEFAULT 0,
    added_at REAL NOT NULL DEFAULT (unixepoch('now')),
    PRIMARY KEY (album_uuid, asset_uuid)
);
CREATE INDEX idx_album_assets_asset ON album_assets(asset_uuid);
```

### album_folders (migration v3)

```sql
CREATE TABLE album_folders (
    uuid TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_folder_uuid TEXT REFERENCES album_folders(uuid) ON DELETE CASCADE,
    sort_index INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL DEFAULT (unixepoch('now'))
);
-- albums gains: folder_uuid TEXT REFERENCES album_folders(uuid) ON DELETE SET NULL
```

Album folders (nested via `parent_folder_uuid`) are purely organizational metadata and are **never written to parquet**; deleting a folder recursively deletes its albums and subfolders (the photos themselves stay in the library).

### keywords / asset_keywords

```sql
CREATE TABLE keywords (
    uuid TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE   -- case-insensitive dedup
);

CREATE TABLE asset_keywords (
    asset_uuid TEXT NOT NULL REFERENCES assets(uuid) ON DELETE CASCADE,
    keyword_uuid TEXT NOT NULL REFERENCES keywords(uuid) ON DELETE CASCADE,
    PRIMARY KEY (asset_uuid, keyword_uuid)
);
```

### persons / faces

```sql
CREATE TABLE persons (
    uuid TEXT PRIMARY KEY,
    name TEXT,
    face_count INTEGER NOT NULL DEFAULT 0,
    cover_face_uuid TEXT,
    created_at REAL NOT NULL DEFAULT (unixepoch('now'))
);

CREATE TABLE faces (
    uuid TEXT PRIMARY KEY,
    asset_uuid TEXT NOT NULL REFERENCES assets(uuid) ON DELETE CASCADE,
    person_uuid TEXT REFERENCES persons(uuid) ON DELETE SET NULL,
    center_x REAL NOT NULL,                -- normalized 0..1
    center_y REAL NOT NULL,
    size REAL NOT NULL,                    -- relative to min(image width, image height)
    thumbnail_relpath TEXT                 -- faces/<faceUUID>.jpg
);
CREATE INDEX idx_faces_asset ON faces(asset_uuid);
CREATE INDEX idx_faces_person ON faces(person_uuid);
```

### asset_fts (FTS5 contentless-delete design)

```sql
CREATE VIRTUAL TABLE asset_fts USING fts5(
    title, caption, keywords, filename,
    content='', contentless_delete=1
);
```

**Rationale** (see the comments in SchemaV1.swift):

1. `content=''` — the original text is not duplicated, so the FTS index stores zero redundant data. The cost is that **column values cannot be read back from the FTS table** (only the rowid is available), so search results must `JOIN assets` to fetch display data.
2. `contentless_delete=1` — allows a **plain `DELETE FROM asset_fts WHERE rowid = ?`** on a contentless table without supplying the original column values at delete time (a plain contentless table requires exact value matches for deletion). This keeps the triggers minimal.

Triggers (sync only the asset's own columns title/caption/filename):

```sql
CREATE TRIGGER assets_fts_ai AFTER INSERT ON assets BEGIN
    INSERT INTO asset_fts(rowid, title, caption, filename)
    VALUES (new.rowid, coalesce(new.title,''), coalesce(new.caption,''), new.filename);
END;
CREATE TRIGGER assets_fts_ad AFTER DELETE ON assets BEGIN
    DELETE FROM asset_fts WHERE rowid = old.rowid;
END;
CREATE TRIGGER assets_fts_au AFTER UPDATE OF title, caption, filename ON assets BEGIN
    DELETE FROM asset_fts WHERE rowid = old.rowid;
    INSERT INTO asset_fts(rowid, title, caption, keywords, filename)
    VALUES (new.rowid, coalesce(new.title,''), coalesce(new.caption,''),
            (SELECT coalesce(group_concat(k.name, ' '), '')
               FROM asset_keywords ak JOIN keywords k ON k.uuid = ak.keyword_uuid
              WHERE ak.asset_uuid = new.uuid),
            new.filename);
END;
```

**Maintaining the `keywords` column**: the UPDATE trigger **rebuilds** the entire keyword text with `group_concat` over the `asset_keywords ⋈ keywords` join; keyword changes themselves (add/remove) happen in `AssetActions.setKeywords`, where the app layer performs an explicit `DELETE + INSERT` rewrite of the FTS row inside a transaction (a contentless FTS row must be rewritten wholesale — a single column cannot be updated incrementally).

### partition_checksums

Content-hash registry for parquet partitions; the core of the "parquet self-healing" mechanism (see `ParquetSync`).

```sql
CREATE TABLE partition_checksums (
    partition_key TEXT PRIMARY KEY,        -- 'timeline:2025-03' | 'album:<uuid>'
    kind TEXT NOT NULL CHECK (kind IN ('timeline','album')),
    row_count INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    regenerated_at REAL NOT NULL
);
```

Semantics:

- `partition_key`: `timeline:YYYY-MM` for timeline partitions (`MonthKey.parquetPartitionKey`), `album:<albumUUID>` for album partitions.
- `sha256`: a **content hash, not a file hash**. `ParquetSync.contentHash` concatenates `uuid|capturedAt(epoch seconds)|editVersion|isHidden|isDeleted|isFavorite` for each asset, sorts them, and SHA-256-hashes the newline-joined string (order-independent and cheap to compute). `validateAndRepair()` recomputes this hash and compares it with the stored value; a mismatch triggers a partition rebuild.
- `row_count` / `regenerated_at`: the row count and timestamp of the last rebuild, updated on every `INSERT … ON CONFLICT(partition_key) DO UPDATE`.
- A partition whose assets are all gone: the parquet file is deleted, and so is its row.

### memories

```sql
CREATE TABLE memories (
    uuid TEXT PRIMARY KEY,
    kind TEXT NOT NULL,                    -- year_highlight | trip | on_this_day
    title TEXT NOT NULL,
    key_date REAL,
    asset_uuids_json TEXT NOT NULL,        -- JSON array of UUID strings, ordered
    created_at REAL NOT NULL DEFAULT (unixepoch('now'))
);
```

Generated by the `MemoryStore` rules engine (year highlights / trips / on this day); rebuilt when the table is empty or more than 24 hours have passed since the last generation (`library_meta.memories_generated_at`).

---

## The fpparquet JSON-lines Protocol

`fpparquet` is a long-lived Go helper process embedded in the app (`go/fpparquet/main.go`), communicating with Swift via **JSON Lines over stdin/stdout**: one JSON request object per line; every request gets exactly one JSON response line, flushed immediately; stdout carries responses only, diagnostics go to stderr; the process exits when stdin closes. Protocol version `"1"` (the `version` field of the `ping` response).

### Commands

```
{"cmd":"ping"}                                                  → {"ok":true,"version":"1"}
{"cmd":"write","path":"<abs>","kind":"asset|timeline_index|album_index","rows":[{...}]}
                                                                → {"ok":true,"rows":<n>,"sha256":"<SHA256 hex of file bytes>"}
{"cmd":"read","path":"<abs>","kind":"...","offset":0,"limit":0} → {"ok":true,"rows":[{...}]}
any failure                                                     → {"ok":false,"error":"<message>"}
```

Details:

- `path` must be an **absolute path**, otherwise an error is returned; `write`'s `rows` must not be empty.
- For `read`, `limit <= 0` reads all remaining rows; an out-of-range `offset` is truncated automatically; the returned `rows` is never null (`[]` when empty).
- Writes are **atomic**: write to `.fpparquet-*.tmp` in the same directory, chmod 0644, fsync, close, then `rename` over the target. Compression is **Snappy** (parquet-go `parquet.Compression(&parquet.Snappy)`).
- `handleLine` recovers from panics: an internal panic becomes `{"ok":false,...}`; the process survives and keeps serving subsequent requests.
- On the Swift side, `ParquetBridge` (an actor) serializes requests; blocking pipe I/O runs on a dedicated `DispatchQueue("franphotos.fpparquet.io")`, off the cooperative thread pool. Helper lookup order: environment variable `FRANPHOTOS_FPPARQUET` → `Bundle.main/Resources/bin/fpparquet` → `go/fpparquet/bin/fpparquet` in a development checkout (built on demand via `scripts/build-go-helper.sh` if missing).

### Row Structures of the Three Kinds (go/fpparquet/schema.go)

Parquet column names match JSON field names exactly (snake_case). A Go pointer field = a parquet `optional` column; JSON null/absent ↔ nil pointer.

**asset (40 columns)** — `AssetRow`:

| # | Column | Parquet type | Optional | Corresponding assets column / notes |
|---|---|---|---|---|
| 1 | `uuid` | string | No | `uuid` |
| 2 | `media_type` | string | No | `"photo"` \| `"video"` |
| 3 | `captured_at` | int64 | No | unix epoch seconds |
| 4 | `captured_at_tz` | int32 | ✅ | `captured_at_tz_offset` |
| 5 | `added_at` | int64 | No | epoch seconds |
| 6 | `duration_ms` | int32 | ✅ | video duration |
| 7 | `width` | int32 | No | |
| 8 | `height` | int32 | No | |
| 9 | `file_size` | int64 | No | |
| 10 | `sha256` | string | No | |
| 11 | `original_relpath` | string | No | |
| 12 | `filename` | string | No | |
| 13 | `uti` | string | No | empty string means absent (on read-back Swift converts `""`→nil) |
| 14 | `title` | string | ✅ | |
| 15 | `caption` | string | ✅ | |
| 16 | `is_favorite` | bool | No | |
| 17 | `is_hidden` | bool | No | |
| 18 | `is_deleted` | bool | No | |
| 19 | `deleted_at` | int64 | ✅ | epoch seconds |
| 20 | `rating` | int32 | No | |
| 21 | `camera_make` | string | ✅ | |
| 22 | `camera_model` | string | ✅ | |
| 23 | `lens_model` | string | ✅ | |
| 24 | `iso` | int32 | ✅ | |
| 25 | `aperture` | float64 | ✅ | |
| 26 | `shutter_speed` | float64 | ✅ | |
| 27 | `focal_length` | float64 | ✅ | |
| 28 | `latitude` | float64 | ✅ | |
| 29 | `longitude` | float64 | ✅ | |
| 30 | `altitude` | float64 | ✅ | |
| 31 | `hdr_type` | string | No | `"sdr"` \| `"gainmap"` \| `"hlg"` \| `"pq"` |
| 32 | `is_live_photo` | bool | No | |
| 33 | `live_photo_video_relpath` | string | ✅ | |
| 34 | `live_photo_still_time_ms` | int32 | ✅ | |
| 35 | `video_codec` | string | ✅ | fourCC, e.g. `hvc1`/`dvhe` |
| 36 | `color_space` | string | ✅ | |
| 37 | `has_audio` | bool | ✅ | |
| 38 | `frame_rate` | float64 | ✅ | |
| 39 | `edit_version` | int32 | No | edit version number |
| 40 | `album_sort_index` | int32 | No | order within the album (0 in timeline partitions) |

Note that **`edit_recipe_json` is not in parquet**: the edit recipe never leaves the main database (`ParquetRowCodec.asset(from:)` hardcodes `editRecipeJSON: nil`).

**timeline_index (6 columns)** — `TimelineIndexRow`:

```go
Month         string `parquet:"month"`           // "2025-03"
RowCount      int32  `parquet:"row_count"`
FirstCaptured int64  `parquet:"first_captured"`
LastCaptured  int64  `parquet:"last_captured"`
CoverUUID     string `parquet:"cover_uuid"`
SHA256        string `parquet:"sha256"`          // content hash (from partition_checksums)
```

**album_index (6 columns)** — `AlbumIndexRow`:

```go
AlbumUUID string `parquet:"album_uuid"`
Name      string `parquet:"name"`
AlbumType string `parquet:"album_type"` // "manual" | "smart" | "builtin"
RowCount  int32  `parquet:"row_count"`
CoverUUID string `parquet:"cover_uuid"`
SHA256    string `parquet:"sha256"`
```

### Reading a Month Partition with DuckDB

```sql
SELECT * FROM 'parquet/timeline/2025/2025-03.parquet';

-- entire timeline (glob wildcard)
SELECT * FROM 'parquet/timeline/*/*.parquet' ORDER BY captured_at DESC;

-- timeline index
SELECT * FROM 'parquet/timeline/_index.parquet';
```

(Paths are relative to the bundle root; DuckDB handles Snappy decompression natively — no plugin needed.)
