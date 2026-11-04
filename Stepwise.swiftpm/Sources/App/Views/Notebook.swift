import SwiftUI

/// 笔记本里每道题的手写区，按题目缓存：页面滚动回收视图时笔迹和高度都不丢
final class NotebookInk: ObservableObject {
    let tools = InkTools()
    private var models: [UUID: HandwritingModel] = [:]

    func model(for id: UUID) -> HandwritingModel {
        if let model = models[id] { return model }
        let model = HandwritingModel(questionID: id, tools: tools)
        models[id] = model
        return model
    }

    func saveAll() { models.values.forEach { $0.saveNow() } }
}

/// 做题的主界面：整个题集是一本可以一直往下写的笔记本。
/// 题目印在纸上，下面就是手写区；批改结果、提示写在页边，完整答案折叠在题目下方。
struct NotebookView: View {
    @EnvironmentObject var store: AppStore
    /// 题集；为 nil 时显示错题本
    let setID: UUID?

    struct Entry: Hashable {
        let setID: UUID
        let qID: UUID
    }

    @StateObject private var ink = NotebookInk()
    @State private var position: UUID?
    @State private var width: CGFloat = 800
    @State private var showSettings = false
    /// 错题本里显示的题：做对移出错题本后先留在页面上，免得正看着结果题目就消失了
    @State private var mistakeEntries: [Entry] = []
    @Environment(\.scenePhase) private var scenePhase

    private var entries: [Entry] {
        if let setID {
            return store.set(setID)?.questions.map { Entry(setID: setID, qID: $0.id) } ?? []
        }
        return mistakeEntries.filter { store.question($0.setID, $0.qID) != nil }
    }

    var body: some View {
        let items = entries
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items, id: \.qID) { entry in
                    QuestionBlock(setID: entry.setID, qID: entry.qID, model: ink.model(for: entry.qID),
                                  wide: width >= 760, mistakeMode: setID == nil,
                                  nextID: next(after: entry, in: items))
                        .id(entry.qID)
                }
                // 给底部的工具条留位置
                Color.clear.frame(height: 110)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 28)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $position, anchor: .top)
        .scrollDismissesKeyboard(.interactively)
        .background(Ink.paper)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .bottom) {
            if HandwritingModel.isAvailable && !items.isEmpty {
                InkPalette(tools: ink.tools).padding(.bottom, 14)
            }
        }
        .overlay {
            // 说明文字在左边的错题本列表里，这里只留标题
            if items.isEmpty && setID == nil {
                ContentUnavailableView("错题本是空的", systemImage: "bookmark")
            }
        }
        .navigationTitle(setID.flatMap { store.set($0)?.title } ?? "错题本")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.setFullScreen(!store.isFullScreen)
                } label: {
                    Label(store.isFullScreen ? "显示题目列表" : "全屏做题",
                          systemImage: store.isFullScreen ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
                }
                ModelMenu { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            if setID == nil {
                mistakeEntries = store.starredEntries.map { Entry(setID: $0.setID, qID: $0.question.id) }
            }
            // 等页面排好版再滚到选中的题
            DispatchQueue.main.async { position = store.selectedQuestionID }
        }
        // 左边目录点了哪道题，就翻到哪道题
        .onChange(of: store.selectedQuestionID) {
            if store.selectedQuestionID != position {
                withAnimation(.easeInOut(duration: 0.3)) { position = store.selectedQuestionID }
            }
        }
        // 翻到哪道题，左边目录就跟着选中哪道题
        .onChange(of: position) {
            if let position, position != store.selectedQuestionID { store.selectedQuestionID = position }
        }
        // 新加入错题本的题接在后面
        .onChange(of: store.starredEntries.map(\.question.id)) {
            guard setID == nil else { return }
            for entry in store.starredEntries where !mistakeEntries.contains(where: { $0.qID == entry.question.id }) {
                mistakeEntries.append(Entry(setID: entry.setID, qID: entry.question.id))
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active { ink.saveAll() }
        }
        .onDisappear { ink.saveAll() }
    }

    /// 做对后“下一题”跳到哪里：题集里是下一道没做完的题，错题本里是下一道错题
    private func next(after entry: Entry, in items: [Entry]) -> UUID? {
        if let setID { return store.nextQuestion(after: entry.qID, in: setID) }
        guard let i = items.firstIndex(of: entry), i + 1 < items.count else { return nil }
        return items[i + 1].qID
    }
}

// MARK: - 一道题

struct QuestionBlock: View {
    @EnvironmentObject var store: AppStore
    let setID: UUID
    let qID: UUID
    @ObservedObject var model: HandwritingModel
    /// 页面够宽时批改结果写在右边页边，否则写在手写区下面
    let wide: Bool
    let mistakeMode: Bool
    let nextID: UUID?

    @State private var draft = ""
    @State private var loaded = false
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var editing = false
    @State private var showHistory = false
    @State private var confirmReset = false
    @State private var confirmClearInk = false
    @State private var showHintNote = false
    @State private var hintNote = ""
    @State private var showAsk = false
    @State private var askText = ""
    /// 页边选中的批注；nil 表示最新一条
    @State private var selectedNote: UUID?
    /// 圈选提问的弹窗。等圈的那一笔抬起来再弹出，否则会被同一次触摸关掉
    @State private var showStepAsk = false

    var body: some View {
        if let q = store.question(setID, qID) {
            VStack(alignment: .leading, spacing: 14) {
                header(q)
                RichText(q.content, scale: 1.08)
                ForEach(q.imageIDs, id: \.self) { id in
                    StoredImage(id: id, maxHeight: 420)
                }
                if mistakeMode { reviewLine(q) }

                // 手写区和按钮在左，批改结果写在右边页边；页面窄时批改结果排在按钮下面
                let work = VStack(alignment: .leading, spacing: 12) {
                    writingArea(q)
                    actionRow(q)
                    if q.status.isDone { followUpRow }
                }
                if wide {
                    HStack(alignment: .top, spacing: 18) {
                        work
                        MarginNotes(setID: setID, qID: qID, mistakeMode: mistakeMode, nextID: nextID, wide: true,
                                    selection: $selectedNote, onSelect: showAskRegion)
                            .frame(width: 290)
                    }
                } else {
                    work
                    MarginNotes(setID: setID, qID: qID, mistakeMode: mistakeMode, nextID: nextID, wide: false,
                                selection: $selectedNote, onSelect: showAskRegion)
                }

                QuestionNotes(setID: setID, qID: qID, wide: wide)
            }
            .padding(.vertical, 28)
            .overlay(alignment: .bottom) {
                // 题与题之间的分隔线，像笔记本上画的横线
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
            }
            .onAppear { onAppear(q) }
            .onDisappear {
                saveDraft()
                model.saveNow()
            }
            // 圈选提问的回答到了：在手写区上标出问的是哪里
            .onChange(of: MarginNotes.selected(MarginNotes.items(q, wide: wide), selectedNote)?.id) { _, _ in
                if let current = MarginNotes.selected(MarginNotes.items(q, wide: wide), selectedNote) {
                    showAskRegion(current)
                }
            }
            // 打字停顿 1 秒自动保存
            .onChange(of: draft) {
                draftSaveTask?.cancel()
                draftSaveTask = Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    saveDraft()
                }
            }
            .sheet(isPresented: $editing) { EditQuestionView(setID: setID, qID: qID) }
            .sheet(isPresented: $showHistory) { QuestionHistoryView(setID: setID, qID: qID) }
            .confirmationDialog("清空这道题的作答、批改记录和手写，重新开始？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("清空并重做", role: .destructive) {
                    store.resetQuestion(setID, qID)
                    draft = ""
                    model.clear()
                }
            }
            .confirmationDialog("擦掉这道题的全部手写？", isPresented: $confirmClearInk, titleVisibility: .visible) {
                Button("全部擦掉", role: .destructive) { model.clear() }
            }
        }
    }

    private func onAppear(_ q: Question) {
        if !loaded {
            draft = q.draftAnswer
            loaded = true
        }
        // 趁做题的时间在后台把答案解出来，点批改时只需对答案
        if !q.status.isDone { store.presolve(setID, [qID]) }
        // 错题本里还没做完的题：开始计复习轮数
        if mistakeMode { store.beginReviewIfNeeded(setID, qID) }
    }

    // MARK: 题头

    private func header(_ q: Question) -> some View {
        HStack(spacing: 8) {
            Text("第 \(q.label) 题").font(.title3.bold())
            StatusPill(status: q.status)
            if q.isGenerated {
                Text("变式题").font(.caption).foregroundStyle(.secondary)
            }
            if mistakeMode, let title = store.set(setID)?.title {
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { store.toggleStar(setID, qID) }
            } label: {
                Label(q.isStarred ? "在错题本里" : "加入错题本", systemImage: q.isStarred ? "bookmark.fill" : "bookmark")
                    .font(.callout)
                    .foregroundStyle(q.isStarred ? Ink.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(q.isStarred ? "移出错题本" : "加入错题本")
            Menu {
                Button("编辑题目", systemImage: "square.and.pencil") { editing = true }
                Button("完整记录", systemImage: "clock.arrow.circlepath") { showHistory = true }
                    .disabled(q.messages.isEmpty && (q.previousAttempts ?? []).isEmpty)
                Button("清空这道题重做", systemImage: "arrow.counterclockwise", role: .destructive) { confirmReset = true }
            } label: {
                Image(systemName: "ellipsis").font(.title3).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("这道题的更多操作")
        }
    }

    /// 错题本里：做过的题可以重新练习；复习中显示已用轮数
    @ViewBuilder
    private func reviewLine(_ q: Question) -> some View {
        if q.status.isDone && q.reviewRounds == nil {
            HStack(spacing: 12) {
                Label("可以重新练一遍：\(AppStore.masteryRounds) 轮之内做对，就从错题本移出", systemImage: "arrow.counterclockwise")
                    .font(.callout).foregroundStyle(Ink.red)
                Spacer()
                Button {
                    withAnimation { store.startReview(setID, qID) }
                    draft = ""
                    model.clear()
                } label: {
                    Label("重新练习", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .tint(Ink.red)
            }
        } else if let rounds = q.reviewRounds {
            Label(rounds == 0
                  ? "错题复习中 · \(AppStore.masteryRounds) 轮之内做对就移出错题本（批改一次或提示一次算一轮）"
                  : "错题复习中 · 已用 \(rounds) 轮" + (rounds < AppStore.masteryRounds ? "，这一轮做对就移出错题本" : "，这次做对也会留在错题本里"),
                  systemImage: "bookmark.fill")
                .font(.callout)
                .foregroundStyle(Ink.red)
        }
    }

    // MARK: 手写区

    private func writingArea(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if HandwritingModel.isAvailable {
                NotebookCanvas(model: model, tools: model.tools)
                    .frame(height: model.height)
                    .background(RuledPaper())
                    // 批改标出的错误行、圈选提问圈住的地方
                    .overlay { annotations(q) }
                    .overlay(alignment: .topLeading) { askAnchor }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
                    .animation(.easeOut(duration: 0.2), value: model.height)

                HStack(spacing: 16) {
                    Button { model.addSpace() } label: { Label("加长", systemImage: "arrow.down.to.line") }
                    Spacer()
                    Button(role: .destructive) { confirmClearInk = true } label: { Label("擦掉全部", systemImage: "trash") }
                        .disabled(model.isEmpty)
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }

            // 打字作答默认隐藏；以前打过的字仍然显示，不会丢
            if store.keyboardAnswer || !HandwritingModel.isAvailable || !draft.isEmpty {
                TextField(model.isEmpty ? "在这里打字作答…" : "可以补充文字说明（可选）", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                if draft.contains("$") || draft.contains("\\(") {
                    RichText(draft, scale: 0.95)
                        .padding(8)
                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 画在手写区上的标注：这一轮批改标出的错误行（红色波浪线），选中的圈选提问圈住的地方（蓝框）
    private func annotations(_ q: Question) -> some View {
        let items = MarginNotes.items(q, wide: wide)
        let verdict = items.last { $0.kind == .verdictWrong || $0.kind == .verdictCorrect }
        let marks = verdict?.kind == .verdictWrong ? verdict?.marks ?? [] : []
        var region = model.circledRegion
        // 问过的地方：继续写字后就不再标出，免得蓝框挡着书写
        if region == nil, model.askRegionVisible, store.pending[qID]?.inMargin == true {
            region = q.messages.last { $0.role == .user && $0.region != nil }?.region?.rect
        }
        if region == nil, model.askRegionVisible, let selected = MarginNotes.selected(items, selectedNote), selected.kind == .chat {
            region = selected.region?.rect
        }
        return InkAnnotations(marks: marks, region: region, span: model.inkSpan(inRow:))
            // 手写纸一直是白的，批注用浅色模式的红笔、蓝笔
            .environment(\.colorScheme, .light)
    }

    /// 选中页边的圈选提问时，重新在手写区上标出问的是哪里
    private func showAskRegion(_ note: ChatMessage) {
        if note.kind == .chat, note.region != nil { model.askRegionVisible = true }
    }

    /// 圈选提问的弹窗从圈住的地方弹出
    private var askAnchor: some View {
        let r = model.circledRegion ?? .zero
        return Color.clear
            .frame(width: max(r.width, 1), height: max(r.height, 1))
            .padding(.leading, max(0, r.minX))
            .padding(.top, max(0, r.minY))
            .onChange(of: model.circledRegion) {
                guard model.circledRegion != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if model.circledRegion != nil { showStepAsk = true }
                }
            }
            .popover(isPresented: $showStepAsk) {
                StepAskPopover(disabled: store.isBusy(qID)) { text in
                    guard let region = model.circledRegion else { return }
                    store.askAboutStep(setID, qID, text: text, image: model.exportJPEG(highlight: region),
                                       region: InkRegion(region))
                    showStepAsk = false
                }
                .onDisappear { model.circledRegion = nil }
            }
    }

    // MARK: 操作

    private func actionRow(_ q: Question) -> some View {
        let busy = store.isBusy(qID)
        let empty = model.isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 20) {
            // 做对之前：批改、提示、看答案。只有“批改”是实心按钮，其余是文字
            if q.status != .passed {
                Button {
                    saveDraft()
                    model.saveNow()
                    store.check(setID, qID, answer: draft, handwriting: model.exportJPEG())
                } label: {
                    Text("批改").padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || empty)

                // 提示分三档：思路方向 → 关键一步 → 下一步写什么，按钮上写着下一档是什么
                Button("提示：" + Tutor.hintLevelShortName(q.hintCount + 1)) {
                    store.requestHint(setID, qID)
                }
                .lineLimit(1)
                .disabled(busy)

                // 先写几句卡在哪里，再要提示
                Button("说说卡在哪") { showHintNote = true }
                    .disabled(busy)
                    .popover(isPresented: $showHintNote) { hintNotePopover(q) }

                if q.status != .revealed {
                    Button("看答案") { store.requestSolution(setID, qID) }
                        .disabled(busy)
                }
            }
            Spacer()
            if busy {
                Button("停止") { store.cancelReply(qID) }
                    .buttonStyle(InkTextButtonStyle(color: .secondary))
            }
        }
        .buttonStyle(InkTextButtonStyle())
    }

    /// 做完之后：自定义的快捷操作，以及自由提问。回答写成这道题下面的笔记
    private var followUpRow: some View {
        FlowLayout(spacing: 18) {
            ForEach(store.followUps.filter { !$0.title.isEmpty && !$0.prompt.isEmpty }) { action in
                Button(action.title) {
                    store.sendChat(setID, qID, text: action.prompt, makesQuestion: action.makesQuestion)
                }
            }
            Button("提问…") { showAsk = true }
                .popover(isPresented: $showAsk) { askPopover }
        }
        .buttonStyle(InkTextButtonStyle())
        .disabled(store.isBusy(qID))
    }

    private func hintNotePopover(_ q: Question) -> some View {
        notePopover(title: "补充说明", prompt: "说说你卡在哪一步、哪里不明白…", text: $hintNote,
                    button: "发送并要提示：" + Tutor.hintLevelName(q.hintCount + 1), tint: Ink.pen) {
            store.requestHint(setID, qID, note: hintNote)
            hintNote = ""
            showHintNote = false
        }
    }

    private var askPopover: some View {
        notePopover(title: "提问", prompt: "关于这道题想问什么…", text: $askText,
                    button: "发送", tint: Ink.pen) {
            store.sendChat(setID, qID, text: askText)
            askText = ""
            showAsk = false
        }
    }

    private func notePopover(title: String, prompt: String, text: Binding<String>, button: String,
                             tint: Color, send: @escaping () -> Void) -> some View {
        NotePopover(title: title, prompt: prompt, text: text, button: button, tint: tint,
                    disabled: store.isBusy(qID), send: send)
    }

    private func saveDraft() {
        let text = draft
        store.mutate(setID, qID) { q in
            if q.draftAnswer != text { q.draftAnswer = text }
        }
    }
}

/// 弹出的小输入框：写一句话发给 AI
private struct NotePopover: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let button: String
    let tint: Color
    let disabled: Bool
    let send: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(3...6)
                .focused($focused)
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            Button(action: send) {
                Text(button).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .disabled(disabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}

/// 横线纸。第 n 行是第 n-1 条和第 n 条横线之间的那一格，批改时按行号标出错误
struct RuledPaper: View {
    static let lineSpacing: CGFloat = 44

    /// 手写区里 y 处是第几行（从 1 开始）
    static func row(at y: CGFloat) -> Int { max(1, Int((y / lineSpacing).rounded(.down)) + 1) }
    static func top(ofRow row: Int) -> CGFloat { CGFloat(row - 1) * lineSpacing }

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y = Self.lineSpacing
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += Self.lineSpacing
            }
            context.stroke(path, with: .color(Color(red: 0.62, green: 0.72, blue: 0.86).opacity(0.45)), lineWidth: 0.8)
        }
        .background(Color.white)
    }
}

// MARK: - 页边批注

extension InkRegion {
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// 手写区上的标注，像老师用红笔改作业：错的那一行下面画波浪线，前面写上序号，后面写短评。
/// 波浪线和序号画在 Canvas 上；短评里可能有公式，用 RichText（KaTeX）叠在对应的位置
struct InkAnnotations: View {
    let marks: [InkMark]
    let region: CGRect?
    /// 某一行笔迹的左右范围
    let span: (Int) -> ClosedRange<CGFloat>?

    /// 一处错误在手写区上的位置
    private struct Placement {
        let number: Int
        let note: String
        /// 波浪线的左右端和所在的行
        let x0: CGFloat
        let x1: CGFloat
        let rowTop: CGFloat
        /// 短评的位置和宽度
        let noteOrigin: CGPoint
        let noteWidth: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            let placements = place(in: geo.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let spacing = RuledPaper.lineSpacing
                    for p in placements {
                        // 波浪线
                        let y = p.rowTop + spacing + 2
                        var wave = Path()
                        wave.move(to: CGPoint(x: p.x0, y: y))
                        var x = p.x0
                        var up = true
                        while x < p.x1 {
                            let next = min(x + 7, p.x1)
                            wave.addQuadCurve(to: CGPoint(x: next, y: y), control: CGPoint(x: (x + next) / 2, y: y + (up ? -3.5 : 3.5)))
                            x = next
                            up.toggle()
                        }
                        context.stroke(wave, with: .color(Ink.red.opacity(0.9)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        let number = context.resolve(Text(MarginNotes.circled(p.number)).font(.system(size: 17, weight: .bold)).foregroundColor(Ink.red))
                        context.draw(number, at: CGPoint(x: max(12, p.x0 - 16), y: p.rowTop + spacing / 2 + 4))
                    }
                    if let region {
                        let box = Path(roundedRect: region, cornerRadius: 8)
                        context.fill(box, with: .color(Ink.blue.opacity(0.05)))
                        context.stroke(box, with: .color(Ink.blue.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                }
                ForEach(placements, id: \.number) { p in
                    RichText(p.note, scale: 0.82, tone: .paperRed)
                        .frame(width: p.noteWidth, alignment: .leading)
                        .offset(x: p.noteOrigin.x, y: p.noteOrigin.y)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 短评写在波浪线右边；右边太窄就写在波浪线下面
    private func place(in size: CGSize) -> [Placement] {
        let spacing = RuledPaper.lineSpacing
        return marks.enumerated().compactMap { i, mark in
            let rowTop = RuledPaper.top(ofRow: mark.line)
            guard rowTop < size.height else { return nil }
            let range = span(mark.line) ?? 40...(size.width * 0.5)
            let x0 = max(28, range.lowerBound)
            let x1 = min(size.width - 8, max(range.upperBound, x0 + 40))
            let roomRight = size.width - x1 - 18
            let origin = roomRight >= 150
                ? CGPoint(x: x1 + 10, y: rowTop + 10)
                : CGPoint(x: x0, y: rowTop + spacing + 8)
            return Placement(number: i + 1, note: mark.note, x0: x0, x1: x1, rowTop: rowTop,
                             noteOrigin: origin, noteWidth: max(80, size.width - origin.x - 8))
        }
    }
}

/// 圈出一步之后弹出：点常用的问题，或者写下想问的
private struct StepAskPopover: View {
    let disabled: Bool
    let send: (String) -> Void
    @State private var text = ""

    static let quick = ["这一步对吗？", "这一步为什么不对？", "这一步是怎么来的？", "接下来该怎么写？"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("问圈出来的这一步").font(.headline)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.quick, id: \.self) { question in
                    Button(question) { send(question) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if question != Self.quick.last { Divider() }
                }
            }
            .buttonStyle(InkTextButtonStyle())
            .disabled(disabled)
            // 输入框里可以直接用 Apple Pencil 写字，系统会转成文字
            TextField("或者写下想问的…", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .padding(10)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            Button { send(text) } label: {
                Text("发送").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(disabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(18)
        .frame(width: 380)
    }
}

// MARK: - 页边批注

/// 页边只放一张当前的批注：最近一次批改、提示、圈选提问的回答（页面宽时还有完整答案）。
/// 之前的收成一排小标签，点哪个看哪个；新的一到就翻回最新一条
struct MarginNotes: View {
    @EnvironmentObject var store: AppStore
    let setID: UUID
    let qID: UUID
    let mistakeMode: Bool
    let nextID: UUID?
    let wide: Bool
    /// 和手写区共用：选中圈选提问时，手写区上标出圈住的地方
    @Binding var selection: UUID?
    /// 点了某个小标签（包括点已经选中的那个），用来重新显示圈选提问的蓝框
    var onSelect: (ChatMessage) -> Void = { _ in }
    @State private var showCorrectDetail = false
    @State private var flash = false

    var body: some View {
        if let q = store.question(setID, qID) {
            let items = Self.items(q, wide: wide)
            let current = Self.selected(items, selection)
            let pending = store.pending[qID].flatMap { showsInMargin($0) ? $0 : nil }
            VStack(alignment: .leading, spacing: 10) {
                if items.count > 1 { tabs(items, current: current, q: q) }
                if let pending {
                    PendingNote(pending: pending)
                } else if let current {
                    note(current, in: q)
                        // 新批注到了，像用荧光笔轻轻划过一下
                        .background(Self.tint(current).opacity(flash ? 0.1 : 0))
                }
                if mistakeMode { reviewOutcome }
                if items.isEmpty && pending == nil && wide && q.status != .passed {
                    Text("写完点“批改”，结果会标在这里")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 新的批注到了：翻回最新一条，轻轻闪一下
            .onChange(of: items.last?.id) { _, newID in
                selection = nil
                showCorrectDetail = false
                guard newID != nil else { return }
                withAnimation(.easeIn(duration: 0.15)) { flash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.easeOut(duration: 0.8)) { flash = false }
                }
            }
        }
    }

    /// 页边的批注：这次作答的所有提示和圈选提问、最近一次提交的批改、（页面宽时）完整答案，按时间排
    static func items(_ q: Question, wide: Bool) -> [ChatMessage] {
        let lastSubmission = q.messages.lastIndex { $0.kind == .submission }
        let lastSolution = q.messages.lastIndex { $0.kind == .solution }
        return q.messages.indices.compactMap { i in
            let m = q.messages[i]
            switch m.kind {
            case .hint: return m
            case .verdictCorrect, .verdictWrong: return lastSubmission.map { i > $0 } == true ? m : nil
            case .chat: return m.role == .assistant && m.region != nil ? m : nil
            case .solution: return wide && i == lastSolution ? m : nil
            default: return nil
            }
        }
    }

    static func selected(_ items: [ChatMessage], _ selection: UUID?) -> ChatMessage? {
        items.first { $0.id == selection } ?? items.last
    }

    static func circled(_ n: Int) -> String {
        let digits = Array("①②③④⑤⑥⑦⑧⑨")
        return (1...digits.count).contains(n) ? String(digits[n - 1]) : "(\(n))"
    }

    private func showsInMargin(_ pending: PendingReply) -> Bool {
        switch pending.kind {
        case .verdictWrong, .verdictCorrect, .hint: return true
        case .chat: return pending.inMargin
        case .solution: return wide
        default: return false
        }
    }

    /// 批改用红笔，答案和圈选提问用蓝笔，提示是便签
    private static func tint(_ m: ChatMessage) -> Color {
        switch m.kind {
        case .verdictCorrect, .verdictWrong: return Ink.red
        case .hint: return .orange
        default: return Ink.blue
        }
    }

    // MARK: 小标签

    /// 一行小字目录：选中的加粗、下面划一道线
    private func tabs(_ items: [ChatMessage], current: ChatMessage?, q: Question) -> some View {
        FlowLayout(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, m in
                let selected = m.id == current?.id
                Button {
                    selection = m.id
                    onSelect(m)
                } label: {
                    Text(tabTitle(m, index: index, in: items))
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.vertical, 3)
                        .overlay(alignment: .bottom) {
                            if selected { Rectangle().fill(Self.tint(m)).frame(height: 1.5) }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tabTitle(_ m: ChatMessage, index: Int, in items: [ChatMessage]) -> String {
        let before = items[..<index]
        switch m.kind {
        case .verdictCorrect: return "✓ 批改"
        case .verdictWrong: return "✗ 批改"
        case .hint:
            let n = before.filter { $0.kind == .hint }.count + 1
            return "\(n) " + Tutor.hintLevelShortName(m.hintLevel ?? n)
        case .chat: return "问 \(before.filter { $0.kind == .chat }.count + 1)"
        case .solution: return "答案"
        default: return ""
        }
    }

    // MARK: 一张批注

    /// 第几档提示；旧版本的提示没有记档次，按是第几次提示算
    private func hintLevel(_ m: ChatMessage, in q: Question) -> Int {
        if let level = m.hintLevel { return level }
        guard let i = q.messages.firstIndex(where: { $0.id == m.id }) else { return 1 }
        return q.messages[...i].filter { $0.kind == .hint }.count
    }

    /// 这条回复前面学生说的话（提问、提示时的补充说明）
    private func request(before m: ChatMessage, in q: Question) -> ChatMessage? {
        guard let i = q.messages.firstIndex(where: { $0.id == m.id }) else { return nil }
        return q.messages[..<i].last { $0.role == .user }
    }

    @ViewBuilder
    private func note(_ message: ChatMessage, in q: Question) -> some View {
        switch message.kind {
        case .verdictCorrect:
            // 做对了只留一个红勾，点开再看说明
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showCorrectDetail.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        PenMark(correct: true)
                        Text(showCorrectDetail ? "收起" : "说明")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        timing(message)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("做对了")
                .accessibilityHint(showCorrectDetail ? "收起说明" : "展开说明")
                if showCorrectDetail {
                    RichText(message.text, scale: 0.92)
                }
                if let nextID {
                    Button("下一题 ↓") { store.selectedQuestionID = nextID }
                        .buttonStyle(InkTextButtonStyle())
                }
            }
        case .verdictWrong:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    PenMark(correct: false)
                    Spacer()
                    timing(message)
                }
                let marks = message.marks ?? []
                if !marks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(marks.enumerated()), id: \.offset) { i, mark in
                            // 序号和手写区上的对应，不用再写第几行；短评里的公式用 KaTeX 排版
                            HStack(alignment: .top, spacing: 6) {
                                Text(Self.circled(i + 1))
                                    .font(.callout)
                                    .foregroundStyle(Ink.red)
                                    .padding(.top, 3)
                                RichText(mark.note, scale: 0.92, tone: .red)
                            }
                        }
                    }
                }
                RichText(message.text, scale: 0.92)
            }
            .marginRule(Ink.red)
        case .hint:
            // 便签：方角、淡淡的影子，像贴在页边
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("提示 · " + Tutor.hintLevelName(hintLevel(message, in: q)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    timing(message)
                }
                if let note = request(before: message, in: q)?.note {
                    Text("我卡在：\(note)").font(.callout).foregroundStyle(.secondary)
                }
                RichText(message.text, scale: 0.92)
            }
            .padding(12)
            .background(Ink.note)
            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        case .chat:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("问这一步").font(.caption.weight(.semibold)).foregroundStyle(Ink.blue)
                    Spacer()
                    timing(message)
                }
                if let asked = request(before: message, in: q) {
                    Text(asked.text).font(.callout).foregroundStyle(.secondary)
                }
                RichText(message.text, scale: 0.92)
            }
            .marginRule(Ink.blue)
        case .solution:
            // 和左边自己的作答并排对照
            VStack(alignment: .leading, spacing: 6) {
                Text("完整答案").font(.caption.weight(.semibold)).foregroundStyle(Ink.blue)
                RichText(message.text, scale: 0.92)
            }
            .marginRule(Ink.blue)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func timing(_ message: ChatMessage) -> some View {
        if store.showTiming, let duration = message.duration {
            Text(String(format: duration < 10 ? "%.1f 秒" : "%.0f 秒", duration))
                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
        }
    }

    /// 错题复习结果
    @ViewBuilder
    private var reviewOutcome: some View {
        if let outcome = store.reviewOutcomes[qID] {
            let (icon, text, color): (String, String, Color) = {
                switch outcome {
                case .mastered(let rounds): return ("checkmark", "\(rounds) 轮就做对了，已移出错题本。", Ink.green)
                case .keep(let rounds): return ("bookmark", "这次用了 \(rounds) 轮，先留在错题本里，下次再练一遍。", Ink.red)
                case .revealed: return ("bookmark", "这次看了完整答案，先留在错题本里，过几天再练一遍。", Ink.red)
                }
            }()
            Label(text, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
        }
    }
}

/// 红笔写的勾和叉：笔画有起笔收笔的粗细变化，不用系统图标
struct PenMark: View {
    let correct: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Canvas { context, size in
                let w = size.width, h = size.height
                var path = Path()
                if correct {
                    path.move(to: CGPoint(x: w * 0.08, y: h * 0.52))
                    path.addQuadCurve(to: CGPoint(x: w * 0.38, y: h * 0.9), control: CGPoint(x: w * 0.22, y: h * 0.66))
                    path.addQuadCurve(to: CGPoint(x: w * 0.95, y: h * 0.08), control: CGPoint(x: w * 0.55, y: h * 0.45))
                } else {
                    path.move(to: CGPoint(x: w * 0.14, y: h * 0.12))
                    path.addQuadCurve(to: CGPoint(x: w * 0.86, y: h * 0.9), control: CGPoint(x: w * 0.48, y: h * 0.46))
                    path.move(to: CGPoint(x: w * 0.84, y: h * 0.1))
                    path.addQuadCurve(to: CGPoint(x: w * 0.16, y: h * 0.88), control: CGPoint(x: w * 0.54, y: h * 0.52))
                }
                context.stroke(path, with: .color(Ink.red), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 30, height: 26)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
            Text(correct ? "对了" : "还不对")
                .font(.headline)
                .foregroundStyle(Ink.red)
        }
        .accessibilityElement(children: .combine)
    }
}

/// AI 正在写的批注：判定一出来就先标上对错，说明随后补上
struct PendingNote: View {
    @EnvironmentObject var store: AppStore
    let pending: PendingReply

    var body: some View {
        let isVerdict = pending.kind == .verdictWrong || pending.kind == .verdictCorrect
        let verdict = isVerdict ? Tutor.parseVerdict(pending.text) : nil
        let shown = Tutor.hideUnfinishedTags(verdict?.feedback ?? pending.text)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let correct = verdict?.correct {
                    PenMark(correct: correct)
                } else {
                    ProgressView().controlSize(.small)
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if store.showTiming {
                    TimelineView(.periodic(from: pending.startedAt, by: 1)) { context in
                        Text("\(Int(context.date.timeIntervalSince(pending.startedAt))) 秒")
                            .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            if !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                RichText(shown, scale: 0.92)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .marginRule(.secondary)
    }

    private var label: String {
        switch pending.kind {
        case .verdictWrong, .verdictCorrect: return "正在批改…"
        case .hint: return "正在写提示…"
        case .solution: return "正在写答案…"
        default: return "正在写…"
        }
    }
}

// MARK: - 题目下方的笔记

/// 完整答案（折叠）和做完之后的笔记（总结技巧、讲思路、新题……）
struct QuestionNotes: View {
    @EnvironmentObject var store: AppStore
    let setID: UUID
    let qID: UUID
    /// 页面宽时完整答案放在页边，和自己的作答并排对照
    let wide: Bool
    @State private var showSolution = false

    var body: some View {
        if let q = store.question(setID, qID) {
            let solution = wide ? nil : q.messages.last { $0.kind == .solution }
            let pending = store.pending[qID]
            VStack(alignment: .leading, spacing: 12) {
                if let solution {
                    DisclosureGroup(isExpanded: $showSolution) {
                        RichText(solution.text)
                            .padding(.top, 8)
                    } label: {
                        Text("完整答案")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Ink.blue)
                    }
                    .tint(Ink.blue)
                    .marginRule(Ink.blue)
                    // 刚看的答案直接展开
                    .onChange(of: solution.id) { showSolution = true }
                }
                if let pending, pending.kind == .solution, !wide {
                    PendingNote(pending: pending)
                        .onDisappear { showSolution = true }
                }

                ForEach(Array(notes(q).enumerated()), id: \.element.answer.id) { _, note in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(note.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        RichText(note.answer.text)
                        ForEach(note.answer.generatedQuestionIDs, id: \.self) { id in
                            if let generated = store.question(setID, id) { NewQuestionCard(question: generated) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .marginRule(Ink.pen)
                }
                if let pending, pending.kind == .chat, !pending.inMargin {
                    PendingNote(pending: pending)
                }
            }
        }
    }

    /// 做完之后的每一问一答；标题用快捷操作的名字，自由提问就用问题本身
    private func notes(_ q: Question) -> [(title: String, answer: ChatMessage)] {
        var result: [(String, ChatMessage)] = []
        var lastQuestion: String?
        // 圈出一步来问的写在页边
        for m in q.messages where m.kind == .chat && m.region == nil {
            if m.role == .user {
                lastQuestion = store.followUps.first { $0.prompt == m.text }?.title ?? m.text
            } else {
                result.append((lastQuestion ?? "笔记", m))
                lastQuestion = nil
            }
        }
        return result
    }
}

// MARK: - 完整记录

/// 一道题的全部作答、批改、提示和对话（包括错题本重新练习之前的记录）
struct QuestionHistoryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let setID: UUID
    let qID: UUID

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let q = store.question(setID, qID) {
                        let attempts = q.previousAttempts ?? []
                        ForEach(Array(attempts.enumerated()), id: \.offset) { index, messages in
                            Text("第 \(index + 1) 次练习").font(.headline)
                            ForEach(messages) { MessageRow(message: $0, setID: setID) }
                            Divider()
                        }
                        if !attempts.isEmpty && !q.messages.isEmpty {
                            Text("这一次").font(.headline)
                        }
                        ForEach(q.messages) { MessageRow(message: $0, setID: setID) }
                    }
                }
                .padding(20)
            }
            .navigationTitle("完整记录")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
