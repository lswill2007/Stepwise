import SwiftUI
#if os(iOS)
import PencilKit
#endif

// MARK: - 纸的点阵、方格

/// 笔记手写块的纸：点阵或方格，纸色不变（白板的纸跟着滚动、缩放画，见 BoardPatternView）
struct PaperPattern: View {
    let style: PaperStyle

    var body: some View {
        Canvas { context, size in
            let s = PaperStyle.spacing
            switch style {
            case .blank:
                break
            case .dots:
                var path = Path()
                var y = s
                while y < size.height {
                    var x = s
                    while x < size.width {
                        path.addEllipse(in: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4))
                        x += s
                    }
                    y += s
                }
                context.fill(path, with: .color(Color.primary.opacity(0.2)))
            case .grid:
                var path = Path()
                var x = s
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += s
                }
                var y = s
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += s
                }
                context.stroke(path, with: .color(Color.primary.opacity(0.09)), lineWidth: 0.7)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 便签的结论图标：对了、再看看、提示、提问
struct BoardVerdictIcon: View {
    let note: BoardNote
    var streaming = false

    var body: some View {
        if streaming && note.verdict == nil && note.text.isEmpty {
            ProgressView().controlSize(.mini).frame(width: 18)
        } else {
            Image(systemName: Self.icon(note)).foregroundStyle(Self.color(note)).frame(width: 18)
        }
    }

    static func icon(_ note: BoardNote) -> String {
        guard note.isCheck else { return "bubble.left.fill" }
        switch note.verdict {
        case "correct": return "checkmark.circle.fill"
        case "wrong": return "exclamationmark.circle.fill"
        default: return "lightbulb.fill"
        }
    }

    static func color(_ note: BoardNote) -> Color {
        guard note.isCheck else { return Ink.blue }
        switch note.verdict {
        case "correct": return Ink.green
        case "wrong": return Ink.red
        default: return .orange
        }
    }

    static func title(_ note: BoardNote) -> String {
        if let q = note.question { return q }
        switch note.verdict {
        case "correct": return L("对了")
        case "wrong": return L("再看看")
        case "unsure": return L("提示")
        default: return L("检查")
        }
    }
}

#if os(iOS)

// MARK: - 白板

/// 白板现在显示的位置：画布坐标 p 在屏幕上是 p × zoom − offset。滚动时每一帧都变，单独放，只有便签那一层跟着刷新
final class BoardViewport: ObservableObject {
    @Published var offset: CGPoint = .zero
    @Published var zoom: CGFloat = 1

    func screen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom - offset.x, y: p.y * zoom - offset.y)
    }

    func screen(_ r: CGRect) -> CGRect {
        CGRect(origin: screen(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom))
    }
}

/// 框选出来的笔迹，等着发给 AI
struct BoardSelection: Equatable {
    let id = UUID()
    var strokes: [PKStroke]
    var bounds: CGRect

    static func == (a: BoardSelection, b: BoardSelection) -> Bool { a.id == b.id }
}

/// 一块白板的画布状态：框选、滚动位置、画布有多大
final class BoardState: ObservableObject {
    @Published var selection: BoardSelection?
    let viewport = BoardViewport()
    weak var canvas: PadCanvasView?
    weak var pattern: BoardPatternView?
    weak var model: HandwritingModel?
    /// 便签最低写到哪里（画布坐标）：画布至少要这么高，才滚得到
    var notesBottom: CGFloat = 0
    /// 量到的每张便签的高度（屏幕上的点）：放新便签时避开它们
    var stickyHeights: [UUID: CGFloat] = [:]
    /// 正在拖（或刚拖过）的便签放在最上面
    @Published var raisedNote: UUID?

    func syncViewport() {
        guard let canvas else { return }
        let offset = canvas.contentOffset, zoom = canvas.zoomScale
        if viewport.offset != offset { viewport.offset = offset }
        if viewport.zoom != zoom { viewport.zoom = zoom }
        if let pattern, pattern.offset != offset || pattern.zoom != zoom {
            pattern.offset = offset
            pattern.zoom = zoom
            pattern.setNeedsDisplay()
        }
    }

    /// 屏幕上看得见的白板有多大。画布本身固定是一个大方块（见 BoardContainerView），比看得见的大，多出来的被裁掉
    var visibleSize: CGSize = .zero

    /// 画布每次加长这么多（纸的坐标）：一次加一大截，不会每写一行就改一次大小
    private static let growStep: CGFloat = 1200

    /// 画布的大小跟着写的内容加长；PencilKit 的 contentSize 是缩放后的大小
    func updateContentSize() {
        guard let canvas, let model else { return }
        let zoom = max(canvas.zoomScale, 0.01)
        let drawing = model.drawing
        let bottom = drawing.strokes.isEmpty ? 0 : drawing.bounds.maxY
        let needed = max(2400, bottom + 1200, notesBottom + 800, visibleSize.height / zoom)
        let height = (needed / Self.growStep).rounded(.up) * Self.growStep
        let size = CGSize(width: Whiteboard.canvasWidth * zoom, height: height * zoom)
        if abs(canvas.contentSize.width - size.width) > 0.5 || abs(canvas.contentSize.height - size.height) > 0.5 {
            // 写字时改画布大小也可能打断这一笔：等抬笔
            canvas.whenIdle { [weak canvas] in canvas?.contentSize = size }
        }
    }

    /// 白板有了尺寸（或变了大小）：最小缩放到能看见整个宽度
    func layout() {
        guard let canvas, visibleSize.width > 1 else { return }
        let minZoom = max(0.25, min(1, visibleSize.width / Whiteboard.canvasWidth))
        if abs(canvas.minimumZoomScale - minZoom) > 0.001 { canvas.minimumZoomScale = minZoom }
        if canvas.maximumZoomScale != 3 { canvas.maximumZoomScale = 3 }
        updateContentSize()
        syncViewport()
    }

    /// 让画布上这一块露出来（便签按屏幕大小算，宽度不随缩放变）；已经看得见就不动
    func reveal(_ rect: CGRect) {
        guard let canvas, visibleSize.width > 1 else { return }
        let z = canvas.zoomScale
        let target = CGRect(x: rect.minX * z, y: rect.minY * z, width: rect.width, height: rect.height).insetBy(dx: -20, dy: -20)
        // 画布比看得见的大，scrollRectToVisible 会把裁掉的那块也当成看得见：按看得见的大小自己算
        var offset = canvas.contentOffset
        let visible = CGRect(origin: offset, size: visibleSize)
        if target.maxX > visible.maxX { offset.x = target.maxX - visibleSize.width }
        if target.minX < offset.x { offset.x = target.minX }
        if target.maxY > visible.maxY { offset.y = target.maxY - visibleSize.height }
        if target.minY < offset.y { offset.y = target.minY }
        offset.x = min(max(0, offset.x), max(0, canvas.contentSize.width - visibleSize.width))
        offset.y = min(max(0, offset.y), max(0, canvas.contentSize.height - visibleSize.height))
        if offset != canvas.contentOffset { canvas.setContentOffset(offset, animated: true) }
    }

    /// 笔迹变了（写了、擦了、拖动了选中的笔迹）：框选作废，画布可能要加长
    func drawingChanged() {
        if selection != nil { selection = nil }
        updateContentSize()
    }

    /// 按圈出的形状选出里面的笔迹：一笔有一半以上在圈里就算
    func select(polygon: [CGPoint]) {
        guard polygon.count >= 3, let model else { selection = nil; return }
        let path = CGMutablePath()
        path.addLines(between: polygon)
        path.closeSubpath()
        let box = path.boundingBox
        guard box.width > 16 || box.height > 16 else { selection = nil; return }
        let chosen = model.drawing.strokes.filter { stroke in
            guard stroke.renderBounds.intersects(box) else { return false }
            let points = stroke.path.interpolatedPoints(by: .distance(6)).map { $0.location.applying(stroke.transform) }
            guard !points.isEmpty else { return false }
            let inside = points.reduce(0) { $0 + (path.contains($1) ? 1 : 0) }
            return inside * 2 >= points.count
        }
        guard let first = chosen.first else { selection = nil; return }
        let bounds = chosen.dropFirst().reduce(first.renderBounds) { $0.union($1.renderBounds) }
        selection = BoardSelection(strokes: chosen, bounds: bounds)
    }

    /// 圈出来问画的那一笔：沿着它的形状选
    func select(circle stroke: PKStroke) {
        let points = stroke.path.interpolatedPoints(by: .distance(4)).map { $0.location.applying(stroke.transform) }
        select(polygon: points)
    }
}

/// 发给 AI 的图片：框住的笔迹放在白底上，左边按行印上行号，AI 才能说出是哪一行
enum BoardExport {
    struct Result {
        var image: Data
        /// 每一行在画布上的位置，行号从 1 开始
        var lines: [CGRect]
    }

    static func make(_ strokes: [PKStroke]) -> Result? {
        guard let first = strokes.first else { return nil }
        let bounds = strokes.dropFirst().reduce(first.renderBounds) { $0.union($1.renderBounds) }
        let lines = textLines(strokes)
        let area = bounds.insetBy(dx: -16, dy: -16)
        // 图片最长一边 1800 像素左右，字小的时候放大一点
        let scale = min(2, max(0.5, 1800 / max(area.width, area.height)))
        var ink: UIImage!
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = PKDrawing(strokes: strokes).image(from: area, scale: scale)
        }
        // 行号的字和左边留白：图片缩小时按比例放大，缩小后还看得清
        let grow = 1 / min(scale, 1)
        let gutter: CGFloat = lines.isEmpty ? 0 : 40 * grow
        let size = CGSize(width: area.width + gutter, height: area.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 15 * grow, weight: .semibold),
                .foregroundColor: UIColor.gray
            ]
            for (i, line) in lines.enumerated() {
                let label = "\(i + 1)" as NSString
                let labelSize = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: gutter - 8 * grow - labelSize.width, y: line.midY - area.minY - labelSize.height / 2),
                           withAttributes: attributes)
            }
            if gutter > 0 {
                UIColor.gray.withAlphaComponent(0.4).setFill()
                context.fill(CGRect(x: gutter - 2, y: 0, width: 1, height: size.height))
            }
            ink.draw(in: CGRect(x: gutter, y: 0, width: area.width, height: area.height))
        }
        guard let cg = image.cgImage, let jpeg = ImageUtil.jpeg(cg),
              let normalized = ImageUtil.normalizedJPEG(jpeg, maxPixel: 1800) else { return nil }
        return Result(image: normalized, lines: lines)
    }

    /// 把笔画按上下分成一行一行：上下有一大半重叠的算同一行。跨好几行的长笔画（分数线旁的大括号、积分号）不单独算一行
    static func textLines(_ strokes: [PKStroke]) -> [CGRect] {
        let rects = strokes.map(\.renderBounds).filter { !$0.isNull && !$0.isInfinite }
        guard !rects.isEmpty else { return [] }
        // 字有多高：不算横线、点这些扁的笔画
        let heights = rects.map(\.height).filter { $0 > 10 }.sorted()
        let typical = heights.isEmpty ? 24 : max(heights[heights.count / 2], 14)
        // 扁的笔画（“=”“+”的横、减号、点）按一个字的高度算，才会和同一行的字连上
        func band(_ r: CGRect) -> CGRect {
            let h = typical * 0.8
            return r.height >= h ? r : r.insetBy(dx: 0, dy: -(h - r.height) / 2)
        }
        let normal = rects.filter { $0.height <= typical * 2.6 }.map(band).sorted { $0.midY < $1.midY }
        var lines: [CGRect] = []
        for r in normal {
            if let i = lines.firstIndex(where: { line in
                min(line.maxY, r.maxY) - max(line.minY, r.minY) > min(r.height, typical) * 0.35
            }) {
                lines[i] = lines[i].union(r)
            } else {
                lines.append(r)
            }
        }
        // 只有长笔画（画了一个图）：每笔各算一行
        if lines.isEmpty { lines = rects }
        return Array(lines.sorted { $0.minY < $1.minY }.prefix(60))
    }
}

/// 白板的纸：点阵或方格，跟着画布滚动、缩放
final class BoardPatternView: UIView {
    var style: PaperStyle = .dots
    var offset: CGPoint = .zero
    var zoom: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: BoardPatternView, _) in view.setNeedsDisplay() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard style != .blank, let ctx = UIGraphicsGetCurrentContext() else { return }
        // 缩得很小时点太密：隔一个画一个
        var step = PaperStyle.spacing * zoom
        while step < 14 { step *= 2 }
        let startX = (offset.x / step).rounded(.up) * step - offset.x
        let startY = (offset.y / step).rounded(.up) * step - offset.y
        switch style {
        case .dots:
            ctx.setFillColor(UIColor.label.withAlphaComponent(0.2).cgColor)
            let r: CGFloat = min(1.6, max(0.9, 1.2 * zoom))
            var y = startY
            while y < bounds.height {
                var x = startX
                while x < bounds.width {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += step
                }
                y += step
            }
        case .grid:
            ctx.setStrokeColor(UIColor.label.withAlphaComponent(0.09).cgColor)
            ctx.setLineWidth(0.7)
            var x = startX
            while x < bounds.width {
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addLine(to: CGPoint(x: x, y: bounds.height))
                x += step
            }
            var y = startY
            while y < bounds.height {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: bounds.width, y: y))
                y += step
            }
            ctx.strokePath()
        case .blank:
            break
        }
    }
}

/// 只看不拦的手势：记下一根手指（或笔）划过的路径，自己从不生效，不影响画布上别的手势
final class TouchPathObserver: UIGestureRecognizer {
    var accepts: (UITouch) -> Bool = { _ in true }
    var onBegin: () -> Void = {}
    var onEnd: ([CGPoint]) -> Void = { _ in }
    private var points: [CGPoint] = []
    private weak var tracked: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    // 画布自己的套索手势开始时，别的手势一般会被它挤掉：这个只看不拦，不让它挤掉，也不挤掉别人
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // 第二根手指放上来（双指滚动、缩放）：不算框选
        guard tracked == nil, touches.count == 1, let touch = touches.first, accepts(touch) else {
            tracked = nil
            points = []
            state = .failed
            return
        }
        tracked = touch
        points = [touch.location(in: view)]
        onBegin()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        points.append(contentsOf: (event.coalescedTouches(for: tracked) ?? [tracked]).map { $0.location(in: view) })
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let tracked, touches.contains(tracked) {
            points.append(tracked.location(in: view))
            onEnd(points)
        }
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func reset() {
        tracked = nil
        points = []
    }
}

/// 手指从窗口最左边向右划：只认手指（笔从最左边落下照样写字）。
/// 不是从最左边落下的手指马上失败，不耽误滚动画布
final class LeftEdgeSwipe: UIGestureRecognizer {
    /// 落在离窗口左边多近的地方才算
    static let edgeWidth: CGFloat = 24
    private var start: CGPoint?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    // 书写手势认出来了也不挤掉它：笔不归它管，手指只有在“手指书写”关着时才会来（那时手指不写字）
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard start == nil, touches.count == 1, let touch = touches.first,
              touch.location(in: nil).x <= Self.edgeWidth else {
            state = .failed
            return
        }
        start = touch.location(in: nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let touch = touches.first else { return }
        let p = touch.location(in: nil)
        let dx = p.x - start.x, dy = abs(p.y - start.y)
        if dx < -8 || (dy > 40 && dy > dx) {
            state = .failed
        } else if dx > 50 && dx > dy * 1.5 {
            state = .ended
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .failed }
    }

    override func reset() {
        start = nil
    }
}

/// 画布外面包一层：纸在下面，画布在上面。
///
/// 画布的大小固定不变：一个边长等于屏幕长边的方块，贴在左上角，看不见的部分被这一层裁掉，
/// 白板变大变小（全屏、收起左栏、分屏、转屏、弹出键盘）只改画布的 contentInset。
/// PencilKit 的画布一改大小常常不重画已有的笔迹，以前只能清空再放回逼它重画，字就会闪一下；
/// 画布大小不变，就不用再重画
final class BoardContainerView: UIView {
    weak var state: BoardState?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let canvas = state?.canvas, let window, bounds.width > 1, bounds.height > 1 else { return }
        let screen = window.screen.bounds.size
        let side = max(screen.width, screen.height, bounds.width, bounds.height).rounded(.up)
        if canvas.frame.size.width < side || canvas.frame.origin != .zero {
            let first = canvas.frame.width < 1
            canvas.frame = CGRect(x: 0, y: 0, width: side, height: side)
            // 只会在接上更大的屏幕时发生：这时才需要逼它重画
            if !first { canvas.refreshRendering() }
        }
        // 多出来、被裁掉的部分算作内边距：滚得到内容的最右边、最下边，滚动条也在看得见的边上
        let insets = UIEdgeInsets(top: 0, left: 0,
                                  bottom: max(0, canvas.bounds.height - bounds.height),
                                  right: max(0, canvas.bounds.width - bounds.width))
        if canvas.contentInset != insets {
            canvas.contentInset = insets
            canvas.verticalScrollIndicatorInsets = insets
            canvas.horizontalScrollIndicatorInsets = insets
        }
        state?.visibleSize = bounds.size
        state?.layout()
    }
}

/// 白板的画布：可以滚动、双指缩放；框选、圈出来问选中的笔迹交给 BoardState
struct BoardCanvas: UIViewRepresentable {
    @ObservedObject var model: HandwritingModel
    @ObservedObject var tools: InkTools
    let state: BoardState
    let paper: PaperStyle
    /// 全屏时从屏幕最左边用手指向右拽：拉回左栏。为 nil 时不响应
    var onEdgePull: (() -> Void)?

    func makeUIView(context: Context) -> BoardContainerView {
        let container = BoardContainerView()
        container.backgroundColor = .clear
        container.clipsToBounds = true
        container.state = state

        // 只认手指的屏幕边缘手势：笔从最左边落下照样写字
        let edge = LeftEdgeSwipe(target: context.coordinator, action: #selector(Coordinator.edgePan(_:)))
        edge.delegate = context.coordinator
        container.addGestureRecognizer(edge)
        context.coordinator.edgeGesture = edge

        let pattern = BoardPatternView(frame: container.bounds)
        pattern.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pattern.style = paper

        // 大小固定，由 BoardContainerView 定，不跟着白板变
        let canvas = PadCanvasView(frame: .zero)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.isScrollEnabled = true
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 3
        canvas.bouncesZoom = true
        canvas.delegate = context.coordinator
        // 手指从最左边向右拽是拉回左栏，不是滚动画布（不在边上落下的手指，边缘手势马上就失败，不耽误滚动）
        canvas.panGestureRecognizer.require(toFail: edge)
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        canvas.addInteraction(pencil)
        canvas.drawingGestureRecognizer.addTarget(context.coordinator, action: #selector(NotebookCanvas.Coordinator.drawingGesture(_:)))
        // 框选（PencilKit 的套索）不走书写手势：另挂一个只看不拦的手势，记下圈的路径
        let observer = TouchPathObserver(target: nil, action: nil)
        observer.accepts = { [weak canvas, weak model] touch in
            guard let canvas, let model, model.tools.tool == .lasso else { return false }
            return canvas.drawingPolicy == .anyInput || touch.type == .pencil
        }
        observer.onBegin = { [weak coordinator = context.coordinator] in coordinator?.lassoBegan() }
        observer.onEnd = { [weak coordinator = context.coordinator, weak canvas] points in
            guard let canvas else { return }
            let z = max(canvas.zoomScale, 0.01)
            coordinator?.lassoEnded(points.map { CGPoint(x: $0.x / z, y: $0.y / z) })
        }
        observer.delegate = context.coordinator
        canvas.addGestureRecognizer(observer)

        container.addSubview(pattern)
        container.addSubview(canvas)
        state.canvas = canvas
        state.pattern = pattern
        state.model = model
        model.attach(canvas)
        return container
    }

    func updateUIView(_ uiView: BoardContainerView, context: Context) {
        context.coordinator.onEdgePull = onEdgePull
        context.coordinator.edgeGesture?.isEnabled = onEdgePull != nil
        if let canvas = state.canvas {
            if model.canvas !== canvas { model.attach(canvas) } else { model.applyTools() }
        }
        if let pattern = state.pattern, pattern.style != paper {
            pattern.style = paper
            pattern.setNeedsDisplay()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, state: state) }

    /// 在笔记画布的基础上：滚动、缩放时挪纸和便签；框选时记下圈的路径，选出里面的笔迹
    final class Coordinator: NotebookCanvas.Coordinator, UIGestureRecognizerDelegate {
        let state: BoardState
        private var previous: BoardSelection?
        var onEdgePull: (() -> Void)?
        weak var edgeGesture: LeftEdgeSwipe?

        init(model: HandwritingModel, state: BoardState) {
            self.state = state
            super.init(model: model)
        }

        /// 从最左边向右拽了一段：拉回左栏
        @objc func edgePan(_ gesture: LeftEdgeSwipe) {
            if gesture.state == .ended { onEdgePull?() }
        }

        /// 笔正在写的时候手掌碰到最左边、打开了手指书写（手指是来写字的）时，都不算拉左栏。
        /// 手指书写时不去取消已经开始的一笔：关掉再打开书写手势会让 PencilKit 有一块纸不再重画
        @objc func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === edgeGesture else { return true }
            guard let canvas = state.canvas else { return false }
            return !canvas.isPencilDown && canvas.drawingPolicy != .anyInput
        }

        @objc func scrollViewDidScroll(_ scrollView: UIScrollView) { state.syncViewport() }
        @objc func scrollViewDidZoom(_ scrollView: UIScrollView) { state.syncViewport() }
        @objc func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            state.updateContentSize()
            state.syncViewport()
        }

        /// 记路径的手势和画布上所有手势同时进行
        @objc func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                     shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer is TouchPathObserver || other is TouchPathObserver
        }

        /// 开始框选：先收起原来的操作条（点在选中的笔迹上时再放回来）
        func lassoBegan() {
            previous = state.selection
            if state.selection != nil { state.selection = nil }
        }

        /// 框选画完（画布坐标）：选出圈里的笔迹
        func lassoEnded(_ points: [CGPoint]) {
            guard let last = points.last else { return }
            let xs = points.map(\.x), ys = points.map(\.y)
            let span = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
            // 只是点了一下（点选中的笔迹弹出菜单）：还是原来选的那些
            if span < 12 {
                if let previous, previous.bounds.insetBy(dx: -20, dy: -20).contains(last) { state.selection = previous }
                return
            }
            // 拖动选中的笔迹：笔迹变了，操作条在 drawingChanged 里收起
            if let previous, previous.bounds.insetBy(dx: -10, dy: -10).contains(points[0]) {
                state.selection = previous
                return
            }
            state.select(polygon: points)
        }
    }
}

/// 白板页：大张的纸，写题目和解答；框选一段发给 AI，回复以便签浮在画布上
struct WhiteboardView: View {
    @EnvironmentObject var store: AppStore
    let boardID: UUID

    @StateObject private var ink = NotebookInk()
    @StateObject private var state = BoardState()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let board = store.board(boardID) {
            let model = ink.model(for: boardID)
            ZStack(alignment: .topLeading) {
                BoardCanvas(model: model, tools: ink.tools, state: state, paper: board.paper,
                            onEdgePull: store.isFullScreen ? { store.setFullScreen(false) } : nil)
                BoardOverlay(boardID: boardID, board: board, state: state, viewport: state.viewport)
            }
            .background(Ink.paper)
            .overlay(alignment: .top) { BoardEmptyHint(model: model, hasNotes: !board.notes.isEmpty) }
            .overlay { InkOptionsDismissLayer(tools: ink.tools) }
            .overlay(alignment: .bottom) { InkPalette(tools: ink.tools) }
            .navigationTitle(board.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if !board.notes.isEmpty {
                        Button {
                            store.mutateBoard(boardID) { $0.notesHidden.toggle() }
                        } label: {
                            Label(board.notesHidden ? L("显示便签") : L("隐藏便签"),
                                  systemImage: board.notesHidden ? "note.text" : "eye.slash")
                        }
                    }
                    Menu {
                        Picker("纸", selection: Binding(get: { board.paper }, set: { store.setBoardPaper(boardID, $0) })) {
                            ForEach(PaperStyle.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                        }
                    } label: {
                        Label("纸", systemImage: board.paper.icon)
                    }
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
            .onAppear {
                model.onCircleStroke = { [weak state] stroke in state?.select(circle: stroke) }
                model.onDrawingChanged = { [weak state] in state?.drawingChanged() }
                state.notesBottom = Self.notesBottom(board)
            }
            .onChange(of: board.notes) { old, new in
                state.notesBottom = Self.notesBottom(board)
                state.updateContentSize()
                // 新的便签：翻到看得见它的地方
                if new.count > old.count, let note = new.last {
                    state.reveal(CGRect(x: note.x, y: note.y, width: Whiteboard.stickyWidth, height: 160))
                }
            }
            .onChange(of: scenePhase) {
                if scenePhase != .active { ink.saveAll() }
            }
            .onDisappear { ink.saveAll() }
        } else {
            ContentUnavailableView("白板不存在", systemImage: "rectangle.and.pencil.and.ellipsis")
        }
    }

    /// 便签大概写到哪里（画布坐标）
    private static func notesBottom(_ board: Whiteboard) -> CGFloat {
        board.notes.map { CGFloat($0.y) + 400 }.max() ?? 0
    }
}

/// 空白板上的一句说明，写了就不显示
private struct BoardEmptyHint: View {
    @ObservedObject var model: HandwritingModel
    let hasNotes: Bool

    var body: some View {
        if model.isEmpty && !hasNotes {
            Label("写下题目和解答，用“框选”圈住一段，点“检查”", systemImage: "lasso.badge.sparkles")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
                .allowsHitTesting(false)
        }
    }
}

/// 画布上面的一层：框住的地方、指出的行、便签、框选后的操作条。跟着滚动和缩放挪
private struct BoardOverlay: View {
    @EnvironmentObject var store: AppStore
    let boardID: UUID
    let board: Whiteboard
    @ObservedObject var state: BoardState
    @ObservedObject var viewport: BoardViewport

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !board.notesHidden {
                marks
                ForEach(Array(board.notes.enumerated()), id: \.element.id) { i, note in
                    let spot = viewport.screen(CGPoint(x: note.x, y: note.y))
                    BoardStickyView(boardID: boardID, note: note, number: i + 1, zoom: viewport.zoom) {
                        if state.raisedNote != note.id { state.raisedNote = note.id }
                    }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.stickyHeights[note.id] = $0 }
                        .zIndex(state.raisedNote == note.id ? 1 : 0)
                        .offset(x: spot.x, y: spot.y)
                }
            }
            if let selection = state.selection {
                let rect = viewport.screen(selection.bounds).insetBy(dx: -8, dy: -8)
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Ink.blue.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
                BoardActionBar(busy: store.boardJobs[boardID] != nil) { question in
                    send(selection, question: question)
                } cancel: {
                    state.selection = nil
                }
                .fixedSize()
                // 放在框住的地方上面；太靠上就放下面
                .offset(x: max(8, rect.minX), y: rect.minY > 70 ? rect.minY - 56 : rect.maxY + 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    /// 框住的地方淡淡的虚线框和序号；指出的那一行下面一道红色波浪线，前面标号，和便签里的对上
    private var marks: some View {
        Canvas { context, _ in
            for (i, note) in board.notes.enumerated() where !note.minimized {
                let r = viewport.screen(note.region.rect).insetBy(dx: -6, dy: -6)
                context.stroke(Path(roundedRect: r, cornerRadius: 8),
                               with: .color(Color.orange.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                let label = context.resolve(Text("\(i + 1)").font(.system(size: 12, weight: .bold)).foregroundColor(.orange))
                context.draw(label, at: CGPoint(x: r.minX + 4, y: r.minY - 3), anchor: .bottomLeading)
                for (k, comment) in note.comments.enumerated() {
                    guard let rect = comment.rect?.rect else { continue }
                    let line = viewport.screen(rect)
                    var wave = Path()
                    let y = line.maxY + 3
                    wave.move(to: CGPoint(x: line.minX, y: y))
                    var x = line.minX
                    var up = true
                    while x < line.maxX {
                        let next = min(x + 6, line.maxX)
                        wave.addQuadCurve(to: CGPoint(x: next, y: y), control: CGPoint(x: (x + next) / 2, y: y + (up ? -3 : 3)))
                        up.toggle()
                        x = next
                    }
                    context.stroke(wave, with: .color(Ink.red.opacity(0.7)), lineWidth: 1.4)
                    let center = CGPoint(x: line.minX - 12, y: line.midY)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)),
                                 with: .color(Ink.red.opacity(0.85)))
                    let n = context.resolve(Text("\(k + 1)").font(.system(size: 10, weight: .bold)).foregroundColor(.white))
                    context.draw(n, at: center, anchor: .center)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func send(_ selection: BoardSelection, question: String?) {
        guard let export = BoardExport.make(selection.strokes) else { return }
        store.askBoard(boardID, region: selection.bounds, lines: export.lines, image: export.image, question: question,
                       zoom: viewport.zoom, stickyHeights: state.stickyHeights)
        state.selection = nil
    }
}

/// 框选之后浮在旁边的操作条：检查，或者问一句
private struct BoardActionBar: View {
    let busy: Bool
    let send: (String?) -> Void
    let cancel: () -> Void
    @State private var asking = false
    @State private var text = ""

    var body: some View {
        HStack(spacing: 14) {
            Button {
                send(nil)
            } label: {
                Label("检查", systemImage: "checkmark.seal")
                    .font(.callout.weight(.semibold))
            }
            Button {
                asking = true
            } label: {
                Label("提问…", systemImage: "bubble.left")
                    .font(.callout)
            }
            .popover(isPresented: $asking) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("问框住的这段").font(.headline)
                    TextField("想问什么…", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                        .padding(10)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    FlowLayout(spacing: 10) {
                        ForEach(Self.quick, id: \.self) { q in
                            Button(q) { submit(q) }.font(.caption)
                        }
                    }
                    .buttonStyle(InkTextButtonStyle())
                    Button {
                        submit(text)
                    } label: {
                        Text("发送").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(18)
                .frame(width: 340)
            }
            Button(action: cancel) {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .accessibilityLabel("取消")
        }
        .buttonStyle(InkTextButtonStyle())
        .disabled(busy)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .overlay(alignment: .bottom) {
            if busy {
                Text("正在回复上一处，稍等一下")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(y: 18)
            }
        }
    }

    static let quick = [L("下一步怎么写？"), L("这一步为什么？"), L("有更简单的方法吗？"), L("讲一下这道题的思路")]

    private func submit(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        asking = false
        text = ""
        send(q)
    }
}

/// 一张便签：结论、回复，下面按序号列出指出的几行。可以拖动、收起、删除；双击放大
private struct BoardStickyView: View {
    @EnvironmentObject var store: AppStore
    let boardID: UUID
    let note: BoardNote
    let number: Int
    let zoom: CGFloat
    /// 开始拖：放到最上面
    var onRaise: () -> Void = {}
    @State private var drag: CGSize = .zero
    @State private var enlarged = false

    private var streaming: Bool { store.boardJobs[boardID] == note.id }

    var body: some View {
        Group {
            if note.minimized { badge } else { card }
        }
        .offset(drag)
        .sheet(isPresented: $enlarged) { enlargedView }
    }

    /// 收起：一个小标签，点一下展开
    private var badge: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { store.mutateBoardNote(boardID, note.id) { $0.minimized = false } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: BoardVerdictIcon.icon(note)).foregroundStyle(BoardVerdictIcon.color(note))
                Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.primary)
            }
            .font(.callout)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Ink.note, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .gesture(moveGesture)
        .accessibilityLabel("展开便签 \(number)")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !note.text.isEmpty {
                RichText(note.text, scale: 0.86)
                    .fixedSize(horizontal: false, vertical: true)
                    // 文字在网页视图里，点击会被它吃掉：盖一层透明的来接双击
                    .overlay {
                        Color.clear.contentShape(Rectangle()).onTapGesture(count: 2) { enlarged = true }
                    }
            }
            ForEach(Array(note.comments.enumerated()), id: \.offset) { k, comment in
                commentRow(k + 1, comment)
            }
            // 一直到写完都显示在最下面：还没出字时是“正在检查…”，出字以后是“还在写…”，都可以停止
            if streaming {
                GeneratingBadge(label: note.text.isEmpty ? (note.isCheck ? L("正在检查…") : L("正在写…")) : L("还在写…"),
                                startedAt: note.createdAt, compact: true) { store.stopBoardJob(boardID) }
            }
        }
        .padding(12)
        .frame(width: Whiteboard.stickyWidth, alignment: .leading)
        .background(Ink.note, in: RoundedRectangle(cornerRadius: 6))
        // 一条胶带
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.45))
                .frame(width: 70, height: 16)
                .rotationEffect(.degrees(-3))
                .offset(y: -8)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.16), radius: 6, x: 1, y: 3)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            BoardVerdictIcon(note: note, streaming: streaming)
            Text(BoardVerdictIcon.title(note))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(note.isCheck ? BoardVerdictIcon.color(note) : Color.primary)
                .lineLimit(2)
            Spacer(minLength: 4)
            // 正在写时，停止按钮在下面的状态胶囊里
            if !streaming {
                Menu {
                    Button("放大查看", systemImage: "arrow.up.left.and.arrow.down.right") { enlarged = true }
                    Button("删除便签", systemImage: "trash", role: .destructive) { store.deleteBoardNote(boardID, note.id) }
                } label: {
                    Image(systemName: "ellipsis").font(.caption).foregroundStyle(.secondary).frame(width: 24, height: 20)
                }
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { store.mutateBoardNote(boardID, note.id) { $0.minimized = true } }
            } label: {
                Image(systemName: "minus").font(.caption.weight(.semibold))
            }
            .buttonStyle(InkTextButtonStyle(color: .secondary))
            .accessibilityLabel("收起便签")
        }
        // 按住标题拖动便签
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    private func commentRow(_ n: Int, _ comment: BoardComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Ink.red.opacity(0.85), in: Circle())
                .padding(.top, 2)
            RichText(comment.note, scale: 0.78)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 拖动便签：按屏幕坐标量拖了多远。按便签自己的坐标量的话，便签一动，量的起点也跟着动，会来回抖
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if drag == .zero { onRaise() }
                drag = value.translation
            }
            .onEnded { value in
                let z = max(zoom, 0.01)
                // 放下时位置和偏移同时换，不加动画，免得闪一下
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    store.mutateBoardNote(boardID, note.id) { n in
                        n.x = max(0, n.x + value.translation.width / z)
                        n.y = max(0, n.y + value.translation.height / z)
                    }
                    drag = .zero
                }
            }
    }

    private var enlargedView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(BoardVerdictIcon.title(note), systemImage: BoardVerdictIcon.icon(note))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(BoardVerdictIcon.color(note))
                    RichText(note.text, scale: 1.15)
                    ForEach(Array(note.comments.enumerated()), id: \.offset) { k, comment in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(k + 1)")
                                .font(.caption.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Ink.red.opacity(0.85), in: Circle())
                            RichText(comment.note, scale: 1.05)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("便签 \(number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { enlarged = false } }
            }
        }
    }
}

#else

/// Mac 上只用于编译检查，没有手写
struct WhiteboardView: View {
    let boardID: UUID
    var body: some View {
        ContentUnavailableView("白板需要在 iPad 上使用", systemImage: "rectangle.and.pencil.and.ellipsis")
    }
}

#endif
