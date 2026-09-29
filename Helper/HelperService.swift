// XPC で公開する実体。root 権限で動く。操作はルーティング等を書き換えるため
// 直列キューで実行し、競合を避ける。

import Foundation
import os

let helperLog = Logger(subsystem: "org.softether.feth.helper", category: "ops")

final class HelperService: NSObject, VPNHelperProtocol {
    private let queue = DispatchQueue(label: "org.softether.feth.helper.ops")

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
