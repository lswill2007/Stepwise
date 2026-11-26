import SwiftUI
import WebKit
#if canImport(PencilKit)
import PencilKit
#endif

/// 没有打开笔记、白板、题集时右边的页面：左栏里点中的文件夹（没点就是最外层）里的东西，一格一格排开，
/// 每格上面是一小页预览，下面是名字和日期。点一格打开
struct LibraryGridView: View {
    @EnvironmentObject var store: AppStore
    @State private var width: CGFloat = 800

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
                    // 一行三格；页面很窄（分屏）时两格
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 22, alignment: .top),
                                             count: width < 520 ? 2 : 3), spacing: 22) {
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
    @EnvironmentObject var store: AppStore
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
            // 从上次做到的那道题排起
            let saved = ReadingPosition.load(set.id)
            let start = set.questions.firstIndex { $0.id == saved?.item } ?? 0
            PagePreview(id: item.id, text: PagePreview.join(set.questions[start...].prefix(4).map { "**\($0.label).** " + $0.content }),
                        icon: item.icon)
        case .note(let doc):
            // 从上次看到的那一块排起
            let saved = ReadingPosition.load(doc.id)
            let start = doc.blocks.firstIndex { $0.id == saved?.item } ?? 0
            PagePreview(id: item.id, text: noteText(doc, from: start, part: saved?.part), icon: item.icon)
        case .board(let board):
            BoardThumbnail(boardID: board.id)
        }
    }

    /// 笔记从第几块起的几块；上次停在那一块的中间时，前面翻过去的几段不排
    private func noteText(_ doc: NoteDoc, from start: Int, part: Double?) -> String {
        var texts = Array(doc.blocks[start...].lazy.map { text(of: $0, in: doc) }.filter { !$0.isEmpty }.prefix(4))
        if let part, !texts.isEmpty, doc.blocks.indices.contains(start), texts[0] == text(of: doc.blocks[start], in: doc) {
            texts[0] = PagePreview.skipping(texts[0], part: part)
        }
        return PagePreview.join(texts)
    }

    /// 笔记的一块排成预览时用的 Markdown：正文、回答照原样，练习题是题目，手写块没有
    private func text(of block: NoteBlock, in doc: NoteDoc) -> String {
        switch block.kind {
        case .text, .answer: return block.text
        case .exercise: return block.questionID.flatMap { store.question(doc.exerciseSetID, $0)?.content } ?? ""
        case .canvas: return ""
        }
    }
}

/// 缩小的一页：和打开以后一样排好版的 Markdown、公式（不是原始的符号），从上次看到的地方排起，像远看的一张纸。
/// 按一页的宽度排好再整个缩小，字的大小、换行的位置都和真的页面成比例。
/// 排版用的是网页，要等一两秒：排好以后截一张图记着，下次（来回滚动、关掉东西回到这里）直接摆图，内容、位置变了才重排
private struct PagePreview: View {
    /// 哪份笔记、题集
    let id: UUID
    /// 从上次看到的地方起的 Markdown
    let text: String
    let icon: String
    @Environment(\.colorScheme) private var colorScheme
    #if canImport(UIKit)
    @State private var host = InkHost()
    @State private var shot: UIImage?
    @State private var shotTask: Task<Void, Never>?
    #endif

    /// 排版时当作一页有多宽、截多高（一格是方的，多截一点）
    private static let pageWidth: CGFloat = 430
    private static let inset: CGFloat = 20

    /// 几块合成一篇；每块只取开头一段，一格里放不下更多
    static func join(_ texts: [String]) -> String {
        texts.map { String($0.prefix(1500)) }.joined(separator: "\n\n")
    }

    /// 一块看到了几分之几：前面翻过去的整段去掉（按字数估，段落对齐）。公式、代码块中间不切
    static func skipping(_ text: String, part: Double) -> String {
        let paragraphs = text.components(separatedBy: "\n\n")
        guard part > 0.02, paragraphs.count > 1 else { return text }
        let total = Double(max(text.count, 1))
        var passed = 0, cut = 0
        for (i, paragraph) in paragraphs.enumerated() where i < paragraphs.count - 1 {
            passed += paragraph.count + 2
            guard Double(passed) / total <= part else { break }
            let before = paragraphs[...i].joined(separator: "\n\n")
            let open = before.components(separatedBy: "$$").count % 2 == 0 || before.components(separatedBy: "```").count % 2 == 0
            if !open { cut = i + 1 }
        }
        return paragraphs[cut...].joined(separator: "\n\n")
    }

    private var key: NSString { "\(colorScheme == .dark)|\(text)" as NSString }

    var body: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let scale = geo.size.width / Self.pageWidth
                Group {
                    #if canImport(UIKit)
                    if let image = shot ?? PagePreviewCache.shared.object(forKey: key) {
                        // 和排版时一样宽，高按图的比例（不让格子的高度把它压小）
                        let shown = Self.pageWidth - Self.inset * 2
                        Image(uiImage: image).resizable()
                            .frame(width: shown, height: shown * image.size.height / max(image.size.width, 1))
                    } else if let old = PagePreviewCache.shared.object(forKey: id.uuidString as NSString) {
                        // 内容、位置变了（刚看完关掉）：新的排好之前先摆着上次的图，不空白一下
                        let shown = Self.pageWidth - Self.inset * 2
                        Image(uiImage: old).resizable()
                            .frame(width: shown, height: shown * old.size.height / max(old.size.width, 1))
                            .background(alignment: .topLeading) {
                                RichText(text, host: host, onRendered: { capture() }).opacity(0)
                            }
                    } else {
                        RichText(text, host: host, onRendered: { capture() })
                    }
                    #else
                    RichText(text)
                    #endif
                }
                .padding(.horizontal, Self.inset)
                .padding(.top, 16)
                .frame(width: Self.pageWidth, height: geo.size.height / max(scale, 0.01), alignment: .topLeading)
                .clipped()
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            // 只是预览：点、按住都交给整格
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            #if canImport(UIKit)
            .onChange(of: key) { shot = nil }
            .onDisappear { shotTask?.cancel() }
            #endif
        }
    }

    #if canImport(UIKit)
    /// 排好版了：等字体、公式稳定下来，把看得见的那一截截成图记下来
    private func capture() {
        let key = key
        shotTask?.cancel()
        shotTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let web = host.view as? WKWebView, web.bounds.width > 10 else { return }
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: web.bounds.width, height: min(web.bounds.height, Self.pageWidth * 1.3))
            guard let image = try? await web.takeSnapshot(configuration: config), !Task.isCancelled else { return }
            PagePreviewCache.shared.setObject(image, forKey: key)
            PagePreviewCache.shared.setObject(image, forKey: id.uuidString as NSString)
            // 正摆着上次的图：换成新的
            if key == self.key { shot = image }
        }
    }
    #endif
}

#if canImport(UIKit)
/// 排好版的预览截图，按内容（和深浅色）记；每份笔记、题集另记一张最近的，内容变了重排时先摆着
private enum PagePreviewCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        return cache
    }()
}
#endif

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
