import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
#if os(iOS)
import WebKit
#endif

// MARK: - 导入资料生成笔记

/// 导入课件、讲义或教材（PDF / 图片 / 文本），按要求生成可编辑的笔记
struct NoteImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var material: ImportedMaterial?
    @State private var pastedText = ""
    @State private var pdfAsImages = false
    /// 程序根据自动判断结果同步开关时，不要触发重新渲染
    @State private var syncingToggle = false
    @State private var prompt = ""
    /// 出不出例题：不出 / 必要时出 / 更多例题；记住上次的选择
    @AppStorage("noteExerciseLevel") private var exerciseLevel: NoteExerciseLevel = .needed
    @State private var title = ""

    @State private var showFilePicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showSettings = false
    @State private var showConsent = false

    private static let examples = ["预习笔记：概念、公式和直观理解", "复习提纲：重点和易错点", "按章节整理", "只整理定义、定理和公式"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showFilePicker = true } label: {
                        Label("选择文件（PDF / 图片 / 文本）", systemImage: "folder")
                    }
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .images) {
                        Label("从相册选择图片", systemImage: "photo.on.rectangle")
                    }
                } header: {
                    Text("导入学习资料")
                } footer: {
                    Text("课件、讲义、教材都可以，用来预习或复习。")
                }

                if let material {
                    Section("已载入") {
                        HStack {
                            Image(systemName: material.images.isEmpty ? "doc.text" : "photo.stack")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(material.name).lineLimit(1)
                                Text(material.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { self.material = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                        if material.pdfData != nil {
                            Toggle(isOn: $pdfAsImages) {
                                VStack(alignment: .leading) {
                                    Text("按图片识别 PDF")
                                    Text("适合扫描件，或公式、图形多的资料；需要支持图片的模型")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .onChange(of: pdfAsImages) {
                                if syncingToggle { syncingToggle = false } else { reloadPDF() }
                            }
                        }
                    }
                } else {
                    Section("或者直接粘贴资料文字") {
                        TextEditor(text: $pastedText).frame(minHeight: 120)
                    }
                }

                Section {
                    TextField(Tutor.defaultNotePrompt, text: $prompt, axis: .vertical)
                        .lineLimit(2...6)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Self.examples, id: \.self) { ex in
                                Button(ex) { prompt = prompt.isEmpty ? ex : prompt + "；" + ex }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("怎么整理（可选）")
                }

                Section {
                    Picker("例题", selection: $exerciseLevel) {
                        ForEach(NoteExerciseLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("例题")
                } footer: {
                    Text(exerciseLevel.detail + "练习题下面就是手写区，可以直接批改。")
                }

                Section("笔记名称（可选，不填由 AI 起名）") {
                    TextField("例如：第三章 函数 复习", text: $title)
                }

                Section {
                    Button(action: start) {
                        HStack {
                            Spacer()
                            Label("生成笔记", systemImage: "sparkles").font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(currentMaterial == nil)
                } footer: {
                    if let p = store.noteProvider ?? store.activeProvider {
                        Text("将使用 \(p.name) · \(p.model.isEmpty ? "未选择模型" : p.model)。生成时会打开笔记，写完一块显示一块。"
                             + (store.noteProvider == nil ? "资料长时，可以在设置 → 笔记里单独选一个整理长资料能力强的模型。" : ""))
                    }
                }
            }
            .navigationTitle("生成笔记")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ModelMenu { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showConsent, onDismiss: {
                if store.aiConsent == true { start() }
            }) { ConsentView() }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: [.pdf, .image, .plainText, .text, .rtf],
                          allowsMultipleSelection: false) { result in
                handleFile(result)
            }
            .onChange(of: photoItems) { loadPhotos() }
        }
    }

    private var currentMaterial: ImportedMaterial? {
        if let material, !material.isEmpty { return material }
        let text = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : ImportedMaterial(name: "粘贴的资料", textPages: [text])
    }

    private func handleFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            material = try Importer.load(url: url)
            let detected = !(material?.images.isEmpty ?? true) && material?.pdfData != nil
            if detected != pdfAsImages {
                syncingToggle = true
                pdfAsImages = detected
            }
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func reloadPDF() {
        guard let m = material, let data = m.pdfData else { return }
        do {
            material = try Importer.loadPDF(data: data, name: m.name, mode: pdfAsImages ? .images : .text)
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func loadPhotos() {
        let items = photoItems
        guard !items.isEmpty else { return }
        Task {
            var images: [Data] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let jpeg = ImageUtil.normalizedJPEG(data) {
                    images.append(jpeg)
                }
            }
            photoItems = []
            if images.isEmpty {
                store.errorMessage = "没有读取到图片"
            } else {
                material = ImportedMaterial(name: "相册图片", images: images)
            }
        }
    }

    private func start() {
        guard let source = currentMaterial else { return }
        // 资料要发给 AI，先确认用户已同意
        guard store.aiConsent == true else {
            showConsent = true
            return
        }
        do {
            try store.startNoteGeneration(material: source, prompt: prompt, exercises: exerciseLevel, title: title)
            dismiss()
        } catch {
            if !(error is ConsentRequired) { store.errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - 笔记目录

/// 中间一栏：笔记的小标题和练习题，点哪里翻到哪里
struct NoteOutlineView: View {
    @EnvironmentObject var store: AppStore
    let noteID: UUID

    struct Item: Identifiable {
        let id: String
        let blockID: UUID
        let title: String
        let level: Int
        let icon: String?
    }

    var body: some View {
        if let doc = store.note(noteID) {
            List {
                Section {
                    ForEach(Self.outline(doc, store: store)) { item in
                        Button {
                            store.noteJump = item.blockID
                        } label: {
                            HStack(spacing: 8) {
                                if let icon = item.icon {
                                    Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(item.title)
                                    .font(item.level <= 2 ? .subheadline.weight(.semibold) : .subheadline)
                                    .foregroundStyle(item.level <= 2 ? Color.primary : Color.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.leading, CGFloat(max(item.level - 2, 0)) * 14)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    if store.noteJobs[noteID] != nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("正在生成…")
                        }
                    } else {
                        Text("目录")
                    }
                }
            }
            .navigationTitle(doc.title)
        }
    }

    /// 笔记块里的 Markdown 小标题作为目录；没有小标题的块用第一行
    static func outline(_ doc: NoteDoc, store: AppStore) -> [Item] {
        var items: [Item] = []
        var exerciseNumber = 0
        for block in doc.blocks {
            switch block.kind {
            case .text:
                let headings = block.text.components(separatedBy: "\n").compactMap { line -> (Int, String)? in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    let hashes = t.prefix { $0 == "#" }.count
                    guard hashes > 0, hashes <= 4 else { return nil }
                    return (hashes, String(t.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
                }
                if headings.isEmpty {
                    let first = block.text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                    if !first.isEmpty {
                        items.append(Item(id: block.id.uuidString, blockID: block.id, title: Tutor.plainPreview(first), level: 3, icon: nil))
                    }
                } else {
                    for (i, h) in headings.enumerated() {
                        items.append(Item(id: "\(block.id)-\(i)", blockID: block.id, title: Tutor.plainPreview(h.1), level: h.0, icon: nil))
                    }
                }
            case .exercise:
                exerciseNumber += 1
                let content = block.questionID.flatMap { store.question(doc.exerciseSetID, $0)?.content } ?? ""
                items.append(Item(id: block.id.uuidString, blockID: block.id,
                                  title: "练习 \(exerciseNumber)：" + Tutor.plainPreview(content), level: 3, icon: "pencil.and.list.clipboard"))
            case .answer:
                items.append(Item(id: block.id.uuidString, blockID: block.id,
                                  title: block.question ?? "提问", level: 4, icon: "questionmark.bubble"))
            }
        }
        return items
    }
}

// MARK: - 笔记文档

/// 笔记页：像文档一样一块一块往下排，每块可以直接编辑；选中文字可以提问；练习题下面就是手写批改区
struct NoteDocView: View {
    @EnvironmentObject var store: AppStore
    let noteID: UUID

    struct Selection: Equatable {
        var blockID: UUID
        var text: String
    }

    @StateObject private var ink = NotebookInk()
    @State private var width: CGFloat = 800
    @State private var editing: UUID?
    @State private var selection: Selection?
    @State private var showAskField = false
    @State private var askText = ""
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let doc = store.note(noteID) {
            let job = store.noteJobs[noteID]
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(doc, job: job)
                        ForEach(doc.blocks) { block in
                            blockView(block, in: doc)
                                .id(block.id)
                            // 出练习题时，在提问的那一块下面显示进度
                            if let job, job.afterBlock == block.id, block.kind != .answer {
                                progressRow(job)
                            }
                        }
                        if let job, job.afterBlock == nil {
                            generatingRow(job)
                        }
                        if job?.afterBlock == nil || job == nil {
                            addRow(doc)
                        }
                        // 给底部的工具条留位置
                        Color.clear.frame(height: 150)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                    // 页面宽时右边留出页边，圈出来问的批注写在那里
                    .frame(maxWidth: commentMargin == nil ? 900 : 1140)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: store.noteJump) {
                    guard let target = store.noteJump else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
                    store.noteJump = nil
                }
                // 练习题出的变式题点“去做这道题”：翻到那道练习题
                .onChange(of: store.selectedQuestionID) {
                    guard let qID = store.selectedQuestionID,
                          let block = doc.blocks.first(where: { b in
                              b.questionID.map { store.exerciseQuestions(noteID, $0).contains { $0.id == qID } } ?? false
                          }) else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(block.id, anchor: .top) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Ink.paper)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .overlay(alignment: .bottom) { bottomBar(doc, busy: job != nil) }
            .navigationTitle(doc.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        store.setFullScreen(!store.isFullScreen)
                    } label: {
                        Label(store.isFullScreen ? "显示目录" : "全屏",
                              systemImage: store.isFullScreen ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    ModelMenu { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onChange(of: scenePhase) {
                if scenePhase != .active { ink.saveAll() }
            }
            .onDisappear { ink.saveAll() }
            .onAppear { store.renumberExercises(noteID) }
        } else {
            ContentUnavailableView("笔记不存在", systemImage: "doc.richtext")
        }
    }

    /// 练习题手写区和页边批注够不够并排
    private var wide: Bool { min(width, 900) - 80 - 32 >= 760 }

    /// 笔记文字按固定的纸宽排版，再整体缩放到页面上：文字不会因为页面变宽变窄重新换行，
    /// 涂鸦、荧光笔和圈出来问的位置才能一直对得上
    private var paperScale: CGFloat {
        let column = min(width, commentMargin == nil ? 900 : 1140) - 80 - (commentMargin.map { $0 + 16 } ?? 0) - 40
        return min(max(column / NotePaper.width, 0.5), 1.25)
    }

    /// 页边批注的宽度；页面不够宽时为 nil，批注写在这一块下面
    private var commentMargin: CGFloat? { width >= 760 ? (width >= 1000 ? 260 : 210) : nil }

    // MARK: 标题

    private func header(_ doc: NoteDoc, job: NoteJob?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("笔记标题", text: Binding(get: { doc.title }, set: { store.renameNote(noteID, to: $0) }), axis: .vertical)
                .font(.largeTitle.bold())
            let source = [doc.sourceName.isEmpty ? nil : "来自 \(doc.sourceName)",
                          doc.prompt.isEmpty ? nil : "要求：\(doc.prompt)"].compactMap { $0 }
            if !source.isEmpty {
                Text(source.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !doc.blocks.isEmpty && job == nil {
                Text("选中文字可以提问；点每块右边的 ⋯ 编辑、插入或删除")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 块

    @ViewBuilder
    private func blockView(_ block: NoteBlock, in doc: NoteDoc) -> some View {
        switch block.kind {
        case .text, .answer:
            NoteTextBlockView(noteID: noteID, block: block, editing: $editing,
                              streaming: store.noteJobs[noteID]?.afterBlock == block.id,
                              busy: store.noteJobs[noteID] != nil,
                              ink: block.kind == .text && HandwritingModel.isAvailable ? ink.model(for: block.id) : nil,
                              comments: (doc.comments ?? []).filter { $0.blockID == block.id },
                              commentMargin: commentMargin,
                              paperScale: paperScale,
                              onSelect: { handleSelection($0, in: block.id) },
                              onExercises: { exercises(count: $0, after: block) }) {
                blockMenu(block, in: doc)
            }
        case .exercise:
            exerciseView(block, in: doc)
                // 练习题和有页边的文字块对齐
                .padding(.trailing, commentMargin.map { $0 + 16 } ?? 0)
        }
    }

    private func exerciseView(_ block: NoteBlock, in doc: NoteDoc) -> some View {
        VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("练习").font(.caption.weight(.semibold)).foregroundStyle(Ink.red)
                    Spacer()
                    blockMenu(block, in: doc)
                }
                .padding(.top, 12)
                ForEach(block.questionID.map { store.exerciseQuestions(noteID, $0) } ?? []) { q in
                    QuestionBlock(setID: doc.exerciseSetID, qID: q.id, model: ink.model(for: q.id),
                                  wide: wide, mistakeMode: false, nextID: nil)
                }
            }
            .padding(.horizontal, 16)
            // 像夹在笔记里的一张练习纸
            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
    }

    private func blockMenu(_ block: NoteBlock, in doc: NoteDoc) -> some View {
        let busy = store.noteJobs[noteID] != nil
        let index = doc.blocks.firstIndex { $0.id == block.id } ?? 0
        return Menu {
            if block.kind != .exercise {
                Button("编辑", systemImage: "pencil") { editing = block.id }
            }
            Button("在下面加笔记块", systemImage: "text.badge.plus") { addTextBlock(after: block.id) }
            Divider()
            Button("上移", systemImage: "arrow.up") { store.moveBlock(noteID, block.id, by: -1) }
                .disabled(index == 0)
            Button("下移", systemImage: "arrow.down") { store.moveBlock(noteID, block.id, by: 1) }
                .disabled(index == doc.blocks.count - 1)
            Button("删除", systemImage: "trash", role: .destructive) {
                if editing == block.id { editing = nil }
                store.deleteBlock(noteID, block.id)
            }
        } label: {
            Image(systemName: "ellipsis").font(.body).foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("这一块的操作")
    }

    private func addTextBlock(after: UUID?) {
        let block = NoteBlock(kind: .text)
        store.insertBlock(block, in: noteID, after: after)
        editing = block.id
    }

    private func addRow(_ doc: NoteDoc) -> some View {
        Button {
            addTextBlock(after: nil)
        } label: {
            Label(doc.blocks.isEmpty ? "写第一块笔记" : "加一块笔记", systemImage: "plus")
        }
        .buttonStyle(InkTextButtonStyle())
    }

    // MARK: 进度

    private func generatingRow(_ job: NoteJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !job.partial.isEmpty {
                // 正在写的这一块，写完就变成正式的笔记块
                RichText(job.partial).opacity(0.55)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(job.label).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("停止") { store.stopNoteJob(noteID) }
                    .buttonStyle(InkTextButtonStyle(color: .secondary))
            }
        }
    }

    private func progressRow(_ job: NoteJob) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(job.label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("停止") { store.stopNoteJob(noteID) }
                .buttonStyle(InkTextButtonStyle(color: .secondary))
        }
    }

    // MARK: 选中提问

    private func handleSelection(_ text: String, in blockID: UUID) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if selection?.blockID == blockID { selection = nil }
        } else {
            selection = Selection(blockID: blockID, text: text)
        }
    }

    private func ask(_ option: Tutor.NoteAskOption, about sel: Selection) {
        store.askNote(noteID, blockID: sel.blockID, selection: sel.text,
                      title: option.title, prompt: option.prompt, exerciseCount: option.makesExercise ? 1 : 0)
        selection = nil
    }

    /// 小节下面的“出例题”：针对整个小节出几道练习题，插在这一小节后面
    private func exercises(count: Int, after block: NoteBlock) {
        store.askNote(noteID, blockID: block.id, selection: Tutor.clip(block.text, 600), title: "出例题",
                      prompt: "请针对这一小节的内容出 \(count) 道练习题。", exerciseCount: count)
    }

    @ViewBuilder
    private func bottomBar(_ doc: NoteDoc, busy: Bool) -> some View {
        VStack(spacing: 10) {
            if let sel = selection {
                askBar(sel, busy: busy)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // 笔记上可以直接涂鸦、画荧光笔，练习题要手写：工具条一直在
            if HandwritingModel.isAvailable {
                InkPalette(tools: ink.tools)
            }
        }
        .padding(.bottom, 14)
        .animation(.easeInOut(duration: 0.2), value: selection)
    }

    /// 选中文字后浮出来的固定选项
    private func askBar(_ sel: Selection, busy: Bool) -> some View {
        HStack(spacing: 16) {
            Text("“\(Tutor.clip(sel.text.replacingOccurrences(of: "\n", with: " "), 24))”")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            ForEach(Tutor.noteAskOptions) { option in
                Button(option.title) { ask(option, about: sel) }
                    .lineLimit(1)
                    .fixedSize()
            }
            Button("提问…") { showAskField = true }
                .popover(isPresented: $showAskField) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("关于选中的内容").font(.headline)
                        TextField("想问什么…", text: $askText, axis: .vertical)
                            .lineLimit(2...5)
                            .padding(10)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        Button {
                            let question = askText.trimmingCharacters(in: .whitespacesAndNewlines)
                            ask(Tutor.NoteAskOption(title: question, prompt: question), about: sel)
                            askText = ""
                            showAskField = false
                        } label: {
                            Text("发送").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(18)
                    .frame(width: 360)
                }
            Button {
                selection = nil
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(InkTextButtonStyle(color: .secondary))
            .accessibilityLabel("取消")
        }
        .buttonStyle(InkTextButtonStyle())
        .disabled(busy)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

// MARK: - 文字块

/// 一块笔记：平时排版显示（可以选中文字提问），编辑时是原文（Markdown + LaTeX）
struct NoteTextBlockView<MenuContent: View>: View {
    @EnvironmentObject var store: AppStore
    let noteID: UUID
    let block: NoteBlock
    @Binding var editing: UUID?
    /// 回答正在写
    let streaming: Bool
    /// 有 AI 任务在进行，不能再出题
    let busy: Bool
    /// 这一块上的涂鸦（笔、荧光笔）；为 nil 时不能涂鸦
    let ink: HandwritingModel?
    /// 圈在这一块上的页边批注
    let comments: [NoteComment]
    /// 页边宽度；为 nil 时批注写在这一块下面
    let commentMargin: CGFloat?
    /// 笔记文字（纸宽固定）缩放到页面上的比例
    let paperScale: CGFloat
    let onSelect: (String) -> Void
    /// 小节下面的“出例题”，参数是出几道
    let onExercises: (Int) -> Void
    @ViewBuilder let menu: () -> MenuContent

    @State private var draft = ""
    @FocusState private var focused: Bool
    /// 文字视图，涂鸦层把书写手势挂上去
    @State private var inkHost = InkHost()

    private var isEditing: Bool { editing == block.id }

    var body: some View {
        // 页面宽时批注写在右边页边，和这一块顶端对齐；窄时写在这一块下面
        if let commentMargin {
            // 批注浮在页边，不占版面：长批注往下延伸也不会把下面的笔记推开
            content
                .padding(.trailing, commentMargin + 16)
                .overlay(alignment: .topTrailing) {
                    commentColumn.frame(width: commentMargin, alignment: .leading)
                }
                .zIndex(comments.isEmpty ? 0 : 1)
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                content
                commentColumn.frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var commentColumn: some View {
        if !comments.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(comments.enumerated()), id: \.element.id) { i, comment in
                    NoteCommentView(noteID: noteID, comment: comment, number: i + 1)
                }
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if block.kind == .answer {
                    answerHeader
                }
                if isEditing {
                    TextField("写点什么…（支持 Markdown，公式写在 $ $ 里）", text: $draft, axis: .vertical)
                        .focused($focused)
                        .lineLimit(2...)
                        .padding(10)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        if draft.contains("$") {
                            Text("公式会在完成后排版").font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("完成") { commit() }
                            .buttonStyle(InkTextButtonStyle())
                    }
                } else if block.text.isEmpty {
                    if streaming {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在回答…").font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("空白笔记块，点这里开始写") { editing = block.id }
                            .buttonStyle(InkTextButtonStyle(color: .secondary))
                    }
                } else {
                    RichText(block.text, onSelect: onSelect, host: inkHost)
                        // 圈出来问过的地方：淡淡的虚线框和序号，对应页边的批注
                        .overlay(alignment: .topLeading) { circledMarks }
                        // 涂鸦层盖在文字上：笔写字、画荧光笔；手指照样能选字、翻页
                        .overlay {
                            if let ink {
                                NotebookCanvas(model: ink, tools: ink.tools, host: inkHost)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if let ink {
                                CircleAskAnchor(ink: ink, busy: busy) { send($0, ink: ink) }
                            }
                        }
                        .modifier(NotePaper(scale: paperScale))
                    // 每个小节下面可以出几道例题
                    if block.kind == .text {
                        HStack {
                            Spacer()
                            Menu {
                                ForEach(1...3, id: \.self) { n in
                                    Button("出 \(n) 道") { onExercises(n) }
                                }
                            } label: {
                                Label("出例题", systemImage: "pencil.and.list.clipboard")
                                    .font(.caption)
                                    .foregroundStyle(busy ? Color.secondary : Ink.pen)
                            }
                            .disabled(busy)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(AnswerRule(isAnswer: block.kind == .answer))
            if !isEditing { menu() }
        }
        .onAppear { if isEditing { startEditing() } }
        .onChange(of: isEditing) { if isEditing { startEditing() } }
        // 点到别处就保存
        .onChange(of: focused) { if !focused && isEditing { commit() } }
    }

    /// 页边批注对应的圈：收起的批注不画
    private var circledMarks: some View {
        Canvas { context, _ in
            for (i, comment) in comments.enumerated() where !comment.minimized {
                let box = Path(roundedRect: comment.region.rect, cornerRadius: 8)
                context.stroke(box, with: .color(Ink.blue.opacity(0.5)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                let label = context.resolve(Text("\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundColor(Ink.blue))
                context.draw(label, at: CGPoint(x: comment.region.rect.maxX + 6, y: comment.region.rect.minY + 4), anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    private func send(_ question: String, ink: HandwritingModel) {
        guard let region = ink.circledRegion else { return }
        let ask = { (image: Data?) in
            store.askCircled(noteID, blockID: block.id, region: InkRegion(region), question: question, image: image)
        }
        #if os(iOS)
        // 把圈住的那一小段（排版后的文字和公式，加上上面的笔迹）截图发给 AI
        guard let web = inkHost.view as? WKWebView else { ask(nil); return }
        let config = WKSnapshotConfiguration()
        config.rect = region.intersection(web.bounds)
        let strokes = ink.drawingImage(in: config.rect)
        web.takeSnapshot(with: config) { image, _ in
            guard let image else { ask(nil); return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let combined = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                UIColor.white.setFill()
                UIRectFill(CGRect(origin: .zero, size: image.size))
                image.draw(at: .zero)
                strokes?.draw(in: CGRect(origin: .zero, size: image.size))
            }
            ask(combined.jpegData(compressionQuality: 0.85).flatMap { ImageUtil.normalizedJPEG($0, maxPixel: 1280) })
        }
        #else
        ask(nil)
        #endif
    }

    private var answerHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(block.question ?? "提问").font(.caption.weight(.semibold)).foregroundStyle(Ink.blue)
            if let quote = block.quote, !quote.isEmpty {
                Text("“\(Tutor.clip(quote.replacingOccurrences(of: "\n", with: " "), 60))”")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func startEditing() {
        draft = block.text
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        store.updateBlockText(noteID, block.id, draft.trimmingCharacters(in: .whitespacesAndNewlines))
        if editing == block.id { editing = nil }
    }
}

/// AI 回答的块：左边一道蓝笔竖线，和自己写的笔记区分开
private struct AnswerRule: ViewModifier {
    let isAnswer: Bool
    func body(content: Content) -> some View {
        if isAnswer { content.marginRule(Ink.blue) } else { content }
    }
}

/// 圈完一处：在圈住的地方画虚线框，从那里弹出提问框
private struct CircleAskAnchor: View {
    @ObservedObject var ink: HandwritingModel
    let busy: Bool
    let send: (String) -> Void
    @State private var showAsk = false

    var body: some View {
        let r = ink.circledRegion ?? .zero
        ZStack(alignment: .topLeading) {
            Color.clear
            if ink.circledRegion != nil {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Ink.blue.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }
            Color.clear
                .frame(width: max(r.width, 1), height: max(r.height, 1))
                .padding(.leading, max(0, r.minX))
                .padding(.top, max(0, r.minY))
                .popover(isPresented: $showAsk) {
                    CircleAskPopover(busy: busy) { question in
                        send(question)
                        showAsk = false
                    }
                    .onDisappear { ink.circledRegion = nil }
                }
        }
        .allowsHitTesting(false)
        .onChange(of: ink.circledRegion) {
            guard ink.circledRegion != nil else { return }
            // 等圈的那一笔抬起来再弹出，否则会被同一次触摸关掉
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if ink.circledRegion != nil { showAsk = true }
            }
        }
    }
}

/// 圈完一处后弹出：常用问题，或者写下想问的（可以直接用 Apple Pencil 写，系统转成文字）
private struct CircleAskPopover: View {
    let busy: Bool
    let send: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    static let quick = ["这是什么意思？", "为什么是这样？", "举个例子", "和前面有什么联系？"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("问圈出来的这段").font(.headline)
            TextField("想问什么…", text: $text, axis: .vertical)
                .focused($focused)
                .lineLimit(1...4)
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .onSubmit { submit(text) }
            FlowLayout(spacing: 14) {
                ForEach(Self.quick, id: \.self) { q in
                    Button(q) { submit(q) }
                }
            }
            .buttonStyle(InkTextButtonStyle())
            Button { submit(text) } label: {
                Text("发送").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if busy {
                Text("正在回答上一个问题，稍等一下").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 360)
        // 直接打字：弹出就聚焦输入框
        .onAppear { focused = true }
    }

    private func submit(_ q: String) {
        guard !busy, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(q)
    }
}

/// 页边的一条批注：小字、支持 LaTeX；双击放大；可以记到笔记里；收起成一个小对话图标
struct NoteCommentView: View {
    @EnvironmentObject var store: AppStore
    let noteID: UUID
    let comment: NoteComment
    let number: Int
    @State private var enlarged = false

    private var streaming: Bool { store.noteJobs[noteID]?.commentID == comment.id }

    var body: some View {
        if comment.minimized {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { store.mutateComment(noteID, comment.id) { $0.minimized = false } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.fill")
                    Text("\(number)").font(.caption2.weight(.bold))
                }
                .font(.callout)
                .foregroundStyle(Ink.blue.opacity(0.8))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Ink.blue.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展开批注 \(number)")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(number)").font(.caption2.weight(.bold)).foregroundStyle(Ink.blue)
                    Text(comment.question).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                    if !streaming && !comment.answer.isEmpty {
                        Menu {
                            Button("放大查看", systemImage: "arrow.up.left.and.arrow.down.right") { enlarged = true }
                            Button("删除批注", systemImage: "trash", role: .destructive) { store.deleteComment(noteID, comment.id) }
                        } label: {
                            Image(systemName: "ellipsis").font(.caption).foregroundStyle(.secondary).frame(width: 22, height: 18)
                        }
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { store.mutateComment(noteID, comment.id) { $0.minimized = true } }
                    } label: {
                        Image(systemName: "minus").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(InkTextButtonStyle(color: .secondary))
                    .accessibilityLabel("收起批注")
                }
                if comment.answer.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在写…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    RichText(comment.answer, scale: 0.82)
                        // 文字显示在网页视图里，点击会被它吃掉：盖一层透明的来接双击
                        .overlay {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { enlarged = true }
                        }
                }
                if !streaming && !comment.answer.isEmpty {
                    if comment.savedToNote {
                        Label("已记到笔记", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            store.saveCommentToNote(noteID, comment.id)
                        } label: {
                            Label("把这个点记到笔记中", systemImage: "plus").font(.caption.weight(.medium))
                        }
                        .buttonStyle(InkTextButtonStyle())
                    }
                }
            }
            .padding(10)
            .background(Ink.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                Rectangle().fill(Ink.blue.opacity(0.5)).frame(width: 2).padding(.vertical, 8)
            }
            .sheet(isPresented: $enlarged) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(comment.question).font(.title3.weight(.semibold))
                            RichText(comment.answer, scale: 1.15)
                        }
                        .padding(24)
                    }
                    .navigationTitle("批注 \(number)")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("关闭") { enlarged = false } }
                        if !comment.savedToNote {
                            ToolbarItem(placement: .primaryAction) {
                                Button("记到笔记中") {
                                    store.saveCommentToNote(noteID, comment.id)
                                    enlarged = false
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// 笔记文字的“纸”：固定宽度排版，整体缩放到页面上，占位大小跟着缩放
struct NotePaper: ViewModifier {
    static let width: CGFloat = 520
    let scale: CGFloat

    func body(content: Content) -> some View {
        PaperLayout(width: Self.width, scale: scale) {
            content.scaleEffect(scale, anchor: .topLeading)
        }
    }
}

/// 按纸宽给里面的内容排版，对外报告缩放后的大小
private struct PaperLayout: Layout {
    let width: CGFloat
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        return CGSize(width: width * scale, height: height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
    }
}
