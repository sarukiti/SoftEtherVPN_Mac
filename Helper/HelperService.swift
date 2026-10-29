// XPC で公開する実体。root 権限で動く。操作はルーティング等を書き換えるため
// 直列キューで実行し、競合を避ける。

import Foundation
import SystemConfiguration

/// 全 XPC 接続とウォッチドッグで共有する操作キュー。HelperService は接続ごとに
/// 生成されるため、キューをインスタンスに持たせると接続間で操作が直列化されない。
let helperOpsQueue = DispatchQueue(label: "io.github.sarukiti.softethervpn.helper.ops")

/// 新セッションの DHCP やり直し・OS 側で消された経路の張り直し・プロキシ不達時の直接接続切替を行う。
/// ネットワーク変化（SCDynamicStore）と vpnclient の再接続（client_log）を契機に即座に動き、
/// 通知の取りこぼしやヘルパー起動直後に備えて低頻度のポーリングも残す。
enum FullTunnelWatchdog {
    private static var timer: DispatchSourceTimer?
    /// 通知の受け口とデバウンス用。チェック本体は helperOpsQueue で他の操作と直列に走らせる。
    private static let eventQueue = DispatchQueue(label: "io.github.sarukiti.softethervpn.helper.events")
    private static var pending: [DispatchWorkItem] = []
    private static var store: SCDynamicStore?
    private static var dirSource: DispatchSourceFileSystemObject?
    private static var logSource: DispatchSourceFileSystemObject?
    private static var logHandle: FileHandle?
    private static var logPath = ""

    private static var clientLogDir: String { VPNOperations.stateDir + "/client_log" }

    static func start(interval: TimeInterval = 60) {
        let t = DispatchSource.makeTimerSource(queue: helperOpsQueue)
        t.schedule(deadline: .now() + 15, repeating: interval)
        t.setEventHandler { runChecks() }
        t.resume()
        timer = t
        eventQueue.async {
            watchNetwork()
            watchClientLog()
        }
    }

    private static func runChecks() {
        // 再接続した新セッションは DHCP し直さないと通らない。経路の張り直しより先に行う
        VPNOperations.renewDhcpIfSessionChanged()
        // 例外ルートを先に直す（プロキシ到達性の判定が死んだトンネルに吸われないように）
        VPNOperations.repairFullTunnelIfNeeded()
        VPNOperations.checkProxyFallback()
    }

    /// 通知はまとまって来るので 2 秒待ってから 1 回だけチェックする。プロキシ切替は不一致を
    /// 2 回続けて観測して初めて動くため、15 秒後にもう一度確認する。
    static func trigger(_ reason: String) {
        eventQueue.async {
            pending.forEach { $0.cancel() }
            pending = [2.0, 17.0].map { delay in
                let w = DispatchWorkItem {
                    helperOpsQueue.async {
                        HLog("watchdog: \(reason) を契機にチェック")
                        runChecks()
                    }
                }
                eventQueue.asyncAfter(deadline: .now() + delay, execute: w)
                return w
            }
        }
    }

    // MARK: ネットワーク変化

    /// Wi-Fi 切替・IP 付け直し・GW 変化。feth の DHCP 完了もここで拾い、経路をすぐ張り直す。
    private static func watchNetwork() {
        var ctx = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        guard let s = SCDynamicStoreCreate(nil, "io.github.sarukiti.softethervpn.helper" as CFString,
                                           { _, _, _ in FullTunnelWatchdog.trigger("ネットワーク変化") }, &ctx) else {
            HLog("watchdog: SCDynamicStore の作成に失敗（ポーリングのみで動作）")
            return
        }
        SCDynamicStoreSetNotificationKeys(s, ["State:/Network/Global/IPv4"] as CFArray,
                                          ["State:/Network/Interface/[^/]+/IPv4"] as CFArray)
        SCDynamicStoreSetDispatchQueue(s, eventQueue)
        store = s
    }

    // MARK: vpnclient の再接続

    /// vpncmd は状態変化を通知しないため、vpnclient が新セッション確立時に書く
    /// "Now connected. Session name: ..." を client_log の追記から拾う。
    /// vpncmd の接続自体もログに出るので、該当行以外では動かない（チェックが自分を呼び続けないように）。
    private static func watchClientLog() {
        let fd = open(clientLogDir, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: eventQueue)
            src.setEventHandler { reopenLatestLog() }   // 日付が変わって新しいログファイルができた
            src.setCancelHandler { close(fd) }
            src.resume()
            dirSource = src
        }
        reopenLatestLog()
    }

    private static func reopenLatestLog() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: clientLogDir)) ?? []
        guard let latest = files.filter({ $0.hasSuffix(".log") }).max() else { return }
        let path = clientLogDir + "/" + latest
        guard path != logPath else { return }

        logSource?.cancel()
        logSource = nil
        logHandle = nil
        logPath = path
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        h.seekToEndOfFile()   // 過去の行は見ない
        logHandle = h
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: h.fileDescriptor,
                                                            eventMask: [.extend, .delete, .rename], queue: eventQueue)
        src.setEventHandler {
            if src.data.contains(.delete) || src.data.contains(.rename) {
                logPath = ""
                reopenLatestLog()
                return
            }
            let added = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            if added.contains("Now connected.") { trigger("vpnclient の新セッション確立") }
        }
        src.setCancelHandler { try? h.close() }
        src.resume()
        logSource = src
    }
}

final class HelperService: NSObject, VPNHelperProtocol {
    private let queue = helperOpsQueue

    func ping(reply: @escaping (Int) -> Void) {
        HLog("ping")
        reply(kHelperProtocolVersion)
    }

    func connect(account: String, reply: @escaping (Bool, String) -> Void) {
        HLog("connect(\(account)) enqueued")
        queue.async {
            HLog("connect running")
            let (ok, msg) = VPNOperations.connect(account: account)
            HLog("connect done ok=\(ok)")
            reply(ok, msg)
        }
    }

    func disconnect(account: String, reply: @escaping (Bool, String) -> Void) {
        queue.async { let (ok, msg) = VPNOperations.disconnect(account: account); reply(ok, msg) }
    }

    func enableFullTunnel(reply: @escaping (Bool, String) -> Void) {
        queue.async { let (ok, msg) = VPNOperations.enableFullTunnel(); reply(ok, msg) }
    }

    func disableFullTunnel(reply: @escaping (Bool, String) -> Void) {
        queue.async { let (ok, msg) = VPNOperations.disableFullTunnel(); reply(ok, msg) }
    }

    func setProxy(type: String, host: String, port: String, user: String, pass: String,
                  account: String, reply: @escaping (Bool, String) -> Void) {
        queue.async {
            let (ok, msg) = VPNOperations.setProxy(type: type, host: host, port: port,
                                                   user: user, pass: pass, account: account)
            reply(ok, msg)
        }
    }

    func clearProxy(account: String, reply: @escaping (Bool, String) -> Void) {
        queue.async { let (ok, msg) = VPNOperations.clearProxy(account: account); reply(ok, msg) }
    }

    func privilegedStatus(account: String, reply: @escaping (String) -> Void) {
        queue.async { reply(VPNOperations.privilegedStatus(account: account).jsonString()) }
    }

    func isConnected(reply: @escaping (Bool) -> Void) {
        // 操作キューを介さず即答（lsof のみの軽量問い合わせ。操作と競合しても害がない）。
        reply(VPNOperations.isConnected())
    }

    func setupVpnAccount(account: String, server: String, port: String, hub: String, username: String, pass: String, authType: String, reply: @escaping (Bool, String) -> Void) {
        HLog("setupVpnAccount(\(account)) enqueued")
        queue.async {
            let (ok, msg) = VPNOperations.setupVpnAccount(account: account, server: server, port: port, hub: hub, username: username, pass: pass, authType: authType)
            HLog("setupVpnAccount done ok=\(ok)")
            reply(ok, msg)
        }
    }
}
