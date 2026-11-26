// SPDX-License-Identifier: GPL-3.0-or-later
// The controls' and gyro aim's settings screens (docs/design/2026-10-09-touch-controls:
// GameOptionsControls.dc.html, GyroAim.dc.html):
//
// - GameControlsOptionRows: Game options' Controls section, the game's own
//   on-screen controls (layout, d-pad, right stick, opacity), the layout editor
//   (Edit on-screen layout, UI/LayoutEditorView.swift, over the game's art) and the entries to
//   its Controller page (UI/ControllerMapView.swift) and its Gyro aim page. Each shows "Default · X" while it follows Settings ›
//   Controls, the amber dot while the game sets it, and Y puts it back.
// - GyroAimPanel: Game options › Controls › Gyro aim (AppRoutes.GamePanel.gyro),
//   the game's own gyro aim (PlayportKit GyroRow), over Game options.
// - GyroTestArea: beside it, the dot that follows the aim. While the page is
//   up and no game runs, GyroSensors runs the sensors for it (GyroRun.previewing)
//   through the same GyroAim, and the output reaches only the dot, never a guest
//   (GyroFeed.process in preview); the page going, or the app leaving the front,
//   stops them.
// - GyroDefaultsRows: Settings › Controls › Gyro aim, the `gyro.*` defaults.
//
// Every change applies at once (ControlsStore), in a running game too.

import HostIOKit
import PlayportKit
import SwiftUI

// MARK: Game options › Controls

struct GameControlsOptionRows: View {
    let titleID: String
    /// The game's name, the pickers' context.
    let context: String
    @ObservedObject private var store = ControlsStore.shared
    @ObservedObject private var navigation = AppNavigation.shared

    var body: some View {
        let own = store.game(titleID)
        let inherited = ControlsState.resolve(game: nil, defaults: store.defaults, controllerConnected: false)
        // The game's compatibility default (decision 0074), where it is the layout the game starts on.
        let entry = LaunchSettingsStore.compat.entry(for: titleID)
        let suggested = ControlsState.resolve(game: nil, defaults: store.defaults, controllerConnected: false,
                                              compat: entry?.controls).layout
        let compat = suggested == inherited.layout ? nil : suggested
        PadSectionHeader(text: "操控").id("controls")
        if let entry, compat != nil {
            // What the marker means, as Graphics' row says it for launch settings (GameDetailView).
            PadRow(id: "opt:compatControls", title: "\(OptionValue.compatMarker) 已按此游戏的兼容性自动配置",
                   subtitle: entry.reason + " 你在下方行中的手动选择优先生效；按 Y 可恢复此配置。",
                   subtitleLines: nil, style: .plain, hint: "详情") {}
        }
        choiceRow("opt:layout", "屏幕触控按键", \.layout, all: OnScreenLayout.allCases, inherited: inherited.layout,
                  compat: compat, name: \.title, detail: "未连接手柄时显示")
        // The Gamepad preset's d-pad and right stick: only while the game plays that preset itself
        // (no copy of its own, not another layout), where they change what is drawn.
        let plays = ControlsState.resolve(game: own, defaults: store.defaults, controllerConnected: false, compat: entry?.controls)
        if plays.hasGamepadOptions {
            choiceRow("opt:dpad", "十字键", \.dpad, all: OnScreenDpad.allCases, inherited: inherited.dpad, name: \.title,
                      detail: "位于左摇杆上方")
            choiceRow("opt:rightStick", "右摇杆", \.rightStick, all: OnScreenRightStick.allCases,
                      inherited: inherited.rightStick, name: \.title, detail: "位于 A/B/X/Y 旁")
        }
        let opacity = OptionValue.of(own: own.opacity, inherited: inherited.opacity, name: ControlsOpacity.label)
        PadRow(id: "opt:opacity", title: "透明度", value: opacity.text, accessory: .chevron, changed: opacity.changed,
               style: .plain, reset: opacity.changed ? { set { $0.opacity = nil } } : nil) {
            PadModal.shared.picker(
                title: "透明度", context: "\(context) · 操控", note: Self.note,
                options: [PadOption(id: "", label: "默认", detail: ControlsOpacity.label(inherited.opacity) + "（来自设置）")]
                    + ControlsOpacity.steps.map { PadOption(id: String($0), label: ControlsOpacity.label($0)) },
                selected: own.opacity.map { String(ControlsOpacity.step($0, by: 0)) } ?? "") { id in set { $0.opacity = Double(id) } }
        }
        // The layout editor (UI/LayoutEditorView.swift) over the game's art; the dot and Y for the game's own copies.
        PadRow(id: LayoutEditorSession.gameRowID, title: "编辑屏幕触控布局",
               value: own.layouts.isEmpty ? "在游戏画面上编辑"
                   : "自定义：" + OnScreenLayout.allCases.filter { own.layouts[$0] != nil }.map(\.title).joined(separator: "、"),
               accessory: .chevron, changed: !own.layouts.isEmpty, style: .plain, hint: "打开",
               reset: own.layouts.isEmpty ? nil : { set { $0.layouts = [:] } }) {
            LayoutEditorSession.shared.openOverArt(titleID: titleID, title: context)
        }
        // The Controller page (UI/ControllerMapView.swift): the game's controller map and its look speed.
        // The dot and Y for its own map or look speed; "Default ·" while the mode is Settings'.
        let ownMap = own.controllerMap != nil || own.lookSpeed != nil
        PadRow(id: ControllerMapView.gameRowID, title: "手柄", subtitle: nil,
               value: (own.controllerMap == nil ? "默认 · " : "") + own.controllerMap(over: store.defaults).mode.title,
               accessory: .chevron, changed: ownMap, style: .plain, hint: "打开",
               reset: ownMap ? {
                   ControllerMapAccess.resetToDefault(.game(titleID), context: context) {
                       set { $0.controllerMap = nil; $0.lookSpeed = nil }
                   }
               } : nil) {
            navigation.gamePanels.append(.controller)
        }
        let gyro = store.gyro(titleID)
        PadRow(id: "opt:gyro", title: "陀螺仪瞄准", value: GyroText.summary(gyro), accessory: .chevron, changed: own.gyro != nil,
               style: .plain, hint: "打开", reset: own.gyro == nil ? nil : { set { $0.gyro = nil } }) {
            navigation.gamePanels.append(.gyro)
        }
    }

    static let note = "仅针对此游戏，修改立即生效（游戏中同样实时生效）。"

    private func set(_ change: (inout GameControls) -> Void) {
        var c = store.game(titleID)
        change(&c)
        store.setGame(titleID, c)
    }

    /// `compat`: the game's compatibility default, when it is not `inherited`.
    private func choiceRow<T: RawRepresentable & CaseIterable & Equatable>(
        _ id: String, _ title: String, _ key: WritableKeyPath<GameControls, T?>, all: [T], inherited: T, compat: T? = nil,
        name: KeyPath<T, String>, detail: String
    ) -> some View where T.RawValue == String {
        let own = store.game(titleID)[keyPath: key]
        let v = OptionValue.of(own: own, compat: compat, inherited: inherited, name: { $0[keyPath: name] })
        let fallback = compat.map { $0[keyPath: name] + "（游戏兼容性推荐）" } ?? inherited[keyPath: name] + "（来自设置）"
        return PadRow(id: id, title: title, value: v.text, accessory: .chevron, changed: v.changed, style: .plain,
                      reset: v.changed ? { set { $0[keyPath: key] = nil } } : nil) {
            PadModal.shared.picker(
                title: title, context: "\(context) · 操控", note: detail + "。" + Self.note,
                options: [PadOption(id: "", label: "默认", detail: fallback)]
                    + all.map { PadOption(id: $0.rawValue, label: $0[keyPath: name]) },
                selected: own?.rawValue ?? "") { choice in set { $0[keyPath: key] = T(rawValue: choice) } }
        }
    }
}

// MARK: Game options › Controls › Gyro aim

/// The page's rows, at the right where Game options was (GyroAim.dc.html).
struct GyroAimPanel: View {
    let titleID: String
    let context: String
    @ObservedObject private var store = ControlsStore.shared
    @ObservedObject private var sensors = GyroSensors.shared
    @ObservedObject private var focus = PadFocus.shared

    var body: some View {
        let own = store.game(titleID).gyro
        let now = store.gyro(titleID)
        let defaults = store.gyroDefaults
        VStack(alignment: .leading, spacing: 2) {
            Text("\(context) · 操控").font(.system(size: 12)).foregroundStyle(PP.muted)
                .padding(.horizontal, 14)
            Text("陀螺仪瞄准").font(PP.display(22)).foregroundStyle(PP.text)
                .padding(.horizontal, 14).padding(.bottom, 2)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(GyroRow.allCases.filter { $0.isShown(in: now) }, id: \.self) { row in
                            gyroRow(row, own: own, now: now, defaults: defaults)
                        }
                        PadRow(id: "gyro:calibration", title: "自动校准", value: "自动 · 静止时校准", style: .plain,
                               hint: "") {}
                    }
                    .padding(.bottom, 18)
                }
                .onChange(of: focus.focused) { _, id in
                    guard let id, id.hasPrefix("gyro:"), id != GyroTestArea.itemID else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
        .padding(.top, 18).padding(.leading, 20).padding(.trailing, 28)
    }

    @ViewBuilder
    private func gyroRow(_ row: GyroRow, own: GameGyro?, now: GyroSettings, defaults: GyroSettings) -> some View {
        let id = "gyro:" + row.rawValue
        let changed = row.isSet(in: own)
        let reset: (() -> Void)? = changed ? { save(row.cleared(own)) } : nil
        if row.isSwitch {
            let on = row.id(in: now) == "true"
            PadRow(id: id, title: row.title, accessory: .toggle(on), changed: changed, style: .plain,
                   hint: on ? "关闭" : "开启", reset: reset) {
                // Back to following the default when that is what it becomes.
                let next = String(!on)
                save(next == row.id(in: defaults) ? row.cleared(own) : row.setting(next, in: own))
            }
        } else {
            let text: (value: String, why: String?) = switch row {
            case .source: GyroText.sourceInUse(now.source, device: sensors.device(for: now))
            case .smoothing: (GyroText.smoothingInUse(now.smoothing, device: sensors.device(for: now)), nil)
            default: (row.text(now), nil)
            }
            PadRow(id: id, title: row.title, subtitle: text.why ?? Self.subtitle(row),
                   value: changed ? text.value : "默认 · " + text.value, accessory: .chevron, changed: changed,
                   style: .plain, reset: reset,
                   adjust: row.isNumber ? { by in save(row.setting(row.step(now, by: by), in: own)) } : nil) {
                PadModal.shared.picker(
                    title: row.title, context: "\(context) · 陀螺仪瞄准", note: GameControlsOptionRows.note,
                    options: [PadOption(id: "", label: "默认", detail: row.text(defaults) + "（来自设置）")]
                        + row.choices.map { PadOption(id: $0.id, label: $0.label, detail: Self.detail(row, $0.id)) },
                    selected: changed ? row.choices[row.index(in: now)].id : "") { choice in
                    save(row.setting(choice.isEmpty ? nil : choice, in: own))
                }
            }
        }
    }

    private func save(_ gyro: GameGyro?) {
        var c = store.game(titleID)
        c.gyro = gyro
        store.setGame(titleID, c)
    }

    /// The grey line under a row.
    static func subtitle(_ row: GyroRow) -> String? {
        switch row {
        case .output: "开启后持续生效，无需按住任何按键"
        case .pauseButton: "按住时暂停陀螺仪瞄准（便于归中视角）"
        case .sensitivity: "按左右方向键可快速调节"
        case .antiDeadZone: "摇杆起始推力，用于跨过游戏自身的死区"
        case .smoothing: "平稳细微转动，会带来轻微延迟"
        case .turnAxis: "「玩家空间」适合任意握持姿势"
        default: nil
        }
    }

    /// A choice's grey text in the picker.
    static func detail(_ row: GyroRow, _ id: String) -> String? {
        switch (row, id) {
        case (.output, "mouse"): "适合使用鼠标瞄准的游戏"
        case (.output, "rightStick"): "适合仅支持手柄输入的游戏"
        case (.antiDeadZone, "0.0"): "摇杆从零位开始输出"
        case (.antiDeadZone, "0.27"): "XInput 标准死区，适用于大多数游戏"
        case (.smoothing, "auto"): "手柄陀螺仪为关闭，iPhone 陀螺仪为标准"
        case (.smoothing, "off"): "原样实时响应，无任何延迟"
        case (.smoothing, "light"): "平滑强度为「标准」的一半，手感更跟手"
        case (.smoothing, "normal"): "稳定持握瞄准，慢速移动时略有延迟"
        case (.source, "auto"): "优先使用已连接手柄的陀螺仪，否则使用 iPhone"
        case (.source, "controller"): "支持 DualSense、DualShock 4 等带陀螺仪的手柄"
        case (.turnAxis, "playerSpace"): "无论如何握持，均围绕现实世界的水平方向左右转向"
        case (.turnAxis, "yaw"): "围绕设备自身的垂直轴转向"
        case (.turnAxis, "roll"): "像转动方向盘一样倾斜转向"
        default: nil
        }
    }
}

/// The dot that follows the aim (GyroAim.dc.html's "Try it"): runs the sensors
/// for itself while it is on screen and no game runs, with `target`'s settings.
struct GyroTestArea: View {
    static let itemID = "gyro:test"
    let target: GyroPreviewTarget
    @ObservedObject private var sensors = GyroSensors.shared
    @ObservedObject private var store = ControlsStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let settings: GyroSettings = switch target {
        case .game(let id): store.gyro(id)
        case .defaults: store.gyroDefaults
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("测试区域 · 圆点代表准星位置").font(.system(size: 10, weight: .semibold)).tracking(0.8)
                .foregroundStyle(PP.muted)
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(PP.background)
                RoundedRectangle(cornerRadius: 14).stroke(PP.line, lineWidth: 1)
                // The middle: where the dot starts, and where a tap brings it back.
                Circle().stroke(PP.text.opacity(0.4), lineWidth: 1.5).frame(width: 40, height: 40)
                Circle().stroke(PP.text.opacity(0.6), lineWidth: 1.5).frame(width: 10, height: 10)
                if case .previewing = sensors.run {
                    TimelineView(.animation) { _ in
                        let p = sensors.feed.preview
                        GeometryReader { geo in
                            let w = geo.size.width / 2 - 12, h = geo.size.height / 2 - 12
                            Circle().fill(PP.accent).frame(width: 14, height: 14).shadow(color: PP.accent, radius: 7)
                                .position(x: geo.size.width / 2 + p.dot.x * w, y: geo.size.height / 2 - p.dot.y * h)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            // The bias learnt while still (GyroAim's calibration).
                            Text(p.calibrated ? "● 已校准" : "请保持静止片刻以完成校准")
                                .font(.system(size: 10)).foregroundStyle(p.calibrated ? PP.ok : PP.muted)
                                .padding(8)
                        }
                    }
                } else {
                    Text(status(settings)).font(.system(size: 13)).foregroundStyle(PP.soft).multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
            .frame(maxHeight: .infinity)
            .padItem(Self.itemID, hint: "归中", cornerRadius: 14) { sensors.feed.centreDot() }
            .accessibilityIdentifier("gyro-test-area")
            Text(hint(settings)).font(.system(size: 12)).foregroundStyle(PP.muted).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(PP.raised, lineWidth: 1))
        .onAppear { sensors.preview(target, active: scenePhase == .active) }
        .onDisappear { sensors.preview(nil, active: true) }
        .onChange(of: scenePhase) { _, phase in sensors.preview(target, active: phase == .active) }
    }

    /// Why the dot is not shown.
    private func status(_ s: GyroSettings) -> String {
        if s.output == .off { return "陀螺仪瞄准已关闭。选择「鼠标」或「右摇杆」即可在此测试。" }
        if let why = GyroText.sourceInUse(s.source, device: sensors.device(for: s)).why { return why + "。" }
        return "正在启动…"
    }

    private func hint(_ s: GyroSettings) -> String {
        switch s.output {
        case .rightStick: "转动设备以推动右摇杆，停止转动后圆点会回到中心。轻点可归中。"
        default: "左右转动控制水平移动，前后倾斜控制上下移动。轻点可归中。静止握持时会自动完成校准。"
        }
    }
}

// MARK: Settings › Controls › Gyro aim

/// What every game's gyro aim follows unless its Game options change it.
struct GyroDefaultsRows: View {
    @ObservedObject private var store = ControlsStore.shared
    @ObservedObject private var sensors = GyroSensors.shared

    var body: some View {
        let d = store.gyroDefaults
        PadSectionHeader(text: "陀螺仪瞄准").id("set:gyro")
        ForEach(GyroRow.allCases.filter { $0.isShown(in: d) }, id: \.self) { row in
            if row.isSwitch {
                SettingsSwitchRow(id: Self.id(row), title: row.title, subtitle: nil,
                                  on: Binding(get: { row.id(in: store.gyroDefaults) == "true" },
                                              set: { UserDefaults.standard.set($0, forKey: row.key) }))
            } else {
                let choices = row.choices
                let i = row.index(in: d)
                // A number between the steps (from the driver's set:) shows as itself.
                let labels = choices.indices.map { $0 == i ? row.text(d) : choices[$0].label }
                let source = GyroText.sourceInUse(d.source, device: sensors.device(for: d))
                let subtitle = switch row {
                case .source: source.why ?? "当前：" + source.value
                case .smoothing: "当前：" + GyroText.smoothingInUse(d.smoothing, device: sensors.device(for: d))
                    + "。「自动」在手柄陀螺仪下为关闭，在 iPhone 陀螺仪下为标准"
                default: GyroAimPanel.subtitle(row)
                }
                PadValueRow(id: "set:" + Self.id(row), title: row.title, subtitle: subtitle,
                            values: labels, index: i) {
                    UserDefaults.standard.set(row.stored(choices[$0].id), forKey: row.key)
                }
            }
        }
        SettingsNote(text: "陀螺仪瞄准可在你转动手机或带陀螺仪的手柄时移动视角，开启后持续生效。每款游戏都可在"
                     + "「游戏选项 › 操控 › 陀螺仪瞄准」中单独调整（内含测试区域），也可在游戏内菜单的「操控」面板中随时开关和调节灵敏度。")
    }

    /// `gyroOutput`, `gyroInvertX`: the row's driver id after `set:`.
    static func id(_ row: GyroRow) -> String {
        "gyro" + row.rawValue.prefix(1).uppercased() + row.rawValue.dropFirst()
    }
}
