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
    /// 放到哪个文件夹；默认是当前打开的题集所在的文件夹
    @State private var folderID: UUID?
    @State private var folderInitialized = false

    @State private var showFilePicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showSettings = false
    @State private var showConsent = false

    private static let examples = [L("预习笔记：概念、公式和直观理解"), L("复习提纲：重点和易错点"), L("按章节整理"), L("只整理定义、定理和公式")]

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
                    Text(exerciseLevel.detail + L("练习题下面就是手写区，写完可以直接检查。"))
                }

                Section {
                    TextField("例如：第三章 函数 复习", text: $title)
                    if !store.folders.isEmpty {
                        Picker("放到文件夹", selection: $folderID) {
                            Text("最外层").tag(UUID?.none)
                            ForEach(store.folderTree(), id: \.folder.id) { item in
                                Text(String(repeating: "    ", count: item.depth) + item.folder.name).tag(Optional(item.folder.id))
                            }
                        }
                        .onAppear {
                            guard !folderInitialized else { return }
                            folderInitialized = true
                            folderID = store.set(store.selectedSetID)?.folderID.flatMap { store.folder($0)?.id }
                        }
                    }
                } header: {
                    Text("笔记名称（可选，不填由 AI 起名）")
                } footer: {
                    if !store.folders.isEmpty {
                        Text("和题集放在同一个文件夹，做里面的题卡住时会先引导你看这篇笔记。")
                    }
                }

                // 生成笔记单独用一个模型（和设置 → 笔记里的是同一个设置）
                Section {
                    ModelOverrideRows(title: L("整理笔记模型"), providerID: $store.noteProviderID, model: $store.noteModel,
                                      resolved: store.noteProvider, recommend: .longContext)
                } header: {
                    Text("用哪个模型生成")
                } footer: {
                    Text("资料长、公式多时，建议选上下文长、能看图的模型，推荐的排在模型列表最上面。不选就用当前模型。")
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
        return text.isEmpty ? nil : ImportedMaterial(name: L("粘贴的资料"), textPages: [text])
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
                store.errorMessage = L("没有读取到图片")
            } else {
                material = ImportedMaterial(name: L("相册图片"), images: images)
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
            try store.startNoteGeneration(material: source, prompt: prompt, exercises: exerciseLevel, title: title,
                                          folderID: folderID)
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
                                  title: String(localized: "练习 \(exerciseNumber)：") + Tutor.plainPreview(content), level: 3, icon: "pencil.and.list.clipboard"))
            case .answer:
                items.append(Item(id: block.id.uuidString, blockID: block.id,
                                  title: block.question ?? L("提问"), level: 4, icon: "questionmark.bubble"))
            case .canvas:
                items.append(Item(id: block.id.uuidString, blockID: block.id, title: L("手写"), level: 3, icon: "scribble"))
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
    /// 先当作很窄：第一次排版不会把页面撑宽，量到实际宽度后再按实际排
    @State private var width: CGFloat = 0
    /// 页面看得见的高度：内容不满一屏时，下面的空白也能写
    @State private var viewHeight: CGFloat = 0
    /// 整页涂鸦层的位置（页边、块和块之间也能写）
    @State private var pageInk = PageInkLayout()
    @State private var editing: UUID?
    /// 正在圈出来问的那一块：提问框在页边，页边要展开
    @State private var askingBlock: UUID?
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
                                // 记下每一块的位置：空白处的笔迹跟着它上面那一块挪
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pageSpace)) } action: { [scale = paperScale(doc)] frame in
                                    pageInk.blockFrames[block.id] = (frame, scale)
                                    pageInk.scheduleSettle { settlePageInk() }
                                }
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
                    // 正文居中；页边有展开的批注时，正文和批注一起居中，正文往左让出位置
                    .frame(width: columnWidth(doc), alignment: .leading)
                    .padding(.horizontal, pagePadding)
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: viewHeight, alignment: .top)
                    .coordinateSpace(name: Self.pageSpace)
                    // 整页涂鸦的书写手势挂在最底下这一层：笔落在空白处写到整页上
                    .background {
                        if HandwritingModel.isAvailable { PageInkHost(layout: pageInk) }
                    }
                    .animation(.easeInOut(duration: 0.25), value: marginOpen(doc))
                }
                // 整页涂鸦的笔迹盖在看得见的这一块上，跟着页面滚动
                .overlay {
                    if HandwritingModel.isAvailable {
                        PageInkCanvas(model: ink.pageModel(for: noteID), tools: ink.tools, layout: pageInk,
                                      textLeft: (width - columnWidth(doc)) / 2, scale: paperScale(doc), paper: doc.paper)
                            .allowsHitTesting(false)
                    }
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
            .onGeometryChange(for: CGSize.self) { $0.size } action: { width = $0.width; viewHeight = $0.height }
            // 页面变宽变窄（缩放比例跟着变）、删掉一块：空白处的笔迹也要重新对上
            .onChange(of: width) { pageInk.scheduleSettle { settlePageInk() } }
            .onChange(of: doc.blocks.map(\.id)) { pageInk.scheduleSettle { settlePageInk() } }
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
                        Label(store.isFullScreen ? L("显示目录") : L("全屏"),
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
            // 问答补进笔记、插在一块中间：这一块插入点下面的笔迹跟着往下挪
            .onReceive(NotificationCenter.default.publisher(for: .noteInkShift)) { note in
                guard let request = note.object as? InkShiftRequest,
                      let model = ink.existingModel(for: request.blockID) else { return }
                model.shiftStrokes(below: request.below, by: request.by)
                request.handled = true
            }
            .onAppear {
                store.upgradePaperIfClean(noteID)
                store.renumberExercises(noteID)
                // 空白处写了、擦了：按现在的排版记下笔迹的位置
                let model = ink.pageModel(for: noteID)
                model.onDrawingChanged = { [weak model] in
                    guard let model, let doc = store.note(noteID),
                          let anchors = pageInk.userChanged(model, blocks: doc.blocks.map(\.id)),
                          anchors != doc.pageInkAnchors else { return }
                    store.setPageInkAnchors(noteID, anchors)
                }
            }
        } else {
            ContentUnavailableView("笔记不存在", systemImage: "doc.richtext")
        }
    }

    /// 页面内容的坐标（整页涂鸦用）
    private static let pageSpace = "notePage"

    /// 排版停下来以后，空白处的笔迹跟着它上面那一块挪
    private func settlePageInk() {
        guard HandwritingModel.isAvailable, width > 0, let doc = store.note(noteID) else { return }
        pageInk.blockFrames = pageInk.blockFrames.filter { id in doc.blocks.contains { $0.id == id.key } }
        if let anchors = pageInk.settle(ink.pageModel(for: noteID), blocks: doc.blocks.map(\.id), saved: doc.pageInkAnchors),
           anchors != doc.pageInkAnchors {
            store.setPageInkAnchors(noteID, anchors)
        }
    }

    /// 练习题手写区和页边批注够不够并排
    private var wide: Bool { min(width, 900) - 80 - 32 >= 760 }

    /// 页面左右留白：竖屏窄一些，正文能大一点
    private var pagePadding: CGFloat { width >= 1000 ? 40 : 24 }

    /// 每一块右边的 ⋯ 按钮占的宽度
    private static let menuWidth: CGFloat = 40

    /// 笔记文字按固定的纸宽排版，再整体缩放到页面上：文字不会因为页面变宽变窄重新换行，
    /// 涂鸦、荧光笔和圈出来问的位置才能一直对得上。
    /// 页面宽时按“留出页边”算比例：批注展开、收起时只左右挪动，文字大小不变
    private func paperScale(_ doc: NoteDoc) -> CGFloat {
        let reserve = commentMargin.map { $0 + 16 } ?? 0
        let column = min(width, 1180) - pagePadding * 2 - reserve - Self.menuWidth
        return min(max(column / doc.paper, 0.5), 1.25)
    }

    /// 正文一栏的宽度：纸 + ⋯ 按钮；页边展开时再加上页边
    private func columnWidth(_ doc: NoteDoc) -> CGFloat {
        let body = doc.paper * paperScale(doc) + Self.menuWidth
        let full = body + (marginOpen(doc) ? (commentMargin ?? 0) + 16 : 0)
        return max(0, min(full, width - pagePadding * 2))
    }

    /// 页边有展开的批注（或做题时被引导来看笔记的提示）：正文往左让出页边
    private func marginOpen(_ doc: NoteDoc) -> Bool {
        guard commentMargin != nil else { return false }
        if askingBlock != nil || store.activeNoteGuide?.noteID == noteID { return true }
        return (doc.comments ?? []).contains { !$0.minimized }
    }

    /// 页边批注的宽度；页面不够宽时为 nil，批注写在这一块下面
    private var commentMargin: CGFloat? { width >= 760 ? (width >= 1000 ? 260 : 210) : nil }

    // MARK: 标题

    private func header(_ doc: NoteDoc, job: NoteJob?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("笔记标题", text: Binding(get: { doc.title }, set: { store.renameNote(noteID, to: $0) }), axis: .vertical)
                .font(.largeTitle.bold())
            let source = [doc.sourceName.isEmpty ? nil : String(localized: "来自 \(doc.sourceName)"),
                          doc.prompt.isEmpty ? nil : String(localized: "要求：\(doc.prompt)")].compactMap { $0 }
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
        case .text, .answer, .canvas:
            NoteTextBlockView(noteID: noteID, block: block, editing: $editing,
                              streaming: store.noteJobs[noteID]?.afterBlock == block.id,
                              busy: store.noteJobs[noteID] != nil,
                              ink: block.kind != .answer && HandwritingModel.isAvailable ? ink.model(for: block.id) : nil,
                              comments: (doc.comments ?? []).filter { $0.blockID == block.id },
                              commentMargin: commentMargin,
                              marginOpen: marginOpen(doc),
                              paperWidth: doc.paper,
                              legacyLayout: doc.paperWidth == nil,
                              paperScale: paperScale(doc),
                              guide: store.activeNoteGuide?.noteID == noteID && store.activeNoteGuide?.blockID == block.id
                                  ? store.activeNoteGuide : nil,
                              asking: askingBlock == block.id,
                              onAskChange: { askChanged($0, in: block.id) },
                              onSelect: { handleSelection($0, in: block.id) },
                              onExercises: { exercises(count: $0, after: block) }) {
                blockMenu(block, in: doc)
            }
        case .exercise:
            exerciseView(block, in: doc)
                // 练习题和文字块对齐：页边展开时让出页边
                .padding(.trailing, marginOpen(doc) ? (commentMargin ?? 0) + 16 : 0)
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
            if block.kind == .answer && !block.text.isEmpty {
                // 不照抄回答：结合上一节写成正式的笔记，替换这块回答
                Button("整理进笔记", systemImage: "text.append") { store.integrateAnswer(noteID, block.id) }
                    .disabled(busy)
            }
            if block.kind == .canvas {
                Picker(selection: Binding(get: { block.paper ?? .dots }, set: { style in store.setBlockPaper(noteID, block.id, style) })) {
                    ForEach(PaperStyle.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                } label: {
                    Label("纸", systemImage: (block.paper ?? .dots).icon)
                }
                .pickerStyle(.menu)
            } else if block.kind != .exercise {
                Button("编辑", systemImage: "pencil") { editing = block.id }
            }
            Button("在下面加笔记块", systemImage: "text.badge.plus") { addTextBlock(after: block.id) }
            Button("在下面加手写块", systemImage: "scribble.variable") { addCanvasBlock(after: block.id) }
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

    /// 圈出来问：同一时间只在一块上问，换到别的块时把上一块圈的撤掉
    private func askChanged(_ asking: Bool, in blockID: UUID) {
        if asking {
            if let old = askingBlock, old != blockID { ink.existingModel(for: old)?.circledRegion = nil }
            askingBlock = blockID
        } else if askingBlock == blockID {
            askingBlock = nil
        }
    }

    private func addTextBlock(after: UUID?) {
        let block = NoteBlock(kind: .text)
        store.insertBlock(block, in: noteID, after: after)
        editing = block.id
    }

    /// 手写块：和笔记一样宽的一块空白纸，写到底自动加长
    private func addCanvasBlock(after: UUID?) {
        var block = NoteBlock(kind: .canvas)
        block.paper = PaperStyle(rawValue: UserDefaults.standard.string(forKey: "noteCanvasPaper") ?? "") ?? .dots
        store.insertBlock(block, in: noteID, after: after)
    }

    private func addRow(_ doc: NoteDoc) -> some View {
        HStack(spacing: 22) {
            Button {
                addTextBlock(after: nil)
            } label: {
                Label(doc.blocks.isEmpty ? L("写第一块笔记") : L("加一块笔记"), systemImage: "plus")
            }
            if HandwritingModel.isAvailable {
                Button {
                    addCanvasBlock(after: nil)
                } label: {
                    Label("加一块手写", systemImage: "scribble.variable")
                }
            }
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
            GeneratingBadge(label: job.label, startedAt: job.startedAt) { store.stopNoteJob(noteID) }
            // 生成整篇笔记时：大概进度、写好几块、用了多久
            if let progress = job.progress {
                GenerationProgressView(progress: progress) { String(localized: "已写好 \($0) 块") }
                    .frame(maxWidth: 420)
            }
        }
    }

    private func progressRow(_ job: NoteJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !job.partial.isEmpty {
                // 补进笔记时正在写的解释，写完插进上面这一块里提问的地方
                RichText(job.partial).opacity(0.55)
            }
            GeneratingBadge(label: job.label, startedAt: job.startedAt) { store.stopNoteJob(noteID) }
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
        store.askNote(noteID, blockID: block.id, selection: Tutor.clip(block.text, 600), title: L("出例题"),
                      prompt: String(localized: "请针对这一小节的内容出 \(count) 道练习题。"), exerciseCount: count)
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
            } else {
                Color.clear.frame(height: 4)
            }
        }
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
    /// 页边有展开的批注：正文让出页边；没有时正文居中，收起的批注小图标挂在这一块右边
    let marginOpen: Bool
    /// 这篇笔记的纸宽，和缩放到页面上的比例
    let paperWidth: CGFloat
    /// 旧笔记（上面已经写画过）：保持原来的换行方式，笔迹才对得上
    let legacyLayout: Bool
    let paperScale: CGFloat
    /// 做题卡住时被引导来看的就是这一块：临时荧光笔标出重点，页边有“详细记录”
    let guide: NoteGuide?
    /// 这一块上圈出来问，提问框正开着
    let asking: Bool
    let onAskChange: (Bool) -> Void
    let onSelect: (String) -> Void
    /// 小节下面的“出例题”，参数是出几道
    let onExercises: (Int) -> Void
    @ViewBuilder let menu: () -> MenuContent

    @State private var draft = ""
    @FocusState private var focused: Bool
    /// 文字视图，涂鸦层把书写手势挂上去
    @State private var inkHost = InkHost()
    /// 正文的高度：最后一条批注最多写到哪里
    @State private var contentHeight: CGFloat = 0

    private var isEditing: Bool { editing == block.id }

    /// 涂鸦画布比文字四周各大出多少（纸的坐标）：从文字里写到页边、块和块之间的笔画不会在文字边上被截断
    private static var inkOverflow: CGFloat { 160 }

    var body: some View {
        // 页面宽时批注写在右边页边，和这一块顶端对齐；窄时写在这一块下面
        // 展开、收起页边用同一个分支，只改留白和批注栏的尺寸：换分支会把这一块（连同排版的网页）整个重建，
        // 重建时高度一下变成 0，页面就被弹回最上面
        if let commentMargin {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                // 展开：批注浮在页边，不占版面，长批注往下延伸也不会把下面的笔记推开
                .padding(.trailing, marginOpen ? commentMargin + 16 : 0)
                .overlay(alignment: .topTrailing) {
                    marginColumn(pinned: true)
                        .frame(width: marginOpen ? commentMargin : nil, alignment: .leading)
                        // 收起：小图标挂在这一块右边外面，点一下展开
                        .fixedSize(horizontal: !marginOpen, vertical: true)
                        .alignmentGuide(.trailing) { marginOpen ? $0[.trailing] : $0[.leading] - 10 }
                }
                .zIndex(comments.isEmpty && !asking ? 0 : 1)
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                content
                marginColumn(pinned: false).frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    /// 页边：圈出来问的回答写在圈住的地方右边，同一高度；提问框也在那里。
    /// pinned 为 false 时（页面窄，没有页边）依次写在这一块下面
    @ViewBuilder
    private func marginColumn(pinned: Bool) -> some View {
        if let ink {
            AskRegionReader(ink: ink) { region in
                marginItems(pinned: pinned, askRegion: asking ? region : nil, ink: ink)
            }
        } else {
            marginItems(pinned: pinned, askRegion: nil, ink: nil)
        }
    }

    @ViewBuilder
    private func marginItems(pinned: Bool, askRegion: CGRect?, ink: HandwritingModel?) -> some View {
        let numbered = Array(comments.enumerated())
        // 按圈住的位置从上到下
        let entries: [MarginEntry] = (guide.map { [MarginEntry.guide($0)] } ?? [])
            + numbered.map { MarginEntry.comment($0.element, number: $0.offset + 1, y: $0.element.region.rect.minY * paperScale) }
            + (askRegion.map { [MarginEntry.ask(y: $0.minY * paperScale)] } ?? [])
        let sorted = pinned ? entries.sorted { $0.y < $1.y } : entries.sorted { $0.order < $1.order }
        if !sorted.isEmpty {
            PinnedColumn(spacing: pinned ? 8 : 10, pinned: pinned) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { i, entry in
                    marginEntry(entry, room: pinned && marginOpen ? room(after: i, in: sorted) : nil, ink: ink)
                        .layoutValue(key: PinY.self, value: entry.y)
                }
            }
        }
    }

    /// 这一条往下能写多高：写到下一条圈住的地方为止；最后一条写到这一块底下。不够写就压缩
    private func room(after i: Int, in entries: [MarginEntry]) -> CGFloat {
        let y = entries[i].y
        let next = entries.dropFirst(i + 1).first?.y ?? max(contentHeight + 40, y + 180)
        return max(next - y - 8, 90)
    }

    @ViewBuilder
    private func marginEntry(_ entry: MarginEntry, room: CGFloat?, ink: HandwritingModel?) -> some View {
        switch entry {
        case .guide(let guide):
            NoteGuideCard(guide: guide)
        case .comment(let comment, let number, _):
            NoteCommentView(noteID: noteID, comment: comment, number: number, room: room)
        case .ask:
            if let ink {
                CircleAskCard(busy: busy) { question in
                    send(question, ink: ink)
                } cancel: {
                    ink.circledRegion = nil
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
                if block.kind == .canvas {
                    canvasArea
                } else if isEditing {
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
                        GeneratingBadge(label: L("正在回答…"), startedAt: store.noteJobs[noteID]?.startedAt, tint: Ink.blue) {
                            store.stopNoteJob(noteID)
                        }
                    } else {
                        Button("空白笔记块，点这里开始写") { editing = block.id }
                            .buttonStyle(InkTextButtonStyle(color: .secondary))
                    }
                } else {
                    RichText(block.text, tone: legacyLayout ? .legacy : .normal, onSelect: onSelect, host: inkHost,
                             highlight: guide.map { Tutor.highlightKey($0.quote) })
                        // 圈出来问过的地方：淡淡的虚线框和序号，对应页边的批注
                        .overlay(alignment: .topLeading) { circledMarks }
                        // 涂鸦层盖在文字上：笔写字、画荧光笔；手指照样能选字、翻页
                        .overlay {
                            if let ink {
                                NotebookCanvas(model: ink, tools: ink.tools, host: inkHost, overflow: Self.inkOverflow)
                                    .padding(-Self.inkOverflow)
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if let ink {
                                CircleAskAnchor(ink: ink, onAskChange: onAskChange)
                            }
                        }
                        .modifier(NotePaper(width: paperWidth, scale: paperScale))
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

    /// 手写块：和笔记一样宽的空白纸（按纸的坐标排，跟着正文一起缩放），写到底自动加长；圈出来问照样能用
    @ViewBuilder
    private var canvasArea: some View {
        if let ink {
            VStack(alignment: .leading, spacing: 4) {
                NoteCanvasArea(model: ink, style: block.paper ?? .dots)
                    .overlay(alignment: .topLeading) { circledMarks }
                    .overlay(alignment: .topLeading) { CircleAskAnchor(ink: ink, onAskChange: onAskChange) }
                    .modifier(NotePaper(width: paperWidth, scale: paperScale))
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { ink.addSpace() }
                } label: {
                    Label("加长", systemImage: "arrow.down.to.line")
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        } else {
            Text("手写块需要在 iPad 上使用").font(.callout).foregroundStyle(.secondary)
        }
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
        // 提问框换成这条批注（同一个位置）
        defer { ink.circledRegion = nil }
        let ask = { (image: Data?) in
            store.askCircled(noteID, blockID: block.id, region: InkRegion(region), question: question, image: image)
        }
        #if os(iOS)
        // 手写块：只有笔迹，放在白底上发过去
        if block.kind == .canvas {
            let image = ink.drawingImage(in: region).map { strokes in
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                return UIGraphicsImageRenderer(size: strokes.size, format: format).image { _ in
                    UIColor.white.setFill()
                    UIRectFill(CGRect(origin: .zero, size: strokes.size))
                    strokes.draw(at: .zero)
                }
            }
            ask(image?.jpegData(compressionQuality: 0.85).flatMap { ImageUtil.normalizedJPEG($0, maxPixel: 1280) })
            return
        }
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
            Text(block.question ?? L("提问")).font(.caption.weight(.semibold)).foregroundStyle(Ink.blue)
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

/// 手写块的纸和画布：高度跟着笔迹（写到底自动加长），和练习题的手写区一样
private struct NoteCanvasArea: View {
    @ObservedObject var model: HandwritingModel
    let style: PaperStyle

    var body: some View {
        NotebookCanvas(model: model, tools: model.tools)
            .frame(height: model.height)
            .background(PaperPattern(style: style))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
            .onChange(of: model.height) { model.redrawSoon() }
    }
}

/// AI 回答的块：左边一道蓝笔竖线，和自己写的笔记区分开
private struct AnswerRule: ViewModifier {
    let isAnswer: Bool
    func body(content: Content) -> some View {
        if isAnswer { content.marginRule(Ink.blue) } else { content }
    }
}

/// 圈完一处：在圈住的地方画虚线框；提问框在右边页边、同一高度（见 CircleAskCard）
private struct CircleAskAnchor: View {
    @ObservedObject var ink: HandwritingModel
    let onAskChange: (Bool) -> Void

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
        }
        .allowsHitTesting(false)
        .onChange(of: ink.circledRegion != nil) { onAskChange(ink.circledRegion != nil) }
        .onDisappear { if ink.circledRegion != nil { onAskChange(false) } }
    }
}

/// 页边上的一条：引导卡、批注或提问框；y 是它想对齐的高度（这一块里的坐标）
private enum MarginEntry: Identifiable {
    case guide(NoteGuide)
    case comment(NoteComment, number: Int, y: CGFloat)
    case ask(y: CGFloat)

    var id: String {
        switch self {
        case .guide: return "guide"
        case .comment(let c, _, _): return c.id.uuidString
        case .ask: return "ask"
        }
    }

    var y: CGFloat {
        switch self {
        case .guide: return 0
        case .comment(_, _, let y), .ask(let y): return y
        }
    }

    /// 页面窄、写在下面时的顺序：引导、提问框、批注
    var order: Int {
        switch self {
        case .guide: return 0
        case .ask: return 1
        case .comment(_, let n, _): return 1 + n
        }
    }
}

private struct PinY: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// 页边一栏：每一条放在它想对齐的高度，和上一条挤到一起时往下让；pinned 为 false 时一条接一条往下排
private struct PinnedColumn: Layout {
    var spacing: CGFloat
    var pinned: Bool

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> (tops: [CGFloat], sizes: [CGSize]) {
        var tops: [CGFloat] = []
        var sizes: [CGSize] = []
        var bottom: CGFloat?
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let want = pinned ? max(0, view[PinY.self]) : 0
            let top = bottom.map { max(want, $0 + spacing) } ?? want
            tops.append(top)
            sizes.append(size)
            bottom = top + size.height
        }
        return (tops, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (tops, sizes) = arrange(subviews, width: proposal.width)
        let height = zip(tops, sizes).map { $0 + $1.height }.max() ?? 0
        let width = proposal.width ?? (sizes.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (tops, _) = arrange(subviews, width: proposal.width ?? bounds.width)
        for (view, top) in zip(subviews, tops) {
            view.place(at: CGPoint(x: bounds.minX, y: bounds.minY + top), anchor: .topLeading,
                       proposal: ProposedViewSize(width: proposal.width ?? bounds.width, height: nil))
        }
    }
}

/// 跟着圈住的地方变：提问框出现、消失
private struct AskRegionReader<Content: View>: View {
    @ObservedObject var ink: HandwritingModel
    @ViewBuilder let content: (CGRect?) -> Content
    var body: some View { content(ink.circledRegion) }
}

/// 圈完一处后在右边页边、同一高度出现的提问框：常用问题，或者写下想问的（可以直接用 Apple Pencil 写，系统转成文字）
private struct CircleAskCard: View {
    let busy: Bool
    let send: (String) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    static let quick = [L("这是什么意思？"), L("为什么是这样？"), L("举个例子"), L("和前面有什么联系？")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("问圈出来的这段").font(.caption.weight(.semibold)).foregroundStyle(Ink.blue)
                Spacer(minLength: 0)
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(InkTextButtonStyle(color: .secondary))
                .accessibilityLabel("不问了")
            }
            TextField("想问什么…", text: $text, axis: .vertical)
                .focused($focused)
                .font(.callout)
                .lineLimit(1...4)
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { submit(text) }
            FlowLayout(spacing: 10) {
                ForEach(Self.quick, id: \.self) { q in
                    Button(q) { submit(q) }.font(.caption)
                }
            }
            .buttonStyle(InkTextButtonStyle())
            Button { submit(text) } label: {
                Text("发送").font(.callout).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if busy {
                Text("正在回答上一个问题，稍等一下").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Ink.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Ink.blue.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        // 直接打字：出现就聚焦输入框（等圈的那一笔抬起来）
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true } }
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
    /// 在页边能写多高（写到下一条批注为止）；写不下就把回答的字缩小，最小缩到 minFit，再写不下只显示前面的、双击看全文。
    /// 为 nil 时不限高度
    var room: CGFloat? = nil
    @State private var enlarged = false
    /// 回答的字缩小到多少
    @State private var fit: CGFloat = 1
    /// 整条批注的高度、回答完整显示时的高度
    @State private var cardHeight: CGFloat = 0
    @State private var answerHeight: CGFloat = 0
    /// 回答实际显示出来的高度（写不下时只显示一部分）
    @State private var shownAnswerHeight: CGFloat = 0

    private static let minFit: CGFloat = 0.7

    private var streaming: Bool { store.noteJobs[noteID]?.commentID == comment.id }

    /// 除了回答以外占的高度（问题、按钮、留白）
    private var otherHeight: CGFloat { max(0, cardHeight - shownAnswerHeight) }

    /// 页边地方不够，正在压缩：问题只写一行，“记到笔记”放进 ⋯ 菜单
    private var compact: Bool { room != nil && fit < 0.995 }

    /// 字已经缩到最小还写不下：回答只显示这么高
    private var answerCap: CGFloat? {
        guard let room, fit <= Self.minFit + 0.005, answerHeight > 0 else { return nil }
        let other = otherHeight
        guard other + answerHeight > room + 1 else { return nil }
        return max(36, room - other)
    }

    /// 量到新高度后重新算字号：回答的高度大约和字号的平方成正比
    private func refit() {
        guard let room, answerHeight > 1, cardHeight > 1 else {
            if room == nil, fit != 1 { fit = 1 }
            return
        }
        let other = otherHeight
        let natural = other + answerHeight
        let answerRoom = max(room - other, 20)
        var target = fit * (answerRoom / answerHeight).squareRoot()
        target = min(1, max(Self.minFit, target))
        let tooTall = natural > room + 1
        let roomy = natural < room * 0.85
        if (tooTall && target < fit - 0.01) || (roomy && target > fit + 0.03) {
            fit = (target * 100).rounded(.down) / 100
        }
    }

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
                    Text(comment.question).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(compact ? 1 : 2)
                    Spacer(minLength: 0)
                    if !streaming && !comment.answer.isEmpty {
                        Menu {
                            Button("放大查看", systemImage: "arrow.up.left.and.arrow.down.right") { enlarged = true }
                            if compact && !comment.savedToNote {
                                Button("把这个点记到笔记中", systemImage: "plus") { store.saveCommentToNote(noteID, comment.id) }
                                    .disabled(store.noteJobs[noteID] != nil)
                            }
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
                    GeneratingBadge(label: L("正在写…"), startedAt: store.noteJobs[noteID]?.startedAt, tint: Ink.blue,
                                    compact: true) { store.stopNoteJob(noteID) }
                } else {
                    RichText(comment.answer, scale: 0.82 * Double(fit))
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0; refit() }
                        .frame(maxHeight: answerCap, alignment: .top)
                        .clipped()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownAnswerHeight = $0; refit() }
                        // 写不下的部分淡出，双击看全文
                        .mask {
                            if answerCap != nil {
                                LinearGradient(stops: [.init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                               startPoint: .top, endPoint: .bottom)
                            } else {
                                Color.black
                            }
                        }
                        // 文字显示在网页视图里，点击会被它吃掉：盖一层透明的来接双击
                        .overlay {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { enlarged = true }
                        }
                }
                if !streaming && !comment.answer.isEmpty && !compact {
                    if comment.savedToNote {
                        Label("已记到笔记", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            store.saveCommentToNote(noteID, comment.id)
                        } label: {
                            Label("把这个点记到笔记中", systemImage: "plus").font(.caption.weight(.medium))
                        }
                        .buttonStyle(InkTextButtonStyle())
                        .disabled(store.noteJobs[noteID] != nil)
                    }
                }
            }
            .padding(10)
            .background(Ink.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .leading) {
                Rectangle().fill(Ink.blue.opacity(0.5)).frame(width: 2).padding(.vertical, 8)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0; refit() }
            .onChange(of: room) { refit() }
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
                                .disabled(store.noteJobs[noteID] != nil)
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
    let width: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        PaperLayout(width: width, scale: scale) {
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
        // 不比给的宽度更宽：否则会把整页撑宽，量出来的页面宽度又跟着变大
        return CGSize(width: min(width * scale, proposal.width ?? .infinity), height: height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
    }
}

/// 被引导来看笔记时，页边的一张卡：记下这个知识点、回到题目
private struct NoteGuideCard: View {
    @EnvironmentObject var store: AppStore
    let guide: NoteGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("做题时卡在这里", systemImage: "highlighter")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if !guide.summary.isEmpty {
                Button {
                    store.recordDetail(guide)
                } label: {
                    Label("详细记录：\(guide.summary)", systemImage: "plus")
                        .font(.caption.weight(.medium))
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(InkTextButtonStyle())
                .disabled(store.noteJobs[guide.noteID] != nil)
            }
            Button {
                store.returnFromNoteGuide()
            } label: {
                Label("回到题目", systemImage: "arrow.uturn.backward").font(.caption.weight(.medium))
            }
            .buttonStyle(InkTextButtonStyle(color: Ink.blue))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
