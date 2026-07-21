# Baobox 构建与安装
#
# 需要完整 Xcode（Command Line Tools 不足以编译 GUI App）。
# 这里用 DEVELOPER_DIR 覆盖工具链，因此不必 sudo xcode-select 改全局设置。
#
# 常用：
#   make install   编译 Release 并装到 /Applications，然后重启 App（日常用这个）
#   make dev       编译 Debug 并直接运行（调试用，不动 /Applications 里的版本）
#   make stop      退出正在运行的 Baobox
#   make clean     清除构建产物

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

PROJECT   := Baobox.xcodeproj
SCHEME    := Baobox
APP       := Baobox.app
DEST      := /Applications/$(APP)
BUILD_DIR := $(CURDIR)/build

.PHONY: all project build install dev stop clean

all: install

## 由 project.yml 生成 Xcode 工程（.xcodeproj 是 gitignore 的生成物）
project:
	@command -v xcodegen >/dev/null || { echo "缺少 xcodegen：brew install xcodegen"; exit 1; }
	@test -d "$(DEVELOPER_DIR)" || { echo "找不到 Xcode：$(DEVELOPER_DIR)"; exit 1; }
	xcodegen generate

## 编译 Release 到 build/Release
build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-allowProvisioningUpdates \
		CONFIGURATION_BUILD_DIR=$(BUILD_DIR)/Release build

## 编译并安装到 /Applications，随后启动
install: build stop
	rm -rf "$(DEST)"
	cp -R "$(BUILD_DIR)/Release/$(APP)" "$(DEST)"
	@codesign --verify --strict "$(DEST)" && echo "签名校验通过"
	@codesign -dv --verbose=2 "$(DEST)" 2>&1 | grep -E "TeamIdentifier|Authority=Apple Development" || true
	open "$(DEST)"
	@echo "已安装并启动：$(DEST)"

## 调试构建并直接运行（不覆盖 /Applications 里的版本）
dev: project stop
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-allowProvisioningUpdates \
		CONFIGURATION_BUILD_DIR=$(BUILD_DIR)/Debug build
	open "$(BUILD_DIR)/Debug/$(APP)"

## 退出正在运行的实例（menu bar App 没有 Dock 图标，只能这样关）
stop:
	@osascript -e 'quit app "Baobox"' 2>/dev/null || true
	@sleep 1
	@pkill -x Baobox 2>/dev/null || true
	@sleep 1

clean:
	rm -rf "$(BUILD_DIR)"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
