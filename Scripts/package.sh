#!/bin/bash
# 制作速下分享包：QuickDown.app（通用版 arm64+x86_64）+ 浏览器扩展 + 安装说明 + 安装脚本
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="1.4.1"
PKG_NAME="速下下载管理器-通用版"
PKG_DIR="$ROOT/dist/$PKG_NAME"
ZIP="$ROOT/dist/$PKG_NAME.zip"

echo "==> 1/4 构建最新版本（universal）"
"$ROOT/Scripts/build.sh" universal >/dev/null

echo "==> 2/4 组装分享包目录"
rm -rf "$PKG_DIR" "$ZIP"
mkdir -p "$PKG_DIR/浏览器扩展"

cp -R "$ROOT/dist/QuickDown.app" "$PKG_DIR/QuickDown.app"
cp -R "$ROOT/Extension/." "$PKG_DIR/浏览器扩展/"
# 清理杂项
find "$PKG_DIR" -name ".DS_Store" -delete

echo "==> 3/4 写入安装说明与脚本"
cat > "$PKG_DIR/安装说明.txt" <<'EOF'
══════════════════════════════════════════════════════════
  速下 QuickDown — macOS 中文下载管理器（通用版 v1.4.1）
══════════════════════════════════════════════════════════

【这是什么】
一个轻量（约 2MB）、全中文的原生下载管理器：
  · 多线程分段下载（默认 8 段，可调 1-32）
  · 断点续传、暂停/继续、并发队列、实时网速
  · 浏览器下载接管（Chrome / Thorium / Edge 等）
  · 网页视频嗅探（m3u8 / ts / mp4），m3u8 自动合并为 MP4
  · 下载自动按「视频/音乐/压缩包/图片/应用程序/其他」分类

【兼容性】Apple 芯片（M1/M2/M3/M4）与 Intel Mac 均支持
【系统要求】macOS 13 及以上

──────────────────────────────
第一步：安装 App（任选其一）
──────────────────────────────
方式 A（推荐，一键安装）：
  1. 先【关闭所有浏览器】（Chrome / Edge / Thorium / Brave 等）
  2. 双击「速下下载管理器-一键安装.pkg」
  3. 按提示输入 Mac 密码，等待安装完成
  4. 重新打开浏览器 —— 速下扩展已自动装好（开发者模式已自动开启）
  5. 打开「速下」应用即可使用

方式 B（手动）：
  1. 把「QuickDown.app」拖入「应用程序」文件夹
  2. 双击打开
  3. 若提示「无法验证开发者」：右键 QuickDown.app → 打开 → 再点「打开」
     （或执行：xattr -dr com.apple.quarantine /Applications/QuickDown.app）
  4. 安装浏览器扩展：终端执行  ./install.sh  （需先关闭浏览器）
     或按下方第二步手动加载

──────────────────────────────
第二步：安装浏览器扩展
──────────────────────────────
1. 打开浏览器（Chrome / Thorium / Edge / 其他 Chromium 内核浏览器）
2. 地址栏输入：chrome://extensions  回车
3. 打开右上角「开发者模式」开关
4. 点击「加载已解压的扩展程序」
5. 选择本目录下的「浏览器扩展」文件夹
6. 把扩展图标固定到工具栏

【扩展使用】
  · 打开速下 → 设置 → 浏览器扩展 → 点对应浏览器的「一键安装向导…」
  · 按提示打开开发者模式，把 BrowserExtension.crx 拖到扩展页面即可
  · 点击扩展图标可开关「接管浏览器下载」
  · 打开含视频的网页，鼠标移到视频上，视频右上角出现「⬇ 下载视频」
    按钮（显示分辨率与大小，移开消失，全屏不出现）→ 点击 → 下载
  · 网页空白处右键 → 「🎬 嗅探本页视频」
  · 下载链接/图片/媒体 → 右键 → 「用速下下载…」

──────────────────────────────
常见问题
──────────────────────────────
Q: 浏览器下载被取消只留下 1 字节？
  正常现象。速下接管后取消浏览器下载（留下 0~1 字节残影），
  真正的完整文件在「下载目录」里，由速下下载（完成后有通知）。

Q: 装了 NeatDownloadManager 的扩展一直报错？
  请移除 NDM 扩展并退出 NDM 应用。速下与 NDM 共用 10007 端口，
  两者同时存在会冲突。

Q: 有些下载速度不快？
  服务器不支持 HTTP Range（断点续传）时只能单连接（IDM/NDM 也一样）。
  支持 Range 的服务器会自动 8 段并行加速。

Q: 想改下载目录/线程数/分类？
  打开速下 → 工具栏齿轮（设置）→ 常规。

【卸载】
  1. 删除浏览器里的「速下」扩展
  2. 删除 /Applications/QuickDown.app
  3. 删除 ~/Library/Application Support/QuickDown

──────────────────────────────
文件清单
──────────────────────────────
  QuickDown.app/    速下应用（含内置扩展副本）
  浏览器扩展/       独立扩展文件夹（供 chrome://extensions 加载）
  install.sh        一键安装脚本
  安装说明.txt      本文件
══════════════════════════════════════════════════════════
EOF

cat > "$PKG_DIR/install.sh" <<'EOF'
#!/bin/bash
# 速下一键安装：安装 App + 注册浏览器扩展
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 退出正在运行的速下"
if pgrep -x QuickDown >/dev/null 2>&1; then
  pkill -x QuickDown 2>/dev/null || true
  sleep 1
fi

echo "==> 安装到 /Applications"
rm -rf /Applications/QuickDown.app
cp -R "$PWD/QuickDown.app" /Applications/QuickDown.app
chmod -R u+rwX,go+rX /Applications/QuickDown.app
xattr -dr com.apple.quarantine /Applications/QuickDown.app 2>/dev/null || true

EXT_SRC="/Applications/QuickDown.app/Contents/Resources/BrowserExtension"
echo "==> 注册浏览器扩展（Thorium / Chrome / Edge 等）"
EXT_ID=""
if command -v python3 >/dev/null 2>&1; then
  EXT_ID=$(python3 - "$EXT_SRC" <<'PYEOF'
import sys, hashlib
path = sys.argv[1]
print(hashlib.sha256(path.encode("utf-8")).digest()[:16].hex())
PYEOF
)
fi

REGISTERED=""
for profile in \
  "$HOME/Library/Application Support/Thorium" \
  "$HOME/Library/Application Support/Google/Chrome" \
  "$HOME/Library/Application Support/Microsoft Edge" \
  "$HOME/Library/Application Support/Chromium" \
  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"; do
  if [ -d "$profile" ]; then
    mkdir -p "$profile/External Extensions"
    if [ -n "$EXT_ID" ]; then
      cat > "$profile/External Extensions/$EXT_ID.json" <<JSONEOF
{
  "path": "$EXT_SRC",
  "allow_file_access": true
}
JSONEOF
      REGISTERED="$profile"
    fi
  fi
done

echo ""
echo "=================================================="
echo " 速下已安装！启动：open /Applications/QuickDown.app"
if [ -n "$REGISTERED" ]; then
  echo " 已尝试为 $REGISTERED 注册扩展，重启浏览器即可。"
fi
echo ""
echo " 若浏览器未出现扩展，请手动加载："
echo " 1. 浏览器打开 chrome://extensions"
echo " 2. 开启「开发者模式」"
echo " 3. 「加载已解压的扩展程序」→ 选择："
echo "    $EXT_SRC"
echo "=================================================="
EOF
chmod +x "$PKG_DIR/install.sh"

echo "==> 4/4 打包 ZIP"
cd "$ROOT/dist"
ditto -c -k --sequesterRsrc --keepParent "$PKG_NAME" "$ZIP"
rm -rf "$PKG_DIR"
echo "完成: $ZIP"
ls -lh "$ZIP"
