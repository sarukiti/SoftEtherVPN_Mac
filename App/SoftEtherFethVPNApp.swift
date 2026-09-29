// メニューバー常駐アプリのエントリ。WARP 風にポップオーバーパネル（.window スタイル）を出す。

import SwiftUI

struct SoftEtherFethVPNApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.tunnel.iconName)
        }
        .menuBarExtraStyle(.window)

        // プロキシ設定は独立ウィンドウ（パネルが閉じても残る）
        Window("プロキシ設定", id: "proxy-settings") {
            ProxySettingsView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
