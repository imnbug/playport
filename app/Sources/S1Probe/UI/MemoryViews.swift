// SPDX-License-Identifier: GPL-3.0-or-later
// The app's memory limit as the player sees it (MemoryLimit): the words
// Settings › Setup check (SetupCheckSettings.swift) and a game's page use
// (MemoryNote), the page's note on a Play iOS ended for memory included
// (PlayportKit MemoryKill). Nothing refuses a Play for memory. A dev build's
// Developer section simulates a lower limit and a JIT pool
// (Dev/DeveloperSettings.swift).

import PlayportKit
import SwiftUI

/// The game page's warning under Play when the limit is low, following the limit as Settings' section does.
struct MemoryWarning: View {
    @State private var limitMB = MemoryLimit.read().effectiveMB

    var body: some View {
        VStack(alignment: .leading) {
            if let text = MemoryNote.lowLimit(limitMB) {
                Text(text).foregroundStyle(.orange)
            }
        }
        .task { await MemoryLimit.follow { limitMB = $0.effectiveMB } }
    }
}

/// What the player is told about the memory limit.
enum MemoryNote {
    /// Under this limit the game's page warns that a larger game may not fit: a 3D game's heap
    /// and textures on top of the runtime (Hollow Knight, a 2D game, reaches about 3 GB). It is
    /// the same for every game; no game carries a figure of its own.
    static let lowLimitMB = 4096

    static let footer = "iOS 允许 Playport 使用的最大内存，由游戏本体与所需的 JIT 内存共同占用。"
        + "若超出此上限，iOS 会直接终止游戏，随后游戏详情页会显示提示及上次达到的内存峰值。系统进入「游戏模式」后可用上限会有所提升。"
        + "开启「增加内存限制」（Increased Memory Limit）权限可大幅提高此上限；未包含该权限的签名版本可用内存会少得多。"

    static let notEntitled = "当前安装的 Playport 签名未包含「增加内存限制」权限。"
        + "请使用支持保留该权限的工具重新签名安装：详见「初始设置向导」中的「内存」步骤说明。"

    /// The game page's warning under Play; nil when the limit is not low or not reported.
    static func lowLimit(_ limitMB: Int?) -> String? {
        guard let limit = limitMB, limit < lowLimitMB else { return nil }
        return "当前 iOS 仅允许 Playport 使用 \(ByteCount.format(mb: limit)) 内存。大型游戏可能需要更多内存，"
            + "一旦超出上限会被 iOS 强制关闭。"
    }

    /// The game page's note on a last Play iOS ended for memory, with its peak and the limit.
    static func killed(_ k: MemoryKill) -> String {
        "上次游玩因内存不足被系统终止：内存峰值达到 \(ByteCount.format(mb: k.peakMB))，而 iOS 允许 Playport 使用的上限为 "
            + "\(ByteCount.format(mb: k.limitMB))。" + advice
    }

    /// The signature's entitlement decides the advice: a copy without it can get more by
    /// being signed again; one with it is at the phone's own limit.
    private static var advice: String {
        switch MemoryLimit.entitled {
        case false?: notEntitled
        case true?: "此 iPhone 已无法为 Playport 提供更多内存。"
        case nil: "安装带有「增加内存限制」签名权限的 Playport 版本可获得更多可用内存。"
        }
    }
}
