#!/bin/bash
# 制作速下一键安装包 .pkg
# 包含：QuickDown.app（通用版）+ 浏览器扩展自动注册脚本（安装时自动执行）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="1.2.0"
PKG="$ROOT/dist/速下下载管理器-一键安装.pkg"
BUILD_DIR="$ROOT/dist/pkg-build"

echo "==> 1/3 构建最新版本（universal，输出到独立目录）"
"$ROOT/Scripts/build.sh" universal "$BUILD_DIR" >/dev/null

echo "==> 2/3 组装安装器"
STAGE="$ROOT/dist/pkg-stage"
rm -rf "$STAGE" "$PKG"
# 标准布局：stage 内直接放 QuickDown.app，install-location 指向 /Applications
mkdir -p "$STAGE"
cp -R "$BUILD_DIR/QuickDown.app" "$STAGE/QuickDown.app"
# 清理 AppleDouble（._*）与 .DS_Store，避免 payload 元数据干扰 PackageKit 的 bundle 处理
find "$STAGE" \( -name "._*" -o -name ".DS_Store" \) -delete

rm -rf "$ROOT/dist/pkg-scripts"
mkdir -p "$ROOT/dist/pkg-scripts"
cp "$ROOT/Scripts/pkg_scripts/postinstall" "$ROOT/dist/pkg-scripts/postinstall"
cp "$ROOT/Scripts/install_extension.sh" "$ROOT/dist/pkg-scripts/install_extension.sh"
chmod 755 "$ROOT/dist/pkg-scripts/postinstall" "$ROOT/dist/pkg-scripts/install_extension.sh"
find "$ROOT/dist/pkg-scripts" -name "._*" -delete

echo "==> 3/3 打包 .pkg"
pkgbuild \
  --root "$STAGE" \
  --scripts "$ROOT/dist/pkg-scripts" \
  --identifier "com.quickdown.installer" \
  --version "$VERSION" \
  --install-location "/tmp/QuickDown-install" \
  "$PKG" 2>&1 | tail -2

rm -rf "$STAGE" "$ROOT/dist/pkg-scripts" "$BUILD_DIR"
echo "==> 完成: $PKG"
ls -lh "$PKG"
