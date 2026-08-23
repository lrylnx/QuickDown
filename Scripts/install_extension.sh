#!/bin/bash
# 速下浏览器扩展自动注册（Chrome / Edge / Thorium / Brave / Chromium / Vivaldi）
# 原理：直接写入各浏览器用户配置 Preferences：
#   extensions.ui.developer_mode = true（自动开启开发者模式）
#   extensions.settings.<扩展ID> = {state:1, location:4(未打包), path:...}（自动加载扩展）
# 要求：浏览器未运行（运行中的浏览器会在退出时覆盖 Preferences）
set -uo pipefail

EXT_PATH="/Applications/QuickDown.app/Contents/Resources/BrowserExtension"
[ -d "$EXT_PATH" ] || EXT_PATH="$HOME/Library/Application Support/QuickDown/browser-extension"
if [ ! -f "$EXT_PATH/manifest.json" ]; then
  echo "❌ 找不到扩展目录: $EXT_PATH"
  exit 1
fi

EXT_ID=$(python3 - "$EXT_PATH" <<'PYEOF'
import sys, hashlib
print(hashlib.sha256(sys.argv[1].encode()).digest()[:16].hex())
PYEOF
)
echo "扩展 ID: $EXT_ID"

# 浏览器应用名 -> 配置目录（相对 ~/Library/Application Support/）
BROWSERS=(
  "Google/Chrome"
  "Microsoft Edge"
  "Thorium"
  "BraveSoftware/Brave-Browser"
  "Chromium"
  "Vivaldi"
)

REGISTERED=""
for dir in "${BROWSERS[@]}"; do
  base="$HOME/Library/Application Support/$dir"
  [ -d "$base" ] || continue

  # 浏览器进程是否在运行
  appname=$(basename "$dir")
  if pgrep -x "$appname" >/dev/null 2>&1 || pgrep -f "Application Support/$dir/" >/dev/null 2>&1; then
    echo "⚠️  $dir 正在运行，跳过（请关闭后重试，或手动加载扩展）"
    continue
  fi

  # 遍历所有 profile（Default、Profile 1、Profile 2 ...）
  for profile in "$base"/Default "$base"/Profile*; do
    [ -d "$profile" ] || continue
    pref="$profile/Preferences"
    [ -f "$pref" ] || continue

    if python3 - "$pref" "$EXT_ID" "$EXT_PATH" <<'PYEOF'
import json, sys, os, time
pref_path, ext_id, ext_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    prefs = json.load(open(pref_path))
except Exception:
    prefs = {}

manifest = json.load(open(os.path.join(ext_path, "manifest.json")))
ext = prefs.setdefault("extensions", {}).setdefault("settings", {}).setdefault(ext_id, {})
ext.update({
    "allow_file_access": True,
    "state": 1,
    "location": 4,
    "path": ext_path,
    "manifest": manifest,
    "from_bookmark": False,
    "from_webstore": False,
    "install_time": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
})
prefs.setdefault("extensions", {}).setdefault("ui", {})["developer_mode"] = True
# 原子写入
tmp = pref_path + ".qd-tmp"
json.dump(prefs, open(tmp, "w"), indent=2)
os.replace(tmp, pref_path)
print("  ✅ 已注册: %s (%s)" % (pref_path, ext_id))
PYEOF
    then
      REGISTERED="$REGISTERED $dir"
    else
      echo "  ❌ 写入失败: $profile"
    fi
  done
done

echo ""
echo "================================================"
if [ -n "$REGISTERED" ]; then
  echo "✅ 已自动注册到浏览器:$REGISTERED"
  echo "   重启浏览器即可看到「速下 - 浏览器下载接管」扩展"
  echo "   （开发者模式已自动开启）"
else
  echo "⚠️  未注册到任何浏览器，请手动安装："
  echo "   1. 浏览器打开 chrome://extensions"
  echo "   2. 开启开发者模式"
  echo "   3. 加载已解压的扩展程序 → 选择：$EXT_PATH"
fi
echo "================================================"
