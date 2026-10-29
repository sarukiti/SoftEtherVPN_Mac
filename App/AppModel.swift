// UI の状態保持と操作のオーケストレーション。状態はキャッシュせず毎回ライブ取得する。

import Foundation
import SwiftUI
import AppKit

enum TunnelState: Equatable {
    case disconnected      // 未接続
    case connected         // 接続中（フルトンネルなし）
    case fullTunnel        // フルトンネル ON

    var iconName: String {
        switch self {
        case .fullTunnel:   return "lock.fill"
        case .connected:    return "lock.open"
        case .disconnected: return "lock.slash"
        }
    }
    var title: String {
        switch self {
        case .fullTunnel:   return "フルトンネル ON"
        case .connected:    return "接続中"
        case .disconnected: return "未接続"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tunnel: TunnelState = .disconnected
    @Published var hostIP: String?
    @Published var egressIP: String?
    @Published var privileged: PrivilegedStatus = .init()
    @Published var helperState: HelperRegistration = .notRegistered
    @Published var busy = false
    @Published var lastMessage = ""
    @Published var helperDiag = "—"   // XPC 疎通の診断表示
    @Published var helperNeedsUpdate = false   // ヘルパーの版不一致 or XPC 不通（要・再登録）
    @Published var proxyDescription: String = "—"   // 実態（AccountGet）からライブ取得
    @Published var proxyConfig: ProxyConfig = .init()  // 保存済みのプロキシ設定（オフにしても保持）
    @Published var vpnConfig: VpnAccountConfig = .init() // 保存済みのVPN設定

    var account: String {
        UserDefaults.standard.string(forKey: VPNDefaults.accountKey) ?? VPNDefaults.defaultAccount
    }

    /// アカウント側に現在プロキシが設定されているか（AccountGet 由来の表示から判定）。
    var proxyActive: Bool { proxyDescription != "なし" && proxyDescription != "—" }

    let helper = HelperClient()
    private var iconTimer: Timer?
    private var didPromptUpdate = false   // 自動アラートは1セッション1回まで（連打防止）
    private var didAutoRepairHelper = false // 起動時の自動再登録試行は1セッション1回まで
    private var settingsWindow: NSWindow?
    private var contextMenu: StatusItemContextMenu?

    init() {
        helperState = helper.registration
        proxyConfig = ProxyStore.loadConfig()
        vpnConfig = VpnStore.loadConfig()
        startIconTimer()
        contextMenu = StatusItemContextMenu(model: self)
        Task { await refreshFull() }
    }

    // MARK: 設定ウィンドウ（パネルが閉じても残る独立ウィンドウ。右クリックメニューからも開くので AppKit で持つ）

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ProxySettingsView().environmentObject(self)))
            w.title = "設定"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func closeSettings() { settingsWindow?.close() }

    // MARK: アイコン用の軽量タイマー（root 不要の項目だけ・約5秒）

    private func startIconTimer() {
        iconTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshLight() }
        }
        Task { await refreshLight() }
    }

    /// メニューバーアイコン用の軽量更新。
    /// 接続判定は feth の残存 IP ではなく「vpnclient が ESTABLISHED な対向を持つか」で行う。
    /// セッションが落ちても feth の DHCP IP は残るため、IP の有無では誤って「接続中」になる。
    /// その真値は root が要るので軽量 XPC（isConnected）で取得し、full tunnel 判定（netstat、
    /// root 不要）と組み合わせる。ヘルパー未登録時のみ従来の IP ヒューリスティックにフォールバック。
    func refreshLight() async {
        helperState = helper.registration
        let (ft, ip) = await Task.detached { (StatusProbe.isFullTunnel(), StatusProbe.hostFethIP()) }.value
        hostIP = ip

        if helper.registration == .enabled, let connected = try? await helper.isConnected() {
            // 真値: 未接続なら IP/経路が残っていても disconnected。接続中かつ 0/1 経路あれば fullTunnel。
            tunnel = connected ? (ft ? .fullTunnel : .connected) : .disconnected
        } else {
            // ヘルパー未登録/未承認時のフォールバック（従来動作）。
            tunnel = ft ? .fullTunnel : (ip != nil ? .connected : .disconnected)
        }
    }

    /// パネルを開くたびに呼ぶ完全リフレッシュ（状態 + 出口IP + root が要るセッション状態）。
    func refreshFull() async {
        await refreshLight()
        // 出口 IP（ネットワーク I/O。バックグラウンドで）
        let egress = await Task.detached { StatusProbe.egressIP() }.value
        egressIP = egress
        // root が要るセッション状態（ヘルパーが有効な時のみ）
        if helper.registration == .enabled {
            do {
                let v = try await helper.ping(timeout: 5)
                helperDiag = "XPC OK (helper v\(v))"
                if v < kHelperProtocolVersion {
                    // 登録済みヘルパーが古い（アプリだけ更新された）。自動で再登録を試行。
                    helperNeedsUpdate = true
                    reregisterHelper()
                } else if v > kHelperProtocolVersion {
                    helperNeedsUpdate = true
                    promptHelperUpdate(reason: "登録済みヘルパー (v\(v)) が想定外です。")
                } else {
                    helperNeedsUpdate = false
                }
            } catch {
                helperDiag = "XPC 失敗: \(error.localizedDescription)"
                helperNeedsUpdate = true
                if !didAutoRepairHelper {
                    didAutoRepairHelper = true
                    print("[AppModel] XPC 疎通失敗 (enabled 状態)。自動再登録を試行します...")
                    reregisterHelper()
                } else {
                    promptHelperUpdate(reason: "特権ヘルパーに接続できません（XPC 失敗）。バイナリの署名が変わると launchd が起動を拒否することがあります。")
                }
            }
            do {
                let status = try await helper.privilegedStatus(account: account)
                privileged = status
                proxyDescription = privileged.proxyDescription   // ← 実態をライブ反映
            } catch {
                privileged = .init(raw: "(状態取得不可: \(error.localizedDescription))")
            }
        }
    }

    private func isVpnConfigSynced(with liveHost: String) -> Bool {
        let expected = vpnConfig.port.isEmpty ? vpnConfig.server : "\(vpnConfig.server):\(vpnConfig.port)"
        return expected == liveHost
    }

    // MARK: ヘルパー登録

    func registerHelper() {
        do {
            try helper.register()
            helperState = helper.registration
            if helperState == .requiresApproval {
                lastMessage = "System Settings の「ログイン項目とバックグラウンドでの実行」で許可してください。"
                helper.openLoginItemsSettings()
            } else {
                lastMessage = "ヘルパーを登録しました。"
            }
        } catch {
            let desc = error.localizedDescription
            if desc.contains("Codesign") || desc.contains("code 1") {
                lastMessage = "登録失敗（署名不一致）:\n証明書作成（sh create-signing-cert.sh）と、署名付きビルド（sh build.sh）、および /Applications への配置が必要です。\n(\(desc))"
            } else {
                lastMessage = "登録失敗: \(desc)"
            }
        }
    }

    /// 再登録（リビルドでヘルパーのバイナリ署名が変わると launchd が起動拒否=EX_CONFIG になるため、
    /// 一度 unregister してから register し直して新バイナリに紐づけ直す）。
    func reregisterHelper() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let v = try await helper.reregister()
                helperState = helper.registration
                lastMessage = "再登録: helper v\(v)"
                didPromptUpdate = false   // 解決したら次回の自動アラートを再び許可
            } catch HelperError.requiresApproval {
                helperState = helper.registration
                lastMessage = "再登録: System Settings の「ログイン項目とバックグラウンドでの実行」で許可してください。"
                helper.openLoginItemsSettings()
            } catch {
                lastMessage = "再登録失敗: \(error.localizedDescription)"
                showHelperAlert(title: "再登録に失敗しました",
                                text: "\(error.localizedDescription)\n\nアプリが /Applications にあるか、System Settings で許可済みかを確認してください。",
                                offerReregister: false)
            }
            await refreshFull()
        }
    }

    /// 版不一致 / XPC 不通を検知したときの自動アラート（1セッション1回）。
    /// 「アプリ側からアラートを出す」ための入口。承認待ちのときは出さない（Onboarding が案内する）。
    private func promptHelperUpdate(reason: String) {
        guard !didPromptUpdate, !busy else { return }
        guard helper.registration == .enabled else { return }
        didPromptUpdate = true
        showHelperAlert(title: "ヘルパーの更新が必要です",
                        text: reason + "\n\n「今すぐ再登録」で特権ヘルパーを入れ直します（System Settings での承認が必要な場合があります）。",
                        offerReregister: true)
    }

    /// NSAlert を前面に出す共通処理。メニューバーのパネルはフォーカスで閉じるため、
    /// アプリをアクティブ化してからモーダル表示する。
    private func showHelperAlert(title: String, text: String, offerReregister: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = text
        if offerReregister {
            a.addButton(withTitle: "今すぐ再登録")
            a.addButton(withTitle: "後で")
            if a.runModal() == .alertFirstButtonReturn { reregisterHelper() }
        } else {
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }

    // MARK: 操作（すべて XPC 経由・パスワード不要）

    private func perform(_ title: String, _ op: @escaping () async throws -> (Bool, String)) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let (ok, msg) = try await op()
                lastMessage = "\(title): \(ok ? "OK" : "失敗")\n\(msg)"
            } catch {
                lastMessage = "\(title): エラー\n\(error.localizedDescription)"
            }
            await refreshFull()
        }
    }

    func connectAndFullTunnel() {
        perform("接続 ＋ フルトンネル") { [self, account, helper, vpnConfig, proxyConfig] in
            guard vpnConfig.isUsable else {
                return (false, "VPN接続設定が未保存です。設定画面から登録してください。")
            }

            // 1. vpnclient のアカウント設定同期（未設定またはズレがある場合のみ再作成）
            let status = try? await helper.privilegedStatus(account: account)
            let isVpnSynced = status != nil && !status!.serverHost.isEmpty && self.isVpnConfigSynced(with: status!.serverHost)
            if !isVpnSynced {
                let pass = VpnStore.loadPassword()
                let (setupOk, setupMsg) = try await helper.setupVpnAccount(
                    account: account,
                    server: vpnConfig.server,
                    port: vpnConfig.port,
                    hub: vpnConfig.hub,
                    username: vpnConfig.username,
                    pass: pass,
                    authType: vpnConfig.authType
                )
                if !setupOk {
                    return (false, "接続前のアカウント自動同期に失敗しました:\n\(setupMsg)")
                }
            }

            // 2. プロキシ設定の同期（保存済みかつ ON なら確実に適用、未設定または OFF なら Direct に）
            if proxyConfig.isUsable && ProxyStore.loadEnabled() {
                let targetDesc = "\(proxyConfig.type) \(proxyConfig.host):\(proxyConfig.port)"
                let latestStatus = try? await helper.privilegedStatus(account: account)
                if latestStatus?.proxyDescription != targetDesc {
                    let pass = ProxyStore.loadPassword()
                    let (proxyOk, proxyMsg) = try await helper.setProxy(
                        type: proxyConfig.type,
                        host: proxyConfig.host,
                        port: proxyConfig.port,
                        user: proxyConfig.user,
                        pass: pass,
                        account: account
                    )
                    if !proxyOk {
                        return (false, "接続前のプロキシ設定同期に失敗しました:\n\(proxyMsg)")
                    }
                }
            } else {
                let latestStatus = try? await helper.privilegedStatus(account: account)
                if latestStatus != nil && latestStatus!.proxyDescription != "なし" {
                    _ = try? await helper.clearProxy(account: account)
                }
            }

            // 3. 接続処理を開始
            let (ok, msg) = try await helper.connect(account: account)
            guard ok else { return (false, msg) }
            let (ok2, msg2) = try await helper.enableFullTunnel()
            return (ok2, msg + "\n" + msg2)
        }
    }
    func disconnect() { perform("VPN 切断") { [account, helper] in try await helper.disconnect(account: account) } }

    /// 設定を保存（UserDefaults + Keychain）してからアカウントへ適用する。
    /// 保存しておくので、以後はオフにしても再入力なしに applyProxy() で ON にできる。
    /// 設定後は perform 末尾の refreshFull が AccountGet から実態を取り直して表示を更新する。
    func saveAndApplyProxy(type: String, host: String, port: String, user: String, pass: String) {
        let cfg = ProxyConfig(type: type, host: host, port: port, user: user)
        ProxyStore.saveConfig(cfg)
        ProxyStore.savePassword(pass)
        ProxyStore.saveEnabled(true)
        proxyConfig = cfg
        Task {
            do {
                let (ok, msg) = try await helper.setProxy(type: type, host: host, port: port, user: user, pass: pass, account: account)
                lastMessage = "プロキシ設定: \(ok ? "OK" : "失敗")\n\(msg)"
            } catch {
                lastMessage = "プロキシ設定: エラー\n\(error.localizedDescription)"
            }
            await refreshFull()
        }
    }

    /// VPN設定を保存（UserDefaults + Keychain）してからアカウントへ適用する。
    func saveAndApplyVpnAccount(server: String, port: String, hub: String, username: String, pass: String, authType: String) {
        let cfg = VpnAccountConfig(server: server, port: port, hub: hub, username: username, authType: authType)
        VpnStore.saveConfig(cfg)
        VpnStore.savePassword(pass)
        vpnConfig = cfg
        Task {
            do {
                let (ok, msg) = try await helper.setupVpnAccount(account: account, server: server, port: port, hub: hub, username: username, pass: pass, authType: authType)
                lastMessage = "VPN設定: \(ok ? "OK" : "失敗")\n\(msg)"
            } catch {
                lastMessage = "VPN設定: エラー\n\(error.localizedDescription)"
            }
            await refreshFull()
        }
    }

    /// 保存済みのVPN設定を完全に消去（クリア）し、アカウントからも削除する。
    func clearVpnAccount() {
        UserDefaults.standard.removeObject(forKey: VPNDefaults.vpnConfigKey)
        VpnStore.savePassword("")
        vpnConfig = VpnAccountConfig()
        Task {
            do {
                // vpnclient 側からもアカウントを削除して不整合をリセット
                let (ok, msg) = try await helper.setupVpnAccount(
                    account: account, server: "", port: "", hub: "",
                    username: "", pass: "", authType: "anonymous"
                )
                lastMessage = "VPN設定を消去: \(ok ? "成功" : "失敗")\n\(msg)"
            } catch {
                lastMessage = "VPN設定消去中のエラー: \(error.localizedDescription)"
            }
            await refreshFull()
        }
    }

    /// 保存済みの設定をアカウントへ適用（再入力なしの ON）。
    func applyProxy() {
        let cfg = proxyConfig
        guard cfg.isUsable else { lastMessage = "プロキシ設定が未保存です。「設定…」から保存してください。"; return }
        let pass = ProxyStore.loadPassword()
        ProxyStore.saveEnabled(true)
        perform("プロキシ ON") { [account, helper] in
            try await helper.setProxy(type: cfg.type, host: cfg.host, port: cfg.port,
                                      user: cfg.user, pass: pass, account: account)
        }
    }

    /// アカウントのプロキシをオフ（直接接続）。保存済み設定は消さない。
    /// OFF は保存し、次に接続し直しても OFF のままにする。
    func clearProxy() {
        ProxyStore.saveEnabled(false)
        perform("プロキシをオフ") { [account, helper] in
            try await helper.clearProxy(account: account)
        }
    }
}
