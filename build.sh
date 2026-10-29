#!/bin/sh
# プロジェクト生成 → 署名付きビルド → .app を dist/ に配置。
# 前提: create-signing-cert.sh で "SoftEther VPN Local" を作成済みであること。
# 実行: sh build.sh
set -e
set -o pipefail
cd "$(dirname "$0")"

IDENTITY="SoftEther VPN Local"
# 既定 Release。Debug は .debug.dylib を生成し、自己署名(Team ID なし)だと
# "different Team IDs" で起動失敗するため。
CONFIG="${1:-Release}"
# 第 1 引数に --install だけ渡された場合は Release でビルドしてインストールする
if [ "$CONFIG" = "--install" ]; then CONFIG=Release; set -- Release --install; fi

FOUND_HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep "$IDENTITY" | head -n 1 | awk '{print $2}')

if [ -z "$FOUND_HASH" ]; then
  echo "!!! コード署名 identity '$IDENTITY' がありません。先に:  sh create-signing-cert.sh"
  exit 1
fi

echo "### 使用するコード署名ハッシュ: $FOUND_HASH ($IDENTITY)"
IDENTITY="$FOUND_HASH"

echo "### project.yml -> .xcodeproj"
xcodegen generate

echo "### build ($CONFIG, signed as '$IDENTITY')"
xcodebuild -project SoftEtherFethVPN.xcodeproj -scheme SoftEtherFethVPN \
  -configuration "$CONFIG" -derivedDataPath build \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
  build | tail -3

APP="build/Build/Products/$CONFIG/SoftEtherFethVPN.app"
rm -rf dist && mkdir -p dist
cp -R "$APP" dist/

echo "### SoftEtherVPN バイナリのコピー"
RESOURCES_DIR="dist/SoftEtherFethVPN.app/Contents/Resources"
mkdir -p "$RESOURCES_DIR"
# SoftEtherVPN を自前でビルドした build ディレクトリ（vpnclient/vpncmd/hamcore.se2 が入っている場所）。
# 環境ごとに違うため、環境変数 SOFTETHER_BUILD で指定する。
#   例: SOFTETHER_BUILD="$HOME/Git/SoftEtherVPN/build" sh build.sh
if [ -z "$SOFTETHER_BUILD" ]; then
  echo "!!! 環境変数 SOFTETHER_BUILD が未設定です。SoftEtherVPN の build ディレクトリを指定してください。"
  echo "    例: SOFTETHER_BUILD=\"\$HOME/Git/SoftEtherVPN/build\" sh build.sh"
  exit 1
fi
if [ ! -f "$SOFTETHER_BUILD/vpnclient" ]; then
  echo "!!! '$SOFTETHER_BUILD' に vpnclient が見つかりません。SOFTETHER_BUILD のパスを確認してください。"
  exit 1
fi
cp "$SOFTETHER_BUILD/vpnclient" "$RESOURCES_DIR/"
cp "$SOFTETHER_BUILD/vpncmd" "$RESOURCES_DIR/"
cp "$SOFTETHER_BUILD/hamcore.se2" "$RESOURCES_DIR/"

echo "### dylibbundler による依存dylibの同梱"
FRAMEWORKS_DIR="dist/SoftEtherFethVPN.app/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
dylibbundler -od -b -x "$RESOURCES_DIR/vpnclient" -d "$FRAMEWORKS_DIR/" -p "@executable_path/../Frameworks/" -s "$SOFTETHER_BUILD"
dylibbundler -od -b -x "$RESOURCES_DIR/vpncmd" -d "$FRAMEWORKS_DIR/" -p "@executable_path/../Frameworks/" -s "$SOFTETHER_BUILD"

echo "### 同梱 dylib のコード署名"
if [ -d "$FRAMEWORKS_DIR" ] && [ "$(ls -A "$FRAMEWORKS_DIR")" ]; then
  for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    echo "署名中: $dylib"
    codesign --force --options runtime --sign "$IDENTITY" "$dylib"
  done
fi

# 一時的な entitlements ファイルを作成してライブラリ検証を無効化 (自己署名でロードを通すため)
ENTITLEMENTS="temp.entitlements"
cat <<EOF > "$ENTITLEMENTS"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

echo "### 同梱バイナリ・特権ヘルパーのコード署名"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$RESOURCES_DIR/vpnclient"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$RESOURCES_DIR/vpncmd"

HELPER_BIN="dist/SoftEtherFethVPN.app/Contents/Library/LaunchDaemons/SoftEtherVPNHelper"
if [ -f "$HELPER_BIN" ]; then
  echo "ヘルパーデーモン署名中: $HELPER_BIN"
  codesign --force --options runtime --sign "$IDENTITY" "$HELPER_BIN"
fi

echo "### メインアプリの再署名"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "dist/SoftEtherFethVPN.app"

rm -f "$ENTITLEMENTS"

echo
echo "### 署名検証"
codesign -dv --verbose=2 "dist/SoftEtherFethVPN.app" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true
echo "### 同梱ヘルパー/plist"
ls -l "dist/SoftEtherFethVPN.app/Contents/Library/LaunchDaemons/" 2>&1
echo
echo "### 完了 -> $(pwd)/dist/SoftEtherFethVPN.app"
if [ "$INSTALL_TO_APPLICATIONS" = "1" ] || [ "$2" = "--install" ]; then
  echo "### /Applications/SoftEtherFethVPN.app にインストール中..."
  killall SoftEtherFethVPN 2>/dev/null || true
  rm -rf /Applications/SoftEtherFethVPN.app
  cp -R dist/SoftEtherFethVPN.app /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/SoftEtherFethVPN.app
  echo "### インストール完了"
fi
echo "起動:  open /Applications/SoftEtherFethVPN.app   （メニューバーに錠前アイコン）"
