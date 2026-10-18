# FranPhotos

**English** | [简体中文](README.zh-CN.md)

A native macOS photo management app written from scratch in SwiftUI — a clean-room
reimagining of Apple Photos that ports most of its core features, with a tidy,
portable library format and zero runtime dependencies.

## Highlights

- **Clean, portable library format**: a `*.franphotoslibrary` bundle holds a SQLite
  main database plus Parquet snapshots (timeline partitioned per month, one per
  album). Media files are copied in as entities — the library folder is a complete,
  self-contained backup.
- **Lazy-loading timeline**: Years / Months / Days / All Photos zoom levels; month
  partitions stream in from Parquet as you scroll, never blocking the UI.
- **Live Photos**: automatic still + MOV pairing on import, hover the LIVE badge to
  play inline, seamless crossfades.
- **Video done right**: poster-frame first paint, muted inline hover previews, and
  gapless still↔video transitions with zero black flashes.
- **HDR / XDR**: detects gain-map HEIC, HLG/PQ stills and HLG/Dolby Vision videos;
  renders with EDR on XDR displays, tone-maps gracefully on SDR ones.
- **Full info panel**: EXIF (body/lens/ISO/aperture/shutter/focal length…), MapKit
  location, and editable title/caption/keywords.
- **Non-destructive editing**: crop/rotate/filters and full light & color
  adjustments; recipes are stored in the library and always reversible.
- **Albums**: manual albums, smart albums (rule engine), and nested folders.
- **People, Places, Memories, duplicate detection, Recently Deleted** — the works.
- **Bilingual UI** (English + Simplified Chinese), driven by a String Catalog with
  room for more languages.

## Building

Requirements: Xcode 16+ (27+ recommended) and Go 1.22+ — Go is a **build-time-only**
dependency for the bundled Parquet helper; end users need nothing installed.

```bash
make build   # or: xcodebuild -project FranPhotos.xcodeproj -scheme FranPhotos build
make test    # full test suite
```

The Go `fpparquet` helper is compiled by an Xcode build phase and embedded in the
app bundle (fully vendored — builds offline).

## Documentation

- [Library format](docs/LIBRARY_FORMAT.md)
- [Database schema](docs/SCHEMA.md)
- [Architecture](docs/ARCHITECTURE.md)
- [HDR rendering](docs/HDR.md)

## License

[Apache-2.0](LICENSE)
