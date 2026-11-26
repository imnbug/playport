// SPDX-License-Identifier: GPL-3.0-only
// Xodus 514dd56f360a4bdf12f4acde5148bac5ce5f957f webview.rs and login.rs;
// translated to Swift by the Playport authors, 2026-10-30. Modified: 0058's
// non-persistent WKWebView, origin-checked main-frame script messages, dev only.
import Combine
import ContentKit
import Foundation
import SwiftUI
import UIKit
import WebKit
import XboxClientKit

enum XboxAccountState { case unknown, signedOut, signedIn }

@MainActor
final class XboxAccount: ObservableObject {
    static let shared = XboxAccount()
    @Published private(set) var state = XboxAccountState.unknown
    @Published private(set) var error: String?
    @Published var signingIn = false
    @Published private(set) var page: XboxLoginPage?
    @Published private(set) var step = 0
    @Published private(set) var exchanging = false
    let session: XboxSession
    private var exchange: Task<Void, Never>?
    /// Sign-outs the player asked for (Sign out, Reset device) not yet heard back.
    private var asked = 0

    private init() {
        #if canImport(Security)
        let store = KeychainSecretStore(service: XboxSession.keychainService)
        #else
        let store = MemorySecretStore()
        #endif
        session = XboxSession(store: store, log: ContentKit.Logger { AppLog.append("xbox: " + $0) })
        Task {
            _ = await session.onSignOut { Task { @MainActor in XboxAccount.shared.ended() } }
            await restore()
        }
    }
    /// The session ended: the player's sign-out or device reset, or Microsoft refusing to
    /// renew it (at app start or mid-play). Every way runs the same clean-up: the play's
    /// bridge is closed by its own handler, and here the account shows signed out, the
    /// runtime's offline identities go and a save question still up is closed. A refusal
    /// asks for sign-in again.
    private func ended() {
        state = .signedOut
        if asked > 0 { asked -= 1; error = nil } else { error = XboxSessionError.signInRequired.description }
        XboxOfflineDeviceModel.removeIdentities()
        XboxSaveConflictPrompt.shared.choose(.none, why: "signed out")
    }
    func restore() async {
        state = await session.state == .signedIn ? .signedIn : .signedOut
        guard state == .signedIn else { return }
        do { try await session.renew(); error = nil }
        catch XboxSessionError.signInRequired { state = .signedOut; error = XboxSessionError.signInRequired.description }
        catch { self.error = Self.message(error) }
    }
    func beginSignIn() { page = nil; error = nil; signingIn = true }
    func prepare() async {
        do {
            let page = try await session.prepareSignIn()
            guard signingIn, !Task.isCancelled else { return }
            self.page = page; step += 1; error = nil
        } catch { if signingIn, !Task.isCancelled { self.error = Self.message(error) } }
    }
    func received(_ token: XboxSignInToken) {
        guard exchange == nil else { return }
        exchanging = true
        exchange = Task {
            defer { exchanging = false; exchange = nil }
            do {
                let result = try await session.signIn(token)
                guard signingIn, !Task.isCancelled else { return }
                switch result {
                case .signedIn: state = .signedIn; error = nil; signingIn = false; page = nil
                case let .continueAt(next): page = next; step += 1
                }
            } catch { if signingIn, !Task.isCancelled { self.error = Self.message(error) } }
        }
    }
    func closeSignIn() { exchange?.cancel(); page = nil }
    func signOut() async {
        exchange?.cancel()
        asked += 1
        do { try await session.signOut(); state = .signedOut; error = nil; signingIn = false; page = nil }
        catch { self.error = Self.message(error) }
    }
    func resetDevice() async {
        exchange?.cancel()
        asked += 1
        do { try await session.resetDevice(); state = .signedOut; error = nil; signingIn = false; page = nil }
        catch { self.error = Self.message(error) }
    }
    private static func message(_ error: Error) -> String {
        if let error = error as? XboxSessionError { return error.description }
        if let error = error as? XboxLicenceFailure { return error.description }
        if let error = error as? ClientError { return error.description }
        return "无法连接 Xbox，请重试。"
    }
}

struct XboxAccountSettings: View {
    @ObservedObject private var account = XboxAccount.shared
    var body: some View {
        PadSectionHeader(text: "Xbox")
        switch account.state {
        case .unknown: SettingsInfoRow(id: "xbox:status", title: "正在检查…", subtitle: nil)
        case .signedOut:
            SettingsInfoRow(id: "xbox:status", title: "未登录", subtitle: account.error ?? "你的 Microsoft 账号（仅开发版可用）。")
            PadRow(id: "set:xbox:signin", title: "登录 Xbox", subtitle: "在 Microsoft 官方登录页面完成验证", accessory: .chevron,
                   hint: "登录") { account.beginSignIn() }
        case .signedIn:
            SettingsInfoRow(id: "xbox:status", title: "已登录", subtitle: account.error ?? "Microsoft 登录凭证仅保存在本机钥匙串中。")
            PadRow(id: "set:xbox:signout", title: "退出登录", subtitle: "删除 Playport 的 Xbox 会话，但保留虚拟 Windows 设备身份。",
                   destructive: true, hint: "退出登录") {
                PadModal.shared.picker(title: "要退出登录 Xbox 吗？", context: "设置 · 账号",
                    note: "Playport 将删除会话密钥并停止签发票据。已登录的游戏在现有票据过期前仍可继续使用。如需注销所有会话，请前往 Microsoft 账号安全页面。虚拟 Windows 设备身份将会保留，因此重新登录不会额外占用 Microsoft Store 的 10 台设备名额。",
                    options: [PadOption(id: "keep", label: "保持登录"), PadOption(id: "out", label: "退出登录")], selected: "keep") {
                    if $0 == "out" { Task { await account.signOut() } }
                }
            }
            XboxOfflineDeviceSettings()
        }
    }
}

struct XboxResetDeviceSettings: View {
    @ObservedObject private var account = XboxAccount.shared
    var body: some View {
        PadSectionHeader(text: "Xbox")
        PadRow(id: "set:xbox:resetDevice", title: "重置 Xbox 设备身份", subtitle: "更换虚拟 Windows 设备并退出登录，不会在 Microsoft 端解绑旧设备。",
               destructive: true, hint: "重置") {
            PadModal.shared.picker(title: "要重置 Xbox 设备身份吗？", context: "设置 · 开发者",
                note: "此操作将退出登录 Xbox 并生成新的虚拟 Windows 设备。Microsoft Store 最多允许关联 10 台设备，请前往 account.microsoft.com/devices/content 解绑旧设备，以免占用名额。",
                options: [PadOption(id: "keep", label: "保留当前设备"), PadOption(id: "reset", label: "重置设备")], selected: "keep") {
                if $0 == "reset" { Task { await account.resetDevice() } }
            }
        }
    }
}

struct XboxSignInSheet: View {
    @ObservedObject private var account = XboxAccount.shared
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(XboxSignIn.passkeyNote).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                if let error = account.error { Text(error).font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
                if account.exchanging { ProgressView("正在完成登录…") }
                if let page = account.page {
                    XboxLoginWebView(page: page, step: account.step, done: account.received)
                } else if account.error == nil { ProgressView("正在准备 Xbox 登录…").frame(maxHeight: .infinity) }
                else { Spacer() }
            }
            .navigationTitle("登录 Xbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { account.signingIn = false } }
                if account.error != nil { ToolbarItem(placement: .primaryAction) { Button("重试") { Task { await account.prepare() } } } }
            }
            .task { await account.prepare() }
            .onAppear { AppDelegate.allowsPortrait = true }
            .onDisappear { AppDelegate.allowsPortrait = false; account.closeSignIn() }
        }
    }
}

struct XboxLoginWebView: UIViewRepresentable {
    let page: XboxLoginPage
    let step: Int
    let done: (XboxSignInToken) -> Void
    func makeCoordinator() -> XboxWebCoordinator { XboxWebCoordinator(done: done) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // 0058: same cookies for both hosted legs, none after dismissal.
        config.userContentController.add(context.coordinator, name: "xbox")
        config.userContentController.addUserScript(WKUserScript(source: XboxSignIn.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = XboxSignIn.userAgent
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        load(view, context.coordinator)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { if context.coordinator.loaded != step { load(view, context.coordinator) } }
    static func dismantleUIView(_ view: WKWebView, coordinator: XboxWebCoordinator) {
        view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "xbox")
        view.configuration.userContentController.removeAllUserScripts(); view.navigationDelegate = nil
    }
    private func load(_ view: WKWebView, _ coordinator: XboxWebCoordinator) {
        coordinator.loaded = step; coordinator.finished = false
        var request = URLRequest(url: page.url)
        for (name, value) in page.headers { request.setValue(value, forHTTPHeaderField: name) }
        view.load(request)
    }
}

@MainActor
final class XboxWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let done: (XboxSignInToken) -> Void
    weak var view: WKWebView?
    var loaded = 0
    var finished = false
    init(done: @escaping (XboxSignInToken) -> Void) { self.done = done }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url, let text = message.body as? String,
              !finished, let result = try? XboxSignIn.receive(Secret(text), from: url) else { return }
        switch result {
        case .ignored: break
        case let .script(script): view?.evaluateJavaScript(script, completionHandler: nil)
        case let .token(token):
            finished = true
            view?.loadHTMLString("", baseURL: nil) // Don't leave ServerData/tickets visible while exchanging.
            done(token)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished, let url = webView.url, XboxSignIn.isHandoff(url) else { return }
        webView.evaluateJavaScript(XboxSignIn.handoffScript, completionHandler: nil)
    }
}

/// A dev-only sheet presenter on AppShell's overlay. No Xbox reference or
/// dependency is compiled into the release shell.
struct XboxSignInPresenter: View {
    @ObservedObject private var account = XboxAccount.shared
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: $account.signingIn) { XboxSignInSheet() }
    }
}
