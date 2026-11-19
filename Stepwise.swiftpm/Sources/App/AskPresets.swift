import Foundation

/// 圈出来问（做题页、笔记、白板）时的常用问题。
/// 按钮上只写两三个字（label，也是存下来、显示在页边的问题）；真正发给 AI 的是 request，说得更具体。
/// detailed 的要写详细，不受“几句话说清楚”的限制
struct AskPreset: Identifiable {
    /// 简体中文的按钮文字，也是翻译用的 key
    let key: String
    let zh: String
    let en: String
    var detailed = false

    var id: String { key }
    var label: String { L(key) }
    /// 按 AI 回答语言发过去的问题
    var request: String { Tutor.pick(zh, en) }

    enum Place { case step, note, board }

    /// 做题页：圈住自己写的一步
    static let step: [AskPreset] = [
        AskPreset(key: "对不对", zh: "圈出来的这一步对不对？有问题的话说清是哪里、为什么。",
                  en: "Is the step I circled right? If not, say where and why."),
        AskPreset(key: "解释", zh: "解释一下圈出来的这一步：它在做什么，为什么可以这样做。",
                  en: "Explain the step I circled: what it does and why it is allowed."),
        AskPreset(key: "详细过程", zh: "把圈出来这一步的过程写详细：中间省掉的每一小步都补出来，每步写清用了什么公式或性质。",
                  en: "Write out the step I circled in full: fill in every small step that was skipped, and say which formula or property each one uses.",
                  detailed: true),
        AskPreset(key: "用了什么公式", zh: "这一步用到了哪个公式、定理或性质？写出来，并说明在这里是怎么用的。",
                  en: "Which formula, theorem or property does this step use? Write it down and show how it is applied here."),
        AskPreset(key: "下一步", zh: "接下来该怎么写？只提示下一步往哪个方向走。",
                  en: "What should I write next? Just hint at the direction of the next step."),
        AskPreset(key: "换个方法", zh: "这一步有没有更简单、更不容易出错的做法？",
                  en: "Is there a simpler or less error-prone way to do this step?"),
    ]

    /// 笔记：圈住一段笔记
    static let note: [AskPreset] = [
        AskPreset(key: "解释", zh: "用更通俗的话解释圈出来的内容。",
                  en: "Explain what I circled in simpler words."),
        AskPreset(key: "详细过程", zh: "把圈出来的推导或结论的完整过程一步一步写出来，每步写清依据。",
                  en: "Write out the full derivation of what I circled, step by step, with the reason for each step.",
                  detailed: true),
        AskPreset(key: "为什么", zh: "为什么是这样？说清背后的原因。",
                  en: "Why is it like this? Explain the reason behind it."),
        AskPreset(key: "举个例子", zh: "举一个具体的例子（最好带数字）说明圈出来的内容。",
                  en: "Give a concrete example (with numbers if possible) of what I circled."),
        AskPreset(key: "易错点", zh: "学这里时常见的错误、容易混淆的地方有哪些？",
                  en: "What are the common mistakes or easily confused points here?"),
        AskPreset(key: "怎么考", zh: "这个知识点考试一般怎么考？出一道典型的小题，附上答案和简要解析。",
                  en: "How is this usually tested in exams? Give one typical short question with its answer and a brief explanation.",
                  detailed: true),
        AskPreset(key: "和前面的联系", zh: "这和笔记前面的内容有什么联系？",
                  en: "How does this connect to the earlier parts of the notes?"),
    ]

    /// 白板：框住一段题目或解答（“检查”是单独的按钮）
    static let board: [AskPreset] = [
        AskPreset(key: "解释", zh: "解释一下框住的这段：它在做什么，为什么可以这样做。",
                  en: "Explain the part I selected: what it does and why it is allowed."),
        AskPreset(key: "详细过程", zh: "把框住这段的过程写详细：中间省掉的每一小步都补出来，每步写清用了什么公式或性质。",
                  en: "Write out the part I selected in full: fill in every small step that was skipped, and say which formula or property each one uses.",
                  detailed: true),
        AskPreset(key: "下一步", zh: "接下来该怎么写？只提示下一步往哪个方向走。",
                  en: "What should I write next? Just hint at the direction of the next step."),
        AskPreset(key: "用了什么公式", zh: "这里用到了哪个公式、定理或性质？写出来，并说明在这里是怎么用的。",
                  en: "Which formula, theorem or property is used here? Write it down and show how it is applied."),
        AskPreset(key: "换个方法", zh: "有没有更简单、更不容易出错的做法？",
                  en: "Is there a simpler or less error-prone way to do this?"),
        AskPreset(key: "讲讲思路", zh: "这道题整体的解题思路是什么？分几步走、每步做什么，不用算出结果。",
                  en: "What is the overall approach to this question? Which steps, and what each one does; no need to work out the result."),
    ]

    static func presets(for place: Place) -> [AskPreset] {
        switch place {
        case .step: return step
        case .note: return note
        case .board: return board
        }
    }

    /// 存下来的问题是按钮文字时，换成发给 AI 的具体问题；自己写的问题原样发
    static func resolve(_ question: String, in place: Place) -> (text: String, detailed: Bool) {
        if let preset = presets(for: place).first(where: { $0.label == question || $0.key == question }) {
            return (preset.request, preset.detailed)
        }
        return (question, false)
    }
}

extension Tutor {
    /// 要求写详细时，代替“几句话说清楚”
    static var detailedAnswerRule: String {
        pick("这次要写详细：把过程一步一步完整写出来，每步写清依据，推导写成对齐的公式。",
             "This time, be detailed: write the process out step by step, giving the reason for each step, with derivations as aligned formulas.")
    }
}
