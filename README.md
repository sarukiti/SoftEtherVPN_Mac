# SoftEther VPN for Mac — macOS メニューバーアプリ

SoftEther VPN Client（`vpnclient` / `vpncmd`）を macOS の feth 仮想 NIC で使い、フルトンネルの
ON/OFF をメニューバーから行うアプリ。操作のたびにパスワードを聞かれないよう、
**root で常駐する特権ヘルパーを SMAppService で一度だけ登録**し、非特権の GUI 本体が
**XPC** で操作を依頼する二層構成にしている。

## 構成
- **App**（`App/`）: SwiftUI `MenuBarExtra`。状態取得（netstat/ifconfig/curl, root 不要）はアプリ内で、
  パネルを開くたびにライブ再取得する。アイコンの右クリックで「ヘルパーを再登録・設定・終了」。
- **Helper**（`Helper/`）: root で動く XPC デーモン。vpncmd での接続/切断/プロキシ設定、
  フルトンネル（例外ルート・DNS・システムプロキシの退避と復元）、ウォッチドッグ
  （再接続時の DHCP やり直し・消えた経路の張り直し・プロキシ不達時の直接接続切替）。
- **Shared**（`Shared/`）: XPC プロトコルと値型。
- XPC は接続元の署名要件（アプリの bundle id + 証明書 CN）を検証して限定する。

### SoftEther のバイナリ
SoftEtherVPN は submodule（`SoftEtherVPN/`、feth 対応を入れた [fork](https://github.com/sarukiti/SoftEtherVPN) の `master`）として取り込んでいる。
`build.sh` がそれをビルドし、`vpnclient` / `vpncmd` / `hamcore.se2` を
`Contents/Resources/` へコピーし、依存 dylib を `dylibbundler` で `Contents/Frameworks/` に同梱する。
SoftEther は実行ファイルの隣に設定・ログ・ロックを書くため、ヘルパーは
`/Library/Application Support/SoftEther VPN for Mac/` にシンボリックリンクを張ってそこ経由で実行する
（バンドル内に root 所有ファイルができて署名が壊れるのを防ぐ）。
`vpn_client.config` や `client_log/` もこのディレクトリにできる。

## ビルド & 初回セットアップ

必要なもの: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), dylibbundler, SoftEther のビルド用に cmake と OpenSSL
（`brew install xcodegen dylibbundler cmake openssl@3`）。

```sh
# 0) submodule の取得（clone 時に --recursive を付けていれば不要）
git submodule update --init --recursive

# 1) 自己署名のコード署名証明書を作成（有料 Developer ID 不要）
#    途中でログインパスワードおよび管理者パスワードを聞かれることがあります
sh create-signing-cert.sh

# 2) 署名付きビルド（submodule の SoftEtherVPN も configure + make する）
sh build.sh
#    -> dist/SoftEther VPN for Mac.app
#    --install を付けると /Applications へのコピーまで行う:
#    sh build.sh --install
#    別の場所でビルドした SoftEtherVPN を使う場合は build ディレクトリを指定する:
#    SOFTETHER_BUILD="/path/to/SoftEtherVPN/build" sh build.sh

# 3) /Applications に配置して起動（SMAppService のシステムデーモン登録に必須）
cp -R "dist/SoftEther VPN for Mac.app" /Applications/
open "/Applications/SoftEther VPN for Mac.app"
```

4. パネルの「ヘルパーを登録（初回のみ）」を押す → System Settings の
   「一般 ▸ ログイン項目とバックグラウンドでの実行」で **SoftEther VPN を許可**（初回1回だけ）。
5. 「設定…」の VPN タブで接続先を保存する（必要ならプロキシタブも）。
6. 以後は「接続」「VPN 切断」を **パスワード不要** で操作できる。接続するとフルトンネルまで張る。

## CLI
アプリ本体に引数を渡すと GUI を出さずに操作できる（検証用）。

```sh
APP="/Applications/SoftEther VPN for Mac.app/Contents/MacOS/SoftEther VPN for Mac"
"$APP" --status              # 登録状態・セッション・プロキシ・出口 IP
"$APP" --connect             # 保存済み設定を同期して接続 + フルトンネル
"$APP" --disconnect
"$APP" --ping-helper
"$APP" --reregister-helper   # アプリ更新後にヘルパーが起動しない時
```

## 前提
- アカウント名は既定 `vpngate`（`UserDefaults` の `vpn.account` で変更可）。

## トラブルシュート
- ヘルパーが「未承認」のまま: System Settings のトグルを ON。`sudo sfltool dumpbtm` で登録状態確認。
- アプリ更新後に XPC がつながらない: 右クリック →「ヘルパーを再登録」（または `--reregister-helper`）。
  自己署名だと差し替え直後は Launch Constraint Violation で拒否されるため、再登録は最大 30 秒ほどかかる。
- XPC 接続不可: アプリとヘルパーが同じ証明書で署名されているか
  （`codesign -dv`）と、`Helper/main.swift` の署名要件 CN を確認。
- 自己署名で SMAppService 登録が拒否される場合: 証明書の信頼設定（create-signing-cert.sh の
  add-trusted-cert）を見直す。
- ヘルパーのログ: `/tmp/se-helper.log`。
