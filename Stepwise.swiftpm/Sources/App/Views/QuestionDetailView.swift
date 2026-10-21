import SwiftUI

struct QuestionDetailView: View {
    @EnvironmentObject var store: AppStore
    let setID: UUID
    let qID: UUID

    @StateObject private var handwriting = HandwritingModel()
    @State private var useHandwriting = false
    @State private var draft = ""
    @State private var chatInput = ""
    @State private var showSettings = false
    @State private var confirmReset = false
    @FocusState private var chatFocused: Bool

    var body: some View {
        if let q = store.question(setID, qID) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        questionCard(q)
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
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: q.messages.count) { scrollToBottom(proxy) }
                .onChange(of: store.pending[qID]?.text.count ?? -1) { scrollToBottom(proxy, animated: false) }
            }
            .safeAreaInset(edge: .bottom) {
                if q.status.isDone { chatBar }
            }
            .navigationTitle("第 \(q.label) 题")
            .toolbar { toolbar(q) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog("清空这道题的作答和对话记录，重新开始？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("清空并重做", role: .destructive) {
                    store.resetQuestion(setID, qID)
                    handwriting.clear()
                }
            }
            .onAppear { draft = q.draftAnswer }
            // 切到手写时自动收起左侧栏，书写区域更大
            .onChange(of: useHandwriting) {
                if useHandwriting { store.setFullScreen(true) }
            }
            .onDisappear { saveDraft() }
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
            }
            RichText(q.content, scale: 1.08)
            ForEach(q.imageIDs, id: \.self) { id in
                StoredImage(id: id, maxHeight: 420)
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
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

    private func passedBanner(_ q: Question) -> some View {
        let next = store.nextQuestion(after: qID, in: setID)
        return HStack(spacing: 12) {
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
                    Text("已是最后一题").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background((q.status == .passed ? Color.green : Color.blue).opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
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
                if let id = store.neighbor(of: qID, in: setID, offset: -1) { store.selectedQuestionID = id }
            } label: { Label("上一题", systemImage: "chevron.up") }
                .disabled(store.neighbor(of: qID, in: setID, offset: -1) == nil)
            Button {
                if let id = store.neighbor(of: qID, in: setID, offset: 1) { store.selectedQuestionID = id }
            } label: { Label("下一题", systemImage: "chevron.down") }
                .disabled(store.neighbor(of: qID, in: setID, offset: 1) == nil)
            Menu {
                Button("清空记录重做", systemImage: "arrow.counterclockwise", role: .destructive) { confirmReset = true }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
        }
    }

    // MARK: - 辅助

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
                }
                .padding(14)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func card(title: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color == .yellow ? Color.orange : color)
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
