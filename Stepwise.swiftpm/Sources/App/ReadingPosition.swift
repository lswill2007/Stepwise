import SwiftUI

/// 每个文件（题集、错题本、笔记、白板）上次看到哪里：关掉再打开时回到原来的位置。
///
/// 题集和笔记的内容会变高变矮（公式排好版、手写区加长），记绝对的滚动位置不准：
/// 记的是页面顶上那条线落在哪一道题（哪一块）里、离它顶端多远。白板记滚动位置和缩放。
/// 存在 UserDefaults，不进备份
struct ReadingPosition: Codable, Equatable {
    /// 顶上那条线落在哪一道题 / 哪一块；白板为 nil
    var item: UUID?
    /// 题集：那条线离这道题顶端多远（屏幕上的点）；白板：滚动位置
    var x: Double = 0
    var y: Double = 0
    /// 笔记：那条线落在这一块的几分之几处。笔记整页按宽度缩放，按比例记，页面宽窄变了也对得上
    var part: Double?
    /// 白板的缩放
    var zoom: Double = 1

    private static let key = "readingPositions"

    static func load(_ file: UUID) -> ReadingPosition? {
        guard let all = UserDefaults.standard.dictionary(forKey: key),
              let data = all[file.uuidString] as? Data else { return nil }
        return try? JSONDecoder().decode(ReadingPosition.self, from: data)
    }

    static func save(_ position: ReadingPosition?, for file: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[file.uuidString] = position.flatMap { try? JSONEncoder().encode($0) }
        UserDefaults.standard.set(all, forKey: key)
    }

    /// 文件删掉了，位置也不用留
    static func forget(_ files: [UUID]) {
        guard var all = UserDefaults.standard.dictionary(forKey: key) else { return }
        files.forEach { all[$0.uuidString] = nil }
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// 题集、笔记页回到上次的位置：先用 ScrollViewReader 翻到那一项的顶端，再按记下的距离往下挪。
/// 公式、图片陆续排好版时那一项上面的内容会变高变矮，所以过一会儿再对一次，直到对准或者用户自己开始滚动
final class ScrollRestorer {
    /// 页面的滚动视图（SwiftUI 的 ScrollView 下面是 UIScrollView）
    #if os(iOS)
    weak var scrollView: UIScrollView?
    #endif
    /// 正在回到上次的位置：这期间不记新的位置
    private(set) var restoring = false
    private var generation = 0

    /// 每次对位置前后各等多久（秒）
    private static let passes: [Double] = [0.05, 0.12, 0.25, 0.45, 0.7, 1.0, 1.5]

    /// - Parameters:
    ///   - gap: 还要往下滚多少才对准；量不到（还没排出来）返回 nil
    func restore(gap: @escaping () -> CGFloat?, done: @escaping () -> Void) {
        generation += 1
        let token = generation
        restoring = true
        #if os(iOS)
        var index = 0
        func pass() {
            guard token == generation else { return }
            // 用户自己滚了：不再跟他抢
            if let scroll = scrollView, scroll.isTracking || scroll.isDragging || scroll.isDecelerating {
                finish(); return
            }
            if let scroll = scrollView, let diff = gap() {
                if abs(diff) > 0.5 {
                    let inset = scroll.adjustedContentInset
                    let minY = -inset.top
                    let maxY = max(minY, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
                    let y = min(max(scroll.contentOffset.y + diff, minY), maxY)
                    if abs(y - scroll.contentOffset.y) > 0.5 { scroll.contentOffset.y = y }
                }
            }
            guard index < Self.passes.count else { finish(); return }
            let delay = Self.passes[index]
            index += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { pass() }
        }
        func finish() {
            guard token == generation else { return }
            restoring = false
            done()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.passes[0]) { pass() }
        #else
        restoring = false
        done()
        #endif
    }

    /// 打开别的地方（点了目录、跳到某道题）：不再往回挪
    func cancel() {
        generation += 1
        restoring = false
    }
}

#if os(iOS)
/// 放在滚动内容里，找到外面的 UIScrollView 交给 ScrollRestorer
struct ScrollViewFinder: UIViewRepresentable {
    let restorer: ScrollRestorer

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.restorer = restorer
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {}

    final class FinderView: UIView {
        weak var restorer: ScrollRestorer?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let v = view, !(v is UIScrollView) { view = v.superview }
            if let scroll = view as? UIScrollView { restorer?.scrollView = scroll }
        }
    }
}
#endif

extension View {
    /// 让 ScrollRestorer 拿到这个滚动内容外面的滚动视图
    @ViewBuilder
    func findsScrollView(_ restorer: ScrollRestorer) -> some View {
        #if os(iOS)
        background { ScrollViewFinder(restorer: restorer).allowsHitTesting(false) }
        #else
        self
        #endif
    }
}
