import Foundation

/// Schema v1 — the full initial DDL. Later versions append migrations; never edit v1.
enum SchemaV1 {
    static let sql = """
    -- schema_migrations is created (IF NOT EXISTS) by the migration runner itself.
    CREATE TABLE library_meta (
        key TEXT PRIMARY KEY,
        value TEXT
    );

    CREATE TABLE assets (
        uuid TEXT PRIMARY KEY,
        media_type TEXT NOT NULL CHECK (media_type IN ('photo','video')),
        captured_at REAL NOT NULL,             -- unix epoch seconds
        captured_at_tz_offset INTEGER,         -- seconds east of GMT at capture time
        added_at REAL NOT NULL,
        duration_ms INTEGER,                   -- videos (and live photo video component)
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        file_size INTEGER NOT NULL,
        sha256 TEXT NOT NULL UNIQUE,
        original_relpath TEXT NOT NULL,        -- e.g. originals/2025/03/<uuid>.heic
        filename TEXT NOT NULL,
        uti TEXT,
        title TEXT,
        caption TEXT,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        is_hidden INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
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
        edit_recipe_json TEXT,
        edit_version INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX idx_assets_captured ON assets(captured_at);
    CREATE INDEX idx_assets_library_view ON assets(is_deleted, is_hidden, captured_at DESC);
    CREATE INDEX idx_assets_sha256 ON assets(sha256);
    CREATE INDEX idx_assets_geo ON assets(latitude, longitude) WHERE latitude IS NOT NULL;
    CREATE INDEX idx_assets_live ON assets(is_live_photo) WHERE is_live_photo = 1;

    CREATE TABLE albums (
        uuid TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL CHECK (type IN ('manual','smart','builtin')),
        smart_rules_json TEXT,
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

    CREATE TABLE keywords (
        uuid TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE
    );

    CREATE TABLE asset_keywords (
        asset_uuid TEXT NOT NULL REFERENCES assets(uuid) ON DELETE CASCADE,
        keyword_uuid TEXT NOT NULL REFERENCES keywords(uuid) ON DELETE CASCADE,
        PRIMARY KEY (asset_uuid, keyword_uuid)
    );

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
        size REAL NOT NULL,                    -- relative to min(image width, height)
        thumbnail_relpath TEXT
    );
    CREATE INDEX idx_faces_asset ON faces(asset_uuid);
    CREATE INDEX idx_faces_person ON faces(person_uuid);

    CREATE VIRTUAL TABLE asset_fts USING fts5(
        title, caption, keywords, filename
    );

    -- FTS sync: assets columns (title/caption/filename) via triggers.
    -- The `keywords` FTS column is maintained by the app (keywords live in a join table).
    CREATE TRIGGER assets_fts_ai AFTER INSERT ON assets BEGIN
        INSERT INTO asset_fts(rowid, title, caption, filename)
        VALUES (new.rowid, coalesce(new.title,''), coalesce(new.caption,''), new.filename);
    END;
    CREATE TRIGGER assets_fts_ad AFTER DELETE ON assets BEGIN
        INSERT INTO asset_fts(asset_fts, rowid, title, caption, keywords, filename)
        VALUES ('delete', old.rowid, coalesce(old.title,''), coalesce(old.caption,''),
                (SELECT coalesce(group_concat(k.name, ' '), '')
                   FROM asset_keywords ak JOIN keywords k ON k.uuid = ak.keyword_uuid
                  WHERE ak.asset_uuid = old.uuid),
                old.filename);
    END;
    CREATE TRIGGER assets_fts_au AFTER UPDATE OF title, caption, filename ON assets BEGIN
        INSERT INTO asset_fts(asset_fts, rowid, title, caption, keywords, filename)
        VALUES ('delete', old.rowid, coalesce(old.title,''), coalesce(old.caption,''),
                (SELECT coalesce(group_concat(k.name, ' '), '')
                   FROM asset_keywords ak JOIN keywords k ON k.uuid = ak.keyword_uuid
                  WHERE ak.asset_uuid = old.uuid),
                old.filename);
        INSERT INTO asset_fts(rowid, title, caption, keywords, filename)
        VALUES (new.rowid, coalesce(new.title,''), coalesce(new.caption,''),
                (SELECT coalesce(group_concat(k.name, ' '), '')
                   FROM asset_keywords ak JOIN keywords k ON k.uuid = ak.keyword_uuid
                  WHERE ak.asset_uuid = new.uuid),
                new.filename);
    END;

    CREATE TABLE partition_checksums (
        partition_key TEXT PRIMARY KEY,        -- 'timeline:2025-03' | 'album:<uuid>'
        kind TEXT NOT NULL CHECK (kind IN ('timeline','album')),
        row_count INTEGER NOT NULL,
        sha256 TEXT NOT NULL,
        regenerated_at REAL NOT NULL
    );

    CREATE TABLE memories (
        uuid TEXT PRIMARY KEY,
        kind TEXT NOT NULL,                    -- year_highlight | trip | on_this_day
        title TEXT NOT NULL,
        key_date REAL,
        asset_uuids_json TEXT NOT NULL,
        created_at REAL NOT NULL DEFAULT (unixepoch('now'))
    );
    """
}
