import SwiftUI

@main
struct StepwiseApp: App {
    init() {
        // 这里什么慢的都不做，让加载页尽快出来：
        // 公式排版用的 WebKit 等加载页画出来再准备（见 LaunchCover），模型价格等第一页揭开后再加载（见 RootView.reveal）
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
                // 双击任何能打字的地方，弹出屏幕键盘（刚用过笔、接着硬件键盘时系统不会自己弹）
                .background(KeyboardSummoner())
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
    /// 宽屏三栏这会儿的总宽度（见 sideBySide）
    @State private var layoutWidth: CGFloat = 0
    /// 浮着的中间栏收起来了（只在 listFloats 时用，不改用户自己收起中间栏的选择 listHidden）
    @State private var listTucked = true
    /// 笔记全屏时点左上角“目录”拉出来的目录（浮在页面上，页面不让位）
    @State private var fullScreenOutline = false
    @State private var showImport = false
    @State private var showNoteImport = false
    @State private var showSettings = false
    /// 第一次打开：请用户选“我的 iPad”，数据存在那里的 Stepwise Files
    @State private var showFolderPrompt = false
    /// 第一页已经排好、能点了：加载页淡出
    @State private var ready = false
    @State private var coverGone = false

    var body: some View {
        ZStack {
            // 数据读完就在加载页下面开始排第一页（左栏、目录、题目），排好了加载页再淡出。
            // 不排好就揭开的话，看到的是一页没排完、点了没反应的界面
            if store.isLoaded {
                main
            }
            if !coverGone {
                LaunchCover(readingFolder: !store.isLoaded && DataLocation.isCustom)
                    .opacity(ready ? 0 : 1)
                    .allowsHitTesting(!ready)
                    .zIndex(1)
            }
        }
        // 万一第一页一直没报“排好了”，读完数据 3 秒后也揭开
        .task(id: store.isLoaded) {
            guard store.isLoaded else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            reveal()
        }
    }

    /// 揭开加载页；之后才弹出同意说明、引导去填 Key，免得弹窗盖在加载页上
    private func reveal() {
        guard !ready else { return }
        withAnimation(.easeOut(duration: 0.3)) { ready = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { coverGone = true }
        // 每次打开 App 都重新加载各家官网的模型价格（没网时用上次存的）。第一页用不到，等揭开后在后台做：
        // 读上次存的价格表要解析几百 KB 的 JSON，刚开机冷启动时要大半秒，和打开 App 抢时间
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            OnlinePrices.shared.refreshOnLaunch()
        }
        if DataLocation.shouldPromptForFolder {
            // 第一次打开：先定好数据存在哪里（重装后选回同一个文件夹，API Key 和设置也一起回来）
            showFolderPrompt = true
        } else {
            continueOnboarding()
        }
    }

    /// 选好储存位置之后：第一次打开先说明数据会发送到哪里，还没有 Key 时引导去设置
    private func continueOnboarding() {
        if store.aiConsent == nil {
            // 第一次打开：先说明数据会发送到哪里
            store.showConsent = true
        } else if !store.providers.contains(where: \.hasKey) {
            // 还没有任何 Key 时，直接引导去设置
            showSettings = true
        }
    }

    private var sidebar: some View {
        SidebarView(showImport: $showImport, showNoteImport: $showNoteImport, showSettings: $showSettings)
    }

    /// 打开了题集、收藏或笔记（中间一栏有东西可显示）
    private var hasList: Bool {
        if let noteID = store.selectedNoteID, store.note(noteID) != nil { return true }
        return store.isMistakeBook || store.set(store.selectedSetID) != nil
    }

    // MARK: 分栏
    //
    // 宽屏不用系统的 NavigationSplitView：它在新系统上把左栏做成浮在页面上的玻璃板，
    // 从收起（全屏）拉出左栏时页面不让位、也不重新排版，中间栏被压在左栏下面、字从左栏透出来，页面右边被挤出屏幕。
    // 现在自己排三栏：左栏 | 中间栏 | 页面，一个挨一个，谁收起谁就滑走，旁边的跟着变宽。
    // 竖屏放不下三栏时左栏和中间栏只露一个（isNarrow）；连中间栏和页面都放不下时中间栏浮在页面上（listFloats）。
    // 窄屏（分屏多任务）还用系统的，会自动叠成一层层推进去

    /// 左栏的宽度
    private let sidebarWidth: CGFloat = 280

    /// 导航栏左右两边（Mac 上只用于编译检查）
    #if os(iOS)
    private static let leading: ToolbarItemPlacement = .topBarLeading
    private static let trailing: ToolbarItemPlacement = .topBarTrailing
    #else
    private static let leading: ToolbarItemPlacement = .navigation
    private static let trailing: ToolbarItemPlacement = .primaryAction
    #endif

    @ViewBuilder
    private var columns: some View {
        if sizeClass == .compact {
            if let boardID = store.selectedBoardID, store.board(boardID) != nil {
                NavigationSplitView(columnVisibility: $store.columnVisibility) {
                    sidebar
                } detail: {
                    WhiteboardView(boardID: boardID)
                        .id(boardID)
                }
            } else {
                NavigationSplitView(columnVisibility: $store.columnVisibility) {
                    sidebar
                } content: {
                    list
                } detail: {
                    detail
                }
            }
        } else {
            sideBySide
        }
    }

    /// 宽屏：左栏和页面并排。左栏收起时滑出去，页面跟着变宽；页面一直是同一个，不会重建。
    /// 左栏收起时也不拿掉，只是推到屏幕外面：拿掉再放回来要重建整个左栏（导航栏、列表、每一行的进度条），
    /// 拉出来的那一下就卡住，滑得一顿一顿的
    private var sideBySide: some View {
        let hidden = store.sidebarHidden
        return HStack(spacing: 0) {
            NavigationStack {
                sidebar
                    #if os(iOS)
                    .toolbarTitleDisplayMode(.inlineLarge)
                    #endif
                    .background(Ink.sidebar)
                    .toolbar {
                        ToolbarItem(placement: Self.trailing) {
                            Button {
                                setSidebarHidden(true)
                            } label: {
                                Label("收起左栏", systemImage: "sidebar.left")
                            }
                        }
                    }
            }
            .frame(width: sidebarWidth)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Ink.separator).frame(width: 0.5).ignoresSafeArea()
            }
            // 向左拽：收起左栏
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    if isLeftSwipe(value) { setSidebarHidden(true) }
                }
            )
            // 外面再套一层：收起时这一层变窄到 0（里面的左栏一直按 280 排，不跟着重排），靠右对齐，
            // 左栏就整个推到屏幕左边外面，看起来是往左滑出去
            .frame(width: hidden ? 0 : sidebarWidth, alignment: .trailing)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            NavigationStack {
                Group {
                    if let boardID = store.selectedBoardID, store.board(boardID) != nil {
                        // 白板只要左栏和画布两栏，书写的地方大一些；纸的样式在右上角选。
                        // 左栏收起后从最左边向右拽拉回来：白板自己用只认手指的边缘手势做（见 BoardCanvas），
                        // 不在上面盖一条透明的条，否则笔从最左边落下会被挡住
                        WhiteboardView(boardID: boardID)
                            .id(boardID)
                    } else {
                        listAndPage
                    }
                }
                .toolbar {
                    // 还没打开题集、笔记（没有目录）而左栏收着：左上角放回左栏。
                    // 打开了的话左上角是“目录”，目录拉出来以后它的左上角才是“资料库”（见 listAndPage）
                    if store.sidebarHidden && !store.isFullScreen && store.selectedBoardID == nil && !hasList {
                        ToolbarItem(placement: Self.leading) {
                            Button {
                                setSidebarHidden(false)
                            } label: {
                                Label("显示左栏", systemImage: "sidebar.left")
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { layoutWidth = $0 }
        // 屏幕窄时在左栏点开题集、笔记、收藏：左栏让开，露出目录和页面
        .onChange(of: store.selectedSetID) { collapseSidebarIfNarrow() }
        .onChange(of: store.selectedNoteID) { collapseSidebarIfNarrow() }
        // 浮着的中间栏里点了一道题、笔记目录里点了一节：收起来，露出整页
        .onChange(of: store.selectedQuestionID) { hideFloatingList() }
        // 看传进来的新值：笔记页翻过去后马上把 noteJump 清掉，这里再读 store 时可能已经是 nil
        .onChange(of: store.noteJump) { _, jump in if jump != nil { hideFloatingList() } }
    }

    /// 页面至少要这么宽，题目和手写区才排得开
    private let minPageWidth: CGFloat = 480

    /// 左栏、中间栏、页面三个并排放不下（竖着拿的 iPad mini、iPad、11 英寸 Air / Pro，13 英寸竖屏也算）：
    /// 这时左栏和中间栏只露一个，左栏开着时中间栏先让开
    private var isNarrow: Bool {
        layoutWidth > 0 && layoutWidth < sidebarWidth + listWidth + minPageWidth
    }

    /// 中间栏因为屏幕窄、左栏开着，暂时让开了（不改用户自己收起中间栏的选择）
    private var listYieldsToSidebar: Bool { isNarrow && !store.sidebarHidden }

    /// 中间栏和页面并排也放不下（竖着拿的 iPad mini）：中间栏浮在页面上，页面不让位，选了题就收起
    private var listFloats: Bool { isNarrow && layoutWidth - listWidth < minPageWidth }

    private func hideFloatingList() {
        guard listOverlays, listShown else { return }
        hideList()
    }

    private func collapseSidebarIfNarrow() {
        guard isNarrow, !store.sidebarHidden, !store.isFullScreen, hasList else { return }
        // 中间栏浮在页面上时（iPad mini 竖屏）不弹出来：打开题集会翻到第一道没做完的题，直接露出整页
        setSidebarHidden(true)
    }

    /// 把中间栏拉出来；屏幕窄时左栏一起收起，给中间栏让位
    private func showList() {
        if store.isFullScreen {
            listDrag = 0
            withAnimation(.snappy(duration: 0.28)) { fullScreenOutline = true }
            return
        }
        if listYieldsToSidebar { setSidebarHidden(true) }
        if listFloats {
            listDrag = 0
            withAnimation(.snappy(duration: 0.28)) { listTucked = false }
        } else {
            setListHidden(false)
        }
    }

    /// 收起中间栏：浮着的只是暂时收起，并排的记住用户的选择
    private func hideList() {
        if store.isFullScreen {
            withAnimation(.snappy(duration: 0.28)) { fullScreenOutline = false }
        } else if listFloats {
            withAnimation(.snappy(duration: 0.28)) { listTucked = true }
        } else {
            setListHidden(true)
        }
    }

    private func setSidebarHidden(_ hidden: Bool) {
        // 白板只有左栏和画布：收起左栏就是全屏
        if store.selectedBoardID != nil {
            store.setFullScreen(hidden)
            return
        }
        store.holdPageWidth()
        withAnimation(.snappy(duration: 0.28)) {
            store.columnVisibility = hidden ? .detailOnly : .all
        }
    }

    /// 中间栏的宽度
    private let listWidth: CGFloat = 340

    /// 中间栏这会儿露在外面（全屏做题时和左栏一起藏起来；笔记全屏时点左上角“目录”浮出来）
    private var listShown: Bool {
        guard hasList else { return false }
        if store.isFullScreen { return fullScreenOutline }
        guard !listYieldsToSidebar else { return false }
        return listFloats ? !listTucked : !store.listHidden
    }

    /// 中间栏浮在页面上（页面不让位）：iPad mini 竖屏，或者全屏时拉出来的笔记目录
    private var listOverlays: Bool { listFloats || store.isFullScreen }

    private var listAndPage: some View {
        ZStack(alignment: .leading) {
            detail
                // 栏正在滑：页面保持原来的宽度整块挪，滑完再排成新的宽度（见 AppStore.holdPageWidth）
                .frame(width: store.frozenPageWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if store.frozenPageWidth == nil { store.pageWidth = width }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, listShown && !listOverlays ? listWidth : 0)
                // 收起后，从页面最左边向右拽拉回来
                .overlay(alignment: .leading) {
                    if hasList && !listShown && !store.isFullScreen { edgePull { showList() } }
                }
            // 中间栏浮在页面上时，点页面空白处收起
            if listShown && listOverlays {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { hideList() }
                    .transition(.opacity)
            }
            // 收起时也留着，挪到屏幕外面：拿掉再放回来要重建整个目录，拉出来时会卡一下
            if hasList {
                list
                    .frame(width: listWidth)
                    .background(Ink.systemBackground)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Ink.separator).frame(width: 0.5)
                    }
                    .shadow(color: .black.opacity(listShown && listOverlays ? 0.15 : 0), radius: 12)
                    .offset(x: listShown ? listDrag : -listWidth - 1)
                    // 向左拽：栏跟着手指走，松手拽够了就收起，不够就弹回去
                    .simultaneousGesture(listSwipe)
                    .allowsHitTesting(listShown)
                    .accessibilityHidden(!listShown)
                    .transition(.move(edge: .leading))
            }
        }
        // 栏被手指拽开时，露出来的是纸色，不是一条灰缝
        .background(Ink.paper)
        // 左上角一层一层往外拉：页面左上角是“目录”，拉出目录以后目录的左上角是“资料库”（左栏）。
        // 全屏时也一样，目录浮在页面上；点“资料库”就退出全屏、放回左栏
        .toolbar {
            if hasList && listShown && store.sidebarHidden {
                ToolbarItem(placement: .navigation) {
                    Button {
                        setSidebarHidden(false)
                    } label: {
                        Label("资料库", systemImage: "sidebar.left")
                    }
                }
            }
            if hasList {
                ToolbarItem(placement: .navigation) {
                    Button {
                        if listShown { hideList() } else { showList() }
                    } label: {
                        Label(listShown ? L("收起目录") : L("目录"), systemImage: "list.bullet.indent")
                    }
                }
            }
        }
        // 退出全屏、换了笔记：全屏时拉出来的目录收起
        .onChange(of: store.isFullScreen) { fullScreenOutline = false }
        .onChange(of: store.selectedNoteID) { fullScreenOutline = false }
        .onChange(of: store.selectedSetID) { fullScreenOutline = false }
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
                    hideList()
                } else {
                    withAnimation(.snappy(duration: 0.25)) { listDrag = 0 }
                }
            }
    }

    private func setListHidden(_ hidden: Bool) {
        if !hidden { listDrag = 0 }
        store.holdPageWidth()
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

    /// 中间一栏：题目列表、收藏或笔记目录
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

    /// 右边的页面：整个题集（或收藏）是一本笔记本，中间的题目列表当目录用
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
            // 没有打开东西：左栏里点中的文件夹（没点就是最外层）里的东西一格一格排开
            LibraryGridView()
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
        .sheet(isPresented: $showFolderPrompt, onDismiss: {
            DataLocation.markPrompted()
            continueOnboarding()
        }) {
            FolderPromptView()
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
            // 第一页排完、画出来之后主线程才空下来。再多等一轮：页面自己也在下一轮翻到上次那道题（见 NotebookView），
            // 等它翻完再揭开，淡出时页面不会再排版、跳动
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    reveal()
                }
            }
        }
    }
}
