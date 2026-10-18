[English](LIBRARY_FORMAT.md) | **简体中文**

# 库格式 Library Format

`.franphotoslibrary` 是 FranPhotos 的库文件包（bundle）。整个文件夹即一个完整、自包含、可移植的照片库：**整文件夹拷贝 = 完整备份**，不依赖库外的任何文件。

本文与实现严格对应，主要源码：`FranPhotos/Library/LibraryPaths.swift`、`FranPhotos/Library/Manifest.swift`、`FranPhotos/Library/LibraryStore.swift`。

---

## 目录树 Directory Tree

```
My Photos.franphotoslibrary/
├── library.json                    # 库清单（LibraryManifest，JSON 明文）
├── database/
│   └── library.sqlite              # 权威元数据库（WAL 模式，FTS5）
├── parquet/
│   ├── timeline/
│   │   ├── _index.parquet          # 时间线索引：每月一行
│   │   └── YYYY/YYYY-MM.parquet    # 按月分区的时间线快照
│   └── albums/
│       ├── _index.parquet          # 相簿索引：每册一行
│       └── <albumUUID>.parquet     # 每个相簿一份资产快照
├── originals/
│   └── YYYY/MM/<assetUUID>.<ext>   # 原始媒体（实体拷贝，按拍摄年月分区）
├── derivatives/                    # 派生缓存（可随时重建）
│   ├── thumbs/<uuid>.jpg           # 网格缩略图（最长边 288pt × 屏幕 scale）
│   ├── screen/<uuid>.jpg           # 屏幕级大图（最长边 1456pt × 屏幕 scale）
│   └── edits/<uuid>/v<version>.jpg # 编辑渲染结果（每个编辑版本一份）
├── faces/<faceUUID>.jpg            # 人脸缩略图（平铺，按 face UUID 命名）
├── temp/                           # 预留临时目录
└── exports/                        # 预留导出暂存目录
```

以上 10 个目录（`database`、`parquet/timeline`、`parquet/albums`、`originals`、`derivatives/thumbs`、`derivatives/screen`、`derivatives/edits`、`faces`、`temp`、`exports`）由 `LibraryPaths.requiredDirectories` 定义，建库时创建；打开库时 `LibraryStore.validate(repair:)` 会补齐缺失目录并报告 `.repaired`。

注意（实现事实）：

- **faces/** 是平铺结构 `faces/<faceUUID>.jpg`（见 `PeopleStore.scanLibrary()` 中 `thumbRel = "faces/\(faceUUID.uuidString).jpg"`），人脸与人物的归属关系只存在数据库里，不靠目录层级表达。
- **temp/ 与 exports/** 目前是保留目录：导出功能（`ExportEngine.export(..., destination:)`）写到用户自选的文件夹，不写入库内 `exports/`。

---

## library.json 清单 Manifest

库身份的单一事实来源（single source of truth）。文件极小、人类可读，可用任意文本编辑器检查与修复。对应类型 `LibraryManifest`（Codable），编码为 prettyPrinted + sortedKeys，日期为 ISO8601（秒精度，编码前向下取整保证往返无损）。

| 字段 | 类型 | 含义 |
|---|---|---|
| `formatVersion` | Int | bundle 磁盘布局版本，当前 `1`（`currentFormatVersion`）。打开时若 `formatVersion > currentFormatVersion` 则拒绝打开（`LibraryError.unsupportedFormatVersion`） |
| `libraryUUID` | UUID | 库的稳定身份标识，用于 parquet 文件与导出 |
| `name` | String | 用户可见的库名（默认取 bundle 文件名去掉扩展名） |
| `createdAt` | Date(ISO8601) | 创建时间 |
| `appVersion` | String | 创建 / 最近迁移该库的 App 版本 |
| `schemaVersion` | Int | SQLite schema 版本信息字段（写入 `currentSchemaVersion`（当前 2））。**运行时以数据库内 `schema_migrations` 表为准**（见 SCHEMA.zh-CN.md），此字段仅为清单信息 |

示例：

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

清单通过 `LibraryStore.saveManifest` 原子重写（`.atomic` 写入选项）。

---

## originals/：媒体实体规则 Media-Entity Rule

**铁律：所有媒体都是库内的实体拷贝（entity copy），库绝不引用外部文件。** `Asset.original_relpath` 永远指向 bundle 内部路径。导入（`ImportEngine`）时把文件复制入库，源文件之后可以安全删除。

路径规则（`LibraryPaths.originalRelativePath(uuid:capturedAt:fileExtension:)`，使用公历日历）：

```
originals/YYYY/MM/<assetUUID>.<ext>     # 例：originals/2025/03/<uuid>.heic
```

- 年/月取自**拍摄时间** `captured_at`（EXIF DateTimeOriginal，缺失时回退文件修改时间）。
- 扩展名一律小写。
- **Live Photo 配对**：静帧与视频组件共用同一个 asset UUID，各占一个文件，仅扩展名不同（如 `<uuid>.heic` + `<uuid>.mov`）。数据库里 `is_live_photo = 1`，视频路径存 `live_photo_video_relpath`，静帧时间点存 `live_photo_still_time_ms`（毫秒）。
- 去重：`assets.sha256` 有 UNIQUE 约束，导入时先算 SHA-256，已存在则计为 duplicate、不再拷贝。

---

## parquet/：可再生的查询快照

Parquet 是 SQLite 的**可再生快照（regenerable snapshot）**，为快速打开库和外部工具读取而设。布局：

| 文件 | kind | 内容 |
|---|---|---|
| `parquet/timeline/_index.parquet` | `timeline_index` | 每月一行：`month, row_count, first_captured, last_captured, cover_uuid, sha256`，按月份倒序 |
| `parquet/timeline/YYYY/YYYY-MM.parquet` | `asset` | 该月全部资产（40 列，含删除/隐藏标记；UI 读取后自行过滤） |
| `parquet/albums/_index.parquet` | `album_index` | 每册一行：`album_uuid, name, album_type, row_count, cover_uuid, sha256` |
| `parquet/albums/<albumUUID>.parquet` | `asset` | 该册资产，`album_sort_index` 列为册内顺序 |

月分区相对路径由 `LibraryPaths.timelineParquetRelativePath(monthKey:)` 生成：`monthKey "2025-03" → parquet/timeline/2025/2025-03.parquet`。

所有 parquet 文件由内置 Go 助手 `fpparquet` 写出：**Snappy 压缩**，写入同目录临时文件（`.fpparquet-*.tmp`）、fsync 后 rename 原子落盘。任何标准 parquet 读取器都能直接打开：

```sql
-- DuckDB
SELECT * FROM 'parquet/timeline/2025/2025-03.parquet';
```

```python
# pandas
import pandas as pd
df = pd.read_parquet("My Photos.franphotoslibrary/parquet/timeline/2025/2025-03.parquet")
```

### 权威性与一致性 Consistency Model

- **SQLite 是权威（authoritative）**：一切写入先落 `database/library.sqlite`。
- 每次资产变更会把受影响月份标记为脏（内存中的 `dirtyMonths` 集合），并把 `library_meta` 表里的 `timeline_dirty` 置为 `"1"`；随后 `ParquetSync.syncTimeline()` 从数据库重新生成脏月分区并重写 `_index.parquet`，完成后把 `timeline_dirty` 清 `"0"`。
- 每个分区的内容哈希存在 SQLite 的 `partition_checksums` 表（`partition_key` 形如 `'timeline:2025-03'` 或 `'album:<uuid>'`）。
- 打开库后后台跑 `ParquetSync.validateAndRepair()`：从 SQLite 重算每月内容哈希，凡文件缺失或哈希不匹配的分区全部重建；已无资产的月份分区会被删除；最后按需重写索引并清除脏标记。**因此整个 `parquet/` 目录即使删掉也能自我恢复**（此时读取路径全部回退 SQLite）。
- 读取路径 parquet 优先：`timelineIndex()` / `monthAssets(_:)` 先试 parquet，文件缺失、不可读或为空时回退 SQLite 查询（详见 ARCHITECTURE.zh-CN.md）。

---

## derivatives/：派生缓存（可丢弃）

三级缓存的磁盘层（`DerivativeCache`）：内存 NSCache → 磁盘 JPEG → 解码原图重建。键含编辑版本（`…-e<editVersion>`），编辑后自动失效。

- `thumbs/<uuid>.jpg`：网格缩略图，最长边 288 pt × 屏幕 backingScaleFactor，JPEG 质量 0.82。
- `screen/<uuid>.jpg`：详情页快速占位大图，最长边 1456 pt × scale，JPEG 质量 0.88。
- `edits/<uuid>/v<version>.jpg`：应用编辑配方后的渲染结果（sRGB），`editVersion` 每次保存编辑时 +1。

所有派生图都是**色调映射后的 SDR**（HDR 源按 headroom 1 应用增益图后输出 sRGB JPEG），保证网格不发灰。整个 `derivatives/` 可删除，会自动按需重建。

## faces/

人脸扫描（`PeopleStore.scanLibrary` → `FaceScanner`）裁剪出的人脸缩略图，`faces/<faceUUID>.jpg`（JPEG 质量 0.85）。数据库 `faces.thumbnail_relpath` 记录相对路径。已扫描的资产在 `assets.faces_scanned = 1`（schema migration v2 新增列）。

## temp/ 与 exports/

预留目录，随 `requiredDirectories` 创建与校验。当前实现中导出写入用户选择的目标文件夹，不占用库内目录。

---

## 可移植性保证 Portability Guarantees

1. **整文件夹 = 完整备份**：元数据（SQLite）、快照（parquet）、原片（originals）、人脸、编辑配方全部在包内；`derivatives/` 丢了只是变慢。
2. **无外部引用**：复制 / 移动整个 bundle 到其他 Mac、外置盘、NAS 均可直接打开。
3. **开放格式**：`library.json` 是明文 JSON；`database/library.sqlite` 是标准 SQLite（可直接用 `sqlite3` 检查）；`parquet/` 是标准 Snappy parquet，DuckDB / pandas / Arrow 均可读。
4. **自愈**：目录缺失自动补齐；parquet 缺失或过期自动从 SQLite 重建。
