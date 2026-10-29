// WARP 風パネル。開くたびに（onAppear で）完全リフレッシュする。

import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject var model: AppModel

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
                        model.openSettings()
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            // 大きな主トグル: 未接続なら接続（フルトンネル込み）、接続中なら切断
            Button {
                if model.tunnel == .disconnected { model.connectAndFullTunnel() }
                else { model.disconnect() }
            } label: {
                Text(model.tunnel == .disconnected ? "接続" : "VPN 切断")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || (model.tunnel == .disconnected && !model.vpnConfig.isUsable))

            Divider().padding(.vertical, 2)

            HStack {
                Text("プロキシ").font(.subheadline)
                Spacer()
                Text(model.proxyDescription).font(.caption)
                    .foregroundStyle(model.privileged.proxyFallbackDirect ? .yellow
                                     : model.proxyActive ? .green : .secondary)
                    .help(model.privileged.proxyFallbackDirect ? "プロキシに到達できないため直接接続中" : "")
            }
            // 保存済み設定があれば、再入力なしで ON / オフ を切り替えられる。
            if model.proxyConfig.isUsable {
                Text("保存済み: \(model.proxyConfig.type) \(model.proxyConfig.host):\(model.proxyConfig.port)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("設定…") {
                    model.openSettings()
                }
                .frame(maxWidth: .infinity).disabled(model.busy)
                Button(model.proxyActive ? "OFF" : "ON") {
                    if model.proxyActive { model.clearProxy() } else { model.applyProxy() }
                }
                .frame(maxWidth: .infinity)
                .disabled(model.busy || (!model.proxyActive && !model.proxyConfig.isUsable))
            }
        }
        .padding(14)
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
