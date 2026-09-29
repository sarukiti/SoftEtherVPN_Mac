# SoftEther feth VPN — macOS GUI（プロダクション版）

PoC（`poc/gui/VpnMenu.swift`）の後継。VPN の ON/OFF のたびにパスワードを聞かれないよう、
**root で常駐する特権ヘルパーを SMAppService で一度だけ登録**し、非特権の GUI 本体が
**XPC** で操作を依頼する二層構成にした。シェルスクリプトは叩かず、ロジックは Swift に移植済み。

## 構成
- **App**（`App/`）: SwiftUI `MenuBarExtra`。状態取得（netstat/ifconfig/curl, root 不要）はアプリ内。
  パネルを開くたびにライブ再取得する。
- **Helper**（`Helper/`）: root で動く XPC デーモン。`poc/vpn-*.sh` のロジックを移植
  （フルトンネル例外ルート/DNS/システムプロキシ退避復元, vpncmd 接続/切断/プロキシ）。
- **Shared**（`Shared/`）: XPC プロトコルと値型。
- XPC は接続元の署名要件（アプリの bundle id + 証明書 CN）を検証して限定する。

## ビルド & 初回セットアップ

```sh
# 1) 自己署名のコード署名証明書を作成（有料 Developer ID 不要）
#    途中でログインパスワードおよび管理者パスワードを聞かれることがあります
sh create-signing-cert.sh

# 2) 署名付きビルド
SOFTETHER_BUILD="/path/to/SoftEtherVPN/build" sh build.sh
#    -> dist/SoftEtherFethVPN.app

# 3) /Applications に配置して起動（SMAppService のシステムデーモン登録に必須）
cp -R dist/SoftEtherFethVPN.app /Applications/
open /Applications/SoftEtherFethVPN.app
```

4. パネルの「ヘルパーを登録（初回のみ）」を押す → System Settings の
   「一般 ▸ ログイン項目とバックグラウンドでの実行」で **SoftEther VPN を許可**（初回1回だけ）。
5. 以後は「接続してフルトンネル」「フルトンネルを切る」等を **パスワード不要** で操作できる。

## 前提
- `build/vpncmd`（このリポジトリのビルド成果物）と `vpnclient` が動作していること。
- アカウント名は既定 `vpngate`（`UserDefaults` の `vpn.account` で変更可）。
- vpncmd のパスはヘルパー内 `VPNOperations.repoRoot` を参照（既定: このリポジトリの絶対パス）。

## トラブルシュート
- ヘルパーが「未承認」のまま: System Settings のトグルを ON。`sudo sfltool dumpbtm` で登録状態確認。
- XPC 接続不可: アプリとヘルパーが同じ証明書で署名されているか
  （`codesign -dv`）と、`main.swift` の署名要件 CN を確認。
- 自己署名で SMAppService 登録が拒否される場合: 証明書の信頼設定（create-signing-cert.sh の
  add-trusted-cert）を見直す。
