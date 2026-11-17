import SwiftUI

/// 导入题目、生成笔记的进度。AI 不会告诉我们还要写多久，按“写完的部分 + 正在写的部分已经写了多少”估算：
/// 每部分预计写多少字按资料的字数（图片按每页大约多少字）估，没写完的部分最多算到 95%
struct GenerationProgress: Equatable {
    var fraction: Double = 0
    var parts = 1
    var doneParts = 0
    /// 已经识别出的题 / 已经写好的笔记块
    var found = 0
    var startedAt = Date()
}

/// 每部分的预计输出字数和已经写了多少
struct ChunkEstimator {
    private let expected: [Double]
    private(set) var written: [Int]
    private(set) var done: [Bool]

    /// ratio：输出大约是输入字数的多少倍；perImage：一页图片大约对应多少字的输出
    init(_ chunks: [SplitChunk], ratio: Double, perImage: Double, minimum: Double) {
        expected = chunks.map { max(minimum, Double($0.text.count) * ratio + Double($0.images.count) * perImage) }
        written = Array(repeating: 0, count: chunks.count)
        done = Array(repeating: false, count: chunks.count)
    }

    mutating func update(_ i: Int, written chars: Int) { written[i] = chars }
    mutating func finish(_ i: Int) { done[i] = true }

    var doneCount: Int { done.filter { $0 }.count }

    var fraction: Double {
        guard !expected.isEmpty else { return 0 }
        let sum = expected.indices.reduce(0.0) { total, i in
            total + (done[i] ? 1 : min(Double(written[i]) / expected[i], 0.95))
        }
        return sum / Double(expected.count)
    }
}

/// 进度条：百分比、第几部分、找到几道题（或写了几块）、用了多久
struct GenerationProgressView: View {
    let progress: GenerationProgress
    /// “已识别 %lld 道题” / “已写好 %lld 块”
    let foundText: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: min(max(progress.fraction, 0), 1))
                .animation(.easeOut(duration: 0.3), value: progress.fraction)
            HStack(spacing: 10) {
                Text("\(Int((progress.fraction * 100).rounded()))%").monospacedDigit()
                if progress.parts > 1 {
                    Text("第 \(min(progress.doneParts + 1, progress.parts))/\(progress.parts) 部分")
                }
                if progress.found > 0 { Text(foundText(progress.found)) }
                Spacer()
                TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(progress.startedAt))).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
