import Foundation

// MARK: - 英文提示词
//
// 和中文提示词一一对应（中文版在 Tutor.swift、Notes.swift、NoteGuide.swift 里，名字带 ZH）。
// 按“AI 回答语言”选用哪一套：改提示词时两边一起改。输出用的标签（<verdict>、<question> 等）两套完全一样。

extension Tutor {
    static var formatRule: String { pick(formatRuleZH, formatRuleEN) }

    /// 英文提示词里的数量：1 question / 2 questions
    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    static let formatRuleEN = """
    Formatting rules:
    - Write in English.
    - Write every mathematical expression in LaTeX: inline as $...$, on its own line as $$...$$. Even a single variable or a simple expression (e.g. $x$, $a_1$, $3\\times 4$) goes inside $.
    - Align multi-step derivations at the equals signs with $$\\begin{aligned} ... \\end{aligned}$$; use \\begin{cases} for systems of equations, \\frac for fractions, \\sqrt for roots, \\vec for vectors and \\angle for angles.
    - Write chemical formulas and equations with $\\ce{...}$, e.g. $\\ce{2H2 + O2 -> 2H2O}$.
    - Do not piece formulas together from Unicode symbols or plain text (no x^2 or sqrt(2)).
    - Markdown **bold**, lists and tables are allowed.
    """

    // MARK: 拆分题目

    static func splitSystem(requirement: String, hasImages: Bool, multiPart: Bool = false) -> String {
        guard AILanguage.isEnglish else { return splitSystemZH(requirement: requirement, hasImages: hasImages, multiPart: multiPart) }
        var s = """
        You organize exam and homework questions. The user will provide the content of a question file (text or images). Split out every question in it, completely and accurately.

        Rules:
        1. Keep each question's full stem, all answer choices, sub-questions and given conditions, copied word for word in the original language. Do not rewrite or solve them.
        1a. [Never drop answer choices] The choices of a multiple-choice question are part of the question: A, B, C, D (and E, F, ... if present) must all go inside <content>, right after the stem, one choice per line, e.g. "A. $x>0$". If the original lays the choices out in a row, in two columns or in a table, still put one per line. Do not omit or merge choices, and do not put them in <answer>.
        2. Use the original question number as the label (e.g. 1, 2(3), II.4). If there is none, number the questions in order.
        3. If the file includes the answer or worked solution for a question, put it in <answer>; otherwise leave out <answer>. Do not treat the answer section itself as questions.
        4. By default a question and all its sub-parts count as one question; if the splitting instructions say otherwise, follow them.
        5. Ignore headers, footers, page numbers, exam instructions and anything else that is not a question.
        6. Transcribe every formula in standard LaTeX (inline $...$, on its own line $$...$$, chemistry $\\ce{...}$), exactly matching the original.
        7. If a figure in a question cannot be transcribed, describe its role in one sentence, e.g. "(See figure: right triangle $ABC$, $\\angle C=90^\\circ$)".
        """
        if hasImages {
            s += "\n8. The content is given as images. Set the page attribute to the number of the image that contains the question's stem (the first image is 1). If the question has a figure, table or circuit diagram that cannot be fully expressed in text, add figure=\"1\"."
        }
        if multiPart {
            s += "\n9. This is only part of the file, and it overlaps the neighboring parts by one page: output only the questions whose stem is visible in this part. If a question's answer or solution appears in this part (including pages after the stem), include it in <answer>. If this part contains no question stems, output only <title></title>."
        }
        if !requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "\n\nSplitting instructions (these take priority): \(requirement)"
        }
        s += """


        Output exactly in the format below, with no other text:
        <title>A short name for this question set, based on its content</title>
        <question label="1"\(hasImages ? " page=\"1\"" : "")>
        <content>
        Full question stem
        A. Choice one
        B. Choice two
        C. Choice three
        D. Choice four
        (no choice lines if it is not multiple choice)
        </content>
        <answer>
        The answer included in the file (leave out the whole answer tag if there is none)
        </answer>
        </question>
        <question label="2"\(hasImages ? " page=\"1\"" : "")>
        ...
        </question>
        """
        return s
    }

    static func missingOptionsFollowUp(labels: [String]) -> String {
        guard AILanguage.isEnglish else { return missingOptionsFollowUpZH(labels: labels) }
        let list = labels.map { "question \($0)" }.joined(separator: ", ")
        let looks = labels.count == 1 ? "looks like a multiple-choice question, but the stem you output has" : "look like multiple-choice questions, but the stems you output have"
        return """
        A check found that \(list) \(looks) no choices. Compare with the original and output only these questions again, including all of their choices (A, B, C, D, ..., one per line, inside <content>). Use the same format as before (<question label="…"><content>…</content><answer>…</answer></question>). Do not output any other questions, and do not output <title>. If a question really has no choices in the original, output it unchanged.
        """
    }

    // MARK: 辅导

    static func tutorSystem(for q: Question, origin: String? = nil) -> String {
        guard AILanguage.isEnglish else { return tutorSystemZH(for: q, origin: origin) }
        var answerSection: String
        if let ref = q.referenceAnswer, !ref.isEmpty {
            answerSection = "[Reference answer] (for judging correctness only; the student cannot see it. Do not reveal it before the student asks for the full solution.)\n\(ref)"
        } else if let solved = q.aiAnswer, !solved.isEmpty {
            answerSection = "[Reference answer] (solved in advance by AI, for judging correctness only; the student cannot see it. Do not reveal it before the student asks for the full solution. It is usually reliable; if it disagrees with the student's work, quickly double-check the reference answer itself first.)\n\(solved)"
        } else {
            answerSection = "[Reference answer] None. Solve the question carefully yourself and check your work before judging the student."
        }
        if let origin, !origin.isEmpty {
            answerSection += """


            [Memory of the original question] This question was generated from an original question the student already worked on. Mistakes the student made there are likely to come back: watch for them when checking and giving hints, and when you see the same kind of mistake, say so directly ("Just like in the original question, ...").
            \(origin)
            """
        }
        return """
        You are a patient, rigorous tutor working one-on-one with a student on the question below.

        [Question] \(q.label)
        \(q.content)

        \(answerSection)

        Tutoring principles: encourage the student to think independently. Until the student has passed this question (answered it correctly or already viewed the full solution), do not give away the final answer.

        When the student asks you for a new question: use the student's work on this question so that the new question tests where they went wrong before. First explain in a sentence or two what the question tests, then give it in the format below (you may give several, one set of tags each). Put the new question's answer only inside <answer>, never outside the tags:
        <new_question>
        <content>Full question stem (including choices, one per line)</content>
        <answer>Reference answer and a brief explanation</answer>
        </new_question>

        \(formatRule)
        """
    }

    static func checkInstruction(lineNumbers: Bool) -> String {
        guard AILanguage.isEnglish else { return checkInstructionZH(lineNumbers: lineNumbers) }
        var s = """
        Please check my work (if there is an image, it is my handwritten answer). Like a teacher sitting next to me, go through it step by step in the order I wrote it, starting from the first step.
        On the first line, output only <verdict>correct</verdict> or <verdict>wrong</verdict> (this is for the app; I won't see it). From the second line on, write your feedback to me:
        - Go through the steps in order: briefly confirm the steps that are right (e.g. "The derivative in the first two lines is fine"), and stop to explain in detail at the first place where something goes wrong.
        - For that step: say which step it is (quote what I wrote), which concept or calculation the problem is in and why it doesn't work, then point me to where I should check. Do not give the correct result of that step, and do not give the full solution.
        - If later steps are wrong only because of that earlier step, don't pick them apart one by one; just say "once this step is fixed, redo the steps that follow". If there are other, separate problems later on, point them out too.
        - Keep the tone calm and matter-of-fact, as if we are working through it together. Don't open with a verdict like "wrong" or "incorrect", and don't lecture; you can start with what I did well.
        - Judge correct when the result and the necessary working are right: confirm it briefly and point out the key idea of the question.
        - If the question asks for working and I only wrote the result, judge wrong and say which working still needs to be added.
        - Be concise: a phrase for each correct step, and spend the words on the step that went wrong; 3–6 sentences overall.
        """
        if lineNumbers {
            s += """

            - The gray numbers on the left of the handwriting image are line numbers. When you judge wrong, at the end of the feedback write one separate line for each place that needs fixing: <mark line="line number">one sentence on what to look at again in this line and why</mark>, where the line number is the one to the left of the line with the problem; at most 3 places. Wrap formulas in the note with $...$, but do not give the correct answer. When you judge correct, do not write any mark.
            """
        }
        return s
    }

    static func hintInstruction(level: Int, note: String? = nil) -> String {
        guard AILanguage.isEnglish else { return hintInstructionZH(level: level, note: note) }
        let detail: String
        switch level {
        case 1:
            detail = "This time, give a \"direction\" hint: only say which direction to think in and which concept or method to use; don't get into specific steps or expressions."
        case 2:
            detail = "This time, give the \"key step\": say what the most important step of this question is (you may write the key relation), but don't carry the calculation further."
        default:
            detail = "This time, tell me \"what to write next\": based on what I've written so far, tell me concretely what to write next (you may give the expression for the next step), but don't give the final answer."
        }
        var s = """
        I need a hint (this is hint number \(level)). \(detail)
        Each hint should be one step more specific than the previous ones and guide me to figure it out myself. Keep it short, a few sentences at most.
        """
        if let note, !note.isEmpty {
            s += "\n\n[My note] \(note)\nPlease aim the hint at the place where I said I'm stuck."
        }
        return s
    }

    static func stuckInstruction(hasImage: Bool, typed: String) -> String {
        guard AILanguage.isEnglish else { return stuckInstructionZH(hasImage: hasImage, typed: typed) }
        var s = "I'm stuck and can't keep going."
        if hasImage {
            s += " The attached image is my handwriting so far (the gray numbers on the left are line numbers)."
        }
        if !typed.isEmpty {
            s += "\n[What I typed]\n\(clip(typed, 1500))"
        }
        if !hasImage && typed.isEmpty {
            s += " I haven't written anything yet and don't know where to start."
        }
        s += """

        Please:
        1. Quickly go through the steps I've written, in order, and find where I'm stuck: usually it's the last step I wrote, but it may be that an earlier step went wrong and that's why I can't continue.
        2. In your first sentence, say exactly where I'm stuck (e.g. "You're stuck on solving $f'(x)=0$"), quoting what I wrote or the line number.
        3. If an earlier step went wrong and caused it, say which step and why, so I can go back and fix it.
        4. If everything before is fine, give me a nudge at the point where I stopped: which condition or method to use for this step, or which way to transform the expression. You may write the key relation, but don't carry the calculation further for me, and don't give the final answer.
        5. Keep the tone calm, like a teacher sitting next to me, and be brief: 3–5 sentences.
        """
        return s
    }

    static func stepQuestion(_ text: String, done: Bool) -> String {
        guard AILanguage.isEnglish else { return stepQuestionZH(text, done: done) }
        var s = "[The step I circled] See the part circled in blue in the handwriting image (the gray numbers on the left are line numbers).\n" + text
        if !done {
            s += "\n(I haven't finished this question yet: answer only about the step I circled. You can point out a problem or suggest a direction, but don't give the final answer.)"
        }
        return s + "\nPlease answer briefly, a few sentences at most."
    }

    static var solutionInstruction: String {
        pick(solutionInstructionZH, "Please give the full answer to this question with a detailed worked solution (write derivations as aligned formulas), and finish by summarizing the key points of the solution.")
    }

    // MARK: 预先求解

    static func presolveSystem(for q: Question) -> String {
        guard AILanguage.isEnglish else { return presolveSystemZH(for: q) }
        return """
        You are a rigorous problem solver. Solve the question below carefully. The result will be used later to check the student's work; the student cannot see it.

        [Question] \(q.label)
        \(q.content)

        Requirements:
        - Double-check your work before writing it out.
        - Output only the final answer and the key steps, concisely, in no more than 12 lines; for multiple choice, state the letter of the correct choice; if there are several sub-questions, give the answer to each in turn.
        - No small talk, and don't explain what you're doing.

        \(formatRule)
        """
    }

    static var presolveInstruction: String { pick(presolveInstructionZH, "Please solve this question.") }

    // MARK: 精简上下文

    static func progressSummary(_ messages: [ChatMessage]) -> String? {
        guard AILanguage.isEnglish else { return progressSummaryZH(messages) }
        var lines: [String] = []
        var attempts = 0, hints = 0
        for m in messages {
            switch m.kind {
            case .verdictWrong, .verdictCorrect:
                attempts += 1
                let result = m.kind == .verdictCorrect ? "correct" : "wrong"
                lines.append("- Attempt \(attempts): judged \(result). Feedback at the time: \(clip(m.text, 300))")
            case .hintRequest:
                if let note = m.note, !note.isEmpty {
                    lines.append("- When asking for a hint, the student added: \(clip(note, 200))")
                }
            case .hint:
                hints += 1
                lines.append("- Hint \(hints): \(clip(m.text, 300))")
            case .solution:
                lines.append("- The student has already viewed the full solution.")
            default:
                break
            }
        }
        guard !lines.isEmpty else { return nil }
        let kept = lines.suffix(8)
        var s = "[Earlier work] \(count(attempts, "attempt", "attempts")) and \(count(hints, "hint", "hints")) in total"
        if kept.count < lines.count { s += " (only the latest \(kept.count) are listed)" }
        return s + "\n" + kept.joined(separator: "\n")
    }

    static var regradeNote: String {
        pick(regradeNoteZH, "The record above is only to show my progress. Check the answer below on its own merits; don't judge it wrong because I got it wrong before. If a mistake pointed out earlier is still there, just mention it briefly instead of repeating the whole feedback.")
    }

    static func originNote(for source: Question) -> String {
        guard AILanguage.isEnglish else { return originNoteZH(for: source) }
        let history = (source.previousAttempts ?? []).flatMap { $0 } + source.messages
        var s = "Original question (question \(source.label)):\n" + clip(source.content, 800) + "\n\n"
        s += progressSummary(history) ?? "The student has no recorded mistakes on the original question."
        if let earlier = source.originNote {
            s += "\n\nAn earlier original question:\n" + clip(earlier, 800)
        }
        return s
    }

    // MARK: 笔记

    static func noteSystem(prompt: String, exercises: NoteExerciseLevel, hasImages: Bool, multiPart: Bool, first: Bool) -> String {
        guard AILanguage.isEnglish else {
            return noteSystemZH(prompt: prompt, exercises: exercises, hasImages: hasImages, multiPart: multiPart, first: first)
        }
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = """
        You are a teacher who is good at organizing study material. The student has uploaded study material (slides, handouts or a textbook) to preview and review. Following the student's request, turn it into clear, well-structured study notes that explain things well.

        [The student's request]
        \(request.isEmpty ? "Turn this into notes for previewing and reviewing: by section, list the core concepts, formulas, methods and common mistakes" : request)

        Output format: output a series of note blocks in order, each wrapped in a pair of <note> tags, one block per section or concept:
        <note>
        ## Section title
        Body (Markdown: lists, **bold**, tables; formulas in LaTeX)
        </note>

        The notes are shown on a tablet, so a line can't hold much: keep tables narrow, usually no more than 4 columns, with only short words or formulas in the cells; put longer explanations below the table.
        """
        let exerciseFormat = """
            <exercise>
            <content>Full question stem (including choices, one per line)</content>
            <answer>Reference answer and a brief explanation</answer>
            </exercise>
            """
        switch exercises {
        case .off:
            s += "\n\nDo not include practice questions."
        case .needed:
            s += "\n\nPractice questions: don't add questions for concepts that already have worked examples in the material. If an important concept has no example in the material, add one practice question right after the <note> that covers it, to check that the student really understands. Keep it moderately difficult and solvable in a few steps:\n" + exerciseFormat
        case .more:
            s += "\n\nPractice questions: right after the <note> for each important concept, add 1–2 practice questions (one set of tags each), from easier to harder, to check that the student really understands. Don't copy the examples from the material; you may write variations of them. Each question should be solvable in a few steps:\n" + exerciseFormat
        }
        if first {
            s += "\n\nAt the very beginning, give these notes a short title in <title>…</title> (no more than 8 words)."
        }
        if multiPart {
            s += "\n\nThe material is long and is sent in several parts. Organize only the part you received this time, continuing from what came before; no introduction or conclusion. Each part overlaps the neighboring parts by one page; organize overlapping content only once."
        }
        if hasImages {
            s += "\n\nThe material is given as images. Read the text, formulas and charts in them carefully."
        }
        s += "\n\nDo not write anything outside the tags.\n\n" + formatRule
        return s
    }

    static func noteAskSystem(doc: NoteDoc) -> String {
        guard AILanguage.isEnglish else { return noteAskSystemZH(doc: doc) }
        let body = doc.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
        return """
        You are a patient tutor. The student is using the notes below to preview or review, and will select part of them to ask you about. Keep your answer focused on the selected content, concise and clear, with a derivation where needed.

        [Notes: \(doc.title)]
        \(clip(body, 8000))

        \(formatRule)
        """
    }

    static func noteCircleInstruction(block: String, question: String, hasImage: Bool) -> String {
        guard AILanguage.isEnglish else { return noteCircleInstructionZH(block: block, question: question, hasImage: hasImage) }
        return """
        \(hasImage ? "[What I circled] See the image (a small part of the notes that I circled, possibly with my handwriting on it).\n\n" : "")[The note text it comes from]
        \(clip(block, 3000))

        [My question] \(question)

        Answer like a teacher's short note in the margin: stick to what is circled, a few sentences, with the key derivation if needed; formulas in $...$. No introduction.
        """
    }

    static func noteIntegrateSystem(doc: NoteDoc) -> String {
        guard AILanguage.isEnglish else { return noteIntegrateSystemZH(doc: doc) }
        let body = doc.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
        return """
        You are helping a student improve their own study notes. The student just asked about one spot in the notes and got an answer; now what they learned should be added to the notes, right at the spot where they asked. Below are the full notes; what you add must fit in with them.

        [Notes: \(doc.title)]
        \(clip(body, 8000))

        \(formatRule)
        """
    }

    static func noteIntegrateInstruction(section: String, quote: String?, question: String, answer: String) -> String {
        guard AILanguage.isEnglish else {
            return noteIntegrateInstructionZH(section: section, quote: quote, question: question, answer: answer)
        }
        var s = "[The section the question was about (note text; the number in brackets at the start of each line is a line number for reference only, not part of the notes)]\n\(numberedLines(section))\n\n"
        if let quote, !quote.isEmpty {
            s += "[What the student selected when asking] \(clip(quote, 600))\n\n"
        }
        s += """
        [The student's question] \(question)

        [The answer given at the time]
        \(clip(answer, 3000))

        Add what was learned in this Q&A to this section, right where the question was asked:
        - Don't change a single word of the original; only insert an explanation after one line. Choose the line where the student asked; if that line is immediately followed by a formula, list or table that belongs to it, choose their last line instead; don't choose a heading line.
        - Write it in context: continue from that line, using the notes' own symbols, examples and wording. You can connect with phrases like "that is," "this is because" or "for example," so it reads as if it was always part of the notes. Don't start over from scratch.
        - Write only what isn't in the notes yet; don't repeat what's already there, and leave out anything in the answer that is unrelated to this point.
        - Write it as notes, not as a Q&A: no "you asked", "the answer", "this question" or the like; no introduction and no closing summary.
        - Be concise: a few sentences or bullet points, with a formula or a very short example if needed; no heading.

        Output in the format below, with nothing outside the tags:
        <after>line number</after>
        <insert>the explanation to insert</insert>
        """
        return s
    }

    static func noteAskInstruction(selection: String, block: String, question: String, exerciseCount: Int = 0) -> String {
        guard AILanguage.isEnglish else {
            return noteAskInstructionZH(selection: selection, block: block, question: question, exerciseCount: exerciseCount)
        }
        var s = """
        [What I selected] (copied from the rendered page, so formulas may be incomplete)
        \(clip(selection, 1500))

        [The note text it comes from]
        \(clip(block, 3000))

        \(question)
        """
        if exerciseCount > 0 {
            s += """

            \(exerciseCount > 1 ? "Write \(exerciseCount) questions in total, from easier to harder, with no overlap, one set of tags each. " : "")Keep it moderately difficult and solvable in a few steps. Output in the format below, with nothing outside the tags:
            <exercise>
            <content>Full question stem (including choices, one per line)</content>
            <answer>Reference answer and a brief explanation</answer>
            </exercise>
            """
        }
        return s
    }

    // MARK: 做题时找相关笔记

    static func relatedNoteSystem() -> String {
        guard AILanguage.isEnglish else { return relatedNoteSystemZH() }
        return """
        A student just got a question wrong or got stuck on it. Below are the question and several sections of the student's own notes (each one numbered).
        Decide whether the notes contain a concept that is highly relevant to this question: reading that section would make the student see how to approach the question. Pick a section only if the relevance is really high; otherwise pick none.

        Output only one of the following, nothing else:
        <match section="number"><quote>The single most important sentence, copied word for word from that section (no more than 25 words, avoiding formulas if possible)</quote><summary>An ultra-short summary of the concept, no more than 6 words</summary></match>
        <none/>
        """
    }

    static func relatedNoteInstruction(question: Question, sections: [NoteSection], wrong: Bool) -> String {
        guard AILanguage.isEnglish else { return relatedNoteInstructionZH(question: question, sections: sections, wrong: wrong) }
        var s = "[Question]\n" + clip(question.content, 1500) + "\n\n[The student's situation] "
            + (wrong ? "Just got it wrong." : "Doesn't know how to do it and wants a hint.")
        s += "\n\n[The student's notes]"
        for (i, section) in sections.enumerated() {
            s += "\n\n#\(i + 1)\n" + clip(section.text, 600)
        }
        return s
    }

    static func detailNoteInstruction(topic: String, block: String) -> String {
        guard AILanguage.isEnglish else { return detailNoteInstructionZH(topic: topic, block: block) }
        return """
        [The related part of the notes]
        \(clip(block, 2000))

        Please write a detailed note on "\(topic)" to add after this part: start with a ### subheading, and cover the definition or result, why it holds, how to use it (with a short example) and common mistakes. Don't repeat what is already written above, and no introduction.
        """
    }
}
