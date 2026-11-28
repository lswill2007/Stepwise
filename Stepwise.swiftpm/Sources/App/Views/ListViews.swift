import SwiftUI

/// 左栏：资料库。收藏固定在最上面，下面是自己建的文件夹（一层层嵌套缩进，颜色只在文件夹图标上），
/// 笔记、白板、题集都可以放进任意一个文件夹，没放进文件夹的排在最外层
struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @Binding var showImport: Bool
    @Binding var showNoteImport: Bool
    @Binding var showSettings: Bool

    /// 正在输入名字：新建文件夹、重命名文件夹、题集、笔记或白板
    enum NameEdit: Identifiable {
        case newFolder(parent: UUID?)
        case renameFolder(UUID)
        case renameSet(UUID)
        case renameNote(UUID)
        case renameBoard(UUID)
        var id: String {
            switch self {
            case .newFolder(let parent): return "new-\(parent?.uuidString ?? "root")"
            case .renameFolder(let id): return "folder-\(id)"
            case .renameSet(let id): return "set-\(id)"
            case .renameNote(let id): return "note-\(id)"
            case .renameBoard(let id): return "board-\(id)"
            }
        }
    }
    @State private var nameEdit: NameEdit?
    @State private var nameText = ""
    @State private var deletingFolder: Folder?
    @State private var deletingNote: NoteDoc?
    @State private var deletingBoard: Whiteboard?
    @State private var deletingSet: QuestionSet?
    /// 从笔记或题集的菜单里点了“导出 PDF”
    @State private var pdfRequest: PDFRequest?

    struct PDFRequest: Identifiable {
        let id = UUID()
        var notes: Set<UUID> = []
        var sets: Set<UUID> = []
    }

    /// 资料库排成一行一行：文件夹条和里面的东西，按层级缩进。folder：所在的文件夹（最外层没有）
    enum Row: Identifiable {
        case folder(Folder, depth: Int)
        case item(LibraryItem, depth: Int, folder: Folder?)
        var id: UUID {
            switch self {
            case .folder(let f, _): return f.id
            case .item(let item, _, _): return item.id
            }
        }
    }

    var body: some View {
        let index = store.libraryIndex()
        let rows = Self.rows(index)
        // 自己管选中（不用 List 的选中：它会把选中那一行的字变白、底色变深）
        let browsing = store.hasOpenItem ? nil : store.folder(store.selectedFolderID)?.id
        List {
            Group {
                if !isEmpty {
                    Section {
                        allRow(selected: !store.hasOpenItem && browsing == nil)
                        if !store.questionSets.isEmpty { mistakeBookRow }
                    }
                }
                Section {
                    ForEach(rows) { row in
                        switch row {
                        case .folder(let folder, let depth):
                            FolderBar(folder: folder, depth: depth, count: index.counts[folder.id] ?? 0,
                                      selected: browsing == folder.id, actions: actions)
                        case .item(let item, let depth, let folder):
                            itemRow(item, depth: depth, folder: folder)
                        }
                    }
                    if !isEmpty {
                        Button {
                            startEdit(.newFolder(parent: nil))
                        } label: {
                            Label("新建文件夹", systemImage: "folder.badge.plus")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 16))
                        .selectionDisabled()
                    }
                }
            }
            // 左栏和中间栏自己排在页面旁边（不在系统分栏里），系统给的是一块块卡片：去掉卡片底色和分隔线，
            // 选中的一行自己画圆角底色（见 PaneRowStyle）
            .paneRows()
        }
        .paneList(selection: nil)
        .overlay {
            if isEmpty {
                ContentUnavailableView {
                    Label("还没有题目", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("导入 PDF、图片或文字，AI 会自动把每道题分开；也可以导入课件、讲义，生成预习和复习笔记")
                } actions: {
                    Button("导入题目") { openImport(notes: false, into: nil) }.buttonStyle(.borderedProminent)
                    Button("导入资料生成笔记") { openImport(notes: true, into: nil) }
                }
            }
        }
        .navigationTitle("资料库")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // 新建、导入的东西放到现在选中的东西所在的文件夹
                    Button("导入题目", systemImage: "doc.text") { openImport(notes: false, into: nil) }
                    Button("导入资料生成笔记", systemImage: "doc.richtext") { openImport(notes: true, into: nil) }
                    Button("新建白板", systemImage: "rectangle.and.pencil.and.ellipsis") { store.createBoard(in: store.currentFolderID) }
                    Divider()
                    Button("新建文件夹", systemImage: "folder.badge.plus") { startEdit(.newFolder(parent: nil)) }
                } label: {
                    Label("导入", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
            }
        }
        .alert(alertTitle, isPresented: Binding(get: { nameEdit != nil }, set: { if !$0 { nameEdit = nil } })) {
            TextField("名称", text: $nameText)
            Button("取消", role: .cancel) { nameEdit = nil }
            Button("确定") { commitName() }
        }
        .sheet(item: $pdfRequest) { request in
            NavigationStack {
                PDFExportView(notes: request.notes, sets: request.sets, inSheet: true)
            }
        }
        .confirmationDialog(
            "删除文件夹“\(deletingFolder?.name ?? "")”？",
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除文件夹", role: .destructive) {
                if let id = deletingFolder?.id { store.deleteFolder(id) }
                deletingFolder = nil
            }
        } message: {
            Text("里面的笔记、白板、题集和子文件夹会移到上一级，不会删除任何内容。")
        }
        .confirmationDialog(
            "删除笔记“\(deletingNote?.title ?? "")”？",
            isPresented: Binding(get: { deletingNote != nil }, set: { if !$0 { deletingNote = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除笔记", role: .destructive) {
                if let id = deletingNote?.id { store.deleteNote(id) }
                deletingNote = nil
            }
        } message: {
            Text("笔记和里面的练习题、手写作答都会删除，不能恢复。")
        }
        .confirmationDialog(
            "删除白板“\(deletingBoard?.title ?? "")”？",
            isPresented: Binding(get: { deletingBoard != nil }, set: { if !$0 { deletingBoard = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除白板", role: .destructive) {
                if let id = deletingBoard?.id { store.deleteBoard(id) }
                deletingBoard = nil
            }
        } message: {
            Text("白板上的笔迹和便签都会删除，不能恢复。")
        }
        // 题集以前点了“删除”马上就删：手写作答都在里面，删之前问一下
        .confirmationDialog(
            "删除题集“\(deletingSet?.title ?? "")”？",
            isPresented: Binding(get: { deletingSet != nil }, set: { if !$0 { deletingSet = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除题集", role: .destructive) {
                if let id = deletingSet?.id { store.deleteSet(id) }
                deletingSet = nil
            }
        } message: {
            Text("题目、手写作答和批改记录都会删除，不能恢复。")
        }
    }

    private var isEmpty: Bool {
        store.questionSets.isEmpty && store.folders.isEmpty && store.notes.isEmpty && store.boards.isEmpty
    }

    /// 展开的文件夹排出里面的子文件夹（在前）和笔记、白板、题集（新的在上）；收起的只排一条
    static func rows(_ index: AppStore.LibraryIndex) -> [Row] {
        var out: [Row] = []
        func walk(_ parent: Folder?, _ depth: Int) {
            guard depth < 50 else { return }
            for folder in index.folders[parent?.id] ?? [] {
                out.append(.folder(folder, depth: depth))
                if !folder.collapsed { walk(folder, depth + 1) }
            }
            for item in index.items[parent?.id] ?? [] {
                out.append(.item(item, depth: depth, folder: parent))
            }
        }
        walk(nil, 0)
        return out
    }

    /// 全部：回到最外层，右边一格一格排出没放进文件夹的东西和最外层的文件夹
    private func allRow(selected: Bool) -> some View {
        LibraryBar(selected: selected, symbol: .icon("square.grid.2x2")) {
            Text("全部").font(.body.weight(selected ? .semibold : .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onTapGesture { store.browseFolder(nil) }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
    }

    /// 收藏：固定在最上面的一条
    private var mistakeBookRow: some View {
        LibraryBar(selected: store.isMistakeBook, symbol: .tinted("star.fill", Ink.star)) {
            HStack {
                Text("收藏").font(.body.weight(store.isMistakeBook ? .semibold : .medium))
                Spacer()
                let count = store.starredCount
                if count > 0 {
                    Text("\(count)")
                        .font(.callout).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onTapGesture { store.openItem(AppStore.mistakeBookID) }
        .accessibilityAddTraits(.isButton)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 10, trailing: 10))
    }

    /// 一篇笔记、一块白板或一个题集：平铺的一行，跟着所在的文件夹缩进
    private func itemRow(_ item: LibraryItem, depth: Int, folder: Folder?) -> some View {
        // 拖到一篇笔记、一块白板或一个题集上：放进它所在的文件夹
        let place = folder?.id
        let selected = (store.selectedBoardID ?? store.selectedNoteID ?? store.selectedSetID) == item.id
        return LibraryBar(selected: selected, symbol: .icon(item.icon)) {
            switch item {
            case .set(let set):
                SetRow(set: set, selected: selected, actions: actions)
            case .note(let doc):
                NoteRow(doc: doc, selected: selected, actions: actions)
            case .board(let board):
                BoardRow(board: board, selected: selected, actions: actions)
            }
        }
        .onTapGesture {
            store.selectedFolderID = place
            store.openItem(item.id)
        }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .listRowInsets(EdgeInsets(top: 1, leading: 10 + SidebarView.indent(depth), bottom: 1, trailing: 10))
        .draggable(item.dragKey) {
            Label(item.title, systemImage: item.icon).padding(8)
        }
        .dropDestination(for: String.self) { items, _ in
            drop(items, into: place)
        }
    }

    /// 每深一层往右缩进多少
    static func indent(_ depth: Int) -> CGFloat { CGFloat(min(depth, 6)) * 14 }

    private var actions: SidebarActions {
        SidebarActions(edit: startEdit, deleteFolder: { deletingFolder = $0 },
                       deleteNote: { deletingNote = $0 }, deleteBoard: { deletingBoard = $0 },
                       deleteSet: { deletingSet = $0 },
                       drop: drop,
                       exportPDF: { pdfRequest = $0 },
                       importInto: openImport)
    }

    /// 打开导入页；into 为文件夹菜单里点的那个文件夹，nil 时默认放到现在选中的东西所在的文件夹
    private func openImport(notes: Bool, into folderID: UUID?) {
        store.importFolderHint = folderID
        if notes { showNoteImport = true } else { showImport = true }
    }

    private var alertTitle: String {
        switch nameEdit {
        case .newFolder(let parent): return parent == nil ? L("新建文件夹") : L("新建子文件夹")
        case .renameFolder: return L("重命名文件夹")
        case .renameSet: return L("重命名题集")
        case .renameNote: return L("重命名笔记")
        case .renameBoard: return L("重命名白板")
        case nil: return ""
        }
    }

    private func startEdit(_ edit: NameEdit) {
        switch edit {
        case .newFolder: nameText = ""
        case .renameFolder(let id): nameText = store.folder(id)?.name ?? ""
        case .renameSet(let id): nameText = store.set(id)?.title ?? ""
        case .renameNote(let id): nameText = store.note(id)?.title ?? ""
        case .renameBoard(let id): nameText = store.board(id)?.title ?? ""
        }
        nameEdit = edit
    }

    private func commitName() {
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch nameEdit {
        case .newFolder(let parent): store.addFolder(name: name, parent: parent)
        case .renameFolder(let id): store.renameFolder(id, to: name)
        case .renameSet(let id): if !name.isEmpty { store.renameSet(id, to: name) }
        case .renameNote(let id): if !name.isEmpty { store.renameNote(id, to: name) }
        case .renameBoard(let id): if !name.isEmpty { store.renameBoard(id, to: name) }
        case nil: break
        }
        nameEdit = nil
    }

    /// 拖放：笔记、白板、题集或文件夹拖到某个文件夹上（nil 为最外层）
    private func drop(_ items: [String], into folderID: UUID?) -> Bool {
        var moved = false
        for item in items {
            guard let colon = item.firstIndex(of: ":"),
                  let id = UUID(uuidString: String(item[item.index(after: colon)...])) else { continue }
            switch item[..<colon] {
            case "set", "note", "board":
                store.moveItem(id, to: folderID)
                moved = true
            case "folder" where id != folderID:
                store.moveFolder(id, to: folderID)
                moved = true
            default:
                break
            }
        }
        return moved
    }
}

/// 侧边栏里各行要用到的操作（新建、重命名、删除、拖放、导出、导入）
struct SidebarActions {
    let edit: (SidebarView.NameEdit) -> Void
    let deleteFolder: (Folder) -> Void
    let deleteNote: (NoteDoc) -> Void
    let deleteBoard: (Whiteboard) -> Void
    let deleteSet: (QuestionSet) -> Void
    let drop: ([String], UUID?) -> Bool
    /// 把题集或笔记导出成 PDF
    let exportPDF: (SidebarView.PDFRequest) -> Void
    /// 导入题目（notes 为 false）或导入资料生成笔记，放到这个文件夹
    let importInto: (_ notes: Bool, _ folder: UUID?) -> Void
}

extension LibraryItem {
    var icon: String {
        switch self {
        case .set: return "doc.text"
        case .note: return "doc.richtext"
        case .board: return "rectangle.and.pencil.and.ellipsis"
        }
    }
}

extension FolderColor {
    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .cyan: return .cyan
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        // 系统的粉色太接近红色
        case .pink: return Color(red: 0.96, green: 0.45, blue: 0.68)
        case .gray: return .gray
        }
    }
}

extension FolderColor {
    /// 文件夹图标上的颜色：同一个色相，调淡、调灰了一些，排在一起不抢眼（系统的原色太艳）。
    /// 菜单里挑颜色的那排圆点还是用原色，好分辨
    var iconColor: Color {
        switch self {
        case .red: return Ink.adaptive(light: (0.80, 0.47, 0.44), dark: (0.78, 0.48, 0.46))
        case .orange: return Ink.adaptive(light: (0.84, 0.60, 0.40), dark: (0.80, 0.59, 0.42))
        case .yellow: return Ink.adaptive(light: (0.82, 0.70, 0.36), dark: (0.80, 0.70, 0.42))
        case .green: return Ink.adaptive(light: (0.47, 0.68, 0.50), dark: (0.48, 0.68, 0.52))
        case .teal: return Ink.adaptive(light: (0.42, 0.67, 0.66), dark: (0.44, 0.67, 0.66))
        case .cyan: return Ink.adaptive(light: (0.45, 0.68, 0.78), dark: (0.46, 0.67, 0.76))
        case .blue: return Ink.adaptive(light: (0.45, 0.60, 0.82), dark: (0.48, 0.62, 0.82))
        case .indigo: return Ink.adaptive(light: (0.54, 0.54, 0.80), dark: (0.57, 0.57, 0.82))
        case .purple: return Ink.adaptive(light: (0.68, 0.53, 0.78), dark: (0.69, 0.55, 0.79))
        case .pink: return Ink.adaptive(light: (0.84, 0.58, 0.68), dark: (0.80, 0.56, 0.66))
        case .gray: return Ink.adaptive(light: (0.62, 0.63, 0.66), dark: (0.56, 0.57, 0.60))
        }
    }
}

/// 资料库里的一条（文件夹、笔记、白板、题集、收藏都用它）：平铺在栏底色上，不给每一行铺颜色。
/// 文件夹的颜色只留在左边的小图标上；选中的一行是一块淡淡的圆角底色，拖东西到文件夹上时描一圈主色
struct LibraryBar<Content: View>: View {
    enum Symbol {
        /// 文件夹：一个纯色的文件夹图标，颜色是自己选的那个
        case folder(Color)
        /// 笔记、白板、题集的小图标
        case icon(String)
        /// 自己带颜色的图标（收藏的星）
        case tinted(String, Color)
    }

    let selected: Bool
    var targeted = false
    let symbol: Symbol
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Group {
                switch symbol {
                case .folder(let color):
                    Image(systemName: "folder.fill").foregroundStyle(color)
                case .icon(let name):
                    Image(systemName: name).foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                case .tinted(let name, let tint):
                    Image(systemName: name).foregroundStyle(tint)
                }
            }
            .font(.callout)
            .frame(width: 30)
            content()
                .padding(.leading, 4)
                .padding(.trailing, 10)
        }
        .padding(.leading, 4)
        .frame(minHeight: 40)
        .background(targeted ? Color.accentColor.opacity(0.12) : selected ? Color.primary.opacity(0.08) : Color.clear, in: shape)
        .overlay {
            if targeted { shape.strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5) }
        }
        .contentShape(shape)
    }
}

/// 一个文件夹：左边带颜色的文件夹图标，右边里面有几样东西和折叠箭头。点一下选中（右边排出里面的东西），点箭头展开 / 收起，按住出菜单
struct FolderBar: View {
    @EnvironmentObject var store: AppStore
    let folder: Folder
    let depth: Int
    /// 里面（包括子文件夹）一共几样东西
    let count: Int
    /// 正在看这个文件夹里的东西
    let selected: Bool
    let actions: SidebarActions
    @State private var targeted = false

    var body: some View {
        LibraryBar(selected: selected, targeted: targeted, symbol: .folder(folder.tint.iconColor)) {
            HStack(spacing: 6) {
                Text(folder.name)
                    .font(.body.weight(selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.callout.weight(selected ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(selected ? .primary : .secondary)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { store.setCollapsed(folder.id, !folder.collapsed) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(folder.collapsed ? -90 : 0))
                        .frame(width: 30, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(folder.collapsed ? L("展开") : L("收起"))
                .padding(.trailing, -8)
            }
        }
        .onTapGesture {
            store.browseFolder(folder.id)
            if folder.collapsed {
                withAnimation(.easeInOut(duration: 0.2)) { store.setCollapsed(folder.id, false) }
            }
        }
        .contextMenu { menuItems }
        .draggable("folder:\(folder.id.uuidString)") {
            Label(folder.name, systemImage: "folder.fill").padding(8)
        }
        .dropDestination(for: String.self) { items, _ in
            actions.drop(items, folder.id)
        } isTargeted: { targeted = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .listRowInsets(EdgeInsets(top: 1, leading: 10 + SidebarView.indent(depth), bottom: 1, trailing: 10))
    }

    @ViewBuilder
    private var menuItems: some View {
        Menu {
            Button("导入题目", systemImage: "doc.text") { actions.importInto(false, folder.id) }
            Button("导入资料生成笔记", systemImage: "doc.richtext") { actions.importInto(true, folder.id) }
            Button("新建白板", systemImage: "rectangle.and.pencil.and.ellipsis") { store.createBoard(in: folder.id) }
            Button("新建子文件夹", systemImage: "folder.badge.plus") { actions.edit(.newFolder(parent: folder.id)) }
        } label: {
            Label("在这里新建", systemImage: "plus")
        }
        Button("重命名", systemImage: "pencil") { actions.edit(.renameFolder(folder.id)) }
        // 菜单里一排只放得下 6 个颜色，分两排，每个颜色都看得见
        let colors = FolderColor.allCases
        colorRow(Array(colors.prefix(6))) { Text("颜色") }
        colorRow(Array(colors.dropFirst(6))) { EmptyView() }
        MoveMenu(excluding: folder.id, current: folder.parentID) { store.moveFolder(folder.id, to: $0) }
        Button("删除文件夹", systemImage: "trash", role: .destructive) { actions.deleteFolder(folder) }
    }

    private func colorRow(_ colors: [FolderColor], @ViewBuilder title: () -> some View) -> some View {
        Picker(selection: Binding(get: { folder.tint }, set: { store.setFolderColor(folder.id, $0) })) {
            ForEach(colors) { c in
                Label(c.title, systemImage: "circle.fill")
                    .tint(c.color)
                    .tag(c)
            }
        } label: {
            title()
        }
        .pickerStyle(.palette)
    }
}

/// 左侧的一块白板（条里面的内容；外面的条见 SidebarView.itemRow）
struct BoardRow: View {
    @EnvironmentObject var store: AppStore
    let board: Whiteboard
    let selected: Bool
    let actions: SidebarActions

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(board.title).font(.body.weight(selected ? .semibold : .medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if store.boardJobs[board.id] != nil {
                        ProgressView().controlSize(.mini)
                        Text("正在回复…")
                    } else {
                        Text(board.notes.isEmpty ? L("还没有便签") : String(localized: "\(board.notes.count) 张便签"))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("白板操作")
        }
        .padding(.vertical, 7)
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("重命名", systemImage: "pencil") { actions.edit(.renameBoard(board.id)) }
        MoveMenu(excluding: nil, current: store.folder(board.folderID)?.id) { store.moveItem(board.id, to: $0) }
        Button("删除", systemImage: "trash", role: .destructive) { actions.deleteBoard(board) }
    }
}

/// 左侧的一篇笔记
struct NoteRow: View {
    @EnvironmentObject var store: AppStore
    let doc: NoteDoc
    let selected: Bool
    let actions: SidebarActions

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title).font(.body.weight(selected ? .semibold : .medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if store.noteJobs[doc.id] != nil {
                        ProgressView().controlSize(.mini)
                        Text("正在生成…")
                    } else {
                        let exercises = doc.blocks.filter { $0.kind == .exercise }.count
                        Text(exercises > 0 ? String(localized: "\(doc.blocks.count) 块 · \(exercises) 道练习") : String(localized: "\(doc.blocks.count) 块"))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("笔记操作")
        }
        .padding(.vertical, 7)
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("重命名", systemImage: "pencil") { actions.edit(.renameNote(doc.id)) }
        // 和题集放在同一个文件夹：做这个文件夹里的题卡住时，会先引导去看这篇笔记
        MoveMenu(excluding: nil, current: store.folder(doc.folderID)?.id) { store.moveItem(doc.id, to: $0) }
        Button("导出 PDF…", systemImage: "doc.richtext") { actions.exportPDF(.init(notes: [doc.id])) }
        Button("删除", systemImage: "trash", role: .destructive) { actions.deleteNote(doc) }
    }
}

/// 左侧的一个题集
struct SetRow: View {
    @EnvironmentObject var store: AppStore
    let set: QuestionSet
    let selected: Bool
    let actions: SidebarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(set.title).font(.body.weight(selected ? .semibold : .medium)).lineLimit(2)
                Spacer(minLength: 4)
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .frame(width: 28, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("题集操作")
            }
            HStack {
                ProgressView(value: Double(set.doneCount), total: Double(max(set.questions.count, 1)))
                Text("\(set.doneCount)/\(set.questions.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 7)
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("重命名", systemImage: "pencil") { actions.edit(.renameSet(set.id)) }
        MoveMenu(excluding: nil, current: store.folder(set.folderID)?.id) { store.moveItem(set.id, to: $0) }
        Button("导出 PDF…", systemImage: "doc.richtext") { actions.exportPDF(.init(sets: [set.id])) }
        Button("删除", systemImage: "trash", role: .destructive) { actions.deleteSet(set) }
    }
}

/// “移到…”菜单：列出所有文件夹（按层级缩进）
struct MoveMenu: View {
    @EnvironmentObject var store: AppStore
    /// 移动文件夹时，不能移到它自己和它的子文件夹里
    let excluding: UUID?
    let current: UUID?
    let move: (UUID?) -> Void

    var body: some View {
        Menu {
            Button {
                move(nil)
            } label: {
                Label("最外层", systemImage: current == nil ? "checkmark" : "tray")
            }
            .disabled(current == nil)
            ForEach(store.folderTree().filter { excluding == nil || !store.isInside($0.folder.id, excluding!) }, id: \.folder.id) { item in
                Button {
                    move(item.folder.id)
                } label: {
                    Label(String(repeating: "    ", count: item.depth) + item.folder.name,
                          systemImage: current == item.folder.id ? "checkmark" : "folder")
                }
                .disabled(current == item.folder.id)
            }
        } label: {
            Label("移到…", systemImage: "folder")
        }
    }
}

struct QuestionListView: View {
    @EnvironmentObject var store: AppStore
    let setID: UUID

    var body: some View {
        let set = store.set(setID)
        // 自己管选中：系统的选中会把那一行的字变白
        List {
            if let set {
                Section {
                    ForEach(set.questions) { q in
                        HStack(alignment: .top, spacing: 10) {
                            StatusIcon(status: q.status)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("第 \(q.label) 题").font(.subheadline.weight(.semibold))
                                    if q.isStarred {
                                        Image(systemName: "star.fill").font(.caption).foregroundStyle(Ink.star)
                                    }
                                    if q.isGenerated {
                                        Text("变式").font(.caption).foregroundStyle(.secondary)
                                    }
                                    if store.isBusy(q.id) { ProgressView().controlSize(.mini) }
                                }
                                Text(Tutor.plainPreview(q.content)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedQuestionID = q.id }
                        .accessibilityAddTraits(.isButton)
                        .paneRow(q.id)
                    }
                } header: {
                    // 做对和看过答案分开数：只看了答案不算做对
                    if set.revealedCount == 0 {
                        Text("做对 \(set.passedCount) / \(set.questions.count)")
                    } else {
                        Text("做对 \(set.passedCount) · 看过答案 \(set.revealedCount) · 共 \(set.questions.count)")
                    }
                }
                .paneRows()
            }
        }
        .paneList(selection: store.selectedQuestionID)
        .navigationTitle(set?.title ?? "")
    }
}

struct StatusIcon: View {
    let status: QuestionStatus

    var body: some View {
        // 像在目录旁边用笔做的记号：没做的空着一个小圈，做对打勾，待订正画一支笔（不打叉，免得打击信心）
        Group {
            switch status {
            case .todo: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .wrong: Image(systemName: "pencil").foregroundStyle(Ink.red)
            case .passed: Image(systemName: "checkmark").foregroundStyle(Ink.green)
            case .revealed: Image(systemName: "eye").foregroundStyle(Ink.blue)
            }
        }
        .font(.callout.weight(.semibold))
        .frame(width: 18)
    }
}

/// 收藏：所有标记为重点错题的题目，按题集分组
struct MistakeBookView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let entries = store.starredEntries
        let groups = Dictionary(grouping: entries, by: \.setID)
        // 题集顺序按其中最新加入的错题排列
        let setOrder = entries.map(\.setID).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }

        // 自己管选中：系统的选中会把那一行的字变白
        List {
            ForEach(setOrder, id: \.self) { setID in
                Section {
                    ForEach(groups[setID] ?? [], id: \.question.id) { entry in
                        let q = entry.question
                        HStack(alignment: .top, spacing: 10) {
                            StatusIcon(status: q.status)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("第 \(q.label) 题").font(.subheadline.weight(.semibold))
                                    if store.isBusy(q.id) { ProgressView().controlSize(.mini) }
                                }
                                Text(Tutor.plainPreview(q.content)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectedQuestionID = q.id }
                        .accessibilityAddTraits(.isButton)
                        .paneRow(q.id)
                        .contextMenu {
                            Button("取消收藏", systemImage: "star.slash") { store.toggleStar(entry.setID, q.id) }
                        }
                    }
                } header: {
                    Text(store.set(setID)?.title ?? "")
                }
                .paneRows()
            }
        }
        .paneList(selection: store.selectedQuestionID)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("还没有收藏的题目", systemImage: "star")
                } description: {
                    Text("做题时点题目右上角的“收藏”，把想留着再看的题收进来。\n收藏的题会一直留着，直到你取消收藏。")
                }
            }
        }
        .navigationTitle("收藏")
    }
}

// MARK: - 左栏、中间栏的列表样式
//
// 左栏和中间栏自己排在页面旁边（不在系统分栏里），系统默认把列表画成一块块白卡片、带分隔线、选中是一整条深色。
// 这里换成平铺在栏底色上，没有分隔线，选中的一行画一块圆角底色

private struct PaneSelectionKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// 这一栏里选中的是哪一行
    var paneSelection: UUID? {
        get { self[PaneSelectionKey.self] }
        set { self[PaneSelectionKey.self] = newValue }
    }
}

extension View {
    /// 栏里的列表：平铺，底色由栏自己给
    func paneList(selection: UUID?) -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.paneSelection, selection)
    }

    /// 列表里的每一行：没有分隔线、没有白底（套在 List 里最外层的 Group / Section 上，对所有行生效）
    func paneRows() -> some View {
        listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// 能选中的一行：选中时画一块圆角底色（indent：左边空出多少，跟着资料库的层级缩进）
    func paneRow(_ id: UUID, tint: Color = Color.primary.opacity(0.08), indent: CGFloat = 0) -> some View {
        modifier(PaneRowBackground(id: id, tint: tint, indent: indent))
    }
}

private struct PaneRowBackground: ViewModifier {
    @Environment(\.paneSelection) private var selection
    let id: UUID
    let tint: Color
    let indent: CGFloat

    func body(content: Content) -> some View {
        content.listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selection == id ? tint : Color.clear)
                .padding(.leading, 10 + indent)
                .padding(.trailing, 10)
                .padding(.vertical, 2)
        )
    }
}
