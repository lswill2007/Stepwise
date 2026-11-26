import SwiftUI
#if canImport(PencilKit)
import PencilKit
#endif

/// 没有打开笔记、白板、题集时右边的页面：左栏里点中的文件夹（没点就是最外层）里的东西，一格一格排开，
/// 每格上面是一小页预览，下面是名字和日期。点一格打开
struct LibraryGridView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let index = store.libraryIndex()
        let folder = store.folder(store.selectedFolderID)
        let folders = index.folders[folder?.id] ?? []
        let items = index.items[folder?.id] ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(folder?.name ?? L("资料库"))
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                if !folders.isEmpty {
                    // 子文件夹：一排小条，点一下进去
                    FlowChips(folders: folders, counts: index.counts)
                }
                if items.isEmpty && !folders.isEmpty {
                    // 只有子文件夹：上面那排就是全部
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label(folder == nil ? L("最外层还没有东西") : L("这个文件夹还是空的"), systemImage: "tray")
                    } description: {
                        Text("在左栏按住文件夹，可以在里面导入题目、生成笔记、新建白板；也可以把已有的拖进来")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 320), spacing: 22)], spacing: 22) {
                        ForEach(items) { item in
                            Button {
                                store.selectedFolderID = folder?.id
                                store.openItem(item.id)
                            } label: {
                                LibraryCard(item: item)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                MoveMenu(excluding: nil, current: folder?.id) { store.moveItem(item.id, to: $0) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ink.sidebar.opacity(0.45))
        .navigationTitle("")
    }
}

/// 子文件夹的一排小条（放不下就换行）
private struct FlowChips: View {
    @EnvironmentObject var store: AppStore
    let folders: [Folder]
    let counts: [UUID: Int]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(folders) { folder in
                Button {
                    store.browseFolder(folder.id)
                    store.setCollapsed(folder.id, false)
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(folder.tint.color.gradient).frame(width: 12, height: 12)
                        Text(folder.name).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 2)
                        if let n = counts[folder.id], n > 0 {
                            Text("\(n)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(folder.tint.color.opacity(0.22), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 一格：上面方方的一小页预览，下面名字和日期
private struct LibraryCard: View {
    let item: LibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(Ink.paper)
                .clipped()
            Rectangle().fill(Ink.separator).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: item.icon).font(.caption).foregroundStyle(.secondary)
                    Text(item.title).font(.headline).lineLimit(1)
                }
                Text(item.createdAt.formatted(.dateTime.year().month().day()))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ink.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Ink.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var preview: some View {
        switch item {
        case .set(let set):
            MiniPage(lines: set.questions.prefix(6).map { "\($0.label). " + Tutor.plainPreview($0.content) })
        case .note(let doc):
            MiniPage(lines: doc.blocks.filter { $0.kind != .canvas && !$0.text.isEmpty }.prefix(6).map { Tutor.plainPreview($0.text) })
        case .board(let board):
            BoardThumbnail(boardID: board.id)
        }
    }
}

/// 缩小的一页：几段很小的字，像远看的一张纸
private struct MiniPage: View {
    let lines: [String]

    var body: some View {
        if lines.isEmpty {
            Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// 白板的缩略图：把笔迹缩小画出来（在后台画）
private struct BoardThumbnail: View {
    let boardID: UUID
    @Environment(\.colorScheme) private var colorScheme
    #if canImport(UIKit)
    @State private var image: UIImage?
    #endif

    var body: some View {
        ZStack {
            #if canImport(UIKit)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(12)
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if canImport(UIKit) && canImport(PencilKit)
        // 深色模式下笔迹要按深色画（黑笔变成白的），不然画在深色纸上看不见
        .task(id: "\(boardID)-\(colorScheme == .dark)") {
            let id = boardID
            let dark = colorScheme == .dark
            let key = "\(id)-\(dark)" as NSString
            // 先摆上次画好的（来回滚动、从白板退回来时不闪一下空白）；笔迹没变就不用重画
            if image == nil { image = BoardThumbnailCache.shared.object(forKey: key)?.image }
            image = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let data = DrawingStore.load(id) else { return nil }
                if let cached = BoardThumbnailCache.shared.object(forKey: key), cached.data == data { return cached.image }
                guard let drawing = try? PKDrawing(data: data) else { return nil }
                let bounds = drawing.bounds
                guard !bounds.isEmpty, bounds.width > 1, bounds.height > 1 else { return nil }
                // 白板很大：缩到长边 500 像素左右
                let scale = min(1, 500 / max(bounds.width, bounds.height))
                var result: UIImage?
                UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
                    result = drawing.image(from: bounds.insetBy(dx: -8, dy: -8), scale: scale)
                }
                if let result { BoardThumbnailCache.shared.setObject(.init(data: data, image: result), forKey: key) }
                return result
            }.value
        }
        #endif
    }

    private var placeholder: some View {
        Image(systemName: "rectangle.and.pencil.and.ellipsis").font(.largeTitle).foregroundStyle(.tertiary)
    }
}

#if canImport(UIKit)
/// 画好的白板缩略图，连同画它时的笔迹数据（数据一样就是同一张图）
private final class BoardThumbnailCache {
    final class Entry {
        let data: Data
        let image: UIImage
        init(data: Data, image: UIImage) { self.data = data; self.image = image }
    }
    static let shared: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 60
        return cache
    }()
}
#endif
