#!/bin/sh
# 自己署名のコード署名証明書を作成し、login キーチェーンに取り込む。
# SMAppService のデーモン登録と XPC の署名要件（CN 一致）に必要。有料 Developer ID は不要。
# 実行: sh macos/create-signing-cert.sh
set -e

CN="SoftEther VPN Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

# 既に同名の identity があればスキップ
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
  echo "既に '$CN' が存在します。再作成は不要です。"
  security find-identity -v -p codesigning | grep "$CN"
  exit 0
fi

cat > "$DIR/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CN
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

echo "### 鍵と自己署名証明書を生成..."
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -config "$DIR/cfg"
# macOS の security は OpenSSL3 既定の PKCS#12（SHA-256 MAC/AES）を読めないため、
# レガシー暗号と SHA1 MAC を明示する（-legacy）。
openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
  -out "$DIR/id.p12" -passout pass:temp -name "$CN" \
  -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

echo "### login キーチェーンに取り込み（codesign から鍵を使えるように）..."
security import "$DIR/id.p12" -k "$KEYCHAIN" -P temp \
  -T /usr/bin/codesign -T /usr/bin/security

echo "### codesign が確認ダイアログなしに鍵を使えるよう partition list を設定..."
security set-key-partition-list -S apple-tool:,apple: -s -l "$CN" "$KEYCHAIN" 2>/dev/null \
  || security set-key-partition-list -S apple-tool:,apple: -s -l "$CN" 2>/dev/null \
  || true

echo "### 証明書を信頼（コード署名用）として登録..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem" || true

echo "### SMAppService（launchd）でのデーモン登録検証のため、証明書をシステム信頼設定に追加します..."
echo "    （管理者パスワードが求められる場合があります）"
sudo security add-trusted-cert -d -r trustRoot -p codeSign "$DIR/cert.pem" 2>/dev/null \
  || echo "注: システム信頼登録がスキップされました。SMAppServiceでエラーが出る場合は手動でキーチェーンアクセスから「常に信頼」を設定してください。"

echo
echo "### 完了。コード署名 identity 一覧:"
security find-identity -v -p codesigning | grep "$CN" || {
  echo "!!! '$CN' が見つかりません。手動確認が必要です。"; exit 1; }
echo "OK"
