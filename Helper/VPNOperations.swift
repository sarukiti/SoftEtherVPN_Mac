// PoC の poc/vpn-*.sh を Swift に移植した中核。すべて root 前提（ヘルパー内で実行）。
// シェルは介さず Shell.run(引数配列) で system バイナリを叩く。
// 運用上の肝（自己ループ防止の例外ルート, DNS/システムプロキシ退避復元）は
// メモリ [[vpn-fulltunnel-ops]] の通り厳密に踏襲する。

import Foundation

enum VPNOperations {
    // ヘルパーバイナリの実行パスから Contents/ ディレクトリの URL を解決する
    static var bundleContentsURL: URL {
        let helperURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        // helperURL: .../SoftEtherFethVPN.app/Contents/Library/LaunchDaemons/SoftEtherVPNHelper
        // 3回親に遡ると Contents/ になる
        return helperURL
            .deletingLastPathComponent() // LaunchDaemons/
            .deletingLastPathComponent() // Library/
            .deletingLastPathComponent() // Contents/
    }

    // /tmp ではなく root 所有の永続ディレクトリに状態を退避（vpn-up が保存、vpn-down が参照）
    static let stateDir = "/Library/Application Support/SoftEtherFethVPN"

    // SoftEther はバイナリのパスから ExeDir / PidDir を解決するため、
    // アプリバンドル内のバイナリを直接叩くと Contents/Resources 内に root ファイルが作られ、
    // アプリのコード署名（Codesign）が無効化されて launchd / SMAppService から拒否されてしまう。
    // stateDir にシンボリックリンクを張り、そこ経由で実行することで全設定・ロックファイルを
    // stateDir 内に閉じ込め、アプリバンドルの署名を永続的に保護する。
    static var vpncmd: String { stateDir + "/vpncmd" }
    static var vpnclient: String { stateDir + "/vpnclient" }
    static var hamcore: String { stateDir + "/hamcore.se2" }

    static var bundleVpncmd: String { bundleContentsURL.appendingPathComponent("Resources/vpncmd").path }
    static var bundleVpnclient: String { bundleContentsURL.appendingPathComponent("Resources/vpnclient").path }
    static var bundleHamcore: String { bundleContentsURL.appendingPathComponent("Resources/hamcore.se2").path }

    static func ensureStateDirBinaries() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let pairs = [
            (vpncmd, bundleVpncmd),
            (vpnclient, bundleVpnclient),
            (hamcore, bundleHamcore)
        ]
        for (target, src) in pairs {
            if fm.fileExists(atPath: target) {
                if let dest = try? fm.destinationOfSymbolicLink(atPath: target), dest == src {
                    continue
                }
                try? fm.removeItem(atPath: target)
            }
            do {
                try fm.createSymbolicLink(atPath: target, withDestinationPath: src)
                HLog("ensureStateDirBinaries: linked \(target) -> \(src)")
            } catch {
                HLog("ensureStateDirBinaries: link failed for \(target): \(error.localizedDescription)")
            }
        }
    }

    static let route = "/sbin/route"
    static let netstat = "/usr/sbin/netstat"
    static let networksetup = "/usr/sbin/networksetup"
    static let ipconfig = "/usr/sbin/ipconfig"
    static let ifconfig = "/sbin/ifconfig"
    static let lsof = "/usr/sbin/lsof"
    static let dscacheutil = "/usr/bin/dscacheutil"
    static let killall = "/usr/bin/killall"

    // MARK: - 状態ファイル

    private static func ensureStateDir() {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    }
    private static func writeState(_ name: String, _ content: String) {
        ensureStateDir()
        try? content.write(toFile: stateDir + "/" + name, atomically: true, encoding: .utf8)
    }
    /// パスワード等を含む state を root のみ読み書き可能（0600）で保存する。
    private static func writeStateSecure(_ name: String, _ content: String) {
        ensureStateDir()
        let path = stateDir + "/" + name
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    private static func readState(_ name: String) -> String {
        (try? String(contentsOfFile: stateDir + "/" + name, encoding: .utf8)) ?? ""
    }
    private static func stateExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: stateDir + "/" + name)
    }
    private static func removeState(_ name: String) {
        try? FileManager.default.removeItem(atPath: stateDir + "/" + name)
    }

    /// フルトンネル投入済みマーカー（PoC の /tmp/vpn_up.lock 相当）。
    /// 二重 up で「元の DNS/プロキシ」バックアップを VPN 値で上書きしないために使う。
    private static let upLock = "up.lock"
    private static let savedHostRoutesFile = "saved_host_routes"

    // MARK: - feth 検出

    /// host 側 feth = MAC がデフォルト 66:65:74:68 でない方（接続直後/DHCP 前でも使える）。
    static func hostFethByMAC() -> String? {
        for name in fethInterfaces() {
            let ether = Shell.out(ifconfig, [name]).lines()
                .first(where: { $0.trimmed().hasPrefix("ether ") })?
                .trimmed().dropFirst(6).trimmed() ?? ""
            if !ether.isEmpty && !ether.hasPrefix("66:65:74:68") { return name }
        }
        return nil
    }

    /// host 側 feth = 実 inet（link-local でない）を持つ feth と、その IP。
    static func hostFethByIP() -> (name: String, ip: String)? {
        for name in fethInterfaces() {
            let ip = Shell.out(ipconfig, ["getifaddr", name])
            if !ip.isEmpty && !ip.hasPrefix("169.254") { return (name, ip) }
        }
        return nil
    }

    private static func fethInterfaces() -> [String] {
        Shell.out(ifconfig, ["-l"]).split(separator: " ").map(String.init).filter { $0.hasPrefix("feth") }
    }

    // MARK: - connect / disconnect

    static func connect(account: String) -> (Bool, String) {
        var log = ""
        
        // vpnclient の起動と常駐を確認
        if !startVpnClientIfNeeded() {
            return (false, "vpnclient の起動に失敗しました。")
        }
        
        HLog("connect: AccountConnect 開始 (\(account))")
        let connRes = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountConnect", account], timeout: 20)
        if !connRes.ok {
            HLog("connect: AccountConnect 失敗: \(connRes.stderr)")
            return (false, "AccountConnect 失敗: \(connRes.stderr)")
        }

        // Session Established を最大 30 秒待つ（プロキシ接続時のハンドシェイク時間を十分に考慮）
        var established = false
        var lastStatus = ""
        for i in 1...30 {
            Thread.sleep(forTimeInterval: 1)
            let st = Shell.out(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountStatusGet", account], timeout: 15)
            if st.contains("Session Established") {
                established = true
                HLog("connect: session established (\(i)秒)")
                break
            }
            for line in st.lines() where line.contains("Session Status") {
                lastStatus = line.components(separatedBy: "|").last?.trimmed() ?? ""
            }
        }
        if !established {
            _ = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountDisconnect", account], timeout: 15)
            _ = releaseFethAddressesAndRoutes()
            let reason = lastStatus.isEmpty ? "タイムアウト" : lastStatus
            return (false, "VPN セッションの確立に失敗しました (状態: \(reason))。プロキシ設定や接続先サーバを確認してください。")
        }
        log += "session established\n"

        // host 側 feth の検出（最大 5 秒待機）
        var hostFeth: String? = nil
        for _ in 1...10 {
            if let f = hostFethByMAC() {
                hostFeth = f
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard let feth = hostFeth else {
            _ = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountDisconnect", account], timeout: 15)
            _ = releaseFethAddressesAndRoutes()
            return (false, log + "host feth が見つかりません（仮想NIC未作成または未接続）")
        }

        HLog("connect: feth \(feth) に DHCP 要求を実行")
        _ = Shell.run(ipconfig, ["set", feth, "DHCP"], timeout: 10)
        var ip = ""
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 1)
            ip = Shell.out(ipconfig, ["getifaddr", feth])
            if !ip.isEmpty && !ip.hasPrefix("169.254") { break }
        }
        if ip.isEmpty || ip.hasPrefix("169.254") {
            _ = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountDisconnect", account], timeout: 15)
            _ = releaseFethAddressesAndRoutes()
            return (false, log + "DHCP失敗: \(feth) ip=\(ip.isEmpty ? "none" : ip)")
        }
        let gw = Shell.out(ipconfig, ["getoption", feth, "router"]).trimmed()
        HLog("connect: 接続成功: \(feth) ip=\(ip) gw=\(gw)")
        return (true, log + "connected: \(feth) ip=\(ip) gw=\(gw)")
    }

    static func disconnect(account: String) -> (Bool, String) {
        let (_, downMsg) = disableFullTunnel()                 // 張っていなければ無害
        _ = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountDisconnect", account], timeout: 15)
        // セッションが消えても feth の DHCP IP と feth 経由 default は残るため明示的に解放する。
        // これをしないと hostFethIP() が古い IP を返し続け、UI が「接続中」と誤表示する。
        let cleaned = releaseFethAddressesAndRoutes()
        return (true, "disconnected: \(account)\n\(downMsg)\n\(cleaned)")
    }

    /// 全 feth の DHCP/IP を解放し（ipconfig set NONE）、feth 経由で残る default を
    /// -ifscope で限定削除する。PoC vpn-down.sh の feth 後片付け相当。仮想NICペア自体は残す。
    @discardableResult
    static func releaseFethAddressesAndRoutes() -> String {
        var log = ""
        // 1) feth 経由の残存 default を ifscope で削除（en0 側のグローバル default を誤消去しないため）
        for feth in fethDefaultRouteInterfaces() {
            _ = Shell.run(route, ["-n", "delete", "-ifscope", feth, "default"])
            // ifscope 非対応の残骸用に GW 指定でも試す
            let gw = fethDefaultGateway(for: feth)
            if !gw.isEmpty { _ = Shell.run(route, ["-n", "delete", "default", gw]) }
            log += "removed default via \(feth)\n"
        }
        // 2) feth の IP 設定を解放（link-local/未設定は触らない）
        for feth in fethInterfaces() {
            let ip = Shell.out(ipconfig, ["getifaddr", feth])
            if ip.isEmpty || ip.hasPrefix("169.254") { continue }
            _ = Shell.run(ipconfig, ["set", feth, "NONE"])
            log += "released \(feth) (\(ip))\n"
        }
        return log.isEmpty ? "feth: 解放対象なし" : log
    }

    /// `default` 宛の経路がインターフェース feth* に紐づいているものの一覧。
    private static func fethDefaultRouteInterfaces() -> [String] {
        var set = Set<String>()
        for line in Shell.out(netstat, ["-rn", "-f", "inet"]).lines() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.first == "default", let last = cols.last, last.hasPrefix("feth") else { continue }
            set.insert(last)
        }
        return set.sorted()
    }

    /// 指定 feth に紐づく default 経路のゲートウェイ。
    private static func fethDefaultGateway(for feth: String) -> String {
        for line in Shell.out(netstat, ["-rn", "-f", "inet"]).lines() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if cols.first == "default", cols.last == feth, cols.count >= 2 { return cols[1] }
        }
        return ""
    }

    // MARK: - full tunnel up / down

    static func enableFullTunnel() -> (Bool, String) {
        var log = ""
        // 二重 up 検知。既に up 済みなら「元の状態」バックアップ（DNS/プロキシ）を上書きしない。
        let alreadyUp = stateExists(upLock)
        if alreadyUp { log += "既に up 済み: 元状態のバックアップは保持し、ルート/DNS のみ再適用\n" }

        // 1) 物理回線の既定 GW/IF（トンネル投入前に取得）
        let def = Shell.out(route, ["-n", "get", "default"])
        var physGW = def.value(after: "gateway:")
        var physIF = def.value(after: "interface:")
        if physIF.hasPrefix("feth") || physIF.hasPrefix("utun") || physGW.isEmpty || physIF.isEmpty {
            for line in Shell.out(netstat, ["-rn", "-f", "inet"]).lines() {
                let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard cols.first == "default", cols.count >= 4 else { continue }
                let iface = cols.last ?? ""
                if !iface.hasPrefix("feth") && !iface.hasPrefix("utun") && !iface.hasPrefix("lo") {
                    physGW = cols[1]
                    physIF = iface
                    break
                }
            }
        }
        if physIF.isEmpty { physIF = "en0" }

        // 2) host feth（実 inet を持つ方）
        guard let host = hostFethByIP() else {
            return (false, "実IPを持つ host 側 feth が見つかりません。先に接続してください。")
        }
        let feth = host.name, fethIP = host.ip

        // 3) VPN GW（DHCP router option → 同/16 の .254.254）
        var vpnGW = Shell.out(ipconfig, ["getoption", feth, "router"])
        if vpnGW.isEmpty {
            let oct = fethIP.split(separator: ".")
            if oct.count == 4 { vpnGW = "\(oct[0]).\(oct[1]).254.254" }
        }
        if physGW.isEmpty || vpnGW.isEmpty {
            return (false, "GW 検出失敗 phys_gw=\(physGW) vpn_gw=\(vpnGW)")
        }

        // 4) 物理 IF のネットワークサービス名
        let svc = networkServiceName(for: physIF)

        // 5) 例外ホストルート対象の収集（VPNサーバ実IP、プロキシIP、ローカルDNSなど）
        var exceptionIPs = Set<String>()

        // 5-A) vpnclient の ESTABLISHED 相手（最大5秒リトライで待機）
        var peerIPs = [String]()
        for _ in 0..<10 {
            peerIPs = vpnclientEstablishedPeers()
            if !peerIPs.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        for ip in peerIPs where isValidIPv4(ip) {
            exceptionIPs.insert(ip)
        }

        // 5-B) 保存されたプロキシ設定のホスト名から IP を解決して追加
        let savedProxyCfg = readState(proxyConfigFile)
        if !savedProxyCfg.isEmpty {
            let f = savedProxyCfg.components(separatedBy: "\n")
            if f.count >= 2, !f[1].isEmpty {
                let resolved = resolveHostIPs(f[1])
                for ip in resolved { exceptionIPs.insert(ip) }
            }
        }

        // 5-C) 物理回線側のローカル DNS サーバ（物理ネットワークで使われていた DNS）
        // プロキシ環境では学内/社内 DNS 経由で名前解決するため、フルトンネルでローカル DNS 宛てが
        // VPN に吸われるとプロキシの再解決やローカル通信が死ぬ。物理 GW への例外ルートに追加する。
        let rawPhysDNS = Shell.out(networksetup, ["-getdnsservers", svc])
        for line in rawPhysDNS.lines() {
            let ip = line.trimmed()
            if isValidIPv4(ip) { exceptionIPs.insert(ip) }
        }
        let dhcpPhysDNS = Shell.out(ipconfig, ["getoption", physIF, "domain_name_servers"])
        for part in dhcpPhysDNS.split(separator: " ") {
            let ip = String(part).trimmed()
            if isValidIPv4(ip) { exceptionIPs.insert(ip) }
        }

        if exceptionIPs.isEmpty {
            return (false, "VPN 通信先（プロキシ/サーバ）の実 IP を検出できませんでした（vpnclient が未接続の可能性）")
        }

        // down 用に保存
        writeState("phys_if", physIF)
        writeState("svc", svc)
        writeState("server_ips", exceptionIPs.sorted().joined(separator: "\n"))
        writeState(savedHostRoutesFile, exceptionIPs.sorted().joined(separator: "\n"))

        log += "iface=\(feth) feth_ip=\(fethIP) vpn_gw=\(vpnGW) phys_gw=\(physGW) phys_if=\(physIF) svc=\(svc)\n"
        log += "exceptions -> 物理回線: \(exceptionIPs.sorted().joined(separator: " "))\n"

        // 6) 例外: VPN サーバ・プロキシ・ローカルDNS宛てを物理回線へ（自己ループ・名前解決不能を防止）
        for ip in exceptionIPs {
            let r = Shell.run(route, ["-n", "add", "-host", ip, physGW])
            if !r.ok { _ = Shell.run(route, ["-n", "change", "-host", ip, physGW]) }
        }

        // 7) フルトンネル: 0/1 と 128/1
        for net in ["0.0.0.0/1", "128.0.0.0/1"] {
            let r = Shell.run(route, ["-n", "add", "-net", net, vpnGW])
            if !r.ok { _ = Shell.run(route, ["-n", "change", "-net", net, vpnGW]) }
        }

        // 8) DNS 設定（VPN側 DHCP DNS を優先、無ければ 1.1.1.1/8.8.8.8 にフォールバック）
        if !alreadyUp {
            writeState("saved_dns", rawPhysDNS)
        }
        let rawVpnDNS = Shell.out(ipconfig, ["getoption", feth, "domain_name_servers"])
        let vpnDNSServers = rawVpnDNS.split(separator: " ").map(String.init).map { $0.trimmed() }.filter { isValidIPv4($0) }
        if !vpnDNSServers.isEmpty {
            _ = Shell.run(networksetup, ["-setdnsservers", svc] + vpnDNSServers)
            log += "dns -> VPN DHCP: \(vpnDNSServers.joined(separator: " "))\n"
        } else {
            _ = Shell.run(networksetup, ["-setdnsservers", svc, "1.1.1.1", "8.8.8.8"])
            log += "dns -> fallback (1.1.1.1 8.8.8.8)\n"
        }
        flushDNS()

        // 8.5) システムプロキシ & PAC を退避して OFF（初回 up のときだけ退避）
        if !alreadyUp {
            let web = proxyState(svc, "-getwebproxy")
            let sec = proxyState(svc, "-getsecurewebproxy")
            let socks = proxyState(svc, "-getsocksfirewallproxy")
            let auto = proxyState(svc, "-getautoproxyurl")
            let discover = proxyState(svc, "-getproxyautodiscovery")
            writeState("saved_proxy", "\(web)\n\(sec)\n\(socks)\n\(auto)\n\(discover)")
            log += "system proxy saved: web=\(web) sec=\(sec) socks=\(socks) auto=\(auto) discover=\(discover)\n"
        }
        _ = Shell.run(networksetup, ["-setwebproxystate", svc, "off"])
        _ = Shell.run(networksetup, ["-setsecurewebproxystate", svc, "off"])
        _ = Shell.run(networksetup, ["-setsocksfirewallproxystate", svc, "off"])
        _ = Shell.run(networksetup, ["-setautoproxystate", svc, "off"])
        _ = Shell.run(networksetup, ["-setproxyautodiscovery", svc, "off"])
        log += "system proxy & PAC -> all OFF（down で復元）\n"

        // up 完了マーカー（down が掃除する）。これで再 up しても元状態を汚さない。
        writeState(upLock, "1")
        log += "full-tunnel up. egress 確認: curl https://1.1.1.1/cdn-cgi/trace"
        return (true, log)
    }

    static func disableFullTunnel() -> (Bool, String) {
        let wasUp = stateExists(upLock)
        var log = ""
        var svc = readState("svc").trimmed()
        if svc.isEmpty { svc = "Wi-Fi" }

        // フルトンネル 2 本を削除（元の default(/0) が復活する）
        for net in ["0.0.0.0/1", "128.0.0.0/1"] { _ = Shell.run(route, ["-n", "delete", "-net", net]) }
        // feth 経由で残った default を ifscope で削除。これが残ると切断後もトラフィックが
        // 死んだトンネルへ吸われ、物理回線(en0)の default があっても通信不能になる。
        for feth in fethDefaultRouteInterfaces() {
            _ = Shell.run(route, ["-n", "delete", "-ifscope", feth, "default"])
            let gw = fethDefaultGateway(for: feth)
            if !gw.isEmpty { _ = Shell.run(route, ["-n", "delete", "default", gw]) }
        }

        // 保存された例外ホストルート（VPNサーバ、プロキシ、DNS等）をすべて掃除
        let savedRoutes = (readState(savedHostRoutesFile) + "\n" + readState("server_ips")).lines().filter { !$0.isEmpty }
        for ip in Set(savedRoutes) where isValidIPv4(ip) {
            _ = Shell.run(route, ["-n", "delete", "-host", ip])
        }
        removeState(savedHostRoutesFile)
        removeState("server_ips")

        // フルトンネルを張っていなかったなら、DNS/プロキシは元々いじっていないので復元しない
        guard wasUp else {
            removeState(upLock)
            return (true, "full-tunnel down（張っていなかったためルート掃除のみ）\n\(log)")
        }

        // DNS 復元。保存値が空/「公開リゾルバ」＝汚染とみなせる場合は安全側に Empty(DHCP) へ倒す。
        let savedDNS = readState("saved_dns")
        let dnsServers = savedDNS.lines()
            .map { $0.trimmed() }
            .filter { isValidIPv4($0) }
        let contaminated = dnsServers.contains("1.1.1.1") || dnsServers.contains("8.8.8.8")
        if dnsServers.isEmpty || contaminated {
            _ = Shell.run(networksetup, ["-setdnsservers", svc, "Empty"])
            log += "dns -> Empty(DHCP)\n"
        } else {
            _ = Shell.run(networksetup, ["-setdnsservers", svc] + dnsServers)
            log += "dns -> \(dnsServers.joined(separator: " "))\n"
        }
        flushDNS()

        // システムプロキシ & PAC 復元（up 時に Yes だったものだけ on）
        let savedProxy = readState("saved_proxy").lines()
        if savedProxy.count >= 3 {
            if savedProxy[0] == "Yes" { _ = Shell.run(networksetup, ["-setwebproxystate", svc, "on"]) }
            if savedProxy[1] == "Yes" { _ = Shell.run(networksetup, ["-setsecurewebproxystate", svc, "on"]) }
            if savedProxy[2] == "Yes" { _ = Shell.run(networksetup, ["-setsocksfirewallproxystate", svc, "on"]) }
            if savedProxy.count >= 4 && savedProxy[3] == "Yes" { _ = Shell.run(networksetup, ["-setautoproxystate", svc, "on"]) }
            if savedProxy.count >= 5 && (savedProxy[4] == "Yes" || savedProxy[4] == "On") { _ = Shell.run(networksetup, ["-setproxyautodiscovery", svc, "on"]) }
            log += "proxy & PAC restored: web=\(savedProxy[0]) sec=\(savedProxy[1]) socks=\(savedProxy[2])\n"
        }

        // up マーカーを掃除（次回の up を確実に「初回」にする）
        removeState(upLock)
        return (true, "full-tunnel down（物理回線/DNS/システムプロキシを復元）\n\(log)")
    }

    // MARK: - proxy

    // setupVpnAccount は AccountDelete→AccountCreate でアカウントを作り直すため、
    // そのたびに AccountProxyHttp/Socks 設定が失われ Direct に戻ってしまう。
    // プロキシ設定をこの state ファイルに退避し、アカウント再作成後に必ず再適用する。
    // パスワードを含むため root のみ読める 0600 で保存する。
    private static let proxyConfigFile = "proxy_config"

    static func setProxy(type: String, host: String, port: String, user: String, pass: String,
                         account: String) -> (Bool, String) {
        guard type == "http" || type == "socks" else { return (false, "unknown proxy type: \(type)") }
        guard !host.isEmpty, !port.isEmpty else { return (false, "host/port が空です") }
        
        _ = startVpnClientIfNeeded()

        // アカウント再作成をまたいで生き残るよう退避（type|host|port|user|pass の5行固定）
        writeStateSecure(proxyConfigFile, [type, host, port, user, pass].joined(separator: "\n"))

        // アカウントが存在する場合は vpnclient に即座に適用
        let accountList = Shell.out(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountList"])
        if accountList.contains(account) {
            let (ok, msg) = applyProxyConfig(type: type, host: host, port: port, user: user, pass: pass, account: account)
            guard ok else { return (false, msg) }
        }

        return (true, "proxy: \(type) \(host):\(port)\(user.isEmpty ? "" : " (auth: \(user))")\n反映には再接続が必要です。")
    }

    static func clearProxy(account: String) -> (Bool, String) {
        removeState(proxyConfigFile)
        _ = startVpnClientIfNeeded()
        let accountList = Shell.out(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountList"])
        if accountList.contains(account) {
            let r = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountProxyNone", account], timeout: 15)
            guard r.ok else { return (false, "vpncmd 失敗: \(r.stdout)\(r.stderr)") }
        }
        return (true, "proxy: none (direct)")
    }

    /// 実際に vpncmd へプロキシ設定を投入する共通処理（setProxy と setupVpnAccount から使う）。
    private static func applyProxyConfig(type: String, host: String, port: String,
                                         user: String, pass: String, account: String) -> (Bool, String) {
        let cmd = type == "http" ? "AccountProxyHttp" : "AccountProxySocks"
        var args = ["/CLIENT", "127.0.0.1", "/CMD", cmd, account, "/SERVER:\(host):\(port)"]
        if !user.isEmpty { args.append("/USERNAME:\(user)") }
        if !pass.isEmpty { args.append("/PASSWORD:\(pass)") }
        let r = Shell.run(vpncmd, args, timeout: 15)
        guard r.ok else { return (false, "vpncmd 失敗: \(r.stdout)\(r.stderr)") }
        return (true, "")
    }

    /// 退避済みプロキシ設定があれば account に再適用する。setupVpnAccount の末尾で呼ぶ。
    /// アカウント作り直しでプロキシが Direct に戻る問題への対策。
    @discardableResult
    private static func reapplySavedProxy(account: String) -> String {
        let raw = readState(proxyConfigFile)
        guard !raw.isEmpty else { return "" }
        let f = raw.components(separatedBy: "\n")
        guard f.count >= 5, f[0] == "http" || f[0] == "socks", !f[1].isEmpty, !f[2].isEmpty else { return "" }
        let (ok, msg) = applyProxyConfig(type: f[0], host: f[1], port: f[2], user: f[3], pass: f[4], account: account)
        return ok ? "proxy 再適用: \(f[0]) \(f[1]):\(f[2])\n" : "proxy 再適用に失敗: \(msg)\n"
    }

    // MARK: - privileged status

    static func privilegedStatus(account: String) -> PrivilegedStatus {
        _ = startVpnClientIfNeeded()

        // セッション状態（AccountStatusGet）
        let st = Shell.out(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountStatusGet", account], timeout: 15)
        if st.isEmpty {
            return PrivilegedStatus(raw: "(取得失敗: vpnclient 未起動 / 管理接続不可)")
        }
        // "Session Status | Retrying" のように | 区切り。値側を取る。
        func field(_ text: String, _ key: String) -> String {
            for line in text.lines() where line.contains(key) {
                return line.components(separatedBy: "|").last?.trimmed() ?? ""
            }
            return ""
        }
        let sessionStatus = field(st, "Session Status")
        // 真の接続判定は vpnclient が ESTABLISHED な対向を持っているか。AccountStatusGet の
        // テキストは最後の状態を引きずることがあるため、実ソケットの有無で確定させる。
        let established = !vpnclientEstablishedPeers().isEmpty
        let serverName = field(st, "Server Name")

        // アカウント設定（AccountGet）から実際のサーバ/プロキシをライブ取得
        let cfg = Shell.out(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountGet", account], timeout: 15)
        let host = field(cfg, "Destination VPN Server Host Name")
        let port = field(cfg, "Destination VPN Server Port Number")
        let serverHost = host.isEmpty ? "" : (port.isEmpty ? host : "\(host):\(port)")

        let ptype = field(cfg, "Proxy Server Type")           // "Direct TCP/IP Connection" / "Connection via HTTP Proxy" / "... SOCKS Proxy"
        let phost = field(cfg, "Proxy Server Host Name")
        let pport = field(cfg, "Proxy Server Port Number")
        let proxyDescription: String
        if ptype.contains("HTTP") {
            proxyDescription = "http \(phost):\(pport)"
        } else if ptype.contains("SOCKS") {
            proxyDescription = "socks \(phost):\(pport)"
        } else {
            // アカウント側が未作成/Directだが、stateに保存されたプロキシ設定がある場合のフォールバック表示
            let raw = readState(proxyConfigFile)
            let f = raw.components(separatedBy: "\n")
            if f.count >= 3 && !f[1].isEmpty && !f[2].isEmpty {
                proxyDescription = "\(f[0]) \(f[1]):\(f[2])"
            } else {
                proxyDescription = "なし"                          // Direct TCP/IP Connection 等
            }
        }

        return PrivilegedStatus(sessionEstablished: established, sessionStatus: sessionStatus,
                                serverName: serverName, serverHost: serverHost,
                                proxyDescription: proxyDescription, raw: "")
    }

    // MARK: - 接続判定（軽量・root 必須）

    /// 接続中か＝vpnclient が ESTABLISHED な対向を 1 本でも持っているか。
    /// メニューバーアイコン用の軽量問い合わせ。feth の残存 IP に依存しない真の判定。
    static func isConnected() -> Bool {
        !vpnclientEstablishedPeers().isEmpty
    }

    // MARK: - helpers

    /// vpnclient プロセスが張る ESTABLISHED ソケットの相手 IP（loopback/link-local を除外）。
    private static func vpnclientEstablishedPeers() -> [String] {
        let out = Shell.out(lsof, ["-nP", "-iTCP", "-a", "-c", "vpnclient"])
        var ips = Set<String>()
        for line in out.lines() where line.contains("ESTABLISHED") {
            // 例: "...  1.2.3.4:54321->5.6.7.8:443 (ESTABLISHED)"  → 5.6.7.8
            guard let arrow = line.range(of: "->") else { continue }
            var tail = String(line[arrow.upperBound...])
            tail = tail.components(separatedBy: " ").first ?? tail
            tail = tail.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            // 末尾 :port を削る（IPv6 は最後のコロンが区切り）
            if let lastColon = tail.lastIndex(of: ":") { tail = String(tail[..<lastColon]) }
            let ip = tail.trimmed()
            if ip.isEmpty { continue }
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") || ip == "::1" || ip.hasPrefix("fe80") { continue }
            ips.insert(ip)
        }
        return ips.sorted()
    }

    /// 物理 IF 名 → ネットワークサービス名（DNS/プロキシはサービス単位で設定する）。
    private static func networkServiceName(for physIF: String) -> String {
        let out = Shell.out(networksetup, ["-listnetworkserviceorder"])
        // "(Hardware Port: Wi-Fi, Device: en0)" の塊から physIF を含む行のポート名を拾う
        let blocks = out.components(separatedBy: "(Hardware Port:")
        for b in blocks {
            if b.contains("Device: \(physIF))") {
                if let comma = b.firstIndex(of: ",") {
                    return String(b[b.startIndex..<comma]).trimmed()
                }
            }
        }
        return "Wi-Fi"
    }

    private static func proxyState(_ svc: String, _ getter: String) -> String {
        let out = Shell.out(networksetup, [getter, svc])
        for line in out.lines() {
            let t = line.trimmed()
            if t.hasPrefix("Enabled:") {
                return t.replacingOccurrences(of: "Enabled:", with: "").trimmed()
            }
            if t.hasPrefix("Auto Proxy Discovery:") {
                return t.replacingOccurrences(of: "Auto Proxy Discovery:", with: "").trimmed()
            }
        }
        return "No"
    }

    /// ホスト名（FQDNまたはIP）からIPv4アドレス一覧を名前解決して取得
    static func resolveHostIPs(_ host: String) -> [String] {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.isEmpty { return [] }
        if isValidIPv4(cleanHost) { return [cleanHost] }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(cleanHost, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }

        var ips = Set<String>()
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let curr = ptr {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(curr.pointee.ai_addr, curr.pointee.ai_addrlen,
                           &hostBuffer, socklen_t(hostBuffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostBuffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if isValidIPv4(ip) {
                    ips.insert(ip)
                }
            }
            ptr = curr.pointee.ai_next
        }
        return ips.sorted()
    }

    /// 有効なグローバル/プライベートIPv4アドレスか（ループバック・リンクローカル・空文字は除外）
    static func isValidIPv4(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("127.") || trimmed.hasPrefix("169.254.") { return false }
        return trimmed.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil
    }

    private static func flushDNS() {
        _ = Shell.run(dscacheutil, ["-flushcache"])
        _ = Shell.run(killall, ["-HUP", "mDNSResponder"])
    }

    // MARK: - SoftEther VPN アカウント設定

    /// SoftEther VPN 接続アカウントの作成・上書き設定
    static func setupVpnAccount(account: String, server: String, port: String, hub: String, username: String, pass: String, authType: String) -> (Bool, String) {
        var log = ""
        HLog("setupVpnAccount: 開始")
        
        // 1. vpnclient の起動と常駐を確認
        if !startVpnClientIfNeeded() {
            HLog("setupVpnAccount: vpnclient の起動に失敗")
            return (false, "vpnclient の起動に失敗しました。")
        }

        // アカウント設定消去（クリア）の場合（server が空）
        if server.isEmpty {
            let accountList = Shell.out(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountList"])
            if accountList.contains(account) {
                _ = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountDelete", account])
            }
            HLog("setupVpnAccount: アカウント \(account) を削除しました")
            return (true, "接続アカウント \(account) を削除しました。")
        }
        
        let nicName = "feth"
        
        // 2. 仮想NICの確認（既に存在していれば無駄な削除・再作成を避けて再利用する）
        let nicList = Shell.out(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "NicList"])
        let nicExistsInVpnClient = nicList.contains(nicName)
        let hasOSFeth = !fethInterfaces().isEmpty

        if !nicExistsInVpnClient || !hasOSFeth {
            if nicExistsInVpnClient {
                HLog("setupVpnAccount: OS側fethが存在しないため仮想NIC \(nicName) を一度削除して再作成します")
                _ = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "NicDelete", nicName])
            }
            HLog("setupVpnAccount: OS側の残存 feth デバイスを破棄して新規作成します")
            _ = destroyAllFethInterfaces()
            let r = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "NicCreate", nicName])
            if !r.ok {
                HLog("setupVpnAccount: NIC作成失敗: \(r.stderr)")
                return (false, "仮想NICの作成に失敗しました: \(r.stderr)")
            }
            // OS側の仮想NICデバイスバインドのタイムラグを回避するため待機
            Thread.sleep(forTimeInterval: 1.5)
        } else {
            HLog("setupVpnAccount: 既存の仮想NIC \(nicName) を再利用します")
        }
        
        // 3. アカウントの重複削除
        let accountList = Shell.out(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountList"])
        if accountList.contains(account) {
            HLog("setupVpnAccount: 既存のアカウント \(account) を更新のため一度削除")
            _ = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountDelete", account])
        }
        
        // 4. アカウント新規作成
        HLog("setupVpnAccount: アカウント作成試行: \(account) server=\(server):\(port)")
        let createRes = Shell.run(vpncmd, [
            "/CLIENT", "127.0.0.1", "/CMD", "AccountCreate", account,
            "/SERVER:\(server):\(port)", "/HUB:\(hub)", "/USERNAME:\(username)", "/NICNAME:\(nicName)"
        ])
        
        guard createRes.ok else {
            HLog("setupVpnAccount: アカウント作成失敗: \(createRes.stderr)")
            return (false, "アカウントの作成に失敗しました: \(createRes.stderr)")
        }
        
        // 5. 認証情報設定
        if authType.lowercased() == "anonymous" {
            HLog("setupVpnAccount: 匿名認証を設定")
            let r = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountAnonymousSet", account])
            if !r.ok { return (false, "匿名認証の設定に失敗しました: \(r.stderr)") }
        } else {
            HLog("setupVpnAccount: パスワード認証を設定")
            let r = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "AccountPasswordSet", account, "/PASSWORD:\(pass)", "/TYPE:standard"])
            if !r.ok { return (false, "パスワード認証の設定に失敗しました: \(r.stderr)") }
        }

        // 6. アカウント作り直しで失われたプロキシ設定を再適用（保存済みがあれば）
        let proxyLog = reapplySavedProxy(account: account)
        if !proxyLog.isEmpty {
            HLog("setupVpnAccount: \(proxyLog.trimmed())")
            log += proxyLog
        }

        HLog("setupVpnAccount: 完了")
        return (true, "接続アカウント \(account) の設定が完了しました！\n\(log)")
    }

    // MARK: - vpnclient デーモン起動管理

    /// 停止中または応答不能な vpnclient プロセスと古いロックファイルを強制クリーンアップ
    static func stopVpnClient() {
        HLog("stopVpnClient: 停止とクリーンアップを開始")
        _ = Shell.run(vpnclient, ["stop"], timeout: 5)
        _ = Shell.run(killall, ["-9", "vpnclient"], timeout: 5)
        
        let fm = FileManager.default

        // 1. stateDir 内の古い .ctl_* や .pid_* をクリーンアップ
        if let stateFiles = try? fm.contentsOfDirectory(atPath: stateDir) {
            for file in stateFiles {
                if file.hasPrefix(".ctl_") || file.hasPrefix(".pid_") || file.hasPrefix(".Global") {
                    let fullPath = stateDir + "/" + file
                    HLog("stopVpnClient: stateDir の古いロックファイルを削除: \(file)")
                    try? fm.removeItem(atPath: fullPath)
                }
            }
        }

        // 2. Resources ディレクトリ内に紛れ込んだ root 所有ファイルを徹底的に掃除し、アプリ署名を健全化
        let resourcesDir = bundleContentsURL.appendingPathComponent("Resources").path
        if let resFiles = try? fm.contentsOfDirectory(atPath: resourcesDir) {
            for file in resFiles {
                // 署名対象外の動的生成ファイル（.ctl_*, .pid_*, .Global*, vpn_client.config, backup.*, client_log, lang.config）
                if file.hasPrefix(".ctl_") || file.hasPrefix(".pid_") || file.hasPrefix(".Global") ||
                   file.hasPrefix("vpn_client.config") || file.hasPrefix("backup.") ||
                   file == "client_log" || file == "lang.config" {
                    let fullPath = resourcesDir + "/" + file
                    HLog("stopVpnClient: Resources 内の汚染ファイルを削除（署名復元）: \(file)")
                    try? fm.removeItem(atPath: fullPath)
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// 必要に応じて vpnclient デーモンを起動する
    static func startVpnClientIfNeeded() -> Bool {
        HLog("startVpnClientIfNeeded: 開始 (stateDir=\(stateDir))")
        
        // 1. stateDir の作成とシンボリックリンクの準備
        ensureStateDirBinaries()
        
        // 2. すでに vpnclient が正常に起動してコマンド応答するか確認
        if isVpnClientRunning() {
            HLog("startVpnClientIfNeeded: vpnclient は既に正常稼働中")
            return true
        }
        
        // 3. 正常応答しない場合、古いプロセスや壊れたロックファイルの残骸がある可能性があるため停止・掃除
        HLog("startVpnClientIfNeeded: vpnclient が応答しないため、停止・クリーンアップ後に新規起動します")
        stopVpnClient()
        
        // 4. stateDir をカレントディレクトリとして vpnclient をバックグラウンド起動
        HLog("startVpnClientIfNeeded: vpnclient 起動試行: \(vpnclient) start")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: vpnclient)
        process.arguments = ["start"]
        process.currentDirectoryURL = URL(fileURLWithPath: stateDir)
        
        do {
            try process.run()
            process.waitUntilExit()
            HLog("startVpnClientIfNeeded: process.run() 完了、終了コード = \(process.terminationStatus)")
            
            // 起動・初期化完了を最大 15 秒間ポーリングして待つ (30 x 0.5s)
            for i in 1...30 {
                Thread.sleep(forTimeInterval: 0.5)
                if isVpnClientRunning() {
                    HLog("startVpnClientIfNeeded: 起動確認成功 (試行 \(i) 回目, \((Double(i) * 0.5))秒)")
                    // 起動中のポート情報をログに記録
                    let lsofRes = Shell.run(lsof, ["-nP", "-c", "vpnclient", "-a", "-iTCP"])
                    HLog("startVpnClientIfNeeded: vpnclient TCPポート状態:\n\(lsofRes.stdout)")
                    return true
                }
            }
            HLog("startVpnClientIfNeeded: 起動確認タイムアウト (15秒)")
            let lsofFail = Shell.run(lsof, ["-nP", "-c", "vpnclient"])
            HLog("startVpnClientIfNeeded: タイムアウト時の vpnclient プロセス/ソケット:\n\(lsofFail.stdout)")
            return false
        } catch {
            HLog("startVpnClientIfNeeded: process.run() 失敗: \(error.localizedDescription)")
            return false
        }
    }

    /// vpnclient が現在動作してコマンドを受け付ける状態か確認
    private static func isVpnClientRunning() -> Bool {
        let res = Shell.run(vpncmd, ["/CLIENT", "127.0.0.1", "/CMD", "About"], timeout: 5)
        return res.ok && res.stdout.contains("SoftEther VPN")
    }

    /// 存在するすべての feth* インターフェースを完全に破棄（destroy）する。
    /// 古い残骸 feth が残っていると、DHCP取得対象の誤認やOSリソースの無駄遣いが発生するため、
    /// アカウントの再設定時や接続開始時、切断時に徹底的にお掃除する。
    @discardableResult
    static func destroyAllFethInterfaces() -> String {
        var log = ""
        let interfaces = fethInterfaces()
        for feth in interfaces {
            let r = Shell.run(ifconfig, [feth, "destroy"])
            if r.ok {
                log += "destroyed \(feth)\n"
            } else {
                log += "failed to destroy \(feth): \(r.stderr)\n"
            }
        }
        return log.isEmpty ? "feth: 削除対象なし" : log
    }
}

// MARK: - 小さな文字列ユーティリティ

private extension String {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func lines() -> [String] { split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    /// "key: value" 形式の行から value を返す（route -n get default の出力向け）。
    func value(after key: String) -> String {
        for line in lines() {
            let t = line.trimmed()
            if t.hasPrefix(key) { return t.dropFirst(key.count).trimmed() }
        }
        return ""
    }
}

private extension Substring {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
