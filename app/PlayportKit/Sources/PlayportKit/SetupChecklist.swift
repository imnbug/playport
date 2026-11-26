// SPDX-License-Identifier: GPL-3.0-or-later
// First run (Setup.dc.html): what a game needs from this phone, as four
// steps: the pairing JIT uses (on iOS 27 made on the phone, decision 0033;
// on iOS 26 a file chosen from Files), LocalDevVPN's tunnel, the Increased
// Memory Limit entitlement in the signature (a signer chose it, so a player
// may only be able to put it off with "Not now"; docs/DISTRIBUTION.md
// section 6), and Accounts (optional: Steam, GOG or Epic Games signed in, or "Not now"; the step's
// case is still `steam`, as its saved "Not now" and the driver's names are). The app shows them once, on a first
// run, which cannot be left until every step is settled (`complete`), and in
// Settings › Setup check; the same facts are checked by themselves before
// every launch (`beforeLaunch`), which names the fix when one fails. A
// controller is no step: a launch only notes its absence (`notes`).
//
// The app reads the facts (UI/SetupView.swift); this is what they mean.

import Foundation

public enum SetupStep: String, CaseIterable, Sendable {
    case pairing, vpn, memory, steam
}

/// What the app reads from the phone for the checks.
public struct SetupFacts: Equatable, Sendable {
    /// The controller connected, by name; nil for none.
    public var controller: String?
    /// A pairing is stored (the Keychain).
    public var pairing: Bool
    /// The pairing is made on this phone (iOS 27); else it is a file from Files.
    public var pairsOnPhone: Bool
    /// LocalDevVPN's tunnel is up; nil before the first read.
    public var tunnelUp: Bool?
    /// Paired with Steam; nil while the stored session is still being read.
    public var steamSignedIn: Bool?
    /// The player chose "Not now" on the Accounts step.
    public var steamSkipped: Bool
    /// Signed in to GOG (decision 0058); nil while the stored session is still being read.
    public var gogSignedIn: Bool? = false
    /// Signed in to Epic Games (decision 0058); nil while the stored session is still being read.
    public var epicSignedIn: Bool? = false
    /// A store is signed in (Steam, GOG or Epic); nil while one is still being read and none is.
    public var accountSignedIn: Bool? {
        let all = [steamSignedIn, gogSignedIn, epicSignedIn]
        if all.contains(true) { return true }
        return all.contains(nil) ? nil : false
    }
    /// The stores signed in, by name, in the order Settings › Accounts lists them.
    public var signedInStores: [String] {
        [steamSignedIn == true ? "Steam" : nil, gogSignedIn == true ? "GOG" : nil, epicSignedIn == true ? "Epic Games" : nil].compactMap { $0 }
    }
    /// The signature carries Increased Memory Limit; nil when it cannot be read.
    public var memoryEntitled: Bool?
    /// The player chose "Not now" on the Memory step.
    public var memorySkipped: Bool
    /// Where JIT comes from (JitMethod): only the built-in helper needs the pairing,
    /// and only it and StikDebug need LocalDevVPN.
    public var jit: JitMethod

    public init(controller: String? = nil, pairing: Bool = false, pairsOnPhone: Bool = true,
                tunnelUp: Bool? = nil, steamSignedIn: Bool? = false, steamSkipped: Bool = false,
                memoryEntitled: Bool? = nil, memorySkipped: Bool = false, jit: JitMethod = .builtIn) {
        self.controller = controller
        self.pairing = pairing
        self.pairsOnPhone = pairsOnPhone
        self.tunnelUp = tunnelUp
        self.steamSignedIn = steamSignedIn
        self.steamSkipped = steamSkipped
        self.memoryEntitled = memoryEntitled
        self.memorySkipped = memorySkipped
        self.jit = jit
    }

    /// The pairing step is settled: made, or not needed by the JIT method.
    public var jitReady: Bool { pairing || !jit.usesPairing }
    /// The LocalDevVPN step is settled: connected, or not needed by the JIT method.
    public var tunnelReady: Bool { tunnelUp == true || !jit.usesTunnel }
}

/// One step's card: done or not, its text, and what A does on it (nil: nothing to do).
public struct SetupItem: Equatable, Sendable {
    public let step: SetupStep
    public let done: Bool
    public let title: String
    public let detail: String
    public let action: String?
}

public enum SetupChecklist {
    public static func item(_ step: SetupStep, _ f: SetupFacts) -> SetupItem {
        switch step {
        case .pairing:
            if !f.jit.usesPairing {
                return SetupItem(step: step, done: true, title: "JIT 来源：\(f.jit.label)",
                                 detail: f.jit == .stikDebug
                                     ? "点击「开始游戏」会自动打开 StikDebug 启用 JIT 并返回，请保持该应用已安装。"
                                     : "点击「开始游戏」后会等待其他应用（如 LiveContainer 的「使用 JIT 启动」）配合 universal.js 脚本启用 JIT。",
                                 action: nil)
            }
            if f.pairsOnPhone {
                return SetupItem(step: step, done: f.pairing, title: "设备配对",
                                 detail: f.pairing ? "此 iPhone 已完成本机配对，游戏可全速运行。"
                                     : "运行游戏需要启用 JIT，设备配对可让 Playport 自动开启 JIT。直接在此 iPhone 上生成，需在 iOS 提示时予以批准。",
                                 action: f.pairing ? "重新配对" : "配对此 iPhone")
            }
            return SetupItem(step: step, done: f.pairing, title: "配对文件",
                             detail: f.pairing ? "已导入配对文件，游戏可全速运行。"
                                 : "运行游戏需要启用 JIT，配对文件可让 Playport 自动开启 JIT。只需在电脑上生成一次，然后从「文件」中选择导入。",
                             action: f.pairing ? "更换文件" : "选择文件")
        case .vpn:
            if !f.jit.usesTunnel {
                return SetupItem(step: step, done: true, title: "LocalDevVPN",
                                 detail: "当 JIT 由其他应用提供时，Playport 无需使用 LocalDevVPN。", action: nil)
            }
            let up = f.tunnelUp == true
            return SetupItem(step: step, done: up, title: "LocalDevVPN",
                             detail: up ? "已连接。游玩期间请保持开启。"
                                 : f.tunnelUp == nil ? "正在检查…" : "请安装并开启 LocalDevVPN，游玩期间请保持开启。",
                             action: up ? nil : "开启")
        case .memory:
            let on = f.memoryEntitled == true
            let detail: String
            if on {
                detail = "「增加内存限制」已开启：游戏可使用此 iPhone 提供的全部可用内存。"
            } else if f.memorySkipped {
                detail = "暂不设置。小型游戏可正常运行，大型游戏需要开启「增加内存限制」。"
            } else if f.memoryEntitled == nil {
                detail = "Playport 无法读取自身签名信息。大型游戏需要开启「增加内存限制」。"
            } else {
                detail = "当前安装的签名未包含「增加内存限制」权限，大型游戏将无法启动。"
            }
            return SetupItem(step: step, done: on || f.memorySkipped, title: "内存", detail: detail,
                             action: on ? nil : "查看解决方法")
        case .steam:
            let done = f.accountSignedIn == true
            let stores = f.signedInStores
            let named = stores.count > 1 ? stores.dropLast().joined(separator: "、") + " 和 " + stores.last! : stores.first ?? ""
            return SetupItem(step: step, done: done || f.steamSkipped, title: "账号",
                             detail: done ? "已登录 \(named)：可访问你的游戏库，以及 Steam 云存档与成就。"
                                 : f.steamSkipped ? "暂不登录。你随时可在「设置 › 账号」中登录 Steam、GOG 或 Epic Games，或从「文件」导入游戏。"
                                 : "可选步骤。登录 Steam、GOG 或 Epic Games 以获取你的游戏库，或直接从「文件」添加游戏。",
                             action: done ? nil : "登录")
        }
    }

    public static func items(_ f: SetupFacts) -> [SetupItem] { SetupStep.allCases.map { item($0, f) } }

    /// Where the ring starts: the first step not done, else the first.
    public static func firstTodo(_ f: SetupFacts) -> SetupStep {
        items(f).first { !$0.done }?.step ?? .pairing
    }

    /// Every step settled: the pairing and LocalDevVPN done, Increased Memory
    /// Limit on or put off, Steam signed in or put off ("Not now"). A first
    /// run's checklist cannot be left before this.
    public static func complete(_ f: SetupFacts) -> Bool {
        f.jitReady && f.tunnelReady && (f.memoryEntitled == true || f.memorySkipped)
            && (f.accountSignedIn == true || f.steamSkipped)
    }

    /// Later visits can always leave; a first run must settle every step first.
    public static func canLeave(_ f: SetupFacts, firstRun: Bool) -> Bool {
        !firstRun || complete(f)
    }

    /// Whether a step offers "Not now": on a first run, the Memory step while the
    /// entitlement is not on, the Steam step while signed out, and neither once put off.
    public static func offersNotNow(_ step: SetupStep, _ f: SetupFacts, firstRun: Bool) -> Bool {
        guard firstRun else { return false }
        switch step {
        case .memory: return f.memoryEntitled != true && !f.memorySkipped
        case .steam: return f.accountSignedIn != true && !f.steamSkipped
        case .pairing, .vpn: return false
        }
    }

    /// Steps done, for Settings' summary ("2 of 4 done").
    public static func doneCount(_ f: SetupFacts) -> Int { items(f).filter(\.done).count }

    /// Start on an unpaired phone, and resume an unfinished first run even if
    /// pairing was completed before the app closed. Already-paired phones that
    /// never started this flow keep their existing setup.
    public static func showsAtStart(left: Bool, pairing: Bool, started: Bool = false) -> Bool {
        !left && (started || !pairing)
    }

    /// What the check before a launch finds.
    public enum LaunchCheck: Equatable, Sendable {
        /// Everything a game needs is there.
        case go
        /// Playport fixes it itself: pairs this iPhone (iOS 27) or turns
        /// LocalDevVPN on, then goes on with the Play (JitSetup).
        case fixesItself(SetupStep)
        /// The player has to act first: the checklist on that step, with the fix.
        case needs(SetupStep, String)
    }

    /// The check a Play runs before JIT: the pairing, then LocalDevVPN. A
    /// controller and Steam never stop a launch; `notes` names them. JIT from
    /// another app (StikDebug, LiveContainer) is that app's to set up: the
    /// launch goes on and waits for it.
    public static func beforeLaunch(_ f: SetupFacts) -> LaunchCheck {
        guard f.jit.usesPairing else { return .go }
        if !f.pairing {
            return f.pairsOnPhone ? .fixesItself(.pairing)
                : .needs(.pairing, "Playport 需要配对文件才能运行游戏。请在「配对文件」步骤中从「文件」选择导入。")
        }
        if f.tunnelUp != true { return .fixesItself(.vpn) }
        return .go
    }

    /// The launch screen drops it once a controller connects.
    public static let noController = "未连接手柄。现在连接手柄即可使用手柄游玩。"

    /// What does not stop a launch but is worth saying on its launch screen.
    public static func notes(_ f: SetupFacts, steamGame: Bool) -> [String] {
        var n: [String] = []
        if f.controller == nil { n.append(noController) }
        if steamGame, f.steamSignedIn == false { n.append("未登录 Steam：云存档与成就将在登录后同步。") }
        return n
    }

    /// The check as one log line (`setup: before play …`).
    public static func summary(_ f: SetupFacts) -> String {
        "controller=\(f.controller ?? "none") pairing=\(f.pairing ? (f.pairsOnPhone ? "on-phone" : "file") : "missing")"
            + " vpn=\(f.tunnelUp.map { $0 ? "up" : "down" } ?? "unknown")"
            + " memory=\(f.memoryEntitled.map { $0 ? "on" : "off" } ?? "unknown")"
            + (f.memorySkipped ? " (not now)" : "")
            + " steam=\(f.steamSignedIn.map { $0 ? "signed-in" : "signed-out" } ?? "unknown")"
            + (f.steamSkipped ? " (not now)" : "")
            + (f.jit == .builtIn ? "" : " jit=\(f.jit.rawValue)")
    }
}
