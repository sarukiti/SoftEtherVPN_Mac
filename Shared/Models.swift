// アプリ／ヘルパー共有の値型。XPC では JSON 文字列として往復する。

import Foundation

/// root が要る範囲のセッション状態（vpncmd AccountStatusGet 由来）。
public struct PrivilegedStatus: Codable, Equatable {
    public var sessionEstablished: Bool
    public var sessionStatus: String   // 例: "Retrying" / "Connection Completed (Session Established)"
    public var serverName: String      // 接続中のサーバ名（AccountStatusGet 由来）
    public var serverHost: String      // 接続先ホスト（AccountGet 由来, 例 public-vpn-129.opengw.net:443）
    public var proxyDescription: String // 実際のプロキシ設定（AccountGet 由来, 例 "http proxy.example.com:8080" / "なし"）
    public var raw: String             // 取得失敗時の生メッセージ等

    public init(sessionEstablished: Bool = false, sessionStatus: String = "",
                serverName: String = "", serverHost: String = "",
                proxyDescription: String = "—", raw: String = "") {
        self.sessionEstablished = sessionEstablished
        self.sessionStatus = sessionStatus
        self.serverName = serverName
        self.serverHost = serverHost
        self.proxyDescription = proxyDescription
        self.raw = raw
    }

    public func jsonString() -> String {
        guard let d = try? JSONEncoder().encode(self),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    public static func from(json: String) -> PrivilegedStatus {
        guard let d = json.data(using: .utf8),
              let v = try? JSONDecoder().decode(PrivilegedStatus.self, from: d) else {
            return PrivilegedStatus(raw: json)
        }
        return v
    }
}

/// 設定（アプリの UserDefaults に保存。デフォルトは下記）。
public enum VPNDefaults {
    public static let accountKey = "vpn.account"
    public static let defaultAccount = "vpngate"
    public static let proxyConfigKey = "vpn.proxy.config"   // ProxyConfig の JSON（パスワードは除く）
    public static let vpnConfigKey = "vpn.account.config"   // VpnAccountConfig の JSON（パスワードは除く）
}

/// 永続化する VPN アカウント設定（パスワードは Keychain 側で別管理）
public struct VpnAccountConfig: Codable, Equatable {
    public var server: String
    public var port: String
    public var hub: String
    public var username: String
    public var authType: String // "password" or "anonymous"

    public init(server: String = "", port: String = "443", hub: String = "VPN", username: String = "vpn", authType: String = "anonymous") {
        self.server = server
        self.port = port
        self.hub = hub
        self.username = username
        self.authType = authType
    }

    public var isUsable: Bool { !server.isEmpty && !port.isEmpty && !hub.isEmpty && (authType == "anonymous" || !username.isEmpty) }

    public func jsonString() -> String {
        guard let d = try? JSONEncoder().encode(self), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    public static func from(json: String) -> VpnAccountConfig {
        guard let d = json.data(using: .utf8),
              let v = try? JSONDecoder().decode(VpnAccountConfig.self, from: d) else { return VpnAccountConfig() }
        return v
    }
}

/// 永続化するプロキシ設定（パスワードは Keychain 側で別管理）。
/// これを保存しておくことで、いったんオフにしても設定を失わず ON で再適用できる。
public struct ProxyConfig: Codable, Equatable {
    public var type: String   // "http" | "socks"
    public var host: String
    public var port: String
    public var user: String

    public init(type: String = "http", host: String = "", port: String = "", user: String = "") {
        self.type = type; self.host = host; self.port = port; self.user = user
    }

    /// host/port が揃っていなければ適用できない（=未設定）。
    public var isUsable: Bool { !host.isEmpty && !port.isEmpty }

    public func jsonString() -> String {
        guard let d = try? JSONEncoder().encode(self), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    public static func from(json: String) -> ProxyConfig {
        guard let d = json.data(using: .utf8),
              let v = try? JSONDecoder().decode(ProxyConfig.self, from: d) else { return ProxyConfig() }
        return v
    }
}
