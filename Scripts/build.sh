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
    # Swift 6.4 起 --show-bin-path 对不同 triple 返回同一路径（互相覆盖），
    # 必须给每个架构用独立的 --scratch-path，否则会 lipo 到陈旧产物
    echo "    -- arm64 ..."
    BIN_A64="$ROOT/.build-a64/release/QuickDown"
    DEVELOPER_DIR="$DEV_DIR" swift build --disable-sandbox -c release --product QuickDown \
      --triple arm64-apple-macosx13.0 --scratch-path "$ROOT/.build-a64"
    echo "    -- x86_64 ..."
    BIN_X64="$ROOT/.build-x64/release/QuickDown"
    DEVELOPER_DIR="$DEV_DIR" swift build --disable-sandbox -c release --product QuickDown \
      --triple x86_64-apple-macosx13.0 --scratch-path "$ROOT/.build-x64"
    for QD_ARCH in arm64 x86_64; do
      if [ "$QD_ARCH" = arm64 ]; then QD_SCRATCH="$ROOT/.build-a64"; else QD_SCRATCH="$ROOT/.build-x64"; fi
      DEVELOPER_DIR="$DEV_DIR" swift build --disable-sandbox -c release --product QuickDownBridge \
        --triple "$QD_ARCH-apple-macosx13.0" --scratch-path "$QD_SCRATCH"
    done
    mkdir -p "$ROOT/.build/universal"
    lipo -create "$ROOT/.build-a64/release/QuickDownBridge" "$ROOT/.build-x64/release/QuickDownBridge" \
      -output "$ROOT/.build/universal/QuickDownBridge"
    BRIDGE_BIN="$ROOT/.build/universal/QuickDownBridge"
    lipo -create "$BIN_A64" "$BIN_X64" -output "$ROOT/.build/universal/QuickDown"
    BIN="$ROOT/.build/universal/QuickDown"
    ;;
  release)
    DEVELOPER_DIR="$DEV_DIR" swift build --disable-sandbox -c release --product QuickDown
    DEVELOPER_DIR="$DEV_DIR" swift build --disable-sandbox -c release --product QuickDownBridge
    BRIDGE_BIN=".build/release/QuickDownBridge"
    BIN=".build/release/QuickDown"
    ;;
  *)
    DEVELOPER_DIR="$DEV_DIR" swift build --disable-sandbox --product QuickDown
    DEVELOPER_DIR="$DEV_DIR" swift build --disable-sandbox --product QuickDownBridge
    BRIDGE_BIN=".build/debug/QuickDownBridge"
    BIN=".build/debug/QuickDown"
    ;;
esac

DIST="${2:-$ROOT/dist}"
APP="$DIST/QuickDown.app"
# 移入废纸篓而非 rm -rf：更安全，也避免触发系统的批量删除保护
trash_path() {
  [ -e "$1" ] || return 0
  mv "$1" "$HOME/.Trash/$(basename "$1")-$(date +%s)" 2>/dev/null || rm -rf "$1"
}
trash_path "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 组装 .app"
cp "$BIN" "$APP/Contents/MacOS/QuickDown"
cp "$BRIDGE_BIN" "$APP/Contents/MacOS/QuickDownBridge"
codesign --force --sign - "$APP/Contents/MacOS/QuickDownBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 内置浏览器扩展（文件夹 + 拖拽安装用 CRX）
cp -R Extension "$APP/Contents/Resources/BrowserExtension"
cp Resources/BrowserExtension.crx "$APP/Contents/Resources/BrowserExtension.crx"
cp Scripts/crx/pub.der "$APP/Contents/Resources/BrowserExtensionPublicKey.der"
cp Scripts/install_extension.sh "$APP/Contents/Resources/install_extension.sh"
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
