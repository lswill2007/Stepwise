import SwiftUI

#if os(iOS)
import PencilKit

/// 手写作答板：支持 Apple Pencil 和手指，导出为白底 JPEG 发给模型批改。
final class HandwritingModel: ObservableObject {
    let canvas = PKCanvasView()
    @Published var isEmpty = true
    @Published var zoom: CGFloat = 1

    static let isAvailable = true
    static let zoomRange: ClosedRange<CGFloat> = 0.5...4

    func clear() {
        canvas.drawing = PKDrawing()
        isEmpty = true
    }

    func undo() {
        canvas.undoManager?.undo()
    }

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
    /// 拖动过程中的实时高度
    @State private var dragStartHeight: Double?

    private static let heightRange: ClosedRange<Double> = 200...1400

    private var height: Double { fullScreen ? fullHeight : normalHeight }

    private func setHeight(_ value: Double) {
        let clamped = min(max(value, Self.heightRange.lowerBound), Self.heightRange.upperBound)
        if fullScreen { fullHeight = clamped } else { normalHeight = clamped }
    }

    var body: some View {
        VStack(spacing: 0) {
            CanvasRepresentable(model: model)
                .frame(height: height)
                .animation(dragStartHeight == nil ? .easeInOut(duration: 0.25) : nil, value: height)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))

            // 拖动条：上下拖动调整手写板高度
            ZStack {
                Color.clear
                Capsule()
                    .fill(dragStartHeight == nil ? Color.secondary.opacity(0.45) : Color.accentColor)
                    .frame(width: 56, height: 6)
            }
            .frame(height: 26)
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

            HStack(spacing: 14) {
                Text("双指缩放 · 拖动下方横条调整高度").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.resetZoom()
                } label: {
                    Label("\(Int((model.zoom * 100).rounded()))%", systemImage: "plus.magnifyingglass")
                }
                .disabled(abs(model.zoom - 1) < 0.01)
                .help("恢复 100%")
                Button("撤销", systemImage: "arrow.uturn.backward") { model.undo() }
                Button("清空", systemImage: "trash", role: .destructive) { model.clear() }
                    .disabled(model.isEmpty)
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }
}

private struct CanvasRepresentable: UIViewRepresentable {
    let model: HandwritingModel

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = model.canvas
        // 一根手指或 Apple Pencil 书写，两根手指滚动和缩放
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.delegate = context.coordinator
        canvas.alwaysBounceVertical = true
        canvas.minimumZoomScale = HandwritingModel.zoomRange.lowerBound
        canvas.maximumZoomScale = HandwritingModel.zoomRange.upperBound
        canvas.bouncesZoom = true
        canvas.contentSize = CGSize(width: 2000, height: 3000)
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
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
