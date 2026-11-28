import SwiftUI

// MARK: - 双击打字的地方，唤出屏幕键盘

/// 放在最外层的背景里：整个窗口里任何能打字的地方（输入框、多行输入、弹出页和提示框里的也算），
/// 双击就弹出屏幕键盘
struct KeyboardSummoner: View {
    var body: some View {
        #if os(iOS)
        KeyboardSummonerView().allowsHitTesting(false)
        #else
        Color.clear
        #endif
    }
}

#if os(iOS)
/// 刚用过 Apple Pencil 时，系统认为接下来要用笔写字（随手写）：输入框聚焦了也不弹屏幕键盘，只有光标在闪。
/// 这个 App 一直在用笔，所以几乎总是这样。
/// 双击输入框、或者点手写区下面的“键盘”，就是明确要屏幕键盘：用 UITextInputContext 告诉系统接下来不是用笔写字。
/// （接着硬件键盘时系统也不弹屏幕键盘，那个这里管不了：用系统快捷栏上的键盘按钮）
@MainActor
enum KeyboardSummon {
    /// 屏幕键盘现在开着（接硬件键盘时底边那条快捷栏、笔的小工具条不算）
    private(set) static var keyboardVisible = false
    /// 用户明确要了屏幕键盘的输入框：它还在输入时，笔再碰屏幕也不让键盘缩回去
    private static weak var wanted: UIView?
    /// 点了“键盘”按钮：马上要聚焦的那个输入框算作要了键盘的
    private static var adoptNextUntil = Date.distantPast
    /// 键盘被系统收回去以后又要回来的次数（连着要不回来就不再要，免得来回闪）
    private static var rescues = 0
    /// 最近开始输入的输入框和时间：双击的第一下让它聚焦，第二下到的时候页面可能已经被键盘顶着挪了位置
    private static weak var lastBegan: UIView?
    private static var lastBeganAt = Date.distantPast
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { note in
            let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated {
                guard let frame else { return }
                keyboardVisible = frame.minY < UIScreen.main.bounds.maxY && frame.height > 150
            }
        }
        center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                keyboardVisible = false
                keyboardWentAway()
            }
        }
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let input = note.object as? UIView
                MainActor.assumeIsolated {
                    guard let input else { return }
                    lastBegan = input
                    lastBeganAt = Date()
                    guard Date() < adoptNextUntil else { return }
                    adoptNextUntil = .distantPast
                    summon(input)
                }
            }
        }
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let input = note.object as? UIView
                MainActor.assumeIsolated {
                    if let input, input === wanted { wanted = nil }
                }
            }
        }
    }

    /// 告诉系统：接下来用屏幕键盘打字，不是用笔写
    private static func expectKeyboard() {
        UITextInputContext.current()?.isPencilInputExpected = false
    }

    /// 让这个输入框弹出屏幕键盘
    static func summon(_ input: UIView) {
        start()
        rescues = 0
        expectKeyboard()
        if !input.isFirstResponder {
            input.becomeFirstResponder()
        } else if !keyboardVisible {
            // 这次输入是用笔点开的，系统一直记着“这个输入框在用笔写”：光改回来不够，
            // 结束这次输入、马上重新开始一次（两步紧挨着，界面还没来得及当成“不输入了”）
            input.resignFirstResponder()
            expectKeyboard()
            input.becomeFirstResponder()
        }
        wanted = input
        ensure(input)
    }

    /// 接下来马上要聚焦一个输入框（点“键盘”按钮）：等它开始输入就弹出屏幕键盘
    static func summonNextFocus(within seconds: TimeInterval = 1.5) {
        start()
        expectKeyboard()
        adoptNextUntil = Date().addingTimeInterval(seconds)
    }

    /// 正在输入、屏幕键盘却被笔压着没出来：把键盘要出来。
    /// 不是这种情况（键盘开着、接着硬件键盘、已经要过一次还是没出来）返回 false
    static func summonCurrentIfHeldBack() -> Bool {
        guard !keyboardVisible, UIScribbleInteraction.isPencilInputExpected,
              let input = UIResponder.currentTextInput, input !== wanted else { return false }
        summon(input)
        return true
    }

    /// 笔的这一下系统可能晚一点才记成“在用笔”，键盘刚要出来又被压回去：过一会儿还没出来就再要一次
    private static func ensure(_ input: UIView, tries: Int = 2) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak input] in
            guard let input, input === wanted, input.isFirstResponder, !keyboardVisible else { return }
            expectKeyboard()
            input.reloadInputViews()
            if tries > 1 { ensure(input, tries: tries - 1) }
        }
    }

    /// 笔落在手写的地方开始写字了：不再替之前的输入框要键盘，写字的时候不动输入框和键盘
    static func writingBegan() {
        wanted = nil
        adoptNextUntil = .distantPast
    }

    /// 笔碰了一下屏幕（点别的按钮、挪光标）：要了键盘的输入框还在输入，就别让键盘缩回去
    fileprivate static func pencilTouched() {
        guard let input = wanted, input.isFirstResponder else { return }
        expectKeyboard()
        ensure(input, tries: 1)
    }

    /// 键盘收起来了，要了键盘的输入框却还在输入：是用笔尖点键盘以后被系统收回去的（自己收键盘时输入框也跟着结束输入），再要回来
    private static func keyboardWentAway() {
        guard let input = wanted, input.isFirstResponder,
              UIScribbleInteraction.isPencilInputExpected, rescues < 3 else { return }
        rescues += 1
        expectKeyboard()
        ensure(input, tries: 1)
    }

    /// 窗口里这个位置被双击了：双击的是正在输入的输入框（第一下已经让它聚焦），屏幕键盘却没出来，就把键盘要出来。
    /// 等一拍再看：第二下落下时聚焦和键盘还在半路上，这时去动输入框会把刚拿到的焦点弄丢。
    /// 不用 hitTest 找输入框：SwiftUI 的输入框聚焦以后才有真正的输入视图
    fileprivate static func doubleTapped(at point: CGPoint, in window: UIWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak window] in
            guard let window, let input = UIResponder.currentTextInput else { return }
            let frame = input.convert(input.bounds, to: window).insetBy(dx: -14, dy: -14)
            let justFocused = input === lastBegan && Date().timeIntervalSince(lastBeganAt) < 1.2
            guard frame.contains(point) || justFocused else { return }
            summon(input)
        }
    }
}

extension UIResponder {
    private static weak var found: UIResponder?

    /// 现在正在输入的输入框
    static var currentTextInput: UIView? {
        found = nil
        UIApplication.shared.sendAction(#selector(reportAsFirstResponder(_:)), to: nil, from: nil, for: nil)
        guard let view = found as? UIView, view is UITextField || view is UITextView else { return nil }
        return view
    }

    @objc func reportAsFirstResponder(_ sender: Any?) { UIResponder.found = self }
}

private struct KeyboardSummonerView: UIViewRepresentable {
    func makeUIView(context: Context) -> Host {
        let view = Host()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: Host, context: Context) {}

    /// 放进窗口后，把双击手势挂到整个窗口上
    final class Host: UIView {
        private var tap: SummonTap?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, tap == nil else { return }
            KeyboardSummon.start()
            // 系统键盘出不来时，App 自己的输入面板顶上（见 InputPanel.swift）
            InputPanelController.shared.start()
            let tap = SummonTap(target: self, action: #selector(doubleTapped(_:)))
            window.addGestureRecognizer(tap)
            self.tap = tap
        }

        @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
            guard tap.state == .ended, let window = tap.view as? UIWindow else { return }
            KeyboardSummon.doubleTapped(at: tap.location(in: window), in: window)
        }
    }
}

/// 只看不拦的双击：不取消、不推迟别人的触摸，也不挡别的手势（输入框自己的双击选词、书写、白板的双击照常）
private final class SummonTap: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        numberOfTapsRequired = 2
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// 落在手写的地方的笔和手指一概不看：写字的每一笔都和这个手势无关
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !InkSurfaces.contains(touch.view)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if touches.contains(where: { $0.type == .pencil }) {
            DispatchQueue.main.async { KeyboardSummon.pencilTouched() }
        }
    }
}
#else
/// 没有屏幕键盘的平台（命令行检查代码用）
enum KeyboardSummon {
    static func summonNextFocus() {}
    static func summonCurrentIfHeldBack() -> Bool { false }
    static func writingBegan() {}
}
#endif
