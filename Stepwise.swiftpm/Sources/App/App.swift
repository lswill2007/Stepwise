import SwiftUI

@main
struct StepwiseApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
        // 退到后台时立即保存题库，避免被系统关闭时丢失最后的改动
        .onChange(of: scenePhase) {
            if scenePhase != .active { store.saveNow() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var showImport = false
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $store.columnVisibility) {
            SidebarView(showImport: $showImport, showSettings: $showSettings)
        } content: {
            if store.isMistakeBook {
                MistakeBookView()
            } else if let setID = store.selectedSetID, store.set(setID) != nil {
                QuestionListView(setID: setID)
            } else {
                ContentUnavailableView("选择或导入题集", systemImage: "tray",
                                       description: Text("在左侧选择一个题集，或点击 + 导入题目文件"))
            }
        } detail: {
            // 错题本里的题来自不同题集，按题目找到它所在的题集
            if let qID = store.selectedQuestionID,
               let setID = store.isMistakeBook ? store.setID(containing: qID) : store.selectedSetID,
               store.question(setID, qID) != nil {
                QuestionDetailView(setID: setID, qID: qID, fromMistakeBook: store.isMistakeBook)
                    // 同一道题从错题本和从题集打开是两种模式，要重新创建页面
                    .id("\(qID)-\(store.isMistakeBook)")
            } else {
                ContentUnavailableView("选择一道题开始", systemImage: "pencil.and.list.clipboard")
            }
        }
        .sheet(isPresented: $showImport) {
            ImportView()
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
