// 特権ヘルパーデーモンのエントリ。launchd（SMAppService 経由）が起動する。
// mach service で待受け、接続元をメインアプリの署名要件に限定する（必須のセキュリティ境界）。

import Foundation

/// 接続を許可するクライアント（メインアプリ）の署名要件。
/// 自己署名証明書を使うため、アプリの bundle id と証明書 CN で限定する。
let kClientCodeSigningRequirement =
    "identifier \"io.github.sarukiti.softethervpn\" and certificate leaf[subject.CN] = \"SoftEther VPN Local\""

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 署名要件を満たさない接続は拒否される（macOS 13+）。
        if #available(macOS 13.0, *) {
            newConnection.setCodeSigningRequirement(kClientCodeSigningRequirement)
        }
        newConnection.exportedInterface = NSXPCInterface(with: VPNHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
listener.delegate = delegate
listener.resume()
FullTunnelWatchdog.start()
dispatchMain()
