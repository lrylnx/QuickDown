#!/bin/bash
# 生成速下浏览器扩展的 CRX 包（CRX2 格式，自签名，拖拽安装用）
# 使用固定的签名密钥 Scripts/crx/key.pem，保证扩展 ID 稳定
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

KEY="$ROOT/Scripts/crx/key.pem"
PUB="$ROOT/Scripts/crx/pub.der"
OUT="$ROOT/Resources/BrowserExtension.crx"

if [ ! -f "$KEY" ] || [ ! -f "$PUB" ]; then
  echo "==> 生成扩展签名密钥（首次构建）"
  mkdir -p "$(dirname "$KEY")"
  openssl genrsa -out "$KEY" 2048 2>/dev/null
  openssl rsa -in "$KEY" -pubout -outform DER -out "$PUB" 2>/dev/null
fi

python3 - "$ROOT/Extension" "$KEY" "$PUB" "$OUT" <<'PYEOF'
import sys, os, zipfile, struct, subprocess, hashlib

ext_dir, key_path, pub_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# 1. 打包扩展为 zip（固定顺序保证可复现）
zip_path = out_path + ".zip"
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in sorted(os.walk(ext_dir)):
        dirs.sort()
        for f in sorted(files):
            full = os.path.join(root, f)
            rel = os.path.relpath(full, ext_dir)
            z.write(full, rel)
zip_bytes = open(zip_path, "rb").read()

# 2. RSA-SHA1 签名 zip 内容（CRX2 格式要求）
sig_path = out_path + ".sig"
subprocess.run(["openssl", "dgst", "-sha1", "-sign", key_path, "-out", sig_path, zip_path], check=True)
sig = open(sig_path, "rb").read()
pubkey = open(pub_path, "rb").read()

# 3. CRX2 头部：魔数 + 版本2 + header_len + (pubkey_len + sig_len + pubkey + sig)
header = struct.pack("<I", len(pubkey)) + struct.pack("<I", len(sig)) + pubkey + sig
crx = b"Cr24" + struct.pack("<I", 2) + struct.pack("<I", len(header)) + header + zip_bytes
open(out_path, "wb").write(crx)

ext_id = hashlib.sha256(pubkey).hexdigest()[:32]
os.remove(zip_path); os.remove(sig_path)
print(f"CRX 已生成: {out_path} ({len(crx)} 字节)  扩展 ID: {ext_id}")
PYEOF
