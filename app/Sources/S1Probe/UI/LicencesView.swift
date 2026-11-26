// SPDX-License-Identifier: GPL-3.0-or-later
// Settings › About › Licences, pages shown in place of the About section
// (AppNavigation.licences; SettingsView.swift). The list: Playport's copyright,
// licence, warranty notice and where its source is (the GPL's Appropriate Legal
// Notices), then every component the app carries with its licence, the credit
// lines and, until the selection is reviewed, its open questions. A component:
// its licence files. A file: its text, one row a paragraph so the ring scrolls
// through it. The list comes from the bundled Licenses/components.json
// (PlayportKit Licences, docs/NOTICES.md); a build without it says so rather
// than showing a placeholder. Every row is on Settings' ring: A opens, B goes
// back a page.

import PlayportKit
import SwiftUI

extension LicencePage {
    /// The row that opens this page on the page under it; the ring goes back to it.
    var row: String {
        switch self {
        case .list: "set:licences"
        case .component(let name): "set:lic:c:" + name
        case .text(let file): "set:lic:f:" + file
        }
    }

    /// Where the ring starts on this page.
    var firstItem: String {
        switch self {
        case .list: "set:lic:playport"
        case .component: "set:lic:head"
        case .text: "set:lic:p:0"
        }
    }
}

@MainActor
enum BundledLicences {
    static let copyright = "Copyright (C) 2026 The Playport authors"
    static let directory = Bundle.main.bundleURL.appendingPathComponent("Licenses", isDirectory: true)
    static let loaded: Result<Licences, Error> = Result { try Licences.load(directory: directory) }
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}

struct LicencePageView: View {
    let page: LicencePage

    var body: some View {
        switch page {
        case .list: LicencesList()
        case .component(let name): LicenceComponentPage(name: name)
        case .text(let file): LicenceTextPage(file: file)
        }
    }
}

/// A paragraph on the ring: A does nothing, the ring moving onto it scrolls it into view.
private struct LicenceParagraph: View {
    let id: String
    let text: String
    var monospaced = false
    var warning = false

    var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .foregroundStyle(warning ? Color(hex: 0xFF9A8A) : PP.soft)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(PP.surface, in: RoundedRectangle(cornerRadius: 10))
            .padItem("set:lic:" + id, hint: "", cornerRadius: 10) {}
    }
}

private struct LicencesList: View {
    var body: some View {
        VStack(spacing: 8) {
            SettingsNote(text: "Playport \(BundledLicences.version) · \(BundledLicences.copyright)")
            LicenceParagraph(id: "playport", text: "Playport 是自由软件：你可以遵照自由软件基金会（Free Software Foundation）发布的 "
                             + "GNU 通用公共许可证（GNU General Public License）第三版或（由你选择的）任何更高版本，"
                             + "以及其许可证附加豁免条款的额外许可，对其进行再分发和/或修改。")
            LicenceParagraph(id: "warranty", text: "发布 Playport 是希望它能够发挥作用，但没有任何担保（WITHOUT ANY WARRANTY）；"
                             + "甚至不包含针对特定用途的适销性或适用性的默示担保。详情请参阅 GNU 通用公共许可证。")
            if case .success(let licences) = BundledLicences.loaded {
                if licences.contains(Licences.playportLicence) { fileRow("GNU 通用公共许可证（GPL）", Licences.playportLicence) }
                if licences.contains(Licences.playportException) { fileRow("附加许可豁免条款", Licences.playportException) }
            }
            PadSectionHeader(text: "源代码")
            LicenceParagraph(id: "source", text: "本版本的完整源代码（包含 Playport 对所依赖上游项目所做的全部修改以及构建说明）"
                             + "均随对应发布版本免费公开提供，文件名为 Playport-\(BundledLicences.version)-source.tar。"
                             + "你可以在上述许可证条款下自由复制、修改和分享 Playport。")
            switch BundledLicences.loaded {
            case .success(let licences):
                PadSectionHeader(text: "开源组件")
                ForEach(licences.components) { c in
                    PadRow(id: LicencePage.component(c.name).row, title: c.name, value: c.licence, accessory: .chevron,
                           hint: "打开") {
                        AppNavigation.shared.openLicence(.component(c.name))
                    }
                }
                SettingsNote(text: "Playport 的各个组成部分均保留其原有的开源许可证。以上是随附的许可证全文。")
                if !licences.credits.isEmpty {
                    PadSectionHeader(text: "致谢")
                    ForEach(licences.credits.indices, id: \.self) { i in
                        LicenceParagraph(id: "credit:\(i)", text: licences.credits[i])
                    }
                }
                if !licences.reviewed {
                    PadSectionHeader(text: "待复核项")
                    ForEach(licences.open.indices, id: \.self) { i in
                        LicenceParagraph(id: "open:\(i)", text: licences.open[i])
                    }
                    SettingsNote(text: "此构建版本的版权声明尚未完成正式发布复核（状态：\(licences.status)）。")
                }
            case .failure(let error):
                PadSectionHeader(text: "开源组件")
                LicenceParagraph(id: "missing", text: "此构建版本未包含开源许可声明文件：\(String(describing: error))",
                                 warning: true)
            }
        }
    }

    private func fileRow(_ title: String, _ file: String) -> some View {
        PadRow(id: LicencePage.text(file).row, title: title, accessory: .chevron, hint: "阅读") {
            AppNavigation.shared.openLicence(.text(file))
        }
    }
}

private struct LicenceComponentPage: View {
    let name: String

    var body: some View {
        VStack(spacing: 8) {
            if case .success(let licences) = BundledLicences.loaded,
               let component = licences.components.first(where: { $0.name == name }) {
                SettingsNote(text: "\(component.name) · \(component.licence)")
                SettingsInfoRow(id: "lic:head", title: component.name, value: component.licence)
                ForEach(component.files, id: \.self) { file in
                    PadRow(id: LicencePage.text(file).row, title: file, accessory: .chevron, hint: "阅读") {
                        AppNavigation.shared.openLicence(.text(file))
                    }
                }
            } else {
                LicenceParagraph(id: "head", text: "此构建版本的许可证列表中未找到 \(name)。", warning: true)
            }
        }
    }
}

private struct LicenceTextPage: View {
    let file: String
    @State private var paragraphs: [String]?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 8) {
            SettingsNote(text: file)
            if let failure {
                LicenceParagraph(id: "p:0", text: failure, warning: true)
            } else if let paragraphs {
                // Lazy: a long text draws the paragraphs near the ring, and the ring
                // moving down scrolls the next ones into being.
                LazyVStack(spacing: 8) {
                    ForEach(paragraphs.indices, id: \.self) { i in
                        LicenceParagraph(id: "p:\(i)", text: paragraphs[i], monospaced: true)
                    }
                }
            } else {
                // Keep the first row on the ring while the text loads. A spinner
                // left only the sidebar focusable, so the ring fell onto Steam
                // and B closed Settings instead of returning to the file list.
                LicenceParagraph(id: "p:0", text: "正在加载许可证全文…")
            }
        }
        .task(id: file) {
            guard case .success(let licences) = BundledLicences.loaded else {
                failure = "此构建版本未包含开源许可声明文件。"
                return
            }
            do {
                let p = Licences.paragraphs(try licences.text(of: file))
                if p.isEmpty { failure = "\(file) 内容为空。" } else { paragraphs = p }
            } catch {
                failure = "无法读取 \(file)：\(String(describing: error))"
            }
        }
    }
}
