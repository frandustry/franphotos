# HDR / XDR 渲染

FranPhotos 支持三类 HDR 源（增益图 / HLG / PQ / Dolby Vision），在 XDR 显示器上以真实 EDR（Extended Dynamic Range）亮度显示，在普通显示器上自动色调映射为 SDR。核心原则：**显示只有一条代码路径**——headroom 大于 1 即 EDR，等于 1 即 SDR，无需两套实现。

对应源码：`FranPhotos/Render/HDRImageView.swift`（EDRPipeline / MetalEDRView / HDRImageView）、`FranPhotos/Render/HDRCompositor.swift`、`FranPhotos/Render/Shaders.metal`、`FranPhotos/Render/ImageDecoder.swift`、`FranPhotos/Import/MetadataExtractor.swift`。

---

## 1. 导入期检测 → `assets.hdr_type`

检测结果入库，列有 CHECK 约束：`hdr_type ∈ {'sdr','gainmap','hlg','pq'}`（见 SCHEMA.md）。

### 静态图（`ImageDecoder.inferredHDRType`，优先级：gainmap > hlg > pq > sdr）

1. **增益图 gainmap**：`CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)` 取 ISO 21496-1 / Apple HDR gain map 辅助数据；解出辅助图即判定 `.gainmap`。
2. **HLG / PQ**：色彩空间探测——做一次 **8 像素**的缩略解码（便宜），读 `CGColorSpace.name`：
   - 名称含 `"hlg"`（或同时含 `"2100"` 与 `"hl"`）→ `.hlg`
   - 名称含 `"pq"` 或 `"perceptual"` → `.pq`
3. 其余 → `.sdr`。

### 视频（`MetadataExtractor.video`，AVFoundation）

遍历视频轨的 `formatDescriptions`：

- `kCVImageBufferTransferFunctionKey` 扩展含 `"2100"`/`hlg` → `.hlg`；含 `PQ`/`"2084"`/`perceptual` → `.pq`。
- **Dolby Vision**：codec fourCC 以 `dvh` 开头或为 `dvhe`（`dvh1`/`dvhe` 等）→ 按 PQ 家族记 `.pq`（用于显示标记）。
- 同时记录 `video_codec`（fourCC）、`color_space`（`kCVImageBufferColorPrimariesKey`）、`frame_rate`、`has_audio`。

---

## 2. 显示：单一路径

```
原图解码（最长边 8000px 上限，HDRAssetView.maxDecodePixels）
  → CIImage base (+ gainMap CIImage，若 hdr_type == gainmap)
  → HDRCompositor.composited(base, gainMap, headroom)
        = base.applyingGainMap(gainMap, headroom: clamp(headroom, 1...8))
        （HLG/PQ 源无增益图，原样返回——由其色彩空间驱动解释）
  → EDRPipeline.render：CIImage 渲染进 CVPixelBuffer
        （kCVPixelFormatType_64RGBAHalf + MetalCompatibility，
          extended-linear Display P3 色彩空间，aspect-fit 到黑底画布）
  → CVMetalTextureCacheCreateTextureFromImage → MTLTexture(rgba16Float)
  → 全屏三角形 blit（Shaders.metal: edrBlitVS / edrBlitFS，采样直写不做变换）
  → CAMetalLayer：pixelFormat = rgba16Float，
                  wantsExtendedDynamicRangeContent = true，
                  colorspace = extendedLinearDisplayP3
```

关键组件：

- **headroom 来源**：`NSScreen.maximumExtendedDynamicRangeColorComponentValue`，下限 1.0（`MetalEDRView.render()` 与 `HDRCompositor.edrHeadroom(for:)`）。XDR 屏上 > 1，extended-linear 空间中超过 1.0 的像素值产生真实 HDR 亮度。
- **SDR 回退 = 同一条路径**：SDR 屏 headroom = 1，`applyingGainMap(headroom: 1)` 即色调映射后的 SDR。一条路径，两种输出。
- **CIContext**：`HDRCompositor.sharedContext`，`CIContext(mtlDevice:)` + `cacheIntermediates: false`，全局复用（创建昂贵）。
- **共享 Metal pipeline**：`EDRPipeline` 持有 device / commandQueue / `CVMetalTextureCache` / render pipeline（`rgba16Float` color attachment）；`MetalEDRView` 用 `nextDrawable()` 取 drawable 渲染后 `present`。
- **屏幕变更重渲染**：监听 `NSWindow.didChangeScreenNotification`，窗口移到 headroom 不同的屏幕时重取 headroom 并重渲染；`setFrameSize` / `viewDidMoveToWindow` 同样触发。
- **SwiftUI 接入**：`HDRImageView`（NSViewRepresentable），`imageProvider: (Float) -> CIImage?` 按请求的 headroom 供图；`contentVersion`（= `asset.editVersion`）变化强制重载。

### 为什么不用 CIRenderDestination(mtlTexture:)

`HDRImageView.swift` 顶部注释记录了实测结论：`CIRenderDestination(mtlTexture:)` **在 macOS 27 上返回 nil**，且 `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` 对普通 MTLTexture 不写任何像素。因此采用显式的「pixel buffer + 全屏 blit」管线——该路径已端到端验证可以输出 > 1.0 的像素值。

---

## 3. 派生图一律 SDR（网格不发灰）

`DerivativeCache` 渲染缩略图 / 屏幕图时走 `HDRCompositor.sdrImage(from:hdrType:maxPixelSize:)`：增益图源以 **headroom = 1.0** 应用增益图，再以 `RGBA8 + sRGB` 落 JPEG。**所有派生图都是色调映射后的 SDR**，因此网格、封面、相簿卡片在任何屏幕上都不会发灰或溢出。键含 `-e<editVersion>`，编辑后自动失效重建。

---

## 4. 编辑：v1 为 SDR 域

- 编辑（`EditEngine`）是纯 CoreImage 配方（`EditRecipe` JSON 存 `assets.edit_recipe_json`），渲染结果为 sRGB JPEG：`derivatives/edits/<uuid>/v<version>.jpg`。
- 已编辑资产的详情视图与网格都显示**编辑产物**（SDR）；`HDRAssetView` / `DerivativeCache` 在 `editDerivativeURL != nil` 时把 `hdrType` 视为 `.sdr`。
- **原片保持不动**：HDR 信息（增益图 / HLG / PQ）完整保留在 `originals/` 里，可随时还原；导出时：
  - `ExportOptions.Mode.original` — 逐字节拷贝原片（增益图等完整保留），live photo 附带视频组件；
  - `.jpeg` — 应用编辑 / 色调映射后输出 SDR JPEG（视频导出海报复位帧）。

即：**编辑在 SDR 域进行（v1 取舍），HDR 保真由「原片不动 + 原片导出」保证。**

---

## 5. 视频

视频不做自绘渲染：`AVPlayer` + `VideoLayerView`（AVFoundation 管线）原生处理 HLG / Dolby Vision 的 EDR 输出。静帧↔视频衔接由 `MediaStageController` 完成：预热时在视频层不可见状态下精确 seek 到静帧时刻（live photo 用 `live_photo_still_time_ms`），第一帧与静帧像素对齐，交叉淡入淡出无黑帧。`PlayerPool`（LRU，容量 3）限制同时存活的解码器数量。

海报帧（网格/详情占位）由 `DerivativeCache.videoPoster` 用 `AVAssetImageGenerator` 抽取——live photo 取静帧时刻，普通视频取第 0 帧——再按第 3 节规则落成 SDR JPEG。
