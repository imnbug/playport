// SPDX-License-Identifier: GPL-3.0-or-later
// The Controller page's logic (ControllerMapping.dc.html; UI/ControllerMapView.swift):
// a controller map's mode and, for Keyboard & mouse and Custom, what each of
// the controller's inputs does, beside a picture of the pad.
//
// - Rows (ControllerMapRow): LT, LB, L stick, L3, D-pad, View and Menu down
//   the left; RT, RB, Y, X, B, A, R stick and R3 down the right. Home is
//   Playport's, shown and not a row.
// - A stick's row is the whole stick (mouse look, a pad stick) or its four
//   directions (W A S D); the D-pad's row is its four directions. Choosing
//   such a row lists its parts (ControllerMapPart): for a stick Whole stick
//   or Four directions, then what each does; a part's ActionPicker sets it.
// - In Custom, a row that differs from the Keyboard & mouse preset has the
//   amber dot, and Y puts just that row back to the preset (`reset`). Reset all
//   (ControllerMapConfirm.resetAll) and Edit a copy (`copyPreset`, from
//   Keyboard & mouse) ask first when they would replace the player's own table.
// - The ring (ControllerMapNav; owner, 2026-10-13, touch controls U, replacing
//   3b's "press a controller's input to ring its row", which left rows out of
//   reach and took B and the shoulders): the D-pad and the left stick move one
//   ring through every item in every mode, LB and RB cycle the mode from
//   anywhere, A edits the ringed input (`ControllerMapConfirm.forEditing`
//   asks first outside Custom), Y resets it, B goes back.

import Foundation
import HostIOKit

extension ControllerMap.Mode {
    /// The page's switch and Game options' value (ControllerMapping.dc.html).
    public var title: String {
        switch self {
        case .controller: "作为手柄"
        case .keyboardMouse: "映射为键鼠"
        case .custom: "自定义"
        }
    }

    /// The in-game menu's narrower panel.
    public var shortTitle: String {
        switch self {
        case .controller: "手柄"
        case .keyboardMouse: "键鼠"
        case .custom: "自定义"
        }
    }
}

public enum ControllerMapRow: String, CaseIterable, Sendable {
    case lt, lb, leftStick, ls, dpad, back, start
    case rt, rb, y, x, b, a, rightStick, rs

    public var title: String {
        switch self {
        case .leftStick: "左摇杆"
        case .rightStick: "右摇杆"
        case .dpad: "十字键"
        default: pad.map(ActionText.pad) ?? rawValue
        }
    }

    /// The pad's control this row is (nil for the D-pad's four).
    public var pad: PadControl? { self == .dpad ? nil : PadControl(rawValue: rawValue) }

    /// Down the left of the picture, else the right.
    public var isLeft: Bool { Self.left.contains(self) }

    public static let left: [ControllerMapRow] = [.lt, .lb, .leftStick, .ls, .dpad, .back, .start]
    public static let right: [ControllerMapRow] = [.rt, .rb, .y, .x, .b, .a, .rightStick, .rs]

    /// The focus item and the driver's id: `ctl:a`, `ctl:leftStick`.
    public var itemID: String { "ctl:" + rawValue }

    public var stick: PadControl? { self == .leftStick ? .leftStick : self == .rightStick ? .rightStick : nil }

    /// Every input the row covers (a stick: whole and its four directions).
    public var inputs: [ControllerInput] {
        if let s = stick { return [.control(s)] + Self.directionOrder.map { .stickDirection(s, $0) } }
        if self == .dpad { return [PadControl.up, .right, .down, .left].map { .control($0) } }
        return [.control(pad!)]
    }

    /// The inputs it shows for `b`, in the picture's order: a stick by direction W A S D
    /// (up, left, down, right), the D-pad clockwise from up.
    public func shown(in b: ControllerBindings) -> [ControllerInput] {
        if let s = stick { return ControllerMapEdit.isWhole(s, in: b) ? [.control(s)] : Array(inputs.dropFirst()) }
        return inputs
    }

    /// What each shown input does, short: `W`, `Mouse`, `Left`, `–`.
    public func caps(in b: ControllerBindings) -> [String] { shown(in: b).map { ActionText.short(b[$0]) } }

    static let directionOrder: [StickDirection] = [.up, .left, .down, .right]

    /// The row an input is on.
    public static func row(of input: ControllerInput) -> ControllerMapRow {
        switch input {
        case .stickDirection(let s, _): s == .leftStick ? .leftStick : .rightStick
        case .control(let c): [.up, .down, .left, .right].contains(c) ? .dpad : ControllerMapRow(rawValue: c.rawValue)!
        }
    }

    /// The row of a ring item's id (`ctl:a`), nil for the page's other items.
    public init?(itemID: String) {
        guard itemID.hasPrefix("ctl:"), let r = ControllerMapRow(rawValue: String(itemID.dropFirst(4))) else { return nil }
        self = r
    }
}

/// The Controller page's ring, laid out as the page is: the header (Edit a copy or
/// Reset all, then the mode switch) above the left column's rows, Look speed under
/// the picture, and the right column's. Up and down walk that order (columns down,
/// then across), so every item is reached in every mode; left and right go across
/// the header, or between the two columns at the same row. Look speed takes left
/// and right itself (its value), as an adjustable item does.
public enum ControllerMapNav {
    public static let modeID = "ctl:mode"
    public static let lookSpeedID = "ctl:lookSpeed"
    public static let resetAllID = "ctl:resetAll"
    public static let copyID = "ctl:copy"

    /// The header's items, left to right.
    public static func header(_ mode: ControllerMap.Mode) -> [String] {
        switch mode {
        case .controller: [modeID]
        case .keyboardMouse: [copyID, modeID]
        case .custom: [resetAllID, modeID]
        }
    }

    /// Every item, in the ring's order.
    public static func order(_ mode: ControllerMap.Mode) -> [String] {
        header(mode) + ControllerMapRow.left.map(\.itemID) + (mode == .controller ? [] : [lookSpeedID])
            + ControllerMapRow.right.map(\.itemID)
    }

    /// Where the ring goes from `from` (nil, or an item not on the page: the mode switch).
    public static func next(from: String?, _ d: FocusDirection, mode: ControllerMap.Mode) -> String {
        let all = order(mode)
        guard let from, let at = all.firstIndex(of: from) else { return modeID }
        switch d {
        case .up: return all[max(0, at - 1)]
        case .down: return all[min(all.count - 1, at + 1)]
        case .left, .right:
            let h = header(mode)
            if let i = h.firstIndex(of: from) { return h[max(0, min(h.count - 1, i + (d == .left ? -1 : 1)))] }
            guard let row = ControllerMapRow(itemID: from) else { return from }
            let (here, there) = row.isLeft ? (ControllerMapRow.left, ControllerMapRow.right) : (ControllerMapRow.right, ControllerMapRow.left)
            guard (d == .right) == row.isLeft else { return from }
            return there[min(there.count - 1, here.firstIndex(of: row)!)].itemID
        }
    }

    /// LB (-1) or RB (+1): the mode before or after, going round.
    public static func cycle(_ mode: ControllerMap.Mode, by: Int) -> ControllerMap.Mode {
        let all = ControllerMap.Mode.allCases
        return all[((all.firstIndex(of: mode)! + by) % all.count + all.count) % all.count]
    }
}

/// One entry of a stick's or the D-pad's list (a PadModal picker).
public struct ControllerMapPart: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Switch the stick to whole, or to its four directions.
        case whole, directions
        /// What this input does: its ActionPicker.
        case input(ControllerInput)
    }

    public var id: String
    public var label: String
    public var detail: String?
    public var kind: Kind
    /// A radio on (the stick's current way).
    public var on = false
}

/// Changing a Custom table; every function returns a valid table.
public enum ControllerMapEdit {
    public static var preset: ControllerBindings { ControllerMap.keyboardMouse }

    /// Bound whole (or not bound at all), rather than by direction.
    public static func isWhole(_ stick: PadControl, in b: ControllerBindings) -> Bool {
        b[.control(stick)] != nil || !StickDirection.allCases.contains { b[.stickDirection(stick, $0)] != nil }
    }

    /// `b` with `input` doing `action` (nil: nothing); a stick bound whole loses its
    /// directions and a direction loses the whole stick. Nil when the input does not take it.
    public static func setting(_ input: ControllerInput, _ action: InputAction?, in b: ControllerBindings) -> ControllerBindings? {
        if let action, !input.accepts(action) { return nil }
        var t = b.table
        t[input] = action
        if action != nil {
            switch input {
            case .control(let s) where s.isStick:
                for d in StickDirection.allCases { t[.stickDirection(s, d)] = nil }
            case .stickDirection(let s, _):
                t[.control(s)] = nil
            default:
                break
            }
        }
        return ControllerBindings(t)
    }

    /// The stick bound whole: the preset's whole action, else its own pad stick.
    public static func usingWhole(_ stick: PadControl, in b: ControllerBindings) -> ControllerBindings {
        guard b[.control(stick)] == nil else { return b }
        return setting(.control(stick), preset[.control(stick)] ?? .pad(stick), in: b)!
    }

    /// The stick by direction: the preset's keys when it has them (W A S D), else the arrow keys.
    public static func usingDirections(_ stick: PadControl, in b: ControllerBindings) -> ControllerBindings {
        guard isWhole(stick, in: b) else { return b }
        let arrows: [StickDirection: UInt8] = [.up: 0x26, .down: 0x28, .left: 0x25, .right: 0x27]
        var t = b.table
        t[.control(stick)] = nil
        for d in StickDirection.allCases {
            t[.stickDirection(stick, d)] = preset[.stickDirection(stick, d)] ?? .key(arrows[d]!, [])
        }
        return ControllerBindings(t)!
    }

    /// The row's inputs back to the preset's (Y on the row).
    public static func reset(_ row: ControllerMapRow, in b: ControllerBindings) -> ControllerBindings {
        var t = b.table
        for i in row.inputs { t[i] = preset[i] }
        return ControllerBindings(t)!
    }

    /// The row does something the preset's does not (the amber dot).
    public static func differs(_ row: ControllerMapRow, in b: ControllerBindings) -> Bool {
        row.inputs.contains { b[$0] != preset[$0] }
    }

    /// A stick's or the D-pad's list; nil for a row of one input (its ActionPicker opens at once).
    public static func parts(_ row: ControllerMapRow, in b: ControllerBindings) -> [ControllerMapPart]? {
        func part(_ i: ControllerInput, _ label: String) -> ControllerMapPart {
            ControllerMapPart(id: i.name, label: label, detail: ActionText.name(b[i]), kind: .input(i))
        }
        if let s = row.stick {
            let whole = isWhole(s, in: b)
            var out = [
                ControllerMapPart(id: "whole", label: "整根摇杆", detail: "鼠标视角，或映射为手柄摇杆", kind: .whole, on: whole),
                ControllerMapPart(id: "directions", label: "四个方向", detail: "每个方向分别触发按键", kind: .directions, on: !whole),
            ]
            if whole {
                out.append(part(.control(s), "触发动作"))
            } else {
                out += ControllerMapRow.directionOrder.map { part(.stickDirection(s, $0), $0.title) }
            }
            return out
        }
        if row == .dpad { return row.inputs.map { i in part(i, i.direction?.title ?? i.name) } }
        return nil
    }

    /// A part chosen: the stick switched (and the list again), or the input whose ActionPicker opens.
    public static func choose(_ part: ControllerMapPart, of row: ControllerMapRow,
                              in b: ControllerBindings) -> (table: ControllerBindings, pick: ControllerInput?) {
        switch part.kind {
        case .whole: (row.stick.map { usingWhole($0, in: b) } ?? b, nil)
        case .directions: (row.stick.map { usingDirections($0, in: b) } ?? b, nil)
        case .input(let i): (b, i)
        }
    }

    /// The ActionPicker's title for an input: `What A presses`, `What L stick up presses`.
    public static func pickerTitle(_ input: ControllerInput) -> String {
        let row = ControllerMapRow.row(of: input)
        let part: String = switch input {
        case .stickDirection(_, let d): row.title + "向" + d.title
        case .control(let c) where row == .dpad: ActionText.pad(c)
        default: row.title
        }
        return "「\(part)」触发的动作"
    }
}

/// Reset all, Edit a copy over the player's own table, and Y putting a game's
/// own Custom map back to Settings' (the mode row, Game options' Controller
/// row): asked first in a list whose first, default choice changes nothing.
public enum ControllerMapConfirm: String, Sendable {
    case resetAll, copyPreset, useDefault
    /// A on an input in Keyboard & mouse while Custom is still the preset: Custom, with a copy, to edit it.
    case editCopy
    /// A on an input in As a controller: Custom (its table kept), to edit it.
    case useCustom

    /// What A on an input row asks first in `map`'s mode; nil in Custom (the input's editor at once).
    /// After a `.save` into Custom the input's editor opens.
    public static func forEditing(_ map: ControllerMap) -> ControllerMapConfirm? {
        switch map.mode {
        case .custom: nil
        case .keyboardMouse: needed(for: map) ? .copyPreset : .editCopy
        case .controller: .useCustom
        }
    }

    /// Whether it must ask: only when it would replace a table that is not the preset.
    public static func needed(for map: ControllerMap) -> Bool { map.custom != ControllerMap.keyboardMouse }

    /// Whether Y on a game's map (back to Settings') must ask first (`useDefault`): the
    /// game's own map is Custom with a table that is not the preset. Else Y resets at once.
    public static func neededForDefault(own: ControllerMap?) -> Bool {
        guard let own, own.mode == .custom else { return false }
        return needed(for: own)
    }

    public var title: String {
        switch self {
        case .resetAll: "重置所有按键映射？"
        case .copyPreset: "基于「键盘与鼠标」预设编辑副本？"
        case .useDefault: "恢复默认手柄映射？"
        case .editCopy: "基于「键盘与鼠标」预设编辑副本？"
        case .useCustom: "修改此按键的功能？"
        }
    }

    public var note: String {
        switch self {
        case .resetAll: "所有输入都将恢复为「键盘与鼠标」预设方案。"
        case .copyPreset: "「自定义」方案中已包含你的个人修改。"
        case .useDefault: "此游戏的「自定义」映射包含你的修改。恢复默认后将改用「设置」中的映射方案。"
        case .editCopy: "「键盘与鼠标」预设为只读。「自定义」将以它的副本为起点，并打开此按键的编辑器。"
        case .useCustom: "在「作为手柄」模式下，游戏直接识别原样手柄。「自定义」可将每个输入映射为键盘按键、鼠标或手柄按键，并打开此按键的编辑器。"
        }
    }

    /// (id, label); the first is the default and keeps the player's table.
    public var options: [(id: String, label: String)] {
        switch self {
        case .resetAll: [("keep", "保留我的修改"), ("reset", "全部重置为「键盘与鼠标」")]
        case .copyPreset: [("keep", "使用现有的「自定义」方案"), ("reset", "从「键盘与鼠标」重新开始")]
        case .useDefault: [("keep", "保留我的修改"), ("reset", "使用「设置」中的默认方案")]
        case .editCopy: [("keep", "暂不"), ("reset", "编辑副本")]
        case .useCustom: [("keep", "保持「作为手柄」"), ("custom", "切换至「自定义」")]
        }
    }

    public var defaultChoice: String { "keep" }

    /// What a choice does to the map asked about.
    public enum Outcome: Equatable, Sendable {
        /// Nothing changes (`keep` in Reset all and Use the default).
        case unchanged
        /// The map is saved as this.
        case save(ControllerMap)
        /// The game's own map goes: it follows Settings' again.
        case useDefault
    }

    /// What `choice` (`keep` or `reset`) does to `map`.
    public func outcome(_ choice: String, for map: ControllerMap) -> Outcome {
        switch self {
        case .resetAll: choice == "reset" ? .save(apply(choice, to: map)) : .unchanged
        case .copyPreset: .save(apply(choice, to: map))
        case .editCopy: choice == "reset" ? .save(apply(choice, to: map)) : .unchanged
        case .useCustom: choice == "custom" ? .save(apply(choice, to: map)) : .unchanged
        case .useDefault: choice == "reset" ? .useDefault : .unchanged
        }
    }

    /// The map after `choice` (`keep` or `reset`) in Reset all or Edit a copy; Edit a copy is in Custom either way.
    public func apply(_ choice: String, to map: ControllerMap) -> ControllerMap {
        var m = map
        if self == .copyPreset || self == .editCopy || (self == .useCustom && choice == "custom") { m.mode = .custom }
        if choice == "reset" { m.custom = ControllerMap.keyboardMouse }
        return m
    }
}

extension StickDirection {
    public var title: String {
        switch self {
        case .up: "上"
        case .down: "下"
        case .left: "左"
        case .right: "右"
        }
    }
}

extension ControllerInput {
    /// A D-pad direction's or a stick direction's way.
    var direction: StickDirection? {
        switch self {
        case .stickDirection(_, let d): d
        case .control(.up): .up
        case .control(.down): .down
        case .control(.left): .left
        case .control(.right): .right
        default: nil
        }
    }
}

extension ActionText {
    /// A row's key cap: `W`, `Shift+1`, `Left`, `Mouse`, `Pad A`, `Playport`; `–` for nothing.
    public static func short(_ a: InputAction?) -> String {
        switch a {
        case nil: "–"
        case .mouse(.left)?: "左键"
        case .mouse(.right)?: "右键"
        case .mouse(.middle)?: "中键"
        case .mouse(.move)?: "鼠标"
        case .playport?: "Playport"
        default: name(a)
        }
    }
}
