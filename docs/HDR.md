# HDR / XDR Rendering

**English** | [简体中文](HDR.zh-CN.md)

FranPhotos supports three categories of HDR sources (gain map / HLG / PQ / Dolby Vision), displaying them at true EDR (Extended Dynamic Range) brightness on XDR displays and automatically tone-mapping them to SDR on regular displays. Core principle: **there is only one code path for display** — headroom greater than 1 means EDR, headroom equal to 1 means SDR, with no need for two separate implementations.

Corresponding source code: `FranPhotos/Render/HDRImageView.swift` (EDRPipeline / MetalEDRView / HDRImageView), `FranPhotos/Render/HDRCompositor.swift`, `FranPhotos/Render/Shaders.metal`, `FranPhotos/Render/ImageDecoder.swift`, `FranPhotos/Import/MetadataExtractor.swift`.

---

## 1. Import-time detection → `assets.hdr_type`

Detection results are stored in the database; the column has a CHECK constraint: `hdr_type ∈ {'sdr','gainmap','hlg','pq'}` (see SCHEMA.md).

### Still images (`ImageDecoder.inferredHDRType`; priority: gainmap > hlg > pq > sdr)

1. **Gain map**: `CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)` retrieves the ISO 21496-1 / Apple HDR gain map auxiliary data; if the auxiliary image is successfully decoded, the asset is classified as `.gainmap`.
2. **HLG / PQ**: color-space probing — perform an **8-pixel** thumbnail decode (cheap) and read `CGColorSpace.name`:
   - Name contains `"hlg"` (or contains both `"2100"` and `"hl"`) → `.hlg`
   - Name contains `"pq"` or `"perceptual"` → `.pq`
3. Everything else → `.sdr`.

### Video (`MetadataExtractor.video`, AVFoundation)

Iterate the video track's `formatDescriptions`:

- `kCVImageBufferTransferFunctionKey` extension containing `"2100"`/`hlg` → `.hlg`; containing `PQ`/`"2084"`/`perceptual` → `.pq`.
- **Dolby Vision**: codec fourCC starting with `dvh` or equal to `dvhe` (`dvh1`/`dvhe`, etc.) → recorded as `.pq` of the PQ family (for display labeling).
- Also records `video_codec` (fourCC), `color_space` (`kCVImageBufferColorPrimariesKey`), `frame_rate`, and `has_audio`.

---

## 2. Display: a single path

```
Decode original image (longest edge capped at 8000px, HDRAssetView.maxDecodePixels)
  → CIImage base (+ gainMap CIImage, if hdr_type == gainmap)
  → HDRCompositor.composited(base, gainMap, headroom)
        = base.applyingGainMap(gainMap, headroom: clamp(headroom, 1...8))
        (HLG/PQ sources have no gain map — returned as-is; interpretation is driven by their color space)
  → EDRPipeline.render: render the CIImage into a CVPixelBuffer
        (kCVPixelFormatType_64RGBAHalf + MetalCompatibility,
          extended-linear Display P3 color space, aspect-fit onto a black canvas)
  → CVMetalTextureCacheCreateTextureFromImage → MTLTexture(rgba16Float)
  → Full-screen triangle blit (Shaders.metal: edrBlitVS / edrBlitFS, sampled and written straight through with no transform)
  → CAMetalLayer: pixelFormat = rgba16Float,
                  wantsExtendedDynamicRangeContent = true,
                  colorspace = extendedLinearDisplayP3
```

Key components:

- **Headroom source**: `NSScreen.maximumExtendedDynamicRangeColorComponentValue`, with a floor of 1.0 (`MetalEDRView.render()` and `HDRCompositor.edrHeadroom(for:)`). It is > 1 on XDR screens, where pixel values above 1.0 in the extended-linear space produce true HDR brightness.
- **SDR fallback = the same path**: on SDR screens headroom = 1, and `applyingGainMap(headroom: 1)` yields the tone-mapped SDR output. One path, two outputs.
- **CIContext**: `HDRCompositor.sharedContext`, `CIContext(mtlDevice:)` + `cacheIntermediates: false`, reused globally (expensive to create).
- **Shared Metal pipeline**: `EDRPipeline` holds the device / commandQueue / `CVMetalTextureCache` / render pipeline (`rgba16Float` color attachment); `MetalEDRView` obtains a drawable with `nextDrawable()`, renders into it, then `present`s it.
- **Re-render on screen change**: listens for `NSWindow.didChangeScreenNotification`; when the window moves to a screen with a different headroom, re-reads the headroom and re-renders; `setFrameSize` / `viewDidMoveToWindow` trigger this as well.
- **SwiftUI integration**: `HDRImageView` (NSViewRepresentable); `imageProvider: (Float) -> CIImage?` supplies the image at the requested headroom; changes to `contentVersion` (= `asset.editVersion`) force a reload.

### Why not CIRenderDestination(mtlTexture:)

The header comment of `HDRImageView.swift` records the measured findings: `CIRenderDestination(mtlTexture:)` **returns nil on macOS 27**, and `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` writes no pixels into an ordinary MTLTexture. Hence the explicit "pixel buffer + full-screen blit" pipeline — this path has been verified end to end to output pixel values > 1.0.

---

## 3. Derivatives are always SDR (the grid never washes out)

When rendering thumbnails / screen-sized images, `DerivativeCache` goes through `HDRCompositor.sdrImage(from:hdrType:maxPixelSize:)`: gain-map sources have the gain map applied at **headroom = 1.0**, then are written to JPEG as `RGBA8 + sRGB`. **All derivatives are tone-mapped SDR**, so the grid, covers, and album cards never look washed out or blown out on any screen. Keys include `-e<editVersion>`, so they are automatically invalidated and rebuilt after edits.

---

## 4. Editing: the SDR domain in v1

- Editing (`EditEngine`) is a pure CoreImage recipe (`EditRecipe` JSON stored in `assets.edit_recipe_json`); the rendered result is an sRGB JPEG: `derivatives/edits/<uuid>/v<version>.jpg`.
- Both the detail view and the grid of an edited asset display the **edited derivative** (SDR); `HDRAssetView` / `DerivativeCache` treat `hdrType` as `.sdr` whenever `editDerivativeURL != nil`.
- **The original is never touched**: HDR information (gain map / HLG / PQ) is fully preserved in `originals/` and can be restored at any time; on export:
  - `ExportOptions.Mode.original` — a byte-for-byte copy of the original (gain map etc. fully preserved); live photos also include the video component;
  - `.jpeg` — an SDR JPEG with edits / tone mapping applied (videos export the poster still frame).

In short: **editing happens in the SDR domain (a v1 trade-off); HDR fidelity is guaranteed by "original untouched + original-as-is export".**

---

## 5. Video

Video uses no custom rendering: `AVPlayer` + `VideoLayerView` (the AVFoundation pipeline) natively handle EDR output for HLG / Dolby Vision. Still↔video transitions are handled by `MediaStageController`: during warm-up it seeks precisely to the still-image moment while the video layer is invisible (live photos use `live_photo_still_time_ms`), so the first frame aligns pixel-perfectly with the still and the crossfade has no black frames. `PlayerPool` (LRU, capacity 3) limits the number of simultaneously live decoders.

Poster frames (grid/detail placeholders) are extracted by `DerivativeCache.videoPoster` using `AVAssetImageGenerator` — live photos take the still-image moment, regular videos take frame 0 — and are then written as SDR JPEGs per the rules in Section 3.
