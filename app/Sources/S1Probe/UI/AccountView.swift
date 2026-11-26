// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Steam account: the sign-in's status, Sign in to Steam
// (SignInView.swift: the account name on this phone, or a QR code a second
// device scans), refreshing the library, and sign-out (confirmed in a
// picker). Every control is a row on the ring.

import SteamClientKit
import SwiftUI

struct SteamAccountSettings: View {
    @EnvironmentObject private var model: SteamAccountModel

    var body: some View {
        SettingsNote(text: "你的 Steam 游戏库、云存档与成就均来自此账号。")
        SettingsInfoRow(id: "steam:status", title: AccountCopy.status(model.state), subtitle: detail)
        switch model.state {
        case let .signedIn(a), let .offline(a, _):
            signedIn(a)
        case .unknown, .restoring:
            EmptyView()
        case .signedOut, .pairing, .expired:
            // Sign in to Steam (SignInView.swift): the account name on this phone, or a QR code.
            PadRow(id: "set:steam:signin", title: "登录 Steam", subtitle: "使用账户名称登录，或用其他设备扫描二维码",
                   accessory: .chevron, hint: "登录") { SignInState.shared.open(preview: false) }
        }
    }

    private var detail: String? {
        switch model.state {
        case let .signedIn(a), let .offline(a, _):
            AccountCopy.pairedUntil(a) { $0.formatted(date: .abbreviated, time: .omitted) }
        case .unknown, .restoring: "正在检查…"
        default: nil
        }
    }

    @ViewBuilder
    private func signedIn(_ a: SteamService.Account) -> some View {
        #if !PLAYPORT_RELEASE
        // The service's raw renewal result ("not-due", "failed: …"); a release build shows none.
        if let r = model.lastRenewal {
            SettingsInfoRow(id: "steam:renewal", title: "上次续期检查",
                            subtitle: r.at.formatted(.relative(presentation: .named)), value: r.result)
        }
        #endif
        PadRow(id: "set:steam:refresh", title: "刷新游戏库",
               subtitle: model.gamesError ?? model.gamesFetchedAt.map { "获取于 " + $0.formatted(.relative(presentation: .named)) },
               value: model.gamesLoading ? "正在连接 Steam…" : nil, hint: "刷新") {
            guard !model.gamesLoading else { return }
            Task { await model.loadGames(refresh: true) }
        }
        PadRow(id: "set:steam:signout", title: model.signingOut ? "正在退出登录…" : "退出登录", subtitle: AccountCopy.signOutNote,
               destructive: true, hint: "退出登录") {
            guard !model.signingOut else { return }
            PadModal.shared.picker(
                title: "要退出登录 Steam 吗？", context: "设置 · Steam 账号", note: AccountCopy.signOutNote,
                options: [PadOption(id: "keep", label: "保持登录"), PadOption(id: "out", label: "退出登录")],
                selected: "keep") { if $0 == "out" { Task { await model.signOut() } } }
        }
        #if !PLAYPORT_RELEASE
        // The sign-in screen while signed in: its steps shown, and nothing goes to Steam.
        PadRow(id: "set:steam:signinPreview", title: "预览登录界面", subtitle: "查看登录界面流程，不会向 Steam 发送任何信息",
               accessory: .chevron, hint: "预览") { SignInState.shared.open(preview: true) }
        #endif
    }
}
