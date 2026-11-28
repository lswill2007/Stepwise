import SwiftUI
import QuartzCore

/// 每个文件（题集、收藏、笔记、白板）上次看到哪里：关掉再打开时回到原来的位置。
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
    /// 笔记：那条线落在这一块的几分之几处。笔记整页按宽度缩放，按比例记，页面宽窄变了也对得上。
    /// 题集：那条线落在 section 这一段的几分之几处
    var part: Double?
    /// 题集：那条线落在这道题的哪一段（见 QuestionSection）。页面变宽变窄时一道题里各段的高度变得不一样
    /// （题目换行；批改结果窄的时候排在作答下面，宽的时候挪到右边页边），只记离题目顶端多远就对不上了。
    /// 以前存的位置没有这一项，还按 y 算
    var section: Int?
    /// 题集：那条线已经过了这一段的底、落在它下面的空隙里，离段底多远
    var past: Double?
    /// 白板的缩放
    var zoom: Double = 1

    private static let key = "readingPositions"

    /// 读过的记在内存里：资料库每一格每次刷新都要读，不用每次把整个字典从 UserDefaults 拿出来再解一遍
    @MainActor private static var cache: [UUID: ReadingPosition?] = [:]

    @MainActor static func load(_ file: UUID) -> ReadingPosition? {
        if let cached = cache[file] { return cached }
        var position: ReadingPosition?
        if let all = UserDefaults.standard.dictionary(forKey: key), let data = all[file.uuidString] as? Data {
            position = try? JSONDecoder().decode(ReadingPosition.self, from: data)
        }
        cache[file] = .some(position)
        return position
    }

    @MainActor static func save(_ position: ReadingPosition?, for file: UUID) {
        cache[file] = .some(position)
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[file.uuidString] = position.flatMap { try? JSONEncoder().encode($0) }
        UserDefaults.standard.set(all, forKey: key)
    }

    /// 文件删掉了，位置也不用留
    @MainActor static func forget(_ files: [UUID]) {
        files.forEach { cache[$0] = .some(nil) }
        guard var all = UserDefaults.standard.dictionary(forKey: key) else { return }
        files.forEach { all[$0.uuidString] = nil }
        UserDefaults.standard.set(all, forKey: key)
    }

    /// 储存位置换了、导入了设置：整个重新读
    @MainActor static func reloadAll() { cache.removeAll() }
}

/// 滚动、缩放停下来一会儿就存一次位置。只在离开页面、进后台时存的话，App 被直接结束
/// （从 Xcode 重新运行、装新版本、被系统清掉、闪退）时最后看的地方就丢了，下次打开回到更早的位置
final class PositionAutosave {
    private var lastChange: CFTimeInterval = 0
    private var scheduled = false
    /// 停下来多久才存（秒）
    private static let quiet: CFTimeInterval = 0.6

    /// 位置变了；停下来以后读一次 position() 存下来。滚动时每一帧都会调，这里只记时间
    func changed(_ file: UUID, _ position: @escaping () -> ReadingPosition?) {
        lastChange = CACurrentMediaTime()
        guard !scheduled else { return }
        scheduled = true
        wait(file, position)
    }

    private func wait(_ file: UUID, _ position: @escaping () -> ReadingPosition?) {
        let remaining = max(0.05, lastChange + Self.quiet - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self else { return }
            if CACurrentMediaTime() - self.lastChange < Self.quiet - 0.01 {
                self.wait(file, position)
                return
            }
            self.scheduled = false
            if let current = position() { ReadingPosition.save(current, for: file) }
        }
    }
}

/// 题集、笔记页回到上次的位置：先用 ScrollViewReader 翻到那一项的顶端，再按记下的距离往下挪。
/// 公式、图片陆续排好版时那一项上面的内容会变高变矮，所以过一会儿再对一次，直到对准或者用户自己开始滚动
final class ScrollRestorer: NSObject {
    /// 页面的滚动视图（SwiftUI 的 ScrollView 下面是 UIScrollView）
    #if os(iOS)
    weak var scrollView: UIScrollView? {
        didSet {
            guard scrollView !== oldValue else { return }
            oldValue?.panGestureRecognizer.removeTarget(self, action: #selector(userPanned(_:)))
            scrollView?.panGestureRecognizer.addTarget(self, action: #selector(userPanned(_:)))
        }
    }
    #endif
    /// 页面现在滚到哪里
    var offset: CGFloat? {
        #if os(iOS)
        scrollView?.contentOffset.y
        #else
        nil
        #endif
    }

    /// 正在回到上次的位置：这期间不记新的位置
    private(set) var restoring = false
    private var generation = 0
    private var onDone: (() -> Void)?

    /// 每次对位置前后各等多久（秒）
    private static let passes: [Double] = [0.05, 0.12, 0.25, 0.45, 0.7, 1.0, 1.5]

    /// - Parameters:
    ///   - eager: 页面已经排出来、只是重新排了一遍（变宽变窄）：不等，这一轮排完马上先对一次，免得先闪一下别处再跳回来
    ///   - gap: 还要往下滚多少才对准；量不到（还没排出来）返回 nil
    func restore(eager: Bool = false, gap: @escaping () -> CGFloat?, done: @escaping () -> Void) {
        generation += 1
        let token = generation
        restoring = true
        onDone = done
        #if os(iOS)
        var index = 0
        func pass() {
            guard token == generation else { return }
            // 用户自己滚了：不再跟他抢
            if let scroll = scrollView, scroll.isTracking || scroll.isDragging || scroll.isDecelerating {
                end(token); return
            }
            align(gap)
            guard index < Self.passes.count else { end(token); return }
            let delay = Self.passes[index]
            index += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { pass() }
        }
        if eager {
            // 先对一次，之后的几次从这一次算起
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.generation else { return }
                self.align(gap)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.passes[0]) { pass() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.passes[0]) { pass() }
        }
        #else
        end(token)
        #endif
    }

    #if os(iOS)
    /// 上一次挪的时候还差多少、挪到了哪里、什么时候挪的
    private var lastMove: (diff: CGFloat, offset: CGFloat, time: CFTimeInterval)?

    private func align(_ gap: () -> CGFloat?) {
        guard let scroll = scrollView, !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating,
              let diff = gap(), abs(diff) > 0.5 else { return }
        // 刚挪过，页面还没把新的位置报上来（量到的还是挪之前的）：不能照同一个差距再挪一遍。
        // 主线程忙的时候两次会挨在一起，挪过头的话要对的那一项滚出屏幕被收走，就再也对不上了
        let now = CACurrentMediaTime()
        if let last = lastMove, now - last.time < 0.03, last.diff == diff,
           abs(scroll.contentOffset.y - last.offset) < 0.01 { return }
        let inset = scroll.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
        let y = min(max(scroll.contentOffset.y + diff, minY), maxY)
        if abs(y - scroll.contentOffset.y) > 0.5 { scroll.contentOffset.y = y }
        lastMove = (diff, scroll.contentOffset.y, now)
    }

    deinit { scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(userPanned(_:))) }

    /// 手指一落到页面上开始拖就停：只在每次对位置的那一刻看“是不是正在滚”的话，
    /// 两次之间拖一小下又松开是看不到的，下一次就把页面拽回原来的地方
    @objc private func userPanned(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { end(generation) }
    }
    #endif

    private func end(_ token: Int) {
        guard token == generation, restoring else { return }
        generation += 1
        restoring = false
        let done = onDone
        onDone = nil
        done?()
    }

    /// 打开别的地方（点了目录、跳到某道题）：不再往回挪
    func cancel() {
        generation += 1
        restoring = false
        onDone = nil
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
