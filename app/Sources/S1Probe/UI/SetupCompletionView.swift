// SPDX-License-Identifier: GPL-3.0-or-later
// Over the dimmed first-run checklist once every step is settled. Continue is
// always highlighted: touch or A leaves setup; B closes only this overlay.

import SwiftUI

struct SetupCompletionView: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 38)).foregroundStyle(PP.ok)
                Text("一切准备就绪").font(PP.display(30))
                Text("选择一款游戏，开始畅玩吧。")
                    .font(.system(size: 15)).foregroundStyle(PP.muted)
                Button { PadModal.shared.press(.a) } label: {
                    HStack(spacing: 10) {
                        PadGlyph(button: .a, inverted: true)
                        Text("继续").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(PP.onAccent)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(PP.accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("setup-continue")
                PadModalHint(button: .b, label: "返回检查步骤") { PadModal.shared.press(.b) }
            }
            .padding(28)
            .frame(width: 370)
            .background(PP.surface, in: RoundedRectangle(cornerRadius: 18))
        }
        .foregroundStyle(PP.text)
        .accessibilityIdentifier("setup-complete")
    }
}
