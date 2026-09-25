import CoreFoundation
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// The 自定义音源 block in Settings: import, enable, reorder, verify and delete
/// LX-Music-compatible scripts.
///
/// A row's switch is the script's one and only switch. `CustomAudioSourceStore`
/// mirrors it into `SettingsManager.enabledAudioSourceIDs`, which is what
/// playback actually reads.
struct CustomAudioSourceSettingsSection: View {
    @ObservedObject var store: CustomAudioSourceStore

    @State private var isPasting = false
    @State private var isChoosingFile = false
    @State private var isImportingURL = false
    @State private var urlDraft = ""
    @State private var draft = ""
    @State private var alertMessage: String?
    @State private var status: ImportStatus?
    @State private var verifyingSourceKey: String?

    /// The last import/verify outcome, rendered **inline** rather than only in an
    /// alert.
    ///
    /// Two separate routes have to report, and both used to be able to fail
    /// silently: an alert raised while the picker is still dismissing is dropped
    /// by SwiftUI, and a read of a security-scoped URL outside its access window
    /// throws somewhere nobody sees. A row inside the section cannot be
    /// swallowed, so the user always gets an answer even when the alert is lost.
    private struct ImportStatus: Equatable {
        var text: String
        var isError: Bool
    }

    var body: some View {
        Section {
            if store.sources.isEmpty {
                Text("还没有导入自定义音源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(store.sources) { source in
                HStack(spacing: 8) {
                    Toggle(isOn: enabledBinding(for: source)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(source.name)
                                if verifyingSourceKey == source.id {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            if let detail = detailLine(for: source) {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let failure = source.lastError {
                                Text(failure)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    actionsMenu(for: source)
                }
            }

            Button("粘贴脚本导入…") {
                draft = ""
                isPasting = true
            }
            Button("从文件导入…") {
                isChoosingFile = true
            }
            Button("从链接导入…") {
                urlDraft = ""
                isImportingURL = true
            }

            if let status {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: status.isError
                          ? "exclamationmark.triangle.fill"
                          : "checkmark.circle.fill")
                        .foregroundStyle(status.isError ? Color.red : Color.green)
                    Text(status.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("自定义音源")
        } footer: {
            Text("兼容 LX Music 自定义源脚本，音源按列表顺序依次尝试。脚本在本机运行、可以发起任意网络请求，请只导入你信任的来源。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $isPasting) {
            pasteSheet
        }
        .sheet(isPresented: $isImportingURL) {
            urlImportSheet
        }
        #if os(iOS)
        // `UIDocumentPickerViewController` with `asCopy: true` — deliberately
        // *not* SwiftUI's `fileImporter`.
        //
        // The copy is the whole point. A `fileImporter` vends a
        // security-scoped URL, and reading one outside the matching
        // `startAccessingSecurityScopedResource()` window fails; when that
        // failure also gets dropped on the way to the UI, the user is left with
        // "I picked a file and absolutely nothing happened". `asCopy: true`
        // hands back a URL inside the app's own container instead, so the read
        // is an ordinary file read that cannot be denied — and for a source
        // script of a few tens of kilobytes the copy costs nothing.
        .fullScreenCover(isPresented: $isChoosingFile) {
            SourceDocumentPicker(
                onPick: { url in
                    isChoosingFile = false
                    readAndImport(url)
                },
                onCancel: { isChoosingFile = false }
            )
            .ignoresSafeArea()
        }
        #else
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.javaScript, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        #endif
        .alert("自定义音源", isPresented: alertBinding) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Rows

    private func enabledBinding(for source: CustomAudioSource) -> Binding<Bool> {
        Binding(
            get: { source.isEnabled },
            set: { store.setEnabled($0, forScriptKey: source.id) }
        )
    }

    private func detailLine(for source: CustomAudioSource) -> String? {
        var parts: [String] = []
        if let author = source.author, !author.isEmpty { parts.append(author) }
        if let version = source.version, !version.isEmpty { parts.append("v\(version)") }
        if !source.declaredQualityLabels.isEmpty {
            parts.append(source.declaredQualityLabels.joined(separator: " / "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func actionsMenu(for source: CustomAudioSource) -> some View {
        Menu {
            Button("测试连通性") { verify(source) }
            Button("上移") { move(source, by: -1) }
                .disabled(store.sources.first?.id == source.id)
            Button("下移") { move(source, by: 1) }
                .disabled(store.sources.last?.id == source.id)
            Divider()
            Button("删除", role: .destructive) { store.remove(scriptKey: source.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func move(_ source: CustomAudioSource, by offset: Int) {
        guard let index = store.sources.firstIndex(where: { $0.id == source.id }) else { return }
        store.move(scriptKey: source.id, toIndex: index + offset)
    }

    private func verify(_ source: CustomAudioSource) {
        verifyingSourceKey = source.id
        Task {
            do {
                let summary = try await store.verify(scriptKey: source.id)
                report(
                    String(localized: "脚本已成功初始化。声明的音源：\n") + summary,
                    isError: false
                )
            } catch {
                report(error.localizedDescription, isError: true)
            }
            verifyingSourceKey = nil
        }
    }

    // MARK: - Import

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("粘贴 LX 自定义源脚本")
                .font(.headline)
            Text("脚本头部需保留 @name / @author 等注释，格式与 LX Music 一致。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 260)
                #if os(macOS)
                // Only macOS wants a floor on the width: on iPhone a 460pt
                // minimum would overflow the sheet.
                .frame(minWidth: 460)
                #endif
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )

            HStack {
                Spacer()
                Button("取消") { isPasting = false }
                Button("导入") {
                    performImport(draft, fallbackName: String(localized: "未命名音源"))
                    isPasting = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            report(String(localized: "打开文件失败：") + error.localizedDescription, isError: true)
        case .success(let urls):
            guard let url = urls.first else {
                report(String(localized: "没有选中任何文件。"), isError: true)
                return
            }
            readAndImport(url)
        }
    }

    /// Reads a picked file and hands its contents to the importer.
    ///
    /// Shared by the iOS document picker and macOS's `fileImporter`. The
    /// security-scope calls are kept even though the iOS picker copies the file
    /// into the app first: they cost nothing when the URL is not scoped, and
    /// they keep the read correct if the picker's behaviour ever changes.
    private func readAndImport(_ url: URL) {
        let fileName = url.lastPathComponent.isEmpty
            ? String(localized: "未命名文件")
            : url.lastPathComponent
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            report(
                String(localized: "读不到这个文件：") + fileName
                    + "\n" + error.localizedDescription,
                isError: true
            )
            return
        }
        guard !data.isEmpty else {
            report(String(localized: "文件是空的：") + fileName, isError: true)
            return
        }

        // LX only promises UTF-8, but scripts written on Windows are very
        // often GB18030/GBK, and rejecting those outright is what made a
        // perfectly good script look like "nothing happened".
        let decoded = Self.decode(data)
        let fallbackName = url.deletingPathExtension().lastPathComponent
        var note = String(localized: "文件：") + fileName
            + "（\(data.count) " + String(localized: "字节") + "）"
        if let warning = decoded.warning {
            note += "\n" + warning
        }
        performImport(decoded.script, fallbackName: fallbackName, note: note)
    }

    private var urlImportSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从链接导入音源")
                .font(.headline)
            Text("填一个直接指向脚本文本的地址（GitHub 的 raw 链接也可以）。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("https://example.com/source.js", text: $urlDraft)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("取消") { isImportingURL = false }
                Button("导入") {
                    let address = urlDraft
                    isImportingURL = false
                    importRemote(address)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    /// Downloads a source from a URL.
    ///
    /// Worth having alongside the file picker: published sources live on GitHub
    /// and forum attachments, and getting one onto the phone is normally
    /// download → save to Files → pick. A raw URL is one paste, and it is the
    /// only route that works when the hosting site hands the file to a browser
    /// rather than to the Files app.
    private func importRemote(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            report(String(localized: "链接无效：") + trimmed, isError: true)
            return
        }

        report(String(localized: "正在下载：") + trimmed, isError: false)

        Task { @MainActor in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    report(
                        String(localized: "下载失败：HTTP ") + "\(http.statusCode)",
                        isError: true
                    )
                    return
                }
                guard !data.isEmpty else {
                    report(String(localized: "下载到的内容是空的。"), isError: true)
                    return
                }
                let decoded = Self.decode(data)
                let fallbackName = url.deletingPathExtension().lastPathComponent
                var note = String(localized: "来源：") + trimmed
                    + "（\(data.count) " + String(localized: "字节") + "）"
                if let warning = decoded.warning {
                    note += "\n" + warning
                }
                performImport(decoded.script, fallbackName: fallbackName, note: note)
            } catch {
                report(
                    String(localized: "下载失败：") + error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    private func performImport(
        _ script: String,
        fallbackName: String,
        note: String? = nil
    ) {
        do {
            let imported = try store.importScript(script, fallbackName: fallbackName)
            var message = String(localized: "已导入：") + imported.name
            if let note { message += "\n" + note }
            message += "\n\n" + String(localized: "建议用右侧菜单的「测试连通性」确认脚本可用。")
            report(message, isError: false)
        } catch {
            report(String(localized: "导入失败：") + error.localizedDescription, isError: true)
        }
    }

    /// Turns the file's bytes into a script, trying the encodings people
    /// actually save these files in.
    ///
    /// The last resort uses `String(decoding:as:)`, which cannot fail: the
    /// JavaScript itself is ASCII, so at worst only the Chinese `@name` comments
    /// come out garbled — still far better than refusing a usable script.
    private static func decode(_ data: Data) -> (script: String, warning: String?) {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }

        if let text = String(data: bytes, encoding: .utf8) {
            return (text, nil)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
           let text = String(data: bytes, encoding: .utf16) {
            return (text, nil)
        }

        // Same encoding helper `LXScriptRuntime` uses for unlabelled GBK HTTP
        // payloads. GB18030 covers GBK and GB2312 too, so one attempt handles
        // every Chinese code page these scripts are saved in.
        let gb = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        if let text = String(data: bytes, encoding: gb) {
            return (
                text,
                String(localized: "⚠️ 文件不是 UTF-8 编码，已按 GBK/GB18030 读取。")
            )
        }

        return (
            String(decoding: bytes, as: UTF8.self),
            String(localized: "⚠️ 文件编码无法识别，脚本名可能显示异常，但脚本本身仍可使用。")
        )
    }

    /// Single feedback path: an inline row (cannot be swallowed) plus a delayed
    /// alert (nicer to notice, but only fired once the picker has finished
    /// dismissing — raising one in the same tick loses it).
    private func report(_ text: String, isError: Bool) {
        status = ImportStatus(text: text, isError: isError)
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            alertMessage = text
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { presented in if !presented { alertMessage = nil } }
        )
    }
}

#if os(iOS)
/// The iOS document picker, copied into the app's container on the way in.
///
/// `asCopy: true` is doing the real work — see the note where this is
/// presented. `UTType.item` sits alongside the specific types so a script saved
/// with an unexpected extension (`.js.txt`, or none at all) stays selectable;
/// whether the contents are a usable script is the importer's decision, not the
/// file type's.
private struct SourceDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.javaScript, .json, .plainText, .item],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: SourceDocumentPicker

        init(_ parent: SourceDocumentPicker) {
            self.parent = parent
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
#endif
