#!/bin/bash
# 速下 QuickDown 安装脚本
# 1) 构建 2) 安装到 /Applications 3) 尝试自动注册 Thorium/Chrome 扩展
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

echo "==> 构建应用"
"$ROOT/Scripts/build.sh" release

APP_SRC="$ROOT/dist/QuickDown.app"
APP_DST="/Applications/QuickDown.app"

echo "==> 退出正在运行的速下"
if pgrep -x QuickDown >/dev/null 2>&1; then
  osascript -e 'tell application "QuickDown" to quit' 2>/dev/null || pkill -x QuickDown 2>/dev/null || true
  sleep 1
fi

echo "==> 安装到 /Applications"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
chmod -R u+rwX,go+rX "$APP_DST"

# 修复隔离属性（本地构建无需，但保险起见）
xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true

EXT_SRC="$APP_DST/Contents/Resources/BrowserExtension"

echo "==> 注册浏览器扩展与原生启动服务"
bash "$ROOT/Scripts/install_extension.sh"
INSTALLED=""

echo ""
echo "=================================================="
echo " 速下已安装到 /Applications/QuickDown.app"
echo ""
if [ -n "$INSTALLED" ]; then
  echo " 已尝试为 $INSTALLED 注册扩展。"
  echo " 若浏览器未出现扩展，请手动安装："
fi
echo ""
echo " 手动安装扩展步骤："
echo " 1. 打开浏览器，地址栏输入 chrome://extensions"
echo " 2. 打开右上角「开发者模式」"
echo " 3. 点击「加载已解压的扩展程序」"
echo " 4. 选择目录：$EXT_SRC"
echo " 5. 固定扩展图标；点击图标可开关下载接管"
echo ""
echo " 首次启动：open /Applications/QuickDown.app"
echo "=================================================="
