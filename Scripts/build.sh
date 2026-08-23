#!/bin/bash
# 速下 QuickDown 构建脚本
# 用法: ./Scripts/build.sh [release|debug|universal] [输出目录]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-release}"

echo "==> 生成图标"
swift Scripts/make_icons.swift "$ROOT" >/dev/null

echo "==> 生成扩展 CRX"
Scripts/make_crx.sh >/dev/null

DEV_DIR=/Applications/Xcode.app/Contents/Developer

echo "==> 编译 ($CONFIG)"
case "$CONFIG" in
  universal)
    echo "    -- arm64 ..."
    DEVELOPER_DIR="$DEV_DIR" swift build -c release --product QuickDown --triple arm64-apple-macosx13.0
    BIN_A64="$(DEVELOPER_DIR="$DEV_DIR" swift build -c release --product QuickDown --triple arm64-apple-macosx13.0 --show-bin-path)/QuickDown"
    echo "    -- x86_64 ..."
    DEVELOPER_DIR="$DEV_DIR" swift build -c release --product QuickDown --triple x86_64-apple-macosx13.0
    BIN_X64="$(DEVELOPER_DIR="$DEV_DIR" swift build -c release --product QuickDown --triple x86_64-apple-macosx13.0 --show-bin-path)/QuickDown"
    mkdir -p "$ROOT/.build/universal"
    lipo -create "$BIN_A64" "$BIN_X64" -output "$ROOT/.build/universal/QuickDown"
    BIN="$ROOT/.build/universal/QuickDown"
    ;;
  release)
    DEVELOPER_DIR="$DEV_DIR" swift build -c release --product QuickDown
    BIN=".build/release/QuickDown"
    ;;
  *)
    DEVELOPER_DIR="$DEV_DIR" swift build --product QuickDown
    BIN=".build/debug/QuickDown"
    ;;
esac

DIST="${2:-$ROOT/dist}"
APP="$DIST/QuickDown.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 组装 .app"
cp "$BIN" "$APP/Contents/MacOS/QuickDown"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 内置浏览器扩展（文件夹 + 拖拽安装用 CRX）
cp -R Extension "$APP/Contents/Resources/BrowserExtension"
cp Resources/BrowserExtension.crx "$APP/Contents/Resources/BrowserExtension.crx"
# 清理 macOS 扩展属性文件
find "$APP" -name ".DS_Store" -delete

# 关键：统一修正权限（源文件可能为 0600，会导致 pkg 安装后 Info.plist/扩展不可读，
# 引发图标空白、通知崩溃、扩展加载失败）
chmod -R a+rX "$APP"
chmod -R u+rwX "$APP"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP"
codesign --verify "$APP" && echo "签名校验通过"

echo "==> 完成: $APP"
file "$APP/Contents/MacOS/QuickDown"
du -sh "$APP"
