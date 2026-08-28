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

# ----------------------------------------------------------------------------
# 步骤 0（升级安装关键）：原地刷新所有旧版扩展副本
#
# 旧版本用户浏览器里加载的扩展可能位于：
#   1. 应用内向导复制的 ~/Library/Application Support/QuickDown/browser-extension
#   2. 各浏览器 profile 中注册的任意位置（如分享包解压目录）
# 未打包扩展的 ID 由路径决定，因此必须「原地刷新文件」而不是改注册路径，
# 否则浏览器里会出现重复扩展。纯文件替换，浏览器运行中执行也安全，
# 浏览器重启后自动加载新版。
# ----------------------------------------------------------------------------
python3 - "$EXT_PATH" <<'PYEOF'
import json, os, shutil, sys, glob

ext_path = os.path.abspath(sys.argv[1])
try:
    ext_name = json.load(open(os.path.join(ext_path, "manifest.json"), encoding="utf-8")).get("name", "")
except Exception:
    raise SystemExit(0)

home = os.path.expanduser("~")
browsers = ["Google/Chrome", "Microsoft Edge", "Thorium",
            "BraveSoftware/Brave-Browser", "Chromium", "Vivaldi"]

# 收集候选目录：应用内向导固定目录 + 各浏览器 profile 注册的未打包扩展路径
candidates = {os.path.join(home, "Library/Application Support/QuickDown/browser-extension")}
for b in browsers:
    base = os.path.join(home, "Library/Application Support", b)
    if not os.path.isdir(base):
        continue
    profiles = [os.path.join(base, "Default")] + glob.glob(os.path.join(base, "Profile *")) + glob.glob(os.path.join(base, "Profile*"))
    for prof in profiles:
        for pf in ("Preferences", "Secure Preferences"):
            p = os.path.join(prof, pf)
            if not os.path.isfile(p):
                continue
            try:
                prefs = json.load(open(p, encoding="utf-8"))
            except Exception:
                continue
            for info in prefs.get("extensions", {}).get("settings", {}).values():
                try:
                    if info.get("location") != 4:
                        continue
                    rp = info.get("path", "")
                    if not rp:
                        continue
                    ap = os.path.abspath(os.path.expanduser(rp))
                    if os.path.isdir(ap):
                        candidates.add(ap)
                except Exception:
                    pass

def is_ours(d):
    m = os.path.join(d, "manifest.json")
    if not os.path.isfile(m):
        return False
    try:
        return json.load(open(m, encoding="utf-8")).get("name") == ext_name
    except Exception:
        return False

def is_source_project(d):
    # 排除 SwiftPM 源码项目里的 Extension 目录（开发者本机）：
    # 那是扩展的源头而非部署副本，刷新它会用安装副本覆盖源码
    cur = os.path.abspath(d)
    for _ in range(4):
        cur = os.path.dirname(cur)
        if os.path.isfile(os.path.join(cur, "Package.swift")):
            return True
    return False

crx = os.path.join(os.path.dirname(ext_path), "BrowserExtension.crx")
refreshed = 0
for dest in sorted(candidates):
    if os.path.abspath(dest) == ext_path or not is_ours(dest):
        continue
    if is_source_project(dest):
        continue
    try:
        tmp = dest + ".qd-updating"
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.copytree(ext_path, tmp, ignore=shutil.ignore_patterns(".DS_Store", "._*"))
        if os.path.isfile(crx):
            shutil.copy2(crx, tmp)
        shutil.rmtree(dest)
        os.rename(tmp, dest)
        refreshed += 1
        print("  ✅ 已更新扩展副本: " + dest)
    except Exception as e:
        print("  ⚠️ 更新失败 %s: %s" % (dest, e))
        shutil.rmtree(dest + ".qd-updating", ignore_errors=True)

if refreshed == 0:
    print("  （未发现需要更新的旧扩展副本）")
PYEOF

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
ALREADY=""
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
our_name = manifest.get("name", "")

# 升级防重：该浏览器已注册过速下扩展（无论副本在哪个路径）就不再重复注册。
# 未打包扩展 ID 由路径决定，重复注册会出现两个「速下」，导致下载被接管两次。
# 手动加载的扩展注册在 Secure Preferences，自动写入的在 Preferences，两处都要查。
settings = dict(prefs.get("extensions", {}).get("settings", {}))
secure_pref = os.path.join(os.path.dirname(pref_path), "Secure Preferences")
if os.path.isfile(secure_pref):
    try:
        secure = json.load(open(secure_pref, encoding="utf-8"))
        settings.update(secure.get("extensions", {}).get("settings", {}))
    except Exception:
        pass
for info in settings.values():
    if info.get("location") != 4:
        continue
    p = info.get("path", "")
    if not p:
        continue
    mpath = os.path.join(os.path.expanduser(p), "manifest.json")
    try:
        if json.load(open(mpath, encoding="utf-8")).get("name") == our_name:
            print("  ⏭ 已存在速下扩展: %s（副本已更新，跳过重复注册）" % p)
            raise SystemExit(2)
    except SystemExit:
        raise
    except Exception:
        pass

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
      rc=$?
      if [ "$rc" = "2" ]; then
        ALREADY="$ALREADY $dir"
      else
        echo "  ❌ 写入失败: $profile"
      fi
    fi
  done
done

echo ""
echo "================================================"
if [ -n "$REGISTERED" ]; then
  echo "✅ 已自动注册到浏览器:$REGISTERED"
  echo "   重启浏览器即可看到「速下 - 浏览器下载接管」扩展"
  echo "   （开发者模式已自动开启；旧版扩展副本已全部更新为最新版）"
fi
if [ -n "$ALREADY" ]; then
  echo "✅ 检测到已安装的速下扩展:$ALREADY"
  echo "   扩展文件已原地更新为最新版，重启浏览器即自动生效"
fi
if [ -z "$REGISTERED" ] && [ -z "$ALREADY" ]; then
  echo "⚠️  未注册到任何浏览器，请手动安装："
  echo "   1. 浏览器打开 chrome://extensions"
  echo "   2. 开启开发者模式"
  echo "   3. 加载已解压的扩展程序 → 选择：$EXT_PATH"
fi
echo "================================================"
