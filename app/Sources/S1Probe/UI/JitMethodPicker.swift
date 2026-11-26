// SPDX-License-Identifier: GPL-3.0-or-later
// The JIT method picker (PlayportKit JitMethod, decision 0051): from Settings ›
// Setup check's JIT method row and X on the setup checklist's first step. The
// choice is stored under JitMethod.key and read by the next Play
// (JitProvider.method); inside LiveContainer the built-in helper is not offered.

import PlayportKit
import SwiftUI

@MainActor
enum JitMethodPicker {
    static func show() {
        let inLC = JitProvider.inLiveContainer
        let current = JitProvider.method
        var note = "所有方式均需开启「开发者模式」。使用 StikDebug 或其他应用时，需为 Playport 指定 universal.js 脚本。"
        if inLC {
            note = "Playport 当前运行在 LiveContainer 内，无法启动自带的 JIT 助手。"
                + "请从 LiveContainer 使用 JIT 启动 Playport（将其 JIT 启用器设为 StikDebug 并搭配 universal.js），"
                + "或在此选择 StikDebug 并在 LiveContainer 设置中开启「使用 LiveContainer 的 Bundle ID」。"
        }
        PadModal.shared.picker(
            title: "JIT 方式", context: "选择游戏获取 JIT 的来源", note: note,
            options: JitMethod.choices(inLiveContainer: inLC).map { PadOption(id: $0.rawValue, label: $0.label, detail: $0.detail) },
            selected: current.rawValue) { id in
            guard let m = JitMethod(rawValue: id) else { return }
            UserDefaults.standard.set(m.rawValue, forKey: JitMethod.key)
            WineHostRuntime.appendLog("jit: method set to \(m.rawValue)" + (inLC ? " (in LiveContainer)" : ""))
        }
    }
}
