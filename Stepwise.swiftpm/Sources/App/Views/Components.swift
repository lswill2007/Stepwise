import SwiftUI

/// 显示保存在本地的图片，点击放大
struct StoredImage: View {
    let id: String
    var maxHeight: CGFloat = 260
    @State private var zoomed = false

    var body: some View {
        if let cg = ImageStore.cgImage(id) {
            Image(decorative: cg, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: maxHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .onTapGesture { zoomed = true }
                .sheet(isPresented: $zoomed) {
                    ZoomableImage(image: cg)
                }
        }
    }
}

struct ZoomableImage: View {
    let image: CGImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 700 * scale * pinch)
                    .gesture(MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { scale = min(max(scale * $0, 0.5), 5) })
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

/// 工具栏里的模型切换菜单
struct ModelMenu: View {
    @EnvironmentObject var store: AppStore
    var onOpenSettings: () -> Void

    var body: some View {
        let configured = ProviderCatalog.displayOrder(store.providers.filter(\.hasKey))
        Menu {
            if configured.isEmpty {
                Text("还没有填写任何 API Key")
            }
            ForEach(configured) { p in
                Menu(p.name) {
                    // 只列常用模型，聚合平台几百个模型放进菜单没法选
                    ForEach(p.menuModels, id: \.self) { m in
                        Button {
                            store.select(provider: p.id, model: m)
                        } label: {
                            if p.id == store.activeProviderID && p.model == m {
                                Label(m, systemImage: "checkmark")
                            } else {
                                Text(m)
                            }
                        }
                    }
                    if p.allModels.count > p.menuModels.count {
                        Divider()
                        Button("更多模型…（在设置里加星标为常用）", systemImage: "star", action: onOpenSettings)
                    }
                }
            }
            Divider()
            Button("模型设置…", systemImage: "gearshape", action: onOpenSettings)
        } label: {
            Label(store.activeProvider.map { $0.model.isEmpty ? $0.name : $0.model } ?? L("选择模型"),
                  systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
    }
}

/// 从左到右排列、放不下就换行的布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty && row.width + spacing + size.width > maxWidth {
                let nextY = row.y + row.height + spacing
                rows.append(Row(y: nextY))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: - 纸笔配色

/// 整个 App 只用纸和笔的颜色：墨蓝钢笔（主色，Assets 里的 AccentColor）、红笔批改、蓝笔答案、便签黄。
/// 不用一种功能配一种鲜艳颜色，页面才像一本笔记本
enum Ink {
    static let pen = Color.accentColor
    static let red = adaptive(light: (0.74, 0.16, 0.12), dark: (0.96, 0.47, 0.42))
    static let blue = adaptive(light: (0.14, 0.35, 0.62), dark: (0.56, 0.71, 0.95))
    static let green = adaptive(light: (0.21, 0.45, 0.28), dark: (0.52, 0.78, 0.57))
    /// 便签纸
    static let note = adaptive(light: (1.0, 0.957, 0.78), dark: (0.29, 0.26, 0.17))
    /// 笔记本的纸色
    static let paper = adaptive(light: (0.984, 0.977, 0.958), dark: (0.105, 0.105, 0.115))

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        #if os(iOS)
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(red: light.0, green: light.1, blue: light.2)
        #endif
    }
}

extension View {
    /// 写在页边的批注：不加底色卡片，左边一条细竖线，像用笔在纸边划了一道
    func marginRule(_ color: Color) -> some View {
        padding(.leading, 12)
            .padding(.vertical, 2)
            .overlay(alignment: .leading) {
                Rectangle().fill(color.opacity(0.7)).frame(width: 2)
            }
    }
}

/// 不带边框、不带图标的文字按钮，用在笔记本页面上
struct InkTextButtonStyle: ButtonStyle {
    var color: Color = Ink.pen
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(color.opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.35))
            .padding(.vertical, 6)
            .contentShape(Rectangle())
    }
}

/// AI 正在生成时的状态：淡色细边胶囊，文字上有一道同色的光划过，后面是已经等了几秒，可以停止。
/// 放在刚点的按钮旁边和正在写的地方，一眼看得出 AI 在干活
struct GeneratingBadge: View {
    let label: String
    var startedAt: Date?
    var tint: Color = Ink.pen
    /// 小号：页边批注、便签里用
    var compact = false
    var stop: (() -> Void)?
    @AppStorage("showTiming") private var showTiming = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            shimmeringLabel
            if let startedAt, showTiming {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(startedAt)))) 秒")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tint.opacity(0.5))
                }
            }
            if let stop {
                Rectangle().fill(tint.opacity(0.15)).frame(width: 1, height: compact ? 10 : 12)
                Button(action: stop) {
                    Text("停止")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint.opacity(0.8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止")
            }
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 4 : 7)
        .background(tint.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.12), lineWidth: 0.5))
        .fixedSize()
    }

    /// 文字本身底色淡，一道深一点的同色光从左到右匀速划过文字。
    /// 按当前时间算位置，不靠 @State 动画，文字流式刷新、秒数变化时都不会被打断重来
    private var shimmeringLabel: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let font: Font = compact ? .caption.weight(.medium) : .subheadline.weight(.medium)
            let period = 2.0
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            // 光的中心从文字左边外面走到右边外面，进出都看不到硬边
            let center = -0.4 + t * 1.8
            Text(label)
                .font(font)
                .lineLimit(1)
                .foregroundStyle(reduceMotion
                    ? AnyShapeStyle(tint.opacity(0.85))
                    : AnyShapeStyle(LinearGradient(
                        stops: [.init(color: tint.opacity(0.4), location: 0),
                                .init(color: tint, location: 0.5),
                                .init(color: tint.opacity(0.4), location: 1)],
                        startPoint: UnitPoint(x: center - 0.35, y: 0.5),
                        endPoint: UnitPoint(x: center + 0.35, y: 0.5))))
        }
    }
}
