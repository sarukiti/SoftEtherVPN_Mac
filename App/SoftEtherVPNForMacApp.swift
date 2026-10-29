// メニューバー常駐アプリのエントリ。WARP 風にポップオーバーパネル（.window スタイル）を出す。

import SwiftUI

struct SoftEtherVPNForMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.tunnel.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}

/// メニューバーアイコンの右クリックメニュー（再登録・設定・終了）。
/// MenuBarExtra には右クリックの API が無いので、自アプリのステータスバー窓への右クリックを横取りする。
@MainActor
final class StatusItemContextMenu: NSObject {
    private weak var model: AppModel?
    private var monitor: Any?
    private let menu = NSMenu()

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.addItem(item("ヘルパーを再登録", #selector(reregister)))
        menu.addItem(item("設定…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("終了", #selector(quit), key: "q"))

        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            // ローカルモニタには自アプリのイベントしか来ないので、ステータスバー窓なら自分のアイコン
            guard let self, let window = event.window,
                  String(describing: type(of: window)).contains("NSStatusBarWindow"),
                  let view = window.contentView else { return event }
            self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY), in: view)
            return nil
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func reregister() { model?.reregisterHelper() }
    @objc private func openSettings() { model?.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
