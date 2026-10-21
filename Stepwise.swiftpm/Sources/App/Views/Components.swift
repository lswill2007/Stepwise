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
        let configured = store.providers.filter(\.hasKey)
        Menu {
            if configured.isEmpty {
                Text("还没有填写任何 API Key")
            }
            ForEach(configured) { p in
                Menu(p.name) {
                    ForEach(p.allModels, id: \.self) { m in
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
                }
            }
            Divider()
            Button("模型设置…", systemImage: "gearshape", action: onOpenSettings)
        } label: {
            Label(store.activeProvider.map { $0.model.isEmpty ? $0.name : $0.model } ?? "选择模型",
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
