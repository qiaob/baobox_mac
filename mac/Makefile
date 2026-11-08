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
#   make vendor    下载离线翻译的推理进程（llama.cpp）、编译「Baobox 同传」虚拟麦克风驱动（build 会自动调用）

DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

PROJECT   := Baobox.xcodeproj
SCHEME    := Baobox
APP       := Baobox.app
DEST      := /Applications/$(APP)
BUILD_DIR := $(CURDIR)/build

# 离线翻译的推理进程：llama.cpp 官方 macOS 预编译包，构建号与 SHA-256 固定（升级时两个一起改）。
# 只取 llama-server 和它依赖的 dylib 放进 Vendor/llama/（gitignore），
# 构建时由 project.yml 的脚本阶段拷进 Baobox.app/Contents/Helpers/llama/ 并签名。
# 见 docs/translation-engine/DESIGN.md §2.2。
LLAMA_BUILD  := b12121
LLAMA_SHA256 := 75e2176148b2d79ff20f503fa131f3d66d74176ed06c58f48e273e20383c32c2
LLAMA_URL    := https://github.com/ggml-org/llama.cpp/releases/download/$(LLAMA_BUILD)/llama-$(LLAMA_BUILD)-bin-macos-arm64.tar.gz
LLAMA_DIR    := $(CURDIR)/Vendor/llama
LLAMA_STAMP  := $(LLAMA_DIR)/.$(LLAMA_BUILD)
LLAMA_LIBS   := libllama-server-impl.dylib libllama-common.0.dylib libmtmd.0.dylib libllama.0.dylib \
                libggml.0.dylib libggml-base.0.dylib libggml-cpu.0.dylib libggml-blas.0.dylib \
                libggml-metal.0.dylib libggml-rpc.0.dylib

# 「Baobox 同传」虚拟麦克风：用 BlackHole（GPL-3.0）源码改名编译的音频服务插件，版本与 SHA-256 固定。
# 产物 Vendor/audio-driver/BaoboxInterpreter.driver（gitignore），构建时由 project.yml 的脚本阶段拷进
# Baobox.app/Contents/Library/Audio/ 并签名；用户在设置里点「安装」才装进 /Library/Audio/Plug-Ins/HAL/。
# 见 docs/live-translate-voice/DESIGN.md §3。
# 下载：GitHub 的 release 下载偶尔连续 504，多重试几次、每次隔 10 秒，所有错误都重试（含 5xx）。
CURL := curl -fL --retry 6 --retry-delay 10 --retry-all-errors --connect-timeout 30

BLACKHOLE_VERSION := 0.7.1
BLACKHOLE_SHA256  := e9de179da54ed55ff27876990f3a2dcfefa66e6bd6cfcba448a8564eabdf3e89
BLACKHOLE_URL     := https://github.com/ExistentialAudio/BlackHole/archive/refs/tags/v$(BLACKHOLE_VERSION).tar.gz
DRIVER_DIR        := $(CURDIR)/Vendor/audio-driver
DRIVER_NAME       := BaoboxInterpreter
DRIVER_BUNDLE_ID  := com.baobox.audio.interpreter
DRIVER_STAMP      := $(DRIVER_DIR)/.$(BLACKHOLE_VERSION)

.PHONY: all project vendor build install dev stop clean

all: install

## 由 project.yml 生成 Xcode 工程（.xcodeproj 是 gitignore 的生成物）
project:
	@command -v xcodegen >/dev/null || { echo "缺少 xcodegen：brew install xcodegen"; exit 1; }
	@test -d "$(DEVELOPER_DIR)" || { echo "找不到 Xcode：$(DEVELOPER_DIR)"; exit 1; }
	xcodegen generate

## 下载并校验 llama.cpp、编译虚拟麦克风驱动（已是当前版本就跳过）
vendor: $(LLAMA_STAMP) $(DRIVER_STAMP)

$(DRIVER_STAMP):
	@rm -rf "$(DRIVER_DIR)" "$(DRIVER_DIR).tmp"
	@mkdir -p "$(DRIVER_DIR).tmp/src"
	$(CURL) -o "$(DRIVER_DIR).tmp/blackhole.tar.gz" "$(BLACKHOLE_URL)"
	echo "$(BLACKHOLE_SHA256)  $(DRIVER_DIR).tmp/blackhole.tar.gz" | shasum -a 256 -c -
	tar -xzf "$(DRIVER_DIR).tmp/blackhole.tar.gz" -C "$(DRIVER_DIR).tmp/src" --strip-components 1
	# 改名：BlackHole.c 里这些常量都由 #ifndef 包着，预先定义就盖过默认值（设备名不带「2ch」后缀）。
	cd "$(DRIVER_DIR).tmp/src/BlackHole" && { printf '%s\n' \
		'#define kDriver_Name "$(DRIVER_NAME)"' \
		'#define kPlugIn_BundleID "$(DRIVER_BUNDLE_ID)"' \
		'#define kHas_Driver_Name_Format false' \
		'#define kDevice_Name "Baobox 同传"' \
		'#define kManufacturer_Name "Baobox"'; cat BlackHole.c; } > BlackHole.c.new && mv BlackHole.c.new BlackHole.c
	# 容器名（音频 MIDI 设置里看得到）是写死的，单独替换。
	sed -i '' 's/CFSTR("BlackHole Box")/CFSTR("Baobox Box")/' "$(DRIVER_DIR).tmp/src/BlackHole/BlackHole.c"
	xcodebuild -project "$(DRIVER_DIR).tmp/src/BlackHole.xcodeproj" -target BlackHole -configuration Release \
		SYMROOT="$(DRIVER_DIR).tmp/build" PRODUCT_NAME=$(DRIVER_NAME) PRODUCT_BUNDLE_IDENTIFIER=$(DRIVER_BUNDLE_ID) \
		MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO build
	@mkdir -p "$(DRIVER_DIR)"
	cp -R "$(DRIVER_DIR).tmp/build/Release/$(DRIVER_NAME).driver" "$(DRIVER_DIR)/"
	cp "$(DRIVER_DIR).tmp/src/LICENSE" "$(DRIVER_DIR)/BlackHole-LICENSE.txt"
	@rm -rf "$(DRIVER_DIR).tmp"
	@touch "$@"

$(LLAMA_STAMP):
	@rm -rf "$(LLAMA_DIR)" "$(LLAMA_DIR).tmp"
	@mkdir -p "$(LLAMA_DIR).tmp"
	$(CURL) -o "$(LLAMA_DIR).tmp/llama.tar.gz" "$(LLAMA_URL)"
	echo "$(LLAMA_SHA256)  $(LLAMA_DIR).tmp/llama.tar.gz" | shasum -a 256 -c -
	tar -xzf "$(LLAMA_DIR).tmp/llama.tar.gz" -C "$(LLAMA_DIR).tmp"
	@mkdir -p "$(LLAMA_DIR)"
	# 预编译包里带版本号的 dylib 是符号链接：-L 拷成实体文件，文件名与 @rpath 引用一致。
	cd "$(LLAMA_DIR).tmp/llama-$(LLAMA_BUILD)" && cp -L llama-server LICENSE $(LLAMA_LIBS) "$(LLAMA_DIR)/"
	@rm -rf "$(LLAMA_DIR).tmp"
	@touch "$@"

## 编译 Release 到 build/Release
build: project vendor
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
dev: project vendor stop
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
