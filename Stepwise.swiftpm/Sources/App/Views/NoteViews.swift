import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
    /// 固定选项：在没有例题的重要知识点后面加练习题和手写批改区
    @State private var withExercises = true
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
                    Toggle(isOn: $withExercises) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("需要例题")
                            Text("资料里没有例题的重要知识点后面，加一道练习题和手写批改区")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
                    if let p = store.activeProvider {
                        Text("将使用 \(p.name) · \(p.model.isEmpty ? "未选择模型" : p.model)。生成时会打开笔记，写完一块显示一块。")
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
            try store.startNoteGeneration(material: source, prompt: prompt, exercises: withExercises, title: title)
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
                    .frame(maxWidth: 900)
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
                              onSelect: { handleSelection($0, in: block.id) }) {
                blockMenu(block, in: doc)
            }
        case .exercise:
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
    }

    private func blockMenu(_ block: NoteBlock, in doc: NoteDoc) -> some View {
        let busy = store.noteJobs[noteID] != nil
        let index = doc.blocks.firstIndex { $0.id == block.id } ?? 0
        return Menu {
            if block.kind != .exercise {
                Button("编辑", systemImage: "pencil") { editing = block.id }
            }
            Button("在下面加笔记块", systemImage: "text.badge.plus") { addTextBlock(after: block.id) }
            Button("在下面出一道练习题", systemImage: "pencil.and.list.clipboard") {
                askAboutBlock(block, option: Tutor.noteAskOptions.first { $0.makesExercise }!)
            }
            .disabled(busy)
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
                      title: option.title, prompt: option.prompt, makesExercise: option.makesExercise)
        selection = nil
    }

    /// 对整块提问（块菜单里“出一道练习题”）
    private func askAboutBlock(_ block: NoteBlock, option: Tutor.NoteAskOption) {
        var text = block.text
        if block.kind == .exercise, let qID = block.questionID, let doc = store.note(noteID) {
            text = store.question(doc.exerciseSetID, qID)?.content ?? ""
        }
        ask(option, about: Selection(blockID: block.id, text: Tutor.clip(text, 600)))
    }

    @ViewBuilder
    private func bottomBar(_ doc: NoteDoc, busy: Bool) -> some View {
        VStack(spacing: 10) {
            if let sel = selection {
                askBar(sel, busy: busy)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if HandwritingModel.isAvailable && doc.blocks.contains(where: { $0.kind == .exercise }) {
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
    let onSelect: (String) -> Void
    @ViewBuilder let menu: () -> MenuContent

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isEditing: Bool { editing == block.id }

    var body: some View {
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
                    RichText(block.text, onSelect: onSelect)
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
