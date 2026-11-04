import SwiftUI

// MARK: - 消息

struct StatusPill: View {
    let status: QuestionStatus

    var body: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .todo: return ("未作答", .secondary)
            case .wrong: return ("待订正", Ink.red)
            case .passed: return ("已做对", Ink.green)
            case .revealed: return ("看过答案", Ink.blue)
            }
        }()
        // 只是一行小字，不做成彩色胶囊
        Text(text).font(.caption).foregroundStyle(color)
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
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

        case .verdictCorrect:
            card(title: "对了", color: Ink.red)

        case .verdictWrong:
            card(title: "还不对", color: Ink.red)

        case .hint:
            card(title: "提示", color: .secondary)

        case .solution:
            card(title: "完整答案", color: Ink.blue)

        case .hintRequest, .solutionRequest:
            VStack(alignment: .trailing, spacing: 6) {
                Text(message.text).font(.callout).foregroundStyle(.secondary)
                if let note = message.note {
                    Text("我卡在：\(note)")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .chat:
            if message.role == .user {
                HStack {
                    Spacer(minLength: 80)
                    RichText(message.text)
                        .padding(12)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
                .marginRule(Ink.pen)
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

    private func card(title: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                Spacer(minLength: 8)
                if let timing = timingText {
                    Text(timing).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            RichText(message.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .marginRule(color)
    }
}

struct NewQuestionCard: View {
    @EnvironmentObject var store: AppStore
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("第 \(question.label) 题 · 已加到题目列表")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            RichText(question.content, scale: 0.95)
            Button("去做这道题 →") { store.selectedQuestionID = question.id }
                .buttonStyle(InkTextButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 像夹在笔记本里的一张卡片
        .background(Color.secondary.opacity(0.05))
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
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
                            // 题目改了，之前预先求解的答案就不能用了
                            if q.content != newContent { q.aiAnswer = nil }
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
