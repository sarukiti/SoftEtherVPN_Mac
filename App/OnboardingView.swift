// 初回フロー。ヘルパー未登録/未承認のときだけ表示。1回承認すれば以後は出ない。

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("初回セットアップ", systemImage: "shield.lefthalf.filled")
                .font(.headline)

            switch model.helperState {
            case .requiresApproval:
                Text("特権ヘルパーの登録が承認待ちです。System Settings の「一般 ▸ ログイン項目とバックグラウンドでの実行」で SoftEther VPN を許可してください。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("System Settings を開く") { model.helper.openLoginItemsSettings() }
            default:
                Text("VPN の ON/OFF をパスワード入力なしで行うため、root で動く特権ヘルパーを一度だけ登録します。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("ヘルパーを登録（初回のみ）") { model.registerHelper() }
                    .buttonStyle(.borderedProminent)
            }

            Button("状態を再確認") { Task { await model.refreshFull() } }
                .buttonStyle(.plain).font(.caption)

            if !model.lastMessage.isEmpty {
                Text(model.lastMessage).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
