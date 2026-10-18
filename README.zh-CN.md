# FranPhotos

[English](README.md) | **简体中文**

一个从 0 用 SwiftUI 编写的原生 macOS 照片管理应用——对标并移植 Apple Photos 的大部分核心功能，库格式整洁可移植，运行时不依赖任何外部软件。

## 特性

- **整洁可移植的库格式**：`*.franphotoslibrary` 包内含 SQLite 主数据库 + Parquet 快照（时间线按月分区、相簿每册一份），媒体文件实体入库，整个库文件夹即完整备份。
- **Timeline 懒加载**：年/月/日/所有照片四级视图，滚动到哪里加载哪里的 Parquet 分区，不阻塞 UI。
- **Live Photos**：导入自动配对（静帧 + MOV），LIVE 徽标悬停即播，交叉淡入淡出。
- **视频无缝衔接**：海报帧开场、悬停内联静音预播、播放全程无黑帧。
- **HDR / XDR**：识别增益图 HEIC、HLG/PQ 静态图与 HLG/Dolby Vision 视频，XDR 显示器上 EDR 渲染，普通显示器自动色调映射。
- **完整信息面板**：EXIF（机身/镜头/ISO/光圈/快门/焦距…）+ MapKit 地图定位 + 标题/说明/关键词编辑。
- **非破坏性编辑**：裁剪/旋转/滤镜/全套光色调整，参数存库、随时还原。
- **相簿**：手动相簿 + 智能相簿（规则引擎）+ 可嵌套的文件夹。
- **人物 / 地点 / 回忆 / 重复检测 / 最近删除** 一应俱全。
- **中英文界面**，String Catalog 驱动，可扩展更多语言。

## 构建

要求：Xcode 16+（建议 27+）、Go 1.22+（仅构建期需要，运行时用户无需安装任何软件）。

```bash
make build   # 或：xcodebuild -project FranPhotos.xcodeproj -scheme FranPhotos build
make test    # 完整测试套件
```

Go parquet 助手会在 Xcode 构建阶段自动编译并嵌入 App（源码已 vendor，离线可构建）。

## 文档

- [库格式 LIBRARY_FORMAT.md](docs/LIBRARY_FORMAT.md)
- [数据库 SCHEMA.md](docs/SCHEMA.md)
- [架构 ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [HDR 渲染 HDR.md](docs/HDR.md)

## 许可证

[Apache-2.0](LICENSE)
