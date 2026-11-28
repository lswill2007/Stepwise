import SwiftUI

#if os(iOS)
import GameController

// MARK: - 键盘检查
//
// 有的 iPad 上（在 Swift Playgrounds 里运行时见过）点输入框没有光标、键盘也不出来，模拟器里复现不了。
// 这一页放两个最简单的输入框，把系统这时的状态原样列出来：输入框有没有拿到焦点、谁占着第一响应者、
// App 的窗口是不是主窗口、触摸落到了哪里、键盘有没有通知要出来。拷贝出来就能看出卡在哪一步

/// 设置里的入口
struct KeyboardCheckRow: View {
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("键盘检查")
                Text("点输入框键盘不出来时，打开这里看看卡在哪一步").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $shown) { KeyboardCheckView() }
    }
}

struct KeyboardCheckView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var report = ""
    @State private var copied = false
    @StateObject private var probe = KeyboardProbe()
    @FocusState private var swiftUIFocused: Bool
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("先用手指点一下下面两个输入框，再看最下面列出的状态。点“拷贝结果”可以把它发出去。")
                        .font(.callout).foregroundStyle(.secondary)

                    Text("① 系统原生输入框").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ProbeField(probe: probe)
                        .frame(height: 40)

                    Text("② 和 App 里一样的输入框").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("点这里试试", text: $text, axis: .vertical)
                        .focused($swiftUIFocused)
                        .padding(10)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 12) {
                        Button("让①聚焦") { probe.focus(makeKey: false) }
                        Button("先设为主窗口再聚焦") { probe.focus(makeKey: true) }
                        Button("收起") {
                            probe.field?.resignFirstResponder()
                            swiftUIFocused = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.callout)

                    Text(report)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    Button {
                        UIPasteboard.general.string = report
                        copied = true
                    } label: {
                        Label(copied ? L("已拷贝") : L("拷贝结果"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(18)
            }
            .navigationTitle("键盘检查")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .background(ProbeTouchSpy(probe: probe).allowsHitTesting(false))
            .onReceive(tick) { _ in
                let next = probe.report(swiftUIFocused: swiftUIFocused)
                if next != report {
                    report = next
                    copied = false
                }
            }
            .onAppear { report = probe.report(swiftUIFocused: swiftUIFocused) }
        }
    }
}

/// 收集状态。只读系统公开的信息，不改任何东西（两个按钮除外）
@MainActor
final class KeyboardProbe: ObservableObject {
    weak var field: UITextField?
    private var lastFocusCall = "—"
    private var lastTouch = "—"
    private var keyboardNote = "还没收到"
    private var keyboardCount = 0
    private var editingNote = "—"
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification,
                     UIResponder.keyboardWillChangeFrameNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
                let short = name.rawValue.replacingOccurrences(of: "UIKeyboard", with: "").replacingOccurrences(of: "Notification", with: "")
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.keyboardCount += 1
                    self.keyboardNote = "\(short) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
                }
            })
        }
        for (name, label) in [(UITextField.textDidBeginEditingNotification, "输入框开始输入"),
                              (UITextField.textDidEndEditingNotification, "输入框结束输入"),
                              (UITextView.textDidBeginEditingNotification, "多行输入开始输入"),
                              (UITextView.textDidEndEditingNotification, "多行输入结束输入")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.editingNote = label }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func focus(makeKey: Bool) {
        guard let field else { lastFocusCall = "输入框不在"; return }
        if makeKey { field.window?.makeKey() }
        let can = field.canBecomeFirstResponder
        let ok = field.becomeFirstResponder()
        lastFocusCall = "\(makeKey ? "设主窗口后 " : "")能聚焦=\(can) 结果=\(ok)"
    }

    func touched(_ touch: UITouch, in window: UIWindow?) {
        let kind: String
        switch touch.type {
        case .pencil: kind = "笔"
        case .direct: kind = "手指"
        default: kind = "其他"
        }
        let hit = touch.view.map { String(describing: type(of: $0)) } ?? "无"
        lastTouch = "\(kind) → \(hit)" + (touch.window === window ? "" : "（别的窗口）")
    }

    func report(swiftUIFocused: Bool) -> String {
        let device = UIDevice.current
        let window = field?.window
        let scene = window?.windowScene
        var lines: [String] = []
        lines.append("系统 \(device.systemName) \(device.systemVersion) · \(device.model)")
        let path = Bundle.main.bundlePath.split(separator: "/").suffix(3).joined(separator: "/")
        lines.append("运行位置 …/\(path)")
        lines.append("进程 \(ProcessInfo.processInfo.processName)")
        if let window {
            let state: String
            switch scene?.activationState {
            case .foregroundActive: state = "前台活跃"
            case .foregroundInactive: state = "前台不活跃"
            case .background: state = "后台"
            case .unattached: state = "未连接"
            default: state = "未知"
            }
            let windows = scene?.windows ?? []
            let key = windows.first(where: \.isKeyWindow).map { String(describing: type(of: $0)) } ?? "没有"
            lines.append("窗口 主窗口=\(window.isKeyWindow) 场景=\(state) 窗口数=\(windows.count) 现在的主窗口=\(key)")
            lines.append("窗口类型 \(String(describing: type(of: window))) 层级=\(window.windowLevel.rawValue)")
        } else {
            lines.append("窗口 输入框还没放进窗口")
        }
        lines.append("实体键盘 \(GCKeyboard.coalesced != nil ? "系统认为接着" : "没有")")
        if let context = UITextInputContext.current() {
            lines.append("系统预期 用笔=\(context.isPencilInputExpected) 实体键盘=\(context.isHardwareKeyboardInputExpected) 听写=\(context.isDictationInputExpected)")
        } else {
            lines.append("系统预期 读不到")
        }
        lines.append("第一响应者 \(UIResponder.currentFirstResponderName)")
        if let field {
            lines.append("①原生输入框 聚焦=\(field.isFirstResponder) 能聚焦=\(field.canBecomeFirstResponder) 可交互=\(field.isUserInteractionEnabled)")
        }
        lines.append("②App 输入框 聚焦=\(swiftUIFocused)")
        lines.append("最近的输入事件 \(editingNote)")
        lines.append("按钮聚焦 \(lastFocusCall)")
        lines.append("最近一次触摸 \(lastTouch)")
        lines.append("键盘通知 \(keyboardCount) 次，最后一次：\(keyboardNote)")
        return lines.joined(separator: "\n")
    }
}

extension UIResponder {
    private static weak var probed: UIResponder?

    /// 现在的第一响应者是什么（类名）
    static var currentFirstResponderName: String {
        probed = nil
        UIApplication.shared.sendAction(#selector(probeAsFirstResponder(_:)), to: nil, from: nil, for: nil)
        return probed.map { String(describing: type(of: $0)) } ?? "没有"
    }

    @objc func probeAsFirstResponder(_ sender: Any?) { UIResponder.probed = self }
}

private struct ProbeField: UIViewRepresentable {
    let probe: KeyboardProbe

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.borderStyle = .roundedRect
        field.placeholder = L("点这里试试")
        field.autocorrectionType = .no
        probe.field = field
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) { probe.field = uiView }
}

/// 看着这个窗口里的触摸落到了哪里（只看不拦）
private struct ProbeTouchSpy: UIViewRepresentable {
    let probe: KeyboardProbe

    func makeUIView(context: Context) -> Host {
        let view = Host()
        view.probe = probe
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: Host, context: Context) { uiView.probe = probe }

    static func dismantleUIView(_ uiView: Host, coordinator: ()) { uiView.detach() }

    final class Host: UIView {
        weak var probe: KeyboardProbe?
        private var spy: Spy?
        private weak var spiedWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, spy == nil else { return }
            let spy = Spy { [weak self, weak window] touch in self?.probe?.touched(touch, in: window) }
            window.addGestureRecognizer(spy)
            self.spy = spy
            spiedWindow = window
        }

        func detach() {
            if let spy { spiedWindow?.removeGestureRecognizer(spy) }
            spy = nil
        }
    }

    final class Spy: UIGestureRecognizer, UIGestureRecognizerDelegate {
        private let onTouch: (UITouch) -> Void

        init(onTouch: @escaping (UITouch) -> Void) {
            self.onTouch = onTouch
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { onTouch(touch) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    }
}
#endif
