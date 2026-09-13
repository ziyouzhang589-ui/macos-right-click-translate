#!/bin/zsh
# 创建本地自签名代码签名证书（每台机器只需一次）。
#
# 为什么需要：ad-hoc 签名的应用，系统按二进制哈希记录「辅助功能」授权，
# 每次重新编译哈希都变，授权会静默失效（系统设置里开关还亮着）。
# 用固定证书签名后，授权绑定证书而非哈希，重新编译也不会掉。
#
# 证书只存在本机登录钥匙串，不会被系统信任，也不用于分发。
set -euo pipefail

CERT_NAME="${CERT_NAME:-BilingualTranslator Local Code Signing}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  print "证书「$CERT_NAME」已存在，跳过。"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 用配置文件声明扩展，macOS 自带的 LibreSSL 与 Homebrew 的 OpenSSL 3 都支持。
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# OpenSSL 3 默认的 PKCS#12 加密算法 macOS 不认（报 MAC verification failed），
# 必须加 -legacy；LibreSSL 没有这个参数，默认算法本身就兼容。
LEGACY=()
openssl version | grep -q "^OpenSSL 3" && LEGACY=(-legacy)

openssl pkcs12 -export "${LEGACY[@]}" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/cert.p12" -passout pass:temp -name "$CERT_NAME"

# -A：允许 codesign 使用私钥而不弹钥匙串密码框。
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P temp -A >/dev/null

security find-identity -p codesigning "$KEYCHAIN" | grep -q "$CERT_NAME"
print "已创建证书「$CERT_NAME」。"
