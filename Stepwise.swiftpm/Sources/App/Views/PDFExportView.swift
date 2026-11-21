import SwiftUI
import PDFKit

/// 选笔记和题集，排成一份 PDF，预览后分享或存到“文件”
struct PDFExportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var exporter = PDFExporter()
    @State private var selectedNotes: Set<UUID>
    @State private var selectedSets: Set<UUID>
    @AppStorage("pdfAnswers") private var answers = true
    @AppStorage("pdfMyWork") private var myWork = true
    @AppStorage("pdfFeedback") private var feedback = false
    @AppStorage("pdfTranscribe") private var transcribe = false
    @State private var result: URL?
    @State private var failure: String?
    /// 放在设置的导航里（没有自己的关闭按钮）还是单独弹出来
    let inSheet: Bool

    init(notes: Set<UUID> = [], sets: Set<UUID> = [], inSheet: Bool = false) {
        _selectedNotes = State(initialValue: notes)
        _selectedSets = State(initialValue: sets)
        self.inSheet = inSheet
    }

    var body: some View {
        Group {
            if let result {
                preview(result)
            } else {
                form
            }
        }
        .navigationTitle(result == nil ? L("导出 PDF") : result!.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayModeInline()
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? L("取消") : L("完成")) { dismiss() }
                        .disabled(exporter.phase != nil)
                }
            }
            if let result {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: result) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .alert("没能导出 PDF", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
        .interactiveDismissDisabled(exporter.phase != nil)
    }

    // MARK: 选择

    private var form: some View {
        let busy = exporter.phase != nil
        return Form {
            if !store.notes.isEmpty {
                Section {
                    ForEach(store.notes) { doc in
                        checkRow(doc.title, detail: String(localized: "\(doc.blocks.count) 块"), on: selectedNotes.contains(doc.id)) {
                            toggle(&selectedNotes, doc.id)
                        }
                    }
                } header: {
                    selectAllHeader(L("笔记"), all: Set(store.notes.map(\.id)), selection: $selectedNotes)
                }
            }
            if !store.questionSets.isEmpty {
                Section {
                    ForEach(store.questionSets) { set in
                        checkRow(set.title, detail: String(localized: "\(set.questions.count) 道题 · 已完成 \(set.doneCount)"),
                                 on: selectedSets.contains(set.id)) {
                            toggle(&selectedSets, set.id)
                        }
                    }
                } header: {
                    selectAllHeader(L("题集"), all: Set(store.questionSets.map(\.id)), selection: $selectedSets)
                }
            }
            if store.notes.isEmpty && store.questionSets.isEmpty {
                Text("还没有笔记或题集").foregroundStyle(.secondary)
            }

            Section {
                Toggle("参考答案和解析", isOn: $answers)
                Toggle("我的作答（手写和打字）", isOn: $myWork)
                Toggle("AI 的检查、提示和讲解", isOn: $feedback)
                Toggle(isOn: $transcribe) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 把手写转成文字")
                        Text(transcribeNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!canTranscribe)
            } header: {
                Text("包含")
            } footer: {
                Text("PDF 按 A4 排版（美国、加拿大用 Letter），文字和公式都是真正的文字，可以选中和搜索。手写作答和手写块以图片放入；笔记页面空白处的涂鸦不导出。")
            }

            Section {
                Button {
                    run()
                } label: {
                    HStack(spacing: 10) {
                        if busy { ProgressView() }
                        Text(exporter.phase ?? buttonTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(busy || (selectedNotes.isEmpty && selectedSets.isEmpty))
            }
        }
        .disabled(busy)
    }

    private var buttonTitle: String {
        let notes = store.notes.filter { selectedNotes.contains($0.id) }.count
        let sets = store.questionSets.filter { selectedSets.contains($0.id) }.count
        let parts = [notes == 0 ? nil : String(localized: "\(notes) 篇笔记"), sets == 0 ? nil : String(localized: "\(sets) 个题集")].compactMap { $0 }
        return parts.isEmpty ? L("请先选择笔记或题集") : L("生成 PDF：") + parts.joined(separator: L("、"))
    }

    private var canTranscribe: Bool { store.aiConsent == true && store.visionProvider != nil }

    private var transcribeNote: String {
        guard canTranscribe, let p = store.visionProvider else { return L("需要先在设置里填好一家服务商的 API Key") }
        return String(localized: "用 \(p.name) 的轻量识图模型（\(p.model)），每段手写一次请求，几段同时发，通常十几秒内完成")
    }

    private func checkRow(_ title: String, detail: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectAllHeader(_ title: String, all: Set<UUID>, selection: Binding<Set<UUID>>) -> some View {
        let allOn = !all.isEmpty && all.isSubset(of: selection.wrappedValue)
        return HStack {
            Text(title)
            Spacer()
            Button(allOn ? L("全不选") : L("全选")) {
                selection.wrappedValue = allOn ? [] : all
            }
            .font(.callout)
            .textCase(nil)
        }
    }

    private func toggle(_ set: inout Set<UUID>, _ id: UUID) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    private func run() {
        // 按左栏里的顺序
        let notes = store.notes.filter { selectedNotes.contains($0.id) }
        let sets = store.questionSets.filter { selectedSets.contains($0.id) }
        let options = PDFExportOptions(answers: answers, myWork: myWork, feedback: feedback, transcribe: transcribe && canTranscribe)
        Task {
            do {
                result = try await exporter.export(sets: sets, notes: notes, store: store, options: options)
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    // MARK: 预览

    private func preview(_ url: URL) -> some View {
        VStack(spacing: 0) {
            PDFPreview(url: url)
            HStack(spacing: 12) {
                Button {
                    result = nil
                } label: {
                    Label("重新选择", systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
                Spacer()
                ShareLink(item: url) {
                    Label("分享或存到“文件”", systemImage: "square.and.arrow.up")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.bar)
        }
    }
}

private extension View {
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#if os(iOS)
/// 生成好的 PDF 预览
struct PDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
#else
struct PDFPreview: View {
    let url: URL
    var body: some View { Text(url.lastPathComponent) }
}
#endif
