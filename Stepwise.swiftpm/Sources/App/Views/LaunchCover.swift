import SwiftUI

/// 打开 App 时的加载页：纸色底，一笔一级画出三级台阶（一步一步来），台阶顶上落一个点，下面是名字。
///
/// 盖在第一页上面，第一页排好、能点了才淡出（见 RootView）。
/// 台阶的动画交给 Core Animation 在系统的渲染进程里跑：读数据、排第一页、启动 WebKit 时主线程会忙一阵，
/// 用 SwiftUI 的动画那时候会停住不动，这样不会
struct LaunchCover: View {
    /// 数据还在从用户选的储存文件夹里读（可能在等 iCloud 下载）
    let readingFolder: Bool
    @State private var showStatus = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Ink.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                StairStroke(animated: !reduceMotion)
                    .frame(width: StairStroke.size.width, height: StairStroke.size.height)
                Text(verbatim: "Stepwise")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .kerning(0.4)
                    .foregroundStyle(.primary)
                    .padding(.top, 22)
                // 快的时候一闪而过，不写字；超过一秒半还没好，才说在做什么
                Text(readingFolder ? "正在读取储存文件夹…" : "正在打开…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                    .opacity(showStatus ? 1 : 0)
            }
            // 名字和台阶整体在屏幕正中略偏上，看着更稳
            .offset(y: -20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(readingFolder ? "正在读取储存文件夹…" : "正在打开…"))
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeIn(duration: 0.3)) { showStatus = true }
        }
        .onAppear {
            // 加载页先画出来，再准备公式排版用的 WebKit：刚开机冷启动时它要在主线程上占大半秒，
            // 放在加载页前面，打开 App 后要对着一片空白等
            DispatchQueue.main.async { MathAssets.prewarm() }
        }
    }
}

/// 三级台阶：一笔从左下画到右上，顶上落一个点；然后从起点开始收掉，再画下一遍
struct StairStroke: View {
    var animated = true

    static let size = CGSize(width: 76, height: 66)
    /// 台阶的折线（左下 → 右上）
    static let points: [CGPoint] = [
        CGPoint(x: 4, y: 62), CGPoint(x: 23, y: 62),
        CGPoint(x: 23, y: 45), CGPoint(x: 42, y: 45),
        CGPoint(x: 42, y: 28), CGPoint(x: 61, y: 28),
        CGPoint(x: 61, y: 11), CGPoint(x: 72, y: 11),
    ]
    /// 顶上那个点
    static let dot = CGPoint(x: 66.5, y: 3.5)
    static let lineWidth: CGFloat = 3.5
    static let dotRadius: CGFloat = 3.2

    static var path: CGPath {
        let p = CGMutablePath()
        p.addLines(between: points)
        return p
    }

    var body: some View {
        #if os(iOS)
        StairStrokeRepresentable(animated: animated)
            .accessibilityHidden(true)
        #else
        // Mac 版只用于编译检查：画一张不动的
        ZStack(alignment: .topLeading) {
            Path(Self.path).stroke(Ink.pen, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
            Circle().fill(Ink.pen)
                .frame(width: Self.dotRadius * 2, height: Self.dotRadius * 2)
                .offset(x: Self.dot.x - Self.dotRadius, y: Self.dot.y - Self.dotRadius)
        }
        #endif
    }
}

#if os(iOS)
private struct StairStrokeRepresentable: UIViewRepresentable {
    let animated: Bool

    func makeUIView(context: Context) -> StairStrokeView {
        let view = StairStrokeView()
        view.animated = animated
        return view
    }

    func updateUIView(_ view: StairStrokeView, context: Context) {
        if view.animated != animated { view.animated = animated }
    }
}

final class StairStrokeView: UIView {
    private let line = CAShapeLayer()
    private let dot = CAShapeLayer()

    var animated = true {
        didSet { restart() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        line.path = StairStroke.path
        line.fillColor = nil
        line.lineWidth = StairStroke.lineWidth
        line.lineCap = .round
        line.lineJoin = .round
        let r = StairStroke.dotRadius
        dot.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2), transform: nil)
        dot.position = StairStroke.dot
        layer.addSublayer(line)
        layer.addSublayer(dot)
        applyColors()
        // 深色、浅色切换时 CGColor 不会自己跟着变
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StairStrokeView, _: UITraitCollection) in
            view.applyColors()
        }
        restart()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { StairStroke.size }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 退到后台再回来时系统会拿掉动画，重新挂上
        if window != nil { restart() }
    }

    private func applyColors() {
        let ink = (UIColor(named: "AccentColor") ?? .tintColor).resolvedColor(with: traitCollection).cgColor
        line.strokeColor = ink
        dot.fillColor = ink
    }

    private func restart() {
        line.removeAllAnimations()
        dot.removeAllAnimations()
        guard animated else {
            line.strokeStart = 0
            line.strokeEnd = 1
            dot.opacity = 1
            dot.transform = CATransform3DIdentity
            return
        }
        // 一遍 2.6 秒：画台阶 → 点落下 → 停一下 → 从起点收掉、点淡去 → 下一遍
        let cycle: CFTimeInterval = 2.6
        let ease = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
        let linear = CAMediaTimingFunction(name: .linear)

        let draw = CAKeyframeAnimation(keyPath: "strokeEnd")
        draw.values = [0, 1, 1]
        draw.keyTimes = [0, 0.46, 1]
        draw.timingFunctions = [ease, linear]

        let erase = CAKeyframeAnimation(keyPath: "strokeStart")
        erase.values = [0, 0, 1, 1]
        erase.keyTimes = [0, 0.7, 0.9, 1]
        erase.timingFunctions = [linear, ease, linear]

        line.strokeStart = 0
        line.strokeEnd = 0
        line.add(group([draw, erase], cycle), forKey: "stairs")

        // 点：台阶画到顶时从上面轻轻落下、弹一下，收线时淡去
        let drop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        drop.values = [-6, -6, 0, 0]
        drop.keyTimes = [0, 0.44, 0.56, 1]
        drop.timingFunctions = [linear, CAMediaTimingFunction(controlPoints: 0.3, 1.4, 0.5, 1), linear]

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0, 1, 1, 0, 0]
        fade.keyTimes = [0, 0.44, 0.52, 0.72, 0.86, 1]
        fade.timingFunctions = [linear, linear, linear, ease, linear]

        dot.opacity = 0
        dot.add(group([drop, fade], cycle), forKey: "dot")
    }

    private func group(_ animations: [CAAnimation], _ duration: CFTimeInterval) -> CAAnimationGroup {
        let g = CAAnimationGroup()
        g.animations = animations
        g.duration = duration
        g.repeatCount = .infinity
        g.isRemovedOnCompletion = false
        return g
    }
}
#endif
