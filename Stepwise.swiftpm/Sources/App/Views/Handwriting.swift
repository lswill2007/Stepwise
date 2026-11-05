import SwiftUI

#if os(iOS)
import PencilKit
import Combine

/// 框选后画布会成为第一响应者（用于剪切 / 拷贝 / 撤销），这里阻止它顺带弹出键盘
final class PadCanvasView: PKCanvasView {
    private let noKeyboard = UIView(frame: .zero)
    /// 恢复的笔迹要等画布显示到屏幕上再放进去，否则 PencilKit 不会绘制
    var pendingDrawing: PKDrawing?
    /// 正在重新放入笔迹（不是用户在写），这时的变化不算
    private(set) var isRefreshing = false

    /// 画布在屏幕上且有了实际尺寸后再放入恢复的笔迹
    override func layoutSubviews() {
        super.layoutSubviews()
        guard pendingDrawing != nil, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let drawing = self.pendingDrawing else { return }
            self.pendingDrawing = nil
            self.isRefreshing = true
            self.drawing = drawing
            self.isRefreshing = false
            // 布局动画结束后再刷新一次：PencilKit 在尺寸变化过程中放入的笔迹可能不会被绘制
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                let current = self.drawing
                self.isRefreshing = true
                self.drawing = PKDrawing()
                self.drawing = current
                self.isRefreshing = false
            }
        }
    }
    override var inputView: UIView? { noKeyboard }
    override var inputAccessoryView: UIView? { nil }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // 去掉键盘上方的快捷栏（撤销 / 重做 / 粘贴）
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        return result
    }
}

/// 笔记本里所有手写区共用的工具：换一次笔，每道题都生效
final class InkTools: ObservableObject {
    /// marker：荧光笔；ask：圈选提问，用笔圈出一步，圈的这一笔不留在纸上
    enum Tool { case pen, marker, eraser, lasso, ask }
    enum EraserKind: String { case area, stroke }

    @Published var tool: Tool = .pen
    @Published var eraserKind: EraserKind {
        didSet { UserDefaults.standard.set(eraserKind.rawValue, forKey: "handwritingEraserKind") }
    }
    /// 没有 Apple Pencil 时可以打开，让手指也能书写（这时要在空白处滑动页面）
    @Published var allowFinger: Bool {
        didSet { UserDefaults.standard.set(allowFinger, forKey: "handwritingAllowFinger") }
    }
    /// 笔和荧光笔的颜色（十六进制）、粗细，记住上次的选择
    @Published var penColor: String { didSet { UserDefaults.standard.set(penColor, forKey: "inkPenColor") } }
    @Published var penWidth: Double { didSet { UserDefaults.standard.set(penWidth, forKey: "inkPenWidth") } }
    @Published var markerColor: String { didSet { UserDefaults.standard.set(markerColor, forKey: "inkMarkerColor") } }
    @Published var markerWidth: Double { didSet { UserDefaults.standard.set(markerWidth, forKey: "inkMarkerWidth") } }
    /// 荧光笔的不透明度（0.15–1），1 就是荧光笔本来的样子
    @Published var markerOpacity: Double { didSet { UserDefaults.standard.set(markerOpacity, forKey: "inkMarkerOpacity") } }

    /// 笔型（仿 GoodNotes）：钢笔有粗细变化，圆珠笔粗细均匀，签字笔介于两者之间
    enum PenKind: String, CaseIterable, Identifiable {
        case fountain, ballpoint, felt
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fountain: return "钢笔"
            case .ballpoint: return "圆珠笔"
            case .felt: return "签字笔"
            }
        }
    }
    @Published var penKind: PenKind { didSet { UserDefaults.standard.set(penKind.rawValue, forKey: "inkPenKind") } }
    /// 压力灵敏度：0 粗细不随压力变，0.5 默认，1 压力影响大
    @Published var penPressure: Double { didSet { UserDefaults.standard.set(penPressure, forKey: "inkPenPressure") } }
    /// 笔尖扁平度：0 圆笔尖，1 很扁（书法效果）
    @Published var penFlatness: Double { didSet { UserDefaults.standard.set(penFlatness, forKey: "inkPenFlatness") } }
    /// 画笔稳定性：0 不处理，1 最平滑
    @Published var penStability: Double { didSet { UserDefaults.standard.set(penStability, forKey: "inkPenStability") } }
    /// 局部橡皮擦的大小
    @Published var eraserWidth: Double { didSet { UserDefaults.standard.set(eraserWidth, forKey: "inkEraserWidth") } }

    static let penWidthRange: ClosedRange<Double> = 1...12
    static let eraserWidthRange: ClosedRange<Double> = 6...60

    /// 写完一笔后要不要按手感参数重新整理
    var shapesPenStrokes: Bool {
        tool == .pen && !InkShape.isDefault(pressure: penPressure, flatness: penFlatness, stability: penStability)
    }

    static let penColors = ["#1C1C1E", "#1F4FA8", "#C0392B", "#2E7D32"]
    static let penWidths: [Double] = [2, 3, 5]
    static let markerColors = ["#FFE066", "#A5E887", "#FFA8C5", "#9CD3FF"]
    static let markerWidthRange: ClosedRange<Double> = 4...40
    static let markerOpacityRange: ClosedRange<Double> = 0.15...1

    /// 当前是不是“按住侧边”的临时橡皮擦
    @Published private(set) var isTemporaryEraser = false

    /// 双击笔身切到橡皮擦前的工具，再双击时切回去
    private var toolBeforeEraser: Tool = .pen
    /// 按住笔身侧边（Apple Pencil Pro 捏住）时临时用橡皮擦，松开恢复的工具
    private var toolBeforeSqueeze: Tool?
    /// 最近写过的手写区，撤销 / 重做作用在它上面
    weak var active: HandwritingModel?

    init() {
        eraserKind = EraserKind(rawValue: UserDefaults.standard.string(forKey: "handwritingEraserKind") ?? "") ?? .area
        allowFinger = UserDefaults.standard.bool(forKey: "handwritingAllowFinger")
        let d = UserDefaults.standard
        penColor = d.string(forKey: "inkPenColor") ?? Self.penColors[0]
        penWidth = d.object(forKey: "inkPenWidth") as? Double ?? 3
        markerColor = d.string(forKey: "inkMarkerColor") ?? Self.markerColors[0]
        markerWidth = d.object(forKey: "inkMarkerWidth") as? Double ?? 16
        markerOpacity = d.object(forKey: "inkMarkerOpacity") as? Double ?? 1
        penKind = PenKind(rawValue: d.string(forKey: "inkPenKind") ?? "") ?? .felt
        penPressure = d.object(forKey: "inkPenPressure") as? Double ?? 0.5
        penFlatness = d.object(forKey: "inkPenFlatness") as? Double ?? 0
        penStability = d.object(forKey: "inkPenStability") as? Double ?? 0
        eraserWidth = d.object(forKey: "inkEraserWidth") as? Double ?? 18
    }

    /// 应用到画布上的工具；key 变了才重新设置
    var styleKey: String { "\(tool)-\(eraserKind)-\(allowFinger)-\(penColor)-\(penWidth)-\(markerColor)-\(markerWidth)-\(markerOpacity)-\(penKind)-\(eraserWidth)" }

    func pkTool() -> PKTool {
        switch tool {
        case .pen:
            let ink: PKInkingTool.InkType
            switch penKind {
            case .fountain: ink = .fountainPen
            case .ballpoint: ink = .monoline
            case .felt: ink = .pen
            }
            return PKInkingTool(ink, color: UIColor(hex: penColor), width: penWidth)
        case .marker:
            return PKInkingTool(.marker, color: UIColor(hex: markerColor).withAlphaComponent(markerOpacity), width: markerWidth)
        case .eraser: return eraserKind == .stroke ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: eraserWidth)
        case .lasso: return PKLassoTool()
        case .ask: return PKInkingTool(.pen, color: .systemBlue, width: 2)
        }
    }

    /// 圈选提问之前的工具，圈完一次就切回去
    private var toolBeforeAsk: Tool = .pen

    func select(_ newTool: Tool) {
        if newTool == .eraser && tool != .eraser { toolBeforeEraser = tool }
        if newTool == .ask && tool != .ask { toolBeforeAsk = tool }
        tool = newTool
    }

    /// 圈完一处：切回原来的工具，接着写
    func finishAsk() {
        if tool == .ask { tool = toolBeforeAsk }
    }

    /// Apple Pencil 双击：在橡皮擦和之前的工具之间切换
    func toggleEraser() {
        if tool == .eraser {
            tool = toolBeforeEraser
        } else {
            toolBeforeEraser = tool
            tool = .eraser
        }
    }

    /// 按住笔身侧边：临时切到橡皮擦
    func beginTemporaryEraser() {
        guard toolBeforeSqueeze == nil else { return }
        toolBeforeSqueeze = tool
        tool = .eraser
        isTemporaryEraser = true
    }

    /// 松开笔身侧边：恢复原来的工具
    func endTemporaryEraser() {
        guard let previous = toolBeforeSqueeze else { return }
        toolBeforeSqueeze = nil
        tool = previous
        isTemporaryEraser = false
    }

    func undo() { active?.canvas?.undoManager?.undo() }
    func redo() { active?.canvas?.undoManager?.redo() }
}

/// 一道题的手写区。笔迹（PKDrawing）保存在这里，画布视图可以随页面滚动被回收、重建
final class HandwritingModel: ObservableObject {
    @Published var isEmpty = true
    /// 手写区高度：写到下面时自动加长
    @Published var height: CGFloat
    /// 刚用“圈选提问”圈住的地方，等学生写下要问什么
    @Published var circledRegion: CGRect?
    /// 橡皮擦经过的位置（手写区坐标）：用来擦掉叠在纸上的批改标注，它们不是笔迹，PencilKit 的橡皮擦不到
    var onEraserTouch: ((CGPoint) -> Void)?
    /// 手写区上要不要标出圈选提问的蓝框。一开始继续写字就藏起来，免得挡着书写；点页边的“问”再显示
    @Published var askRegionVisible = false

    let tools: InkTools
    private(set) var drawing = PKDrawing()
    /// 当前显示在屏幕上的画布
    weak var canvas: PadCanvasView?

    /// 笔迹属于哪道题；为 nil 时不保存
    private let questionID: UUID?
    private var pendingSave: DispatchWorkItem?

    static let isAvailable = true
    static let minHeight: CGFloat = 260
    /// 每次加长的高度
    static let growStep: CGFloat = 240

    init(questionID: UUID?, tools: InkTools) {
        self.questionID = questionID
        self.tools = tools
        // 恢复这道题上次写的笔迹
        if let questionID, let data = DrawingStore.load(questionID), let saved = try? PKDrawing(data: data) {
            drawing = saved
        }
        let empty = drawing.strokes.isEmpty
        height = empty ? Self.minHeight : max(Self.minHeight, drawing.bounds.maxY + 160)
        isEmpty = empty
    }

    /// 新建或重建画布时调用：放入笔迹、应用当前工具
    func attach(_ canvas: PadCanvasView) {
        self.canvas = canvas
        // 没有要恢复的笔迹就不用等画布排好版
        canvas.pendingDrawing = drawing.strokes.isEmpty ? nil : drawing
        appliedTools = nil
        applyTools()
    }

    /// 上次应用到画布上的工具；没变就不重复设置，免得打断正在写的一笔
    private var appliedTools: String?

    func applyTools() {
        let key = tools.styleKey
        guard let canvas, key != appliedTools else { return }
        appliedTools = key
        canvas.tool = tools.pkTool()
        canvas.drawingPolicy = tools.allowFinger ? .anyInput : .pencilOnly
    }

    func drawingChanged(_ newDrawing: PKDrawing) {
        drawing = newDrawing
        let empty = newDrawing.strokes.isEmpty
        if isEmpty != empty { isEmpty = empty }
        // 写到靠近底部时自动加长，像翻到下一行纸
        if !empty, newDrawing.bounds.maxY > height - 100 {
            height = newDrawing.bounds.maxY + Self.growStep
        }
        tools.active = self
        // 只在变化时赋值，平时写字不会让整道题的页面跟着刷新
        if askRegionVisible { askRegionVisible = false }
        scheduleSave()
    }

    /// 某一块地方的笔迹图片（圈出来问时和下面的文字截图合在一起）
    func drawingImage(in rect: CGRect) -> UIImage? {
        guard !drawing.strokes.isEmpty, rect.width > 1, rect.height > 1 else { return nil }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: rect, scale: 2)
        }
        return image
    }

    /// 圈选提问画完一笔：这一笔不留在纸上，记下圈住的地方。只点了一下就当作圈住这一行
    func circled(_ bounds: CGRect) {
        var region = bounds
        if bounds.width < 30 && bounds.height < 30 {
            let row = RuledPaper.row(at: bounds.midY)
            let span = inkSpan(inRow: row) ?? (bounds.minX - 60)...(bounds.maxX + 60)
            region = CGRect(x: span.lowerBound, y: RuledPaper.top(ofRow: row),
                            width: span.upperBound - span.lowerBound, height: RuledPaper.lineSpacing)
        }
        circledRegion = region.insetBy(dx: -4, dy: -4)
        askRegionVisible = true
        tools.finishAsk()
    }

    /// 某一行（横线行，从 1 开始）里笔迹的左右范围；这一行没写字时为 nil
    func inkSpan(inRow row: Int) -> ClosedRange<CGFloat>? {
        let band = CGRect(x: -10_000, y: RuledPaper.top(ofRow: row) + 6, width: 20_000, height: RuledPaper.lineSpacing - 12)
        var hits = drawing.strokes.map(\.renderBounds).filter { $0.intersects(band) }
        // 跨好几行的长笔画（竖线、大括号）不算这一行的字，除非这一行只有它
        let short = hits.filter { $0.height < RuledPaper.lineSpacing * 2.5 }
        if !short.isEmpty { hits = short }
        guard let first = hits.first else { return nil }
        let union = hits.dropFirst().reduce(first) { $0.union($1) }
        return union.minX...union.maxX
    }

    func addSpace() { height += Self.growStep }

    /// 笔迹变化后稍等片刻再写盘，连续书写时不会频繁保存
    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let questionID else { return }
        DrawingStore.save(drawing.strokes.isEmpty ? nil : drawing.dataRepresentation(), for: questionID)
    }

    func clear() {
        drawing = PKDrawing()
        canvas?.pendingDrawing = nil
        canvas?.drawing = PKDrawing()
        isEmpty = true
        height = Self.minHeight
        saveNow()
    }

    /// 导出发给 AI 的手写图片：左边印上行号、画上横线，AI 才能说出错在哪一行。
    /// highlight：圈选提问时圈住的地方，用蓝框标出
    func exportJPEG(highlight: CGRect? = nil) -> Data? {
        guard !drawing.strokes.isEmpty else { return nil }
        let spacing = RuledPaper.lineSpacing
        var content = drawing.bounds
        if let highlight { content = content.union(highlight) }
        let firstRow = RuledPaper.row(at: content.minY)
        let lastRow = max(firstRow, RuledPaper.row(at: content.maxY))
        let top = RuledPaper.top(ofRow: firstRow)
        let left = max(0, content.minX - 24)
        let area = CGRect(x: left, y: top, width: content.maxX + 24 - left,
                          height: CGFloat(lastRow - firstRow + 1) * spacing)
        var ink: UIImage!
        // 固定浅色外观，避免深色模式下导出白色笔迹
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: area, scale: 2)
        }
        let gutter: CGFloat = 40
        let size = CGSize(width: area.width + gutter, height: area.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: UIColor.gray
            ]
            for row in firstRow...lastRow {
                let bottom = RuledPaper.top(ofRow: row) + spacing - top
                UIColor(red: 0.62, green: 0.72, blue: 0.86, alpha: 0.6).setFill()
                context.fill(CGRect(x: gutter, y: bottom - 0.5, width: area.width, height: 1))
                let label = "\(row)" as NSString
                let labelSize = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: gutter - 8 - labelSize.width, y: bottom - spacing / 2 - labelSize.height / 2),
                           withAttributes: attributes)
            }
            UIColor.gray.withAlphaComponent(0.4).setFill()
            context.fill(CGRect(x: gutter - 2, y: 0, width: 1, height: size.height))
            ink.draw(in: CGRect(x: gutter, y: 0, width: area.width, height: area.height))
            if let highlight {
                let box = UIBezierPath(roundedRect: highlight.offsetBy(dx: gutter - left, dy: -top), cornerRadius: 8)
                box.lineWidth = 3
                UIColor.systemBlue.setStroke()
                box.stroke()
            }
        }
        guard let cg = image.cgImage else { return nil }
        // 1280 像素足够看清手写，图片更小，上传和识别都更快
        return ImageUtil.jpeg(cg).flatMap { ImageUtil.normalizedJPEG($0, maxPixel: 1280) }
    }
}

/// 笔记上的涂鸦层盖在文字上面：画布本身不接收触摸，书写手势挂到下面的文字视图上。
/// 这样手指照样能选字、翻页、点按钮，只有笔的触摸被认成书写
final class InkHost {
    weak var view: UIView?
}

/// 笔记本里的一块手写区：横线纸背景；画布不自己滚动，手指拖动滚的是整本笔记
struct NotebookCanvas: UIViewRepresentable {
    @ObservedObject var model: HandwritingModel
    @ObservedObject var tools: InkTools
    /// 笔记上的涂鸦层：书写手势挂到这个视图（下面的文字）上
    var host: InkHost?

    func makeUIView(context: Context) -> PadCanvasView {
        let canvas = PadCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.delegate = context.coordinator
        // Apple Pencil 双击 / 捏合切换橡皮擦
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        canvas.addInteraction(pencil)
        // 跟着书写手势看橡皮擦经过哪里，好擦掉批改标注
        canvas.drawingGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.drawingGesture(_:)))
        model.attach(canvas)
        // 文字视图可能还没建好，下一轮再挂一次
        attachToHost(canvas)
        DispatchQueue.main.async { attachToHost(canvas) }
        return canvas
    }

    func updateUIView(_ uiView: PadCanvasView, context: Context) {
        attachToHost(uiView)
        // 工具在任何一块手写区换了，所有手写区跟着换
        if model.canvas !== uiView { model.attach(uiView) } else { model.applyTools() }
    }

    /// 涂鸦层：书写手势挂到文字视图上，画布不挡触摸；框选时画布要能拖动选中的笔迹
    private func attachToHost(_ canvas: PadCanvasView) {
        guard let host else { return }
        canvas.isUserInteractionEnabled = tools.tool == .lasso
        if let target = host.view, canvas.drawingGestureRecognizer.view !== target {
            target.addGestureRecognizer(canvas.drawingGestureRecognizer)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        let model: HandwritingModel
        /// 用户正在用笔（或手指）写，下一次笔迹变化是用户写的
        private var penDown = false
        init(model: HandwritingModel) { self.model = model }

        @objc func drawingGesture(_ gesture: UIGestureRecognizer) {
            // 很快的一笔可能只收到“结束”，也要算
            guard model.tools.tool == .eraser, [.began, .changed, .ended].contains(gesture.state),
                  let view = gesture.view else { return }
            model.onEraserTouch?(gesture.location(in: view))
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            penDown = true
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let pad = canvasView as? PadCanvasView else { return }
            // 恢复的笔迹还没放进去，用户就开始写了：把恢复的笔迹和新写的合在一起
            if let pending = pad.pendingDrawing, penDown {
                pad.pendingDrawing = nil
                var merged = pending
                merged.strokes.append(contentsOf: canvasView.drawing.strokes)
                DispatchQueue.main.async {
                    if pad.drawing != merged { pad.drawing = merged }
                }
                let byPen = penDown
                penDown = false
                if byPen, model.tools.tool == .ask, let stroke = canvasView.drawing.strokes.last {
                    // 圈的这一笔不留：只放回恢复的笔迹
                    DispatchQueue.main.async { pad.drawing = pending }
                    model.circled(stroke.renderBounds)
                } else {
                    model.drawingChanged(merged)
                }
                return
            }
            // 恢复、重新放入笔迹时的变化不算；把圈选的一笔撤掉时也会进来，笔迹没变就不算
            guard pad.pendingDrawing == nil, !pad.isRefreshing, canvasView.drawing != model.drawing else { return }
            let byPen = penDown
            penDown = false
            // 圈选提问：用户刚画的这一笔只用来圈出地方，不留在纸上
            if byPen, model.tools.tool == .ask, canvasView.drawing.strokes.count == model.drawing.strokes.count + 1,
               let stroke = canvasView.drawing.strokes.last {
                let saved = model.drawing
                DispatchQueue.main.async { canvasView.drawing = saved }
                model.circled(stroke.renderBounds)
                return
            }
            // 笔的手感参数（压力灵敏度、笔尖扁平度、稳定性）：把刚写的这一笔重新整理
            if byPen, model.tools.shapesPenStrokes,
               canvasView.drawing.strokes.count == model.drawing.strokes.count + 1,
               let shaped = Self.shaped(canvasView.drawing, tools: model.tools) {
                let before = model.drawing
                model.drawingChanged(shaped)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // PencilKit 已经记下“加了原来那一笔”：先撤掉，撤销记录里只留下面换成整理后笔画的这一步
                    if let undoManager = canvasView.undoManager, undoManager.canUndo {
                        undoManager.undo()
                    }
                    self.replace(canvasView, with: shaped, undoTo: before)
                }
                return
            }
            model.drawingChanged(canvasView.drawing)
        }

        /// 用代码换掉画布上的笔迹，PencilKit 不会记撤销，自己记：撤销回到写这一笔之前，重做再放回来
        private func replace(_ canvasView: PKCanvasView, with drawing: PKDrawing, undoTo previous: PKDrawing) {
            let undoManager = canvasView.undoManager
            canvasView.drawing = drawing
            model.drawingChanged(drawing)
            undoManager?.registerUndo(withTarget: self) { coordinator in
                coordinator.replace(canvasView, with: previous, undoTo: drawing)
            }
        }

        /// 按笔的手感参数重新生成最后一笔
        static func shaped(_ drawing: PKDrawing, tools: InkTools) -> PKDrawing? {
            guard let stroke = drawing.strokes.last else { return nil }
            let original = Array(stroke.path)
            guard original.count > 1 else { return nil }
            let points = original.map { InkShape.Point(location: $0.location, force: $0.force, size: $0.size.width) }
            let smoothed = InkShape.smooth(points, stability: tools.penStability)
            let widths = InkShape.widths(smoothed, pressure: tools.penPressure, flatness: tools.penFlatness)
            let newPoints = original.indices.map { i -> PKStrokePoint in
                let p = original[i]
                let scale = widths[i] / max(p.size.width, 0.01)
                return PKStrokePoint(location: smoothed[i].location, timeOffset: p.timeOffset,
                                     size: CGSize(width: widths[i], height: p.size.height * scale),
                                     opacity: p.opacity, force: p.force, azimuth: p.azimuth, altitude: p.altitude)
            }
            let path = PKStrokePath(controlPoints: newPoints, creationDate: stroke.path.creationDate)
            var result = drawing
            result.strokes[result.strokes.count - 1] = PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)
            return result
        }

        // iPadOS 17.0–17.4
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            handleTap()
        }

        // iPadOS 17.5 起
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            handleTap()
        }

        /// Apple Pencil Pro：按住笔身侧边时是橡皮擦，松开恢复原来的工具
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            switch squeeze.phase {
            case .began:
                // 用户在“设置 › Apple Pencil”里关闭了捏合就不响应
                guard UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
                model.tools.beginTemporaryEraser()
            case .ended, .cancelled:
                model.tools.endTemporaryEraser()
            default:
                break
            }
        }

        /// Apple Pencil 2 不能感知“按住”，双击笔身在笔和橡皮擦之间切换
        private func handleTap() {
            // 尊重系统设置：用户在“设置 › Apple Pencil”里关闭了双击就不响应
            guard UIPencilInteraction.preferredTapAction != .ignore else { return }
            model.tools.toggleEraser()
        }
    }
}

/// 浮在页面底部的工具栏（仿 Notability）：大按钮，可以收起成一个小胶囊；
/// 再点一次已选中的工具（或点右边的调节按钮），上方展开这个工具的参数
struct InkPalette: View {
    @ObservedObject var tools: InkTools
    @AppStorage("inkPaletteCollapsed") private var collapsed = false
    @State private var showOptions = false

    var body: some View {
        VStack(spacing: 8) {
            if tools.isTemporaryEraser {
                Text("正在用橡皮擦 · 松开笔身侧边恢复书写")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
            if showOptions && !collapsed {
                InkOptionsPanel(tools: tools)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if collapsed {
                collapsedBar
            } else {
                // 页面窄（侧栏打开、分屏）时去掉文字、按钮小一点
                ViewThatFits(in: .horizontal) {
                    fullBar(labels: true)
                    fullBar(labels: false)
                }
            }
        }
        .animation(.spring(duration: 0.25), value: showOptions)
        .animation(.spring(duration: 0.25), value: collapsed)
        // 换工具时，参数面板跟着换；选了没有参数的工具就收起来
        .onChange(of: tools.tool) {
            if tools.tool == .lasso { showOptions = false }
        }
    }

    /// 收起：只剩当前工具和颜色，点一下展开
    private var collapsedBar: some View {
        Button {
            collapsed = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(tools.tool)).font(.title3)
                if let color = currentColor {
                    Circle().fill(color).frame(width: 16, height: 16)
                }
                Image(systemName: "chevron.up").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开工具栏")
    }

    private func fullBar(labels: Bool) -> some View {
        HStack(spacing: labels ? 6 : 2) {
            toolButton(.pen, title: "笔", label: labels)
            toolButton(.marker, title: "荧光笔", label: labels)
            toolButton(.eraser, title: "橡皮", label: labels)
            toolButton(.lasso, title: "框选", label: labels)
            toolButton(.ask, title: "圈出来问", label: labels)

            Divider().frame(height: 30).padding(.horizontal, labels ? 4 : 2)

            iconButton("arrow.uturn.backward", "撤销") { tools.undo() }
            iconButton("arrow.uturn.forward", "重做") { tools.redo() }
            iconButton(showOptions ? "slider.horizontal.below.square.filled.and.square" : "slider.horizontal.3", "调节") {
                showOptions.toggle()
            }
            iconButton("chevron.down", "收起工具栏") {
                showOptions = false
                collapsed = true
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, labels ? 12 : 8).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    private var currentColor: Color? {
        switch tools.tool {
        case .pen: return Color(UIColor(hex: tools.penColor))
        case .marker: return Color(UIColor(hex: tools.markerColor))
        default: return nil
        }
    }

    private func icon(_ tool: InkTools.Tool) -> String {
        switch tool {
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .eraser: return tools.eraserKind == .stroke ? "eraser.line.dashed" : "eraser"
        case .lasso: return "lasso"
        case .ask: return "questionmark.bubble"
        }
    }

    private func toolButton(_ tool: InkTools.Tool, title: String, label: Bool) -> some View {
        let selected = tools.tool == tool
        return Button {
            // 再点一次已选中的工具：展开或收起它的参数
            if selected && tool != .lasso {
                showOptions.toggle()
            } else {
                tools.select(tool)
            }
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: icon(tool))
                        .font(.title2)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    if tool == .pen || tool == .marker {
                        // 小圆点是当前颜色
                        Circle()
                            .fill(Color(UIColor(hex: tool == .pen ? tools.penColor : tools.markerColor)))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1))
                            .offset(x: 4, y: 2)
                    }
                }
                if label {
                    Text(title).font(.caption2).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
            }
            .frame(width: label ? 58 : 46, height: label ? 52 : 44)
            .background(selected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func iconButton(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title3).frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }
}

/// 当前工具的参数：笔（颜色、笔型、粗细、压力灵敏度、笔尖扁平度、稳定性），荧光笔（颜色、粗细、透明度），橡皮（方式、大小）
private struct InkOptionsPanel: View {
    @ObservedObject var tools: InkTools

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tools.tool {
            case .pen: penOptions
            case .marker: markerOptions
            case .eraser: eraserOptions
            case .ask:
                Text("用笔圈住想问的地方，圈的这一笔不会留下，圈完弹出输入框。")
                    .font(.callout).foregroundStyle(.secondary)
            case .lasso:
                EmptyView()
            }
            Divider()
            Toggle(isOn: $tools.allowFinger) {
                Label("允许手指书写", systemImage: "hand.draw").font(.callout)
            }
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    // MARK: 笔

    private var penOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            colorRow(InkTools.penColors, color: $tools.penColor)
            Picker("笔型", selection: $tools.penKind) {
                ForEach(InkTools.PenKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            PenPreview(color: Color(UIColor(hex: tools.penColor)), width: tools.penWidth,
                       pressure: tools.penPressure, flatness: tools.penFlatness, stability: tools.penStability)
                .frame(height: 56)
            slider("笔尖粗细", $tools.penWidth, InkTools.penWidthRange, String(format: "%.1f", tools.penWidth))
            slider("压力灵敏度", $tools.penPressure, 0...1, percent(tools.penPressure))
            slider("笔尖扁平度", $tools.penFlatness, 0...1, percent(tools.penFlatness))
            slider("画笔稳定性", $tools.penStability, 0...1, percent(tools.penStability))
            HStack {
                Text("扁平的笔尖斜着写：横细竖粗，像钢笔、书法笔。稳定性越高，手抖时线条越顺。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认") {
                    tools.penPressure = 0.5
                    tools.penFlatness = 0
                    tools.penStability = 0
                    tools.penWidth = 3
                }
                .font(.caption)
            }
        }
    }

    // MARK: 荧光笔

    private var markerOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            colorRow(InkTools.markerColors, color: $tools.markerColor)
            ZStack(alignment: .leading) {
                // 真正的荧光笔是正片叠底，字在下面也看得清：预览里把色块放在字后面
                Capsule()
                    .fill(Color(UIColor(hex: tools.markerColor)).opacity(0.75 * tools.markerOpacity))
                    .frame(width: 220, height: min(tools.markerWidth, 40))
                Text("荧光笔预览 Aa 你好").font(.callout).foregroundStyle(.primary).padding(.leading, 8)
            }
            .frame(height: 44)
            slider("粗细", $tools.markerWidth, InkTools.markerWidthRange, "\(Int(tools.markerWidth.rounded()))")
            slider("透明度", $tools.markerOpacity, InkTools.markerOpacityRange, percent(tools.markerOpacity))
        }
    }

    // MARK: 橡皮

    private var eraserOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("橡皮擦类型", selection: $tools.eraserKind) {
                Text("局部擦除").tag(InkTools.EraserKind.area)
                Text("整笔擦除").tag(InkTools.EraserKind.stroke)
            }
            .pickerStyle(.segmented)
            if tools.eraserKind == .area {
                slider("大小", $tools.eraserWidth, InkTools.eraserWidthRange, "\(Int(tools.eraserWidth.rounded()))")
            }
        }
    }

    // MARK: 共用

    /// 预设颜色，最后一个是自选颜色
    private func colorRow(_ presets: [String], color: Binding<String>) -> some View {
        HStack(spacing: 14) {
            ForEach(presets, id: \.self) { hex in
                Button {
                    color.wrappedValue = hex
                } label: {
                    Circle()
                        .fill(Color(UIColor(hex: hex)))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Color.primary, lineWidth: color.wrappedValue == hex ? 2.5 : 0).padding(-4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("颜色")
            }
            Divider().frame(height: 26)
            // 自选颜色
            ColorPicker("自选颜色", selection: Binding(
                get: { Color(UIColor(hex: color.wrappedValue)) },
                set: { color.wrappedValue = UIColor($0).hexString }), supportsOpacity: false)
                .labelsHidden()
                .overlay(alignment: .bottom) {
                    if !presets.contains(color.wrappedValue) {
                        Circle().fill(Color.primary).frame(width: 5, height: 5).offset(y: 9)
                    }
                }
            Spacer(minLength: 0)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.callout).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
            Text(label).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
        }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

/// 笔的预览：用和写字一样的算法画一条“S”形线，调参数时立刻能看到效果
private struct PenPreview: View {
    let color: Color
    let width: Double
    let pressure: Double
    let flatness: Double
    let stability: Double

    var body: some View {
        Canvas { context, size in
            // 一条带抖动和压力变化的示范笔画
            let n = 90
            var points: [InkShape.Point] = (0..<n).map { i in
                let t = CGFloat(i) / CGFloat(n - 1)
                let x = 16 + t * (size.width - 32)
                let y = size.height / 2 + sin(t * .pi * 2.4) * size.height * 0.3 + (i % 3 == 0 ? 1.6 : -0.8)
                let force = 0.25 + 0.75 * sin(t * .pi)
                return InkShape.Point(location: CGPoint(x: x, y: y), force: force, size: CGFloat(width) * (0.6 + 0.8 * force))
            }
            points = InkShape.smooth(points, stability: stability)
            let widths = InkShape.widths(points, pressure: pressure, flatness: flatness)
            for i in 1..<points.count {
                var segment = Path()
                segment.move(to: points[i - 1].location)
                segment.addLine(to: points[i].location)
                context.stroke(segment, with: .color(color),
                               style: StrokeStyle(lineWidth: (widths[i - 1] + widths[i]) / 2, lineCap: .round))
            }
        }
        .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .light)
    }
}

extension UIColor {
    /// "#RRGGBB"
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let clamp = { (v: CGFloat) in max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", clamp(r), clamp(g), clamp(b))
    }
}

#else

/// Mac 上仅用于编译检查，不提供手写
final class InkTools: ObservableObject {}

final class HandwritingModel: ObservableObject {
    @Published var isEmpty = true
    @Published var height: CGFloat = 260
    let tools: InkTools
    static let isAvailable = false
    init(questionID: UUID?, tools: InkTools) { self.tools = tools }
    func clear() {}
    func saveNow() {}
    @Published var circledRegion: CGRect?
    @Published var askRegionVisible = false
    var onEraserTouch: ((CGPoint) -> Void)?
    func addSpace() {}
    func inkSpan(inRow row: Int) -> ClosedRange<CGFloat>? { nil }
    func exportJPEG(highlight: CGRect? = nil) -> Data? { nil }
}

final class InkHost {}

struct NotebookCanvas: View {
    @ObservedObject var model: HandwritingModel
    @ObservedObject var tools: InkTools
    var host: InkHost?
    var body: some View { Color.clear }
}

struct InkPalette: View {
    @ObservedObject var tools: InkTools
    var body: some View { EmptyView() }
}

#endif

#if os(iOS)
extension UIColor {
    /// "#RRGGBB"
    convenience init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
#endif
