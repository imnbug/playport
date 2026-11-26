// SPDX-License-Identifier: GPL-3.0-or-later
// A game's page (docs/design/2026-09-28-gamepad-ui/Game.dc.html,
// GameInstall.dc.html), opened from the Library or Home over the grid: the
// hero art filling the screen behind it (drawn by the shell, PageArt), the name, the developer and controller
// support, then the buttons, all on the focus ring:
//
// - installed: Play (A), the achievements count, Options (X), Update when
//   Steam has a newer build on the install's branch; a running update or
//   repair takes Play's place with its progress, Pause and Cancel;
// - not installed: Install with the size (Resume or Discard a stopped
//   download), and Version (X) when Steam lists betas; a Battle.net product
//   (PLA-519) Install with its download size and Region (X), the store
//   region picker, its Install refused up front when the space it needs is
//   not free.
//
// At the right a card of facts: last played, cloud saves and the size on the
// phone, or the download size, the version and the achievements. Under the
// buttons one or two lines say what stands in the way of a Play (another game
// ran in this process, the memory limit, a download that pauses) and whether a
// controller is connected; an installed Battle.net copy's ban-risk notice
// (PLA-514), which its first Play asks the player to accept.
//
// Game options (GameOptions.dc.html) is a panel over the dimmed page: the
// game's resolution, frame rate limit and Direct3D, each "Default · X" until
// changed and marked when changed (PlayportKit OptionValue; LaunchSettings
// inherits game, then Settings, then 720p, 60 fps and DXMT), launch arguments
// on the controller keyboard; then the version, cloud saves (and the
// Cloud save conflict screen when they conflict), check game files (and Repair), achievements (a list over the
// panel), report a problem (a share sheet with a zip of the logs) and uninstall. Y puts
// the ringed setting back to its default. A dev build adds a Developer
// section: FEX's memory ordering, block size and x87 precision over the game's
// profile (FEXProfile), which steam_api the game loads, and the build facts.
//
// Play is refused, with the reason, once this process has run a title (one
// runtime per process). A release build words failures without internals
// (decision 0009). A dev build's `open:ID#SECTION` opens the options at a
// section (graphics, game, files, developer, ordering, steam).

import BattleNetClientKit
import GameController
import HostIOKit
import GOGClientKit
import EpicClientKit
import PlayportKit
import SteamClientKit
import SwiftUI
import UIKit
#if !PLAYPORT_RELEASE
import XboxClientKit  // the dev app's Xbox copies (decision 0181); release has no such package
#endif

/// What X does on the game page now, for the shell's footer (AppShell.gamePageHints).
@MainActor
final class GamePageState: ObservableObject {
    static let shared = GamePageState()

    struct Action {
        let label: String
        let action: () -> Void
    }

    @Published var x: Action?
}

struct GameDetailView: View {
    let ref: GameRef
    @EnvironmentObject private var steam: SteamAccountModel

    var body: some View { GameDetailPage(ref: ref, installs: steam.installs) }
}

private struct GameDetailPage: View {
    let ref: GameRef
    @ObservedObject var installs: Downloads
    @EnvironmentObject private var model: SteamAccountModel
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var launch = TitleLaunch.shared
    @ObservedObject private var launchSettings = LaunchSettingsStore.shared
    @ObservedObject private var navigation = AppNavigation.shared
    @ObservedObject private var focus = PadFocus.shared
    @ObservedObject private var gog = GOGAccount.shared
    @ObservedObject private var epic = EpicAccount.shared
    @ObservedObject private var bnet = BattleNetStore.shared
    @ObservedObject private var bnetInstalled = BattleNetInstalled.shared
    #if !PLAYPORT_RELEASE
    @ObservedObject private var xbox = XboxInstalls.shared
    @ObservedObject private var xboxGames = XboxGames.shared
    @ObservedObject private var xboxAddOns = XboxGameAddOns.shared
    @ObservedObject private var xboxUpdates = XboxUpdates.shared
    @ObservedObject private var xboxLapses = XboxLapses.shared
    #endif
    /// The page's width, for the narrow layout (page()).
    @State private var pageWidth: CGFloat = 0
    @State private var playError: String?
    @State private var controllers = GCController.controllers().count
    @State private var stageOnDisk = false
    /// The version picker's choice; nil until the player picks one.
    @State private var pickedBranch: String?
    /// Which steam_api the game's folder holds now (SteamAPISwap), read off the main thread.
    @State private var steamAPIState: SteamAPISwap.State?
    /// Its executables wrapped in Steam's DRM (SteamStub), and whether it is off them.
    @State private var steamStubs: [SteamStub.Site] = []

    /// The game in C:\Games, if it is there now.
    private var installed: InstalledTitle? {
        switch ref {
        case let .title(id): library.title(id)
        case let .steam(app): library.catalog.titles.first { $0.appID == app }
        case let .store(key): library.catalog.titles.first { $0.key == key }
        }
    }

    private var appID: UInt32? {
        switch ref {
        case let .title(id): installed?.appID ?? Self.appID(fromTitleID: id)
        case let .steam(app): app
        case let .store(key): key.steamAppID
        }
    }

    /// The game's store identity (decision 0057): what its download and art key on.
    private var key: StoreGameKey? {
        if let installed { return installed.key }
        switch ref {
        case let .title(id): return StoreGameKey(titleID: id)
        case let .steam(app): return .steam(app)
        case let .store(key): return key
        }
    }

    /// `app-367520` names Steam app 367520 (InstalledTitle.id), so an
    /// uninstalled title's page still finds its Steam game.
    private static func appID(fromTitleID id: String) -> UInt32? {
        id.hasPrefix("app-") ? UInt32(id.dropFirst(4)) : nil
    }

    /// The paired account's copy of the game, if it owns it.
    private var game: SteamGame? { appID.flatMap { app in model.games.first { $0.id == app } } }

    private var job: Downloads.Job? { key.flatMap { installs.jobs[$0] } }

    /// The Steam branches this game can be downloaded from, public first.
    private var branches: [Branch] { game?.info.depots.installableBranches ?? [] }

    /// The cohort's build, when one of the branches carries it (The Witcher 3's
    /// D3D11 `classic`): the picker's preset, not marked.
    private var cohortBranch: String? {
        guard let app = appID, let build = LibraryModel.cohort.titles.first(where: { $0.appID == app })?.buildID else { return nil }
        return branches.first { $0.buildID == build }?.name
    }

    /// The picker's choice, else the install's branch, else the cohort's, else public.
    private var selectedBranch: String {
        pickedBranch ?? installed?.branch ?? (installed == nil ? cohortBranch : nil) ?? Branch.publicName
    }

    private var name: String { installed?.name ?? game?.info.name ?? gogGame?.title ?? epicGame?.title ?? bnetProduct?.name ?? xboxTitle ?? "" }

    /// The GOG listing of this game, when GOG is signed in and owns it.
    private var gogGame: GOGGame? { key.flatMap { $0.store == .gog ? gog.game($0.id) : nil } }

    private var canDownloadGOG: Bool { gog.state == .signedIn && !installs.suspended }

    /// The Epic listing of this game, when Epic is signed in and owns it.
    private var epicGame: EpicGame? { key.flatMap { $0.store == .epic ? epic.game($0.id) : nil } }

    private var canDownloadEpic: Bool { epic.state == .signedIn && !installs.suspended }

    /// A Battle.net product not installed: the store offers it (no sign-in).
    private var bnetProduct: BattleNetProduct? { installed == nil ? key.flatMap { bnet.offered($0) } : nil }

    /// An installed Battle.net product: its region and language change on the page (PLA-520).
    private var installedBnet: BattleNetProduct? {
        installed.flatMap { $0.store == .battlenet && $0.source == .installed ? BattleNet.product($0.key) : nil }
    }

    #if !PLAYPORT_RELEASE
    /// The Xbox account's copy of this game, when Xbox is signed in and lists it (dev only).
    private var xboxCopy: XboxLibraryCopy? { key.flatMap { $0.store == .xbox ? xboxGames.game($0.id) : nil } }
    private var xboxTitle: String? { xboxCopy?.title }
    #else
    private var xboxTitle: String? { nil }
    #endif

    private var stats: UserStatsSnapshot? { appID.flatMap { model.userStats[$0]?.steam } }

    var body: some View {
        let t = installed, g = game
        Group {
            if t == nil, g == nil, gogGame == nil, epicGame == nil, bnetProduct == nil, xboxTitle == nil {
                VStack(spacing: 8) {
                    Text("未安装").font(PP.display(28)).foregroundStyle(PP.text)
                    #if PLAYPORT_RELEASE
                    Text("此游戏已不在 Playport 中。").foregroundStyle(PP.muted)
                    #else
                    Text("此游戏文件夹已不在 C:\\Games 中。").foregroundStyle(PP.muted)
                    #endif
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content(t, g)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focus.reset(start: navigation.focusStart ?? primaryID) }
        .onDisappear { GamePageState.shared.x = nil }
    }

    // MARK: page

    private func content(_ t: InstalledTitle?, _ g: SteamGame?) -> some View {
        let panel = navigation.gamePanels.last
        return ZStack(alignment: .topLeading) {
            page(t, g)
                // Under a panel the page's controls leave the ring.
                .transformPreference(PadItemsKey.self) { if panel != nil { $0 = [:] } }
            if panel == .controller, let t {
                // The Controller page covers the whole page (ControllerMapping.dc.html).
                ControllerMapView(target: .game(t.id), context: name)
                    .transition(.move(edge: .trailing))
            } else if let panel {
                Color(hex: 0x05070A).opacity(0.72).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { _ = navigation.back() }
                HStack(spacing: 0) {
                    if panel == .gyro, let t {
                        // Gyro aim's test area at the left, over the page's dimmed title (GyroAim.dc.html).
                        GyroTestArea(target: .game(t.id))
                            .frame(maxWidth: 330)
                            .padding(.leading, 24).padding(.trailing, 20).padding(.top, 70)
                            .padding(.bottom, AppShell.footerBottom + 36 + 12)
                    } else {
                        // The note sits low at the left, just above the footer the shell
                        // draws there (36 pt), clear of the page's dimmed title and
                        // subtitle (GameOptions.dc.html puts it under the title).
                        VStack(alignment: .leading) {
                            Spacer()
                            if panel == .options {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(PP.accent).frame(width: 7, height: 7)
                                    Text("已针对此游戏单独修改，其余项跟随全局「设置」。")
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 13)).foregroundStyle(PP.soft)
                                .padding(.bottom, AppShell.footerBottom + 36 + 12)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    Spacer(minLength: 0)
                    Group {
                        switch panel {
                        case .options: if let t { optionsPanel(t, g) }
                        case .achievements: achievementsPanel
                        case .gyro: if let t { GyroAimPanel(titleID: t.id, context: name) }
                        case .controller: EmptyView()
                        }
                    }
                    .frame(width: 410)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(PP.surface.ignoresSafeArea(edges: [.top, .trailing, .bottom]))
                    .overlay(alignment: .leading) { Rectangle().fill(PP.line).frame(width: 1).ignoresSafeArea(edges: [.top, .bottom]) }
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.15), value: panel)
        .task(id: job?.phase) { stageOnDisk = appID.map(installs.hasStageOnDisk) ?? false }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            controllers = GCController.controllers().count
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            controllers = GCController.controllers().count
        }
        .onChange(of: navigation.gamePanels) { old, new in panelsChanged(from: old, to: new) }
        .onChange(of: xKey(t), initial: true) { _, _ in updateX(t) }
        .task(id: t?.id) {
            if let t, t.store == .gog, t.source == .installed { await gog.checkUpdate(t.key.id) }
            if let t, t.store == .epic, t.source == .installed { await epic.checkUpdate(t.key.id) }
            #if !PLAYPORT_RELEASE
            if let t, t.store == .xbox, t.source == .installed { await xboxUpdates.check(t.key.id) }
            #endif
        }
        // A Battle.net product's sizes in its region and locale (again after the region picker).
        .task(id: bnetProduct.map { "\($0.code)/\(bnet.region($0).rawValue)" }) {
            if let p = bnetProduct { await bnet.loadSizes(p) }
        }
        // An installed Battle.net product's region and language, again after a language download.
        .task(id: installedBnet.map { "\($0.code)/\(job == nil)" }) {
            if let p = installedBnet { bnetInstalled.load(p) }
        }
        .task(id: navigation.pageSection) {
            // A dev build's `open:ID#SECTION`: the options, at that section.
            #if !PLAYPORT_RELEASE
            guard UIDriver.allowsDeferredNavigation else { return }
            #endif
            guard navigation.onGamePage, navigation.pageSection != nil, t != nil else { return }
            if let page = ["gyro": AppNavigation.GamePanel.gyro, "controller": .controller][navigation.pageSection ?? ""] {
                // Its Controls › Gyro aim or Controller page, over Game options.
                navigation.gamePanels = [.options, page]
                navigation.pageSection = nil
                return
            }
            if navigation.pageSection == "layout", let t {
                // Its Controls › Edit on-screen layout: the layout editor over the game's art.
                if navigation.gamePanels != [.options] { navigation.gamePanels = [.options] }
                navigation.pageSection = nil
                LayoutEditorSession.shared.openOverArt(titleID: t.id, title: name)
                return
            }
            if navigation.gamePanels != [.options] { navigation.gamePanels = [.options] }
        }
        // Again once a restore signs in: a page opened while it ran fetched nothing.
        .task(id: "\(t?.appID.map(String.init) ?? "-") \(launch.running) \(signedIn)") {
            guard let t, let app = t.appID else { return }
            await model.loadGameProfile(app)
            // Not while the game runs: its launch suspends Steam in this process,
            // and the next start of the app syncs the played game.
            if !launch.running {
                await model.syncStats(app)
                await model.syncCloud(app)
            }
            let root = LibraryModel.paths.games.appendingPathComponent(t.installDir, isDirectory: true)
            (steamAPIState, steamStubs) = await Task.detached(priority: .utility) {
                (SteamAPISwap.state(in: root), SteamStub.sites(in: root))
            }.value
        }
        .alert("无法启动 \(name)", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("确定") {}
        } message: {
            Text(playError ?? "")
        }
    }

    /// The page's hero art: Steam's app, else the installed title, else the store's game
    /// (GOG, Epic, Battle.net, Xbox). One step at a time: the `??` chain of all of them
    /// was too much for the type checker at -Onone.
    private func pageArt(_ t: InstalledTitle?, _ g: SteamGame?) -> PageArt? {
        if let g { return PageArt(appID: g.id, name: name, info: g.info) }
        if let t { return PageArt(appID: t.appID, name: t.name, info: nil, titleID: t.id, storeKey: t.key) }
        if let gg = gogGame { return PageArt(appID: nil, name: gg.title, info: nil, storeKey: StoreGameKey(store: .gog, id: gg.id)) }
        if let eg = epicGame { return PageArt(appID: nil, name: eg.title, info: nil, storeKey: StoreGameKey(store: .epic, id: eg.id)) }
        if let p = bnetProduct { return PageArt(appID: nil, name: p.name, info: nil, storeKey: BattleNet.key(p)) }
        if let title = xboxTitle, let key { return PageArt(appID: nil, name: title, info: nil, storeKey: key) }
        return nil
    }

    /// The page; under a panel only its art and name show (GameOptions.dc.html).
    private func page(_ t: InstalledTitle?, _ g: SteamGame?) -> some View {
        let under = !navigation.gamePanels.isEmpty
        // A narrow page (an iPhone Duo's cover panel, UI/PanelFit.swift) gives the buttons
        // the width the facts beside them would take: a slimmer facts column, closer.
        let narrow = pageWidth > 0 && pageWidth < 760
        return ZStack(alignment: .topLeading) {
            // The hero art fills the screen behind the page and its footer: the shell draws
            // it (PageArt), as the launch screen does, so on Play it does not change.
            Color.clear
                .preference(key: PageArtKey.self, value: pageArt(t, g))

            HStack(alignment: .top, spacing: narrow ? 16 : 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(name).font(PP.display(48)).foregroundStyle(PP.text)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Group {
                        if let line = subtitle(t, g) {
                            Text(line).font(.system(size: 13)).foregroundStyle(PP.soft)
                        }
                        // One row of buttons that wraps rather than squeezing a label to a letter.
                        PageButtonRows {
                            if let t { installedButtons(t, g) } else if let g { installButtons(g) } else if let gg = gogGame { gogInstallButtons(gg) } else if let eg = epicGame { epicInstallButtons(eg) } else if let p = bnetProduct { bnetInstallButtons(p) } else if xboxTitle != nil { xboxInstallButtons }
                        }
                        .padding(.top, 14)
                        notes(t, g)
                            .font(.system(size: 13)).foregroundStyle(PP.muted)
                            .lineSpacing(2)
                            .padding(.top, 12)
                    }
                    .opacity(under ? 0 : 1)
                }
                .frame(maxWidth: 500, alignment: .leading)
                Spacer(minLength: 0)
                facts(t, g)
                    .frame(width: narrow ? 220 : 270)
                    .padding(.top, 94)
                    .opacity(under ? 0 : 1)
            }
            .padding(.top, 76)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
    }

    private func subtitle(_ t: InstalledTitle?, _ g: SteamGame?) -> String? {
        let developer = t?.developer ?? g?.info.developer
        let controller: String? = switch g?.info.controllerSupport {
        case "full": "完全支持手柄"
        case "partial": "部分支持手柄"
        default: nil
        }
        let parts = [developer, controller].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The control the ring starts on.
    private var primaryID: String {
        if installed != nil { return job == nil ? "game:play" : "game:job" }
        return job == nil ? "game:install" : "game:job"
    }

    // MARK: buttons

    @ViewBuilder
    private func installedButtons(_ t: InstalledTitle, _ g: SteamGame?) -> some View {
        if let job {
            jobControls(job)
        } else if launch.spent {
            SecondaryButton(id: "game:close", systemImage: "xmark.circle", title: "关闭 Playport", hint: "关闭") { exit(0) }
        } else {
            PrimaryButton(id: "game:play", title: library.preparing[t.id] ?? "开始游戏",
                          enabled: canPlay(t) && library.preparing[t.id] == nil, hint: "开始游戏") { start(t) }
            #if !PLAYPORT_RELEASE
            // An Xbox copy whose licence lapsed (PLA-505): ask Microsoft again, or uninstall it before its date.
            if t.store == .xbox, xboxLapses.state(t.key).isLapsed {
                SecondaryButton(id: "game:xboxLicence", systemImage: "arrow.clockwise", title: "检查许可",
                                enabled: !launch.running, hint: "检查许可") { Task { await xboxLapses.check(t) } }
                SecondaryButton(id: "game:xboxUninstall", systemImage: "trash", title: "立即卸载",
                                enabled: !launch.running && !library.removing.contains(t.id), hint: "卸载") { xboxLapses.askRemove(t) }
            }
            #endif
        }
        if let s = stats, !s.schema.achievements.isEmpty {
            SecondaryButton(id: "game:achievements", systemImage: "trophy", title: "\(s.unlockedCount) / \(s.schema.achievements.count)",
                            hint: "成就") { navigation.gamePanels = [.achievements] }
        }
        SecondaryButton(id: "game:options", systemImage: "slider.horizontal.3", title: "选项", glyph: .x, hint: "游戏选项") {
            navigation.gamePanels = [.options]
        }
        // Updates (PLA-521): every Play checks first; Check for update asks by hand, and Update
        // queues it. Region and Language are rows of the facts card (`bnetLinks`): a phone in
        // landscape has room for neither another button nor another row of them.
        if let p = installedBnet, job == nil {
            let update = bnetInstalled.updates[p]
            if case .available? = update {
                SecondaryButton(id: "game:update", systemImage: "arrow.down.circle", title: "更新",
                                enabled: !launch.running && !installs.suspended,
                                hint: "更新") { bnetInstalled.update(p, downloads: installs) }
            } else {
                SecondaryButton(id: "game:check-update", systemImage: "arrow.triangle.2.circlepath", title: "检查更新",
                                enabled: !launch.running && update != .checking,
                                hint: "检查更新") { Task { await bnetInstalled.checkUpdate(p) } }
            }
        }
        #if !PLAYPORT_RELEASE
        if job == nil, t.store == .xbox, t.source == .installed {
            SecondaryButton(id: "game:addons", systemImage: "puzzlepiece.extension", title: xboxAddOns.title(t.key.id),
                            enabled: !launch.running, hint: "附加内容") { xboxAddOns.open(t) }
        }
        #endif
        if job == nil, t.store == .gog, t.source == .installed, let newest = gog.newest[t.key.id], newest != t.storeVersion {
            SecondaryButton(id: "game:update", systemImage: "arrow.down.circle", title: "更新", enabled: canDownloadGOG && !launch.running,
                            hint: "更新") { gog.install(t.key.id, name: t.name, kind: .update) }
        }
        if job == nil, t.store == .epic, t.source == .installed, let newest = epic.newest[t.key.id], newest != t.storeVersion {
            SecondaryButton(id: "game:update", systemImage: "arrow.down.circle", title: "更新", enabled: canDownloadEpic && !launch.running,
                            hint: "更新") { epic.install(t.key.id, name: t.name, kind: .update) }
        }
        #if !PLAYPORT_RELEASE
        if job == nil, t.store == .xbox, t.source == .installed, let newest = xboxUpdates.newest[t.key.id], newest != t.storeVersion {
            SecondaryButton(id: "game:update", systemImage: "arrow.down.circle", title: "更新",
                            enabled: XboxAccount.shared.state == .signedIn && !installs.suspended && !launch.running,
                            hint: "更新") { xboxUpdates.update(t.key.id, name: t.name) }
        }
        if job == nil, t.store == .xbox, t.source == .installed, xboxUpdates.newest[t.key.id] == nil {
            let id = t.key.id, busy = xboxUpdates.checking.contains(id)
            let current: String? = if case .current(let latest)? = xboxUpdates.answers[id] { latest } else { nil }
            SecondaryButton(id: "game:xboxCheckUpdate", systemImage: "arrow.clockwise",
                            title: busy ? "正在检查…" : current.map { "已是最新（\($0)）· 重新检查" } ?? "检查更新",
                            enabled: XboxAccount.shared.state == .signedIn && !busy && !launch.running,
                            hint: "检查") { Task { await xboxUpdates.check(id, force: true) } }
        }
        #endif
        if job == nil, let g, SteamInstallStatus.updateAvailable(t, g.info) {
            SecondaryButton(id: "game:update", systemImage: "arrow.down.circle", title: "更新", enabled: canDownload && !launch.running,
                            hint: "更新") { installs.install(g.id, name: g.info.name) }
        }
    }

    @ViewBuilder
    private func installButtons(_ g: SteamGame) -> some View {
        if let job {
            jobControls(job)
        } else if stageOnDisk {
            PrimaryButton(id: "game:install", title: "继续下载", enabled: canDownload, hint: "继续") {
                installs.install(g.id, name: g.info.name)
            }
            SecondaryButton(id: "game:discard", systemImage: "trash", title: "放弃下载", hint: "放弃") {
                installs.discard(g.id)
                stageOnDisk = false
            }
        } else {
            let size = g.info.installSize(branch: selectedBranch).map { " · " + ByteCount.format($0) } ?? ""
            PrimaryButton(id: "game:install", title: "安装" + size, enabled: canDownload, hint: "安装") {
                installs.install(g.id, name: g.info.name, branch: selectedBranch)
            }
            if branches.count > 1 {
                SecondaryButton(id: "game:version", systemImage: nil, title: "版本", glyph: .x, hint: "版本") { pickVersion(g) }
            }
        }
    }

    /// A GOG game not installed: Install, or its download's controls.
    @ViewBuilder
    private func gogInstallButtons(_ gg: GOGGame) -> some View {
        if let job {
            jobControls(job)
        } else {
            PrimaryButton(id: "game:install", title: gog.installer.hasStage(gg.id) ? "继续下载" : "安装",
                          enabled: canDownloadGOG, hint: "安装") { gog.install(gg.id, name: gg.title) }
        }
    }

    /// An Epic game not installed: Install (not offered for a game Playport refuses), or its download's controls.
    @ViewBuilder
    private func epicInstallButtons(_ eg: EpicGame) -> some View {
        if let job {
            jobControls(job)
        } else {
            PrimaryButton(id: "game:install", title: epic.installer.hasStage(eg.id) ? "继续下载" : "安装",
                          enabled: canDownloadEpic && epic.refusal(eg.id) == nil, hint: "安装") { epic.install(eg.id, name: eg.title) }
        }
    }

    /// A Battle.net product not installed: Install with its download size (refused up front when
    /// it does not fit) and Region, or its download's controls.
    @ViewBuilder
    private func bnetInstallButtons(_ p: BattleNetProduct) -> some View {
        if let job {
            jobControls(job)
        } else {
            let size = bnet.listing(p)?.sizes.map { " · " + ByteCount.format($0.download) } ?? ""
            PrimaryButton(id: "game:install", title: bnet.hasStage(p) ? "继续下载" : "安装" + size,
                          enabled: !installs.suspended && !bnet.sizing.contains(p), hint: "安装") { bnet.install(p) }
            SecondaryButton(id: "game:region", systemImage: nil, title: "地区 · \(bnet.region(p).rawValue)", glyph: .x,
                            hint: "商店地区") { bnet.pickRegion(p) }
        }
    }

    /// An Xbox copy not installed (dev only): Install with its download size, or its download's controls.
    @ViewBuilder
    private var xboxInstallButtons: some View {
        #if !PLAYPORT_RELEASE
        if let job {
            jobControls(job)
        } else if let copy = xboxCopy {
            PrimaryButton(id: "game:install", title: xbox.installer.hasStage(copy.id) ? "继续下载" : "安装",
                          enabled: xbox.canInstall(copy.id) && !installs.suspended, hint: "安装") { xbox.install(copy) }
        }
        #endif
    }

    /// A download, update or repair of this game: its progress, Pause or Resume, and Cancel.
    @ViewBuilder
    private func jobControls(_ job: Downloads.Job) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(job.status).font(.system(size: 15, weight: .semibold)).foregroundStyle(PP.text)
                Spacer(minLength: 8)
                if let d = job.detail { Text(d).font(.system(size: 12)).foregroundStyle(PP.muted).monospacedDigit() }
            }
            ProgressView(value: job.fraction ?? 0).tint(PP.progress)
        }
        .padding(.horizontal, 14)
        .frame(width: 230, height: 52)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 12))
        .padItem("game:job", hint: job.isRunning || job.phase == .queued ? "暂停" : "继续", cornerRadius: 12) {
            if job.isRunning || job.phase == .queued { installs.pause(job.key) } else if canDownload || job.key.store != .steam { installs.resume(job.key) }
        }
        SecondaryButton(id: "game:cancel", systemImage: "xmark", title: "取消", hint: job.kind == .repair ? "取消修复" : "取消下载") {
            installs.discard(job.key)
        }
    }

    private func canPlay(_ t: InstalledTitle) -> Bool {
        #if !PLAYPORT_RELEASE
        if xboxLapses.state(t.key).isLapsed { return false }  // its licence lapsed (dev Xbox, PLA-505)
        #endif
        return t.canPlay && !launch.spent && !launch.running && !library.verifying.contains(t.id)
            && !library.removing.contains(t.id) && job == nil
    }

    /// An uninstalled Xbox copy's download size, needed space, refusal or download state (dev only).
    @ViewBuilder
    private var xboxNote: some View {
        #if !PLAYPORT_RELEASE
        if let copy = xboxCopy {
            if let why = xbox.refused[copy.id] {
                Text(why).foregroundStyle(.orange)
            } else if let job {
                if case let .paused(reason?) = job.phase { Text(reason).foregroundStyle(.orange) }
                if job.isRunning { Text("下载期间请保持 Playport 开启：离开屏幕后下载会暂停。") }
            } else if let package = xbox.package(copy.id) {
                let parts = ["下载 \(ByteCount.format(package.downloadSize))", "需要 \(ByteCount.format(package.neededBytes))"]
                    + [library.freeBytes.map { "可用 \(ByteCount.format($0))" }].compactMap { $0 }
                Text(parts.joined(separator: " · ") + " · 下载期间请保持 Playport 开启")
            } else {
                Text("Microsoft 未提供此游戏可供 Playport 安装的 Windows 安装包。").foregroundStyle(.orange)
            }
        }
        #endif
    }

    private var xboxFacts: [(String, String, Color?)] {
        #if !PLAYPORT_RELEASE
        guard let copy = xboxCopy, let package = xbox.package(copy.id) else { return [] }
        return [("授权方式", copy.access == .owned ? "已拥有" : "PC Game Pass", nil),
                ("下载大小", ByteCount.format(package.downloadSize), nil), ("所需空间", ByteCount.format(package.neededBytes), nil)]
        #else
        return []
        #endif
    }

    private func start(_ t: InstalledTitle) {
        guard canPlay(t) else { return }
        Task {
            do {
                try await library.play(t.id)
            } catch {
                #if PLAYPORT_RELEASE
                LibraryModel.log("play \(t.id) refused: \(error)")
                playError = "Playport 无法准备启动此游戏。"
                #else
                playError = "\(error)"
                #endif
            }
        }
    }

    private var canDownload: Bool {
        guard case .signedIn = model.state else { return false }
        return !installs.suspended
    }

    /// Steam's public build or one of its betas (Steam's own "Betas" choice). For an installed
    /// game, another version downloads it over the one there.
    private func pickVersion(_ g: SteamGame) {
        let installedBranch = installed.map { $0.branch ?? Branch.publicName }
        PadModal.shared.picker(
            title: "版本", context: name,
            note: installedBranch == nil ? "点击「安装」将下载此处所选的版本。"
                : "选择其他版本将覆盖当前已安装的版本，你的游戏存档不会受影响。",
            options: branches.map { b in
                PadOption(id: b.name, label: BranchLabel.text(b),
                          detail: b.name == installedBranch ? "已安装" : g.info.installSize(branch: b.name).map(ByteCount.format))
            },
            selected: selectedBranch) { picked in
            pickedBranch = picked
            if let installedBranch, picked != installedBranch, canDownload, !launch.running, job == nil {
                installs.install(g.id, name: g.info.name, branch: picked)
            }
        }
    }

    // MARK: notes and facts

    @ViewBuilder
    private func notes(_ t: InstalledTitle?, _ g: SteamGame?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let p = installedBnet, let why = bnetInstalled.errors[p] { Text(why).foregroundStyle(.orange) }
            if let p = installedBnet, case let .unreachable(why)? = bnetInstalled.updates[p] {
                Text("无法检查更新：\(why)").foregroundStyle(.orange)
            }
            if let t {
                if launch.spent {
                    Text(JitProvider.inLiveContainer
                         ? "Playport 无法在当前会话中启动另一个游戏。请关闭应用，并从 LiveContainer 使用 JIT 重新启动以继续游玩。"
                         : "Playport 无法在当前会话中启动另一个游戏。请关闭应用，并从主屏幕重新打开以继续游玩。")
                } else if !t.canPlay {
                    Text("此文件夹中未找到 Windows 可执行文件。").foregroundStyle(.orange)
                } else if let job {
                    if case let .paused(reason?) = job.phase { Text(reason).foregroundStyle(.orange) }
                    // An update Playport queued by itself holds Play too: say how to play now.
                    Text(job.kind == .repair ? "修复完成后即可开始游戏，或点击「取消」直接游玩。"
                         : job.record.automatic ? "Playport 已自动将此更新加入队列。更新完成后即可开始游戏；也可点击「取消」直接游玩（之后将在 Steam 发布下一版本时再更新）。"
                         : "更新完成后即可开始游戏，或点击「取消」直接游玩。")
                } else {
                    #if !PLAYPORT_RELEASE
                    if let lapse = xboxLapses.notice(t.key) { Text(lapse).foregroundStyle(.orange) }
                    // Saves the Xbox cloud doesn't have yet (Dev/XboxCloudSaves.swift, PLA-500).
                    if t.store == .xbox, let saves = XboxCloudSaves.note(productID: t.key.id) {
                        Text(saves).foregroundStyle(.orange).accessibilityIdentifier("xbox-unsynced-saves")
                    }
                    #endif
                    MemoryWarning()
                    if installs.isBusy { Text("启动游戏会暂停当前下载，游戏结束重新打开 Playport 后将继续下载。") }
                    controllerLine(t)
                }
                // Its last Play was ended for memory (PlayportKit MemoryKill): said, never a reason not to play.
                if let kill = t.memoryKill {
                    Text(MemoryNote.killed(kill)).foregroundStyle(.orange).accessibilityIdentifier("memory-kill")
                }
                riskNotice(t)
            } else if let g {
                installNote(g)
            } else if let eg = epicGame, let why = epic.refusal(eg.id) {
                Text(why).foregroundStyle(.orange)
            } else if let p = bnetProduct {
                bnetNote(p)
            } else if xboxTitle != nil {
                xboxNote
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A Battle.net copy's ban-risk notice (PLA-514, decision 0175): its text stays on the page, before
    /// the first Play asks and after it was accepted.
    @ViewBuilder
    private func riskNotice(_ t: InstalledTitle) -> some View {
        if let p = BattleNet.product(t.key) {
            Text(BattleNetPlay.notice(p).text).foregroundStyle(.orange)
            if let at = t.riskNoticeAccepted {
                Text("你已于 \(at.formatted(date: .abbreviated, time: .omitted)) 确认接受此提示。")
            } else {
                Text("首次点击「开始游戏」前需要你确认接受此提示。")
            }
        }
    }

    @ViewBuilder
    private func controllerLine(_ t: InstalledTitle) -> some View {
        if Panel.isFoldable, launchSettings.settings(for: t.id).virtualPad == true {
            // The on-screen controller is a pad of its own (VirtualGamepad.swift).
            Text("此游戏已开启虚拟手柄。")
        } else if controllers == 0 {
            Text("未连接手柄。请现在连接手柄：部分游戏可能无法识别启动后才连接的手柄。")
                .foregroundStyle(.orange)
        } else {
            Text("手柄已连接。")
        }
    }

    @ViewBuilder
    private func installNote(_ g: SteamGame) -> some View {
        if installs.suspended {
            Text(InstallCopy.afterLaunch)
        } else if case let .offline(_, reason) = model.state {
            Text("无法连接 Steam（\(reason)）。恢复连接后将继续下载。")
        } else if model.state.account == nil || model.state == .expired {
            Text("请先登录 Steam 以下载游戏。")
        } else if let job {
            if case let .paused(reason?) = job.phase { Text(reason).foregroundStyle(.orange) }
            if job.isRunning { Text("下载期间请保持 Playport 开启：离开屏幕后下载会暂停。") }
        } else {
            let need = g.info.installSize(branch: selectedBranch).map { "需要 \(ByteCount.format($0))" }
            let free = library.freeBytes.map { "可用 \(ByteCount.format($0))" }
            let parts = [need, free].compactMap { $0 }
            if !parts.isEmpty { Text(parts.joined(separator: " · ") + " · 下载期间请保持 Playport 开启") }
        }
    }

    @ViewBuilder
    private func bnetNote(_ p: BattleNetProduct) -> some View {
        if installs.suspended {
            Text(InstallCopy.afterLaunch)
        } else if let job {
            if case let .paused(reason?) = job.phase { Text(reason).foregroundStyle(.orange) }
            if job.isRunning { Text("下载期间请保持 Playport 开启：离开屏幕后下载会暂停。") }
            Text("下载完成后即可开始游戏。")
        } else {
            if let why = bnet.refusals[p] ?? bnet.spaceRefusal(p) { Text(why).foregroundStyle(.orange) }
            if let why = bnet.sizeErrors[p] ?? bnet.error { Text(why).foregroundStyle(.orange) }
            if bnet.sizing.contains(p) {
                Text("正在向暴雪查询 \(BattleNetStore.label(bnet.region(p))) 地区的安装包大小…")
            } else {
                let need = bnet.needed(p).map { "需要 \(ByteCount.format($0))" }
                let free = library.freeBytes.map { "可用 \(ByteCount.format($0))" }
                let parts = [need, free].compactMap { $0 }
                if !parts.isEmpty { Text(parts.joined(separator: " · ") + " · 下载期间请保持 Playport 开启") }
            }
            Text("安装无需登录 Battle.net 账号。World of Warcraft 会在启动后提示你登录。")
        }
    }

    private func facts(_ t: InstalledTitle?, _ g: SteamGame?) -> some View {
        let source: LibrarySource = key?.store ?? (appID == nil ? .local : .steam)
        var links: [String: FactLink] = [:]
        var rows: [(String, String, Color?)] = [("商店", source.label, nil)]
        if let t {
            if t.badge != .ready { rows.append(("状态", t.badge.rawValue, .orange)) }
            rows.append(("上次游玩", t.lastPlayed.map { $0.formatted(.relative(presentation: .named)) } ?? "从未", nil))
            if let played = t.playSeconds { rows.append(("游玩时长", PlayTime.format(played), nil)) }
            if t.source == .installed, let b = t.branch, b != Branch.publicName {
                rows.append(("版本", BranchLabel.text(b, in: g?.info), nil))
            }
            if t.appID != nil { rows.append(("云存档", cloudStatus(t).0, cloudStatus(t).1)) }
            rows.append(("占用空间", t.sizeBytes.map(ByteCount.format) ?? "未知", nil))
            if let p = installedBnet {
                let now = bnetInstalled.current[p]
                rows.append(("地区", bnetInstalled.changingRegion.contains(p) ? "正在切换…" : now.map { BattleNetStore.label($0.region) } ?? "…", nil))
                rows.append(("语言", now.map { BattleNetInstalled.name($0.locale) ?? $0.locale } ?? "…", nil))
                links = bnetLinks(p, now)
                switch bnetInstalled.updates[p] {
                case nil: break
                case .checking?: rows.append(("更新", "正在检查…", nil))
                case let .current(v)?: rows.append(("更新", "已是最新 · \(v)", nil))
                // At the installed build: an install from before decision 0177 getting the x64 client.
                case let .available(from, to, bytes)?:
                    rows.append(("更新", (from == to ? "x64 客户端" : "\(from) → \(to)") + " · \(ByteCount.format(bytes))", .orange))
                case .unreachable?: rows.append(("更新", "无法检查", .orange))
                }
            }
        } else if let g {
            if let s = g.info.installSize(branch: selectedBranch) { rows.append(("下载大小", ByteCount.format(s), nil)) }
            if branches.count > 1 { rows.append(("版本", BranchLabel.text(selectedBranch, in: g.info), nil)) }
            if let s = stats, !s.schema.achievements.isEmpty {
                rows.append(("成就", "\(s.unlockedCount) / \(s.schema.achievements.count)", nil))
            }
        } else if let p = bnetProduct {
            let l = bnet.listing(p)
            if let s = l?.sizes { rows.append(("下载大小", ByteCount.format(s.download), nil)) }
            if let n = bnet.needed(p) { rows.append(("所需空间", ByteCount.format(n), nil)) }
            rows.append(("地区", BattleNetStore.label(bnet.region(p)), nil))
            rows.append(("语言", bnet.locale(p), nil))
            if let v = l?.version { rows.append(("版本", v, nil)) }
        } else if xboxTitle != nil {
            rows += xboxFacts
        }
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                factRow(rows[i], link: links[rows[i].0], last: i == rows.count - 1)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        .background(PP.surface, in: RoundedRectangle(cornerRadius: 14))
        .opacity(rows.isEmpty ? 0 : 1)
    }

    /// A fact that opens its picker: an installed Battle.net product's region and language.
    private struct FactLink {
        let id: String
        let hint: String
        let enabled: Bool
        let action: () -> Void
    }

    /// The facts card's Region and Language rows, which change them as the store page's Region
    /// button does: by their labels, the words a button beside Play had no room for (PLA-519).
    private func bnetLinks(_ p: BattleNetProduct, _ now: BattleNetInstalled.Choice?) -> [String: FactLink] {
        let idle = now != nil && job == nil && !launch.running
        return [
            "地区": FactLink(id: "game:region", hint: "商店地区", enabled: idle && !bnetInstalled.changingRegion.contains(p)) {
                bnetInstalled.pickRegion(p)
            },
            "语言": FactLink(id: "game:language", hint: "语言", enabled: idle && !installs.suspended) {
                bnetInstalled.pickLanguage(p, downloads: installs)
            },
        ]
    }

    @ViewBuilder
    private func factRow(_ row: (String, String, Color?), link: FactLink?, last: Bool) -> some View {
        let line = HStack(spacing: 12) {
            Text(row.0).foregroundStyle(PP.muted)
            Spacer(minLength: 8)
            Text(row.1).foregroundStyle(row.2 ?? PP.text).lineLimit(1).minimumScaleFactor(0.8)
            if let link {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(link.enabled ? PP.soft : PP.muted)
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(PP.raised).frame(height: 1) }
        }
        if let link {
            line.padItem(link.id, hint: link.hint, cornerRadius: 6) { if link.enabled { link.action() } }
        } else {
            line
        }
    }

    /// Steam Cloud for the facts card and the options' row.
    private func cloudStatus(_ t: InstalledTitle) -> (String, Color?) {
        guard SteamAccountModel.cloudOn else { return ("已在设置中关闭", nil) }
        guard launchSettings.settings(for: t.id).cloudSync ?? true else { return ("已关闭", nil) }
        guard let app = t.appID else { return ("未同步", nil) }
        if model.cloudSyncing.contains(app) { return ("正在同步…", nil) }
        if model.cloudErrors[app] != nil { return ("未同步", .orange) }
        guard let c = model.cloud[app] else { return ("尚未同步", nil) }
        if !c.conflicts.isEmpty { return ("\(c.conflicts.count) 个冲突待处理", .orange) }
        if !c.failed.isEmpty { return ("\(c.failed.count) 个未同步", .orange) }
        return ("已同步", PP.ok)
    }

    private var signedIn: Bool {
        if case .signedIn = model.state { true } else { false }
    }

    // MARK: X and the ring

    private func xKey(_ t: InstalledTitle?) -> String {
        if t != nil { return "options" }
        if t == nil, bnetProduct != nil, job == nil { return "region" }
        return game != nil && job == nil && !stageOnDisk && branches.count > 1 ? "version" : "none"
    }

    private func updateX(_ t: InstalledTitle?) {
        switch xKey(t) {
        case "options":
            GamePageState.shared.x = .init(label: "游戏选项") { navigation.gamePanels = [.options] }
        case "version":
            GamePageState.shared.x = .init(label: "版本") { if let g = game { pickVersion(g) } }
        case "region":
            GamePageState.shared.x = .init(label: "商店地区") { if let p = bnetProduct { bnet.pickRegion(p) } }
        default:
            GamePageState.shared.x = nil
        }
    }

    private func panelsChanged(from old: [AppNavigation.GamePanel], to new: [AppNavigation.GamePanel]) {
        switch new.last {
        case .options?:
            let section = navigation.pageSection.flatMap(Self.firstRow(ofSection:))
            focus.reset(start: section ?? (old.last == .achievements ? "opt:achievements" : old.last == .gyro ? "opt:gyro"
                                           : old.last == .controller ? ControllerMapView.gameRowID : "opt:aspect"))
        case .gyro?:
            focus.reset(start: "gyro:output")
        case .controller?:
            focus.reset(start: ControllerMapView.modeID)
        case .achievements?:
            focus.reset(start: "ach:0")
        case nil:
            focus.reset(start: old.last == .achievements ? "game:achievements" : "game:options")
        }
    }

    /// Where `open:ID#SECTION` rings the options.
    private static func firstRow(ofSection s: String) -> String? {
        #if !PLAYPORT_RELEASE
        return UIDriverGameSection(rawValue: s)?.row(firstOrdering: MemoryOrdering.Setting.allCases[0].rawValue)
        #else
        // Release has no driver (Dev/ is not in it), so nothing sets pageSection: this copy
        // is unreachable. It still names the dev enum's sections and rows exactly, so a
        // section added there is added here too (tools/tests/test_ui.py compares them).
        switch s {
        case "graphics": "opt:aspect"
        case "controls": "opt:layout"
        case "game": "opt:version"
        case "files": "opt:files"
        case "developer", "ordering": "opt:ordering-\(MemoryOrdering.Setting.allCases[0].rawValue)"
        case "steam": "opt:steamAPI"
        case "gyro", "controller", "layout": nil
        case "runtime": "opt:runtime"
        case "graphicsoptions": "opt:graphicsOptions"
        default: nil
        }
        #endif
    }

    // MARK: Game options

    private func optionsPanel(_ t: InstalledTitle, _ g: SteamGame?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("游戏选项").font(PP.display(22)).foregroundStyle(PP.text)
                .padding(.horizontal, 14).padding(.bottom, 2)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        graphicsRows(t)
                        GameControlsOptionRows(titleID: t.id, context: context)
                        gameRows(t, g)
                        #if !PLAYPORT_RELEASE
                        developerRows(t)
                        #endif
                    }
                    .padding(.bottom, 18)
                }
                .onChange(of: focus.focused) { _, id in
                    guard let id, id.hasPrefix("opt:") else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
                .task(id: navigation.pageSection) {
                    guard let s = navigation.pageSection, navigation.onGamePage else { return }
                    #if !PLAYPORT_RELEASE
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    guard navigation.pageSection == s, UIDriver.allowsDeferredNavigation else { return }
                    #else
                    try? await Task.sleep(for: .milliseconds(300))
                    #endif
                    if let row = Self.firstRow(ofSection: s) {
                        focus.ring(row)
                        proxy.scrollTo(row, anchor: .top)
                    }
                    navigation.pageSection = nil
                }
            }
        }
        .padding(.top, 18).padding(.leading, 20).padding(.trailing, 28)
    }

    private var context: String { name }

    // Graphics: aspect ratio, resolution, frame rate limit, Direct3D, launch arguments,
    // and on a foldable the virtual gamepad.
    @ViewBuilder
    private func graphicsRows(_ t: InstalledTitle) -> some View {
        let settings = launchSettings.binding(for: t.id)
        let own = settings.wrappedValue
        let inherited = LaunchSettings.resolve(game: nil, global: launchSettings.global)
        let screenName: (String?) -> String = { LaunchSettingsText.screen($0, pixels: false) }
        // The game's compatibility default (decision 0074) sits between the person's own
        // choice and Settings': a row it sets shows its marker, and Y goes back to it.
        let compat = launchSettings.compat(for: t.id)
        let cs = compat?.settings
        let from: (Bool) -> String = { $0 ? "，针对此游戏兼容适配" : "，来自全局设置" }
        // The aspect ratio and the resolution are separate choices (decision 0073): every shape
        // offers the same resolutions, each computed for it.
        let ownAspect = own.aspect.flatMap(ScreenAspect.init(rawValue:))
        let compatAspect = cs?.aspect.flatMap(ScreenAspect.init(rawValue:))
        let aspect = OptionValue.of(own: ownAspect, compat: compatAspect, inherited: inherited.aspect, name: LaunchSettingsText.aspect)
        let shape = ownAspect ?? compatAspect ?? inherited.aspect
        let screen = OptionValue.of(own: own.screen.map(Optional.some), compat: cs?.screen.map(Optional.some),
                                    inherited: inherited.screen, name: screenName)
        let limit = OptionValue.of(own: own.frameLimit, compat: cs?.frameLimit, inherited: inherited.frameLimit,
                                   name: LaunchSettingsText.frameLimit)
        let inheritedGraphics = launchSettings.effective(for: t, inheritingGraphics: true).graphics
        let d3d = OptionValue.of(own: own.graphics, compat: cs?.graphics, inherited: inheritedGraphics, name: LaunchSettingsText.graphics)
        PadSectionHeader(text: "画面").id("graphics")
        if let compat, compat.settings != LaunchSettings() {
            // On the page for touch and in the ring for a controller: what the marker means. An entry
            // that sets only the on-screen layout says so in Controls (GameControlsOptionRows).
            PadRow(id: "opt:compat", title: "\(OptionValue.compatMarker) 已为此游戏进行兼容预设",
                   subtitle: compat.reason + " 你在下方选项中的手动设置优先；按 Y 可恢复为此兼容预设。",
                   subtitleLines: nil, style: .plain, hint: "说明") {}
        }
        PadRow(id: "opt:aspect", title: "画面比例", value: aspect.text, accessory: .chevron, changed: aspect.changed,
               style: .plain, reset: aspect.changed ? { settings.wrappedValue.aspect = nil } : nil) {
            PadModal.shared.picker(
                title: "画面比例", context: "\(context) · 画面", note: LaunchSettingsText.nextStart,
                options: [PadOption(id: "", label: "默认",
                                    detail: LaunchSettingsText.aspect(compatAspect ?? inherited.aspect) + from(compatAspect != nil))]
                    + ScreenAspect.allCases.map { a in
                        PadOption(id: a.rawValue, label: LaunchSettingsText.aspect(a), detail: LaunchSettingsText.aspectDetail(a))
                    },
                selected: own.aspect ?? "") { settings.wrappedValue.aspect = $0.isEmpty ? nil : $0 }
        }
        PadRow(id: "opt:screen", title: "分辨率", value: screen.text, accessory: .chevron, changed: screen.changed,
               style: .plain, reset: screen.changed ? { settings.wrappedValue.screen = nil } : nil) {
            let resolutions = LaunchSettingsText.screens(shape)
            let native = resolutions.first == "native"
            PadModal.shared.picker(
                title: "分辨率", context: "\(context) · 画面", note: LaunchSettingsText.nextStart,
                options: [PadOption(id: "", label: "默认", detail: screenName(cs?.screen ?? inherited.screen) + from(cs?.screen != nil))]
                    + resolutions.map { spec in
                        PadOption(id: spec, label: screenName(spec),
                                  detail: spec == "native" && native ? "最清晰，耗电最高"
                                      : spec == LaunchSettings.defaultScreen ? "续航最佳" : LaunchSettingsText.pixels(spec, shape))
                    },
                selected: own.screen ?? "") { settings.wrappedValue.screen = $0.isEmpty ? nil : $0 }
        }
        PadRow(id: "opt:frameLimit", title: "帧率限制", value: limit.text, accessory: .chevron, changed: limit.changed,
               style: .plain, reset: limit.changed ? { settings.wrappedValue.frameLimit = nil } : nil) {
            PadModal.shared.picker(
                title: "帧率限制", context: "\(context) · 画面", note: LaunchSettingsText.nextStart,
                options: [PadOption(id: "", label: "默认", detail: "\(LaunchSettingsText.frameLimit(inherited.frameLimit))，来自全局设置")]
                    + LaunchSettingsText.frameLimits.map { PadOption(id: String($0), label: LaunchSettingsText.frameLimit($0)) }
                    + [PadOption(id: "0", label: "关闭", detail: "按屏幕支持的最高速度运行")],
                selected: own.frameLimit.map(String.init) ?? "") { settings.wrappedValue.frameLimit = Int($0) }
        }
        PadRow(id: "opt:graphics", title: "Direct3D", value: d3d.text, accessory: .chevron, changed: d3d.changed,
               style: .plain, reset: d3d.changed ? { settings.wrappedValue.graphics = nil } : nil) {
            PadModal.shared.picker(
                title: "Direct3D", context: "\(context) · 画面",
                note: LaunchSettingsText.nextStart + " " + LaunchSettingsText.graphicsDetection(t) + " " + LaunchSettingsText.graphicsFooter,
                options: [PadOption(id: "", label: "默认", detail: "\(LaunchSettingsText.graphics(inheritedGraphics))，来自全局设置或游戏自动检测")]
                    + GraphicsBackend.allCases.filter { Manifest.has($0) || own.graphics == $0 }.map {
                        PadOption(id: $0.rawValue, label: LaunchSettingsText.graphics($0), detail: LaunchSettingsText.graphicsDetail($0))
                    },
                selected: own.graphics?.rawValue ?? "") { settings.wrappedValue.graphics = GraphicsBackend(rawValue: $0) }
        }
        let args = own.arguments.trimmingCharacters(in: .whitespaces)
        PadRow(id: "opt:arguments", title: "启动参数", value: args.isEmpty ? "无" : args, accessory: .chevron,
               changed: !args.isEmpty, style: .plain, hint: "编辑",
               reset: args.isEmpty ? nil : { settings.wrappedValue.arguments = "" }) {
            PadModal.shared.keyboard(title: "启动参数", text: own.arguments, placeholder: "例如 -DX12",
                                     maxLength: 200) { settings.wrappedValue.arguments = $0 }
        }
        // A foldable's open panel held upright: the game above, a controller under it (VirtualGamepad.swift).
        if Panel.isFoldable {
            let padOn = own.virtualPad ?? false
            let layouts = PadLayoutStore.shared.all
            let off = { settings.wrappedValue.virtualPad = nil; settings.wrappedValue.virtualPadLayout = nil }
            PadRow(id: "opt:virtualPad", title: "虚拟手柄",
                   subtitle: "手机展开竖握时：上方显示游戏画面，下方显示手柄",
                   accessory: .toggle(padOn), changed: padOn, style: .plain, hint: padOn ? "关闭" : "开启",
                   reset: padOn ? off : nil) {
                // Turned on, the game keeps the default layout of now (Settings › Virtual gamepad).
                if padOn { off() } else {
                    settings.wrappedValue.virtualPad = true
                    settings.wrappedValue.virtualPadLayout = layouts.defaultID
                }
            }
            if padOn {
                let current = layouts.layout(own.virtualPadLayout)
                PadRow(id: "opt:virtualPadLayout", title: "手柄布局", value: current.name, accessory: .chevron,
                       style: .plain) {
                    PadModal.shared.picker(
                        title: "手柄布局", context: "\(context) · 画面",
                        note: "可在「设置 › 虚拟手柄」中编辑布局；在游戏内可长按 ⌂ 键调整。",
                        options: layouts.layouts.map { PadOption(id: $0.id, label: $0.name,
                                                                 detail: $0.id == layouts.defaultID ? "默认" : nil) },
                        selected: current.id) { settings.wrappedValue.virtualPadLayout = $0 }
                }
            }
        }
    }

    // Game: version, cloud saves, check game files, achievements, report a problem, uninstall.
    @ViewBuilder
    private func gameRows(_ t: InstalledTitle, _ g: SteamGame?) -> some View {
        let settings = launchSettings.binding(for: t.id)
        PadSectionHeader(text: "游戏").id("game")
        if let g, t.source == .installed, branches.count > 1 {
            PadRow(id: "opt:version", title: "版本", value: BranchLabel.text(t.branch, in: g.info), accessory: .chevron,
                   style: .plain) { if job == nil { pickVersion(g) } }
        }
        if let app = t.appID {
            let cloudOn = settings.wrappedValue.cloudSync ?? true
            let cloud = cloudStatus(t)
            if SteamAccountModel.cloudOn {
                PadRow(id: "opt:cloud", title: "云存档", subtitle: cloudOn ? cloudDetail(app) : nil,
                       accessory: .toggle(cloudOn), changed: !cloudOn, style: .plain, hint: cloudOn ? "关闭" : "开启",
                       reset: cloudOn ? nil : { settings.wrappedValue.cloudSync = nil }) {
                    settings.wrappedValue.cloudSync = cloudOn ? false : nil
                }
            } else {
                PadRow(id: "opt:cloud", title: "云存档", value: cloud.0, style: .plain, hint: "设置") {}
            }
            if cloudOn, SteamAccountModel.cloudOn, let c = model.cloud[app], !c.conflicts.isEmpty {
                // One choice for the game's saves, as Play asks it (UI/CloudConflictView.swift).
                PadRow(id: "opt:conflict", title: "选择要保留的存档",
                       subtitle: "\(c.conflicts.count) 个文件在本地与 Steam 云端均有改动",
                       value: "选择", accessory: .chevron, style: .plain, hint: "选择") {
                    guard !model.cloudSyncing.contains(app), !launch.running else { return }
                    library.askCloud(t, app, c.conflicts, thenPlay: false)
                }
            }
        }
        if t.store != .steam, t.source != .cohort { localRows(t) }
        filesRows(t)
        if let s = stats, !s.schema.achievements.isEmpty {
            PadRow(id: "opt:achievements", title: "成就", value: "\(s.unlockedCount) / \(s.schema.achievements.count)",
                   accessory: .chevron, style: .plain, hint: "打开") { navigation.gamePanels.append(.achievements) }
        }
        PadRow(id: "opt:report", title: "导出问题报告", value: "分享日志压缩包", accessory: .chevron, style: .plain,
               hint: "分享") { ProblemReport.share(t) }
        uninstallRow(t)
    }

    /// A game that came without a store's launch record (imported, found, or another
    /// store's copy): which executable Play starts, and the name it shows.
    @ViewBuilder
    private func localRows(_ t: InstalledTitle) -> some View {
        let machine = t.executableMachine.map(Self.machineName)
        PadRow(id: "opt:executable", title: "可执行文件",
               subtitle: [machine, t.direct3D.flatMap { $0.apis.isEmpty ? nil : $0.summary }].compactMap { $0 }.joined(separator: " · "),
               value: t.executable ?? "未找到", accessory: .chevron, changed: t.chosenExecutable != nil, style: .plain,
               hint: "选择", reset: t.chosenExecutable == nil ? nil : { library.setExecutable(t.id, nil) }) {
            let dir = LibraryModel.paths.games.appendingPathComponent(t.installDir, isDirectory: true)
            let found = Adoption.candidates(in: dir, folder: t.installDir)
            guard !found.isEmpty else { return }
            PadModal.shared.picker(
                title: "可执行文件", context: "\(context) · 游戏",
                note: "点击「开始游戏」时启动的程序。首项为 Playport 自动推荐项；安装程序、辅助工具与崩溃报告器排在最后。",
                options: [PadOption(id: "", label: "默认", detail: found.first.map { "\($0)，Playport 推荐" })]
                    + found.map { PadOption(id: $0, label: $0) },
                selected: t.chosenExecutable ?? "") { library.setExecutable(t.id, $0.isEmpty ? nil : $0) }
        }
        PadRow(id: "opt:name", title: "名称", value: t.name, accessory: .chevron, changed: t.displayName != nil, style: .plain,
               hint: "编辑", reset: t.displayName == nil ? nil : { library.rename(t.id, nil) }) {
            PadModal.shared.keyboard(title: "名称", text: t.name, placeholder: t.installDir, maxLength: 80) { library.rename(t.id, $0) }
        }
    }

    static func machineName(_ m: UInt16) -> String {
        switch m {
        case 0x8664: "x86-64"
        case 0x14C: "32 位 x86"
        case 0xAA64: "ARM64"
        default: String(format: "架构 0x%04X", m)
        }
    }

    @ViewBuilder
    private func filesRows(_ t: InstalledTitle) -> some View {
        let checking = library.verifying.contains(t.id)
        let canCheck = library.canVerify(t) && !launch.running && !library.removing.contains(t.id) && job == nil
        PadRow(id: "opt:files", title: "校验游戏文件", subtitle: verifyError(t), value: filesValue(t, checking: checking),
               style: .plain, hint: "校验") {
            if canCheck, !checking { library.verify(t.id) }
        }
        if t.source == .installed, let app = t.appID, job == nil, !checking, t.lastVerification.map({ !$0.ok }) ?? false {
            PadRow(id: "opt:repair", title: "从 Steam 修复",
                   subtitle: (t.lastVerification?.depotsToRecheck ?? 0) > 0 ? "重新下载缺失的 Steam 安装内容"
                                                                            : "重新下载已损坏的文件",
                   accessory: .chevron, style: .plain, hint: "修复") {
                if !installs.suspended, !launch.running { installs.repair(app, name: t.name) }
            }
        }
        if t.store == .epic, job == nil, !checking, t.lastVerification.map({ !$0.ok }) ?? false {
            PadRow(id: "opt:repair", title: "从 Epic Games 修复", subtitle: "重新下载已损坏的文件",
                   accessory: .chevron, style: .plain, hint: "修复") {
                if !installs.suspended, !launch.running { epic.install(t.key.id, name: t.name, kind: .repair) }
            }
        }
        if t.store == .gog, job == nil, !checking, t.lastVerification.map({ !$0.ok }) ?? false {
            PadRow(id: "opt:repair", title: "从 GOG 修复", subtitle: "重新下载已损坏的文件",
                   accessory: .chevron, style: .plain, hint: "修复") {
                if !installs.suspended, !launch.running { gog.install(t.key.id, name: t.name, kind: .repair) }
            }
        }
    }

    private func filesValue(_ t: InstalledTitle, checking: Bool) -> String {
        if checking { return "正在校验…" }
        if !library.canVerify(t) { return "仅限商店安装的游戏" }
        guard let v = t.lastVerification else { return "尚未校验" }
        let when = v.date.formatted(.relative(presentation: .named))
        if v.bad == 0, (v.depotsToRecheck ?? 0) > 0 { return "需与 Steam 核对内容" }
        return v.ok ? "上次校验正常（\(when)）" : "\(v.bad) / \(v.files) 个文件损坏"
    }

    private func verifyError(_ t: InstalledTitle) -> String? {
        guard let e = library.verifyErrors[t.id] else { return nil }
        #if PLAYPORT_RELEASE
        _ = e
        return "文件校验未能完成，请重试。"
        #else
        return e
        #endif
    }

    @ViewBuilder
    private func uninstallRow(_ t: InstalledTitle) -> some View {
        let removing = library.removing.contains(t.id)
        let downloading = installs.jobs[t.key]?.isRunning ?? false
        PadRow(id: "opt:uninstall", title: removing ? "正在卸载…" : "卸载", subtitle: removeError(t),
               value: t.sizeBytes.map { "可释放 \(ByteCount.format($0))" }, destructive: true, style: .plain, hint: "卸载") {
            guard !removing, !launch.running, !library.verifying.contains(t.id), !downloading else { return }
            let again = t.source == .installed
                ? "你随时可从游戏库重新安装。"
                : "若想再次游玩，需要将游戏重新拷入 Playport。"
            let frees = t.sizeBytes.map { "释放 \(ByteCount.format($0))" }
            var note = "游戏保存在自身安装目录内的存档会随之删除；保存在 Playport Windows 用户目录中的存档会保留。" + again
            var options = [PadOption(id: "keep", label: "保留游戏"), PadOption(id: "uninstall", label: "卸载", detail: frees)]
            #if !PLAYPORT_RELEASE
            if t.store == .xbox {
                // An Xbox copy's runtime keeps its saves per game in the prefix: the player chooses.
                note = "此游戏在手机上的存档可以保留供日后重装使用，也可以一并删除。" + again
                options = [PadOption(id: "keep", label: "保留游戏"),
                           PadOption(id: "uninstall", label: "卸载并保留存档", detail: frees),
                           PadOption(id: "uninstall-saves", label: "卸载并删除存档", detail: frees)]
            }
            #endif
            PadModal.shared.picker(title: "卸载 \(t.name)？", context: context, note: note, options: options, selected: nil) { choice in
                guard choice == "uninstall" || choice == "uninstall-saves" else { return }
                navigation.gamePanels = []
                library.uninstall(t.id, keepSaves: choice != "uninstall-saves")
            }
        }
    }

    private func removeError(_ t: InstalledTitle) -> String? {
        guard let e = library.removeErrors[t.id] else { return nil }
        #if PLAYPORT_RELEASE
        _ = e
        return "无法移除此游戏，请重试。"
        #else
        return e
        #endif
    }

    private func cloudDetail(_ app: UInt32) -> String? {
        if model.cloudSyncing.contains(app) { return "正在同步存档…" }
        if let e = model.cloudErrors[app] { return "未同步：" + e }
        guard let c = model.cloud[app] else { return nil }
        var s = "已于 " + c.at.formatted(date: .omitted, time: .shortened) + " 同步"
        if !c.downloaded.isEmpty || !c.uploaded.isEmpty { s += " · 从 Steam 下载 \(c.downloaded.count) 个，上传至 Steam \(c.uploaded.count) 个" }
        if !c.failed.isEmpty { s += " · \(c.failed.count) 个失败" }
        return s
    }

    // MARK: Developer (dev builds)

    #if !PLAYPORT_RELEASE
    /// FEX's four ordering switches, its block size and x87 precision over the game's profile, madeira.cfg
    /// keys over the game's own, the steam_api the game loads, and the build's facts. Not in the player's app (decision 0034).
    @ViewBuilder
    private func developerRows(_ t: InstalledTitle) -> some View {
        let settings = launchSettings.binding(for: t.id)
        let exe = (try? t.launchPlan(cohort: LibraryModel.cohort))?.exe ?? ""
        let profile = FEXProfile.defaults(appID: t.appID, exe: exe)
        let onOff: (Bool) -> String = { $0 ? "开启" : "关闭" }
        PadSectionHeader(text: "开发者").id("developer")
        ForEach(MemoryOrdering.Setting.allCases, id: \.self) { s in
            let v = OptionValue.of(own: settings.wrappedValue.ordering[s], inherited: profile[s] == true, name: onOff)
            PadRow(id: "opt:ordering-\(s.rawValue)", title: LaunchSettingsText.ordering(s), value: v.text, accessory: .chevron,
                   changed: v.changed, style: .plain, reset: v.changed ? { settings.wrappedValue.ordering[s] = nil } : nil) {
                PadModal.shared.picker(
                    title: LaunchSettingsText.ordering(s), context: "\(context) · x86 内存序", note: LaunchSettingsText.orderingFooter,
                    options: [PadOption(id: "", label: "默认", detail: "\(onOff(profile[s] == true))，游戏预设配置"),
                              PadOption(id: "on", label: "开启"), PadOption(id: "off", label: "关闭")],
                    selected: settings.wrappedValue.ordering[s].map { $0 ? "on" : "off" } ?? "") {
                    settings.wrappedValue.ordering[s] = $0.isEmpty ? nil : $0 == "on"
                }
            }
        }
        let block = OptionValue.of(own: settings.wrappedValue.maxInst, inherited: FEXProfile.defaultBlockSize(appID: t.appID, exe: exe)) {
            "\($0) 条指令"
        }
        PadRow(id: "opt:maxInst", title: "基本块大小", value: block.text, accessory: .chevron, changed: block.changed, style: .plain,
               reset: block.changed ? { settings.wrappedValue.maxInst = nil } : nil) {
            PadModal.shared.picker(
                title: "基本块大小", context: "\(context) · x86 模拟器", note: LaunchSettingsText.orderingFooter,
                options: [PadOption(id: "", label: "默认",
                                    detail: "\(FEXProfile.defaultBlockSize(appID: t.appID, exe: exe))，游戏预设配置")]
                    + FEXProfile.blockSizes.map { PadOption(id: String($0), label: "\($0) 条指令") },
                selected: settings.wrappedValue.maxInst.map(String.init) ?? "") { settings.wrappedValue.maxInst = Int($0) }
        }
        let x87Profile = FEXProfile.defaultX87Reduced(appID: t.appID, exe: exe)
        let x87Name: (Bool) -> String = { $0 ? "64 位" : "80 位" }
        let x87 = OptionValue.of(own: settings.wrappedValue.x87Reduced, inherited: x87Profile, name: x87Name)
        PadRow(id: "opt:x87Reduced", title: "x87 浮点精度", value: x87.text, accessory: .chevron, changed: x87.changed,
               style: .plain, reset: x87.changed ? { settings.wrappedValue.x87Reduced = nil } : nil) {
            PadModal.shared.picker(
                title: "x87 浮点精度", context: "\(context) · x86 模拟器", note: LaunchSettingsText.x87Footer,
                options: [PadOption(id: "", label: "默认", detail: "\(x87Name(x87Profile))，游戏预设配置"),
                          PadOption(id: "reduced", label: "64 位"), PadOption(id: "full", label: "80 位")],
                selected: settings.wrappedValue.x87Reduced.map { $0 ? "reduced" : "full" } ?? "") {
                settings.wrappedValue.x87Reduced = $0.isEmpty ? nil : $0 == "reduced"
            }
        }
        let cacheName: (Bool) -> String = { $0 ? "开启" : "关闭" }
        let cache = OptionValue.of(own: settings.wrappedValue.diskCache, inherited: FEXProfile.defaultDiskCache, name: cacheName)
        PadRow(id: "opt:diskCache", title: "磁盘缓存", value: cache.text, accessory: .chevron, changed: cache.changed,
               style: .plain, reset: cache.changed ? { settings.wrappedValue.diskCache = nil } : nil) {
            PadModal.shared.picker(
                title: "磁盘缓存", context: "\(context) · x86 模拟器", note: LaunchSettingsText.diskCacheFooter,
                options: [PadOption(id: "", label: "默认", detail: cacheName(FEXProfile.defaultDiskCache)),
                          PadOption(id: "on", label: "开启"), PadOption(id: "off", label: "关闭")],
                selected: settings.wrappedValue.diskCache.map { $0 ? "on" : "off" } ?? "") {
                settings.wrappedValue.diskCache = $0.isEmpty ? nil : $0 == "on"
            }
        }
        // A compatibility default's keys stay under the person's own, per key (decision 0091).
        let compat = launchSettings.compat(for: t.id)?.settings
        // Windows services (decision 0107): services.exe and the services it starts, for this play.
        // Unset, every game's default (decision 0153).
        let every = LaunchSettings.everyGame
        let services = OptionValue.of(own: settings.wrappedValue.windowsServices, compat: compat?.windowsServices,
                                      inherited: every.windowsServices ?? false, name: onOff)
        PadRow(id: "opt:windowsServices", title: "Windows 服务", value: services.text, accessory: .chevron,
               changed: services.changed, style: .plain,
               reset: services.changed ? { settings.wrappedValue.windowsServices = nil } : nil) {
            PadModal.shared.picker(
                title: "Windows 服务", context: "\(context) · Windows",
                note: "在启动游戏前运行 Wine 服务管理器（services.exe），供安装并依赖 Windows 服务的启动器使用；游戏结束时相关服务将自动停止。",
                options: [PadOption(id: "", label: "默认",
                                    detail: compat?.windowsServices.map { "\(onOff($0))，针对此游戏" } ?? onOff(every.windowsServices ?? false)),
                          PadOption(id: "on", label: "开启"), PadOption(id: "off", label: "关闭")],
                selected: settings.wrappedValue.windowsServices.map { $0 ? "on" : "off" } ?? "") {
                settings.wrappedValue.windowsServices = $0.isEmpty ? nil : $0 == "on"
            }
        }
        // The Khronos Vulkan loader (decision 0131): its vulkan-1.dll in place of Wine's, for this play.
        let khronosName: (Bool) -> String = { $0 ? "Khronos" : "Wine 自带" }
        let loader = OptionValue.of(own: settings.wrappedValue.khronosVulkanLoader, compat: compat?.khronosVulkanLoader,
                                    inherited: every.khronosVulkanLoader ?? false, name: khronosName)
        PadRow(id: "opt:khronosVulkanLoader", title: "Vulkan 加载器", value: loader.text, accessory: .chevron,
               changed: loader.changed, style: .plain,
               reset: loader.changed ? { settings.wrappedValue.khronosVulkanLoader = nil } : nil) {
            PadModal.shared.picker(
                title: "Vulkan 加载器", context: "\(context) · Windows",
                note: "Khronos Vulkan 加载器会加载游戏请求的 Vulkan 层（例如游戏内覆盖层）；Wine 自带的加载器不会加载它们。",
                options: [PadOption(id: "", label: "默认",
                                    detail: compat?.khronosVulkanLoader.map { "\(khronosName($0))，针对此游戏" }
                                        ?? khronosName(every.khronosVulkanLoader ?? false)),
                          PadOption(id: "khronos", label: "Khronos"), PadOption(id: "wine", label: "Wine 自带")],
                selected: settings.wrappedValue.khronosVulkanLoader.map { $0 ? "khronos" : "wine" } ?? "") {
                settings.wrappedValue.khronosVulkanLoader = $0.isEmpty ? nil : $0 == "khronos"
            }
        }
        let compatKeys = LaunchSettings.keyItems(compat?.runtime ?? "", over: LaunchSettings.everyGame.runtime)
            .trimmingCharacters(in: .whitespaces)
        let compatOptions = compat?.graphicsOptions.trimmingCharacters(in: .whitespaces) ?? ""
        let forThisGame: (String) -> String? = { $0.isEmpty ? nil : "\(OptionValue.compatMarker) 针对此游戏：\($0)；你设置的同名参数将优先覆盖" }
        let keys = settings.wrappedValue.runtime.trimmingCharacters(in: .whitespaces)
        PadRow(id: "opt:runtime", title: "运行时参数",
               subtitle: LaunchSettings.unusedRuntimeKeysNote(keys) ?? forThisGame(compatKeys),
               subtitleLines: 2,
               value: keys.isEmpty ? "无" : keys, accessory: .chevron, changed: !keys.isEmpty, style: .plain,
               reset: keys.isEmpty ? nil : { settings.wrappedValue.runtime = "" }) {
            PadModal.shared.keyboard(title: "运行时参数", text: settings.wrappedValue.runtime,
                                     placeholder: "例如 inproc-sync=1 env.FEX_SMCCHECKS=mtrack",
                                     maxLength: 200) { settings.wrappedValue.runtime = $0 }
        }
        // The game's environment variables and Vulkan layers' options (decisions 0060, 0137).
        let options = settings.wrappedValue.graphicsOptions.trimmingCharacters(in: .whitespaces)
        PadRow(id: "opt:graphicsOptions", title: "图形环境变量",
               subtitle: options.isEmpty || LaunchSettings.graphicsEnvironment(options) != nil ? forThisGame(compatOptions)
                   : "非 NAME=value 或 DXVK 选项格式：未生效",
               subtitleLines: 2,
               value: options.isEmpty ? "无" : options, accessory: .chevron, changed: !options.isEmpty, style: .plain,
               reset: options.isEmpty ? nil : { settings.wrappedValue.graphicsOptions = "" }) {
            PadModal.shared.keyboard(title: "图形环境变量", text: settings.wrappedValue.graphicsOptions,
                                     placeholder: "例如 dxvk.tilerMode=False VKD3D_CONFIG=one_time_submit",
                                     maxLength: 300) { settings.wrappedValue.graphicsOptions = $0 }
        }
        if let app = t.appID {
            // Playport's Steam client (decision 0115) may be the game's compatibility default.
            let steamAPI = OptionValue.of(own: settings.wrappedValue.steamAPI, compat: compat?.steamAPI, inherited: every.steamAPI ?? .emulated,
                                          name: Self.steamAPIModeText)
            PadRow(id: "opt:steamAPI", title: "Steam API", value: steamAPI.text, accessory: .chevron,
                   changed: steamAPI.changed, style: .plain,
                   reset: steamAPI.changed ? { settings.wrappedValue.steamAPI = nil } : nil) {
                PadModal.shared.picker(
                    title: "Steam API", context: "\(context) · Steam",
                    note: "游戏自带的 Steam API 需要 Steam 客户端处于运行状态：选择「Playport Steam 客户端」会为其提供仅响应当前游戏的内置客户端；"
                        + "若单独使用「游戏自带」，检测 Steam 运行状态的游戏将无法启动。"
                        + "更改将在下次启动游戏时生效。",
                    options: [PadOption(id: "", label: "默认",
                                        detail: compat?.steamAPI.map { "\(Self.steamAPIModeText($0))，针对此游戏" }
                                            ?? Self.steamAPIModeText(every.steamAPI ?? .emulated)),
                              PadOption(id: SteamAPISwap.Mode.emulated.rawValue, label: Self.steamAPIModeText(.emulated)),
                              PadOption(id: SteamAPISwap.Mode.client.rawValue, label: Self.steamAPIModeText(.client)),
                              PadOption(id: SteamAPISwap.Mode.original.rawValue, label: Self.steamAPIModeText(.original))],
                    selected: settings.wrappedValue.steamAPI?.rawValue ?? "") {
                    settings.wrappedValue.steamAPI = SteamAPISwap.Mode(rawValue: $0)
                }
            }
            developerFacts(t, app)
            PadRow(id: "opt:cloud-forget", title: "重置云同步记录",
                   subtitle: "下次同步将视为首次同步：与 Steam 云端不一致的存档将提示冲突",
                   style: .plain, hint: "重置") {
                guard !model.cloudSyncing.contains(app), !launch.running else { return }
                Task { await model.forgetCloud(app) }
            }
            let busy = model.gameProfileLoading.contains(app) || model.statsSyncing.contains(app)
            PadRow(id: "opt:steam-refresh", title: "从 Steam 刷新信息", subtitle: model.gameProfileErrors[app] ?? model.statsErrors[app],
                   value: busy ? "正在请求 Steam…" : nil, style: .plain, hint: "刷新") {
                guard !busy, signedIn, !launch.running else { return }
                Task {
                    await model.loadGameProfile(app, refresh: true)
                    await model.syncStats(app)
                    await model.syncCloud(app)
                }
            }
        } else {
            developerFacts(t, nil)
        }
    }

    /// The build's facts, as grey lines.
    private func developerFacts(_ t: InstalledTitle, _ app: UInt32?) -> some View {
        let g = game
        var lines: [(String, String)] = []
        if let b = t.buildID { lines.append(("构建号", String(b))) }
        if let b = g?.info.depots.buildID(branch: selectedBranch), b != t.buildID { lines.append(("Steam 构建号", String(b))) }
        if let app { lines.append(("Steam App ID", String(app))) }
        lines.append(("目录", "C:\\Games\\\(t.installDir)"))
        lines.append(("可执行文件", t.executable ?? "未找到"))
        if let state = steamAPIState { lines.append(("游戏目录内", Self.steamAPIText(state))) }
        for site in steamStubs {
            lines.append(("Steam DRM", Self.steamStubText(site, mode: launchSettings.settings(for: t.id).steamAPI ?? .emulated)))
        }
        if let app, let profile = model.gameProfiles[app] {
            lines.append(("玩家昵称", profile.personaName ?? "未知"))
            lines.append(("DLC", profile.dlc.isEmpty ? "未拥有" : "已拥有 \(profile.dlc.count) 项"))
        }
        if let note = t.note { lines.append(("备注", note)) }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(lines.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(lines[i].0).foregroundStyle(PP.muted)
                    Spacer(minLength: 8)
                    Text(lines[i].1).foregroundStyle(PP.soft).multilineTextAlignment(.trailing)
                }
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private static func steamAPIModeText(_ m: SteamAPISwap.Mode) -> String {
        switch m {
        case .emulated: "Playport 模拟器"
        case .client: "Playport Steam 客户端"
        case .original: "游戏自带"
        }
    }

    private static func steamStubText(_ site: SteamStub.Site, mode: SteamAPISwap.Mode) -> String {
        if site.info.unsupported != nil { return "\(site.info.label)，暂不支持移除" }
        if site.removed { return mode.removesSteamStub ? "已移除（\(site.info.label)）" : "已移除；下次启动时恢复" }
        return mode.removesSteamStub ? "\(site.info.label)，下次启动时移除" : site.info.label
    }

    private static func steamAPIText(_ s: SteamAPISwap.State) -> String {
        switch s {
        case .none: "无 steam_api"
        case .original: "游戏自带"
        case .emulated: "Playport 模拟器"
        case .mixed: "部分替换"
        }
    }
    #endif

    // MARK: achievements

    /// The game's achievements on Steam: unlocked ones first, newest first, then the rest.
    private var achievementsPanel: some View {
        let s = stats
        let all = s?.schema.achievements ?? []
        let sorted = all.enumerated().sorted { l, r in
            let lt = s?.unlockTime(l.element) ?? 0, rt = s?.unlockTime(r.element) ?? 0
            let lu = s?.unlocked(l.element) ?? false, ru = s?.unlocked(r.element) ?? false
            if lu != ru { return lu }
            if lu, lt != rt { return lt > rt }
            return l.offset < r.offset
        }.map(\.element)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(context) · 已解锁 \(s?.unlockedCount ?? 0) / \(all.count)").font(.system(size: 12)).foregroundStyle(PP.muted)
                .padding(.horizontal, 14)
            Text("成就").font(PP.display(22)).foregroundStyle(PP.text)
                .padding(.horizontal, 14).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(sorted.indices, id: \.self) { i in
                            achievementRow(sorted[i], s, id: "ach:\(i)")
                        }
                        if !(s?.schema.achievements.isEmpty ?? true) {
                            Text("数据来自 Steam。游玩期间解锁的成就将在下次打开 Playport 时同步至 Steam。")
                                .font(.system(size: 12)).foregroundStyle(PP.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.top, 8)
                        }
                    }
                    .padding(.bottom, 18)
                }
                .onChange(of: focus.focused) { _, id in
                    guard let id, id.hasPrefix("ach:") else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
        .padding(.top, 18).padding(.leading, 20).padding(.trailing, 28)
    }

    private func achievementRow(_ a: StatsSchema.Achievement, _ s: UserStatsSnapshot?, id: String) -> some View {
        let unlocked = s?.unlocked(a) ?? false
        let time = s?.unlockTime(a) ?? 0
        let selected = focus.focused == id
        let hidden = a.hidden && !unlocked
        return HStack(spacing: 12) {
            Image(systemName: unlocked ? "trophy.fill" : "lock.fill")
                .font(.system(size: 14))
                .foregroundStyle(unlocked ? PP.accent : selected ? Color(hex: 0x3A4452) : PP.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(hidden ? "隐藏成就" : a.text(a.displayName)).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? PP.background : unlocked ? PP.text : PP.soft)
                let desc = hidden ? "解锁后即可查看详情。" : a.text(a.description)
                if !desc.isEmpty, desc != a.name {
                    Text(desc).font(.system(size: 12)).foregroundStyle(selected ? Color(hex: 0x3A4452) : PP.muted)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if unlocked, time > 0 {
                Text(Date(timeIntervalSince1970: TimeInterval(time)).formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 12)).foregroundStyle(selected ? Color(hex: 0x3A4452) : PP.muted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .frame(minHeight: 44)
        .background(selected ? PP.text : .clear, in: RoundedRectangle(cornerRadius: 10))
        .padItem(id, hint: "", cornerRadius: 10, ring: false) {}
    }
}

/// The page's buttons, each at its full width and in order, starting a new row where the next
/// would not fit, so no label is cut to a letter on a phone in landscape.
private struct PageButtonRows: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for (i, size) in zip(row.indices, row.sizes) {
                subviews[i].place(at: CGPoint(x: x, y: y + row.height / 2), anchor: .leading,
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Each button at its ideal size (narrowed only when it alone is wider than the rows).
    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            var size = subviews[i].sizeThatFits(.unspecified)
            if size.width > width { size = subviews[i].sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            row.sizes.append(size)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: buttons

/// The page's big amber button (Play, Install), with A on it.
private struct PrimaryButton: View {
    let id: String
    let title: String
    var enabled = true
    let hint: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PadGlyph(button: .a, inverted: enabled)
            Text(title).font(PP.display(20)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(enabled ? PP.onAccent : PP.muted)
        .padding(.leading, 14).padding(.trailing, 26)
        .frame(height: 52)
        .background(enabled ? PP.accent : PP.raised, in: RoundedRectangle(cornerRadius: 12))
        .padItem(id, hint: hint, cornerRadius: 12) { if enabled { action() } }
    }
}

/// A dark button beside it (achievements, Options, Update), with its button glyph when it has one.
private struct SecondaryButton: View {
    let id: String
    let systemImage: String?
    let title: String
    var glyph: NavButton?
    var enabled = true
    let hint: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 14)) }
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
            if let glyph { PadGlyph(button: glyph).padding(.leading, 2) }
        }
        .foregroundStyle(enabled ? PP.text : PP.muted)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(PP.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
        .padItem(id, hint: hint, cornerRadius: 10) { if enabled { action() } }
    }
}

// MARK: report a problem

/// Report a problem: the system share sheet with the app's log (playport.log in the
/// player's app, s1-host.log in a dev build, which hold the game's last run) and the
/// logs a game left on drive C, for the player to send where they like.
@MainActor
enum ProblemReport {
    static func files() -> [URL] {
        let fm = FileManager.default
        var urls = [AppLog.url]
        #if PLAYPORT_RELEASE
        urls.append(AppLog.url.deletingLastPathComponent().appendingPathComponent(AppLog.previousName))
        #endif
        let driveC = LibraryModel.paths.games.deletingLastPathComponent()
        urls += ((try? fm.contentsOfDirectory(at: driveC, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return urls.filter { fm.fileExists(atPath: $0.path) }
    }

    static func share(_ t: InstalledTitle) {
        let urls = files()
        Task { @MainActor in
            let zip = await archive(urls, name: t.id)
            LibraryModel.log("report a problem for \(t.id): sharing \(urls.map(\.lastPathComponent).joined(separator: ", "))"
                             + (zip.map { " as \($0.lastPathComponent)" } ?? " (not zipped)"))
            present(zip.map { [$0] } ?? urls)
        }
    }

    /// `urls` as one zip in the temporary folder, which a GitHub issue takes and a
    /// paste site does not need to (PLA-21): `Playport-report-<id>-<time>.zip`, with
    /// the files in a folder of that name. iOS zips a folder for upload
    /// (NSFileCoordinator's forUploading, through the queue form: the blocking form's
    /// non-escaping block makes Swift record this file's full path for its escape check);
    /// nil when that fails, and the files go as they are.
    static func archive(_ urls: [URL], name id: String) async -> URL? {
        guard !urls.isEmpty else { return nil }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Report a problem", isDirectory: true)
        try? fm.removeItem(at: root)   // the last report's
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let safe = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        let base = "Playport-report-\(safe)-\(stamp.string(from: Date()))"
        let folder = root.appendingPathComponent(base, isDirectory: true)
        let zip = root.appendingPathComponent(base + ".zip")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for u in urls { try fm.copyItem(at: u, to: folder.appendingPathComponent(u.lastPathComponent)) }
        } catch {
            LibraryModel.log("report a problem: could not gather the logs: \(error)")
            return nil
        }
        let intent = NSFileAccessIntent.readingIntent(with: folder, options: .forUploading)
        let failure: String? = await withCheckedContinuation { done in
            NSFileCoordinator().coordinate(with: [intent], queue: OperationQueue()) { error in
                if let error { return done.resume(returning: "\(error)") }
                do {
                    try FileManager.default.moveItem(at: intent.url, to: zip)
                    done.resume(returning: nil)
                } catch {
                    done.resume(returning: "\(error)")
                }
            }
        }
        try? fm.removeItem(at: folder)
        if let failure {
            LibraryModel.log("report a problem: could not zip the logs: \(failure)")
            return nil
        }
        return fm.fileExists(atPath: zip.path) ? zip : nil
    }

    /// The system share sheet with `urls` (also a dev build's Settings › Developer › logs).
    static func present(_ urls: [URL]) {
        guard !urls.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        }
        top.present(sheet, animated: true)
        shown = sheet
    }

    /// The share sheet `present` put up, while it is on screen. It takes no
    /// controller focus, so the shell keeps the pad's presses from the page
    /// under it (AppShell.press) and B closes it.
    private static weak var shown: UIViewController?
    static var sheetUp: Bool { shown.map { $0.presentingViewController != nil && !$0.isBeingDismissed } ?? false }

    /// A pad press while the sheet is up: B closes it, the rest do nothing.
    static func sheetPress(_ b: NavButton) {
        if b == .b { shown?.dismiss(animated: true) }
    }
}

/// What the player is told about JIT before and during a launch (JitProvider).
enum JitNote {
    static let beforePlay = "JIT 由 Playport 内置助手通过 LocalDevVPN 提供；若未开启，点击「开始游戏」时会自动开启。"
    static let waiting = "Playport 的 JIT 助手正在附加，请保持 Playport 开启。"
    static let waitingForStikDebug = "正在等待 StikDebug 启用 JIT，完成后会自动返回 Playport。"
    static let waitingForAnotherApp = "正在等待其他应用提供 JIT。请现在前往该应用配合 universal.js 脚本为 Playport 启用 JIT。"

    /// Why a game ended on running out of its JIT pool (LaunchMessage). Every Play
    /// gets the same pool (JitPool.sizeMB, decision 0184); only a dev build's simulated
    /// one is smaller. One that went on running was ended by the restart (decision 0030).
    static func outOfMemory(_ part: JitPool.Exhaustion, poolMB: Int) -> String {
        let what = switch part {
        case .head: "游戏的程序文件"
        case .tail: "Playport 为游戏转译的代码"
        case .alias: "游戏运行期间动态编译的代码"
        }
        let size = poolMB > 0 ? "\(ByteCount.format(mb: poolMB)) 的 " : ""
        let more = poolMB > 0 && poolMB < JitPool.sizeMB
            ? "当前预留空间低于正常值：「设置 › 开发者」中的「模拟 JIT 内存大小」缩小了上限。"
            : "此游戏所需的 JIT 内存超出了 Playport 的预留上限。"
        return "Playport 为游戏预留了 \(size)JIT 内存，已被\(what)占满。\(more)"
    }

    /// Why a game ended on FEX's host band filling (LaunchMessage, decision 0120): its size is
    /// fixed, so there is nothing to set; what fills it is the game's threads, with its launcher's.
    static let outOfEmulatorMemory = "x86 模拟器会为游戏及其启动器运行的每个线程保留固定大小的内存，"
        + "当前已被这些线程占满。此游戏创建的线程数超出了 Playport 的承载上限。"
}
