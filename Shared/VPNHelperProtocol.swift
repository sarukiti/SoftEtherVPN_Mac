// XPC 契約。アプリ（非特権）と特権ヘルパー（root）の双方から参照する。
// XPC のシリアライズを単純に保つため、やり取りはプリミティブのみ
// （結果は Bool+String、構造化データは JSON 文字列）に限定する。

import Foundation

/// ヘルパーが公開する mach service 名。SMAppService の plist の MachServices と一致させる。
public let kHelperMachServiceName = "io.github.sarukiti.softethervpn.helper"

/// SMAppService に登録する LaunchDaemon plist のファイル名。
public let kHelperPlistName = "io.github.sarukiti.softethervpn.helper.plist"

/// アプリ／ヘルパーの版整合性チェック用。プロトコルを変えたら上げる。
public let kHelperProtocolVersion = 1

@objc public protocol VPNHelperProtocol {
    /// ヘルパーの稼働確認とプロトコル版の取得。
    func ping(reply: @escaping (_ version: Int) -> Void)

    /// AccountConnect + host feth に DHCP（フルトンネルは張らない）。vpn-connect.sh 相当。
    func connect(account: String, reply: @escaping (_ ok: Bool, _ message: String) -> Void)

    /// フルトンネル解除 + AccountDisconnect。vpn-disconnect.sh 相当。
    func disconnect(account: String, reply: @escaping (_ ok: Bool, _ message: String) -> Void)

    /// フルトンネル ON（例外ルート/0,1+128,1/DNS/システムプロキシ退避）。vpn-up.sh 相当。
    func enableFullTunnel(reply: @escaping (_ ok: Bool, _ message: String) -> Void)

    /// フルトンネル OFF（ルート削除/DNS復元/システムプロキシ復元）。vpn-down.sh 相当。
    func disableFullTunnel(reply: @escaping (_ ok: Bool, _ message: String) -> Void)

    /// VPN アカウントのプロキシ設定。type は "http" | "socks"。vpn-proxy.sh 相当。
    func setProxy(type: String, host: String, port: String, user: String, pass: String,
                  account: String, reply: @escaping (_ ok: Bool, _ message: String) -> Void)

    /// プロキシをオフ（直接接続）。vpn-proxy.sh none 相当。
    func clearProxy(account: String, reply: @escaping (_ ok: Bool, _ message: String) -> Void)

    /// root が要る状態取得（vpncmd AccountStatusGet）。結果は PrivilegedStatus の JSON 文字列。
    func privilegedStatus(account: String, reply: @escaping (_ json: String) -> Void)

    /// 接続中か（vpnclient が ESTABLISHED な対向を持つか）の軽量判定。
    /// メニューバーアイコンの定期更新用。feth の残存 IP に依存しない真の判定。
    func isConnected(reply: @escaping (_ connected: Bool) -> Void)

    /// SoftEther VPN 接続アカウントの作成・上書き設定。
    func setupVpnAccount(account: String, server: String, port: String, hub: String, username: String, pass: String, authType: String, reply: @escaping (_ ok: Bool, _ message: String) -> Void)
}
