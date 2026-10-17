# 架构 Architecture

FranPhotos 是一个 SwiftUI macOS 照片应用，严格分层：**SQLite 是唯一的权威数据源，parquet 是可再生快照，渲染层一切皆可重建**。工程为纯 Swift 6（`SWIFT_VERSION = 6.0`，严格并发检查），部署目标 macOS 15.0。

## 分层总览

```
┌─────────────────────────────────────────────────────────────┐
│ UI (SwiftUI)  TimelineGridView / DetailView / PeopleView …  │
├─────────────────────────────────────────────────────────────┤
│ App 层      LibraryManager (@MainActor @Observable)          │
│             打开/关闭库、导入调度、变更编排                     │
├─────────────────────────────────────────────────────────────┤
│ Stores      TimelineStore · AlbumsStore · SearchStore ·      │
│             PeopleStore · MemoryStore                        │
│             （@MainActor @Observable 表现模型）               │
├─────────────────────────────────────────────────────────────┤
│ 数据层      DatabaseActor (SQLite, WAL)  ←→  ParquetSync     │
│             （权威写入）            （脏分区 → 快照重建）        │
│                        ParquetBridge (actor)                 │
│                        └─ stdio JSON-lines → Go fpparquet    │
├─────────────────────────────────────────────────────────────┤
│ Render      DerivativeCache（三级缓存）· HDRCompositor ·      │
│             EDRPipeline（Metal EDR 渲染，见 HDR.md）          │
├─────────────────────────────────────────────────────────────┤
│ Media       MediaStageController（静帧↔视频交叉淡入淡出）      │
│             PlayerPool（AVPlayer LRU，容量 3）                │
├─────────────────────────────────────────────────────────────┤
│ Import/Edit ImportEngine（实体拷贝入库）· EditEngine（纯 CI） │
└─────────────────────────────────────────────────────────────┘
```

## 各层职责

### App 层：`LibraryManager`（FranPhotos/App/LibraryManager.swift）

拥有当前打开的库及绑定其上的全部长寿命服务：`LibraryStore`、`DatabaseActor`、`DerivativeCache`、`ParquetSync`、`TimelineStore`、`AlbumsStore`、`SearchStore`。打开流程（`open(_:createIfMissing:)`）：

1. `LibraryStore.create/open` → `validate(repair: true)` 补齐目录。
2. `DatabaseActor.openOrCreate` 打开 `database/library.sqlite` 并跑迁移。
3. 非新建库时把 manifest 的 `schemaVersion` 更新为 `LibraryManifest.currentSchemaVersion`。
4. 构建全部服务，然后**后台**并行两件杂务：`ParquetSync.validateAndRepair()`（校验/修复 parquet 分区）与 `LibraryMaintenance.purgeExpiredTrash`（清除超过 30 天的最近删除项：行 + 原片 + live 组件 + 派生图 + edits 目录）。

### Stores（表现模型，全部 `@MainActor @Observable`）

- **TimelineStore** — 月索引 + `MonthSlice` LRU 池（`maxHotSlices = 12`），四级缩放（years / months / days / allPhotos），跨年导航自动加载相邻月分区。`slice(for:)` 是纯读取（LRU 触碰只发生在 `ensureLoaded` 异步路径里——在视图 body 求值期间改可观察状态曾导致 AttributeGraph 无限失效循环卡死主线程）；逐出不清字典条目，而是清空 `MonthSlice.assets` 并自增 `reloadToken`，屏幕上的分区借此自动重新加载。
- **AlbumsStore** — 相簿列表；每次变更经 `AlbumStore` 落库后 `markAlbumDirty` + `syncAlbums` 重建该册 parquet。
- **SearchStore** — FTS5 全文（title/caption/keywords/filename）+ 结构化 scope（全部/照片/视频/收藏），250ms 防抖。
- **PeopleStore** — 人脸扫描编排（`faces_scanned = 0` 的资产逐一过 `FaceScanner`，缩略图写 `faces/<faceUUID>.jpg`）、人物命名/合并/封面。
- **MemoryStore** — 规则引擎生成回忆（year_highlight / trip / on_this_day），24 小时过期重建，持久化到 `memories` 表。

### 数据层

**DatabaseActor**（actor）串行化所有 SQLite 访问；底层 `Database` 是系统 libsqlite3 的薄同步封装（`SQLITE_OPEN_FULLMUTEX`），pragmas：WAL、foreign_keys ON、synchronous NORMAL、busy_timeout 5000。上层（repositories、ImportEngine、ParquetSync）只与 actor 对话。

**ParquetSync**（actor）维护 parquet 与 SQLite 的一致性（详见 SCHEMA.md / LIBRARY_FORMAT.md）：

- 写路径：内存 `dirtyMonths` + `library_meta.timeline_dirty = 1` → `syncTimeline()` 逐月重建分区 → 重写 `_index.parquet` → 清脏标记。相簿同理（`dirtyAlbums` → `syncAlbums()`）。
- 读路径：parquet 优先，SQLite 回退 + 后台修复。
- 打开库后 `validateAndRepair()` 全量比对内容哈希，自愈。

**ParquetBridge**（actor）→ Go 助手 `fpparquet`：stdIO JSON-lines 协议，阻塞 IO 在专用 DispatchQueue；查找顺序 env `FRANPHOTOS_FPPARQUET` → `Resources/bin/fpparquet` → `go/fpparquet/bin/fpparquet`。

### Render 层

- **DerivativeCache**（actor）三级：NSCache 内存（默认 256 MB 成本上限）→ 磁盘 `derivatives/{thumbs,screen}/<uuid>.jpg` → 解码原图重建并回写磁盘。键 = `uuid-size-e<editVersion>`，所以**编辑后网格自动失效**；同一键的并发请求共享一个 in-flight Task。HDR 源经 `HDRCompositor.sdrImage` 色调映射成 SDR 再存 JPEG。
- **HDRCompositor**（enum）：共享 `CIContext(mtlDevice:)`（创建昂贵，全局复用）；`composited(base:gainMap:headroom:)` 一条代码路径同时服务 EDR 显示与 SDR 输出。
- **EDRPipeline / MetalEDRView / HDRImageView**：CIImage → `CVPixelBuffer(64RGBAHalf, extendedLinearDisplayP3)` → `CVMetalTextureCache` → 全屏三角形 blit（`Shaders.metal` 的 `edrBlitVS/edrBlitFS`）→ `CAMetalLayer(rgba16Float, wantsExtendedDynamicRangeContent)`。完整推导见 [HDR.md](HDR.md)。

### Media 层

- **MediaStageController**（@MainActor @Observable）驱动静帧↔视频无缝衔接的状态机：`still → prewarming → playing → returning → still`。预热时在视频层不可见的情况下**精确 seek 到静帧时刻**（live photo 的 `live_photo_still_time_ms`，tolerance 为零），因此第一帧可见画面与静帧完全一致——无黑闪、无跳变。播放结束通知（`AVPlayerItemDidPlayToEndTime`）触发 `returnToStill`。
- **PlayerPool**（@MainActor 单例）：AVPlayer LRU 池，`capacity = 3`，避免悬停预加载制造无限解码器实例；`actionAtItemEnd = .pause`。

### Import / Edit

- **ImportEngine**：实体拷贝入库（媒体永不留外部引用），SHA-256 去重，EXIF/视频元数据提取，Live Photo 配对（`LivePhotoPairer.plan`），串行处理保证可预测的磁盘 IO。
- **EditEngine**：纯 CoreImage、确定性可重放；几何 → 光 → 色 → 创意滤镜 → 细节的顺序应用 `EditRecipe`；渲染结果写 `derivatives/edits/<uuid>/v<version>.jpg`。

## 并发模型

- **Swift 6 严格并发**。状态隔离边界：
  - actor：`DatabaseActor`、`ParquetSync`、`ParquetBridge`、`DerivativeCache`。
  - `@MainActor`：全部 Stores、`LibraryManager`、`MediaStageController`、`PlayerPool`。
- `@unchecked Sendable` 的少数例外都有注释说明理由：`Database`（只经 actor 访问）、`LibraryStore`、`ImportEngine`、`EDRPipeline`、`SendableImageCache`（NSCache 文档保证线程安全但未标 Sendable，包了一层）。
- 阻塞式管道 IO 不占用 Swift 协作线程池：`ParquetBridge` 在 `DispatchQueue("franphotos.fpparquet.io")` 上读写，用 `withCheckedThrowingContinuation` 桥回 async。
- 昂贵解码/渲染显式 `Task.detached`（导入、编辑渲染、人脸检测、HDR 解码）。

## 懒加载数据流（打开库 → 滚动）

```
open library
  → LibraryStore.validate(repair:) 补齐目录
  → DatabaseActor 迁移；后台 validateAndRepair()
  → TimelineStore.loadIndex()
      → ParquetSync.timelineIndex()
          优先 parquet/timeline/_index.parquet
          缺失/为空 → SQLite 聚合查询（GROUP BY strftime('%Y-%m', captured_at...)）
      → 得出 months[] / years[] 摘要（含每月封面 cover_uuid）
scroll 到某月
  → TimelineStore.ensureLoaded(monthKey)
      → ParquetSync.monthAssets(key)
          优先 parquet/timeline/YYYY/YYYY-MM.parquet
          缺失/不可读 → SQLite SELECT * ... ORDER BY captured_at DESC（并等待下次修复重建）
      → MonthSlice.assets（过滤隐藏/已删除），按 captured_at 倒序
  → LRU：hotOrder 超过 maxHotSlices = 12 时逐出最久未用的已加载 MonthSlice
    （清空其 assets、保留对象身份、reloadToken 自增，分区视图自动重新加载）
缩略图
  → DerivativeCache.image(for:size:) → 内存 → 磁盘 → 解码重建
```

## 变更数据流（写）

```
用户操作（收藏/隐藏/删除/改标题…）
  → LibraryManager.mutateAsset(uuid) { AssetActions 写 SQLite }   ← 权威写入
  → 取 monthKey → markMonthsDirty([month])
      → ParquetSync.markDirty：dirtyMonths ∪= month，library_meta.timeline_dirty = 1
      → ParquetSync.syncTimeline()：从 SQLite 重读该月 → fpparquet 原子重写
        parquet/timeline/YYYY/YYYY-MM.parquet → 更新 partition_checksums
        → 重写 _index.parquet → timeline_dirty = 0
  → 重新 fetch 该资产 → TimelineStore.updateAssetInSlices 就地更新/移除
编辑保存
  → EditEngine.renderEditDerivative 写 derivatives/edits/<uuid>/v<version>.jpg
  → assets.edit_recipe_json + edit_version +1（AssetActions）
  → 派生缓存键含 -e<editVersion>，旧缩略图自动失效（必要时 DerivativeCache.invalidate）
相簿变更
  → AlbumStore 写库 → ParquetSync.markAlbumDirty(uuid) → syncAlbums()
    重建 parquet/albums/<uuid>.parquet 与 albums/_index.parquet
关闭库
  → closeLibrary() 尽力而为地 syncTimeline() 落盘脏分区后释放全部服务
```

## 构建布局

- **手写 `FranPhotos.xcodeproj/project.pbxproj`**（objectVersion 77，无 Xcode 生成步骤）：
  - 三个 target（`FranPhotos` / `FranPhotosTests` / `FranPhotosUITests`）均用 **PBXFileSystemSynchronizedRootGroup**（Xcode 16 文件夹同步），Sources/Frameworks/Resources 阶段文件列表为空——新增源文件无需改 pbxproj。
  - App target 的构建阶段顺序：**`Build fpparquet helper`（PBXShellScriptBuildPhase）→ Sources → Frameworks → Resources**。脚本阶段 `alwaysOutOfDate = 1`，输出声明为 `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/fpparquet`。
  - `MACOSX_DEPLOYMENT_TARGET = 15.0`，bundle id `com.franphotos.FranPhotos`。
- **`scripts/build-go-helper.sh`**：Xcode 环境下装到 `$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources/bin`；独立运行时装到 `go/fpparquet/bin`。在极简 PATH 下依次探测 `/opt/homebrew/bin/go` 等常见位置；二进制比所有 `.go`/`go.mod`/`go.sum`/`vendor/` 都新则跳过（增量构建）；编译参数 `GOFLAGS=-mod=vendor CGO_ENABLED=0 go build -trimpath -ldflags="-s -w"`——vendor 树已提交，离线可构建，产物为静态无依赖二进制。
- 运行时用户无需安装 Go；Go 只是构建期依赖。
