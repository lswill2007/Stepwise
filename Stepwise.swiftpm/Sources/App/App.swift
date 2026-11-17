import SwiftUI

@main
struct StepwiseApp: App {
    init() {
        // 公式排版用的 WebKit 和 KaTeX 最慢，一启动就在后台准备
        MathAssets.prewarm()
    }
    @StateObject private var store = AppStore()
    @StateObject private var tracker = StudyTracker()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(tracker)
                // 一分钟内有操作就算学习时间
                .background(ActivityDetector { tracker.touch() })
                .onAppear { tracker.start() }
        }
        // 退到后台时立即保存题库，避免被系统关闭时丢失最后的改动
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                // 先存学习时间，store.saveNow 会把它一起写进储存文件夹
                tracker.save()
                store.saveNow()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage("clockEnabled") private var clockEnabled = false
    @State private var showImport = false
    @State private var showNoteImport = false
    @State private var showSettings = false

    var body: some View {
        if store.isLoaded {
            main
        } else {
            LaunchPlaceholder()
        }
    }

    private var sidebar: some View {
        SidebarView(showImport: $showImport, showNoteImport: $showNoteImport, showSettings: $showSettings)
    }

    /// 打开了题集、错题本或笔记（中间一栏有东西可显示）
    private var hasList: Bool {
        if let noteID = store.selectedNoteID, store.note(noteID) != nil { return true }
        return store.isMistakeBook || store.set(store.selectedSetID) != nil
    }

    @ViewBuilder
    private var columns: some View {
        if let boardID = store.selectedBoardID, store.board(boardID) != nil {
            // 白板只要左栏和画布两栏，书写的地方大一些；纸的样式在右上角选
            NavigationSplitView(columnVisibility: $store.columnVisibility) {
                sidebar
            } detail: {
                WhiteboardView(boardID: boardID)
                    .id(boardID)
            }
        } else if store.listHidden && hasList {
            // 中间的白色栏拽到左边收起来了：只留左栏和页面
            NavigationSplitView(columnVisibility: $store.columnVisibility) {
                sidebar
            } detail: {
                detail
                    .overlay(alignment: .leading) { showListEdge }
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                setListHidden(false)
                            } label: {
                                Label("显示列表", systemImage: "list.bullet.indent")
                            }
                        }
                    }
            }
        } else {
            NavigationSplitView(columnVisibility: $store.columnVisibility) {
                sidebar
            } content: {
                list
                    // 向左拽：收起这一栏，页面变宽
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24).onEnded { value in
                            let t = value.translation
                            if hasList, t.width < -70, abs(t.width) > abs(t.height) * 1.5 { setListHidden(true) }
                        }
                    )
            } detail: {
                detail
            }
        }
    }

    private func setListHidden(_ hidden: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { store.listHidden = hidden }
    }

    /// 收起中间一栏后，页面最左边一窄条：向右拽把它拉回来（全屏时不管）
    @ViewBuilder
    private var showListEdge: some View {
        if store.columnVisibility != .detailOnly {
            Color.clear
                .frame(width: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12).onEnded { value in
                        if value.translation.width > 50 { setListHidden(false) }
                    }
                )
        }
    }

    /// 中间一栏：题目列表、错题本或笔记目录
    @ViewBuilder
    private var list: some View {
        if let noteID = store.selectedNoteID, store.note(noteID) != nil {
            NoteOutlineView(noteID: noteID)
        } else if store.isMistakeBook {
            MistakeBookView()
        } else if let setID = store.selectedSetID, store.set(setID) != nil {
            QuestionListView(setID: setID)
        } else {
            ContentUnavailableView("选择或导入题集", systemImage: "tray",
                                   description: Text("在左侧选择一个题集，或点击 + 导入题目文件"))
        }
    }

    /// 右边的页面：整个题集（或错题本）是一本笔记本，中间的题目列表当目录用
    @ViewBuilder
    private var detail: some View {
        if let noteID = store.selectedNoteID, store.note(noteID) != nil {
            NoteDocView(noteID: noteID)
                .id(noteID)
        } else if store.isMistakeBook {
            NotebookView(setID: nil)
                .id(AppStore.mistakeBookID)
        } else if let setID = store.selectedSetID, store.set(setID) != nil {
            NotebookView(setID: setID)
                .id(setID)
        } else {
            ContentUnavailableView("选择一个题集开始", systemImage: "pencil.and.list.clipboard")
        }
    }

    private var main: some View {
        columns
        // 时钟浮在所有页面上面
        .overlay {
            if clockEnabled { FloatingClock() }
        }
        .sheet(isPresented: $showImport) {
            ImportView()
        }
        .sheet(isPresented: $showNoteImport) {
            NoteImportView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $store.showConsent, onDismiss: {
            // 同意后如果还没有填写任何 Key，接着引导去设置
            if store.aiConsent == true && !store.providers.contains(where: \.hasKey) { showSettings = true }
        }) {
            ConsentView()
        }
        .alert("出错了", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onAppear {
            if store.aiConsent == nil {
                // 第一次打开：先说明数据会发送到哪里
                store.showConsent = true
            } else if !store.providers.contains(where: \.hasKey) {
                // 还没有任何 Key 时，直接引导去设置
                showSettings = true
            }
        }
    }
}

/// 启动时数据还在后台读：先显示空白页，读得慢（例如 iCloud 正在下载）时才转圈
private struct LaunchPlaceholder: View {
    @State private var showSpinner = false

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            if showSpinner {
                ProgressView("正在打开…")
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            showSpinner = true
        }
    }
}
