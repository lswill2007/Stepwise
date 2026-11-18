import SwiftUI

@main
struct StepwiseApp: App {
    init() {
        // 公式排版用的 WebKit 和 KaTeX 最慢，一启动就在后台准备
        MathAssets.prewarm()
        // 每次打开 App 都重新加载各家官网的模型价格（没网时用上次存的）
        OnlinePrices.shared.refreshOnLaunch()
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
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// 手指向左拽中间栏时它跟着走的距离（≤ 0）
    @State private var listDrag: CGFloat = 0
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
                    // 向左拽：收起左栏，整个屏幕都是白板
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 24).onEnded { value in
                            if isLeftSwipe(value) { store.setFullScreen(true) }
                        }
                    )
            } detail: {
                WhiteboardView(boardID: boardID)
                    .id(boardID)
                    // 左栏收起后，从最左边向右拽拉回来
                    .overlay(alignment: .leading) {
                        if store.isFullScreen { edgePull { store.setFullScreen(false) } }
                    }
            }
        } else if sizeClass == .compact {
            // 窄屏（分屏多任务）：用系统的三栏，会自动叠成一层层推进去
            NavigationSplitView(columnVisibility: $store.columnVisibility) {
                sidebar
            } content: {
                list
            } detail: {
                detail
            }
        } else {
            // 中间栏和页面放在同一栏里：收起 / 拉回只是把中间栏滑走 / 滑回来，
            // 页面一直是同一个，不会因为换布局整页重建（以前就是这样卡住、还跳回第一题）
            NavigationSplitView(columnVisibility: $store.columnVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(280)
            } detail: {
                listAndPage
            }
        }
    }

    /// 中间栏的宽度
    private let listWidth: CGFloat = 340

    /// 中间栏这会儿露在外面（全屏做题时和左栏一起藏起来）
    private var listShown: Bool { hasList && !store.listHidden && !store.isFullScreen }

    private var listAndPage: some View {
        ZStack(alignment: .leading) {
            detail
                .padding(.leading, listShown ? listWidth : 0)
                // 收起后，从页面最左边向右拽拉回来
                .overlay(alignment: .leading) {
                    if hasList && store.listHidden && !store.isFullScreen { edgePull { setListHidden(false) } }
                }
            if listShown {
                list
                    // 和原来系统中间栏一样：白底、选中是圆角灰条
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .frame(width: listWidth)
                    .background(Color(.systemBackground))
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color(.separator)).frame(width: 0.5)
                    }
                    .offset(x: listDrag)
                    // 向左拽：栏跟着手指走，松手拽够了就收起，不够就弹回去
                    .simultaneousGesture(listSwipe)
                    .transition(.move(edge: .leading))
            }
        }
        // 栏被手指拽开时，露出来的是纸色，不是一条灰缝
        .background(Ink.paper)
        .toolbar {
            if hasList && store.listHidden && !store.isFullScreen {
                ToolbarItem(placement: .navigation) {
                    Button {
                        setListHidden(false)
                    } label: {
                        Label("显示列表", systemImage: "list.bullet.indent")
                    }
                }
            }
        }
    }

    private var listSwipe: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let t = value.translation
                // 只认横着往左拽；上下滑是在翻列表
                if listDrag != 0 || (t.width < 0 && abs(t.width) > abs(t.height) * 1.5) {
                    listDrag = min(0, t.width)
                }
            }
            .onEnded { value in
                guard listDrag != 0 else { return }
                let flung = value.predictedEndTranslation.width < -listWidth / 2
                if listDrag < -listWidth / 3 || flung {
                    setListHidden(true)
                } else {
                    withAnimation(.snappy(duration: 0.25)) { listDrag = 0 }
                }
            }
    }

    private func setListHidden(_ hidden: Bool) {
        if !hidden { listDrag = 0 }
        withAnimation(.snappy(duration: 0.28)) { store.listHidden = hidden }
    }

    /// 横着向左拽了一段
    private func isLeftSwipe(_ value: DragGesture.Value) -> Bool {
        let t = value.translation
        return t.width < -70 && abs(t.width) > abs(t.height) * 1.5
    }

    /// 页面最左边一窄条：向右拽一段就执行 action（把收起的栏拉回来）
    private func edgePull(_ action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12).onEnded { value in
                    if value.translation.width > 50 { action() }
                }
            )
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
