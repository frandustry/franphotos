# Architecture

**English** | [简体中文](ARCHITECTURE.zh-CN.md)

FranPhotos is a SwiftUI macOS photo app with strict layering: **SQLite is the single source of truth, parquet is a regenerable snapshot, and everything in the render layer can be rebuilt**. The project is pure Swift 6 (`SWIFT_VERSION = 6.0`, strict concurrency checking); deployment target macOS 15.0.

## Layer overview

```
┌─────────────────────────────────────────────────────────────┐
│ UI (SwiftUI)  TimelineGridView / DetailView / PeopleView …  │
├─────────────────────────────────────────────────────────────┤
│ App layer   LibraryManager (@MainActor @Observable)         │
│             open/close, import scheduling, orchestration    │
├─────────────────────────────────────────────────────────────┤
│ Stores      TimelineStore · AlbumsStore · SearchStore ·     │
│             PeopleStore · MemoryStore                       │
│             (@MainActor @Observable presentation models)    │
├─────────────────────────────────────────────────────────────┤
│ Data layer  DatabaseActor (SQLite, WAL)  ←→  ParquetSync    │
│             (authoritative)       (dirty → snapshot rebuild)│
│                        ParquetBridge (actor)                │
│                        └─ stdio JSON-lines → Go fpparquet   │
├─────────────────────────────────────────────────────────────┤
│ Render      DerivativeCache (3-tier cache) · HDRCompositor ·│
│             EDRPipeline (Metal EDR rendering, see HDR.md)   │
├─────────────────────────────────────────────────────────────┤
│ Media       MediaStageController (still↔video crossfade)    │
│             PlayerPool (AVPlayer LRU, capacity 3)           │
├─────────────────────────────────────────────────────────────┤
│ Import/Edit ImportEngine (copy-in) · EditEngine (pure CI)   │
└─────────────────────────────────────────────────────────────┘
```

## Layer responsibilities

### App layer: `LibraryManager` (FranPhotos/App/LibraryManager.swift)

Owns the currently open library and every long-lived service bound to it: `LibraryStore`, `DatabaseActor`, `DerivativeCache`, `ParquetSync`, `TimelineStore`, `AlbumsStore`, `SearchStore`. Open flow (`open(_:createIfMissing:)`):

1. `LibraryStore.create/open` → `validate(repair: true)` fills in missing directories.
2. `DatabaseActor.openOrCreate` opens `database/library.sqlite` and runs migrations.
3. If the library is not newly created, update the manifest's `schemaVersion` to `LibraryManifest.currentSchemaVersion`.
4. Build all services, then run two chores in the **background** in parallel: `ParquetSync.validateAndRepair()` (validate/repair parquet partitions) and `LibraryMaintenance.purgeExpiredTrash` (purge Recently Deleted items older than 30 days: row + original + live components + derivatives + edits directory).

### Stores (presentation models, all `@MainActor @Observable`)

- **TimelineStore** — month index + `MonthSlice` LRU pool (`maxHotSlices = 12`), four zoom levels (years / months / days / allPhotos); cross-year navigation automatically loads adjacent month partitions. `slice(for:)` is a pure read (LRU touches happen only on the `ensureLoaded` async path — mutating observable state during view body evaluation once caused an AttributeGraph infinite-invalidation loop that froze the main thread); eviction does not remove the dictionary entry but clears `MonthSlice.assets` and bumps `reloadToken`, which makes the on-screen partition reload automatically.
- **AlbumsStore** — album list; after every change is persisted through `AlbumStore`, `markAlbumDirty` + `syncAlbums` rebuild that album's parquet.
- **SearchStore** — FTS5 full-text (title/caption/keywords/filename) + structured scopes (all/photos/videos/favorites), 250ms debounce.
- **PeopleStore** — face-scan orchestration (assets with `faces_scanned = 0` go through `FaceScanner` one by one, thumbnails written to `faces/<faceUUID>.jpg`), person naming/merging/cover photos.
- **MemoryStore** — rule engine generates memories (year_highlight / trip / on_this_day), rebuilt when older than 24 hours, persisted to the `memories` table.

### Data layer

**DatabaseActor** (actor) serializes all SQLite access; the underlying `Database` is a thin synchronous wrapper over the system libsqlite3 (`SQLITE_OPEN_FULLMUTEX`), pragmas: WAL, foreign_keys ON, synchronous NORMAL, busy_timeout 5000. Upper layers (repositories, ImportEngine, ParquetSync) talk only to the actor.

**ParquetSync** (actor) keeps parquet consistent with SQLite (see SCHEMA.md / LIBRARY_FORMAT.md):

- Write path: in-memory `dirtyMonths` + `library_meta.timeline_dirty = 1` → `syncTimeline()` rebuilds partitions month by month → rewrites `_index.parquet` → clears the dirty flags. Albums likewise (`dirtyAlbums` → `syncAlbums()`).
- Read path: parquet first, SQLite fallback + background repair.
- After a library is opened, `validateAndRepair()` compares all content hashes and self-heals.

**ParquetBridge** (actor) → Go helper `fpparquet`: stdio JSON-lines protocol, blocking IO on a dedicated DispatchQueue; lookup order: env `FRANPHOTOS_FPPARQUET` → `Resources/bin/fpparquet` → `go/fpparquet/bin/fpparquet`.

### Render layer

- **DerivativeCache** (actor), three tiers: NSCache memory (default 256 MB cost limit) → disk `derivatives/{thumbs,screen}/<uuid>.jpg` → decode the original, rebuild, and write back to disk. Key = `uuid-size-e<editVersion>`, so **the grid auto-invalidates after edits**; concurrent requests for the same key share one in-flight Task. HDR sources are tone-mapped to SDR via `HDRCompositor.sdrImage` before being stored as JPEG.
- **HDRCompositor** (enum): shared `CIContext(mtlDevice:)` (expensive to create, reused globally); a single code path, `composited(base:gainMap:headroom:)`, serves both EDR display and SDR output.
- **EDRPipeline / MetalEDRView / HDRImageView**: CIImage → `CVPixelBuffer(64RGBAHalf, extendedLinearDisplayP3)` → `CVMetalTextureCache` → full-screen triangle blit (`edrBlitVS/edrBlitFS` in `Shaders.metal`) → `CAMetalLayer(rgba16Float, wantsExtendedDynamicRangeContent)`. Full derivation in [HDR.md](HDR.md).

### Media layer

- **MediaStageController** (@MainActor @Observable) drives the state machine for seamless still↔video handoff: `still → prewarming → playing → returning → still`. While prewarming, with the video layer still invisible, it **seeks precisely to the still-frame moment** (the live photo's `live_photo_still_time_ms`, zero tolerance), so the first visible frame matches the still exactly — no black flash, no jump. The playback-finished notification (`AVPlayerItemDidPlayToEndTime`) triggers `returnToStill`.
- **PlayerPool** (@MainActor singleton): AVPlayer LRU pool, `capacity = 3`, so hover preloading can't spawn unbounded decoder instances; `actionAtItemEnd = .pause`.

### Import / Edit

- **ImportEngine**: copies media into the library as entities (media is never left as an external reference), SHA-256 dedup, EXIF/video metadata extraction, Live Photo pairing (`LivePhotoPairer.plan`), serial processing for predictable disk IO.
- **EditEngine**: pure CoreImage, deterministic and replayable; applies `EditRecipe` in the order geometry → light → color → creative filters → detail; renders output to `derivatives/edits/<uuid>/v<version>.jpg`.

## Concurrency model

- **Swift 6 strict concurrency**. State isolation boundaries:
  - actors: `DatabaseActor`, `ParquetSync`, `ParquetBridge`, `DerivativeCache`.
  - `@MainActor`: all Stores, `LibraryManager`, `MediaStageController`, `PlayerPool`.
- The few `@unchecked Sendable` exceptions each carry a comment explaining why: `Database` (only accessed through the actor), `LibraryStore`, `ImportEngine`, `EDRPipeline`, `SendableImageCache` (NSCache is documented thread-safe but not marked Sendable, so it's wrapped).
- Blocking pipe IO never occupies the Swift cooperative thread pool: `ParquetBridge` reads/writes on `DispatchQueue("franphotos.fpparquet.io")` and bridges back to async with `withCheckedThrowingContinuation`.
- Expensive decode/render work is explicitly `Task.detached` (import, edit rendering, face detection, HDR decode).

## Lazy-loading data flow (open library → scroll)

```
open library
  → LibraryStore.validate(repair:) fills in missing directories
  → DatabaseActor migrates; validateAndRepair() in the background
  → TimelineStore.loadIndex()
      → ParquetSync.timelineIndex()
          prefer parquet/timeline/_index.parquet
          missing/empty → SQLite aggregate query (GROUP BY strftime('%Y-%m', captured_at...))
      → yields months[] / years[] summaries (including per-month cover cover_uuid)
scroll to a month
  → TimelineStore.ensureLoaded(monthKey)
      → ParquetSync.monthAssets(key)
          prefer parquet/timeline/YYYY/YYYY-MM.parquet
          missing/unreadable → SQLite SELECT * ... ORDER BY captured_at DESC (and wait for the next repair rebuild)
      → MonthSlice.assets (hidden/deleted filtered out), sorted by captured_at DESC
  → LRU: when hotOrder exceeds maxHotSlices = 12, evict the least-recently-used loaded MonthSlice
    (clear its assets, keep object identity, bump reloadToken; the partition view reloads automatically)
thumbnails
  → DerivativeCache.image(for:size:) → memory → disk → decode & rebuild
```

## Mutation data flow (writes)

```
user action (favorite/hide/delete/edit title…)
  → LibraryManager.mutateAsset(uuid) { AssetActions writes SQLite }   ← authoritative write
  → resolve monthKey → markMonthsDirty([month])
      → ParquetSync.markDirty: dirtyMonths ∪= month, library_meta.timeline_dirty = 1
      → ParquetSync.syncTimeline(): re-read that month from SQLite → fpparquet atomically rewrites
        parquet/timeline/YYYY/YYYY-MM.parquet → update partition_checksums
        → rewrite _index.parquet → timeline_dirty = 0
  → re-fetch the asset → TimelineStore.updateAssetInSlices updates/removes in place
edit saved
  → EditEngine.renderEditDerivative writes derivatives/edits/<uuid>/v<version>.jpg
  → assets.edit_recipe_json + edit_version +1 (AssetActions)
  → derivative cache keys include -e<editVersion>, so old thumbnails auto-invalidate (DerivativeCache.invalidate if needed)
album change
  → AlbumStore persists → ParquetSync.markAlbumDirty(uuid) → syncAlbums()
    rebuild parquet/albums/<uuid>.parquet and albums/_index.parquet
close library
  → closeLibrary() best-effort syncTimeline() flushes dirty partitions, then releases all services
```

## Build layout

- **Hand-written `FranPhotos.xcodeproj/project.pbxproj`** (objectVersion 77, no Xcode generation step):
  - All three targets (`FranPhotos` / `FranPhotosTests` / `FranPhotosUITests`) use **PBXFileSystemSynchronizedRootGroup** (Xcode 16 folder synchronization); the Sources/Frameworks/Resources phase file lists are empty — adding a source file doesn't require touching the pbxproj.
  - App target build phase order: **`Build fpparquet helper` (PBXShellScriptBuildPhase) → Sources → Frameworks → Resources**. The script phase has `alwaysOutOfDate = 1` and declares its output as `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/fpparquet`.
  - `MACOSX_DEPLOYMENT_TARGET = 15.0`, bundle id `com.frandustry.franphotos`.
- **`scripts/build-go-helper.sh`**: under Xcode it installs to `$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/bin`; run standalone it installs to `go/fpparquet/bin`. Under a minimal PATH it probes common locations such as `/opt/homebrew/bin/go` in order; if the binary is newer than every `.go`/`go.mod`/`go.sum`/`vendor/` file it skips (incremental build); build flags `GOFLAGS=-mod=vendor CGO_ENABLED=0 go build -trimpath -ldflags="-s -w"` — the vendor tree is committed, so builds work offline and the product is a static, dependency-free binary.
- Users don't need Go installed at runtime; Go is only a build-time dependency.
