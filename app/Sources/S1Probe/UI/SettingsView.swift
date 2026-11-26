// SPDX-License-Identifier: GPL-3.0-or-later
// Settings (docs/design/2026-09-28-gamepad-ui/Settings.dc.html,
// SettingsGraphics.dc.html): the sections down the left (PlayportKit
// SettingsSection), the one the ring is on shown at the right. The ring moves
// down the list with up and down, which shows each section; right goes into
// it, left and B come back to the list, B there closes Settings (AppShell's
// `settingsPress`). Every row is on the ring, and a tap does what A does.
//
// - Accounts: Steam's, SteamAccountSettings (AccountView.swift); GOGAccountSettings and EpicAccountSettings after it.
// - Graphics: what every game launches with unless its Game options change
//   it (LaunchSettingsStore.global): resolution, frame rate limit and
//   Direct3D, changed with left and right, each "Default · X" while it follows
//   Playport's default; and the performance overlay (UI/PerformanceOverlay.swift).
// - Downloads: PlayportKit DownloadPreferences (the download queue reads
//   them) and Steam Cloud's switch (SteamAccountModel.cloudKey).
// - Controls: when the on-screen controls show, every game's starting layout
//   (`controls.startingLayout`; Suggested for the game, else a layout), their
//   opacity, the Gamepad layout's d-pad and right stick, and haptics
//   (PlayportKit ControlsDefaults; UI/TouchControlsView.swift), gyro aim's
//   defaults (UI/GyroAimView.swift, the `gyro.*` keys), every
//   controller connected, with its battery and whether it has a gyro (PadRouter),
//   and the Controller page for every game's default controller map
//   (UI/ControllerMapView.swift, `controls.controllerMap`, `controls.lookSpeed`).
// - Virtual gamepad, a foldable's only: its layouts, each opening the editor
//   (VirtualGamepad.swift, PadLayoutEditor.swift).
// - Storage: free space and each game's size; A opens the game's page. Steamworks Shared
//   (Steam's redistributables) with its size and Remove, and the emulator cache with Clear.
// - Setup check: JIT, LocalDevVPN and memory (SetupCheckSettings.swift).
// - Launchers, dev builds only for now: each publisher's launcher with Open (LaunchersSettings.swift).
// - About: the build, the copyright and the licences (LicencesView.swift),
//   whose pages show in its place; B on one of their rows goes back a page.
// - Developer, dev builds only (Dev/DeveloperSettings.swift, decision 0009).

import Combine
import HostIOKit
import PlayportKit
import SteamClientKit
import SwiftUI
import UniformTypeIdentifiers
import WineHost

extension SettingsSection {
    /// The list entry's focus item.
    var navItem: String { "set:nav:" + rawValue }

    static func isNavItem(_ id: String) -> Bool { id.hasPrefix("set:nav:") }

    /// The sections this build shows.
    @MainActor static var shown: [SettingsSection] {
        #if PLAYPORT_RELEASE
        all(developer: false, foldable: Panel.isFoldable)
        #else
        all(developer: true, foldable: Panel.isFoldable)
        #endif
    }
}

struct SettingsView: View {
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var focus = PadFocus.shared
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollOffset: CGFloat = 0

    /// The page's width, for the narrow layout below.
    @State private var width: CGFloat = 0

    var body: some View {
        // A narrow page (an iPhone Duo's cover panel, UI/PanelFit.swift) keeps more of its
        // width for the section: a slimmer list and margins.
        let narrow = width > 0 && width < 760
        HStack(alignment: .top, spacing: narrow ? 16 : 22) {
            sidebar.frame(width: narrow ? 150 : 190)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, narrow ? 20 : 44).padding(.top, 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The height the shell offers, from the top: a sidebar a few points taller must
        // not push the shell's footer off its place.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .task(id: navigation.pageSection) {
            // A dev build's `open:settings#SECTION`.
            guard navigation.settings, let name = navigation.pageSection else { return }
            if let s = SettingsSection.named(name), SettingsSection.shown.contains(s) {
                navigation.settingsSection = s
                try? await Task.sleep(for: .milliseconds(200))
                // `gyro`: Controls, at its Gyro aim rows; `jitdump`: Developer, at its JIT pool
                // dump switch; `controller`: its Controller page.
                if name == "controller" {
                    navigation.pageSection = nil
                    return navigation.openSettingsControllerMap()
                }
                focus.ring(name == "gyro" ? "set:" + GyroDefaultsRows.id(.output) : name == "jitdump" ? "set:dev:jitDump" : s.navItem)
            }
            navigation.pageSection = nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("设置").font(PP.display(26)).foregroundStyle(PP.text)
                .padding(.horizontal, 14).padding(.bottom, 10)
            // The list scrolls when the sections outgrow the height (a landscape phone
            // with the developer section); the ring keeps its entry in view.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(SettingsSection.shown, id: \.self) { s in
                            let on = navigation.settingsSection == s
                            Text(s.title)
                                .font(.system(size: 15, weight: on ? .semibold : .medium))
                                .foregroundStyle(on ? PP.background : PP.soft)
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity, minHeight: 37, alignment: .leading)
                                .background(on ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .padItem(s.navItem, hint: "打开", cornerRadius: 10) {
                                    navigation.settingsSection = s
                                    SettingsRing.enter()
                                }
                                .id(s.navItem)
                        }
                    }
                    // Room for the ring, 6 pt outside a row, which the scroll view would clip.
                    .padding(8).padding(.bottom, 12)
                }
                .padding(-8)
                .onChange(of: navigation.settingsSection) { _, s in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(s.navItem) }
                }
            }
        }
    }

    private var content: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        section(navigation.settingsSection)
                    }
                    // Room for the ring, 6 pt outside a row, which the scroll view would clip.
                    .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 20)
                }
                .padding(.horizontal, -8)
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                    scrollOffset = offset
                }
                // Another section starts at its top, however it was picked (touch or pad).
                .onChange(of: navigation.settingsSection) { scrollPosition.scrollTo(edge: .top) }
                .onChange(of: focus.focused) { _, id in
                    guard let id, id.hasPrefix("set:") else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        if SettingsSection.isNavItem(id) { proxy.scrollTo("set:top", anchor: .top) }
                        else if id.hasPrefix("set:lic") { scrollLicence(id, in: viewport.frame(in: .global)) }
                        else { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .task(id: navigation.licences) {
                    // A restored row may be offscreen. Its focus changes before the
                    // replacement page is laid out; scroll again once it is mounted,
                    // as the section-opening task above waits for its sidebar row.
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let id = focus.focused, id.hasPrefix("set:lic") else { return }
                    scrollLicence(id, in: viewport.frame(in: .global))
                }
            }
        }
    }

    private func scrollLicence(_ id: String, in viewport: CGRect) {
        guard let frame = focus.items[id]?.frame else { return }
        // The focus geometry is the actual row, unlike a nested ForEach's
        // ScrollViewReader anchor (which can cover the whole licences page).
        scrollPosition.scrollTo(y: max(0, scrollOffset + frame.midY - viewport.midY))
    }

    @ViewBuilder
    private func section(_ s: SettingsSection) -> some View {
        Color.clear.frame(height: 0).id("set:top")
        switch s {
        case .accounts:
            SteamAccountSettings()
            GOGAccountSettings()
            EpicAccountSettings()
            #if !PLAYPORT_RELEASE
            XboxAccountSettings()
            #endif
        case .graphics: GraphicsSettings()
        case .downloads: DownloadSettings()
        case .controls: ControlsSettings()
        case .virtualPad: VirtualPadSettings()
        case .storage: StorageSettings()
        case .setup: SetupCheckSettings()
        case .launchers: LaunchersSettings()
        case .about:
            if let page = navigation.licences.last { LicencePageView(page: page) } else { AboutSettings() }
        case .developer:
            #if PLAYPORT_RELEASE
            EmptyView()
            #else
            DeveloperSettings()
            #endif
        }
    }
}

/// The ring inside Settings (AppShell sends its presses here): the list's entries
/// and the shown section's rows, kept apart so up and down in a section never
/// land on the list, and left from a row comes back to the section's entry.
@MainActor
enum SettingsRing {
    /// Handles a press in Settings; false leaves it to the shell's footer.
    static func press(_ b: NavButton) -> Bool {
        let focus = PadFocus.shared
        let nav = AppNavigation.shared
        let ringed = focus.focused ?? ""
        let onList = SettingsSection.isNavItem(ringed) || focus.items[ringed] == nil
        switch b {
        case .up, .down:
            if onList {
                let s = nav.settingsSection.step(b == .up ? -1 : 1, developer: SettingsSection.shown.contains(.developer),
                                                 foldable: SettingsSection.shown.contains(.virtualPad))
                nav.settingsSection = s
                focus.ring(s.navItem)
            } else {
                focus.move(b == .up ? .up : .down, within: isRow)
            }
        case .right:
            if onList { enter() } else { focus.move(.right, within: isRow) }
        case .left:
            if onList { return true }
            if focus.items[ringed]?.adjustable == true { focus.move(.left) } else { focus.ring(nav.settingsSection.navItem) }
        case .b:
            if onList { _ = nav.back() } else if !nav.licences.isEmpty { nav.closeLicence() } else { focus.ring(nav.settingsSection.navItem) }
        default:
            return false
        }
        return true
    }

    /// Into the shown section: its top row.
    static func enter() {
        let focus = PadFocus.shared
        let rows = focus.items.filter { isRow($0.key) }.mapValues(\.frame)
        if let top = FocusMove.first(among: rows) { focus.ring(top) }
    }

    private static func isRow(_ id: String) -> Bool { id.hasPrefix("set:") && !SettingsSection.isNavItem(id) }

    /// What B does here, for the footer.
    static var backLabel: String {
        if SettingsSection.isNavItem(PadFocus.shared.focused ?? "set:nav:") { return "返回" }
        return AppNavigation.shared.licences.isEmpty ? "分类" : "返回"
    }
}

/// Asks the shell (AppShell) for the Files picker: Setup check's pairing file import, the checklist's step.
@MainActor
enum SettingsImport {
    static let requests = PassthroughSubject<Void, Never>()
}

// MARK: shared pieces

/// The grey line over a section's rows (SettingsGraphics.dc.html).
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(PP.muted).lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2).padding(.top, 12).padding(.bottom, 2)
    }
}

/// A row that shows a fact: on the ring, A does nothing.
struct SettingsInfoRow: View {
    let id: String
    let title: String
    var subtitle: String?
    var value: String?

    var body: some View {
        PadRow(id: "set:" + id, title: title, subtitle: subtitle, value: value, hint: "") {}
    }
}

/// A switch row bound to a UserDefaults Bool.
struct SettingsSwitchRow: View {
    let id: String
    let title: String
    var subtitle: String?
    @Binding var on: Bool

    var body: some View {
        PadRow(id: "set:" + id, title: title, subtitle: subtitle, accessory: .toggle(on), hint: "切换") { on.toggle() }
    }
}

// MARK: Graphics

private struct GraphicsSettings: View {
    @ObservedObject private var launchSettings = LaunchSettingsStore.shared
    @AppStorage(PerformanceOverlay.key) private var performanceOverlay = false
    // On unless turned off (decision 0153; GameSocialClubEnd).
    @AppStorage(GameSocialClubEnd.key) private var endGameSocialClub = true
    @AppStorage(GameSocialClubEnd.refuseRestartKey) private var refuseGameSocialClubRestart = true
    /// Read only to redraw the donor row when it changes; DonorPool.setting reads it (Auto when unset).
    @AppStorage(DonorPool.key) private var donorPoolStored = DonorPoolSizing.Setting.autoStored

    var body: some View {
        SettingsNote(text: "所有游戏的默认画面设置，除非你在单个游戏的详情页中另行修改。")
        let global = $launchSettings.global
        // The aspect ratio, then the resolution, the same levels in every shape (decision 0073).
        // Left is lower, right higher: 540p … Native; 30 fps … Off.
        let shape = launchSettings.global.aspect.flatMap(ScreenAspect.init(rawValue:)) ?? .phone
        let aspects = SettingSteps(values: ScreenAspect.allCases.map(\.rawValue), defaultValue: ScreenAspect.phone.rawValue)
        valueRow("aspect", "画面比例", shape == .phone ? "适配手机自身屏幕比例" : "画面两侧或上下保留黑边",
                 aspects, name: { LaunchSettingsText.aspect(ScreenAspect(rawValue: $0) ?? .phone) }, value: global.aspect)
        let screens = SettingSteps(values: LaunchSettingsText.screens(shape).reversed(), defaultValue: LaunchSettings.defaultScreen)
        valueRow("screen", "分辨率", "越高越清晰，越低越省电", screens,
                 name: { LaunchSettingsText.screen($0, pixels: false) }, value: global.screen)
        let limits = SettingSteps(values: LaunchSettingsText.frameLimits + [0], defaultValue: LaunchSettings.defaultFrameLimit)
        valueRow("frameLimit", "帧率限制", "调低可节省电量并减少发热", limits,
                 name: LaunchSettingsText.frameLimit, value: global.frameLimit)
        let backends = SettingSteps(values: GraphicsBackend.allCases.filter { Manifest.has($0) || $0 == launchSettings.global.graphics },
                                    defaultValue: GraphicsBackend.default)
        valueRow("graphics", "Direct3D", "默认 Vulkan；Direct3D 10 和 11 游戏也可选 DXMT", backends,
                 name: LaunchSettingsText.graphics, value: global.graphics)
        SettingsSwitchRow(id: "performanceOverlay", title: "性能监控悬浮窗",
                          subtitle: "在游戏画面上方显示帧率、帧时间与机身温度",
                          on: $performanceOverlay)
        memoryRows
        SettingsNote(text: "在每个游戏下次启动时生效。720p 搭配 60 fps 能让手机保持凉爽并稳定维持帧率；"
                     + "「原生」使用屏幕完整分辨率，「关闭」帧率限制则会按屏幕支持的最高速度运行。"
                     + "选择手机屏幕以外的画面比例会在画面两侧或上下留出黑边；"
                     + "若部分游戏在手机超宽屏下显示黑屏，切换为 16:9 即可解决。"
                     + LaunchSettingsText.graphicsFooter)
    }

    /// Every game's memory defaults (decision 0153): the donor pool, on phones with a tier pool
    /// (DonorPoolSizing.offered), and the end of a game's own Social Club after its sign-in.
    @ViewBuilder
    private var memoryRows: some View {
        if DonorPoolSizing.offered(physicalMB: Int(ProcessInfo.processInfo.physicalMemory >> 20)) {
            // Through DonorPool.setting: the driver's set: may store "auto" or "off" as a string.
            let _ = donorPoolStored
            let current = DonorPool.setting
            let options = Self.donorOptions
            PadRow(id: "set:donorPool", title: "扩展内存池", subtitle: "由辅助进程分配后移交游戏使用的额外内存",
                   value: options.first { $0.0 == current }?.1 ?? "\(current.stored) MB（固定）", accessory: .chevron, hint: "更改") {
                PadModal.shared.picker(title: "扩展内存池", context: "设置 · 画面",
                                       note: "「自动」会在游戏启动前按机型默认大小申请内存池，并在系统内存紧张时自动停止；"
                                           + "若申请失败，游戏仍会使用常规内存启动。在每个游戏下次启动时生效。",
                                       options: options.map { PadOption(id: "\($0.0.stored)", label: $0.1) },
                                       selected: "\(current.stored)") { donorPoolStored = Int($0) ?? 0 }
            }
        }
        SettingsSwitchRow(id: "endGameSocialClub", title: "自动结束游戏自带的 Social Club",
                          subtitle: "针对 Rockstar 游戏：完成登录且接近内存上限时结束该进程，绝不终止游戏本体",
                          on: $endGameSocialClub)
        SettingsSwitchRow(id: "refuseGameSocialClubRestart", title: "阻止 Social Club 重新启动",
                          subtitle: "开启自动结束时生效：拦截游戏后续重新拉起 Social Club 的请求",
                          on: $refuseGameSocialClubRestart)
    }

    /// Off and Auto; a dev build also offers the fixed sizes to experiment with.
    private static var donorOptions: [(DonorPoolSizing.Setting, String)] {
        var options: [(DonorPoolSizing.Setting, String)] = [(.off, "关闭"), (.auto, "自动")]
        #if !PLAYPORT_RELEASE
        options += DonorPoolSizing.fixedSizesMB.map { (.fixed($0), ByteCount.format(mb: $0) + "（固定）") }
        #endif
        return options
    }

    private func valueRow<T: Equatable & Sendable>(_ id: String, _ title: String, _ subtitle: String, _ steps: SettingSteps<T>,
                                                   name: @escaping (T) -> String, value: Binding<T?>) -> some View {
        PadValueRow(id: "set:" + id, title: title, subtitle: subtitle, values: steps.labels(name),
                    index: steps.index(of: value.wrappedValue)) { value.wrappedValue = steps.stored(at: $0) }
    }
}

// MARK: Downloads

private struct DownloadSettings: View {
    @AppStorage(DownloadPreferences.autoUpdateKey) private var autoUpdate = true
    @AppStorage(DownloadPreferences.cellularKey) private var cellular = false
    @AppStorage(DownloadPreferences.dimKey) private var dim = true
    @AppStorage(SteamAccountModel.cloudKey) private var steamCloud = true
    @ObservedObject private var network = NetworkPath.shared

    var body: some View {
        Color.clear.frame(height: 42)
        SettingsSwitchRow(id: "autoUpdate", title: "自动更新游戏",
                          subtitle: "当 Steam 发布新版本时自动加入下载队列", on: $autoUpdate)
        SettingsSwitchRow(id: "cellular", title: "使用蜂窝网络下载",
                          subtitle: "关闭时仅通过 Wi-Fi 下载 · " + network.summary, on: $cellular)
        SettingsSwitchRow(id: "dim", title: "下载时调暗屏幕",
                          subtitle: "无操作一分钟后自动变暗", on: $dim)
        SettingsSwitchRow(id: "steamCloud", title: "使用 Steam 云同步存档",
                          subtitle: "适用于所有支持云存档的游戏", on: $steamCloud)
        SettingsNote(text: "打开游戏详情页时会从 Steam 云获取最新存档，结束游玩后会将存档同步回云端。"
                     + "你也可以在单个游戏的「游戏选项」中单独关闭该游戏的云存档。")
    }
}

// MARK: Controls

private struct ControlsSettings: View {
    @ObservedObject private var router = PadRouter.shared
    @ObservedObject private var store = ControlsStore.shared
    @AppStorage(ControlsDefaults.showKey) private var show = ControlsShow.automatic.rawValue
    @AppStorage(ControlsDefaults.opacityKey) private var opacity = ControlsOpacity.defaultValue
    @AppStorage(ControlsDefaults.hapticsKey) private var haptics = true
    @AppStorage(ControlsDefaults.dpadKey) private var dpad = OnScreenDpad.off.rawValue
    @AppStorage(ControlsDefaults.rightStickKey) private var rightStick = OnScreenRightStick.off.rawValue
    /// A layout's name, or "" for Suggested for the game.
    @AppStorage(ControlsDefaults.startingLayoutKey) private var startingLayout = ""

    var body: some View {
        Color.clear.frame(height: 42)
        let shows = ControlsShow.allCases
        let current = ControlsShow(rawValue: show) ?? .automatic
        PadValueRow(id: "set:controlsShow", title: "触屏按键", subtitle: Self.showSubtitle(current),
                    values: shows.map(\.title), index: shows.firstIndex(of: current) ?? 0) { show = shows[$0].rawValue }
        // Every game's layout unless it has its own or a compatibility default (SettingsControls.dc.html).
        let starts = OnScreenLayout.startingChoices
        PadValueRow(id: "set:controlsStartingLayout", title: "初始布局", subtitle: "每个游戏可单独选择各自布局",
                    values: starts.map(OnScreenLayout.startingTitle),
                    index: starts.firstIndex(of: OnScreenLayout(rawValue: startingLayout)) ?? 0) {
            startingLayout = starts[$0]?.rawValue ?? ""
        }
        let steps = ControlsOpacity.steps
        PadValueRow(id: "set:controlsOpacity", title: "不透明度", subtitle: "按键透出底层游戏画面的程度",
                    values: steps.map(ControlsOpacity.label),
                    index: steps.firstIndex(of: ControlsOpacity.step(opacity, by: 0)) ?? 0) { opacity = steps[$0] }
        let dpads = OnScreenDpad.allCases
        PadValueRow(id: "set:controlsDpad", title: "十字键", subtitle: "位于左摇杆上方",
                    values: dpads.map(\.title),
                    index: dpads.firstIndex(of: OnScreenDpad(rawValue: dpad) ?? .off) ?? 0) { dpad = dpads[$0].rawValue }
        let sticks = OnScreenRightStick.allCases
        PadValueRow(id: "set:controlsRightStick", title: "右摇杆", subtitle: "在 A/B/X/Y 按键旁的位置",
                    values: sticks.map(\.title),
                    index: sticks.firstIndex(of: OnScreenRightStick(rawValue: rightStick) ?? .off) ?? 0) {
            rightStick = sticks[$0].rawValue
        }
        SettingsSwitchRow(id: "controlsHaptics", title: "触觉反馈", subtitle: "按下触屏控件时提供振动反馈",
                          on: $haptics)
        SettingsNote(text: "每个游戏均可在游戏内菜单的「操控」中单独关闭或调整这些选项；"
                     + "三指轻点游戏画面或长按手柄 Home 键即可呼出游戏内菜单。若要连接实体手柄，请前往 iOS「设置 › 蓝牙」配对；Playport 与游戏会自动使用你最后按下的手柄。")
        if router.controllers.isEmpty {
            SettingsInfoRow(id: "controller:none", title: "未连接手柄", subtitle: "在此期间可全程使用触屏操作")
        }
        ForEach(Array(router.controllers.enumerated()), id: \.offset) { i, c in
            SettingsInfoRow(id: "controller:\(i)", title: c.name,
                            subtitle: ([i == 0 ? "正在使用" : nil, c.gyro ? "支持陀螺仪" : nil].compactMap { $0 }
                                .joined(separator: " · ")).nilIfEmpty,
                            value: battery(c))
        }
        // The Controller page for every game (UI/ControllerMapView.swift).
        PadRow(id: ControllerMapView.settingsRowID, title: "手柄映射", subtitle: "设置在所有游戏中手柄按键的默认行为",
               value: store.defaults.controllerMap.mode.title, accessory: .chevron, hint: "打开") {
            AppNavigation.shared.openSettingsControllerMap()
        }
        GyroDefaultsRows()
        Color.clear.frame(height: 0).onAppear { router.refreshControllers() }
    }

    private static func showSubtitle(_ s: ControlsShow) -> String {
        switch s {
        case .automatic: "未连接实体手柄时自动显示"
        case .always: "连接实体手柄时也始终显示"
        case .never: "默认关闭，除非在单个游戏中开启"
        }
    }

    private func battery(_ c: PadRouter.Controller) -> String {
        guard let b = c.battery else { return c.charging ? "正在充电" : "未报告电量" }
        return "电量 \(b)%" + (c.charging ? "，正在充电" : "")
    }
}

// MARK: Storage

private struct StorageSettings: View {
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        SettingsNote(text: "所有游戏及其存档均保存在 Playport 应用内部。删除应用会一并清空它们。")
        SettingsInfoRow(id: "free", title: "本机可用空间", value: library.freeBytes.map(ByteCount.format) ?? "未知")
        let used = library.catalog.titles.compactMap(\.sizeBytes).reduce(0, +)
        SettingsInfoRow(id: "games", title: "已装游戏", subtitle: "共安装 \(library.catalog.titles.count) 款",
                        value: ByteCount.format(used))
        ForEach(library.catalog.titles.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }) { t in
            PadRow(id: "set:title:\(t.id)", title: t.name, value: t.sizeBytes.map(ByteCount.format) ?? "未知",
                   accessory: .chevron, hint: "打开") {
                AppNavigation.shared.openTitle(t.id)
            }
        }
        // Steam's shared redistributables (decision 0081), which the library does not list: their
        // size, and the one way to remove them (PLA-171); a game that lists them downloads them again.
        if let sharedBytes {
            PadRow(id: "set:steamworks-shared", title: CommonRedistributables.installDir,
                   subtitle: "Steam 共享运行库组件，需要时会自动重新下载",
                   value: ByteCount.format(sharedBytes), destructive: true,
                   hint: launch.running || removingShared ? "" : "移除") {
                guard !launch.running, !removingShared else { return }
                removingShared = true
                Task {
                    self.sharedBytes = await library.removeSteamworksShared()
                    removingShared = false
                }
            }
        }
        // FEX's disk cache (decision 0056) and the runtime's image copies (decision 0167): their
        // size, and the one way to clear them (decision 0012).
        PadRow(id: "set:emulator-cache", title: "模拟器缓存",
               subtitle: "加快后续启动速度；超过 5 GB 或存储空间不足时自动清理",
               value: cacheBytes.map(ByteCount.format) ?? "…", hint: launch.running ? "" : "清理") {
            guard !launch.running, !clearing else { return }
            clearing = true
            Task {
                cacheBytes = await Task.detached(priority: .userInitiated) { () -> UInt64 in
                    EmulatorCache.clear()
                    return EmulatorCache.size()
                }.value
                clearing = false
            }
        }
        // The graphics backends' shader caches (PLA-279): their size, and the one way to clear them.
        PadRow(id: "set:shader-cache", title: "着色器缓存",
               subtitle: "加快后续启动速度；Mesa 缓存上限为 1 GB",
               value: shaderBytes.map(ByteCount.format) ?? "…", hint: launch.running ? "" : "清理") {
            guard !launch.running, !clearingShaders else { return }
            clearingShaders = true
            Task {
                shaderBytes = await Task.detached(priority: .userInitiated) { () -> UInt64 in
                    ShaderCache.clear()
                    return ShaderCache.size()
                }.value
                clearingShaders = false
            }
        }
        .task {
            cacheBytes = await Task.detached(priority: .utility) { EmulatorCache.size() }.value
            shaderBytes = await Task.detached(priority: .utility) { ShaderCache.size() }.value
            sharedBytes = await library.steamworksSharedBytes()
        }
    }

    @ObservedObject private var launch = TitleLaunch.shared
    @State private var cacheBytes: UInt64?
    @State private var clearing = false
    @State private var shaderBytes: UInt64?
    @State private var clearingShaders = false
    @State private var sharedBytes: UInt64?
    @State private var removingShared = false
}

// MARK: About

private struct AboutSettings: View {
    var body: some View {
        SettingsNote(text: "Playport 可在此 iPhone 上运行 Windows 游戏。基于 willfaust/Madeira 构建："
                     + "在同一进程内集成 Wine、FEX-Emu 与 DXMT。")
        SettingsInfoRow(id: "version", title: "版本", value: version)
        #if PLAYPORT_RELEASE
        SettingsInfoRow(id: "variant", title: "构建类型", value: "正式版")
        #else
        SettingsInfoRow(id: "variant", title: "构建类型", value: "开发版")
        #endif
        SettingsInfoRow(id: "abi", title: "运行时接口", value: "wine_host ABI \(wine_host_abi_version())")
        PadRow(id: LicencePage.list.row, title: "开源许可", subtitle: "GPL-3.0-or-later 及各组件的独立许可证",
               accessory: .chevron, hint: "打开") {
            AppNavigation.shared.openLicence(.list)
        }
        SettingsNote(text: "\(BundledLicences.copyright)。Playport 是遵循 GNU GPL 发布的自由软件，"
                     + "不提供任何形式的担保（ABSOLUTELY NO WARRANTY）。")
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        return [short, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "未知"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
