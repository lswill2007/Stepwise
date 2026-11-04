import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @Binding var showImport: Bool
    @Binding var showNoteImport: Bool
    @Binding var showSettings: Bool

    /// 正在输入名字：新建文件夹、重命名文件夹或题集
    enum NameEdit: Identifiable {
        case newFolder(parent: UUID?)
        case renameFolder(UUID)
        case renameSet(UUID)
        case renameNote(UUID)
        var id: String {
            switch self {
            case .newFolder(let parent): return "new-\(parent?.uuidString ?? "root")"
            case .renameFolder(let id): return "folder-\(id)"
            case .renameSet(let id): return "set-\(id)"
            case .renameNote(let id): return "note-\(id)"
            }
        }
    }
    @State private var nameEdit: NameEdit?
    @State private var nameText = ""
    @State private var deletingFolder: Folder?
    @State private var deletingNote: NoteDoc?

    var body: some View {
        // 题集、错题本和笔记共用一个选中状态
        List(selection: Binding(get: { store.selectedNoteID ?? store.selectedSetID }, set: { id in
            if let id, store.note(id) != nil {
                store.selectNote(id)
                return
            }
            store.selectedNoteID = nil
            store.selectedSetID = id
            if id == AppStore.mistakeBookID {
                store.selectedQuestionID = store.starredEntries.first?.question.id
            } else {
                store.selectedQuestionID = store.set(id)?.questions.first(where: { !$0.status.isDone })?.id
                    ?? store.set(id)?.questions.first?.id
            }
        })) {
            if !store.questionSets.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(Ink.red)
                        Text("错题本").font(.headline)
                        Spacer()
                        let count = store.starredEntries.count
                        if count > 0 {
                            Text("\(count)")
                                .font(.callout).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .tag(AppStore.mistakeBookID)
                }
            }
            Section {
                ForEach(store.notes) { doc in
                    NoteRow(doc: doc, rename: { startEdit(.renameNote(doc.id)) }, delete: { deletingNote = doc })
                }
                Button {
                    showNoteImport = true
                } label: {
                    Label("导入资料生成笔记", systemImage: "doc.badge.plus")
                        .foregroundStyle(Color.accentColor)
                }
            } header: {
                Text("笔记")
            }
            Section {
                FolderContents(parent: nil, actions: actions)
                if !store.questionSets.isEmpty || !store.folders.isEmpty {
                    Button {
                        startEdit(.newFolder(parent: nil))
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            } header: {
                if !store.folders.isEmpty || !store.questionSets.isEmpty {
                    Text("题集")
                        // 拖到这里放回最外层
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, into: nil)
                        }
                }
            }
        }
        .overlay {
            if store.questionSets.isEmpty && store.folders.isEmpty && store.notes.isEmpty {
                ContentUnavailableView {
                    Label("还没有题目", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("导入 PDF、图片或文字，AI 会自动把每道题分开；也可以导入课件、讲义，生成预习和复习笔记")
                } actions: {
                    Button("导入题目") { showImport = true }.buttonStyle(.borderedProminent)
                    Button("导入资料生成笔记") { showNoteImport = true }
                }
            }
        }
        .navigationTitle("题集")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("导入题目", systemImage: "doc.text") { showImport = true }
                    Button("导入资料生成笔记", systemImage: "doc.richtext") { showNoteImport = true }
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
            Text("里面的题集和子文件夹会移到上一级，不会删除任何题目。")
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
    }

    private var actions: SidebarActions {
        SidebarActions(edit: startEdit, deleteFolder: { deletingFolder = $0 }, drop: drop)
    }

    private var alertTitle: String {
        switch nameEdit {
        case .newFolder(let parent): return parent == nil ? "新建文件夹" : "新建子文件夹"
        case .renameFolder: return "重命名文件夹"
        case .renameSet: return "重命名题集"
        case .renameNote: return "重命名笔记"
        case nil: return ""
        }
    }

    private func startEdit(_ edit: NameEdit) {
        switch edit {
        case .newFolder: nameText = ""
        case .renameFolder(let id): nameText = store.folder(id)?.name ?? ""
        case .renameSet(let id): nameText = store.set(id)?.title ?? ""
        case .renameNote(let id): nameText = store.note(id)?.title ?? ""
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
        case nil: break
        }
        nameEdit = nil
    }

    /// 拖放：题集或文件夹拖到某个文件夹上（nil 为最外层）
    private func drop(_ items: [String], into folderID: UUID?) -> Bool {
        var moved = false
        for item in items {
            if item.hasPrefix("set:"), let id = UUID(uuidString: String(item.dropFirst(4))) {
                store.moveSet(id, to: folderID)
                moved = true
            } else if item.hasPrefix("folder:"), let id = UUID(uuidString: String(item.dropFirst(7))), id != folderID {
                store.moveFolder(id, to: folderID)
                moved = true
            }
        }
        return moved
    }
}

/// 侧边栏里各行要用到的操作（新建、重命名、删除、拖放）
struct SidebarActions {
    let edit: (SidebarView.NameEdit) -> Void
    let deleteFolder: (Folder) -> Void
    let drop: ([String], UUID?) -> Bool
}

/// 一个文件夹（或最外层）里的内容：子文件夹在前，题集在后
struct FolderContents: View {
    @EnvironmentObject var store: AppStore
    let parent: UUID?
    let actions: SidebarActions

    var body: some View {
        ForEach(store.childFolders(of: parent)) { folder in
            FolderNode(folder: folder, actions: actions)
        }
        ForEach(store.sets(in: parent)) { set in
            SetRow(set: set, actions: actions)
        }
        .onDelete { offsets in
            let ids = offsets.map { store.sets(in: parent)[$0].id }
            ids.forEach(store.deleteSet)
        }
    }
}

struct FolderNode: View {
    @EnvironmentObject var store: AppStore
    let folder: Folder
    let actions: SidebarActions
    @State private var targeted = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { !(store.folder(folder.id)?.collapsed ?? false) },
                                            set: { store.setCollapsed(folder.id, !$0) })) {
            FolderContents(parent: folder.id, actions: actions)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: targeted ? "folder.badge.plus" : "folder")
                    .foregroundStyle(.secondary)
                Text(folder.name).font(.headline).lineLimit(1)
                Spacer()
                let count = store.setCount(inTree: folder.id)
                if count > 0 {
                    Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("文件夹操作")
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            // 点文件夹名展开 / 收起
            .onTapGesture {
                withAnimation { store.setCollapsed(folder.id, !(store.folder(folder.id)?.collapsed ?? false)) }
            }
            .draggable("folder:\(folder.id.uuidString)") {
                Label(folder.name, systemImage: "folder.fill").padding(8)
            }
            .dropDestination(for: String.self) { items, _ in
                actions.drop(items, folder.id)
            } isTargeted: { targeted = $0 }
            .contextMenu { menuItems }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("新建子文件夹", systemImage: "folder.badge.plus") { actions.edit(.newFolder(parent: folder.id)) }
        Button("重命名", systemImage: "pencil") { actions.edit(.renameFolder(folder.id)) }
        MoveMenu(excluding: folder.id, current: folder.parentID) { store.moveFolder(folder.id, to: $0) }
        Button("删除文件夹", systemImage: "trash", role: .destructive) { actions.deleteFolder(folder) }
    }
}

/// 左侧的一篇笔记
struct NoteRow: View {
    @EnvironmentObject var store: AppStore
    let doc: NoteDoc
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    if store.noteJobs[doc.id] != nil {
                        ProgressView().controlSize(.mini)
                        Text("正在生成…")
                    } else {
                        let exercises = doc.blocks.filter { $0.kind == .exercise }.count
                        Text(exercises > 0 ? "\(doc.blocks.count) 块 · \(exercises) 道练习" : "\(doc.blocks.count) 块")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("笔记操作")
        }
        .padding(.vertical, 4)
        .tag(doc.id)
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("重命名", systemImage: "pencil", action: rename)
        Button("删除", systemImage: "trash", role: .destructive, action: delete)
    }
}

struct SetRow: View {
    @EnvironmentObject var store: AppStore
    let set: QuestionSet
    let actions: SidebarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(set.title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
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
        .padding(.vertical, 4)
        .tag(set.id)
        .draggable("set:\(set.id.uuidString)") {
            Label(set.title, systemImage: "doc.text").padding(8)
        }
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("重命名", systemImage: "pencil") { actions.edit(.renameSet(set.id)) }
        MoveMenu(excluding: nil, current: set.folderID) { store.moveSet(set.id, to: $0) }
        Button("删除", systemImage: "trash", role: .destructive) { store.deleteSet(set.id) }
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
        List(selection: $store.selectedQuestionID) {
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
                                        Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(Ink.red)
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
                        .tag(q.id)
                    }
                } header: {
                    Text("已完成 \(set.doneCount) / \(set.questions.count)")
                }
            }
        }
        .navigationTitle(set?.title ?? "")
    }
}

struct StatusIcon: View {
    let status: QuestionStatus

    var body: some View {
        // 像在目录旁边用笔做的记号：没做的空着一个小圈，做对打勾，做错打叉
        Group {
            switch status {
            case .todo: Image(systemName: "circle").foregroundStyle(.tertiary)
            case .wrong: Image(systemName: "xmark").foregroundStyle(Ink.red)
            case .passed: Image(systemName: "checkmark").foregroundStyle(Ink.green)
            case .revealed: Image(systemName: "eye").foregroundStyle(Ink.blue)
            }
        }
        .font(.callout.weight(.semibold))
        .frame(width: 18)
    }
}

/// 错题本：所有标记为重点错题的题目，按题集分组
struct MistakeBookView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let entries = store.starredEntries
        let groups = Dictionary(grouping: entries, by: \.setID)
        // 题集顺序按其中最新加入的错题排列
        let setOrder = entries.map(\.setID).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }

        List(selection: $store.selectedQuestionID) {
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
                                    if let rounds = q.reviewRounds {
                                        Text(rounds == 0 ? "复习中" : "复习中 · 已用 \(rounds) 轮")
                                            .font(.caption).foregroundStyle(Ink.red)
                                    }
                                    if store.isBusy(q.id) { ProgressView().controlSize(.mini) }
                                }
                                Text(Tutor.plainPreview(q.content)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(q.id)
                        .contextMenu {
                            Button("移出错题本", systemImage: "bookmark.slash") { store.toggleStar(entry.setID, q.id) }
                        }
                    }
                } header: {
                    Text(store.set(setID)?.title ?? "")
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("错题本是空的", systemImage: "bookmark")
                } description: {
                    Text("做题时点题目右上角的“错题”，把需要重点复习的题加进来。\n在错题本里 \(AppStore.masteryRounds) 轮之内做对，就会自动移出。")
                }
            }
        }
        .navigationTitle("错题本")
    }
}
