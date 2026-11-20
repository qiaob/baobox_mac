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
# 目录名以 .noindex 结尾：Spotlight 不索引这种目录，编出来的 Baobox.app 就不会出现在
# 「应用程序」列表里（每个 worktree 编一次就多一个同名图标）。
BUILD_DIR := $(CURDIR)/build.noindex
# 光躲开 Spotlight 不够：xcodebuild 每次编完都会把产物登记进 Launch Services，
# 系统的 App 列表也读那份登记。所以编完再把它注销掉（只按路径注销，不动 /Applications 里那份）。
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# 连包里嵌着的 .app 一起注销（抓包内核 mitmproxy.app 和它里面的小工具）：xcodebuild 登记外层时把它们也登记了。
# find -d：先里后外。
unregister = find -d "$(1)" -name "*.app" -type d -print0 2>/dev/null | xargs -0 -n1 $(LSREGISTER) -u >/dev/null 2>&1 || true

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

# 网络抓包的内核：mitmproxy（MIT）官方 macOS 包，版本与 SHA-256 固定（升级时两个一起改，不得低于 12.2.2）。
# 整个 mitmproxy.app 原样放进 Vendor/mitmproxy.noindex/（gitignore），构建时由 project.yml 的脚本阶段拷进
# Baobox.app/Contents/Helpers/。它自带 Developer ID 签名并已公证，**不能重签、也不能删里面的文件**
# （签名封住了整个包）。只带 Apple 芯片版：两个架构都带要多 176 MB，Intel 上抓包模块置灰。
# 官方包里没有 LICENSE，从 GitHub 同一个标签取。见 docs/packet-capture/TECH_DESIGN.md §2。
MITM_VERSION := 12.3.1
MITM_SHA256  := 9b7f7a8e3fd1b1544089c937c579ef1f0f503f0ea598c25bda9eab077c735b93
MITM_URL     := https://downloads.mitmproxy.org/$(MITM_VERSION)/mitmproxy-$(MITM_VERSION)-macos-arm64.tar.gz
MITM_LICENSE_URL := https://raw.githubusercontent.com/mitmproxy/mitmproxy/v$(MITM_VERSION)/LICENSE
# 目录名以 .noindex 结尾：里面是一个完整的 .app，不这样 Spotlight 会把它当成一个应用列出来。
MITM_DIR     := $(CURDIR)/Vendor/mitmproxy.noindex
MITM_STAMP   := $(MITM_DIR)/.$(MITM_VERSION)

.PHONY: all project vendor build install dev stop clean

all: install

## 由 project.yml 生成 Xcode 工程（.xcodeproj 是 gitignore 的生成物）
project:
	@command -v xcodegen >/dev/null || { echo "缺少 xcodegen：brew install xcodegen"; exit 1; }
	@test -d "$(DEVELOPER_DIR)" || { echo "找不到 Xcode：$(DEVELOPER_DIR)"; exit 1; }
	xcodegen generate

## 下载并校验 llama.cpp 与 mitmproxy、编译虚拟麦克风驱动（已是当前版本就跳过）
vendor: $(LLAMA_STAMP) $(DRIVER_STAMP) $(MITM_STAMP)

$(MITM_STAMP):
	@rm -rf "$(MITM_DIR)" "$(MITM_DIR).tmp"
	@mkdir -p "$(MITM_DIR).tmp"
	$(CURL) -o "$(MITM_DIR).tmp/mitmproxy.tar.gz" "$(MITM_URL)"
	echo "$(MITM_SHA256)  $(MITM_DIR).tmp/mitmproxy.tar.gz" | shasum -a 256 -c -
	$(CURL) -o "$(MITM_DIR).tmp/LICENSE" "$(MITM_LICENSE_URL)"
	tar -xzf "$(MITM_DIR).tmp/mitmproxy.tar.gz" -C "$(MITM_DIR).tmp"
	# 解出来的包必须还带着原签名，否则嵌进去之后外层校验过不了。
	codesign --verify --deep --strict "$(MITM_DIR).tmp/mitmproxy.app"
	@mkdir -p "$(MITM_DIR)"
	ditto "$(MITM_DIR).tmp/mitmproxy.app" "$(MITM_DIR)/mitmproxy.app"
	cp "$(MITM_DIR).tmp/LICENSE" "$(MITM_DIR)/LICENSE"
	@rm -rf "$(MITM_DIR).tmp"
	@touch "$@"

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

## 编译 Release 到 build.noindex/Release
build: project vendor
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-allowProvisioningUpdates \
		CONFIGURATION_BUILD_DIR=$(BUILD_DIR)/Release build
	@$(call unregister,$(BUILD_DIR)/Release/$(APP))

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
	@$(call unregister,$(BUILD_DIR)/Release/$(APP))
	@$(call unregister,$(BUILD_DIR)/Debug/$(APP))
	rm -rf "$(BUILD_DIR)" "$(CURDIR)/build"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
