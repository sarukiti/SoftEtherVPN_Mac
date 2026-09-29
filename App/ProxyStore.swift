// プロキシ設定の永続化。設定値（type/host/port/user）は UserDefaults に、
// パスワードだけは平文 plist を避けて Keychain に保存する。
// これにより「オフ → ON」を設定の再入力なしに行える。

import Foundation
import Security

enum ProxyStore {
    private static let keychainService = "org.softether.feth.proxy"
    private static let keychainAccount = "proxy-password"

    // MARK: 設定値（UserDefaults）

    static func loadConfig() -> ProxyConfig {
        guard let json = UserDefaults.standard.string(forKey: VPNDefaults.proxyConfigKey) else { return ProxyConfig() }
        return ProxyConfig.from(json: json)
    }
    static func saveConfig(_ c: ProxyConfig) {
        UserDefaults.standard.set(c.jsonString(), forKey: VPNDefaults.proxyConfigKey)
    }

    // MARK: パスワード（Keychain）

    static func loadPassword() -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func savePassword(_ password: String) {
        // 既存を消してから入れる（update 分岐を避けて単純化）。
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum VpnStore {
    private static let keychainService = "org.softether.feth.vpn"
    private static let keychainAccount = "vpn-password"

    // MARK: 設定値（UserDefaults）

    static func loadConfig() -> VpnAccountConfig {
        guard let json = UserDefaults.standard.string(forKey: VPNDefaults.vpnConfigKey) else { return VpnAccountConfig() }
        return VpnAccountConfig.from(json: json)
    }
    static func saveConfig(_ c: VpnAccountConfig) {
        UserDefaults.standard.set(c.jsonString(), forKey: VPNDefaults.vpnConfigKey)
    }

    // MARK: パスワード（Keychain）

    static func loadPassword() -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func savePassword(_ password: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
