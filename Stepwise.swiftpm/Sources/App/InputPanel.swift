#if os(iOS)
import UIKit
import PencilKit
import Vision
import GameController

// MARK: - App 自带的输入面板
//
// 有的 iPad 上系统的屏幕键盘出不来（iPadOS 27.2 在 Swift Playgrounds 里运行的 App：输入框有光标，键盘不出现；
// 刚用过 Apple Pencil 时系统也只给一条小工具条）。App 叫不出系统键盘，就自己给一个：
// 输入框聚焦了、系统键盘过一会儿还没出来（也没接实体键盘），在窗口里浮出这块面板。
// - 手写：用笔或手指写，停笔后在本机认成文字（中文、英文、数字都行），不联网
// - 字母、数字、符号：一排排的按键
// - 空格、删除、换行、左右挪光标、粘贴
// 面板是窗口里普通的一块视图，不走系统的键盘通道，所以系统键盘出不来时它照样能用；
// 打出来的字直接交给正在输入的那个输入框

@MainActor
final class InputPanelController: NSObject {
    static let shared = InputPanelController()

    private var panel: InputPanelView?
    /// 正在输入的输入框
    private weak var target: UIView?
    /// 用户点了“收起”的那个输入框：它还聚焦着就不再弹出来，换一个输入框再说
    private weak var dismissedFor: UIView?
    private var systemKeyboardVisible = false
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let input = note.object as? UIView
                MainActor.assumeIsolated { self?.began(input) }
            }
        }
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended() }
            }
        }
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated {
                guard let self, let frame else { return }
                self.systemKeyboardVisible = frame.minY < UIScreen.main.bounds.maxY && frame.height > 150
                if self.systemKeyboardVisible { self.hide() } else { self.checkSoon() }
            }
        }
        center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.systemKeyboardVisible = false
                self?.checkSoon()
            }
        }
    }

    private func began(_ input: UIView?) {
        guard let input else { return }
        #if targetEnvironment(simulator)
        // 模拟器里系统键盘总能出来：测试时用一块空的输入视图顶掉它，和“输入框有光标、键盘不出现”一样
        if UserDefaults.standard.bool(forKey: "inputPanelTestNoSystemKeyboard") {
            let empty = UIView(frame: .zero)
            if let field = input as? UITextField, field.inputView == nil { field.inputView = empty; field.reloadInputViews() }
            if let text = input as? UITextView, text.inputView == nil { text.inputView = empty; text.reloadInputViews() }
        }
        #endif
        target = input
        if dismissedFor !== input { dismissedFor = nil }
        checkSoon()
    }

    private func ended() {
        // 焦点可能只是换到另一个输入框：等一下再看
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if let current = UIResponder.currentTextInput {
                self.target = current
                self.reposition()
            } else {
                self.target = nil
                self.hide()
            }
        }
    }

    /// 系统键盘通常一聚焦就通知要出来；过一会儿还没有，就出自己的面板
    private func checkSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showIfNeeded() }
    }

    private func showIfNeeded() {
        guard let input = target, input.isFirstResponder, let window = input.window,
              !systemKeyboardVisible, dismissedFor !== input,
              // 接着实体键盘：系统本来就不显示屏幕键盘，直接用实体键盘打
              GCKeyboard.coalesced == nil else { return }
        let panel = self.panel ?? InputPanelView(controller: self)
        self.panel = panel
        if panel.superview !== window {
            panel.removeFromSuperview()
            window.addSubview(panel)
        }
        window.bringSubviewToFront(panel)
        panel.isHidden = false
        reposition()
    }

    /// 面板放在底边；正在输入的输入框在那里会被挡住，就放到顶上
    private func reposition() {
        guard let panel, let window = panel.window, !panel.isHidden else { return }
        let safe = window.safeAreaInsets
        let width = min(window.bounds.width - 16, 780)
        let height = InputPanelView.height
        let x = (window.bounds.width - width) / 2
        let bottom = CGRect(x: x, y: window.bounds.height - height - max(safe.bottom, 8), width: width, height: height)
        let top = CGRect(x: x, y: max(safe.top, 8) + 4, width: width, height: height)
        var frame = bottom
        if let input = target {
            let field = input.convert(input.bounds, to: window).insetBy(dx: 0, dy: -10)
            if field.intersects(bottom) && !field.intersects(top) { frame = top }
        }
        if panel.movedByUser, panel.frame.width == width { return }
        panel.frame = frame
        panel.autoresizingMask = frame == top
            ? [.flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
            : [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin]
    }

    func hide() {
        panel?.isHidden = true
        panel?.movedByUser = false
    }

    /// 面板上的“收起”：收起面板，这次输入也结束
    func dismiss() {
        dismissedFor = target
        hide()
        target?.resignFirstResponder()
    }

    // MARK: 往输入框里打字

    private var input: UIView? {
        if let target, target.isFirstResponder { return target }
        return UIResponder.currentTextInput
    }

    func insert(_ text: String) {
        guard !text.isEmpty, let input else { return }
        if text == "\n", let field = input as? UITextField {
            // 单行输入框的换行就是“完成”
            if field.delegate?.textFieldShouldReturn?(field) ?? true { field.sendActions(for: .editingDidEndOnExit) }
            return
        }
        (input as? UIKeyInput)?.insertText(text)
    }

    func deleteBackward() {
        (input as? UIKeyInput)?.deleteBackward()
    }

    func moveCursor(by offset: Int) {
        guard let input = input as? UITextInput, let range = input.selectedTextRange,
              let position = input.position(from: offset < 0 ? range.start : range.end, offset: offset) else { return }
        input.selectedTextRange = input.textRange(from: position, to: position)
    }

    func paste() {
        guard let text = UIPasteboard.general.string else { return }
        insert(text)
    }
}

// MARK: - 面板

final class InputPanelView: UIView, PKCanvasViewDelegate {
    static let height: CGFloat = 262

    private weak var controller: InputPanelController?
    /// 用户拖过面板：之后不再自动挪位置
    var movedByUser = false

    private enum Mode: Int, CaseIterable {
        case write, letters, numbers, symbols
        var title: String {
            switch self {
            case .write: return L("手写")
            case .letters: return "ABC"
            case .numbers: return "123"
            case .symbols: return L("符号")
            }
        }
    }

    private let modePicker = UISegmentedControl(items: Mode.allCases.map(\.title))
    private let content = UIView()
    private let canvas = PanelCanvas()
    private let hint = UILabel()
    /// 认不出来时的一行小字（在手写板左下角，不盖住写的字）
    private let status = UILabel()
    private var keyPages: [Mode: UIView] = [:]
    private var uppercase = false
    private var letterButtons: [UIButton] = []
    private var recognizeWork: DispatchWorkItem?
    private var isWriting = false
    private var repeatTimer: Timer?

    init(controller: InputPanelController) {
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: Self.height))
        build()
        HandwritingReader.warmUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 4)

        // 顶上一条：拖动的把手、切换、收起
        let grip = UIImageView(image: UIImage(systemName: "line.3.horizontal"))
        grip.tintColor = .tertiaryLabel
        grip.contentMode = .center
        grip.isUserInteractionEnabled = true
        grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        grip.widthAnchor.constraint(equalToConstant: 44).isActive = true
        grip.accessibilityLabel = L("拖动输入面板")

        modePicker.selectedSegmentIndex = 0
        modePicker.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        close.accessibilityLabel = L("收起输入面板")
        close.addAction(UIAction { [weak self] _ in self?.controller?.dismiss() }, for: .touchUpInside)
        close.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let header = UIStackView(arrangedSubviews: [grip, modePicker, close])
        header.spacing = 8
        header.alignment = .center

        // 最下面一条：挪光标、粘贴、空格、删除、换行
        let left = key(image: "arrow.left", label: L("光标左移")) { [weak self] in self?.controller?.moveCursor(by: -1) }
        let right = key(image: "arrow.right", label: L("光标右移")) { [weak self] in self?.controller?.moveCursor(by: 1) }
        let paste = key(title: L("粘贴")) { [weak self] in self?.controller?.paste() }
        let space = key(title: L("空格")) { [weak self] in self?.controller?.insert(" ") }
        let delete = key(image: "delete.left", label: L("删除")) { [weak self] in self?.controller?.deleteBackward() }
        delete.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        delete.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let enter = key(image: "return", label: L("换行")) { [weak self] in self?.controller?.insert("\n") }
        let controls = UIStackView(arrangedSubviews: [left, right, paste, space, delete, enter])
        controls.spacing = 6
        controls.distribution = .fill
        for narrow in [left, right, delete, enter] { narrow.widthAnchor.constraint(equalToConstant: 58).isActive = true }
        paste.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let stack = UIStackView(arrangedSubviews: [header, content, controls])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            header.heightAnchor.constraint(equalToConstant: 34),
            controls.heightAnchor.constraint(equalToConstant: 42)
        ])

        buildWriting()
        keyPages[.letters] = keyGrid(rows: ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }, letters: true)
        keyPages[.numbers] = keyGrid(rows: [
            "1234567890".map(String.init),
            ["+", "-", "×", "÷", "=", "<", ">", "(", ")", "."],
            [",", "/", "^", "_", "$", "\\", "{", "}", "[", "]"]
        ])
        keyPages[.symbols] = keyGrid(rows: [
            ["，", "。", "？", "！", "：", "；", "、", "（", "）", "…"],
            ["“", "”", "《", "》", "√", "π", "≤", "≥", "≠", "≈"],
            ["°", "%", "∠", "△", "∞", "±", "·", "|", "&", "@"]
        ])
        show(.write)
    }

    // MARK: 手写

    private func buildWriting() {
        canvas.delegate = self
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvas.backgroundColor = .white
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.layer.cornerRadius = 12
        canvas.layer.cornerCurve = .continuous
        canvas.clipsToBounds = true

        hint.text = L("在这里写字（中文、英文、数字都行），停笔后自动变成文字")
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = UIColor(white: 0.55, alpha: 1)
        hint.textAlignment = .center
        hint.numberOfLines = 2
        hint.isUserInteractionEnabled = false

        status.font = .preferredFont(forTextStyle: .caption1)
        status.textColor = UIColor(red: 0.75, green: 0.3, blue: 0.2, alpha: 1)
        status.isUserInteractionEnabled = false
        status.isHidden = true
    }

    private func setHint(_ text: String?) {
        hint.text = text
        hint.isHidden = text == nil
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        isWriting = true
        recognizeWork?.cancel()
        setHint(nil)
        status.isHidden = true
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        isWriting = false
        scheduleRecognition()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if !isWriting { scheduleRecognition() }
    }

    /// 停笔一会儿就认：认出来的字交给输入框，认过的笔画从板上拿掉（认的时候又写的留着）
    private func scheduleRecognition() {
        recognizeWork?.cancel()
        guard !canvas.drawing.strokes.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.recognize() }
        recognizeWork = work
        var delay = 1.0
        #if targetEnvironment(simulator)
        // 模拟器里一笔一笔是工具画的，两笔之间隔得久：测试时把等的时间放长
        let testDelay = UserDefaults.standard.double(forKey: "inputPanelTestDelay")
        if testDelay > 0 { delay = testDelay }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func recognize() {
        guard !isWriting else { return }
        let drawing = canvas.drawing
        let count = drawing.strokes.count
        guard count > 0 else { return }
        HandwritingReader.read(drawing) { [weak self] text in
            guard let self else { return }
            // 认的这会儿又落笔了：等这一笔写完连着一起认
            guard !self.isWriting, self.canvas.drawing.strokes.count == count else { return }
            if text.isEmpty {
                self.status.text = L("没认出来：接着写清楚一点，或者点右上角清掉重写")
                self.status.isHidden = false
                return
            }
            self.controller?.insert(text)
            self.canvas.drawing = PKDrawing()
            self.status.isHidden = true
            self.setHint(nil)
        }
    }

    // MARK: 按键

    private func key(title: String? = nil, image: String? = nil, label: String? = nil, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = .tertiarySystemBackground
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        if let title {
            var text = AttributedString(title)
            text.font = .systemFont(ofSize: 19)
            config.attributedTitle = text
        }
        if let image { config.image = UIImage(systemName: image) }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label ?? title
        return button
    }

    private func keyGrid(rows: [[String]], letters: Bool = false) -> UIView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 6
        grid.distribution = .fillEqually
        for (index, row) in rows.enumerated() {
            let line = UIStackView()
            line.spacing = 6
            line.distribution = .fillEqually
            if letters, index == rows.count - 1 {
                let shift = key(image: "shift", label: L("大写")) { [weak self] in self?.toggleUppercase() }
                line.addArrangedSubview(shift)
            }
            for symbol in row {
                let button = key(title: symbol) { [weak self] in
                    guard let self else { return }
                    self.controller?.insert(letters && self.uppercase ? symbol.uppercased() : symbol)
                }
                if letters { letterButtons.append(button) }
                line.addArrangedSubview(button)
            }
            grid.addArrangedSubview(line)
        }
        return grid
    }

    private func toggleUppercase() {
        uppercase.toggle()
        for button in letterButtons {
            guard let title = button.accessibilityLabel else { continue }
            var text = AttributedString(uppercase ? title.uppercased() : title.lowercased())
            text.font = .systemFont(ofSize: 19)
            button.configuration?.attributedTitle = text
            button.accessibilityLabel = uppercase ? title.uppercased() : title.lowercased()
        }
    }

    @objc private func deleteDown() {
        repeatTimer?.invalidate()
        // 按住不放连着删
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.controller?.deleteBackward() }
                }
            }
        }
    }

    @objc private func deleteUp() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: 切换、拖动

    @objc private func modeChanged() {
        show(Mode(rawValue: modePicker.selectedSegmentIndex) ?? .write)
    }

    private func show(_ mode: Mode) {
        content.subviews.forEach { $0.removeFromSuperview() }
        let pages: [UIView]
        if mode == .write {
            let clear = UIButton(type: .system)
            clear.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            clear.tintColor = UIColor(white: 0.7, alpha: 1)
            clear.accessibilityLabel = L("清掉重写")
            clear.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.recognizeWork?.cancel()
                self.canvas.drawing = PKDrawing()
                self.status.isHidden = true
                self.setHint(L("在这里写字（中文、英文、数字都行），停笔后自动变成文字"))
            }, for: .touchUpInside)
            pages = [canvas, hint, status, clear]
            for view in pages {
                view.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(view)
            }
            NSLayoutConstraint.activate([
                canvas.topAnchor.constraint(equalTo: content.topAnchor),
                canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                hint.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                hint.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                hint.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 44),
                status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
                status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
                clear.topAnchor.constraint(equalTo: content.topAnchor, constant: 2),
                clear.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
                clear.widthAnchor.constraint(equalToConstant: 40),
                clear.heightAnchor.constraint(equalToConstant: 40)
            ])
        } else if let page = keyPages[mode] {
            page.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(page)
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: content.topAnchor),
                page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ])
        }
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let window else { return }
        let move = pan.translation(in: window)
        pan.setTranslation(.zero, in: window)
        var next = frame.offsetBy(dx: move.x, dy: move.y)
        let bounds = window.bounds.inset(by: window.safeAreaInsets)
        next.origin.x = min(max(next.minX, bounds.minX), max(bounds.maxX - next.width, bounds.minX))
        next.origin.y = min(max(next.minY, bounds.minY), max(bounds.maxY - next.height, bounds.minY))
        frame = next
        movedByUser = true
        autoresizingMask = []
    }
}

/// 面板上的手写板：不抢焦点（正在输入的输入框要一直聚焦着），也不让“随手写”把笔画拿走
final class PanelCanvas: PKCanvasView {
    override var canBecomeFirstResponder: Bool { false }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        blockScribbleInSubtree()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        hit?.blockScribble()
        return hit
    }
}

// MARK: - 认手写

/// 用系统自带的文字识别（Vision）在本机把手写认成文字：不联网，不用 AI 模型
enum HandwritingReader {
    private static let queue = DispatchQueue(label: "com.lswill2007.stepwise.handwriting-reader", qos: .userInitiated)

    private static var languages: [String] {
        UILanguage.isTraditional || AILanguage.isCantonese ? ["zh-Hant", "en-US"] : ["zh-Hans", "en-US"]
    }

    /// 垫在手写左边的印刷字。系统的文字识别是按“一行字”认的：只有一两个手写字时没有上下文，常常认错或者认不出来；
    /// 同一行里垫上几个印刷字就认得准了。认完把冒号和它前面的去掉
    private static let anchor = "以下文字："
    /// 每一行手写缩放到这么高（像素）再认
    private static let lineHeight: CGFloat = 72

    /// 第一次识别要先装载模型（一两秒）：面板一出来就先装好
    @MainActor
    static func warmUp() {
        guard let image = compose(nil) else { return }
        let languages = languages
        queue.async { _ = recognize(image, languages: languages) }
    }

    @MainActor
    static func read(_ drawing: PKDrawing, completion: @escaping @MainActor (String) -> Void) {
        let images = rows(of: drawing).compactMap { row -> CGImage? in
            let bounds = row.bounds.insetBy(dx: -6, dy: -6)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            // 按浅色画：深色模式下黑色的墨水会被画成白的
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = row.image(from: bounds, scale: 2)
            }
            return compose(ink)
        }
        guard !images.isEmpty else { completion(""); return }
        let languages = languages
        queue.async {
            let text = images.map { strip(recognize($0, languages: languages)) }.joined()
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// 把笔画分成一行一行（从上到下）。两行字之间有一条空白；
    /// 很扁的一组（“二”的两横、等号）不单独成行，并到挨着的那一行里
    @MainActor
    static func rows(of drawing: PKDrawing) -> [PKDrawing] {
        let strokes = drawing.strokes.sorted { $0.renderBounds.minY < $1.renderBounds.minY }
        var groups: [(strokes: [PKStroke], minY: CGFloat, maxY: CGFloat)] = []
        for stroke in strokes {
            let box = stroke.renderBounds
            if let last = groups.last, box.minY <= last.maxY + 4 {
                groups[groups.count - 1].strokes.append(stroke)
                groups[groups.count - 1].maxY = max(last.maxY, box.maxY)
            } else {
                groups.append(([stroke], box.minY, box.maxY))
            }
        }
        // 太扁的并到上一组（没有上一组就并到下一组）
        var merged: [(strokes: [PKStroke], minY: CGFloat, maxY: CGFloat)] = []
        for group in groups {
            let thin = group.maxY - group.minY < 26
            if let last = merged.last, thin || last.maxY - last.minY < 26 {
                merged[merged.count - 1].strokes += group.strokes
                merged[merged.count - 1].maxY = max(last.maxY, group.maxY)
            } else {
                merged.append(group)
            }
        }
        return merged.map { PKDrawing(strokes: $0.strokes) }
    }

    /// 一行手写和参照字拼成一张图：白底，参照字在左，手写在右，一样高。ink 为空时只有参照字
    @MainActor
    private static func compose(_ ink: UIImage?) -> CGImage? {
        let font = UIFont.systemFont(ofSize: lineHeight * 0.72)
        let label = NSAttributedString(string: anchor, attributes: [.font: font, .foregroundColor: UIColor.black])
        let labelSize = label.size()
        let pad: CGFloat = 28
        var inkWidth: CGFloat = 0
        if let ink, ink.size.height > 0 { inkWidth = ink.size.width * lineHeight / ink.size.height }
        let size = CGSize(width: pad + labelSize.width + 8 + inkWidth + pad, height: lineHeight + pad * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            label.draw(at: CGPoint(x: pad, y: pad + (lineHeight - labelSize.height) / 2))
            ink?.draw(in: CGRect(x: pad + labelSize.width + 8, y: pad, width: inkWidth, height: lineHeight))
        }
        return image.cgImage
    }

    private static func recognize(_ image: CGImage, languages: [String]) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        // 一张图里只有一行：从左到右接起来
        let pieces = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        return pieces.compactMap { $0.topCandidates(1).first?.string }.joined()
    }

    /// 去掉参照字，剩下的就是手写的内容；中文之间不留空格
    static func strip(_ text: String) -> String {
        var rest = Substring(text)
        if let colon = rest.firstIndex(where: { $0 == "：" || $0 == ":" }) {
            rest = rest[rest.index(after: colon)...]
        } else {
            // 冒号没认出来：把开头属于参照字的去掉
            let anchorCharacters = Set(anchor + "以下文字:")
            rest = rest.drop { anchorCharacters.contains($0) || $0 == " " }
        }
        let characters = Array(rest.trimmingCharacters(in: .whitespacesAndNewlines))
        var result = ""
        for (index, character) in characters.enumerated() {
            if character == " ", index > 0, index + 1 < characters.count,
               isCJK(characters[index - 1]) || isCJK(characters[index + 1]) { continue }
            result.append(character)
        }
        return result
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
}
#endif
