import SwiftUI

#if os(iOS)
import PencilKit
import Combine

extension PKDrawing {
    /// 中心在 y 以下的笔画往下挪 dy
    func shifted(below y: CGFloat, by dy: CGFloat) -> PKDrawing {
        var result = self
        result.strokes = strokes.map { stroke in
            guard stroke.renderBounds.midY > y else { return stroke }
            var moved = stroke
            moved.transform = stroke.transform.concatenating(CGAffineTransform(translationX: 0, y: dy))
            return moved
        }
        return result
    }
}

extension DrawingStore {
    /// 直接改存下的笔迹（笔记页没开着时用）
    static func shiftStrokes(_ id: UUID, below y: CGFloat, by dy: CGFloat) {
        guard let data = load(id), let drawing = try? PKDrawing(data: data) else { return }
        save(drawing.shifted(below: y, by: dy).dataRepresentation(), for: id)
    }
}

/// 框选后画布会成为第一响应者（用于剪切 / 拷贝 / 撤销），这里阻止它顺带弹出键盘
final class PadCanvasView: PKCanvasView {
    private let noKeyboard = UIView(frame: .zero)
    /// 恢复的笔迹要等画布显示到屏幕上再放进去，否则 PencilKit 不会绘制
    var pendingDrawing: PKDrawing?
    /// 正在重新放入笔迹（不是用户在写），这时的变化不算
    private(set) var isRefreshing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        observePageMoves()
        // 每一笔写完时，把写的时候推迟的换笔迹补上
        drawingGestureRecognizer.addTarget(self, action: #selector(strokeGestureChanged(_:)))
        drawingGestureRecognizer.addTarget(self, action: #selector(trackAskOutline(_:)))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observePageMoves()
        drawingGestureRecognizer.addTarget(self, action: #selector(strokeGestureChanged(_:)))
        drawingGestureRecognizer.addTarget(self, action: #selector(trackAskOutline(_:)))
    }

    // MARK: 圈出来问的虚线

    /// 正在用“圈出来问”：PencilKit 的笔画不了虚线，这时笔的墨水是透明的（见 InkTools.pkTool），
    /// 由这里沿着笔尖画一条深蓝色虚线；抬笔就拿掉（圈的这一笔本来就不留在纸上）
    var drawsAskOutline = false {
        didSet { if !drawsAskOutline { askPath = nil; askOutline.path = nil } }
    }
    private var askPath: UIBezierPath?
    /// 落笔的位置：书写手势挪了一小段才开始，虚线从落笔的地方画起
    private var askStart: CGPoint?
    private lazy var askOutline: CAShapeLayer = {
        let outline = CAShapeLayer()
        outline.fillColor = nil
        outline.lineWidth = 2.5
        outline.lineDashPattern = [7, 5]
        outline.lineCap = .round
        outline.lineJoin = .round
        outline.zPosition = 1000
        layer.addSublayer(outline)
        return outline
    }()

    @objc private func trackAskOutline(_ gesture: UIGestureRecognizer) {
        guard drawsAskOutline else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            let path = UIBezierPath()
            path.move(to: askStart ?? point)
            path.addLine(to: point)
            askStart = nil
            askPath = path
            askOutline.strokeColor = UIColor(Ink.blue).resolvedColor(with: traitCollection).cgColor
        case .changed:
            askPath?.addLine(to: point)
        default:
            askPath = nil
        }
        // 不要隐式动画：虚线要紧跟着笔尖
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        askOutline.path = askPath?.cgPath
        CATransaction.commit()
    }

    // MARK: 写字时不换笔迹
    //
    // 正在写的一笔还没落下时，用代码给 drawing 赋值（放回恢复的笔迹、清空再放回逼 PencilKit 重画、换成整理后的笔画……），
    // PencilKit 会把这一笔取消，只留下最后一个点：写字时纸上冒出来的小点、偶尔整笔不见，都是这么来的。
    // 所以所有用代码换笔迹的地方都走 whenIdle：没在写就马上做，正在写就等这一笔抬起来再做

    /// 笔（或手指）正落在纸上写着。笔一碰到纸就算，不等书写手势开始：
    /// 刚落笔、书写手势还没开始的那一下换笔迹，这一笔也会被取消
    var isStroking: Bool {
        let state = drawingGestureRecognizer.state
        return state == .began || state == .changed || touchWatcher.isDown
    }

    /// 有笔落在纸上
    var isPencilDown: Bool { touchWatcher.pencilDown }

    /// 看着落在纸上的笔和手指（只看不拦）
    private lazy var touchWatcher: InkTouchWatcher = {
        let watcher = InkTouchWatcher()
        // 手指只有在能写字（打开了手指书写）时才算；手掌、滑动页面的手指不算
        watcher.canDraw = { [weak self] touch in touch.type == .pencil || self?.drawingPolicy == .anyInput }
        watcher.onPencilDown = { [weak self] in self?.pencilTouchedDown() }
        watcher.onDrawTouchBegan = { [weak self] touch in
            guard let self, self.drawsAskOutline else { return }
            self.askStart = touch.location(in: self)
        }
        // 换完笔迹 PencilKit 还没重画好就又落笔了：这时才把垫着的截图露出来（见 coverWhileRedrawing）
        watcher.onTouchDown = { [weak self] in
            guard let self, self.touchWatcher.isDown, self.awaitingRender else { return }
            self.redrawCovers.forEach { $0.isHidden = false }
        }
        watcher.onAllLifted = { [weak self] in
            guard let self else { return }
            // 写的时候 PencilKit 不重画别处：抬笔后等它画完再拿掉垫在下面的截图
            if !self.redrawCovers.isEmpty { self.armCoverDeadline() }
            guard !self.deferredWork.isEmpty else { return }
            self.scheduleFlush()
        }
        return watcher
    }()

    /// 书写手势挂在哪个视图上（笔记的涂鸦层挂在下面的文字上），看触摸的也挂在那里
    private func syncTouchWatcher() {
        guard let target = drawingGestureRecognizer.view, touchWatcher.view !== target else { return }
        target.addGestureRecognizer(touchWatcher)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncTouchWatcher()
    }

    // MARK: 写字时手掌、别的手指不滚动、不缩放画布
    //
    // 白板的画布自己就能滚动、缩放。笔在写的时候手掌碰到屏幕、拖动了一点，画布就滚起来（或者两点一捏就缩放），
    // PencilKit 会把正在写的这一笔取消：这就是写着写着“断触”。笔落在纸上时不让画布开始滚动、缩放；
    // 笔落下时画布已经在被手掌拖着滚，就把这次拖动停掉，让笔接着写

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if touchWatcher.pencilDown, gestureRecognizer === panGestureRecognizer || gestureRecognizer === pinchGestureRecognizer {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    private func pencilTouchedDown() {
        for gesture in [panGestureRecognizer, pinchGestureRecognizer].compactMap({ $0 })
        where gesture.state == .began || gesture.state == .changed {
            // 关掉再打开会取消正在进行的手势
            gesture.isEnabled = false
            gesture.isEnabled = true
        }
    }

    private var deferredWork: [() -> Void] = []
    private var flushScheduled = false

    /// 没在写就马上做；正在写就等这一笔写完再做（到时候再读当时的笔迹，不会把刚写的一笔弄丢）
    func whenIdle(_ work: @escaping () -> Void) {
        syncTouchWatcher()
        if isStroking || !deferredWork.isEmpty {
            deferredWork.append(work)
            scheduleFlush()
        } else {
            work()
        }
    }

    @objc private func strokeGestureChanged(_ gesture: UIGestureRecognizer) {
        if [.ended, .cancelled, .failed].contains(gesture.state), !deferredWork.isEmpty { scheduleFlush() }
    }

    /// 稍等一下再做：PencilKit 要先把刚抬笔的这一笔放进笔迹；那时又开始写下一笔了就接着等
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard !self.isStroking else { return }  // 抬笔（手）时还会再排
            let work = self.deferredWork
            self.deferredWork = []
            work.forEach { $0() }
        }
    }

    /// 清空再放回去，逼 PencilKit 把现有的笔迹重画一遍（尺寸、缩放变了它常常不重画）。写字时等抬笔再做
    ///
    /// 清空的那一下会空一帧，字就闪一下：先拍一张现在的样子垫在画布下面，PencilKit 重画完再拿掉
    func refreshRendering() {
        whenIdle { [weak self] in
            guard let self, self.pendingDrawing == nil, !self.drawing.strokes.isEmpty else { return }
            self.coverWhileRedrawing()
            let current = self.drawing
            self.isRefreshing = true
            self.drawing = PKDrawing()
            self.drawing = current
            self.isRefreshing = false
        }
    }

    // MARK: 收起、拉出栏时垫一张截图
    //
    // 收起、拉出左栏或目录时，PencilKit 一看到外面的排版在变就把画好的字丢掉，等外面停下来才重画：
    // 栏滑动的那零点几秒里手写的字整块不见（看起来像少了笔画、闪一下）。栏开始滑之前先拍一张垫在下面露着，重画好再拿掉

    static let pageWillMove = Notification.Name("PadCanvasPageWillMove")

    // 用 selector 的写法：画布释放时系统自动注销。以前用 block 的写法、没留下注销用的 token，
    // 每个建过的画布都留下一个观察者，越用越多，每次拉出、收起栏都要挨个跑一遍
    private func observePageMoves() {
        NotificationCenter.default.addObserver(self, selector: #selector(pageWillMove(_:)), name: Self.pageWillMove, object: nil)
    }

    @objc private func pageWillMove(_ note: Notification) {
        guard window != nil, pendingDrawing == nil, !isStroking, !drawing.strokes.isEmpty else { return }
        coverWhileRedrawing()
    }

    // MARK: 用代码换笔迹时垫一张截图
    //
    // 用代码给 drawing 赋值（写完一笔整理笔锋、撤销、排版变了挪笔迹、逼它重画……）后，PencilKit 要过几帧才把变了的地方重画好。
    // 这几帧里笔又落下开始写下一笔，PencilKit 会先顾着正在写的这一笔、停下别处的重画，直到这一笔写完：
    // 刚写的上一笔就在写下一笔时消失、抬笔后才回来。
    // 所以换笔迹前先拍一张现在的样子垫在画布下面（画布是透明的）：没重画好的地方露出来的是截图里的字，
    // 正在写的笔画在画布上，不会被挡住。PencilKit 重画完、笔也抬起来了再拿掉

    /// 写完一笔整理笔锋、换笔迹时，垫着的截图一开始就露出来（白板）。
    /// 白板的画布是一大块，真机上 PencilKit 换完笔迹要空一两帧才重画好，截图藏着的话字就闪一下
    var showsCoverWhileReshaping = false

    /// 垫在画布下面的截图（连着换了几次就有几张，一起拿掉）
    private var redrawCovers: [UIView] = []
    private var coverDeadline: DispatchWorkItem?
    /// 换了笔迹、PencilKit 还没报告重画好
    private var awaitingRender = false
    /// 拍截图时画布滚动到的位置：之后画布滚动、缩放了，截图就对不上，马上拿掉
    private var coverOffset: CGPoint = .zero
    private var coverZoom: CGFloat = 1

    /// visible 为 false：先藏着，PencilKit 重画好之前又落笔了才露出来。
    /// 截图和画布上的字叠在一起会画两遍（边缘发硬、对不准时像重影，看起来就是别的字一下变模糊），
    /// 所以只在真的需要它补位的时候才露出来：写完一笔整理笔锋时，PencilKit 不清空画布，直接换笔迹没有空白的一帧。
    ///
    /// changed / becoming：要换成的笔迹（纸的坐标）和变了的那一块。截图拍的是换之前的样子，
    /// 整理笔锋前后这一笔的粗细、位置都不一样，叠在画布上整理后的笔画下面，写下一笔时这一笔就毛毛的、像糊了，
    /// 一抬笔截图拿掉才又清楚。所以截图上这一块挖掉，换成照着新笔迹画的图，和画布上的一模一样
    func coverWhileRedrawing(visible: Bool = true, changed: CGRect? = nil, becoming newDrawing: PKDrawing? = nil) {
        guard window != nil, let superview, bounds.width > 1, bounds.height > 1,
              let snapshot = snapshotView(afterScreenUpdates: false) else { return }
        if !redrawCovers.isEmpty, contentOffset != coverOffset || zoomScale != coverZoom { removeRedrawCover() }
        // 截图装在一层里：这一层和画布一样大、一样的位置。
        // 画布在正文的缩放里（scaleEffect）：frame 在有变换时不可靠，照着 bounds / center / transform 放，才和画布严丝合缝
        let cover = UIView()
        cover.bounds = CGRect(origin: .zero, size: bounds.size)
        cover.center = center
        cover.transform = transform
        cover.isUserInteractionEnabled = false
        snapshot.frame = cover.bounds
        cover.addSubview(snapshot)
        if let changed, let newDrawing { patch(snapshot, in: cover, at: changed, with: newDrawing) }
        cover.isHidden = !visible && !isStroking
        superview.insertSubview(cover, belowSubview: self)
        redrawCovers.append(cover)
        awaitingRender = true
        coverOffset = contentOffset
        coverZoom = zoomScale
        armCoverDeadline()
    }

    /// 截图上 changed 这一块（纸的坐标）挖掉，放上照着新笔迹画的这一块
    private func patch(_ snapshot: UIView, in cover: UIView, at changed: CGRect, with newDrawing: PKDrawing) {
        guard !changed.isNull, !changed.isInfinite, !changed.isEmpty else { return }
        // 纸的坐标 → 画布笔迹的坐标：笔画边上留一点，抗锯齿的毛边也挖干净
        let rect = changed.offsetBy(dx: overflow, dy: overflow).insetBy(dx: -4, dy: -4).integral
        let zoom = zoomScale
        // 在画布看得见的这一块里的位置
        let local = CGRect(x: rect.minX * zoom - contentOffset.x, y: rect.minY * zoom - contentOffset.y,
                           width: rect.width * zoom, height: rect.height * zoom)
        guard local.intersects(cover.bounds) else { return }
        // 屏幕上实际放大了多少（正文的 scaleEffect 也算上），图按这个清晰度画
        let onScreen = convert(CGRect(x: 0, y: 0, width: 100, height: 100), to: nil).width / 100
        let scale = (window?.screen.scale ?? 2) * zoom * min(max(onScreen, 0.25), 4)
        // 只画和这一块挨着的笔画：写完一笔正要写下一笔时在主线程上做，满满一页时不用把所有笔画都挪一遍
        let near = changed.insetBy(dx: -8, dy: -8)
        let canvasDrawing = PKDrawing(strokes: newDrawing.strokes.filter { $0.renderBounds.intersects(near) }.map { stroke in
            var moved = stroke
            moved.transform = stroke.transform.concatenating(toCanvas)
            return moved
        })
        var image = UIImage()
        // 深色模式下 PencilKit 会把墨水颜色反过来画，图也按画布的深浅画
        traitCollection.performAsCurrent { image = canvasDrawing.image(from: rect, scale: scale) }
        let mask = CAShapeLayer()
        mask.frame = snapshot.layer.bounds
        let path = UIBezierPath(rect: mask.bounds)
        path.append(UIBezierPath(rect: local.offsetBy(dx: mask.bounds.minX, dy: mask.bounds.minY)))
        mask.path = path.cgPath
        mask.fillRule = .evenOdd
        snapshot.layer.mask = mask
        let piece = UIImageView(image: image)
        piece.frame = local
        cover.addSubview(piece)
    }

    /// PencilKit 没报告画完也不一直垫着；笔还在纸上就接着等
    private func armCoverDeadline() {
        coverDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isStroking { self.armCoverDeadline() } else { self.removeRedrawCover() }
        }
        coverDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: deadline)
    }

    /// PencilKit 画完了：再等一帧拿掉截图，免得刚画完的那一帧还没上屏。
    /// 笔还在纸上时它报告的“画完”不算（只画了正在写的这一笔），等抬笔后下一次
    func renderingFinished() {
        guard !redrawCovers.isEmpty, !isStroking else { return }
        awaitingRender = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.isStroking else { return }
            self.removeRedrawCover()
        }
    }

    func removeRedrawCover() {
        coverDeadline?.cancel()
        coverDeadline = nil
        redrawCovers.forEach { $0.removeFromSuperview() }
        redrawCovers = []
        awaitingRender = false
    }

    /// 画布在屏幕上且有了实际尺寸后再放入恢复的笔迹
    override func layoutSubviews() {
        // 画布大出文字的那一圈也要画得出来：PencilKit 只画内容范围里的笔迹
        if overflow > 0, contentSize != bounds.size { contentSize = bounds.size }
        super.layoutSubviews()
        // 画布滚动、缩放了：垫着的截图对不上了，拿掉。
        // 只是挪了位置、变宽变窄（收起拉出栏以后页面重排）：笔迹按画布左上角算，截图跟着左上角挪过去接着垫着，
        // 拿掉的话 PencilKit 重画好之前字会空一两帧
        if let first = redrawCovers.first {
            if contentOffset != coverOffset || zoomScale != coverZoom || first.transform != transform {
                removeRedrawCover()
            } else if first.bounds.size != bounds.size || first.center != center {
                let topLeft = CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2)
                for cover in redrawCovers {
                    cover.center = CGPoint(x: topLeft.x + cover.bounds.width / 2, y: topLeft.y + cover.bounds.height / 2)
                }
            }
        }
        guard pendingDrawing != nil, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.whenIdle { [weak self] in
                guard let self, let drawing = self.pendingDrawing else { return }
                self.pendingDrawing = nil
                self.isRefreshing = true
                self.paperDrawing = drawing
                self.isRefreshing = false
                // 布局动画结束后再刷新一次：PencilKit 刚放入的笔迹有时有一块不画（白板上也见过），
                // 刷新时盖着截图，不会闪
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refreshRendering() }
            }
        }
    }

    /// 用代码换掉笔迹（不算用户写的），再逼 PencilKit 重画一遍。写字时等抬笔再换
    func replaceDrawing(_ newDrawing: PKDrawing) {
        whenIdle { [weak self] in
            guard let self else { return }
            self.coverWhileRedrawing()
            self.isRefreshing = true
            self.paperDrawing = newDrawing
            self.isRefreshing = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.paperDrawing == newDrawing else { return }
                self.refreshRendering()
            }
        }
    }

    /// 画布比文字四周各大出这么多（笔记的涂鸦层）：从文字里写到页边、块和块之间的笔画不会在文字边上被截断。
    /// PencilKit 画不出坐标为负的笔迹，所以画布上的坐标比纸的坐标（文字左上角为原点）多出这么多；
    /// 存下的、圈出来问的位置都还是纸的坐标，进出画布时用 paperDrawing 换算
    var overflow: CGFloat = 0

    private var toPaper: CGAffineTransform { CGAffineTransform(translationX: -overflow, y: -overflow) }
    private var toCanvas: CGAffineTransform { CGAffineTransform(translationX: overflow, y: overflow) }
    /// 上一次换算的结果：没变的笔画直接用，来回换算不会带来浮点误差
    private var converted: (canvas: PKDrawing, paper: PKDrawing)?

    /// 纸的坐标下的笔迹
    var paperDrawing: PKDrawing {
        get {
            guard overflow > 0 else { return drawing }
            let current = drawing
            var paper: PKDrawing
            if let converted, converted.canvas == current {
                return converted.paper
            } else if let converted, current.strokes.count > converted.canvas.strokes.count,
                      PKDrawing(strokes: current.strokes.prefix(converted.canvas.strokes.count)) == converted.canvas {
                // 平时写字：只是多了几笔，只换算新写的
                paper = converted.paper
                let added = PKDrawing(strokes: current.strokes.dropFirst(converted.canvas.strokes.count))
                paper.strokes.append(contentsOf: added.transformed(using: toPaper).strokes)
            } else {
                paper = current.transformed(using: toPaper)
            }
            converted = (current, paper)
            return paper
        }
        set {
            guard overflow > 0 else { drawing = newValue; return }
            let shown = newValue.transformed(using: toCanvas)
            converted = (shown, newValue)
            drawing = shown
        }
    }

    /// 纸以外大出来的那一圈不接收触摸（框选时）：下面的空白和别的块照常能写
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard overflow > 0 else { return super.point(inside: point, with: event) }
        return bounds.insetBy(dx: overflow, dy: overflow).contains(point)
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

/// 只看不拦：记下现在有几支笔、几根能写字的手指落在纸上。自己从不生效，不影响别的手势
final class InkTouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var canDraw: (UITouch) -> Bool = { $0.type == .pencil }
    var onPencilDown: () -> Void = {}
    var onTouchDown: () -> Void = {}
    /// 能写字的笔或手指落下的那一下（书写手势要挪一点才开始，落笔的位置从这里拿）
    var onDrawTouchBegan: (UITouch) -> Void = { _ in }
    var onAllLifted: () -> Void = {}
    private var drawing = Set<ObjectIdentifier>()
    private var pencils = Set<ObjectIdentifier>()
    private var all = Set<ObjectIdentifier>()

    /// 有能写字的笔或手指落在纸上
    var isDown: Bool { !drawing.isEmpty }
    /// 有笔落在纸上
    var pencilDown: Bool { !pencils.isEmpty }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        var pencil = false
        for touch in touches {
            let id = ObjectIdentifier(touch)
            all.insert(id)
            if canDraw(touch) { drawing.insert(id); onDrawTouchBegan(touch) }
            if touch.type == .pencil { pencils.insert(id); pencil = true }
        }
        onTouchDown()
        if pencil { onPencilDown() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        let wasDown = isDown
        for touch in touches {
            let id = ObjectIdentifier(touch)
            all.remove(id)
            drawing.remove(id)
            pencils.remove(id)
        }
        if wasDown && !isDown { onAllLifted() }
        // 所有触摸都离开了：这一轮结束（只在这时失败，之前一直看着）
        if all.isEmpty { state = .failed }
    }

    override func reset() {
        let wasDown = isDown
        all = []
        drawing = []
        pencils = []
        if wasDown { onAllLifted() }
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
    /// 两支笔（默认黑、蓝），各记各的颜色和粗细，方便用不同颜色记笔记；笔型、压力等两支共用
    @Published var penSlotColors: [String] {
        didSet {
            UserDefaults.standard.set(penSlotColors[0], forKey: "inkPenColor")
            UserDefaults.standard.set(penSlotColors[1], forKey: "inkPen2Color")
        }
    }
    /// 正在用第几支笔（0 / 1）
    @Published var penSlot: Int { didSet { UserDefaults.standard.set(penSlot, forKey: "inkPenSlot") } }
    @Published var penSlotWidths: [Double] {
        didSet {
            UserDefaults.standard.set(penSlotWidths[0], forKey: "inkPenWidth")
            UserDefaults.standard.set(penSlotWidths[1], forKey: "inkPen2Width")
        }
    }
    /// 当前这支笔的颜色（十六进制）
    var penColor: String {
        get { penSlotColors[penSlot] }
        set { penSlotColors[penSlot] = newValue }
    }
    /// 当前这支笔的粗细
    var penWidth: Double {
        get { penSlotWidths[penSlot] }
        set { penSlotWidths[penSlot] = newValue }
    }
    /// 荧光笔的颜色、粗细，记住上次的选择
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
            case .fountain: return L("钢笔")
            case .ballpoint: return L("圆珠笔")
            case .felt: return L("签字笔")
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
        tool == .pen && (penNib > 0 || !InkShape.isDefault(pressure: penPressure, flatness: penFlatness, stability: penStability))
    }

    /// 钢笔的笔锋（横细竖粗）。PencilKit 自带的钢笔按笔身朝向算粗细，有的方向细得像头发丝，
    /// 所以钢笔写的时候用普通的笔，写完一笔再按这个整理出粗细变化
    var penNib: Double { penKind == .fountain ? 0.6 : 0 }

    static let penColors = ["#1C1C1E", "#1F4FA8", "#C0392B", "#2E7D32"]
    static let markerColors = ["#FFE066", "#A5E887", "#FFA8C5", "#9CD3FF"]
    static let markerWidthRange: ClosedRange<Double> = 4...40
    static let markerOpacityRange: ClosedRange<Double> = 0.15...1

    /// 工具栏上方的参数面板开着没有。开着时页面上盖一层（InkOptionsDismissLayer），点别处先关面板
    @Published var optionsShown = false

    /// 当前是不是“按住侧边”的临时橡皮擦
    @Published private(set) var isTemporaryEraser = false

    /// 双击笔身切到橡皮擦前的工具，再双击时切回去
    private var toolBeforeEraser: Tool = .pen
    /// 按住笔身侧边（Apple Pencil Pro 捏住）时临时用橡皮擦，松开恢复的工具
    private var toolBeforeSqueeze: Tool?
    /// 最近写过的手写区，撤销 / 重做作用在它上面
    weak var active: HandwritingModel?
    /// 橡皮擦经过别的画布时一起擦（笔记页上文字、空白处的笔迹在不同的画布上）
    let eraserRelay = InkEraserRelay()

    init() {
        eraserKind = EraserKind(rawValue: UserDefaults.standard.string(forKey: "handwritingEraserKind") ?? "") ?? .area
        allowFinger = UserDefaults.standard.bool(forKey: "handwritingAllowFinger")
        let d = UserDefaults.standard
        penSlotColors = [d.string(forKey: "inkPenColor") ?? Self.penColors[0],
                         d.string(forKey: "inkPen2Color") ?? Self.penColors[1]]
        penSlot = min(max(d.integer(forKey: "inkPenSlot"), 0), 1)
        penSlotWidths = [d.object(forKey: "inkPenWidth") as? Double ?? 3,
                         d.object(forKey: "inkPen2Width") as? Double ?? 3]
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
            case .fountain: ink = .pen
            case .ballpoint: ink = .monoline
            case .felt: ink = .pen
            }
            return PKInkingTool(ink, color: UIColor(hex: penColor), width: penWidth)
        case .marker:
            return PKInkingTool(.marker, color: UIColor(hex: markerColor).withAlphaComponent(markerOpacity), width: markerWidth)
        case .eraser: return eraserKind == .stroke ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: eraserWidth)
        case .lasso: return PKLassoTool()
        // 墨水透明：纸上看到的是画布自己画的深蓝虚线（PadCanvasView.drawsAskOutline）
        case .ask: return PKInkingTool(.monoline, color: .clear, width: 2)
        }
    }

    /// 圈选提问之前的工具，圈完一次就切回去
    private var toolBeforeAsk: Tool = .pen

    /// 选第几支笔
    func selectPen(_ slot: Int) {
        penSlot = slot
        select(.pen)
    }

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

    /// 笔（或手指）落到画布上开始写：工具栏自动缩小。不用 @Published，免得每一笔都刷新整个页面
    let writingBegan = PassthroughSubject<Void, Never>()

    /// PencilKit 记“加了一笔”的撤销项叫什么（跟系统语言走，写字时从撤销记录里认出来）
    var pencilKitStrokeUndoName: String?

    func undo() { step(undo: true) }
    func redo() { step(undo: false) }

    /// 撤销 / 重做一步。被取消的一笔（手掌把页面带动了之类）PencilKit 也会记一条“加了一笔”，
    /// 撤销它纸上什么也不变，看起来就是按了没反应、最后一笔撤不掉：这种空的一步跳过，接着做下一步。
    /// 只跳过 PencilKit 自己的“加了一笔”，别的（比如输入框里的撤销）照常一次一步
    private func step(undo: Bool) {
        guard let canvas = active?.canvas, let manager = canvas.undoManager else { return }
        for _ in 0..<8 {
            guard undo ? manager.canUndo : manager.canRedo else { return }
            let name = undo ? manager.undoActionName : manager.redoActionName
            let before = canvas.drawing
            if undo { manager.undo() } else { manager.redo() }
            let wasEmptyStroke = canvas.drawing == before && !name.isEmpty && name == pencilKitStrokeUndoName
            if !wasEmptyStroke { return }
        }
    }
}

/// 橡皮擦跨画布擦。
///
/// 笔记页上的笔迹分在好几块画布上：每一块文字一块（书写手势挂在那块文字上），页边、块和块之间的空白处一块整页的。
/// PencilKit 的橡皮擦只擦落笔那块画布上的笔迹：一笔从文字擦到页边、从这一块擦到下一块，另一块画布上的字就留着 ——
/// 擦好几个字时有的擦不掉，就是这么来的。所以橡皮擦经过的路线也交给同一页上别的画布，按同样的大小把碰到的笔迹擦掉
final class InkEraserRelay {
    private let models = NSHashTable<HandwritingModel>.weakObjects()
    /// 这一笔橡皮擦落在哪块画布上（那块由 PencilKit 自己擦）
    private weak var origin: PadCanvasView?
    private weak var originModel: HandwritingModel?
    /// 上一次经过的位置（窗口坐标）
    private var last: CGPoint?
    /// 这一笔擦到的别的画布和擦之前的笔迹：抬笔时记撤销用
    private var touched: [(canvas: PadCanvasView, before: PKDrawing)] = []

    var isErasing: Bool { origin != nil }

    func register(_ model: HandwritingModel) { models.add(model) }

    func track(_ gesture: UIGestureRecognizer, from model: HandwritingModel, tools: InkTools) {
        switch gesture.state {
        case .began, .changed, .ended: break
        case .cancelled, .failed: finish(); return
        default: return
        }
        // 看画布上真正用着的工具：刚点了橡皮、画布还没换过来时，这一笔还是笔写的
        guard let canvas = model.canvas, let eraser = canvas.tool as? PKEraserTool,
              let window = canvas.window else { finish(); return }
        if gesture.state == .began || origin !== canvas {
            finish()
            origin = canvas
            originModel = model
        }
        let point = gesture.location(in: nil)
        erase(from: last ?? point, to: point, in: window, eraser: eraser, tools: tools)
        last = point
        if gesture.state == .ended { finish() }
    }

    private func erase(from a: CGPoint, to b: CGPoint, in window: UIWindow, eraser: PKEraserTool, tools: InkTools) {
        guard let origin else { return }
        let page = Self.screenRoot(of: origin)
        // 局部擦按橡皮的大小；整笔擦碰到就算
        let wholeStrokes = eraser.eraserType == .vector
        let screenRadius: CGFloat = wholeStrokes ? 3 : eraser.width / 2
        for model in models.allObjects {
            guard let pad = model.canvas, pad !== origin, pad.window === window, !pad.isHidden,
                  pad.pendingDrawing == nil, !pad.isStroking, !pad.drawing.strokes.isEmpty,
                  // 只擦同一页上的：盖在上面的白板、弹出的页面不会擦到下面笔记的字
                  Self.screenRoot(of: pad) === page else { continue }
            // 窗口坐标 → 这块画布笔迹的坐标（画布可能滚动过、缩放过，文字块的画布还整体缩放过）
            let zoom = max(pad.zoomScale, 0.0001)
            func local(_ p: CGPoint) -> CGPoint {
                let q = pad.convert(p, from: nil)
                return CGPoint(x: q.x / zoom, y: q.y / zoom)
            }
            let la = local(a), lb = local(b)
            let probe = local(CGPoint(x: a.x + 100, y: a.y))
            let radius = screenRadius * hypot(probe.x - la.x, probe.y - la.y) / 100
            let before = pad.drawing
            guard let erased = Self.erase(before, from: la, to: lb, radius: radius,
                                          wholeStrokes: wholeStrokes) else { continue }
            if !touched.contains(where: { $0.canvas === pad }) { touched.append((pad, before)) }
            // 垫着的截图里还有擦掉的字，拿掉
            pad.removeRedrawCover()
            pad.drawing = erased
        }
        // 撤销 / 重做还是作用在落笔的那块（别的画布擦掉的记在它上面，一起撤销）
        if let originModel { tools.active = originModel }
    }

    /// 抬笔：别的画布上擦掉的记一步撤销，记在落笔那块画布上。
    /// 和 PencilKit 记的“擦掉”在同一次事件里登记，撤销时一下全回来
    private func finish() {
        let changes = touched.compactMap { item -> Change? in
            let after = item.canvas.drawing
            return after == item.before ? nil : Change(canvas: item.canvas, before: item.before, after: after)
        }
        if let origin, let manager = origin.undoManager, !changes.isEmpty {
            Self.registerUndo(on: manager, changes: changes, origin: origin, backward: true, active: originModel)
        }
        origin = nil
        originModel = nil
        last = nil
        touched = []
    }

    private struct Change {
        weak var canvas: PadCanvasView?
        let before: PKDrawing
        let after: PKDrawing
    }

    private static func registerUndo(on manager: UndoManager, changes: [Change], origin: PadCanvasView,
                                     backward: Bool, active: HandwritingModel?) {
        manager.registerUndo(withTarget: manager) { [weak origin, weak active] manager in
            guard let origin else { return }
            registerUndo(on: manager, changes: changes, origin: origin, backward: !backward, active: active)
            for change in changes {
                guard let pad = change.canvas, pad.window != nil else { continue }
                pad.drawing = backward ? change.before : change.after
            }
            if let active { active.tools.active = active }
            // 撤销时放回来的笔画（连同落笔那块 PencilKit 自己放回的）PencilKit 常常不画，
            // 手写块还可能跟着变高：等这一下忙完逼它们重画一遍
            let pads = changes.compactMap(\.canvas) + [origin]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                pads.forEach { $0.refreshRendering() }
            }
        }
    }

    /// 视图所在的这一页（窗口的根页面，或者弹出来盖在上面的那一页）
    private static func screenRoot(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let r = responder, !(r is UIViewController) { responder = r.next }
        var controller = responder as? UIViewController
        while let parent = controller?.parent { controller = parent }
        return controller
    }

    /// 擦掉 a 到 b 这一段碰到的笔迹（笔迹的坐标）；什么也没碰到时为 nil。
    /// wholeStrokes：整笔擦；否则只擦掉碰到的那一段，两边剩下的各留成一笔
    static func erase(_ drawing: PKDrawing, from a: CGPoint, to b: CGPoint, radius: CGFloat,
                      wholeStrokes: Bool) -> PKDrawing? {
        let reach = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .insetBy(dx: -radius, dy: -radius)
        let step = min(max(radius / 3, 0.5), 2)
        var strokes: [PKStroke] = []
        var changed = false
        for stroke in drawing.strokes {
            guard stroke.renderBounds.intersects(reach) else { strokes.append(stroke); continue }
            let points = Array(stroke.path.interpolatedPoints(by: .distance(step)))
            // 笔画有粗细：橡皮碰到墨迹的边就算
            let hit = points.map { p in
                distance(p.location.applying(stroke.transform), a, b) <= radius + p.size.width / 2
            }
            guard hit.contains(true) else { strokes.append(stroke); continue }
            changed = true
            if wholeStrokes { continue }
            var run: [PKStrokePoint] = []
            func keepRun() {
                if run.count > 1 {
                    var piece = PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: run, creationDate: stroke.path.creationDate),
                                         transform: stroke.transform, mask: stroke.mask)
                    piece.randomSeed = stroke.randomSeed
                    strokes.append(piece)
                }
                run = []
            }
            for (point, isHit) in zip(points, hit) {
                if isHit { keepRun() } else { run.append(point) }
            }
            keepRun()
        }
        guard changed else { return nil }
        var result = drawing
        result.strokes = strokes
        return result
    }

    /// 点 p 到线段 ab 的距离
    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length2, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
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
    /// 圈选提问画完一笔时交给这里（白板：按圈的形状选出里面的笔迹），不设就按圈住的方框处理
    var onCircleStroke: ((PKStroke) -> Void)?
    /// 手写区上要不要标出圈选提问的蓝框。一开始继续写字就藏起来，免得挡着书写；点页边的“问”再显示
    @Published var askRegionVisible = false

    let tools: InkTools
    /// 只认 Apple Pencil（打开了“手指书写”也一样）：笔记的空白处留给手指滑动页面
    var pencilOnly = false
    /// 用户写了、擦了（不是只换显示位置）
    var onDrawingChanged: (() -> Void)?
    /// 只换了显示位置（整页涂鸦跟着排版挪）时，存盘的还是原来记下的笔迹
    private var storedDrawing: PKDrawing?
    private(set) var drawing = PKDrawing()
    /// 纸上有几笔：用来判断上次求助以后有没有接着写
    var strokeCount: Int { drawing.strokes.count }
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
        tools.eraserRelay.register(self)
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
        canvas.drawsAskOutline = tools.tool == .ask
        canvas.drawingPolicy = tools.allowFinger && !pencilOnly ? .anyInput : .pencilOnly
    }

    func drawingChanged(_ newDrawing: PKDrawing) {
        drawing = newDrawing
        let empty = newDrawing.strokes.isEmpty
        if isEmpty != empty { isEmpty = empty }
        // 写到靠近底部时自动加长，像翻到下一行纸
        if !empty, newDrawing.bounds.maxY > height - 100 {
            grow(to: newDrawing.bounds.maxY + Self.growStep)
        }
        tools.active = self
        // 只在变化时赋值，平时写字不会让整道题的页面跟着刷新
        if askRegionVisible { askRegionVisible = false }
        storedDrawing = nil
        onDrawingChanged?()
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

    /// 圈选提问画完一笔：交给白板，或者按圈住的方框处理
    func circled(stroke: PKStroke) {
        if let onCircleStroke {
            onCircleStroke(stroke)
            tools.finishAsk()
        } else {
            circled(stroke.renderBounds)
        }
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

    /// 画布变高以后 PencilKit 有时不重画已有的笔迹（笔记里的手写块是缩放过的）：停一下放回一次逼它重画
    func redrawSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.canvas?.refreshRendering()
        }
    }

    /// 写字时推迟的加长：等正在写的这一笔写完再加长
    private var pendingHeight: CGFloat?

    /// 画布上有一笔正在写。PencilKit 常常在下一笔已经开始时才报告上一笔写完，
    /// 这时改画布大小会把正在写的这一笔打断
    private var strokeInProgress: Bool {
        guard let state = canvas?.drawingGestureRecognizer.state else { return false }
        return state == .began || state == .changed
    }

    private func grow(to newHeight: CGFloat) {
        guard newHeight > height else { return }
        if strokeInProgress {
            pendingHeight = max(pendingHeight ?? 0, newHeight)
        } else {
            pendingHeight = nil
            height = newHeight
        }
    }

    /// 一笔写完（或被取消）时调用：补上写的时候推迟的加长
    func strokeEnded() {
        guard pendingHeight != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.strokeInProgress, let pending = self.pendingHeight else { return }
            self.pendingHeight = nil
            if pending > self.height { self.height = pending }
        }
    }

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
        let toSave = storedDrawing ?? drawing
        DrawingStore.saveInBackground(for: questionID) { toSave.strokes.isEmpty ? nil : toSave.dataRepresentation() }
    }

    /// 笔记这一块中间插进了内容：y 以下的笔迹往下挪 dy，屏幕上和存下的一起改
    func shiftStrokes(below y: CGFloat, by dy: CGFloat) {
        let shifted = drawing.shifted(below: y, by: dy)
        guard shifted != drawing else { return }
        drawing = shifted
        if let canvas {
            // 恢复的笔迹还没放上画布：换成挪过的；已经在画布上：直接换（和模型一致，不算用户改的）
            if canvas.pendingDrawing != nil {
                canvas.pendingDrawing = shifted
            } else {
                canvas.whenIdle { [weak canvas, weak self] in
                    guard let canvas, let self else { return }
                    canvas.paperDrawing = self.drawing
                }
            }
        }
        saveNow()
    }

    /// 只换显示的位置，不算用户改的，存盘的还是原来的笔迹
    func display(_ shown: PKDrawing) {
        guard shown != drawing else { return }
        if storedDrawing == nil { storedDrawing = drawing }
        drawing = shown
        if let canvas {
            if canvas.pendingDrawing != nil {
                // 还没放上画布：换掉等着放的，并且让画布再排一次版，否则可能一直放不上去
                canvas.pendingDrawing = shown
                canvas.setNeedsLayout()
            } else {
                canvas.replaceDrawing(shown)
            }
        }
    }

    func clear() {
        drawing = PKDrawing()
        storedDrawing = nil
        canvas?.pendingDrawing = nil
        canvas?.paperDrawing = PKDrawing()
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
        let gutter: CGFloat = 40
        let size = CGSize(width: area.width + gutter, height: area.height)
        // 宽不超过 1280 像素就够看清手写；写得多（图很高）时高度放宽到 2400，不然整张缩小后每行的字太小。
        // 识别时高的图会切成几段同时转写（ImageUtil.horizontalStrips），每段都不大。
        // 直接按最后的大小画：以前先按 2 倍画出整张大图（写得长时几千万像素）、压成 JPEG，再解开缩小、再压一次
        let scale = 2 * min(1, 1280 / (size.width * 2), 2400 / (size.height * 2))
        var ink: UIImage!
        // 固定浅色外观，避免深色模式下导出白色笔迹
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: area, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
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
                // fill(_:) 默认是 copy 混合，半透明颜色会变成很深的线；要 normal 才是浅色横线
                context.fill(CGRect(x: gutter, y: bottom - 0.5, width: area.width, height: 1), blendMode: .normal)
                let label = "\(row)" as NSString
                let labelSize = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: gutter - 8 - labelSize.width, y: bottom - spacing / 2 - labelSize.height / 2),
                           withAttributes: attributes)
            }
            UIColor.gray.withAlphaComponent(0.4).setFill()
            context.fill(CGRect(x: gutter - 2, y: 0, width: 1, height: size.height), blendMode: .normal)
            ink.draw(in: CGRect(x: gutter, y: 0, width: area.width, height: area.height))
            if let highlight {
                let box = UIBezierPath(roundedRect: highlight.offsetBy(dx: gutter - left, dy: -top), cornerRadius: 8)
                box.lineWidth = 3
                UIColor.systemBlue.setStroke()
                box.stroke()
            }
        }
        guard let cg = image.cgImage else { return nil }
        return ImageUtil.jpeg(cg)
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
    /// 画布比文字四周各大出多少：从文字里写出去的笔画照样画得出来
    var overflow: CGFloat = 0

    func makeUIView(context: Context) -> PadCanvasView {
        let canvas = PadCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.overflow = overflow
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

    /// 白板的画布在这个基础上再看滚动、缩放和框选（BoardCanvas.Coordinator）
    class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        let model: HandwritingModel
        /// 用户正在用笔（或手指）写，下一次笔迹变化是用户写的
        private var penDown = false
        /// 正在用代码换画布上的笔迹（replace），这时的变化不是用户写的
        private var applying = false
        init(model: HandwritingModel) { self.model = model }

        /// 写字时锁住的页面：手掌碰到屏幕把页面滚动了，笔下的纸跟着动，会画出一条笔直的长线
        private weak var lockedScroll: UIScrollView?

        private func lockScrolling(_ gesture: UIGestureRecognizer) {
            guard lockedScroll == nil else { return }
            var view = gesture.view?.superview
            while let v = view, !(v is UIScrollView && v.bounds.height > 0 && !(v is PKCanvasView)) { view = v.superview }
            guard let scroll = view as? UIScrollView, scroll.isScrollEnabled else { return }
            // 关掉再打开会取消正在进行的拖动
            scroll.isScrollEnabled = false
            lockedScroll = scroll
        }

        private func unlockScrolling() {
            lockedScroll?.isScrollEnabled = true
            lockedScroll = nil
        }

        @objc func drawingGesture(_ gesture: UIGestureRecognizer) {
            switch gesture.state {
            case .began, .changed: lockScrolling(gesture)
            case .ended, .cancelled, .failed: unlockScrolling()
            default: break
            }
            // 开始写：工具栏自动缩小。笔记上的涂鸦层把书写手势挂在文字视图上，
            // 不一定会走 canvasViewDidBeginUsingTool，手势也可能只收到“结束”，所以这里也发
            if [.began, .changed, .ended].contains(gesture.state) { model.tools.writingBegan.send() }
            // 写字时推迟的加长，这一笔写完再补上
            if [.ended, .cancelled, .failed].contains(gesture.state) { model.strokeEnded() }
            // 橡皮擦经过的地方，别的画布上的笔迹也擦掉
            if model.canvas?.tool is PKEraserTool || model.tools.eraserRelay.isErasing {
                model.tools.eraserRelay.track(gesture, from: model, tools: model.tools)
            }
            // 很快的一笔可能只收到“结束”，也要算
            guard model.tools.tool == .eraser, [.began, .changed, .ended].contains(gesture.state),
                  let view = gesture.view else { return }
            model.onEraserTouch?(gesture.location(in: view))
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            penDown = true
            model.tools.writingBegan.send()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            model.strokeEnded()
        }

        /// 圈选提问圈的那几笔（按写下的时间和点数认）。用代码把它从纸上拿掉以后，PencilKit 心里还记着它：
        /// 下一笔写完时会连它一起放回来，蓝圈就一直留在纸上。认出来就再拿掉
        private var discardedCircles: [CircleKey] = []

        private struct CircleKey: Equatable {
            let created: Date
            let points: Int
            init(_ stroke: PKStroke) {
                created = stroke.path.creationDate
                points = stroke.path.count
            }
        }

        private func discard(_ stroke: PKStroke) {
            discardedCircles.append(CircleKey(stroke))
            if discardedCircles.count > 20 { discardedCircles.removeFirst() }
        }

        /// 去掉被 PencilKit 放回来的圈；没有就原样返回
        private func withoutCircles(_ drawing: PKDrawing) -> PKDrawing {
            // 改过 strokes 的 PKDrawing 和原来的不再相等，没有要去掉的就一定原样返回
            guard !discardedCircles.isEmpty,
                  drawing.strokes.contains(where: { discardedCircles.contains(CircleKey($0)) }) else { return drawing }
            var cleaned = drawing
            cleaned.strokes.removeAll { discardedCircles.contains(CircleKey($0)) }
            return cleaned
        }

        func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
            (canvasView as? PadCanvasView)?.renderingFinished()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let pad = canvasView as? PadCanvasView else { return }
            // 我们自己用代码换笔迹（整理后的笔画、撤销 / 重做）：model 已经在 replace 里更新了，不当成用户写的
            guard !applying else { return }
            // 恢复的笔迹还没放进去，用户就开始写了：把恢复的笔迹和新写的合在一起
            if let pending = pad.pendingDrawing, penDown {
                pad.pendingDrawing = nil
                var merged = pending
                merged.strokes.append(contentsOf: pad.paperDrawing.strokes)
                DispatchQueue.main.async {
                    pad.whenIdle { if pad.paperDrawing != merged { pad.paperDrawing = merged } }
                }
                let byPen = penDown
                penDown = false
                if byPen, model.tools.tool == .ask, let stroke = pad.paperDrawing.strokes.last {
                    // 圈的这一笔不留：只放回恢复的笔迹
                    discard(stroke)
                    DispatchQueue.main.async { pad.whenIdle { pad.paperDrawing = pending } }
                    model.circled(stroke: stroke)
                } else {
                    model.drawingChanged(merged)
                }
                return
            }
            // 恢复、重新放入笔迹时的变化不算；把圈选的一笔撤掉时也会进来，笔迹没变就不算
            guard pad.pendingDrawing == nil, !pad.isRefreshing else { return }
            let onCanvas = pad.paperDrawing
            // 已经拿掉的圈被 PencilKit 放回来了：不算，纸上也再拿掉
            let current = withoutCircles(onCanvas)
            /// 纸上换成去掉圈的笔迹（和交给 model 的是同一份，换完不会再算一次变化）
            func dropReturnedCircle() {
                guard current != onCanvas else { return }
                DispatchQueue.main.async { [weak self] in
                    pad.whenIdle { [weak self] in
                        guard let self else { return }
                        let shown = pad.paperDrawing
                        if shown == onCanvas {
                            pad.paperDrawing = current
                        } else {
                            let cleaned = self.withoutCircles(shown)
                            if cleaned != shown { pad.paperDrawing = cleaned }
                        }
                    }
                }
            }
            guard current != model.drawing else { dropReturnedCircle(); return }
            let byPen = penDown
            penDown = false
            // 刚写下一笔：这时撤销记录最上面是 PencilKit 的“加了一笔”，记下它叫什么，撤销时好认出空的一步
            if byPen, current.strokes.count > model.drawing.strokes.count,
               let name = pad.undoManager?.undoActionName, !name.isEmpty {
                model.tools.pencilKitStrokeUndoName = name
            }
            // 圈选提问：用户刚画的这一笔只用来圈出地方，不留在纸上
            if byPen, model.tools.tool == .ask, current.strokes.count == model.drawing.strokes.count + 1,
               let stroke = current.strokes.last {
                let saved = model.drawing
                discard(stroke)
                DispatchQueue.main.async { pad.whenIdle { pad.paperDrawing = saved } }
                model.circled(stroke: stroke)
                return
            }
            // 笔的手感参数（压力灵敏度、笔尖扁平度、稳定性）：把刚写的这一笔重新整理
            if byPen, model.tools.shapesPenStrokes,
               current.strokes.count == model.drawing.strokes.count + 1,
               let shaped = Self.shaped(current, tools: model.tools) {
                let before = model.drawing
                // 先按纸上的样子记下；换成整理后的笔画时再记一次
                model.drawingChanged(current)
                DispatchQueue.main.async { [weak self] in
                    pad.whenIdle { [weak self] in
                        guard let self else { return }
                        // PencilKit 晚报了这一笔、等到下一笔写完才轮到这里：纸上已经多了别的笔画，
                        // 再换成当时整理好的样子会把后来写的弄丢，撤销记录最上面也不再是这一笔。这一笔就不整理了
                        guard pad.paperDrawing == current else { return }
                        // 先换成整理后的笔画，再把 PencilKit 记下的“加了原来那一笔”拿掉：
                        // 以前先撤销再放回，中间有一两帧这一笔不见了，写完一笔字就闪一下。
                        // 原来那一笔已经不在纸上，撤销它什么也不会改，只是从撤销记录里拿掉
                        self.replace(pad, with: shaped, undoTo: before, droppingPencilKitUndo: true)
                    }
                }
                return
            }
            model.drawingChanged(current)
            dropReturnedCircle()
        }

        /// 用代码换掉画布上的笔迹，PencilKit 不会记撤销，自己记：撤销回到写这一笔之前，重做再放回来
        private func replace(_ canvasView: PadCanvasView, with drawing: PKDrawing, undoTo previous: PKDrawing,
                             droppingPencilKitUndo: Bool = false) {
            let undoManager = canvasView.undoManager
            // 换之前垫一张截图（先藏着）：PencilKit 重画好之前又落笔写下一笔时露出来，刚写的字也不会消失。
            // 变了的那几笔在截图上换成新的样子，露出来时和画布上的对得上，不会糊
            canvasView.coverWhileRedrawing(visible: canvasView.showsCoverWhileReshaping, changed: Self.changedBounds(canvasView.paperDrawing, drawing),
                                           becoming: drawing)
            applying = true
            canvasView.paperDrawing = drawing
            if droppingPencilKitUndo, let undoManager, undoManager.canUndo {
                if let name = undoManager.undoActionName.nilIfEmpty { model.tools.pencilKitStrokeUndoName = name }
                undoManager.undo()
            }
            applying = false
            model.drawingChanged(drawing)
            // 撤销记录在整个窗口共用的撤销管理器里：不要拉着画布不放（关掉的页面、白板的画布一直留在内存里）
            undoManager?.registerUndo(withTarget: self) { [weak canvasView] coordinator in
                guard let canvasView else { return }
                coordinator.replace(canvasView, with: previous, undoTo: drawing)
            }
        }

        /// 两份笔迹里不一样的笔画占的地方（前面一样的笔画跳过）；变的太多就不算（返回 nil）
        static func changedBounds(_ old: PKDrawing, _ new: PKDrawing) -> CGRect? {
            func same(_ a: PKStroke, _ b: PKStroke) -> Bool {
                a.renderBounds == b.renderBounds && a.path.creationDate == b.path.creationDate
                    && a.path.count == b.path.count && a.ink.inkType == b.ink.inkType && a.ink.color == b.ink.color
            }
            let a = old.strokes, b = new.strokes
            var start = 0
            while start < a.count, start < b.count, same(a[start], b[start]) { start += 1 }
            let changed = a[start...] + b[start...]
            guard !changed.isEmpty, changed.count <= 40 else { return nil }
            return changed.reduce(CGRect.null) { $0.union($1.renderBounds) }
        }

        /// 按笔的手感参数重新生成最后一笔
        static func shaped(_ drawing: PKDrawing, tools: InkTools) -> PKDrawing? {
            guard let stroke = drawing.strokes.last else { return nil }
            let original = Array(stroke.path)
            guard original.count > 1 else { return nil }
            let points = original.map { InkShape.Point(location: $0.location, force: $0.force, size: $0.size.width) }
            let smoothed = InkShape.smooth(points, stability: tools.penStability)
            let widths = InkShape.widths(smoothed, pressure: tools.penPressure, flatness: tools.penFlatness,
                                         nib: tools.penNib)
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

/// 笔记整页的涂鸦层：页边、块和块之间、页尾这些空白处也能写。
/// 画布固定盖在屏幕上看得见的那一块，页面滚动、缩放时改画布的滚动位置和缩放（PencilKit 只画看得见的部分，长笔记也不占内存）；
/// 书写手势挂在页面内容最底下一层（PageInkHost）上：笔落在空白处才写到这里，落在文字上的照旧写在那一块上。
/// 笔迹用纸的坐标存：x 从正文左边算、按正文的缩放比例缩放，页面变宽变窄、全屏时和正文一起挪
final class PageInkLayout {
    weak var canvas: PadCanvasView?
    weak var host: UIView?
    /// 正文左边在页面内容里的位置、正文缩放比例、纸宽
    var textLeft: CGFloat = 0
    var scale: CGFloat = 1
    var paper: CGFloat = 800
    /// 正文左边留出的纸面（纸的坐标）：正文左边的页边也能写
    static let leftMargin: CGFloat = 2000
    private var observation: NSKeyValueObservation?
    private weak var observedScroll: UIScrollView?
    private var pendingRefresh: DispatchWorkItem?

    /// 每一块在页面内容里的位置（上下边），和量的时候正文的缩放比例。
    /// 页面变宽变窄时缩放比例先变、块的位置后量到，两个要是同一次排版的才对得上
    var blockFrames: [UUID: (frame: CGRect, scale: CGFloat)] = [:]
    private var pendingSettle: DispatchWorkItem?

    /// 块的位置变了：等排版停下来再挪笔迹，排版过程中的中间状态不算
    func scheduleSettle(_ action: @escaping () -> Void) {
        pendingSettle?.cancel()
        let work = DispatchWorkItem(block: action)
        pendingSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 记下的笔迹，和记下时每一块的上下边（纸的坐标）。排版变了只改显示的位置，记下的不动：
    /// 排版中途的样子（文字还没排好、高度一下变小）不会把笔迹挤坏
    private var reference: PKDrawing?
    private var referenceAnchors: [String: [Double]]?

    /// 现在每一块的上下边（纸的坐标）；还没排好版（高度是 0、有的块还是上一次排版量的）时为 nil
    func measure(_ blocks: [UUID]) -> [String: [Double]]? {
        guard let scale = blocks.first.flatMap({ blockFrames[$0]?.scale }), scale > 0 else { return nil }
        var current: [String: [Double]] = [:]
        for id in blocks {
            guard let measured = blockFrames[id], measured.frame.height > 4,
                  abs(measured.scale - scale) < 0.0001 else { return nil }
            let frame = measured.frame
            current[id.uuidString] = [Double(frame.minY / scale), Double(frame.maxY / scale)].map { ($0 * 10).rounded() / 10 }
        }
        return current
    }

    /// 排版停下来以后：空白处的笔迹按记下时的位置放到现在的排版上。
    /// 一块旁边的笔迹按它在这一块里的比例放到这一块现在的位置；块和块之间的笔迹按比例放到现在两块之间
    /// （中间插进了新的块，就跟着上面一块的下边走）。saved 是存下的位置；要存新的位置时返回
    func settle(_ model: HandwritingModel, blocks: [UUID], saved: [String: [Double]]?) -> [String: [Double]]? {
        guard let current = measure(blocks) else { return nil }
        if reference == nil {
            reference = model.drawing
            referenceAnchors = saved
        }
        // 第一次记下排版（以前没写过）
        guard let reference, let referenceAnchors else {
            referenceAnchors = current
            return current
        }
        guard !reference.strokes.isEmpty else { return nil }
        let map = Self.mapping(blocks: blocks.map(\.uuidString), saved: referenceAnchors, current: current)
        var shown = reference
        shown.strokes = reference.strokes.map { stroke in
            let y = Double(stroke.renderBounds.midY)
            let dy = CGFloat(map(y) - y)
            guard abs(dy) > 0.01 else { return stroke }
            var moved = stroke
            moved.transform = stroke.transform.concatenating(CGAffineTransform(translationX: 0, y: dy))
            return moved
        }
        model.display(shown)
        return nil
    }

    /// 用户写了、擦了：现在显示的就是要记下的，按现在的排版记；返回要存的位置
    func userChanged(_ model: HandwritingModel, blocks: [UUID]) -> [String: [Double]]? {
        reference = model.drawing
        if let current = measure(blocks) { referenceAnchors = current }
        return referenceAnchors
    }

    /// 旧排版里的 y 对应到新排版里的哪里
    static func mapping(blocks: [String], saved: [String: [Double]], current: [String: [Double]]) -> (Double) -> Double {
        let index = Dictionary(blocks.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // 两次都有的块，按原来的上下顺序
        let old = blocks.filter { (saved[$0]?.count ?? 0) == 2 && (current[$0]?.count ?? 0) == 2 }
            .sorted { saved[$0]![0] < saved[$1]![0] }
        func lerp(_ y: Double, _ a: Double, _ b: Double, _ a2: Double, _ b2: Double) -> Double {
            b - a > 0.5 ? a2 + (y - a) / (b - a) * (b2 - a2) : a2 + (y - a)
        }
        return { y in
            guard let first = old.first else { return y }
            let o0 = saved[first]!, n0 = current[first]!
            // 第一块上面（标题旁边）
            if y < o0[0] { return index[first] == 0 ? lerp(y, 0, o0[0], 0, n0[0]) : y }
            for (i, id) in old.enumerated() {
                let o = saved[id]!, n = current[id]!
                if y <= o[1] { return lerp(y, o[0], o[1], n[0], n[1]) }
                guard i + 1 < old.count else { return y + n[1] - o[1] }
                let next = old[i + 1]
                let on = saved[next]!, nn = current[next]!
                if y < on[0] {
                    // 两块现在还挨着：按比例放到两块之间；中间插进了别的块（或挪开了）：跟着上面一块的下边
                    return index[next] == index[id]! + 1 ? lerp(y, o[1], on[0], n[1], nn[0]) : y + n[1] - o[1]
                }
            }
            return y
        }
    }

    /// 书写手势挂到页面内容最底下一层，画布本身不挡触摸
    func attach() {
        guard let canvas, let host else { return }
        if canvas.drawingGestureRecognizer.view !== host {
            host.addGestureRecognizer(canvas.drawingGestureRecognizer)
        }
        // 页面滚动时跟着挪
        var view = host.superview
        while let v = view, !(v is UIScrollView) { view = v.superview }
        if let scroll = view as? UIScrollView, scroll !== observedScroll {
            observedScroll = scroll
            observation = scroll.observe(\.contentOffset) { [weak self] _, _ in self?.sync() }
        }
    }

    /// 让画布显示页面内容的这一块：(textLeft + x * scale, y * scale) 是纸上 (x, y) 在页面内容里的位置
    func sync() {
        guard let canvas, let host, let container = canvas.superview,
              host.window != nil, canvas.window != nil, scale > 0 else { return }
        if abs(canvas.zoomScale - scale) > 0.0001 {
            canvas.minimumZoomScale = min(canvas.minimumZoomScale, scale)
            canvas.maximumZoomScale = max(canvas.maximumZoomScale, scale)
            canvas.zoomScale = scale
            // 缩放变了 PencilKit 不一定重画：放回一次笔迹逼它重画。
            // 收起、拉出左栏时缩放跟着动画一帧一帧变，每帧都重画（还要拍截图垫着）会让滑动卡顿：等缩放停下来再重画一次
            pendingRefresh?.cancel()
            let work = DispatchWorkItem { [weak canvas] in canvas?.refreshRendering() }
            pendingRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        // 页面内容的原点在画布上的位置
        let origin = container.convert(CGPoint.zero, from: host)
        let dx = origin.x - canvas.frame.minX
        let dy = origin.y - canvas.frame.minY
        let size = CGSize(width: (Self.leftMargin * 2 + paper) * scale, height: max(host.bounds.height, canvas.bounds.height))
        if canvas.contentSize != size { canvas.contentSize = size }
        let offset = CGPoint(x: Self.leftMargin * scale - textLeft - dx, y: -dy)
        if canvas.contentOffset != offset { canvas.contentOffset = offset }
    }
}

/// 页面内容最底下的一层，整页涂鸦的书写手势挂在这里：只收到落在空白处的触摸
final class PageInkHostView: UIView {
    var layout: PageInkLayout?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        layout?.attach()
        layout?.sync()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        layout?.sync()
    }
}

struct PageInkHost: UIViewRepresentable {
    let layout: PageInkLayout

    func makeUIView(context: Context) -> PageInkHostView {
        let view = PageInkHostView()
        view.backgroundColor = .clear
        view.layout = layout
        layout.host = view
        layout.attach()
        return view
    }

    func updateUIView(_ uiView: PageInkHostView, context: Context) {
        uiView.layout = layout
        layout.host = uiView
        layout.attach()
        layout.sync()
    }
}

/// 整页涂鸦的画布外面包一层：画布大小跟着它，排版变了重新对位置
final class PageInkContainer: UIView {
    var layout: PageInkLayout?
    override func layoutSubviews() {
        super.layoutSubviews()
        layout?.sync()
    }
}

/// 整页涂鸦的画布：盖在笔记页看得见的那一块上，不接收触摸
struct PageInkCanvas: UIViewRepresentable {
    @ObservedObject var model: HandwritingModel
    @ObservedObject var tools: InkTools
    let layout: PageInkLayout
    let textLeft: CGFloat
    let scale: CGFloat
    let paper: CGFloat

    func makeUIView(context: Context) -> PageInkContainer {
        let container = PageInkContainer()
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        container.clipsToBounds = true
        let canvas = PadCanvasView()
        canvas.frame = container.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.minimumZoomScale = 0.25
        canvas.maximumZoomScale = 4
        canvas.isUserInteractionEnabled = false
        canvas.delegate = context.coordinator
        canvas.drawingGestureRecognizer.addTarget(context.coordinator,
                                                  action: #selector(NotebookCanvas.Coordinator.drawingGesture(_:)))
        container.addSubview(canvas)
        container.layout = layout
        layout.canvas = canvas
        update(canvas)
        model.attach(canvas)
        layout.attach()
        return container
    }

    func updateUIView(_ uiView: PageInkContainer, context: Context) {
        guard let canvas = layout.canvas else { return }
        update(canvas)
        if model.canvas !== canvas { model.attach(canvas) } else { model.applyTools() }
        layout.attach()
        layout.sync()
    }

    private func update(_ canvas: PadCanvasView) {
        layout.textLeft = textLeft
        layout.scale = scale
        layout.paper = paper
    }

    func makeCoordinator() -> NotebookCanvas.Coordinator { NotebookCanvas.Coordinator(model: model) }
}

/// 浮在页面底部的工具栏（仿 Notability）：大按钮，可以收起成一个小胶囊；
/// 再点一次已选中的工具（或点右边的调节按钮），上方展开这个工具的参数
struct InkPalette: View {
    @ObservedObject var tools: InkTools
    /// 套索工具的名字：做题、笔记页上它只用来挪笔迹，叫“移动”，免得和“圈出来问”分不清；
    /// 白板上框住的笔迹还能发给 AI 检查，仍叫“框选”
    var lassoTitle: String = L("移动")
    /// 一直展开：不能收起，写字时也不缩小（白板）
    var alwaysOpen = false
    /// 手动收起（记住）；shrunk 是开始书写时自动缩小（临时的，下次打开还是展开）
    @AppStorage("inkPaletteCollapsed") private var collapsed = false
    @State private var shrunk = false

    private var isSmall: Bool { !alwaysOpen && (collapsed || shrunk) }

    var body: some View {
        VStack(spacing: 8) {
            if tools.isTemporaryEraser {
                Text("正在用橡皮擦 · 松开笔身侧边恢复书写")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
            if tools.optionsShown && !isSmall {
                InkOptionsPanel(tools: tools)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if isSmall {
                collapsedBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                // 贴在页面最下沿的一整条；页面窄（侧栏打开、分屏）时去掉文字、按钮小一点
                ViewThatFits(in: .horizontal) {
                    fullBar(labels: true)
                    fullBar(labels: false)
                }
                .padding(.top, 6).padding(.bottom, 2)
                .frame(maxWidth: .infinity)
                .background {
                    Rectangle().fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.06), radius: 6, y: -2)
                        .ignoresSafeArea(edges: .bottom)
                }
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: tools.optionsShown)
        .animation(.spring(duration: 0.25), value: isSmall)
        // 开始书写：缩成底边的小标签，把纸面让出来；点一下再展开
        .onReceive(tools.writingBegan) {
            guard !isSmall else { return }
            if tools.optionsShown { tools.optionsShown = false }
            if !alwaysOpen { shrunk = true }
        }
        // 换工具时，参数面板跟着换；选了没有参数的工具就收起来
        .onChange(of: tools.tool) {
            if tools.tool == .lasso { tools.optionsShown = false }
        }
        // 换到别的页面，面板不跟过去
        .onDisappear { tools.optionsShown = false }
    }

    /// 收起：贴在底边中间的小标签，所有功能都在上面（只有图标）。点工具直接换（不展开）；
    /// 再点已选中的工具或调节按钮，展开并打开它的参数；点向上箭头展开
    private var collapsedBar: some View {
        let tab = UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
        let row = HStack(spacing: 2) {
            compactPen(0)
            compactPen(1)
            compactTool(.marker, title: L("荧光笔"))
            compactTool(.eraser, title: L("橡皮"))
            compactTool(.lasso, title: lassoTitle)
            compactTool(.ask, title: L("圈出来问"))
            Divider().frame(height: 24).padding(.horizontal, 4)
            compactIcon("arrow.uturn.backward", L("撤销")) { tools.undo() }
            compactIcon("arrow.uturn.forward", L("重做")) { tools.redo() }
            compactIcon("slider.horizontal.3", L("调节")) { expand(options: true) }
            compactIcon("chevron.up", L("展开工具栏")) { expand(options: false) }
        }
        .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 2)
        // 页面太窄放不下时可以左右滑
        return ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .background {
            tab.fill(.regularMaterial)
                .shadow(color: .black.opacity(0.1), radius: 6, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func expand(options: Bool) {
        collapsed = false
        shrunk = false
        tools.optionsShown = options && tools.tool != .lasso
    }

    private func compactPen(_ slot: Int) -> some View {
        compactTool(.pen, title: penTitle(slot), selected: tools.tool == .pen && tools.penSlot == slot,
                    color: tools.penSlotColors[slot]) { tools.selectPen(slot) }
    }

    private func compactTool(_ tool: InkTools.Tool, title: String) -> some View {
        compactTool(tool, title: title, selected: tools.tool == tool,
                    color: tool == .marker ? tools.markerColor : nil) { tools.select(tool) }
    }

    /// 收起的小标签上的一个工具：图标 + 颜色圆点，选中的有底色
    private func compactTool(_ tool: InkTools.Tool, title: String, selected: Bool,
                             color: String?, choose: @escaping () -> Void) -> some View {
        Button {
            if selected && tool != .lasso { expand(options: true) } else { choose() }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon(tool)).font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                if let color {
                    Circle().fill(Color(UIColor(hex: color)))
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1))
                        .offset(x: 3, y: 2)
                }
            }
            .frame(width: 38, height: 34)
            .background(selected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func compactIcon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.body.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func penTitle(_ slot: Int) -> String { slot == 0 ? L("笔 1") : L("笔 2") }

    private func fullBar(labels: Bool) -> some View {
        HStack(spacing: labels ? 6 : 2) {
            penButton(0, label: labels)
            penButton(1, label: labels)
            toolButton(.marker, title: L("荧光笔"), label: labels)
            toolButton(.eraser, title: L("橡皮"), label: labels)
            toolButton(.lasso, title: lassoTitle, label: labels)
            toolButton(.ask, title: L("圈出来问"), label: labels)

            Divider().frame(height: 30).padding(.horizontal, labels ? 4 : 2)

            iconButton("arrow.uturn.backward", L("撤销")) { tools.undo() }
            iconButton("arrow.uturn.forward", L("重做")) { tools.redo() }
            iconButton(tools.optionsShown ? "slider.horizontal.below.square.filled.and.square" : "slider.horizontal.3", L("调节")) {
                tools.optionsShown.toggle()
            }
            if !alwaysOpen {
                iconButton("chevron.down", L("收起工具栏")) {
                    tools.optionsShown = false
                    collapsed = true
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, labels ? 12 : 8)
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

    /// 两支笔各一个按钮；再点一次正在用的这支：展开或收起它的参数
    private func penButton(_ slot: Int, label: Bool) -> some View {
        toolButton(.pen, title: penTitle(slot), label: label,
                   selected: tools.tool == .pen && tools.penSlot == slot,
                   color: tools.penSlotColors[slot]) {
            tools.selectPen(slot)
        }
    }

    private func toolButton(_ tool: InkTools.Tool, title: String, label: Bool) -> some View {
        toolButton(tool, title: title, label: label, selected: tools.tool == tool,
                   color: tool == .marker ? tools.markerColor : nil) {
            tools.select(tool)
        }
    }

    private func toolButton(_ tool: InkTools.Tool, title: String, label: Bool, selected: Bool,
                            color: String?, choose: @escaping () -> Void) -> some View {
        Button {
            // 再点一次已选中的工具：展开或收起它的参数
            if selected && tool != .lasso {
                tools.optionsShown.toggle()
            } else {
                choose()
            }
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: icon(tool))
                        .font(.title2)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    if let color {
                        // 小圆点是这支笔的颜色
                        Circle()
                            .fill(Color(UIColor(hex: color)))
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

/// 参数面板开着时盖在页面上（工具栏下面）的透明层：笔或手指点一下别处就关掉面板，
/// 这一下被这层接住，不会在纸上写出一点
struct InkOptionsDismissLayer: View {
    @ObservedObject var tools: InkTools

    var body: some View {
        if tools.optionsShown {
            Color.clear
                .contentShape(Rectangle())
                // 一碰到就关，不等抬起；这一笔剩下的部分也还是这层的，不会传到画布上
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                    if tools.optionsShown { tools.optionsShown = false }
                })
                .accessibilityHidden(true)
        }
    }
}

/// 当前工具的参数：笔（颜色、笔型、粗细、压力灵敏度、笔尖扁平度、稳定性），荧光笔（颜色、粗细、不透明度），橡皮（方式、大小）
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
            slider(L("笔尖粗细"), $tools.penWidth, InkTools.penWidthRange, String(format: "%.1f", tools.penWidth))
            slider(L("压力灵敏度"), $tools.penPressure, 0...1, percent(tools.penPressure))
            slider(L("笔尖扁平度"), $tools.penFlatness, 0...1, percent(tools.penFlatness))
            slider(L("画笔稳定性"), $tools.penStability, 0...1, percent(tools.penStability))
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
            slider(L("粗细"), $tools.markerWidth, InkTools.markerWidthRange, "\(Int(tools.markerWidth.rounded()))")
            slider(L("不透明度"), $tools.markerOpacity, InkTools.markerOpacityRange, percent(tools.markerOpacity))
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
                slider(L("大小"), $tools.eraserWidth, InkTools.eraserWidthRange, "\(Int(tools.eraserWidth.rounded()))")
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
    var pencilOnly = false
    var strokeCount: Int { 0 }
    var onDrawingChanged: (() -> Void)?
    init(questionID: UUID?, tools: InkTools) { self.tools = tools }
    func clear() {}
    func saveNow() {}
    @Published var circledRegion: CGRect?
    @Published var askRegionVisible = false
    var onEraserTouch: ((CGPoint) -> Void)?
    func addSpace() {}
    func redrawSoon() {}
    func inkSpan(inRow row: Int) -> ClosedRange<CGFloat>? { nil }
    func exportJPEG(highlight: CGRect? = nil) -> Data? { nil }
    func shiftStrokes(below y: CGFloat, by dy: CGFloat) {}
}

extension DrawingStore {
    static func shiftStrokes(_ id: UUID, below y: CGFloat, by dy: CGFloat) {}
}

final class InkHost {}

struct NotebookCanvas: View {
    @ObservedObject var model: HandwritingModel
    @ObservedObject var tools: InkTools
    var host: InkHost?
    var overflow: CGFloat = 0
    var body: some View { Color.clear }
}

struct InkPalette: View {
    @ObservedObject var tools: InkTools
    var lassoTitle: String = ""
    var alwaysOpen = false
    var body: some View { EmptyView() }
}

struct InkOptionsDismissLayer: View {
    @ObservedObject var tools: InkTools
    var body: some View { EmptyView() }
}

final class PageInkLayout {
    var blockFrames: [UUID: (frame: CGRect, scale: CGFloat)] = [:]
    func scheduleSettle(_ action: @escaping () -> Void) {}
    func settle(_ model: HandwritingModel, blocks: [UUID], saved: [String: [Double]]?) -> [String: [Double]]? { nil }
    func userChanged(_ model: HandwritingModel, blocks: [UUID]) -> [String: [Double]]? { nil }
}

struct PageInkHost: View {
    let layout: PageInkLayout
    var body: some View { Color.clear }
}

struct PageInkCanvas: View {
    @ObservedObject var model: HandwritingModel
    @ObservedObject var tools: InkTools
    let layout: PageInkLayout
    let textLeft: CGFloat
    let scale: CGFloat
    let paper: CGFloat
    var body: some View { Color.clear }
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
