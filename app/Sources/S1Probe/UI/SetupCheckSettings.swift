// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Setup check: what a game needs from this phone, each a row with
// its state, and the rows that fix one. The controller; JIT, from the app's
// own helper (BuiltInJit.swift) with its pairing (on iOS 27 made on the
// phone, JitSetup; the import from Files is touch only); LocalDevVPN, which
// Playport turns on (LocalDevVPN.swift); and the memory iOS lets Playport use
// (MemoryLimit), with the JIT memory a Play gets from it; Steam, optional. Its
// first row opens the first-run checklist (SetupView.swift), which shows the
// pairing, LocalDevVPN, Increased Memory Limit and Steam (PlayportKit
// SetupChecklist) as four steps.
//
// The JIT method row picks where JIT comes from (JitMethodPicker, decision
// 0051). With StikDebug or another app, the built-in helper's rows give way
// to what that method needs; the pairing stays offered outside LiveContainer,
// since Playport restarts itself after a game with it (AppRestart).
//
// A dev build's built-in JIT rows are the full panel (the helper's raw readiness and
// reason, the disk image reset); a release build's show what a player acts
// on (decision 0009). A dev build's memory rows add the footprint and the
// phone's RAM; its simulations are in Developer.

import PlayportKit
import SwiftUI

struct SetupCheckSettings: View {
    @ObservedObject private var builtIn = BuiltInJitStatus.shared
    @ObservedObject private var setup = JitSetup.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @ObservedObject private var router = PadRouter.shared
    @ObservedObject private var state = SetupState.shared
    @EnvironmentObject private var model: SteamAccountModel
    @State private var reading = MemoryLimit.read()
    /// Read for its changes only; JitProvider.method is the choice.
    @AppStorage(JitMethod.key) private var storedMethod = ""
    private var method: JitMethod { _ = storedMethod; return JitProvider.method }

    private var tunnelUp: Bool? { state.tunnelUp }

    var body: some View {
        SettingsNote(text: "运行游戏所需的手机环境条件。每次启动游戏前 Playport 都会自动重新检查。")
        PadRow(id: "set:setup:checklist", title: "初始设置向导",
               subtitle: "首次启动时显示的四步检查清单",
               value: "已完成 \(SetupChecklist.doneCount(state.facts)) / \(SetupStep.allCases.count)", accessory: .chevron,
               hint: "打开") {
            AppNavigation.shared.openSetup()
        }
        #if !PLAYPORT_RELEASE
        // A dev build sees the checklist as a first run shows it, without deleting the
        // pairing or the Steam session: A completes each simulated step.
        PadRow(id: "set:setup:preview", title: "预览首次运行向导", subtitle: "开发调试：按 A 完成模拟步骤，不会改动手机实际设置",
               accessory: .chevron, hint: "预览") { preview(onPhone: SetupState.pairsOnPhone) }
        PadRow(id: "set:setup:preview26", title: "预览 iOS 26 首次运行向导", subtitle: "开发调试：从「文件」选择导入配对文件",
               accessory: .chevron, hint: "预览") { preview(onPhone: false) }
        #endif
        SettingsInfoRow(id: "setup:controller", title: "手柄",
                        subtitle: router.controller.map { "已连接 \($0.name)" } ?? "未连接；也可使用触屏操作",
                        value: router.controller == nil ? "可选" : "已就绪")
        jitRows
        PadRow(id: "set:setup:vpn", title: "LocalDevVPN", subtitle: "JIT 需要通过此隧道连接本机",
               value: tunnelUp.map { $0 ? "已连接" : "未连接" } ?? "正在检查…", accessory: .chevron,
               hint: "连接") {
            LocalDevVPN.connect { outcome in
                if outcome != .notInstalled, builtIn.pairingFile { builtIn.check() }
                state.readTunnel()
            }
        }
        steamRow
        memoryRows
            .task { await MemoryLimit.follow { reading = $0 } }
            .onAppear { state.follow() }
            .onDisappear { state.stopFollowing() }
    }

    #if !PLAYPORT_RELEASE
    private func preview(onPhone: Bool) {
        SetupState.log("preview a first run" + (onPhone ? "" : " on iOS 26"))
        state.previewFirstRun(onPhone: onPhone)
    }
    #endif

    /// Accounts, optional: A opens Settings › Accounts.
    private var steamRow: some View {
        let f = state.facts
        let stores = f.signedInStores
        return PadRow(id: "set:setup:steam", title: "账号", subtitle: stores.isEmpty ? "可选：登录 Steam、GOG 或 Epic Games 获取游戏库" : nil,
                      value: stores.isEmpty ? "未登录" : stores.joined(separator: "、"), accessory: .chevron, hint: "打开") {
            AppNavigation.shared.openSettings(section: .accounts)
        }
    }

    // MARK: JIT

    @ViewBuilder private var jitRows: some View {
        PadRow(id: "set:setup:jitMethod", title: "JIT 方式",
               subtitle: JitProvider.inLiveContainer ? "Playport 当前运行在 LiveContainer 内" : nil,
               value: method.label, accessory: .chevron, hint: "更改") {
            guard !TitleLaunch.shared.running else { return }
            JitMethodPicker.show()
        }
        if method == .builtIn, !BuiltInJit.helperBundled {
            // Found before any check: the helper extension was removed (a re-signer, or
            // SideStore's "remove app extensions"), so nothing below can work.
            SettingsInfoRow(id: "setup:jit", title: "JIT", subtitle: JitFailureReason.helperMissingMessage,
                            value: "缺少助手扩展")
        } else if method == .builtIn {
            builtInRows
        } else {
            SettingsInfoRow(id: "setup:jit", title: "JIT", subtitle: externalAdvice, value: method.label)
            if !JitProvider.inLiveContainer {
                pairingRow
                importRow
            }
        }
    }

    /// What JIT from another app needs; its own setup is that app's.
    private var externalAdvice: String {
        let lc = JitProvider.inLiveContainer
        switch method {
        case .stikDebug:
            return lc ? "点击「开始游戏」会自动打开 StikDebug。请在 LiveContainer 设置中开启「使用 LiveContainer 的 Bundle ID」。"
                : "点击「开始游戏」会自动打开 StikDebug，通过 universal.js 脚本启用 JIT 后返回 Playport。"
        default:
            return lc ? "请从 LiveContainer 使用 JIT 启动 Playport，并搭配 universal.js 脚本。每次启动新游戏都需要重新启动。"
                : "点击「开始游戏」后会等待其他应用提供 JIT，其脚本必须设为 universal.js。"
        }
    }

    #if PLAYPORT_RELEASE
    /// The built-in helper's rows. What it reports is worded for a
    /// player; its raw reason stays in the log.
    @ViewBuilder private var builtInRows: some View {
        SettingsInfoRow(id: "setup:jit", title: "JIT", subtitle: advice, value: statusText)
        pairingRow
        importRow
        if builtIn.pairingFile, !builtIn.busy, builtIn.status != "ready" {
            PadRow(id: "set:setup:check", title: "重新检查", hint: "检查") { builtIn.check() }
        }
        if builtIn.pairingFile, !builtIn.busy, builtIn.status == "not ready" {
            PadRow(id: "set:setup:ddi", title: "重新下载开发者磁盘映像", hint: "下载") { builtIn.resetDDI() }
        }
    }

    private var statusText: String {
        if !builtIn.pairingFile {
            if #available(iOS 27.0, *) { return "需要设置" }
            return "需要配对文件"
        }
        if builtIn.busy { return "正在检查…" }
        switch builtIn.status {
        case "ready": return "已就绪"
        case "unreachable": return "无法连接"
        case "not ready": return "未就绪"
        default: return "尚未检查"
        }
    }

    private var advice: String? {
        if builtIn.detail?.hasPrefix("import failed") ?? false { return "所选文件不是有效的配对文件。" }
        guard builtIn.pairingFile, !builtIn.busy else { return "游戏全速运行所必需的组件" }
        switch builtIn.status {
        case "unreachable": return "LocalDevVPN 未连接。点击「开始游戏」时 Playport 会自动开启它。"
        case "not ready":
            return (builtIn.failureReason?.message ?? "Playport 无法完成本机调试环境准备。") + " 请重新检查。"
        default: return "游戏全速运行所必需的组件"
        }
    }
    #else
    /// The full panel: the helper's raw readiness and reason, the reset.
    @ViewBuilder private var builtInRows: some View {
        SettingsInfoRow(id: "setup:jit", title: "JIT", subtitle: builtIn.detail,
                        value: builtIn.busy ? "正在检查…" : builtIn.readiness)
        SettingsInfoRow(id: "setup:pairingFile", title: "配对文件", value: builtIn.pairingFile ? "已导入" : "缺失")
        pairingRow
        importRow
        PadRow(id: "set:setup:check", title: "检查就绪状态", hint: "检查") {
            if builtIn.pairingFile, !builtIn.busy { builtIn.check() }
        }
        PadRow(id: "set:setup:ddi", title: "重置开发者磁盘映像",
               subtitle: "每次设备重启后会自动重新下载并挂载一次", hint: "重置") {
            if builtIn.pairingFile, !builtIn.busy { builtIn.resetDDI() }
        }
    }
    #endif

    @ViewBuilder private var pairingRow: some View {
        if #available(iOS 27.0, *) {
            PadRow(id: "set:setup:pair", title: builtIn.pairingFile ? "重新配对" : "配对此 iPhone",
                   subtitle: method == .builtIn ? "需要你批准开启开发者模式与 LocalDevVPN"
                       : "允许 Playport 在退出游戏后自动重启应用", accessory: .chevron, hint: "配对") {
                guard !builtIn.busy, !pairing.busy, !TitleLaunch.shared.spent else { return }
                setup.begin(repair: builtIn.pairingFile)
            }
        }
    }

    private var importRow: some View {
        PadRow(id: "set:setup:import", title: "导入配对文件", subtitle: "高级选项；选择文件需要使用触屏操作",
               accessory: .chevron, hint: "选择文件") {
            guard !builtIn.busy, !pairing.busy else { return }
            SettingsImport.requests.send()
        }
    }

    // MARK: memory

    @ViewBuilder private var memoryRows: some View {
        SettingsInfoRow(id: "setup:memory", title: "内存上限", subtitle: "由游戏本体与 Playport JIT 内存共同使用",
                        value: reading.effectiveMB.map { ByteCount.format(mb: $0) } ?? "未报告")
        SettingsInfoRow(id: "setup:iml", title: "增加内存限制",
                        subtitle: reading.entitled == false ? "当前安装包的签名未包含此权限" : nil,
                        value: reading.entitled.map { $0 ? "已开启" : "未开启" } ?? "未知")
        SettingsInfoRow(id: "setup:pool", title: "JIT 内存", value: ByteCount.format(mb: MemoryLimit.poolMB(reading)))
        #if !PLAYPORT_RELEASE
        if reading.simulatedMB != nil {
            SettingsInfoRow(id: "setup:realLimit", title: "实际内存上限",
                            value: reading.limitMB.map { ByteCount.format(mb: $0) } ?? "未报告")
        }
        SettingsInfoRow(id: "setup:footprint", title: "当前已用内存", value: ByteCount.format(mb: reading.footprintMB))
        SettingsInfoRow(id: "setup:phone", title: "本机物理内存", value: ByteCount.format(mb: reading.physicalMB))
        #endif
        SettingsNote(text: reading.entitled == false ? MemoryNote.notEntitled + " " + MemoryNote.footer : MemoryNote.footer)
    }
}
