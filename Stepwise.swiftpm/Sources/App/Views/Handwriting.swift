import SwiftUI

#if os(iOS)
import PencilKit

/// 框选后画布会成为第一响应者（用于剪切 / 拷贝 / 撤销），这里阻止它顺带弹出键盘
final class PadCanvasView: PKCanvasView {
    private let noKeyboard = UIView(frame: .zero)
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

/// 手写作答板：Apple Pencil 书写，手指滚动和缩放；导出为白底 JPEG 发给模型批改。
final class HandwritingModel: ObservableObject {
    enum Tool { case pen, eraser, lasso }
    enum EraserKind: String { case area, stroke }

    let canvas = PadCanvasView()
    @Published var isEmpty = true
    @Published var zoom: CGFloat = 1
    @Published var tool: Tool = .pen { didSet { applyTool() } }
    @Published var eraserKind: EraserKind {
        didSet {
            UserDefaults.standard.set(eraserKind.rawValue, forKey: "handwritingEraserKind")
            if tool == .eraser { applyTool() }
        }
    }
    /// 没有 Apple Pencil 时可以打开，让手指也能书写
    @Published var allowFinger: Bool {
        didSet {
            UserDefaults.standard.set(allowFinger, forKey: "handwritingAllowFinger")
            canvas.drawingPolicy = allowFinger ? .anyInput : .pencilOnly
        }
    }

    /// 双击笔身切到橡皮擦前的工具，再双击时切回去
    private var toolBeforeEraser: Tool = .pen

    static let isAvailable = true
    static let zoomRange: ClosedRange<CGFloat> = 0.5...4

    init() {
        eraserKind = EraserKind(rawValue: UserDefaults.standard.string(forKey: "handwritingEraserKind") ?? "") ?? .area
        allowFinger = UserDefaults.standard.bool(forKey: "handwritingAllowFinger")
        canvas.drawingPolicy = allowFinger ? .anyInput : .pencilOnly
        applyTool()
    }

    private func applyTool() {
        switch tool {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        case .eraser:
            canvas.tool = eraserKind == .stroke ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: 18)
        case .lasso:
            canvas.tool = PKLassoTool()
        }
    }

    func select(_ newTool: Tool) {
        if newTool == .eraser && tool != .eraser { toolBeforeEraser = tool }
        tool = newTool
    }

    /// Apple Pencil 双击或捏合：在橡皮擦和之前的工具之间切换
    func toggleEraser() {
        if tool == .eraser {
            tool = toolBeforeEraser
        } else {
            toolBeforeEraser = tool
            tool = .eraser
        }
    }

    func clear() {
        canvas.drawing = PKDrawing()
        isEmpty = true
    }

    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }

    func resetZoom() {
        canvas.setZoomScale(1, animated: true)
    }

    func exportJPEG() -> Data? {
        let drawing = canvas.drawing
        guard !drawing.strokes.isEmpty else { return nil }
        // 笔迹坐标与缩放无关，导出结果不受当前缩放影响
        let bounds = drawing.bounds.insetBy(dx: -24, dy: -24)
        var image: UIImage!
        // 固定浅色外观，避免深色模式下导出白色笔迹
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: 2)
        }
        guard let cg = image.cgImage else { return nil }
        return ImageUtil.jpeg(cg).flatMap { ImageUtil.normalizedJPEG($0) }
    }
}

struct HandwritingPad: View {
    @ObservedObject var model: HandwritingModel
    /// 全屏时用另一套记忆的高度
    var fullScreen = false

    @AppStorage("handwritingPadHeight") private var normalHeight: Double = 340
    @AppStorage("handwritingPadHeightFull") private var fullHeight: Double = 520
    /// 拖动过程中的起始高度
    @State private var dragStartHeight: Double?

    private static let heightRange: ClosedRange<Double> = 200...1400

    private var height: Double { fullScreen ? fullHeight : normalHeight }

    private func setHeight(_ value: Double) {
        let clamped = min(max(value, Self.heightRange.lowerBound), Self.heightRange.upperBound)
        if fullScreen { fullHeight = clamped } else { normalHeight = clamped }
    }

    var body: some View {
        VStack(spacing: 8) {
            toolbar

            CanvasRepresentable(model: model)
                .frame(height: height)
                .animation(dragStartHeight == nil ? .easeInOut(duration: 0.25) : nil, value: height)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))

            VStack(spacing: 2) {
                // 拖动条：上下拖动调整手写板高度
                ZStack {
                    Color.clear
                    Capsule()
                        .fill(dragStartHeight == nil ? Color.secondary.opacity(0.45) : Color.accentColor)
                        .frame(width: 56, height: 6)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if dragStartHeight == nil { dragStartHeight = height }
                            setHeight((dragStartHeight ?? height) + value.translation.height)
                        }
                        .onEnded { _ in dragStartHeight = nil }
                )
                .accessibilityLabel("调整手写板高度")

                Text(model.allowFinger
                     ? "Apple Pencil 或手指书写 · 双指缩放 · 双击笔身切换橡皮擦 · 拖动横条调整高度"
                     : "Apple Pencil 书写 · 手指拖动和双指缩放 · 双击笔身切换橡皮擦 · 拖动横条调整高度")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolButton(.pen, title: "笔", icon: "pencil.tip")
            toolButton(.eraser,
                       title: model.eraserKind == .stroke ? "整笔擦" : "橡皮",
                       icon: model.eraserKind == .stroke ? "eraser.line.dashed" : "eraser")
                .contextMenu {
                    Picker("橡皮擦类型", selection: $model.eraserKind) {
                        Label("局部擦除", systemImage: "eraser").tag(HandwritingModel.EraserKind.area)
                        Label("整笔擦除", systemImage: "eraser.line.dashed").tag(HandwritingModel.EraserKind.stroke)
                    }
                }
            toolButton(.lasso, title: "框选", icon: "lasso")

            Divider().frame(height: 22).padding(.horizontal, 4)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .accessibilityLabel("撤销")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .accessibilityLabel("重做")

            Spacer(minLength: 4)

            Button {
                model.resetZoom()
            } label: {
                Label("\(Int((model.zoom * 100).rounded()))%", systemImage: "plus.magnifyingglass")
            }
            .disabled(abs(model.zoom - 1) < 0.01)
            .accessibilityHint("恢复 100%")

            Button(role: .destructive) { model.clear() } label: { Image(systemName: "trash") }
                .disabled(model.isEmpty)
                .accessibilityLabel("清空")

            Menu {
                Toggle(isOn: $model.allowFinger) {
                    Label("允许手指书写", systemImage: "hand.draw")
                }
                Picker("橡皮擦类型", selection: $model.eraserKind) {
                    Label("局部擦除", systemImage: "eraser").tag(HandwritingModel.EraserKind.area)
                    Label("整笔擦除", systemImage: "eraser.line.dashed").tag(HandwritingModel.EraserKind.stroke)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("手写设置")
        }
        .buttonStyle(.borderless)
        .font(.body)
    }

    private func toolButton(_ tool: HandwritingModel.Tool, title: String, icon: String) -> some View {
        let selected = model.tool == tool
        return Button {
            model.select(tool)
        } label: {
            Label(title, systemImage: icon)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CanvasRepresentable: UIViewRepresentable {
    let model: HandwritingModel

    func makeUIView(context: Context) -> PadCanvasView {
        let canvas = model.canvas
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        canvas.alwaysBounceVertical = true
        canvas.minimumZoomScale = HandwritingModel.zoomRange.lowerBound
        canvas.maximumZoomScale = HandwritingModel.zoomRange.upperBound
        canvas.bouncesZoom = true
        canvas.contentSize = CGSize(width: 2000, height: 3000)

        // Apple Pencil 双击 / 捏合切换橡皮擦
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        canvas.addInteraction(pencil)
        return canvas
    }

    func updateUIView(_ uiView: PadCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        let model: HandwritingModel
        init(model: HandwritingModel) { self.model = model }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let empty = canvasView.drawing.strokes.isEmpty
            if model.isEmpty != empty { model.isEmpty = empty }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoom = scrollView.zoomScale
            if abs(model.zoom - zoom) > 0.005 { model.zoom = zoom }
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

        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard squeeze.phase == .ended, UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
            model.toggleEraser()
        }

        private func handleTap() {
            // 尊重系统设置：用户在“设置 › Apple Pencil”里关闭了双击就不响应
            guard UIPencilInteraction.preferredTapAction != .ignore else { return }
            model.toggleEraser()
        }
    }
}

#else

/// Mac 上仅用于编译检查，不提供手写
final class HandwritingModel: ObservableObject {
    @Published var isEmpty = true
    static let isAvailable = false
    func clear() {}
    func exportJPEG() -> Data? { nil }
}

struct HandwritingPad: View {
    @ObservedObject var model: HandwritingModel
    var fullScreen = false
    var body: some View { EmptyView() }
}

#endif
