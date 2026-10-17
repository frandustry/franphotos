# FranPhotos — 常用任务入口
# 要求: Xcode 16+ (含 Metal Toolchain), Go 1.22+ (仅构建期, vendor 离线)

PROJECT   := FranPhotos.xcodeproj
SCHEME    := FranPhotos
BUILD_DIR := build/DerivedData
APP       := $(BUILD_DIR)/Build/Products/Debug/FranPhotos.app
RELEASE_APP := $(BUILD_DIR)/Build/Products/Release/FranPhotos.app

XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(BUILD_DIR)

.DEFAULT_GOAL := build

.PHONY: build release test test-go test-ui run clean helper l10n docs open-app

## build: 构建 Debug 版 App（自动编译并嵌入 Go parquet 助手）
build:
	$(XCB) -configuration Debug build

## release: 构建 Release 版 App
release:
	$(XCB) -configuration Release build

## test: 运行全部 Swift 测试（单测 + 集成；UI 冒烟需在 Xcode 中授权后运行）
test:
	$(XCB) -configuration Debug test

## test-go: 运行 fpparquet Go 测试
test-go:
	cd go/fpparquet && GOFLAGS=-mod=vendor go test ./...

## test-ui: 运行 UI 冒烟测试（需要主机的 UI 自动化权限）
test-ui:
	$(XCB) -configuration Debug test -only-testing:FranPhotosUITests

## run: 构建并启动 App
run: build
	open "$(APP)"

## helper: 仅编译 Go parquet 助手到 go/fpparquet/bin/
helper:
	bash scripts/build-go-helper.sh

## l10n: 检查代码中的本地化键与 String Catalog 完整性（缺失则非零退出）
l10n:
	python3 scripts/update_localization.py

## clean: 删除本地构建产物
clean:
	rm -rf build go/fpparquet/bin

## open-app: 用 Xcode 打开工程
open-app:
	open $(PROJECT)

help:
	@grep -E '^## ' Makefile | sed 's/## //'
