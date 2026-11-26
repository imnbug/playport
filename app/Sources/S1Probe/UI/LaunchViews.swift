// SPDX-License-Identifier: GPL-3.0-or-later
// The launch screen over a title's screen until its first frame
// (Launch.dc.html: the game's art, one progress bar, the step in a word, the
// tip for the in-game menu; the steps listed only when JIT is slow), the
// screen of a launch that failed at a step (LaunchFailureView: the steps,
// what happened and the fix), what a launch that did not end cleanly says
// (LaunchMessage), and the screen shown while Playport restarts itself after
// a game (decision 0029). A clean exit says nothing: Playport restarts to
// Home. A launch refused before the runtime started (a failed start-up
// self-check, a missing executable or Direct3D backend; never memory)
// says why in an alert over the page it was started from;
// one that failed at a step (JIT, the runtime, the game's start) shows the
// failure screen there or, when it had spent the runtime, once the
// restarted Playport shows Home (AppRestart); a crash or the JIT pool running
// out says why in an alert then.

import HostIOKit
import PlayportKit
import SteamClientKit
import SwiftUI

/// The launch screen over the title's black surface until its first frame
/// (Launch.dc.html): over the game's art as its page shows it (LaunchBackdrop,
/// drawn under this by RootView), its name, one progress bar and
/// the step in a word, what the checks before the Play found that does not stop
/// it (no controller, Steam signed out), and the tip for the in-game menu. The steps (JIT,
/// runtime, the dependencies once a launch installs some, game; decision 0095) are drawn
/// as dots and listed only when JIT is slow (LaunchProgress.jitSlow),
/// with the fix: LocalDevVPN when its tunnel is down. The pads are the
/// guest's from Play on (TitleLaunch.begin), so this screen takes no presses.
/// A step that fails shows on LaunchFailureView once the launch has ended.
struct LaunchScreen: View {
    @ObservedObject private var launch = TitleLaunch.shared
    @ObservedObject private var setup = SetupState.shared
    @ObservedObject private var router = PadRouter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Shown from Play: its parts come in one after another (UI/LaunchTransition.swift).
    @State private var shown = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(launch.stageSince)
            let slow = LaunchProgress.showsSteps(launch.stage, elapsed: elapsed)
            ZStack {
                VStack(spacing: 18) {
                    LaunchTitle(name: launch.title)
                        .scaleEffect(shown || reduceMotion ? 1 : 0.9)
                        .blur(radius: shown || reduceMotion ? 0 : 4)
                        .opacity(shown ? 1 : 0)
                        .animation(LaunchMotion.partIn(0.5, delay: 0.15), value: shown)
                    LaunchBar(fraction: LaunchProgress.fraction(launch.stage, elapsed: elapsed, part: launch.dependencyPart))
                        .opacity(shown ? 1 : 0)
                        .animation(LaunchMotion.partIn(0.45, delay: 0.25), value: shown)
                    HStack(spacing: 10) {
                        ForEach(LaunchProgress.steps(dependencies: launch.installsDependencies), id: \.self) { s in
                            Circle().fill(launch.stage > s ? PP.accent : PP.line).frame(width: 8, height: 8)
                        }
                        Text(LaunchProgress.status(launch.stage, part: launch.dependencyPart, elapsed: elapsed))
                            .font(.system(size: 14)).foregroundStyle(PP.soft).monospacedDigit()
                            .accessibilityIdentifier("launch-status")
                    }
                    .opacity(shown ? 1 : 0)
                    .animation(LaunchMotion.partIn(0.45, delay: 0.3), value: shown)
                    if slow, case .waitingForJit(let until) = launch.step {
                        LaunchSteps(current: .jit, failed: nil, dependencies: launch.installsDependencies) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("将在 \(max(0, Int(until.timeIntervalSince(ctx.date)))) 秒后停止等待").monospacedDigit()
                                Text(LaunchFix.slowJit(tunnelUp: LocalDevVPN.tunnelUp))
                            }
                        }
                        .frame(width: 420)
                    }
                }
                .padding(.top, slow ? 0 : 20)
                .frame(maxHeight: .infinity, alignment: slow ? .center : .top)
                .padding(.top, slow ? 0 : 98)
                VStack(spacing: 8) {
                    Spacer()
                    // What the checks before the Play found that does not stop it (SetupChecklist.notes).
                    ForEach(notes, id: \.self) { n in
                        Text(n).font(.system(size: 13, weight: .semibold)).foregroundStyle(PP.accent)
                    }
                    LaunchTip().padding(.bottom, 26)
                }
                .opacity(shown ? 1 : 0)
                .animation(LaunchMotion.partIn(0.45, delay: 0.35), value: shown)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(PP.text)
        .accessibilityIdentifier("launch-screen")
        .onAppear { shown = true }
    }
}

extension LaunchScreen {
    /// No controller (until one connects, and never with the virtual gamepad) and Steam signed out.
    private var notes: [String] {
        let pad = router.controller != nil || VirtualGamepad.shared.enabled
        return setup.launchNotes.filter { !pad || $0 != SetupChecklist.noController }
    }
}

/// What the player can do about a slow or failed step.
enum LaunchFix {
    /// What the launch screen says while it waits for JIT, by where JIT comes from (JitMethod).
    static func slowJit(tunnelUp: Bool, method: JitMethod = JitProvider.method) -> String {
        if method == .external { return JitNote.waitingForAnotherApp }
        if !tunnelUp {
            return "LocalDevVPN 未连接。请打开 LocalDevVPN 并连接：JIT 就绪后启动流程会自动继续。"
        }
        return method == .stikDebug ? JitNote.waitingForStikDebug : JitNote.waiting
    }

    static func failed(_ step: LaunchStage, tunnelUp: Bool, method: JitMethod = JitProvider.method) -> String {
        switch step {
        case .jit, .preparing:
            if method == .external {
                method.debuggerFailureMessage(detached: false, inLiveContainer: JitProvider.inLiveContainer)
            } else if !tunnelUp {
                "LocalDevVPN 未连接。请按 Y 开启它，然后重试。"
            } else if method == .stikDebug {
                "未收到 JIT 响应。请检查 StikDebug 是否已安装并配置妥当，然后重试。"
            } else {
                "未收到 JIT 响应。请在游戏启动期间保持 Playport 在前台显示，然后重试。"
            }
        case .runtime: "请重试。若仍然失败，请重启此 iPhone。"
        case .prerequisites, .game, .drawing: "请重试。若仍然失败，请在该游戏的「游戏选项」中校验游戏文件。"
        }
    }
}

/// A game's hero art as its page and its launch screen show it: filling the whole screen,
/// centred, dimmed as the launch screen always had it (28 % over the design's dark blue,
/// darker towards the bottom). Both draw it through this, so from the page to the game it
/// does not change.
struct GameHeroArt<Art: View>: View {
    @ViewBuilder let art: Art

    /// The widest band the art fills, width to height. A store's hero art is about
    /// 3:1; filling a whole panel nearer square (an iPhone Duo's, about 1.45:1) would
    /// crop away more than half its width. There the art fills a band this shape at
    /// the top and fades into the page; a landscape iPhone (about 2.2:1) is unchanged.
    static var band: CGFloat { 2 }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let height = size.width / size.height < Self.band ? size.width / Self.band : size.height
            ZStack(alignment: .top) {
                Color(hex: 0x131C2B)
                art
                    .frame(width: size.width, height: height)
                    .clipped()
                    .mask {
                        if height < size.height {
                            LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom)
                        } else {
                            Color.black
                        }
                    }
                    .opacity(0.28)
                LinearGradient(colors: [.clear, Color(hex: 0x05070A).opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The art a game's page hands the shell to draw behind it (AppShell, GameDetailView).
struct PageArt: Equatable {
    let appID: UInt32?
    let name: String
    /// The store's app, when the page has it; else GameArt looks the game up.
    let info: SteamAppInfo?
    /// The catalogue's title (a local game's icon) and the store's game (GOG's or Epic's art).
    var titleID: String? = nil
    var storeKey: StoreGameKey? = nil

    @ViewBuilder var view: some View {
        if let info {
            SteamArtView(app: info, kind: .hero, placeholder: PP.tile(for: name))
        } else {
            GameArt(appID: appID, name: name, kind: .hero, titleID: titleID, storeKey: storeKey)
        }
    }
}

struct PageArtKey: PreferenceKey {
    static let defaultValue: PageArt? = nil
    static func reduce(value: inout PageArt?, nextValue: () -> PageArt?) { value = value ?? nextValue() }
}

/// Behind the launch screen: the game's page as it was without its text and controls, its
/// hero art filling the screen, unchanged for the whole launch (on Play only the page's
/// text and controls leave and the launch screen's come; RootView).
struct LaunchBackdrop: View {
    let art: UIImage?
    let title: String

    var body: some View {
        ZStack {
            PP.background
            GameHeroArt { picture }
        }
        .ignoresSafeArea()
    }

    /// As SteamArtView draws it on the page: the tile colour under the art.
    private var picture: some View {
        ZStack {
            Rectangle().fill(PP.tile(for: title))
            if let art { Image(uiImage: art).resizable().aspectRatio(contentMode: .fill) }
        }
        .clipped()
    }
}

/// Across Playport's restart between a title's prerequisites and its game (decision 0084):
/// the launch screen's art and name with "Dependencies installed. Starting <title>…" (decision
/// 0095), in the old process from its
/// restart request to its end and in the new one until the game's launch screen takes over.
struct PlayContinuingScreen: View {
    let next: PlayContinuation
    @State private var art: UIImage?

    var body: some View {
        ZStack {
            LaunchBackdrop(art: art, title: next.title)
            VStack(spacing: 18) {
                LaunchTitle(name: next.title)
                Text(LaunchProgress.continuing(title: next.title)).font(.system(size: 14)).foregroundStyle(PP.soft)
                    .accessibilityIdentifier("launch-status")
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 118)
        }
        .foregroundStyle(PP.text)
        .accessibilityIdentifier("play-continuing")
        .onAppear { art = TitleLaunch.cachedArt(titleID: next.titleID, appID: next.appID) }
    }
}

/// Over the game surface (which ignores the safe area) the name keeps clear
/// of the Dynamic Island on whichever side it is (WindowInsets). Long names
/// wrap to two centred lines before shrinking, rather than running off-screen.
struct LaunchTitle: View {
    let name: String
    @ObservedObject private var safe = WindowInsets.shared

    var body: some View {
        let side = max(safe.side(44, safe.insets.leading), safe.side(44, safe.insets.trailing))
        Text(name.uppercased()).font(PP.display(56)).tracking(1.1)
            .lineLimit(2).minimumScaleFactor(0.5).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, side)
    }
}

struct LaunchBar: View {
    let fraction: Double
    var color: Color = PP.accent

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(PP.line)
            Capsule().fill(color).frame(width: 320 * min(1, max(0, fraction)))
                .animation(.linear(duration: 0.2), value: fraction)
        }
        .frame(width: 320, height: 4)
    }
}

/// "Tip: hold ⌂ on your controller for the Playport menu".
struct LaunchTip: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("提示：长按手柄上的")
            Text("⌂").font(.system(size: 11, weight: .bold)).foregroundStyle(PP.background)
                .padding(.horizontal, 5).frame(minWidth: 20, minHeight: 20).background(PP.text, in: Capsule())
            Text("键可呼出 Playport 菜单")
        }
        .font(.system(size: 13))
        .foregroundStyle(PP.muted)
    }
}

/// JIT, runtime, the dependencies (a launch that installed some) and game, each done,
/// running, failed or still to come; the running or failed one carries `detail`.
struct LaunchSteps<Detail: View>: View {
    let current: LaunchStage
    let failed: LaunchStage?
    var dependencies = false
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(LaunchProgress.steps(dependencies: dependencies || failed == .prerequisites), id: \.self) { s in
                let at = failed ?? current
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Group {
                        if s < at {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(PP.ok)
                        } else if s == at, failed != nil {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color(hex: 0xFF7A6B))
                        } else if s == at {
                            Image(systemName: "circle").hidden().overlay { ProgressView().tint(PP.text).scaleEffect(0.7) }
                        } else {
                            Image(systemName: "circle").foregroundStyle(PP.line)
                        }
                    }
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LaunchProgress.stepName(s)).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(s > at ? PP.muted : PP.text)
                        if s == at { detail().font(.system(size: 12)).foregroundStyle(PP.soft).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(PP.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(PP.line))
    }
}

/// A launch that stopped at a step (LaunchMessage.step), over the page it
/// was started from or, after the restart that follows a spent launch, over
/// the new process's Home: the steps with the failed one marked, what
/// happened, and the fix. A Try again, Y Turn on LocalDevVPN (a JIT step with
/// its tunnel down), B Back.
@MainActor
final class LaunchFailureSession: ObservableObject {
    let message: LaunchMessage
    @Published private(set) var tunnelUp = LocalDevVPN.tunnelUp

    init(_ message: LaunchMessage) { self.message = message }

    var offersVPN: Bool { (message.step == .jit || message.step == .preparing) && !tunnelUp && JitProvider.method.usesTunnel }

    func press(_ b: NavButton) {
        switch b {
        case .a: retry()
        case .y where offersVPN: turnOnVPN()
        case .b: close()
        default: break
        }
    }

    func close() {
        PadModal.shared.close()
        if TitleLaunch.shared.message == message { TitleLaunch.shared.message = nil }
    }

    func retry() {
        guard let id = message.titleID else { return close() }
        close()
        Task {
            if (try? await LibraryModel.shared.play(id)) != true, !TitleLaunch.shared.running, !PadModal.shared.isUp {
                AppNavigation.shared.openTitle(id)
            }
        }
    }

    func turnOnVPN() {
        LocalDevVPN.connect { _ in
            LaunchFailureSession.refresh()
        }
    }

    static func refresh() {
        if case .launchFailure(let s) = PadModal.shared.content { s.tunnelUp = LocalDevVPN.tunnelUp }
    }
}

struct LaunchFailureView: View {
    @ObservedObject var session: LaunchFailureSession

    var body: some View {
        let m = session.message
        let jitGuidance = JitMethod.debuggerFailure(in: m.text)
        ZStack {
            VStack(spacing: 14) {
                Text(m.title).font(PP.display(30)).multilineTextAlignment(.center).lineLimit(2)
                LaunchSteps(current: m.step ?? .jit, failed: m.step ?? .jit, dependencies: m.installedDependencies == true) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(jitGuidance ?? m.text)
                        if jitGuidance == nil {
                            Text(LaunchFix.failed(m.step ?? .jit, tunnelUp: session.tunnelUp)).foregroundStyle(PP.accent)
                        }
                    }
                }
                .frame(width: 460)
            }
            .padding(.bottom, 20)
            VStack {
                Spacer()
                HStack(spacing: 18) {
                    Spacer()
                    if m.titleID != nil { PadModalHint(button: .a, label: "重试") { session.press(.a) } }
                    if session.offersVPN { PadModalHint(button: .y, label: "开启 LocalDevVPN") { session.press(.y) } }
                    PadModalHint(button: .b, label: "返回") { session.press(.b) }
                }
                .padding(.horizontal, 36)
                .frame(height: 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The dimmed game art is a background, not a ZStack child: as a child
            // its ignoresSafeArea inflated the stack to the full window and pushed
            // the footer's right-aligned buttons into the side safe-area insets.
            Group {
                if let app = m.appID { GameArt(appID: app, name: m.title, kind: .hero).opacity(0.28) } else { Color.clear }
            }
            .background(Color(hex: 0x131C2B))
            .overlay(LinearGradient(colors: [.clear, Color(hex: 0x05070A).opacity(0.7)], startPoint: .top, endPoint: .bottom))
            .clipped()
            .ignoresSafeArea()
        }
        .foregroundStyle(PP.text)
        .accessibilityIdentifier("launch-failure")
    }
}

/// Why a launch did not end cleanly, as an alert says it; nil for a clean exit.
struct LaunchMessage: Codable, Equatable, Identifiable {
    var title: String
    var text: String
    /// The step that failed (LaunchProgress.failedStage): the launch screen
    /// shows the steps and the fix instead of an alert. Nil for the rest.
    var step: LaunchStage?
    /// The title, for the failure screen's art and its Try again.
    var titleID: String?
    var appID: UInt32?
    /// The launch installed dependencies before it failed: the steps list them (decision 0095).
    var installedDependencies: Bool?
    var id: String { title + "\n" + text }

    init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    static func of(_ outcome: LaunchCoordinator.Outcome, title: String, spent: Bool) -> LaunchMessage? {
        guard var m = message(outcome, title: title, spent: spent) else { return nil }
        if outcome.kind == .failed { m.step = LaunchProgress.failedStage(outcome.line) }
        return m
    }

    private static func message(_ outcome: LaunchCoordinator.Outcome, title: String, spent: Bool) -> LaunchMessage? {
        let line = outcome.line
        switch outcome.kind {
        case .exited(0):
            return nil
        case .exited(let code):
            #if PLAYPORT_RELEASE
            return .init(title: "\(title) 意外退出", text: "游戏因发生错误而结束。")
            #else
            return .init(title: "\(title) 意外退出", text: "游戏已退出，退出码 \(String(format: "0x%08X", code))。")
            #endif
        case .refused where SelfCheck.failure(in: line) != nil, .failed where SelfCheck.failure(in: line) != nil:
            return .init(title: "\(title) 无法启动", text: SelfCheck.explanation(SelfCheck.failure(in: line)!))
        case .refused where sessionFull(line):
            return .init(title: "Playport 需要重新启动",
                         text: "上一次游戏结束后 Playport 未能自动重启。请关闭应用并从主屏幕重新打开以游玩 \(title)。")
        case .refused where line.contains(" graphics="):
            return .init(title: "\(title) 无法启动",
                         text: "当前版本的 Playport 未包含此游戏所选的 Direct3D 后端。"
                            + "请在该游戏详情页或全局「设置 › 画面」中切换其他后端。")
        case .refused:
            return .init(title: "找不到 \(title)",
                         text: "在预期路径下未找到游戏可执行文件。请在游戏库页面下拉刷新重试。")
        case .prerequisitesRan:
            // The same Play goes on after the restart (decision 0084): nothing to say.
            return nil
        case .outOfJitMemory(let part):
            return .init(title: "\(title) 的 JIT 内存已耗尽",
                         text: JitNote.outOfMemory(part, poolMB: outcome.poolMB))
        case .outOfEmulatorMemory:
            return .init(title: "\(title) 的模拟器内存已耗尽",
                         text: JitNote.outOfEmulatorMemory)
        case .failed:
            return .init(title: "\(title) 无法启动", text: failedText(line, spent: spent))
        }
    }

    private static func failedText(_ line: String, spent: Bool) -> String {
        // WineHostRuntime.start's detail: `JIT pool (<n> MiB): <JitProvider failure>`.
        if let r = line.range(of: "JIT pool ("), let colon = line[r.upperBound...].range(of: "): ") {
            let why = line[colon.upperBound...]
            // The live-tracer gate supplies a player-facing reason, not a raw
            // helper error. Keep its script/target/relaunch guidance in both
            // variants instead of replacing it with LocalDevVPN advice.
            if JitMethod.debuggerFailure(in: String(why)) != nil { return String(why) }
            #if PLAYPORT_RELEASE
            // The helper's raw reason is in the log; the player gets what to do.
            if why.contains("no pairing file") { return "请先在「设置」中导入配对文件，然后重试。" }
            return "无法配置 JIT。请检查 LocalDevVPN 是否已连接，然后重试。"
            #else
            return why.hasPrefix("wine_host_jit_pool_acquire")
                ? "JIT 等待超时（\(why)）。请检查 LocalDevVPN 是否已连接，然后重试。"
                : "无法请求 JIT：\(why)。"
            #endif
        }
        return spent ? "JIT 已启用，但运行时环境或游戏启动失败。"
                     : "运行时环境或游戏启动失败。"
    }

    /// A Play in a process that already played its title (LaunchCoordinator:
    /// `launch=refused session=spent`): only after a restart that failed.
    private static func sessionFull(_ line: String) -> Bool {
        line.contains("launch=refused session=spent")
    }
}
