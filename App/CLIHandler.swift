// CLI ハンドラー。ターミナルから各種操作（ヘルパー再登録、ping、接続、切断、状態確認）を
// 自動実行・検証できるようにする。

import Foundation
import ServiceManagement

enum CLIHandler {
    private static func log(_ msg: String) {
        print(msg)
        fflush(stdout)
    }

    /// CLI 引数が渡された場合は処理を実行して true を返す。
    @MainActor
    static func handleIfNeeded() async -> Bool {
        let cleanArgs = CommandLine.arguments.filter { !$0.hasPrefix("-psn_") }
        guard cleanArgs.count > 1 else { return false }

        let cmd = cleanArgs[1]
        switch cmd {
        case "--reregister-helper":
            let service = SMAppService.daemon(plistName: kHelperPlistName)
            log("[CLI] 初期登録状態: status=\(service.status.rawValue)")
            log("[CLI] ヘルパーを再登録中（差し替え直後は LWCR 修復待ちで最大 30 秒ほどかかります）...")
            do {
                let v = try await HelperClient().reregister()
                log("[CLI] XPC ping 成功! ヘルパープロトコルバージョン: \(v)")
                exit(0)
            } catch {
                log("[CLI] 再登録失敗: \(error.localizedDescription) (status=\(service.status.rawValue))")
                exit(1)
            }

        case "--ping-helper":
            let client = HelperClient()
            do {
                let v = try await client.ping()
                log("XPC ping OK! ヘルパープロトコルバージョン: \(v)")
                exit(0)
            } catch {
                log("XPC ping 失敗: \(error.localizedDescription)")
                exit(1)
            }

        case "--status":
            let client = HelperClient()
            let acc = UserDefaults.standard.string(forKey: VPNDefaults.accountKey) ?? VPNDefaults.defaultAccount
            log("=== アカウント: \(acc) ===")
            let service = SMAppService.daemon(plistName: kHelperPlistName)
            log("SMAppService Status: \(service.status.rawValue)")
            do {
                let status = try await client.privilegedStatus(account: acc)
                log("Session Established: \(status.sessionEstablished)")
                log("Session Status: \(status.sessionStatus)")
                log("Server: \(status.serverHost) (\(status.serverName))")
                log("Proxy: \(status.proxyDescription)" + (status.proxyFallbackDirect ? " [unreachable, direct]" : ""))
            } catch {
                log("特権状態取得失敗: \(error.localizedDescription)")
            }
            log("host feth IP: \(StatusProbe.hostFethIP() ?? "none")")
            log("Full Tunnel Active: \(StatusProbe.isFullTunnel())")
            log("Egress IP: \(StatusProbe.egressIP() ?? "none")")
            exit(0)

        case "--connect":
            let client = HelperClient()
            let acc = UserDefaults.standard.string(forKey: VPNDefaults.accountKey) ?? VPNDefaults.defaultAccount

            // 1) VPN アカウントの同期
            let vpnCfg = VpnStore.loadConfig()
            if vpnCfg.isUsable {
                let pass = VpnStore.loadPassword()
                log("[CLI] VPN アカウント '\(acc)' を同期中: \(vpnCfg.server):\(vpnCfg.port) (hub: \(vpnCfg.hub))...")
                do {
                    let (sOk, sMsg) = try await client.setupVpnAccount(
                        account: acc,
                        server: vpnCfg.server,
                        port: vpnCfg.port,
                        hub: vpnCfg.hub,
                        username: vpnCfg.username,
                        pass: pass,
                        authType: vpnCfg.authType
                    )
                    log("[CLI] アカウント同期結果: ok=\(sOk), msg=\(sMsg)")
                    if !sOk { exit(1) }
                } catch {
                    log("[CLI] アカウント同期例外: \(error.localizedDescription)")
                    exit(1)
                }
            }

            // 2) 保存されたプロキシ設定があり、ON なら同期
            let proxy = ProxyStore.loadConfig()
            if proxy.isUsable && ProxyStore.loadEnabled() {
                let pass = ProxyStore.loadPassword()
                log("[CLI] プロキシ設定を適用中: \(proxy.type)://\(proxy.host):\(proxy.port)...")
                do {
                    let (pOk, pMsg) = try await client.setProxy(
                        type: proxy.type,
                        host: proxy.host,
                        port: proxy.port,
                        user: proxy.user,
                        pass: pass,
                        account: acc
                    )
                    log("[CLI] プロキシ設定結果: ok=\(pOk), msg=\(pMsg)")
                } catch {
                    log("[CLI] プロキシ設定例外: \(error.localizedDescription)")
                }
            }

            // 2) 接続
            log("[CLI] アカウント '\(acc)' に接続中...")
            do {
                let (cOk, cMsg) = try await client.connect(account: acc)
                log("[CLI] 接続結果: ok=\(cOk), msg=\(cMsg)")
                guard cOk else {
                    log("[CLI] 接続失敗のため中断します。")
                    exit(1)
                }
            } catch {
                log("[CLI] 接続例外: \(error.localizedDescription)")
                exit(1)
            }

            // 3) フルトンネル投入
            log("[CLI] フルトンネルを有効化中...")
            do {
                let (ftOk, ftMsg) = try await client.enableFullTunnel()
                log("[CLI] フルトンネル結果: ok=\(ftOk), msg=\(ftMsg)")
                guard ftOk else {
                    log("[CLI] フルトンネル失敗のため中断します。")
                    exit(1)
                }
            } catch {
                log("[CLI] フルトンネル例外: \(error.localizedDescription)")
                exit(1)
            }

            log("[CLI] 出口IPを確認中...")
            if let egress = StatusProbe.egressIP() {
                log("[CLI] 接続成功! 現在の出口 IP: \(egress)")
            } else {
                log("[CLI] 接続完了 (出口 IP の取得はタイムアウトしました)")
            }
            exit(0)

        case "--disconnect":
            let client = HelperClient()
            let acc = UserDefaults.standard.string(forKey: VPNDefaults.accountKey) ?? VPNDefaults.defaultAccount

            log("[CLI] フルトンネルを解除中...")
            _ = try? await client.disableFullTunnel()

            log("[CLI] アカウント '\(acc)' を切断中...")
            do {
                let (dOk, dMsg) = try await client.disconnect(account: acc)
                log("[CLI] 切断結果: ok=\(dOk), msg=\(dMsg)")
            } catch {
                log("[CLI] 切断例外: \(error.localizedDescription)")
                exit(1)
            }
            exit(0)

        case "-h", "--help":
            log("SoftEtherFethVPN コマンドラインツール")
            log("使用法: SoftEtherFethVPN [オプション]")
            log("")
            log("オプション:")
            log("  --reregister-helper   特権ヘルパーの登録解除と再登録を実行し、XPC疎通を確認")
            log("  --ping-helper         特権ヘルパーの疎通 (ping) を確認")
            log("  --status              現在の接続状態・トンネル状態・プロキシ設定を表示")
            log("  --connect             プロキシ同期・VPN接続・フルトンネル有効化を一括実行")
            log("  --disconnect          フルトンネル無効化・VPN切断を一括実行")
            log("  -h, --help            ヘルプメッセージを表示")
            exit(0)

        default:
            return false
        }
    }
}
