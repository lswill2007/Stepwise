import SwiftUI

struct QuestionDetailView: View {
    @EnvironmentObject var store: AppStore
    let setID: UUID
    let qID: UUID
    /// 从错题本打开：上一题 / 下一题在错题本里切换，并按复习规则计轮数
    let fromMistakeBook: Bool

    @StateObject private var handwriting: HandwritingModel
    @State private var useHandwriting: Bool
    @State private var draftSaveTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    init(setID: UUID, qID: UUID, fromMistakeBook: Bool = false) {
        self.setID = setID
        self.qID = qID
        self.fromMistakeBook = fromMistakeBook
        _handwriting = StateObject(wrappedValue: HandwritingModel(questionID: qID))
        // 上次在这道题上手写过，就直接回到手写模式
        _useHandwriting = State(initialValue: HandwritingModel.isAvailable && DrawingStore.exists(qID))
    }
    @State private var draft = ""
    @State private var chatInput = ""
    @State private var showSettings = false
    @State private var confirmReset = false
    @State private var editingQuestion = false
    @FocusState private var chatFocused: Bool

    /// 题目卡片底边在滚动区域中的位置，滚到快看不见时显示置顶的题目
    @State private var cardBottom: CGFloat = .infinity
    @State private var viewHeight: CGFloat = 800
    @State private var pinnedContentHeight: CGFloat = 40
    @AppStorage("pinnedQuestionCollapsed") private var pinnedCollapsed = false

    private var showPinned: Bool { cardBottom < 90 }

    var body: some View {
        if let q = store.question(setID, qID) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        questionCard(q)
                            .id("question")
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(in: .named("detailScroll")).maxY
                            } action: { cardBottom = $0 }
                        if fromMistakeBook && q.isStarred {
                            reviewCard(q)
                        }
                        if let attempts = q.previousAttempts, !attempts.isEmpty {
                            previousAttemptsSection(attempts)
                        }
                        let split = Self.passIndex(in: q).map { $0 + 1 } ?? q.messages.count
                        ForEach(q.messages[..<split]) { message in
                            MessageRow(message: message, setID: setID)
                        }
                        if q.status.isDone {
                            passedBanner(q)
                            ForEach(q.messages[split...]) { message in
                                MessageRow(message: message, setID: setID)
                            }
                        }
                        if let pending = store.pending[qID] {
                            PendingRow(pending: pending) { store.cancelReply(qID) }
                        }
                        if q.status.isDone {
                            followUpChips
                        } else {
                            answerComposer(q)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(20)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "detailScroll")
                .scrollDismissesKeyboard(.interactively)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewHeight = $0 }
                .onChange(of: q.messages.count) { scrollToBottom(proxy) }
                .onChange(of: store.pending[qID]?.text.count ?? -1) { scrollToBottom(proxy, animated: false) }
                // 题目滚出视野时浮在最上面
                .overlay(alignment: .top) {
                    if showPinned {
                        pinnedQuestion(q) {
                            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("question", anchor: .top) }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: showPinned)
            }
            .safeAreaInset(edge: .bottom) {
                if q.status.isDone { chatBar }
            }
            .navigationTitle("第 \(q.label) 题")
            #if os(iOS)
            // 小标题：大标题会和滚到下面的内容、置顶的题目叠在一起
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbar(q) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $editingQuestion) {
                EditQuestionView(setID: setID, qID: qID)
            }
            .confirmationDialog("清空这道题的作答和对话记录，重新开始？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("清空并重做", role: .destructive) {
                    store.resetQuestion(setID, qID)
                    draftSaveTask?.cancel()
                    draft = ""
                    handwriting.clear()
                }
            }
            .onAppear {
                draft = q.draftAnswer
                // 从错题本打开还没做完的题：开始计复习轮数
                if fromMistakeBook { store.beginReviewIfNeeded(setID, qID) }
            }
            // 切到手写时自动收起左侧栏，书写区域更大
            .onChange(of: useHandwriting) {
                if useHandwriting { store.setFullScreen(true) }
            }
            // 打字停顿 1 秒自动保存草稿
            .onChange(of: draft) {
                draftSaveTask?.cancel()
                draftSaveTask = Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    saveDraft()
                }
            }
            // 退到后台 / 关闭 App 前立即保存
            .onChange(of: scenePhase) {
                if scenePhase != .active { saveEverything() }
            }
            // 检查通过后，写过的草稿已经作为作答记录保存，清掉
            .onChange(of: q.status) {
                if q.status == .passed {
                    draftSaveTask?.cancel()
                    draft = ""
                    handwriting.clear()
                }
            }
            .onDisappear { saveEverything() }
        }
    }

    // MARK: - 题目

    private func questionCard(_ q: Question) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("第 \(q.label) 题").font(.title3.bold())
                StatusPill(status: q.status)
                if q.isGenerated {
                    Text("AI 新题").font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
                }
                Spacer()
                if let set = store.set(setID), let i = set.questions.firstIndex(where: { $0.id == qID }) {
                    Text("\(i + 1) / \(set.questions.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { store.toggleStar(setID, qID) }
                } label: {
                    Label(q.isStarred ? "已加入错题本" : "错题", systemImage: q.isStarred ? "bookmark.fill" : "bookmark")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background((q.isStarred ? Color.red : Color.secondary).opacity(q.isStarred ? 0.15 : 0.1), in: Capsule())
                        .foregroundStyle(q.isStarred ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(q.isStarred ? "移出错题本" : "加入错题本")
            }
            RichText(q.content, scale: 1.08)
            ForEach(q.imageIDs, id: \.self) { id in
                StoredImage(id: id, maxHeight: 420)
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    /// 置顶的题目：短题完整显示，长题限制高度可在内部滚动，也可以收起成一行
    private func pinnedQuestion(_ q: Question, backToTop: @escaping () -> Void) -> some View {
        let maxHeight = max(120, viewHeight * 0.33)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("第 \(q.label) 题").font(.subheadline.bold())
                StatusPill(status: q.status)
                if pinnedCollapsed {
                    Text(Tutor.plainPreview(q.content))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: backToTop) {
                    Image(systemName: "arrow.up.to.line")
                }
                .accessibilityLabel("回到题目")
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { pinnedCollapsed.toggle() }
                } label: {
                    Image(systemName: pinnedCollapsed ? "chevron.down" : "chevron.up")
                }
                .accessibilityLabel(pinnedCollapsed ? "展开题目" : "收起题目")
            }
            .buttonStyle(.borderless)
            .font(.callout)

            if !pinnedCollapsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        RichText(q.content)
                        ForEach(q.imageIDs, id: \.self) { id in
                            StoredImage(id: id, maxHeight: 200)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pinnedContentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(pinnedContentHeight, 24), maxHeight))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 作答区（未通过）

    private func answerComposer(_ q: Question) -> some View {
        let busy = store.isBusy(qID)
        let canSubmit = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (useHandwriting && !handwriting.isEmpty)
        let wrong = q.status == .wrong

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(wrong ? "修改后再检查一次" : "你的作答").font(.headline)
                Spacer()
                if HandwritingModel.isAvailable {
                    Picker("作答方式", selection: $useHandwriting) {
                        Label("键盘", systemImage: "keyboard").tag(false)
                        Label("手写", systemImage: "pencil.tip").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }

            if useHandwriting {
                HandwritingPad(model: handwriting, fullScreen: store.isFullScreen)
            }

            if !useHandwriting {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Button(symbol) { draft += symbol }
                                .buttonStyle(.bordered)
                                .font(.body.monospaced())
                        }
                    }
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .frame(minHeight: useHandwriting ? 60 : 130)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                if draft.isEmpty {
                    Text(useHandwriting ? "可以补充文字说明（可选）" : "在这里写下答案和解题过程…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }

            // 作答里写了 LaTeX（$...$）时显示排版预览
            if draft.contains("$") || draft.contains("\\(") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("公式预览").font(.caption).foregroundStyle(.secondary)
                    RichText(draft)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }

            Button {
                saveDraft()
                let image = useHandwriting ? handwriting.exportJPEG() : nil
                store.check(setID, qID, answer: draft, handwriting: image)
            } label: {
                Label("检查答案", systemImage: "checkmark.seal")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy || !canSubmit)

            HStack(spacing: 12) {
                Button {
                    store.requestHint(setID, qID)
                } label: {
                    Label(q.hintCount == 0 ? "需要提示" : "需要进一步提示", systemImage: "lightbulb")
                        .frame(maxWidth: .infinity)
                }
                .tint(.orange)
                Button {
                    store.requestSolution(setID, qID)
                } label: {
                    Label("给出完整答案", systemImage: "text.book.closed")
                        .frame(maxWidth: .infinity)
                }
                .tint(.blue)
            }
            .buttonStyle(.bordered)
            .controlSize(wrong ? .large : .regular)
            .disabled(busy)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).stroke(wrong ? Color.orange.opacity(0.5) : Color.secondary.opacity(0.25)))
    }

    /// 作答时常用的符号（追加到末尾），AI 能直接理解
    private static let symbols = ["²", "³", "√", "π", "±", "×", "÷", "≤", "≥", "≠", "≈", "∞", "°", "∠", "△", "⊥", "∥", "∈", "∪", "∩", "→", "⇒", "α", "β", "θ", "Δ"]

    // MARK: - 通过后

    private static let followUps: [(String, String)] = [
        ("出一道类似的新题", "请出一道考查相同知识点的类似新题。"),
        ("出一道更难的题", "请出一道考查相同知识点、但更难一些的新题。"),
        ("总结做题技巧", "请总结这道题用到的做题技巧和通用方法，以后遇到类似的题应该怎么想？"),
        ("讲讲解题思路", "请从头讲一下这道题的解题思路：拿到题目时先注意什么，突破口在哪里？"),
        ("还有别的解法吗", "这道题还有其他解法吗？请和原来的方法比较一下。"),
        ("常见易错点", "这类题有哪些常见的易错点？")
    ]

    /// 通过这道题的那条消息（第一次判对或看完整答案），之后的消息都是通过后的对话
    static func passIndex(in q: Question) -> Int? {
        guard q.status.isDone else { return nil }
        return q.messages.firstIndex { $0.kind == .verdictCorrect || $0.kind == .solution }
    }

    // MARK: - 错题复习

    /// 错题本里打开时的提示：已做完的题可以重新练习；复习中显示已用轮数
    @ViewBuilder
    private func reviewCard(_ q: Question) -> some View {
        // 已做完、不在复习中的错题：随时可以重新练习（包括刚看完答案或用了 3 轮以上的）
        if q.status.isDone && q.reviewRounds == nil {
            HStack(spacing: 12) {
                Image(systemName: "arrow.counterclockwise.circle.fill").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.reviewOutcomes[qID] == nil ? "这道题之前已经做过" : "想再练一遍？").font(.headline)
                    Text("重新做一遍来巩固：\(AppStore.masteryRounds) 轮之内做对，就会从错题本移出").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation { store.startReview(setID, qID) }
                    draft = ""
                    handwriting.clear()
                } label: {
                    Label("重新练习", systemImage: "play.fill").font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(14)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        } else if let rounds = q.reviewRounds {
            Label {
                Text(rounds == 0
                     ? "错题复习中 · \(AppStore.masteryRounds) 轮之内做对就移出错题本（检查一次或提示一次算一轮）"
                     : "错题复习中 · 已用 \(rounds) 轮" + (rounds < AppStore.masteryRounds ? "，这一轮做对就移出错题本" : "，这次做对也会留在错题本里"))
            } icon: {
                Image(systemName: "bookmark.fill")
            }
            .font(.callout)
            .foregroundStyle(.red)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// 复习结果提示
    @ViewBuilder
    private func reviewOutcomeBanner() -> some View {
        if let outcome = store.reviewOutcomes[qID] {
            let (icon, text, color): (String, String, Color) = {
                switch outcome {
                case .mastered(let rounds):
                    return ("checkmark.seal.fill", "\(rounds) 轮就做对了，已经掌握！这道题已移出错题本。", .green)
                case .keep(let rounds):
                    return ("bookmark.fill", "这次用了 \(rounds) 轮，先留在错题本里，下次再练一遍。", .orange)
                case .revealed:
                    return ("bookmark.fill", "这次看了完整答案，先留在错题本里，过几天再练一遍。", .orange)
                }
            }()
            Label(text, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// 重新练习之前的作答记录，默认折叠
    private func previousAttemptsSection(_ attempts: [[ChatMessage]]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(attempts.enumerated()), id: \.offset) { index, messages in
                    Text("第 \(index + 1) 次作答").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(messages) { message in
                        MessageRow(message: message, setID: setID)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("之前的作答记录（\(attempts.count) 次）", systemImage: "clock.arrow.circlepath")
                .font(.callout)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 题目切换

    /// 上一题 / 下一题：错题本里按错题本顺序，否则按题集顺序
    private func neighborID(_ offset: Int) -> UUID? {
        guard fromMistakeBook else { return store.neighbor(of: qID, in: setID, offset: offset) }
        let ids = store.starredEntries.map(\.question.id)
        guard let i = ids.firstIndex(of: qID) else {
            // 当前题已经移出错题本：下一题就是错题本里的第一题
            return offset > 0 ? ids.first : nil
        }
        let j = i + offset
        return ids.indices.contains(j) ? ids[j] : nil
    }

    private var nextID: UUID? {
        fromMistakeBook ? neighborID(1) : store.nextQuestion(after: qID, in: setID)
    }

    private func passedBanner(_ q: Question) -> some View {
        let next = nextID
        return VStack(spacing: 10) {
            reviewOutcomeBanner()
            HStack(spacing: 12) {
                Image(systemName: q.status == .passed ? "party.popper.fill" : "book.fill")
                    .font(.title)
                    .foregroundStyle(q.status == .passed ? .green : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.status == .passed ? "很好！这道题通过了" : "已经看过完整答案")
                        .font(.headline)
                    Text(q.status == .passed ? "可以做下一题，也可以继续和 AI 聊聊这道题" : "弄懂了就继续吧，也可以让 AI 再出一道类似的题练练手")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let next {
                    Button {
                        store.selectedQuestionID = next
                    } label: {
                        Label("下一题", systemImage: "arrow.right")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Text(fromMistakeBook ? "错题本里没有下一题了" : "已是最后一题").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background((q.status == .passed ? Color.green : Color.blue).opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var followUpChips: some View {
        // 自动换行，所有按钮都能直接看到
        FlowLayout(spacing: 8) {
            ForEach(Array(Self.followUps.enumerated()), id: \.offset) { index, item in
                Button(item.0) { store.sendChat(setID, qID, text: item.1) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(index < 2 ? .purple : .accentColor)
            }
        }
        .disabled(store.isBusy(qID))
    }

    private var chatBar: some View {
        let busy = store.isBusy(qID)
        return HStack(alignment: .bottom, spacing: 10) {
            TextField("继续提问，或让 AI 出一道新题…", text: $chatInput, axis: .vertical)
                .lineLimit(1...5)
                .focused($chatFocused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                .onSubmit(send)
            if busy {
                Button { store.cancelReply(qID) } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 32))
                }
                .buttonStyle(.plain)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func send() {
        guard !store.isBusy(qID) else { return }
        store.sendChat(setID, qID, text: chatInput)
        chatInput = ""
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private func toolbar(_ q: Question) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.setFullScreen(!store.isFullScreen)
            } label: {
                Label(store.isFullScreen ? "显示题目列表" : "全屏做题",
                      systemImage: store.isFullScreen ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
            }
            ModelMenu { showSettings = true }
            Button {
                if let id = neighborID(-1) { store.selectedQuestionID = id }
            } label: { Label("上一题", systemImage: "chevron.up") }
                .disabled(neighborID(-1) == nil)
            Button {
                if let id = neighborID(1) { store.selectedQuestionID = id }
            } label: { Label("下一题", systemImage: "chevron.down") }
                .disabled(neighborID(1) == nil)
            Menu {
                Button("编辑题目", systemImage: "square.and.pencil") { editingQuestion = true }
                Button("清空记录重做", systemImage: "arrow.counterclockwise", role: .destructive) { confirmReset = true }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
        }
    }

    // MARK: - 辅助

    private func saveEverything() {
        draftSaveTask?.cancel()
        saveDraft()
        handwriting.saveNow()
        store.saveNow()
    }

    private func saveDraft() {
        let text = draft
        store.mutate(setID, qID) { q in
            if q.draftAnswer != text { q.draftAnswer = text }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

// MARK: - 消息

struct StatusPill: View {
    let status: QuestionStatus

    var body: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .todo: return ("未作答", .gray)
            case .wrong: return ("待订正", .orange)
            case .passed: return ("已通过", .green)
            case .revealed: return ("已看答案", .blue)
            }
        }()
        Text(text).font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct MessageRow: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let setID: UUID

    var body: some View {
        switch message.kind {
        case .submission:
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .leading, spacing: 8) {
                    Text("我的作答").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if !message.text.isEmpty { RichText(message.text) }
                    ForEach(message.imageIDs, id: \.self) { StoredImage(id: $0, maxHeight: 220) }
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }

        case .verdictCorrect:
            card(title: "回答正确", icon: "checkmark.circle.fill", color: .green)

        case .verdictWrong:
            card(title: "还不对，问题在这里", icon: "xmark.circle.fill", color: .orange)

        case .hint:
            card(title: "提示", icon: "lightbulb.fill", color: .yellow)

        case .solution:
            card(title: "完整解答", icon: "text.book.closed.fill", color: .blue)

        case .hintRequest, .solutionRequest:
            HStack {
                Spacer()
                Text(message.text).font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

        case .chat:
            if message.role == .user {
                HStack {
                    Spacer(minLength: 80)
                    RichText(message.text)
                        .padding(12)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    RichText(message.text)
                    ForEach(message.generatedQuestionIDs, id: \.self) { id in
                        if let q = store.question(setID, id) { NewQuestionCard(question: q) }
                    }
                    if let timing = timingText {
                        Text(timing).font(.caption2).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(14)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    /// “用时 3.2 秒 · 模型名”
    private var timingText: String? {
        guard store.showTiming, let duration = message.duration else { return nil }
        let seconds = String(format: duration < 10 ? "%.1f" : "%.0f", duration)
        if let model = message.model, !model.isEmpty { return "用时 \(seconds) 秒 · \(model)" }
        return "用时 \(seconds) 秒"
    }

    private func card(title: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color == .yellow ? Color.orange : color)
                Spacer(minLength: 8)
                if let timing = timingText {
                    Text(timing).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            RichText(message.text)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct NewQuestionCard: View {
    @EnvironmentObject var store: AppStore
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("新题已加入题目列表：第 \(question.label) 题", systemImage: "plus.square.on.square")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.purple)
            RichText(question.content, scale: 0.95)
            Button {
                store.selectedQuestionID = question.id
            } label: {
                Label("去做这道题", systemImage: "arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PendingRow: View {
    @EnvironmentObject var store: AppStore
    let pending: PendingReply
    let onStop: () -> Void

    var body: some View {
        let verdict = isVerdict ? Tutor.parseVerdict(pending.text) : nil
        let shown = verdict?.feedback ?? Tutor.hideUnfinishedTags(pending.text)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if let correct = verdict?.correct {
                    Label(correct ? "回答正确" : "还不对，问题在这里", systemImage: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(correct ? .green : .orange)
                } else {
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if store.showTiming {
                    // 实时显示已经等了多久
                    TimelineView(.periodic(from: pending.startedAt, by: 1)) { context in
                        Text("\(Int(context.date.timeIntervalSince(pending.startedAt))) 秒")
                            .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                Button("停止", action: onStop).font(.callout).buttonStyle(.borderless)
            }
            if !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                RichText(shown)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var isVerdict: Bool { pending.kind == .verdictWrong || pending.kind == .verdictCorrect }

    private var label: String {
        if isVerdict { return "正在批改…" }
        if !pending.text.isEmpty { return "正在回答…" }
        switch pending.kind {
        case .hint: return "正在想提示…"
        case .solution: return "正在写完整解答…"
        default: return "思考中…"
        }
    }
}

/// 手动修改题目内容（例如补上漏掉的选项），带公式预览
struct EditQuestionView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let setID: UUID
    let qID: UUID

    @State private var content = ""
    @State private var answer = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $content)
                        .font(.body.monospaced())
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("题目")
                } footer: {
                    Text("公式用 LaTeX：行内 $...$，单独一行 $$...$$。选择题的选项每个单独一行，例如 A. $x>0$")
                }
                Section("预览") {
                    RichText(content, scale: 1.05)
                }
                Section {
                    TextEditor(text: $answer)
                        .font(.body.monospaced())
                        .frame(minHeight: 100)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("参考答案（可选）")
                } footer: {
                    Text("只给 AI 判题用，做题时不会显示。")
                }
            }
            .navigationTitle("编辑题目")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let newContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                        let newAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.mutate(setID, qID) { q in
                            q.content = newContent
                            q.referenceAnswer = newAnswer.isEmpty ? nil : newAnswer
                        }
                        dismiss()
                    }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let q = store.question(setID, qID) {
                    content = q.content
                    answer = q.referenceAnswer ?? ""
                }
            }
        }
    }
}
