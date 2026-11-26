// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › Developer, dev builds only (decision 0009): the Metal HUD
// (MetalHUD.swift), the diagnostics a
// game's next launch runs with (Diagnostics.swift), the memory simulations
// (MemoryLimit), the on-device pairing experiment (iOS 27), the probes
// (HelperLifetimeProbe.swift), the black screen (BlackScreen.swift), the logs
// and the wine_host ABI. Every control
// is a row on the ring; a choice opens a list picker. The workstation sets
// the same keys with `pp ui --action set:KEY=VALUE` (decision 0012).

import PlayportKit
import SwiftUI
import WineHost

struct DeveloperSettings: View {
    @AppStorage(MetalHUD.key) private var metalHUD = true
    @AppStorage(GPUCapture.key) private var frame = 0
    @AppStorage(Diagnostics.passProfileKey) private var passProfile = false
    @AppStorage(Diagnostics.cpuProfileKey) private var cpuProfile = false
    @AppStorage(Diagnostics.jitDumpKey) private var jitDump = false
    @AppStorage(MetalValidation.key) private var validation = MetalValidation.Level.off.rawValue
    @AppStorage(RuntimeCounters.key) private var countersOff = false
    @AppStorage(InprocSync.offKey) private var inprocSyncOff = false
    @AppStorage(MemoryLimit.simulatedKey) private var simulated = 0
    @AppStorage(MemoryLimit.simulatedPoolKey) private var simulatedPool = 0
    @ObservedObject private var sharedMemory = SharedMemoryProbe.shared
    @ObservedObject private var probe = HelperLifetimeProbe.shared
    @ObservedObject private var authProbe = NativeAuthProbe.shared
    @ObservedObject private var restart = AppRestart.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @ObservedObject private var builtIn = BuiltInJitStatus.shared
    @State private var hold = false

    var body: some View {
        diagnostics
        memory
        if #available(iOS 27.0, *) { pairingProbe }
        probes
        logs
        XboxResetDeviceSettings()
        SettingsInfoRow(id: "dev:abi", title: "wine_host ABI", value: "\(wine_host_abi_version())")
    }

    // MARK: diagnostics

    @ViewBuilder private var diagnostics: some View {
        PadSectionHeader(text: "诊断工具").id("diagnostics")
        SettingsSwitchRow(id: "dev:metalHUD", title: "Metal HUD",
                          subtitle: "在游戏上方显示 Apple Metal 性能浮层并将数据写入日志；下次启动 Playport 生效",
                          on: $metalHUD)
        choice("dev:gpuCapture", "GPU 帧捕获", subtitle: "将单帧保存为游戏目录下的 Metal .gputrace 文件",
               value: frame == 0 ? "关闭" : "第 \(frame) 帧",
               options: [PadOption(id: "0", label: "关闭")] + GPUCapture.frames.map { PadOption(id: "\($0)", label: "第 \($0) 帧") },
               selected: "\(frame)", note: "下次启动 Playport 生效；开启期间每一帧都会产生额外性能开销。") { frame = Int($0) ?? 0 }
        SettingsSwitchRow(id: "dev:passProfile", title: "逐渲染通道 GPU 耗时", subtitle: "在日志中记录 [pass-prof] 行",
                          on: $passProfile)
        SettingsSwitchRow(id: "dev:cpuProfile", title: "CPU 采样分析", subtitle: "在日志中记录 [wprof] 行", on: $cpuProfile)
        let levels: [(MetalValidation.Level, String)] = [(.off, "关闭"), (.api, "仅 API"), (.shaders, "API 与着色器"),
                                                         (.stop, "API（遇到首个错误即中止）")]
        choice("dev:validation", "Metal 校验层", subtitle: "错误信息输出至设备系统日志",
               value: levels.first { $0.0.rawValue == validation }?.1 ?? validation,
               options: levels.map { PadOption(id: $0.0.rawValue, label: $0.1) }, selected: validation,
               note: "下次启动 Playport 生效；会消耗额外的 CPU 与 GPU 时间。") { validation = $0 }
        SettingsSwitchRow(id: "dev:counters", title: "运行时计数器", subtitle: "关闭后与正式版一致，下次启动 Playport 生效",
                          on: Binding(get: { !countersOff }, set: { countersOff = !$0 }))
        SettingsSwitchRow(id: "dev:inprocsync", title: "进程内同步", subtitle: "不经 wineserver 的 NT 同步等待（ppsync）；下次启动 Playport 生效",
                          on: Binding(get: { !inprocSyncOff }, set: { inprocSyncOff = !$0 }))
        SettingsSwitchRow(id: "dev:jitDump", title: "JIT 内存池转储",
                          subtitle: "首次遇到未处理异常时，将完整 JIT 内存池保存为游戏 title-cfg 目录下的 fex-jit-dump.bin",
                          on: $jitDump)
    }

    // MARK: memory

    @ViewBuilder private var memory: some View {
        PadSectionHeader(text: "内存模拟").id("memory")
        // A Play ends at it as iOS ends one past its limit (PlayClock): 2 GB is under the about 3 GB
        // Hollow Knight reaches; 3.3 GB is what a copy without the entitlement gets.
        let limits = Self.choices([2048, 3379, 4096], with: simulated)
        choice("dev:simulatedLimit", "模拟内存上限", subtitle: "每次游玩达到此值即终止，模拟 iOS 超出内存限制强杀",
               value: simulated > 0 ? ByteCount.format(mb: simulated) : "关闭",
               options: [PadOption(id: "0", label: "关闭")] + limits.map { PadOption(id: "\($0)", label: ByteCount.format(mb: $0)) },
               selected: "\(simulated)", note: nil) { simulated = Int($0) ?? 0 }
        // Below Hollow Knight's high-water marks, so a Play runs the pool out (docs/evidence/2026-09-28-jit-pool.md).
        let pools = Self.choices([128, 256, 512], with: simulatedPool)
        choice("dev:simulatedPool", "模拟 JIT 内存大小", subtitle: "每次启动游戏分配的 JIT 内存池容量",
               value: simulatedPool > 0 ? ByteCount.format(mb: simulatedPool) : "关闭",
               options: [PadOption(id: "0", label: "关闭")] + pools.map { PadOption(id: "\($0)", label: ByteCount.format(mb: $0)) },
               selected: "\(simulatedPool)", note: nil) { simulatedPool = Int($0) ?? 0 }
        // The donor pool and the end of a game's own Social Club are Settings › Graphics' rows (decision 0153).
    }

    private static func choices(_ base: [Int], with current: Int) -> [Int] {
        current > 0 && !base.contains(current) ? (base + [current]).sorted() : base
    }

    // MARK: on-device pairing (iOS 27)

    @ViewBuilder private var pairingProbe: some View {
        PadSectionHeader(text: "本机配对（实验性）").id("pairing")
        PadRow(id: "set:dev:pairing", title: "配对此 iPhone（实验性）", subtitle: pairing.status,
               value: pairing.code, hint: "配对") {
            guard !pairing.busy, !builtIn.busy, !JitSetup.shared.presented else { return }
            pairing.start()
        }
        if pairing.storedNewPairing { SettingsInfoRow(id: "dev:pairingReadiness", title: "就绪状态", value: builtIn.readiness) }
        if pairing.busy { PadRow(id: "set:dev:pairingCancel", title: "取消配对", hint: "取消") { pairing.stop() } }
        if pairing.hasNewPairing {
            PadRow(id: "set:dev:pairingUse", title: "使用新配对", hint: "使用") { if !builtIn.busy { pairing.useNewPairing() } }
        }
    }

    // MARK: probes

    @ViewBuilder private var probes: some View {
        PadSectionHeader(text: "底层探测").id("probes")
        ForEach([64, 2048, 4096], id: \.self) { mb in
            PadRow(id: "set:dev:memoryBroker:\(mb)", title: "共享内存：\(mb) MiB", subtitle: sharedMemory.status, hint: "测试") {
                if !sharedMemory.busy { Task { _ = await sharedMemory.run(mb: mb) } }
            }
        }
        ForEach([false, true], id: \.self) { purgeable in
            ForEach([2048, 4096], id: \.self) { mb in
                let kind = purgeable ? "purgeable" : "tagged"
                let kindLabel = purgeable ? "可清除" : "已标记"
                PadRow(id: "set:dev:memoryDonor:\(kind):\(mb)", title: "扩展内存（\(kindLabel)）：\(mb) MiB",
                       subtitle: "辅助进程分配后退出，主应用保留 60 秒", hint: "测试") {
                    if !sharedMemory.busy { Task { _ = await sharedMemory.runDonor(mb: mb, purgeable: purgeable) } }
                }
            }
        }
        ForEach(SharedMemoryProbe.donorTotals, id: \.self) { mb in
            PadRow(id: "set:dev:memoryDonors:\(mb)", title: "扩展内存池：\(mb) MiB",
                   subtitle: "新辅助进程提供可清除内存后退出，主应用保留内存池", hint: "测试") {
                if !sharedMemory.busy { Task { _ = await sharedMemory.runDonors(mb: mb) } }
            }
        }
        PadRow(id: "set:dev:memoryPoolZero", title: "扩展内存池：清零测试", subtitle: sharedMemory.status, hint: "测试") {
            if !sharedMemory.busy { Task { _ = await sharedMemory.runPoolZero() } }
        }
        PadRow(id: "set:dev:memoryPoolGPU", title: "扩展内存池：Metal 缓冲区测试", subtitle: sharedMemory.status, hint: "测试") {
            if !sharedMemory.busy { Task { _ = await sharedMemory.runPoolGPU() } }
        }
        PadRow(id: "set:dev:memoryPoolVerify", title: "校验扩展内存池", subtitle: sharedMemory.status, hint: "校验") {
            if !sharedMemory.busy { Task { _ = await sharedMemory.verifyPool() } }
        }
        PadRow(id: "set:dev:nativeAuth", title: "原生身份验证探测", subtitle: authProbe.status,
               hint: "运行") {
            if !authProbe.busy { Task { _ = await authProbe.run() } }
        }
        PadRow(id: "set:dev:helperExit", title: "助手生命周期：exit 退出", subtitle: probe.status, hint: "运行") {
            if !probe.busy { Task { _ = await probe.run(.exit, hold: hold) } }
        }
        PadRow(id: "set:dev:helperKill", title: "助手生命周期：SIGKILL 终止", hint: "运行") {
            if !probe.busy { Task { _ = await probe.run(.kill, hold: hold) } }
        }
        SettingsSwitchRow(id: "dev:helperHold", title: "助手保持驻留", subtitle: "持有独立事务并忽略 SIGTERM", on: $hold)
        PadRow(id: "set:dev:helperReport", title: "助手生命周期：读取报告", hint: "读取") {
            if !probe.busy { Task { _ = await probe.report() } }
        }
        PadRow(id: "set:dev:restart", title: "立即重启 Playport", subtitle: "模拟退出游戏后的应用自重启流程（不运行游戏）",
               hint: "重启") {
            if !restart.restarting, !probe.busy { restart.restart(notice: nil) }
        }
        PadRow(id: "set:dev:blackScreen", title: "纯黑息屏护眼",
               subtitle: "手机未锁屏静置时以最低亮度显示纯黑画面；轻点屏幕或按任意键唤醒",
               hint: "显示") { BlackScreen.shared.show() }
    }

    // MARK: logs

    @ViewBuilder private var logs: some View {
        PadSectionHeader(text: "日志").id("logs")
        let urls = Self.logs
        if urls.isEmpty { SettingsInfoRow(id: "dev:nologs", title: "暂无日志") }
        ForEach(urls, id: \.self) { url in
            PadRow(id: "set:dev:log:\(url.lastPathComponent)", title: url.lastPathComponent, accessory: .chevron, hint: "分享") {
                ProblemReport.present([url])
            }
        }
    }

    /// The host log, the Steam log and any title's player log (a `-logFile C:\...` argument).
    private static var logs: [URL] {
        let fm = FileManager.default
        let driveC = LibraryModel.paths.games.deletingLastPathComponent()
        let players = ((try? fm.contentsOfDirectory(at: driveC, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return ([AppLog.url, SteamLog.url] + players).filter { fm.fileExists(atPath: $0.path) }
    }

    // MARK: pieces

    /// A row whose value comes from a list picker.
    private func choice(_ id: String, _ title: String, subtitle: String?, value: String, options: [PadOption], selected: String,
                        note: String?, choose: @escaping (String) -> Void) -> some View {
        PadRow(id: "set:" + id, title: title, subtitle: subtitle, value: value, accessory: .chevron, hint: "更改") {
            PadModal.shared.picker(title: title, context: "设置 · 开发者", note: note, options: options,
                                   selected: selected, choose: choose)
        }
    }
}
