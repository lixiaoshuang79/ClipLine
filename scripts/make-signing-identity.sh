#!/bin/bash
# 生成「ClipLine Dev」本地签名身份（自签名证书导入登录钥匙串，私钥不落盘）。
#
# 为什么需要它：ad-hoc 签名（codesign --sign -）的指定要求绑定 cdhash，
# 每次重编译 cdhash 都变 → TCC（屏幕录制/辅助功能）的授权全部作废、反复要求重新授权。
# 固定证书签名的指定要求是 `certificate leaf = H"<证书哈希>"`，跨重编译恒定，
# 一次授权永久有效。证书只存在本机钥匙串，仅用于本地开发构建。
#
# 实现注记：
# - 用 /usr/bin/openssl（LibreSSL）生成传统 PEM；Homebrew 的 OpenSSL 3 产出的
#   p12 用 PBKDF2/AES，macOS Security 框架导入会报 "MAC verification failed"。
# - 私钥与证书分开导入（不走 p12）；私钥导入带 -A，允许本机程序使用，免弹授权框。
# - 幂等：`security find-identity -p codesigning` 能看到身份就跳过（自签名未受信
#   会带 CSSMERR_TP_NOT_TRUSTED 标记，属正常，不影响 codesign 使用）。
set -euo pipefail

KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q '"ClipLine Dev"'; then
  echo "ClipLine Dev 身份已存在，跳过"
  exit 0
fi

# 上次半途失败可能留下「有证书无密钥」的残件，先清掉
if security find-certificate -c "ClipLine Dev" "$KC" >/dev/null 2>&1; then
  security delete-certificate -c "ClipLine Dev" "$KC" >/dev/null
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/ext.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=ClipLine Dev
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

/usr/bin/openssl genrsa -out "$WORK/key.pem" 2048 2>/dev/null
/usr/bin/openssl req -x509 -new -key "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 -config "$WORK/ext.cnf" 2>/dev/null

security import "$WORK/key.pem" -k "$KC" -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null
security import "$WORK/cert.pem" -k "$KC" >/dev/null

echo "已生成并导入 ClipLine Dev 签名身份（私钥仅存于登录钥匙串）"
