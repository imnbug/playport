// SPDX-License-Identifier: GPL-3.0-or-later
import HostIOKit

/// The note Point & click shows at the bottom of the screen as a side-bar tool
/// or the Tap to click / Trackpad switch is pressed (TouchPointer.dc.html): what
/// a finger on the game does now. A tool turned off says nothing.
public enum PointerHint {
    /// The tool and the trackpad mode before and after the press.
    public static func text(from before: (tool: PointerTool?, trackpad: Bool),
                            to after: (tool: PointerTool?, trackpad: Bool)) -> String? {
        if after.trackpad != before.trackpad {
            return after.trackpad ? "触控板模式：拖动移动指针，轻点进行点击" : "点按即点模式：手指点按处即为指针位置"
        }
        guard after.tool != before.tool, let tool = after.tool else { return nil }
        return switch tool {
        case .rightClick: "右键已开启：下一次轻点将触发右键点击"
        case .hover: "悬停已开启：移动手指仅移动指针，不触发点击"
        case .scroll: "滚轮已开启：拖动屏幕即可滚动"
        case .trackpad: nil
        }
    }
}
