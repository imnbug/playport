// SPDX-License-Identifier: GPL-3.0-or-later
// The Cloud save conflict screen (CloudConflict.dc.html): a game whose saves
// changed on this phone and on Steam Cloud since the last sync asks once
// which side to keep, for all its conflicting files (PlayportKit CloudSides).
// A keeps the phone's, X keeps Steam's: one SteamService.syncCloud(resolve:)
// call settles every file the same way (SteamService.resolveAll), and the side
// not picked is backed up for 30 days (Cloud.Backups, pruned by LibraryModel).
// B, Decide later, closes it and the game does not start.
//
// Play asks it first (LibraryModel.play, `cloudGate`) and starts the game once
// the choice is settled; Game options' Cloud saves row asks it without a Play.

import HostIOKit
import PlayportKit
import SteamClientKit
import SwiftUI

@MainActor
final class CloudConflictSession: ObservableObject {
    let titleID: String
    let appID: UInt32
    let name: String
    let conflicts: [SteamService.CloudConflict]
    let sides: CloudSides
    /// Play the game once the choice is settled.
    let thenPlay: Bool
    /// Played on this phone (the catalogue's total), for the phone's card.
    let playSeconds: TimeInterval?
    @Published private(set) var settling: SteamService.CloudChoice?
    @Published private(set) var error: String?

    init(titleID: String, appID: UInt32, name: String, conflicts: [SteamService.CloudConflict], thenPlay: Bool, playSeconds: TimeInterval?) {
        self.titleID = titleID
        self.appID = appID
        self.name = name
        self.conflicts = conflicts
        sides = CloudSides(conflicts)
        self.thenPlay = thenPlay
        self.playSeconds = playSeconds
    }

    func press(_ b: NavButton) {
        guard settling == nil else { return }
        switch b {
        case .a: keep(.phone)
        case .x: keep(.steam)
        case .b: decideLater()
        default: break
        }
    }

    func decideLater() {
        guard settling == nil else { return }
        LibraryModel.log("cloud: \(titleID): decide later; \(conflicts.count) conflict(s) stay"
                         + (thenPlay ? " and the game does not start" : ""))
        PadModal.shared.close()
    }

    func keep(_ side: SteamService.CloudChoice) {
        guard settling == nil, let steam = SteamAccountModel.current else { return }
        settling = side
        error = nil
        LibraryModel.log("cloud: \(titleID): keep \(side == .phone ? "this phone's" : "Steam Cloud's") saves for \(conflicts.count) file(s)")
        Task {
            await steam.syncCloud(appID, resolve: SteamService.resolveAll(conflicts, side))
            settling = nil
            let left = steam.cloud[appID]?.conflicts ?? conflicts
            if case .signedIn = steam.state {
                if let e = steam.cloudErrors[appID] {
                    error = "无法连接 Steam 云存档（\(e)）。请重试，或稍后决定。"
                } else if !left.isEmpty {
                    error = "仍有 \(left.count) 个文件存在冲突。请重试，或稍后决定。"
                }
            } else {
                error = "需要先登录 Steam 才能解决云存档冲突。请登录后重试，或稍后决定。"
            }
            guard error == nil else {
                LibraryModel.log("cloud: \(titleID): not settled: \(error!)")
                return
            }
            LibraryModel.log("cloud: \(titleID): settled" + (thenPlay ? "; starting the game" : ""))
            if case .cloud(let s) = PadModal.shared.content, s === self { PadModal.shared.close() }
            guard thenPlay else { return }
            do {
                if try await LibraryModel.shared.play(titleID) != true, !TitleLaunch.shared.running, !PadModal.shared.isUp {
                    AppNavigation.shared.openTitle(titleID)
                }
            } catch {
                LibraryModel.log("play \(titleID) refused: \(error)")
            }
        }
    }
}

struct CloudConflictView: View {
    @ObservedObject var session: CloudConflictSession

    var body: some View {
        ZStack {
            // The design's own screen, not a scrim: the page and its footer do not show through.
            ZStack { PP.background; Color(hex: 0x1E2A3F).opacity(0.35) }.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Text("要保留哪一份「\(session.name)」存档？").font(PP.display(24)).lineLimit(2)
                Text("自上次同步以来，本机与 Steam 云端的存档均发生了变动。未被选中的存档将保留备份 30 天。")
                    .font(.system(size: 13)).foregroundStyle(PP.muted).lineSpacing(2).padding(.top, -6)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    card(.phone, heading: "本机存档", time: session.sides.phone.newest, line: phoneLine, button: .a)
                    card(.steam, heading: "Steam 云存档", time: session.sides.steam.newest, line: steamLine, button: .x)
                }
                if let e = session.error {
                    Text(e).font(.system(size: 12)).foregroundStyle(Color(hex: 0xFF9A6B))
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(width: 600)
            .background(PP.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(PP.line))
            .padding(.bottom, 20)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    PadModalHint(button: .b, label: session.thenPlay ? "稍后决定（暂不启动游戏）" : "稍后决定") {
                        session.press(.b)
                    }
                }
                .padding(.horizontal, 36)
                .frame(height: 36)
            }
        }
        .foregroundStyle(PP.text)
        .accessibilityIdentifier("cloud-conflict")
    }

    private var phoneLine: String {
        let s = session.sides.phone
        if s.files == 0 { return "本机暂无存档" }
        return session.playSeconds.map { "本机已游玩 \(PlayTime.format($0))" } ?? files(s)
    }

    private var steamLine: String {
        let s = session.sides.steam
        return s.files == 0 ? "Steam 云端暂无存档" : files(s)
    }

    private func files(_ s: CloudSides.Side) -> String {
        "\(s.files) 个文件 · \(ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file))"
    }

    private func when(_ d: Date?) -> String {
        guard let d else { return "—" }
        let time = d.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天 \(time)" }
        if cal.isDateInYesterday(d) { return "昨天 \(time)" }
        return d.formatted(.dateTime.day().month(.abbreviated)) + " \(time)"
    }

    /// One side: the ring on the phone's (A), as the design draws it.
    private func card(_ side: SteamService.CloudChoice, heading: String, time: Date?, line: String, button: NavButton) -> some View {
        let busy = session.settling == side
        return Button { session.press(button) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(heading.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.1).foregroundStyle(PP.muted)
                Text(when(time)).font(PP.display(22))
                Text(line).font(.system(size: 13)).foregroundStyle(PP.soft)
                HStack(spacing: 6) {
                    PadGlyph(button: button)
                    Text(busy ? "正在与 Steam 同步…" : "保留此存档").font(.system(size: 13))
                    if busy { ProgressView().scaleEffect(0.6).tint(PP.text) }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(PP.raised, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                if side == .phone {
                    RoundedRectangle(cornerRadius: 17).stroke(PP.accent, lineWidth: 3).padding(-3)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(session.settling != nil && !busy ? 0.5 : 1)
        .accessibilityIdentifier("cloud-keep-\(side.rawValue)")
    }
}
