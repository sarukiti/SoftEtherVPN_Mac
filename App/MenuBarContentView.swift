// WARP 風パネル。開くたびに（onAppear で）完全リフレッシュする。

import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if model.helperState != .enabled {
                OnboardingView()
                    .environmentObject(model)
                    .padding(14)
            } else {
                controls
            }

            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { Task { await model.refreshFull() } }
    }

    // MARK: ヘッダ（大きな状態表示 + トグル）

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: model.tunnel.iconName)
                    .font(.system(size: 26))
                    .foregroundStyle(model.tunnel == .fullTunnel ? .green : .secondary)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.tunnel.title).font(.headline)
                    if let ip = model.hostIP { Text("内部IP \(ip)").font(.caption).foregroundStyle(.secondary) }
                    // セッション状態を綺麗に整形して表示
                    if !cleanSessionStatus.isEmpty {
                        Text("状態: \(cleanSessionStatus)")
                            .font(.caption)
                            .foregroundStyle(model.privileged.sessionEstablished ? .green : .orange)
                            .lineLimit(1)
                    }
                    if !model.privileged.serverHost.isEmpty {
                        Text(model.privileged.serverHost)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if model.busy { ProgressView().scaleEffect(0.7) }
            }
            HStack {
                Text("出口IP").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.egressIP ?? "—").font(.caption.monospaced())
            }
            HStack {
                Text("ヘルパー").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.helperDiag).font(.caption2.monospaced())
                    .foregroundStyle(model.helperDiag.hasPrefix("XPC OK") ? .green : .secondary)
            }
        }
        .padding(14)
    }

    // MARK: 主要操作

    private var controls: some View {
        VStack(spacing: 8) {
            // 版不一致/XPC 不通の警告バナー（アラートを「後で」にしても気づけるように）
            if model.helperNeedsUpdate {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("ヘルパーの更新が必要です").font(.caption)
                    Spacer()
                    Button("再登録") { model.reregisterHelper() }.font(.caption).disabled(model.busy)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            // VPN設定未保存の警告バナー
            if !model.vpnConfig.isUsable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text("VPN設定が未登録です").font(.caption)
                    Spacer()
                    Button("設定…") {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "proxy-settings")
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            // 大きな主トグル
            Button {
                if model.tunnel == .fullTunnel { model.disableFullTunnel() }
                else { model.connectAndFullTunnel() }
            } label: {
                Text(model.tunnel == .fullTunnel ? "フルトンネルを切る" : "接続してフルトンネル")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || (model.tunnel != .fullTunnel && !model.vpnConfig.isUsable))

            HStack(spacing: 8) {
                Button("フルトンネル ON") { model.enableFullTunnel() }
                    .frame(maxWidth: .infinity)
                    .disabled(model.busy || !model.vpnConfig.isUsable)
                Button("VPN 切断") { model.disconnect() }
                    .frame(maxWidth: .infinity).disabled(model.busy)
            }

            Divider().padding(.vertical, 2)

            HStack {
                Text("プロキシ").font(.subheadline)
                Spacer()
                Text(model.proxyDescription).font(.caption)
                    .foregroundStyle(model.proxyActive ? .green : .secondary)
            }
            // 保存済み設定があれば、再入力なしで ON / オフ を切り替えられる。
            if model.proxyConfig.isUsable {
                Text("保存済み: \(model.proxyConfig.type) \(model.proxyConfig.host):\(model.proxyConfig.port)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("設定…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "proxy-settings")
                }
                .frame(maxWidth: .infinity).disabled(model.busy)
                Button("ON") { model.applyProxy() }
                    .frame(maxWidth: .infinity)
                    .disabled(model.busy || !model.proxyConfig.isUsable || model.proxyActive)
                Button("オフ") { model.clearProxy() }
                    .frame(maxWidth: .infinity)
                    .disabled(model.busy || !model.proxyActive)
            }

            if !model.lastMessage.isEmpty {
                ScrollView {
                    Text(model.lastMessage)
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 90)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.refreshFull() }
            } label: {
                Label { Text("更新") } icon: {
                    Image(systemName: "arrow.clockwise").imageScale(.small)
                }
            }
            .buttonStyle(.plain).font(.caption)
            Button("再登録") { model.reregisterHelper() }.buttonStyle(.plain).font(.caption)
            Spacer()
            Button("設定") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "proxy-settings")
            }.buttonStyle(.plain).font(.caption)
            Button("終了") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.caption)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var cleanSessionStatus: String {
        let status = model.privileged.sessionStatus
        if status.isEmpty { return "" }
        if status.contains("Session Established") { return "接続完了" }
        if status.contains("Retrying") { return "再試行中..." }
        if status.contains("Connecting") { return "接続中..." }
        if status.contains("Requesting") { return "要求中..." }
        if status.contains("Disconnect") { return "切断中..." }
        return status
    }
}
