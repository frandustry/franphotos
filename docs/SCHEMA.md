# 数据库 Schema 与 fpparquet 协议

本文描述 FranPhotos 库的权威元数据 schema（SQLite）与 parquet 交换协议。对应源码：

- `FranPhotos/Library/Database/SchemaV1.swift` — v1 全量 DDL（**永不修改，后续版本只追加迁移**）
- `FranPhotos/Library/Database/Migrations.swift` — 有序、只追加的迁移列表
- `go/fpparquet/schema.go`、`go/fpparquet/main.go` — parquet 行结构与 JSON-lines 协议
- `FranPhotos/Parquet/ParquetBridge.swift`、`ParquetRowCodec.swift`、`ParquetSync.swift` — Swift 侧实现

---

## 迁移机制 Migrations

迁移运行器先建表（幂等）：

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
```

`Migrations.all` 是有序数组，每个未应用的迁移在**各自独立的事务**中执行（迁移 SQL + 写入 `schema_migrations`）。`Migrations.currentVersion` 取 `SELECT COALESCE(MAX(version), 0) FROM schema_migrations`。

| version | name | 内容 |
|---|---|---|
| 1 | `initial schema` | `SchemaV1.sql` 全量 DDL（下文所有表） |
| 2 | `faces_scanned flag` | `ALTER TABLE assets ADD COLUMN faces_scanned INTEGER NOT NULL DEFAULT 0;` |

数据库打开时的 pragmas（`Database.init`）：`journal_mode = WAL`、`foreign_keys = ON`、`synchronous = NORMAL`、`busy_timeout = 5000`，连接带 `SQLITE_OPEN_FULLMUTEX`。

---

## 表结构 Tables

### library_meta

键值对表，存放库级状态。

```sql
CREATE TABLE library_meta (
    key TEXT PRIMARY KEY,
    value TEXT
);
```

已知键：`timeline_dirty`（`"1"` = 时间线 parquet 待重建）、`memories_generated_at`（回忆上次生成时间，unix epoch 字符串）。

### assets

核心资产表，每行一张照片或一个视频。

```sql
CREATE TABLE assets (
    uuid TEXT PRIMARY KEY,
    media_type TEXT NOT NULL CHECK (media_type IN ('photo','video')),
    captured_at REAL NOT NULL,             -- unix epoch 秒
    captured_at_tz_offset INTEGER,         -- 拍摄时区：GMT 以东秒数（v1 列名）
    added_at REAL NOT NULL,
    duration_ms INTEGER,                   -- 视频（含 live photo 视频组件）
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    file_size INTEGER NOT NULL,
    sha256 TEXT NOT NULL UNIQUE,           -- 导入去重键
    original_relpath TEXT NOT NULL,        -- 如 originals/2025/03/<uuid>.heic
    filename TEXT NOT NULL,
    uti TEXT,
    title TEXT,
    caption TEXT,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    is_hidden INTEGER NOT NULL DEFAULT 0,
    is_deleted INTEGER NOT NULL DEFAULT 0, -- 1 = 最近删除（30 天后物理清除）
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
    edit_recipe_json TEXT,                 -- 编辑配方 JSON，只在主库，不进 parquet
    edit_version INTEGER NOT NULL DEFAULT 0
);
-- migration v2 追加：
ALTER TABLE assets ADD COLUMN faces_scanned INTEGER NOT NULL DEFAULT 0;
```

索引：

```sql
CREATE INDEX idx_assets_captured ON assets(captured_at);
CREATE INDEX idx_assets_library_view ON assets(is_deleted, is_hidden, captured_at DESC);
CREATE INDEX idx_assets_sha256 ON assets(sha256);
CREATE INDEX idx_assets_geo ON assets(latitude, longitude) WHERE latitude IS NOT NULL;
CREATE INDEX idx_assets_live ON assets(is_live_photo) WHERE is_live_photo = 1;
```

`idx_assets_library_view` 支撑主时间线查询（排除已删除/隐藏，按拍摄时间倒序）；两个部分索引（`WHERE` 子句）只覆盖有地理位置的行和 live photo 行。

### albums / album_assets

```sql
CREATE TABLE albums (
    uuid TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('manual','smart','builtin')),
    smart_rules_json TEXT,                 -- 智能相簿规则（SmartRuleSet）
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

### album_folders（迁移 v3）

```sql
CREATE TABLE album_folders (
    uuid TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_folder_uuid TEXT REFERENCES album_folders(uuid) ON DELETE CASCADE,
    sort_index INTEGER NOT NULL DEFAULT 0,
    created_at REAL NOT NULL DEFAULT (unixepoch('now'))
);
-- albums 增加：folder_uuid TEXT REFERENCES album_folders(uuid) ON DELETE SET NULL
```

相簿文件夹（嵌套用 `parent_folder_uuid`）只是组织性元数据，**不写 parquet**；
删除文件夹会递归删除其中的相簿与子文件夹（照片本体留在图库）。

### keywords / asset_keywords

```sql
CREATE TABLE keywords (
    uuid TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE COLLATE NOCASE   -- 大小写不敏感去重
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
    center_x REAL NOT NULL,                -- 归一化 0..1
    center_y REAL NOT NULL,
    size REAL NOT NULL,                    -- 相对 min(图宽, 图高)
    thumbnail_relpath TEXT                 -- faces/<faceUUID>.jpg
);
CREATE INDEX idx_faces_asset ON faces(asset_uuid);
CREATE INDEX idx_faces_person ON faces(person_uuid);
```

### asset_fts（FTS5 contentless-delete 设计）

```sql
CREATE VIRTUAL TABLE asset_fts USING fts5(
    title, caption, keywords, filename,
    content='', contentless_delete=1
);
```

**设计理由**（见 SchemaV1.swift 注释）：

1. `content=''` — 不复制原始文本，FTS 索引零冗余存储。代价是**列值无法从 FTS 表读回**（只能拿到 rowid），所以搜索结果必须 `JOIN assets` 取展示数据。
2. `contentless_delete=1` — 允许对无内容表执行**普通 `DELETE FROM asset_fts WHERE rowid = ?`**，不要求删除时提供原始列值（普通 contentless 表删除需要精确值匹配）。这使触发器可以写得极简。

触发器（只同步资产自有列 title/caption/filename）：

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

**keywords 列的维护**：UPDATE 触发器会用 `group_concat` 从 `asset_keywords ⋈ keywords` 联结表**重建**整行关键词文本；而关键词本身的变更（增删）发生在 `AssetActions.setKeywords` 里，应用层在事务内对 FTS 行做显式 `DELETE + INSERT` 重写（contentless FTS 需要整行重写，不能增量改一列）。

### partition_checksums

Parquet 分区的内容哈希登记表，是「parquet 可自愈」机制的核心（见 `ParquetSync`）。

```sql
CREATE TABLE partition_checksums (
    partition_key TEXT PRIMARY KEY,        -- 'timeline:2025-03' | 'album:<uuid>'
    kind TEXT NOT NULL CHECK (kind IN ('timeline','album')),
    row_count INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    regenerated_at REAL NOT NULL
);
```

语义：

- `partition_key`：时间线分区为 `timeline:YYYY-MM`（`MonthKey.parquetPartitionKey`），相簿分区为 `album:<albumUUID>`。
- `sha256`：**内容哈希，不是文件哈希**。`ParquetSync.contentHash` 对每个资产拼接 `uuid|capturedAt(epoch秒)|editVersion|isHidden|isDeleted|isFavorite`，排序后对换行连接的串做 SHA-256（顺序无关、计算便宜）。`validateAndRepair()` 重算该哈希并与表中值比对，不一致即重建分区。
- `row_count` / `regenerated_at`：上次重建时的行数与时间，随每次 `INSERT … ON CONFLICT(partition_key) DO UPDATE` 更新。
- 资产清空的分区：parquet 文件删除，对应行也删除。

### memories

```sql
CREATE TABLE memories (
    uuid TEXT PRIMARY KEY,
    kind TEXT NOT NULL,                    -- year_highlight | trip | on_this_day
    title TEXT NOT NULL,
    key_date REAL,
    asset_uuids_json TEXT NOT NULL,        -- UUID 字符串数组 JSON，有序
    created_at REAL NOT NULL DEFAULT (unixepoch('now'))
);
```

由 `MemoryStore` 规则引擎生成（今年亮点 / 旅行 / 往年今日），表为空或距上次生成超过 24 小时（`library_meta.memories_generated_at`）时重建。

---

## fpparquet JSON-lines 协议

`fpparquet` 是嵌入 App 的长驻 Go 助手进程（`go/fpparquet/main.go`），经 **stdin/stdout 的 JSON Lines** 与 Swift 通信：每行一个 JSON 请求对象，每个请求严格回一行 JSON 响应并立即 flush；stdout 只写响应，诊断走 stderr；stdin 关闭即退出。协议版本 `"1"`（`ping` 响应的 `version` 字段）。

### 命令

```
{"cmd":"ping"}                                                  → {"ok":true,"version":"1"}
{"cmd":"write","path":"<abs>","kind":"asset|timeline_index|album_index","rows":[{...}]}
                                                                → {"ok":true,"rows":<n>,"sha256":"<文件字节SHA256 hex>"}
{"cmd":"read","path":"<abs>","kind":"...","offset":0,"limit":0} → {"ok":true,"rows":[{...}]}
任何失败                                                        → {"ok":false,"error":"<message>"}
```

细节：

- `path` 必须是**绝对路径**，否则报错；`write` 的 `rows` 不能为空。
- `read` 的 `limit <= 0` 表示读全部剩余行；`offset` 越界自动截断；返回的 `rows` 永不为 null（空为 `[]`）。
- 写入是**原子的**：写到同目录 `.fpparquet-*.tmp`，chmod 0644，fsync，close，`rename` 覆盖目标。压缩为 **Snappy**（parquet-go `parquet.Compression(&parquet.Snappy)`）。
- `handleLine` 带 recover，内部 panic 转为 `{"ok":false,...}`，进程不死，可继续服务后续请求。
- Swift 侧 `ParquetBridge`（actor）串行化请求；阻塞管道读写放在专用 `DispatchQueue("franphotos.fpparquet.io")`，不占协作线程池。助手查找顺序：环境变量 `FRANPHOTOS_FPPARQUET` → `Bundle.main/Resources/bin/fpparquet` → 开发 checkout 的 `go/fpparquet/bin/fpparquet`（缺失时跑 `scripts/build-go-helper.sh` 现编）。

### 三种 kind 的行结构（go/fpparquet/schema.go）

Parquet 列名与 JSON 字段名完全一致（snake_case）。Go 指针字段 = parquet `optional` 列；JSON null/缺省 ↔ nil 指针。

**asset（40 列）** — `AssetRow`：

| # | 列 | parquet 类型 | 可选 | 对应 assets 列 / 说明 |
|---|---|---|---|---|
| 1 | `uuid` | string | 否 | `uuid` |
| 2 | `media_type` | string | 否 | `"photo"` \| `"video"` |
| 3 | `captured_at` | int64 | 否 | unix epoch 秒 |
| 4 | `captured_at_tz` | int32 | ✅ | `captured_at_tz_offset` |
| 5 | `added_at` | int64 | 否 | epoch 秒 |
| 6 | `duration_ms` | int32 | ✅ | 视频时长 |
| 7 | `width` | int32 | 否 | |
| 8 | `height` | int32 | 否 | |
| 9 | `file_size` | int64 | 否 | |
| 10 | `sha256` | string | 否 | |
| 11 | `original_relpath` | string | 否 | |
| 12 | `filename` | string | 否 | |
| 13 | `uti` | string | 否 | 空串表示无（Swift 读回时 `""`→nil） |
| 14 | `title` | string | ✅ | |
| 15 | `caption` | string | ✅ | |
| 16 | `is_favorite` | bool | 否 | |
| 17 | `is_hidden` | bool | 否 | |
| 18 | `is_deleted` | bool | 否 | |
| 19 | `deleted_at` | int64 | ✅ | epoch 秒 |
| 20 | `rating` | int32 | 否 | |
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
| 31 | `hdr_type` | string | 否 | `"sdr"` \| `"gainmap"` \| `"hlg"` \| `"pq"` |
| 32 | `is_live_photo` | bool | 否 | |
| 33 | `live_photo_video_relpath` | string | ✅ | |
| 34 | `live_photo_still_time_ms` | int32 | ✅ | |
| 35 | `video_codec` | string | ✅ | fourCC，如 `hvc1`/`dvhe` |
| 36 | `color_space` | string | ✅ | |
| 37 | `has_audio` | bool | ✅ | |
| 38 | `frame_rate` | float64 | ✅ | |
| 39 | `edit_version` | int32 | 否 | 编辑版本号 |
| 40 | `album_sort_index` | int32 | 否 | 册内顺序（时间线分区中为 0） |

注意 **`edit_recipe_json` 不在 parquet 中**：编辑配方永不离开主库（`ParquetRowCodec.asset(from:)` 里硬编码 `editRecipeJSON: nil`）。

**timeline_index（6 列）** — `TimelineIndexRow`：

```go
Month         string `parquet:"month"`           // "2025-03"
RowCount      int32  `parquet:"row_count"`
FirstCaptured int64  `parquet:"first_captured"`
LastCaptured  int64  `parquet:"last_captured"`
CoverUUID     string `parquet:"cover_uuid"`
SHA256        string `parquet:"sha256"`          // 内容哈希（来自 partition_checksums）
```

**album_index（6 列）** — `AlbumIndexRow`：

```go
AlbumUUID string `parquet:"album_uuid"`
Name      string `parquet:"name"`
AlbumType string `parquet:"album_type"` // "manual" | "smart" | "builtin"
RowCount  int32  `parquet:"row_count"`
CoverUUID string `parquet:"cover_uuid"`
SHA256    string `parquet:"sha256"`
```

### 用 DuckDB 读一个月分区

```sql
SELECT * FROM 'parquet/timeline/2025/2025-03.parquet';

-- 整条时间线（glob 通配）
SELECT * FROM 'parquet/timeline/*/*.parquet' ORDER BY captured_at DESC;

-- 时间线索引
SELECT * FROM 'parquet/timeline/_index.parquet';
```

（路径相对于 bundle 根目录；Snappy 解压 DuckDB 自带，无需插件。）
