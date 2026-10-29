// 設定。独立した通常ウィンドウ（AppModel.openSettings が開く NSWindow）の中身として使う。
// MenuBarExtra のパネルはフォーカスを失うと閉じる仕様なので、設定は別ウィンドウに出す。
// 値はそのまま XPC の引数配列で渡る（シェル展開なし）ので特殊文字の制限はない。

import SwiftUI

struct ProxySettingsView: View {
    @EnvironmentObject var model: AppModel

    // Tab 選択用
    @State private var selectedTab = 0

    // プロキシ設定の状態
    @State private var proxyType = "http"
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var proxyUser = ""
    @State private var proxyPass = ""

    // VPN設定の状態
    @State private var vpnServer = ""
    @State private var vpnPort = "443"
    @State private var vpnHub = "VPN"
    @State private var vpnUser = "vpn"
    @State private var vpnPass = ""
    @State private var vpnAuthType = "anonymous" // "anonymous" or "password"

    var body: some View {
        TabView(selection: $selectedTab) {
            proxyTab
                .tabItem {
                    Label("プロキシ", systemImage: "network")
                }
                .tag(0)

            vpnTab
                .tabItem {
                    Label("SoftEther VPN", systemImage: "lock.shield")
                }
                .tag(1)
        }
        .padding(16)
        .frame(width: 440, height: 380)
        .onAppear {
            // プロキシ設定のロード
            let pc = model.proxyConfig
            proxyType = pc.type.isEmpty ? "http" : pc.type
            proxyHost = pc.host
            proxyPort = pc.port
            proxyUser = pc.user
            proxyPass = ProxyStore.loadPassword()

            // VPN設定のロード
            let vc = model.vpnConfig
            vpnServer = vc.server
            vpnPort = vc.port.isEmpty ? "443" : vc.port
            vpnHub = vc.hub.isEmpty ? "VPN" : vc.hub
            vpnUser = vc.username.isEmpty ? "vpn" : vc.username
            vpnAuthType = vc.authType.isEmpty ? "anonymous" : vc.authType
            vpnPass = VpnStore.loadPassword()
        }
    }

    // MARK: - プロキシ設定タブ

    private var proxyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プロキシ設定").font(.headline)
            Text("現在: \(model.proxyDescription)").font(.caption).foregroundStyle(.secondary)

            Picker("種類", selection: $proxyType) {
                Text("HTTP").tag("http")
                Text("SOCKS").tag("socks")
            }
            .pickerStyle(.segmented)

            HStack {
                TextField("host（例: proxy.example.com）", text: $proxyHost)
                TextField("port", text: $proxyPort).frame(width: 80)
            }
            HStack {
                TextField("user（任意）", text: $proxyUser)
                SecureField("pass（任意）", text: $proxyPass)
            }

            Text("保存すると設定は記憶され、オフにしても再入力なしに「ON」で戻せます。")
                .font(.caption).foregroundStyle(.secondary)
            Text("設定後は「VPN 切断 → 接続」で再接続すると反映されます。")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button("キャンセル") { model.closeSettings() }
                Button("保存して適用") {
                    model.saveAndApplyProxy(type: proxyType,
                                            host: proxyHost.trimmingCharacters(in: .whitespaces),
                                            port: proxyPort.trimmingCharacters(in: .whitespaces),
                                            user: proxyUser, pass: proxyPass)
                    model.closeSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(proxyHost.isEmpty || proxyPort.isEmpty)
            }
        }
    }

    // MARK: - VPN設定タブ

    private var vpnTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SoftEther VPN 接続設定").font(.headline)
            if !model.privileged.serverHost.isEmpty {
                Text("現在のアカウント接続先: \(model.privileged.serverHost)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("現在のアカウント接続先: 未設定").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                TextField("接続先サーバー（例: vpn.example.com）", text: $vpnServer)
                TextField("ポート", text: $vpnPort).frame(width: 80)
            }

            HStack {
                TextField("仮想HUB名（例: VPN）", text: $vpnHub)
                Picker("認証方式", selection: $vpnAuthType) {
                    Text("匿名認証").tag("anonymous")
                    Text("パスワード認証").tag("password")
                }
            }

            if vpnAuthType == "password" {
                HStack {
                    TextField("ユーザー名", text: $vpnUser)
                    SecureField("パスワード", text: $vpnPass)
                }
            }

            Text("設定を保存すると、VPNアカウント情報が自動的に作成・上書きされ、")
                .font(.caption).foregroundStyle(.secondary)
            Text("「接続」からその設定で接続できるようになります。")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()

            HStack {
                if model.vpnConfig.isUsable {
                    Button("設定を消去") {
                        model.clearVpnAccount()
                        model.closeSettings()
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }
                Spacer()
                Button("キャンセル") { model.closeSettings() }
                Button("保存して適用") {
                    model.saveAndApplyVpnAccount(
                        server: vpnServer.trimmingCharacters(in: .whitespaces),
                        port: vpnPort.trimmingCharacters(in: .whitespaces),
                        hub: vpnHub.trimmingCharacters(in: .whitespaces),
                        username: vpnUser.trimmingCharacters(in: .whitespaces),
                        pass: vpnPass,
                        authType: vpnAuthType
                    )
                    model.closeSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vpnServer.isEmpty || vpnPort.isEmpty || vpnHub.isEmpty || (vpnAuthType == "password" && vpnUser.isEmpty))
            }
        }
    }
}
