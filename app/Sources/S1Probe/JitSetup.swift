// SPDX-License-Identifier: GPL-3.0-or-later
// Root-owned, same-phone setup. A pending Play awaits sheet dismissal before
// starting the runtime; no title, code or temporary credential persists on disk.
// A first run starts at the checklist (UI/SetupView.swift), whose pairing step
// begins this; a Play with no pairing or LocalDevVPN down begins it too (ensureReady).
import Foundation
import os
import PlayportKit
import SwiftUI
import UIKit

@MainActor
final class JitSetup: ObservableObject {
    static let shared = JitSetup()
    enum Phase { case preparing, pairing, vpn, connectingVPN, checking, failed, ready, cancelled }
    @Published private(set) var presented = false
    @Published private(set) var phase = Phase.preparing
    @Published private(set) var message = "正在准备游戏调试环境…"
    private var visible = false
    private var generation = 0
    private var repair = false
    private var original: Data?
    private var candidate: Data?
    private var cancellation = OSAllocatedUnfairLock(initialState: false)
    private var waiter: CheckedContinuation<Bool, Never>?
    private var preparation: Task<Void, Never>?
    private var dismissing = false
    private var replacementConflict = false


    /// Same entry for the game button and driver. Existing credentials with an
    /// active VPN do not require another sheet/check before each ordinary Play.
    var isActive: Bool { presented || visible || dismissing }

    func ensureReady() async -> Bool {
        guard !TitleLaunch.shared.running, !TitleLaunch.shared.spent else { return false }
        // A setup already visible (the checklist's pairing step) may be up before the driver's Play.
        // Join it once; subsequent duplicate Play requests are refused.
        if isActive {
            guard waiter == nil else { return false }
            return await withCheckedContinuation { waiter = $0 }
        }
        guard waiter == nil else { return false }
        // JIT from another app (JitMethod): that app has its own pairing and tunnel.
        guard JitProvider.method.usesPairing else { return true }
        do {
            if try BuiltInJit.storedPairingData() != nil, LocalDevVPN.tunnelUp { return true }
        } catch { /* Present a recoverable Keychain error, not an automatic replacement. */ }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            begin()
        }
    }

    func begin(repair: Bool = false) {
        guard !presented, !visible, !dismissing, !TitleLaunch.shared.running, !TitleLaunch.shared.spent else { return }
        replacementConflict = false
        preparation?.cancel()
        preparation = nil
        generation += 1
        cancellation = OSAllocatedUnfairLock(initialState: false)
        self.repair = repair
        original = nil
        candidate = nil
        visible = false
        phase = .preparing
        message = "正在准备游戏调试环境…"
        presented = true
    }

    func appeared() { visible = true; advance() }
    func sceneBecameActive() {
        OnDevicePairing.shared.codeWindow.dock()
        if presented, visible { advance() }
    }

    private func advance() {
        guard presented, visible, UIApplication.shared.applicationState == .active else { return }
        switch phase {
        case .preparing:
            guard preparation == nil else { return }
            let id = generation
            preparation = Task {
                defer { if id == generation { preparation = nil } }
                while BuiltInJitStatus.shared.busy || OnDevicePairing.shared.busy {
                    guard id == generation, presented, !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard id == generation, presented, UIApplication.shared.applicationState == .active else { return }
                guard BuiltInJit.hasGetTaskAllow else {
                    fail("当前安装版本无法启用游戏调试。请使用开发者签名重新签名安装 Playport。"); return
                }
                if candidate == nil {
                    do { original = try BuiltInJit.storedPairingData() }
                    catch { fail("无法读取系统钥匙串（Keychain）。请解锁此 iPhone 后重试，原有配对记录未被替换。"); return }
                }
                if candidate == nil && (original == nil || repair) {
                    phase = .pairing
                    message = "配对此 iPhone"
                    OnDevicePairing.shared.start { data, failure in
                        guard id == self.generation, self.presented else { return }
                        guard let data else { self.fail(failure ?? "设备配对未能完成。"); return }
                        self.candidate = data
                        self.phase = .vpn
                        self.advance()
                    }
                } else {
                    phase = .vpn
                    advance()
                }
            }
        case .vpn:
            if LocalDevVPN.tunnelUp { checkReadiness(); return }
            phase = .connectingVPN
            message = "正在连接 LocalDevVPN… 若 iOS 弹出提示，请允许添加其 VPN 配置。"
            let id = generation
            LocalDevVPN.connect { outcome in
                guard id == self.generation, self.presented else { return }
                switch outcome {
                case .connected:
                    self.phase = .vpn
                    self.advance()
                case .notInstalled:
                    self.fail("请从打开的 App Store 页面安装 LocalDevVPN，打开一次并允许添加 VPN 配置，然后返回此处轻点「继续」。")
                case .notConnected:
                    self.fail("LocalDevVPN 未连接。请打开该应用并允许其 VPN 配置，然后返回轻点「继续」。")
                case .late:
                    self.fail("欢迎回来。请轻点「继续」以完成游戏调试环境设置。")
                }
            }
        case .ready: finishPresentation()
        default: break
        }
    }

    private func checkReadiness() {
        guard !BuiltInJitStatus.shared.busy else {
            phase = .preparing
            advance()
            return
        }
        guard BuiltInJit.helperBundled else {
            BuiltInJitStatus.log("setup: PlugIns/PlayportJIT.appex is not in the app bundle")
            fail(JitFailureReason.helperMissingMessage)
            return
        }
        phase = .checking
        message = "正在准备游戏调试环境… 开发者磁盘映像将自动下载并挂载。"
        let id = generation
        BuiltInJitStatus.shared.check(pairingFile: candidate, cancelled: cancellation) { status in
            guard id == self.generation, self.presented else { return }
            guard status == "ready" else {
                self.fail(status == "unreachable"
                    ? "无法连接 LocalDevVPN。请先连接该 VPN，然后轻点「继续」。"
                    : (BuiltInJitStatus.shared.failureReason?.message ?? "无法准备游戏调试环境。")
                        + " 请轻点「继续」重试。")
                return
            }
            do {
                if let data = self.candidate {
                    try BuiltInJit.commitGeneratedPairing(data, replacing: self.original)
                    BuiltInJitStatus.shared.generatedPairingCommitted()
                    OnDevicePairing.shared.discardCredentials()
                    self.candidate = nil
                    BuiltInJitStatus.log("on-device setup: verified pairing committed to Keychain")
                }
            } catch {
                if case BuiltInJit.Failure.helper(let why) = error, why.contains("changed during setup") {
                    self.replacementConflict = true
                    self.candidate = nil
                    self.repair = false
                    OnDevicePairing.shared.discardCredentials()
                    self.fail("设置期间已有另一份配对记录被保存。轻点「继续」即可使用该配对，原有记录未被替换。")
                } else {
                    self.fail("无法保存配对记录。你原有的配对记录未被替换。")
                }
                return
            }
            self.phase = .ready
            self.message = "已就绪"
            // Never launch/dismiss over system Settings or another app.
            if UIApplication.shared.applicationState == .active { self.finishPresentation() }
        }
    }

    private func finishPresentation() {
        guard presented else { return }
        if visible { dismissing = true }
        presented = false
        if !visible { resumeWaiter(phase == .ready) }
    }

    func retry() {
        guard presented, phase == .failed else { return }
        if replacementConflict {
            replacementConflict = false
            original = nil
            phase = .preparing
        } else if candidate != nil || (!repair && original != nil) {
            phase = .vpn
        } else { phase = .preparing }
        advance()
    }

    private func fail(_ text: String) { phase = .failed; message = text }

    func cancel() {
        preparation?.cancel()
        preparation = nil
        generation += 1
        cancellation.withLock { $0 = true }
        OnDevicePairing.shared.stop()
        candidate = nil
        original = nil
        phase = .cancelled
        finishPresentation()
    }

    private func resumeWaiter(_ ready: Bool) {
        let continuation = waiter
        waiter = nil
        continuation?.resume(returning: ready)
    }

    /// Root sheet onDismiss: consume a pending Play exactly once, after the
    /// presentation has gone. Cold launch never resurrects an executable request.
    func dismissed() {
        visible = false
        dismissing = false
        let ready = phase == .ready
        if !ready { cancel() }
        original = nil
        candidate = nil
        resumeWaiter(ready)
    }
}

struct JitSetupSheet: View {
    @ObservedObject private var setup = JitSetup.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("设置游戏调试环境").font(.title2.bold())
                    if setup.phase == .pairing {
                        if let code = pairing.code {
                            // Plain text first: the picture-in-picture layer below shows
                            // nothing for someone who has picture in picture turned off.
                            Text("配对码").font(.headline).foregroundStyle(.secondary)
                            Text(verbatim: String(code.prefix(3)) + " " + String(code.suffix(3)))
                                .font(.system(size: 56, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("配对码 \(code.map(String.init).joined(separator: " "))")
                            PairingCodeView(window: pairing.codeWindow)
                                .aspectRatio(720.0 / 270.0, contentMode: .fit)
                            Text("如果配对码没有以悬浮窗形式显示在系统「设置」上方（即「设置 → 通用 → 画中画」已关闭），请先记住这组数字再轻点「打开系统设置」。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("打开系统设置") { pairing.openSettings() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                        Text(pairing.status)
                        Text("完成配对返回此处后，Playport 会自动完成剩余设置。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        if setup.phase != .failed { ProgressView() }
                        Text(setup.message)
                    }
                    if setup.phase == .failed {
                        Button("继续") { setup.retry() }.buttonStyle(.borderedProminent)
                        Button("在 iOS「设置」中查看 Playport 权限") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                    Text("「开发者模式」与系统权限需要你手动批准。在 iOS 27 上无需使用电脑或导入配对文件。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { setup.cancel() } } }
        }
        .interactiveDismissDisabled()
        .onAppear { setup.appeared() }
    }
}
