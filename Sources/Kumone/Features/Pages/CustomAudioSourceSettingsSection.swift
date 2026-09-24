import SwiftUI
import UniformTypeIdentifiers

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
    @State private var draft = ""
    @State private var alertMessage: String?
    @State private var verifyingSourceKey: String?

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
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.javaScript, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
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
                alertMessage = String(localized: "脚本已成功初始化。\n\n声明的音源：\n") + summary
            } catch {
                alertMessage = error.localizedDescription
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
            alertMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // LX requires custom sources to be UTF-8, so a decode failure is
                // a real answer about the file rather than something to paper over.
                let script = try String(contentsOf: url, encoding: .utf8)
                performImport(script, fallbackName: url.deletingPathExtension().lastPathComponent)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func performImport(_ script: String, fallbackName: String) {
        do {
            let imported = try store.importScript(script, fallbackName: fallbackName)
            alertMessage = String(localized: "已导入：") + imported.name
                + "\n\n" + String(localized: "建议用右侧菜单的「测试连通性」确认脚本可用。")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { presented in if !presented { alertMessage = nil } }
        )
    }
}
