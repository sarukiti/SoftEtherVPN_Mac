// root 不要のライブ状態取得。PoC VpnMenu.swift の isFullTunnel()/hostFethIP()/showEgress を移植。
// アプリ内部に状態をキャッシュしないので、再起動やアプリ外操作でも常に正しく反映される。

import Foundation

enum StatusProbe {
    /// フルトンネル中か（netstat に 0/1 の行があるか）。
    static func isFullTunnel() -> Bool {
        run("/usr/sbin/netstat", ["-rn", "-f", "inet"])
            .split(separator: "\n").contains { $0.hasPrefix("0/1") }
    }

    /// host 側 feth（MAC がデフォルト 66:65:74:68 でない）の inet。未接続なら nil。
    static func hostFethIP() -> String? {
        let out = run("/sbin/ifconfig", [])
        var current = "", ether = "", inet = "", result: String? = nil
        func flush() {
            if current.hasPrefix("feth"), !ether.hasPrefix("66:65:74:68"),
               !inet.isEmpty, !inet.hasPrefix("169.254") { result = inet }
        }
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let f = line.first, f != "\t", f != " " {
                flush()
                current = String(line.prefix(while: { $0 != ":" }))
                ether = ""; inet = ""
            } else {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("ether ") { ether = String(t.dropFirst(6)) }
                if t.hasPrefix("inet ") {
                    let parts = t.split(separator: " ")
                    if parts.count >= 2 { inet = String(parts[1]) }
                }
            }
        }
        flush()
        return result
    }

    /// 出口 IP。https・DNS 非依存（IP 直）の Cloudflare trace を第一候補、ipify をフォールバック。
    static func egressIP() -> String? {
        let trace = run("/usr/bin/curl", ["-sL", "--max-time", "8", "https://1.1.1.1/cdn-cgi/trace"])
        if let line = trace.split(separator: "\n").first(where: { $0.hasPrefix("ip=") }) {
            let ip = String(line.dropFirst(3))
            if !ip.isEmpty { return ip }
        }
        let alt = run("/usr/bin/curl", ["-sL", "--max-time", "8", "https://api.ipify.org"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return alt.isEmpty ? nil : alt
    }

    // MARK: -

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
