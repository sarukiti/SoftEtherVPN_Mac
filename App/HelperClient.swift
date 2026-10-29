// SMAppService によるヘルパー登録と、XPC 接続の管理。
// 初回に1回 register()（→ System Settings で承認）すれば、以後は接続のみでパスワード不要。

import Foundation
import ServiceManagement

enum HelperRegistration: Equatable {
    case notRegistered          // 未登録
    case requiresApproval       // 登録済みだがユーザー承認待ち（System Settings）
    case enabled                // 有効・常駐
    case unknown(String)
}

@MainActor
final class HelperClient {
    private let service = SMAppService.daemon(plistName: kHelperPlistName)
    private var connection: NSXPCConnection?

    // MARK: 登録状態

    var registration: HelperRegistration {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled:       return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:      return .notRegistered
        @unknown default:    return .unknown("status=\(service.status.rawValue)")
        }
    }

    /// ヘルパーを登録。requiresApproval の場合は System Settings を開いて承認を促す。
    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
        invalidate()
    }

    /// 登録し直して、新しいヘルパーが応答するまで確かめる。応答したヘルパーの版を返す。
    ///
    /// 自己署名（Team ID なし）だと、BTM は起動制約（LWCR）をバイナリの cdhash で持つ。
    /// アプリ更新でヘルパーが差し替わった後の 1 回目の register は、BTM が旧バイナリの記録を
    /// 使い回すため "Launch Constraint Violation" で起動拒否される。launchd は約 10 秒後の
    /// 再 spawn で LWCR 修復を要求し、BTM は新バイナリの記録を作るが、Team ID が無いと
    /// ジョブに結び付けられず失敗する。その記録は残るので、修復後にもう一度
    /// unregister → register すると新しい記録が使われて起動できる。
    func reregister() async throws -> Int {
        var lastError: Error = HelperError.proxyUnavailable
        for attempt in 1...2 {
            try? await unregister()
            // unregister 直後の register は launchd の状態反映待ちで弾かれることがあるため少し待つ。
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            try register()
            if registration == .requiresApproval { throw HelperError.requiresApproval }
            // 1 回目は LWCR 修復（拒否から約 10 秒後の再 spawn）が走るまで待つ
            do { return try await ping(timeout: attempt == 1 ? 15 : 10) } catch { lastError = error }
        }
        throw lastError
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: XPC

    private func proxyConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: kHelperMachServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: VPNHelperProtocol.self)
        c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
        c.interruptionHandler = { [weak self] in Task { @MainActor in self?.connection = nil } }
        c.resume()
        connection = c
        return c
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    /// XPC のコールバック型 API を async/await でラップして呼ぶ。
    private func call<T>(_ body: @escaping (VPNHelperProtocol, @escaping (T) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            let resumed = Lock()
            let proxy = proxyConnection().remoteObjectProxyWithErrorHandler { err in
                if resumed.tryOnce() { cont.resume(throwing: err) }
            }
            guard let helper = proxy as? VPNHelperProtocol else {
                if resumed.tryOnce() { cont.resume(throwing: HelperError.proxyUnavailable) }
                return
            }
            body(helper) { value in
                if resumed.tryOnce() { cont.resume(returning: value) }
            }
        }
    }

    // 二重 resume を防ぐ最小ロック
    private final class Lock {
        private var done = false
        private let l = NSLock()
        func tryOnce() -> Bool { l.lock(); defer { l.unlock() }; if done { return false }; done = true; return true }
    }

    // MARK: 操作ラッパ

    func ping() async throws -> Int {
        try await call { helper, reply in helper.ping(reply: reply) }
    }

    /// launchd が spawn に失敗し続けていると XPC の応答が永久に返らないため、期限付きで ping する。
    func ping(timeout: TimeInterval) async throws -> Int {
        let timer = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.invalidate()   // 応答待ちの呼び出しをエラーで返させる
        }
        defer { timer.cancel() }
        return try await ping()
    }
    func connect(account: String) async throws -> (Bool, String) {
        try await callBoolMsg { helper, reply in helper.connect(account: account, reply: reply) }
    }
    func disconnect(account: String) async throws -> (Bool, String) {
        try await callBoolMsg { helper, reply in helper.disconnect(account: account, reply: reply) }
    }
    func enableFullTunnel() async throws -> (Bool, String) {
        try await callBoolMsg { helper, reply in helper.enableFullTunnel(reply: reply) }
    }
    func disableFullTunnel() async throws -> (Bool, String) {
        try await callBoolMsg { helper, reply in helper.disableFullTunnel(reply: reply) }
    }
    func setProxy(type: String, host: String, port: String, user: String, pass: String, account: String) async throws -> (Bool, String) {
        try await callBoolMsg { helper, reply in
            helper.setProxy(type: type, host: host, port: port, user: user, pass: pass, account: account, reply: reply)
        }
    }
    func clearProxy(account: String) async throws -> (Bool, String) {
        try await callBoolMsg { helper, reply in helper.clearProxy(account: account, reply: reply) }
    }
    func setupVpnAccount(account: String, server: String, port: String, hub: String, username: String, pass: String, authType: String) async throws -> (Bool, String) {
        try await callBoolMsg { helper, reply in
            helper.setupVpnAccount(account: account, server: server, port: port, hub: hub, username: username, pass: pass, authType: authType, reply: reply)
        }
    }
    func isConnected() async throws -> Bool {
        try await call { helper, reply in helper.isConnected(reply: reply) }
    }
    func privilegedStatus(account: String) async throws -> PrivilegedStatus {
        let json: String = try await call { helper, reply in helper.privilegedStatus(account: account, reply: reply) }
        return PrivilegedStatus.from(json: json)
    }

    // (Bool, String) を返す XPC 用の薄いヘルパー
    private func callBoolMsg(_ body: @escaping (VPNHelperProtocol, @escaping (Bool, String) -> Void) -> Void) async throws -> (Bool, String) {
        try await withCheckedThrowingContinuation { cont in
            let resumed = Lock()
            let proxy = proxyConnection().remoteObjectProxyWithErrorHandler { err in
                if resumed.tryOnce() { cont.resume(throwing: err) }
            }
            guard let helper = proxy as? VPNHelperProtocol else {
                if resumed.tryOnce() { cont.resume(throwing: HelperError.proxyUnavailable) }
                return
            }
            body(helper) { ok, msg in
                if resumed.tryOnce() { cont.resume(returning: (ok, msg)) }
            }
        }
    }
}

enum HelperError: LocalizedError {
    case proxyUnavailable
    case requiresApproval
    var errorDescription: String? {
        switch self {
        case .proxyUnavailable: return "ヘルパーに接続できません（未登録/未承認の可能性）"
        case .requiresApproval: return "System Settings でヘルパーの承認が必要です"
        }
    }
}
