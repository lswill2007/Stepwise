import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var showConsent = false
    @State private var showImporter = false
    /// 设置页只放一个文件选择器：同一个页面上有两个 .fileImporter 时，较早的 iOS 只认一个，另一个按钮点了没反应
    @State private var importerKind: ImporterKind = .backup
    /// 选好的储存文件夹，交给“文件储存位置”那一节处理
    @State private var folderPick: FolderPick?

    enum ImporterKind { case backup, folder }
    @State private var importMessage: String?
    @AppStorage("clockEnabled") private var clockEnabled = false
    @AppStorage("clockScale") private var clockScale: Double = 1

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    StudySummaryRow()
                    NavigationLink {
                        StudyLogView()
                    } label: {
                        Label("学习日志和周报", systemImage: "chart.bar")
                    }
                } footer: {
                    Text("一分钟内有操作（写字、翻页、点按）的时间算作学习，停下来不动的时间不算。记在本机；选了文件储存位置时也存一份在那个文件夹里。")
                }

                Section {
                    Toggle(isOn: $clockEnabled) {
                        Label("时钟", systemImage: "clock")
                    }
                    if clockEnabled {
                        LabeledContent("大小") {
                            Slider(value: $clockScale, in: 0.6...3)
                                .frame(maxWidth: 220)
                        }
                        Button("放回右上角") {
                            UserDefaults.standard.set(0.85, forKey: "clockX")
                            UserDefaults.standard.set(0.06, forKey: "clockY")
                        }
                    }
                } footer: {
                    Text("时钟浮在页面上，液态玻璃效果，颜色跟随系统深浅色；可以拖到任何位置，双指缩放。")
                }

                Section {
                    if let p = store.activeProvider {
                        LabeledContent("服务商", value: p.name)
                        LabeledContent("模型", value: p.model.isEmpty ? "未选择" : p.model)
                        if !p.hasKey {
                            Label("还没有填写这个服务商的 API Key", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("当前使用")
                } footer: {
                    Text("点下面任意服务商，填写 API Key 并选择模型，再点“设为当前使用”。做题时也可以在右上角随时切换模型。")
                }

                Section {
                    NavigationLink {
                        UsageView()
                    } label: {
                        UsageSummaryRow()
                    }
                } header: {
                    Text("用量和费用")
                }

                gradingSection
                followUpSection
                noteSection
                answerSection

                Section("模型服务商") {
                    ForEach(store.providers) { p in
                        NavigationLink(value: p.id) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name)
                                    Text(p.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if p.id == store.activeProviderID {
                                    Text("使用中").font(.caption).foregroundStyle(.tint)
                                }
                                if p.hasKey {
                                    Image(systemName: "key.fill").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    Button {
                        let custom = ProviderCatalog.newCustom()
                        store.updateProvider(custom)
                        path.append(custom.id)
                    } label: {
                        Label("添加自定义服务商（OpenAI 兼容）", systemImage: "plus")
                    }
                }

                StorageLocationSection(pick: $folderPick) {
                    importerKind = .folder
                    showImporter = true
                }
                backupSection

                Section {
                    LabeledContent("发送题目给 AI 服务商") {
                        Text(store.aiConsent == true ? "已同意" : "未同意")
                            .foregroundStyle(store.aiConsent == true ? Color.green : Color.orange)
                    }
                    Button("查看数据发送说明", systemImage: "hand.raised") { showConsent = true }
                    Link(destination: AppInfo.privacyPolicyURL) {
                        Label("隐私政策", systemImage: "doc.text")
                    }
                    Link(destination: AppInfo.supportURL) {
                        Label("帮助与反馈", systemImage: "questionmark.circle")
                    }
                } header: {
                    Text("数据与隐私")
                } footer: {
                    Text("API Key 保存在本机钥匙串中，选了文件储存位置时也会存一份在那个文件夹里；只会发送给对应服务商的接口地址。Stepwise 不收集任何数据。")
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showConsent) { ConsentView() }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: importerKind == .folder ? [.folder] : [.json]) { result in
                if importerKind == .folder {
                    folderPick = FolderPick(result: result)
                    return
                }
                do {
                    let backup = try LibraryBackup.read(from: result.get())
                    let r = store.importBackup(backup, select: false)
                    var message = "已导入 \(r.sets) 个题集，共 \(r.questions) 道题"
                    message += r.notes > 0 ? "，以及 \(r.notes) 篇笔记，都放在左侧列表的最上面。" : "，放在左侧题集列表的最上面。"
                    if r.copies > 0 { message += "其中 \(r.copies) 个题集本机已经有了，作为副本导入（名称后面带“导入”）。" }
                    importMessage = message
                } catch {
                    importMessage = error.localizedDescription
                }
            }
            .alert("导入", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("好") { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
            .navigationDestination(for: String.self) { id in
                ProviderEditView(providerID: id)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    /// 某个服务商的常用模型（批改模型选择页里也能加星）
    private func favoritesBinding(for providerID: String) -> Binding<[String]> {
        Binding(
            get: { store.providers.first { $0.id == providerID }?.favoriteModels ?? [] },
            set: { newValue in
                guard var p = store.providers.first(where: { $0.id == providerID }) else { return }
                p.favoriteModels = newValue
                store.updateProvider(p)
            })
    }

    // MARK: - 批改速度

    private var gradingSection: some View {
        Section {
            Toggle(isOn: $store.quickGrading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("快速检查")
                    Text("检查答案和给提示时让模型少思考").font(.caption).foregroundStyle(.secondary)
                }
            }

            modelOverride("检查与提示模型", providerID: $store.gradingProviderID, model: $store.gradingModel,
                          resolved: store.gradingProvider)

            Toggle(isOn: $store.presolveAnswers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("预先求解答案")
                    Text("没有参考答案的题，在你做题时由 AI 在后台先解出来，检查时只需对答案，更快也更准。每题多用一次 API，使用出新题模型（没设置时用当前模型）").font(.caption).foregroundStyle(.secondary)
                }
            }

            Toggle("显示用时", isOn: $store.showTiming)
        } header: {
            Text("检查速度")
        } footer: {
            Text("可以单独选一个反应快的模型专门检查答案和给提示，例如 deepseek-chat、Claude Haiku、Gemini Flash；看完整答案和继续对话仍使用当前模型。模型不支持快速检查时会自动按正常方式请求。")
        }
    }

    /// 单独给某项用途选模型：先选服务商，再选模型；不选则跟随当前模型
    private func modelOverride(_ title: String, providerID: Binding<String?>, model: Binding<String>,
                               resolved: ProviderConfig?, recommend: ModelBrowser.Recommend = .fastVision) -> some View {
        ModelOverrideRows(title: title, providerID: providerID, model: model, resolved: resolved, recommend: recommend)
    }

    // MARK: - 备份与迁移

    private var backupSection: some View {
        Section {
            NavigationLink {
                ExportView()
            } label: {
                Label("导出题目和做题记录", systemImage: "square.and.arrow.up")
            }
            Button {
                importerKind = .backup
                showImporter = true
            } label: {
                Label("导入题目和做题记录", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("备份与迁移")
        } footer: {
            Text("导出的文件包含题目、参考答案、作答和对话记录、笔记、图片和手写笔迹，可以存到“文件”或隔空投送到另一台 iPad，再在那里导入。不包含 API Key 和设置。导入只会新增题集，不会覆盖本机已有的内容。")
        }
    }

    // MARK: - 作答

    @ViewBuilder
    private var answerSection: some View {
        if HandwritingModel.isAvailable {
            Section {
                Toggle(isOn: $store.keyboardAnswer) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("键盘作答")
                        Text("打开后每道题的手写区下面会多一个打字框").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("作答")
            } footer: {
                Text("默认只用 Apple Pencil 手写作答。")
            }
        }
    }

    // MARK: - 做完一道题之后

    private var followUpSection: some View {
        Section {
            NavigationLink {
                FollowUpSettingsView()
            } label: {
                LabeledContent("快捷操作", value: "\(store.followUps.count) 个")
            }
            modelOverride("出新题模型", providerID: $store.questionProviderID, model: $store.questionModel,
                          resolved: store.questionProvider)
        } header: {
            Text("做完一道题之后")
        } footer: {
            Text("做对或看完答案后，题目下方会显示这些快捷操作，可以增删、改文字、调整顺序。出新题建议选推理能力强的模型（名字里常带 pro、opus、reasoner、thinking）。新题会记住原题的作答记录，检查时会特别留意你在原题上犯过的错。")
        }
    }

    // MARK: - 笔记

    private var noteSection: some View {
        Section {
            modelOverride("整理笔记模型", providerID: $store.noteProviderID, model: $store.noteModel,
                          resolved: store.noteProvider, recommend: .longContext)
        } header: {
            Text("笔记")
        } footer: {
            Text("导入资料生成笔记时用的模型。资料长、公式多时，建议选上下文长、归纳能力强、能看图的模型，例如 Gemini 2.5 Pro / 3 Pro、Claude Sonnet 4.5、GPT-5、GPT-4.1、通义 Qwen-VL-Max；只有文字的资料也可以用 Kimi K2、DeepSeek。选模型时，推荐的模型排在最上面。笔记里的提问用当前模型，出练习题用出新题模型。")
        }
    }
}

/// 选择要导出的题集，生成备份文件分享出去
struct ExportView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: Set<UUID> = []
    @State private var selectedNotes: Set<UUID> = []
    @State private var initialized = false

    var body: some View {
        let chosen = store.questionSets.filter { selected.contains($0.id) }
        let chosenNotes = store.notes.filter { selectedNotes.contains($0.id) }
        // 笔记里的练习题集跟着笔记一起导出
        let noteSets = chosenNotes.compactMap { store.set($0.exerciseSetID) }
        let allSelected = !store.questionSets.isEmpty && chosen.count == store.questionSets.count
        List {
            Section {
                if store.questionSets.isEmpty {
                    Text("还没有题集").foregroundStyle(.secondary)
                }
                ForEach(store.questionSets) { set in
                    Button {
                        if selected.contains(set.id) { selected.remove(set.id) } else { selected.insert(set.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected.contains(set.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected.contains(set.id) ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.title).foregroundStyle(.primary)
                                Text("\(set.questions.count) 道题 · 已完成 \(set.doneCount)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("选择要导出的题集")
                    Spacer()
                    if !store.questionSets.isEmpty {
                        Button(allSelected ? "全不选" : "全选") {
                            selected = allSelected ? [] : Set(store.questionSets.map(\.id))
                        }
                        .font(.callout)
                        .textCase(nil)
                    }
                }
            }

            if !store.notes.isEmpty {
                Section("选择要导出的笔记") {
                    ForEach(store.notes) { doc in
                        Button {
                            if selectedNotes.contains(doc.id) { selectedNotes.remove(doc.id) } else { selectedNotes.insert(doc.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedNotes.contains(doc.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedNotes.contains(doc.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title).foregroundStyle(.primary)
                                    Text("\(doc.blocks.count) 块 · \(doc.blocks.filter { $0.kind == .exercise }.count) 道练习")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                let parts = [chosen.isEmpty ? nil : "\(chosen.count) 个题集",
                             chosenNotes.isEmpty ? nil : "\(chosenNotes.count) 篇笔记"].compactMap { $0 }
                ShareLink(item: BackupFile(sets: chosen + noteSets, folders: store.folders, notes: chosenNotes),
                          preview: SharePreview("Stepwise 备份（\(parts.joined(separator: "、"))）")) {
                    Label(parts.isEmpty ? "请先选择题集或笔记" : "导出 " + parts.joined(separator: "、"),
                          systemImage: "square.and.arrow.up")
                }
                .disabled(parts.isEmpty)
            } footer: {
                Text("可以存到“文件”、隔空投送到另一台 iPad，或用其他 App 发送。在另一台设备上打开设置 → 导入题目和做题记录。")
            }
        }
        .navigationTitle("导出")
        .onAppear {
            // 默认全选
            if !initialized {
                selected = Set(store.questionSets.map(\.id))
                selectedNotes = Set(store.notes.map(\.id))
                initialized = true
            }
        }
    }
}

/// 自定义做完一道题之后的快捷操作
struct FollowUpSettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var newAction: FollowUpAction?
    @State private var confirmRestore = false
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    var body: some View {
        List {
            Section {
                ForEach($store.followUps) { $action in
                    NavigationLink {
                        FollowUpEditor(action: $action).navigationTitle("编辑操作")
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.title.isEmpty ? "（未命名）" : action.title)
                                Text(action.prompt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if action.makesQuestion {
                                Text("出新题").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { store.followUps.remove(atOffsets: $0) }
                .onMove { store.followUps.move(fromOffsets: $0, toOffset: $1) }

                Button {
                    newAction = FollowUpAction(title: "", prompt: "")
                } label: {
                    Label("添加操作", systemImage: "plus")
                }
            } footer: {
                Text("点一下按钮，就会把“发给 AI 的话”发出去。打开“出新题”的操作使用出新题模型，出的题自动加入题目列表。左滑删除，点右上角“编辑”调整顺序。")
            }

            Section {
                Button("恢复默认", role: .destructive) { confirmRestore = true }
            }
        }
        .navigationTitle("快捷操作")
        #if os(iOS)
        // 系统的 EditButton 显示英文，自己做一个
        .environment(\.editMode, $editMode)
        .toolbar {
            Button(editMode.isEditing ? "完成" : "编辑") {
                withAnimation { editMode = editMode.isEditing ? .inactive : .active }
            }
        }
        #endif
        .confirmationDialog("恢复成默认的快捷操作？你添加和修改的内容会被清除。", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) { store.followUps = FollowUpAction.defaults }
        }
        .sheet(item: $newAction) { _ in
            NavigationStack {
                FollowUpEditor(action: Binding(get: { newAction ?? FollowUpAction(title: "", prompt: "") },
                                               set: { newAction = $0 }))
                    .navigationTitle("添加操作")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { newAction = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("添加") {
                                if let action = newAction { store.followUps.append(action) }
                                newAction = nil
                            }
                            .disabled(newAction.map { $0.title.trimmingCharacters(in: .whitespaces).isEmpty
                                || $0.prompt.trimmingCharacters(in: .whitespaces).isEmpty } ?? true)
                        }
                    }
            }
        }
    }
}

struct FollowUpEditor: View {
    @Binding var action: FollowUpAction

    var body: some View {
        Form {
            Section("按钮文字") {
                TextField("例如：出一道类似的新题", text: $action.title)
            }
            Section {
                TextField("例如：请出一道考查相同知识点的类似新题。", text: $action.prompt, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("发给 AI 的话")
            }
            Section {
                Toggle("出新题", isOn: $action.makesQuestion)
            } footer: {
                Text("打开后用出新题模型回答，出的题自动加入题目列表，并记住原题的作答记录。")
            }
        }
    }
}

struct ProviderEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let providerID: String

    @State private var config: ProviderConfig?
    @State private var apiKey = ""
    @State private var fetching = false
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        Form {
            if let binding = Binding($config) {
                content(binding)
            }
        }
        .navigationTitle(config?.name ?? "")
        .onAppear {
            // 从模型选择页返回时不能用旧数据覆盖刚改的内容
            if config == nil {
                config = store.providers.first { $0.id == providerID }
                apiKey = Keychain.get(providerID) ?? ""
            }
        }
        .onChange(of: config) { persist() }
        .onDisappear(perform: persist)
    }

    @ViewBuilder
    private func content(_ c: Binding<ProviderConfig>) -> some View {
        Section {
            // 用普通输入框：SecureField 会让系统误以为是网站密码并弹出“保存密码”
            TextField("粘贴 API Key", text: $apiKey)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .privacySensitive()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: apiKey) {
                    Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: providerID)
                    // 选了储存文件夹时，Key 也存一份到文件夹里
                    store.saveSettingsFile()
                }
        } header: {
            Text("API Key")
        } footer: {
            Text(c.wrappedValue.note)
        }

        Section("模型") {
            NavigationLink {
                ModelBrowser(title: c.wrappedValue.name, models: c.wrappedValue.allModels,
                             selection: c.model,
                             favorites: Binding(get: { c.wrappedValue.favoriteModels ?? [] },
                                                set: { c.wrappedValue.favoriteModels = $0 }),
                             onFetch: apiKey.isEmpty ? nil : { await fetchModelsAsync() })
            } label: {
                LabeledContent("模型") {
                    Text(c.wrappedValue.model.isEmpty ? "选择模型" : c.wrappedValue.model)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if let favorites = c.wrappedValue.favoriteModels, !favorites.isEmpty {
                Text("常用：" + favorites.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button {
                fetchModels()
            } label: {
                HStack {
                    Label("获取模型列表", systemImage: "arrow.down.circle")
                    if fetching { Spacer(); ProgressView() }
                }
            }
            .disabled(fetching || apiKey.isEmpty)
            if !c.wrappedValue.fetchedModels.isEmpty {
                let all = c.wrappedValue.fetchedModels
                let chat = all.filter { !ModelInfo.isNonChat($0) }.count
                Text(chat == all.count ? "已获取 \(all.count) 个模型" : "已获取 \(all.count) 个模型，其中 \(chat) 个可以用来做题")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("接口") {
            if c.wrappedValue.isCustom {
                TextField("名称", text: c.name)
                Picker("接口格式", selection: c.apiProtocol) {
                    ForEach(APIProtocol.allCases) { Text($0.displayName).tag($0) }
                }
            } else {
                LabeledContent("接口格式", value: c.wrappedValue.apiProtocol.displayName)
            }
            TextField("接口地址", text: c.baseURL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
        }

        Section {
            Button {
                persist()
                store.activeProviderID = providerID
            } label: {
                Label(store.activeProviderID == providerID ? "正在使用" : "设为当前使用", systemImage: "checkmark.circle")
            }
            .disabled(store.activeProviderID == providerID)

            Button {
                test()
            } label: {
                HStack {
                    Label("测试连接", systemImage: "bolt.horizontal")
                    if testing { Spacer(); ProgressView() }
                }
            }
            .disabled(testing || apiKey.isEmpty || c.wrappedValue.model.isEmpty)
            if let testResult {
                Text(testResult).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }

        if c.wrappedValue.isCustom {
            Section {
                Button("删除这个服务商", role: .destructive) {
                    store.deleteProvider(providerID)
                    config = nil
                    dismiss()
                }
            }
        }
    }

    private func persist() {
        guard let config else { return }
        store.updateProvider(config)
    }

    private func fetchModels() {
        fetching = true
        Task {
            await fetchModelsAsync()
            fetching = false
        }
    }

    private func fetchModelsAsync() async {
        guard let config else { return }
        do {
            let models = try await LLMClient(config: config, apiKey: apiKey).listModels()
            self.config?.fetchedModels = models
            // 还没选模型时，默认选第一个能对话的模型（聚合平台按字母排序，第一个可能是绘图模型）
            if self.config?.model.isEmpty == true,
               let first = models.first(where: { !ModelInfo.isNonChat($0) }) ?? models.first {
                self.config?.model = first
            }
            persist()
            testResult = models.isEmpty ? "服务商没有返回模型列表，请手动填写模型名称。" : nil
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func test() {
        guard let config else { return }
        persist()
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            do {
                let reply = try await LLMClient(config: config, apiKey: apiKey).complete(
                    system: "你是一个助手。",
                    messages: [LLMMessage(role: .user, parts: [.text("请只回复四个字：连接成功")])])
                testResult = "✅ " + reply.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                testResult = "❌ " + error.localizedDescription
            }
        }
    }
}

/// 单独给某项用途选模型的两行：先选服务商，再选模型；不选则跟随当前模型。设置页和生成笔记页共用
struct ModelOverrideRows: View {
    @EnvironmentObject var store: AppStore
    let title: String
    @Binding var providerID: String?
    @Binding var model: String
    let resolved: ProviderConfig?
    var recommend: ModelBrowser.Recommend = .fastVision

    init(title: String, providerID: Binding<String?>, model: Binding<String>,
         resolved: ProviderConfig?, recommend: ModelBrowser.Recommend = .fastVision) {
        self.title = title
        self._providerID = providerID
        self._model = model
        self.resolved = resolved
        self.recommend = recommend
    }

    var body: some View {
        Picker(title, selection: Binding(
            get: { providerID ?? "" },
            set: { id in
                providerID = id.isEmpty ? nil : id
                // 换服务商时默认选它当前的模型
                if let p = store.providers.first(where: { $0.id == id }) { model = p.model }
            })) {
            Text("跟随当前模型").tag("")
            ForEach(store.providers.filter(\.hasKey)) { p in
                Text(p.name).tag(p.id)
            }
        }

        if let id = providerID, let p = store.providers.first(where: { $0.id == id }) {
            NavigationLink {
                ModelBrowser(title: title, models: p.allModels, selection: $model, favorites: favorites(for: p.id),
                             recommend: recommend)
            } label: {
                LabeledContent("模型", value: model.isEmpty ? "未选择" : model)
            }
            if resolved == nil {
                Label("请选择一个模型，否则会继续使用当前模型", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func favorites(for providerID: String) -> Binding<[String]> {
        Binding(
            get: { store.providers.first { $0.id == providerID }?.favoriteModels ?? [] },
            set: { newValue in
                guard var p = store.providers.first(where: { $0.id == providerID }) else { return }
                p.favoriteModels = newValue
                store.updateProvider(p)
            })
    }
}

// MARK: - 文件储存位置

/// 选一个“文件”App 里的文件夹，题目、笔记、图片和手写笔迹都存在那里；更新或重装 App 后重新选同一个文件夹就能读到
/// 从文件选择器选到的文件夹（每次选都是新的一项，同一个文件夹再选一次也会处理）
struct FolderPick: Equatable {
    let id = UUID()
    let result: Result<URL, Error>
    static func == (a: FolderPick, b: FolderPick) -> Bool { a.id == b.id }
}

struct StorageLocationSection: View {
    @EnvironmentObject var store: AppStore
    /// 设置页的文件选择器选好文件夹后放在这里
    @Binding var pick: FolderPick?
    /// 请设置页打开文件夹选择器
    let choose: () -> Void
    @State private var current = DataLocation.customFolder
    @State private var working = false
    @State private var dialog: Dialog?

    /// 确认框或提示：change 不为 nil 时有“确认”按钮
    struct Dialog: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var change: Change?
    }

    struct Change {
        /// nil 表示改回 App 内默认位置
        var folder: URL?
        var mode: AppStore.LocationChange
        var confirm: String
    }

    var body: some View {
        Section {
            LabeledContent("当前位置") {
                Text(DataLocation.describe(current))
                    .multilineTextAlignment(.trailing)
            }
            if let problem = DataLocation.launchProblem, current == nil {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if store.writesBlocked {
                Label("储存位置里的数据还没读出来，现在的改动不会保存。", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Button {
                choose()
            } label: {
                Label(current == nil ? "选择文件夹…" : "换一个文件夹…", systemImage: "folder")
            }
            .disabled(working)
            if current != nil {
                Button {
                    prepareReset()
                } label: {
                    Label("改回 App 内默认位置", systemImage: "arrow.uturn.backward")
                }
                .disabled(working)
            }
            if working {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在处理…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("文件储存位置")
        } footer: {
            Text("默认存在 App 内，删除 App 时会一起删掉。可以选一个“文件”App 里的文件夹（iCloud 云盘或“我的 iPad”），题目、笔记、图片和手写笔迹都存在那里；更新或重新安装 App 后，重新选同一个文件夹就能读到原来的数据。选空文件夹会把现在的数据复制过去；选已有 Stepwise 数据的文件夹会改用那份数据。原来位置的数据不会删除。API Key、服务商、选的模型和常用模型、学习时间和周报、其他设置也会存在这个文件夹里（settings.json，API Key 没有加密，请不要把文件夹分享给别人）。")
        }
        .onChange(of: pick) {
            guard let p = pick else { return }
            pick = nil
            picked(p.result)
        }
        .alert(dialog?.title ?? "", isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }), presenting: dialog) { d in
            if let change = d.change {
                Button(change.confirm) { apply(change) }
                Button("取消", role: .cancel) {}
            } else {
                Button("好") {}
            }
        } message: { d in
            Text(d.message)
        }
    }

    /// 现在这份数据有多少，例如“3 个题集、2 篇笔记”
    private var currentSummary: String {
        "\(store.questionSets.count) 个题集、\(store.notes.count) 篇笔记"
    }

    private func picked(_ result: Result<URL, Error>) {
        let folder: URL
        switch result {
        case .success(let url): folder = url
        case .failure(let error):
            dialog = Dialog(title: "没能打开文件夹", message: error.localizedDescription)
            return
        }
        if DataLocation.isSame(folder, DataLocation.root) {
            dialog = Dialog(title: "已经在用这个文件夹", message: "数据现在就存在“\(DataLocation.describe(folder))”。")
            return
        }
        if store.hasBackgroundWork {
            dialog = Dialog(title: "稍等一下", message: "AI 正在回复或生成笔记，等它完成后再换储存位置。")
            return
        }
        let name = DataLocation.describe(folder)
        working = true
        Task {
            let contents = await Task.detached(priority: .userInitiated) { DataLocation.inspect(folder) }.value
            working = false
            switch contents {
            case .empty:
                dialog = Dialog(title: "把现在的数据复制到“\(name)”？",
                                message: "现在的\(currentSummary)，连同图片、手写笔迹、学习时间、API Key 和各项设置，会复制到这个文件夹，之后都存在那里。原来位置的那份保留不动，可以随时改回来。",
                                change: Change(folder: folder, mode: .copyCurrent, confirm: "复制并使用这个文件夹"))
            case .stepwise(let summary):
                dialog = Dialog(title: "“\(name)”里已经有 Stepwise 数据",
                                message: "里面有\(summary.text)。改用这个文件夹后，App 显示的是那份数据，不会用现在的数据覆盖它。现在的\(currentSummary)留在原来的位置，不会删除，改回原来的位置就能看到。",
                                change: Change(folder: folder, mode: .useExisting, confirm: "使用文件夹里的数据"))
            case .otherFiles(let names):
                let list = names.prefix(3).joined(separator: "、") + (names.count > 3 ? " 等" : "")
                dialog = Dialog(title: "这个文件夹里有其他文件",
                                message: "“\(name)”里有\(list)。为了不弄乱你的文件，Stepwise 只存在空文件夹里：请在选择时新建一个文件夹（例如“Stepwise 数据”），再选它。")
            }
        }
    }

    private func prepareReset() {
        if store.hasBackgroundWork {
            dialog = Dialog(title: "稍等一下", message: "AI 正在回复或生成笔记，等它完成后再换储存位置。")
            return
        }
        let folderName = DataLocation.describe(current)
        working = true
        Task {
            let contents = await Task.detached(priority: .userInitiated) { DataLocation.inspect(DataLocation.defaultRoot) }.value
            working = false
            if case .stepwise(let summary) = contents {
                dialog = Dialog(title: "App 内已经有一份数据",
                                message: "App 内有\(summary.text)，可能是选文件夹之前的旧数据。改回后显示的是那份数据，不会被覆盖。“\(folderName)”里现在的\(currentSummary)保留不动，之后再选这个文件夹就能看到。",
                                change: Change(folder: nil, mode: .useExisting, confirm: "改回并使用 App 内的数据"))
            } else {
                // App 内没有题库：把文件夹里的数据复制回来（App 内其他文件不会动）
                dialog = Dialog(title: "把数据复制回 App 内？",
                                message: "现在的\(currentSummary)，连同图片和手写笔迹，会复制回 App 内，之后存在那里（删除 App 时会一起删掉）。“\(folderName)”里的那份保留不动。",
                                change: Change(folder: nil, mode: .copyCurrent, confirm: "复制并改回"))
            }
        }
    }

    private func apply(_ change: Change) {
        working = true
        Task {
            do {
                try await store.changeDataLocation(to: change.folder, mode: change.mode)
                current = DataLocation.customFolder
                let place = DataLocation.describe(current)
                dialog = Dialog(title: "储存位置已更改",
                                message: change.mode == .copyCurrent
                                    ? "数据已复制，之后都存在“\(place)”。"
                                    : "现在显示的是“\(place)”里的数据：\(currentSummary)。")
            } catch {
                dialog = Dialog(title: "没能更改储存位置", message: error.localizedDescription + "\n数据仍然存在原来的位置。")
            }
            working = false
        }
    }
}

// MARK: - 用量和费用

/// 设置首页的一行：今天和本月用了多少 token、花了多少钱
private struct UsageSummaryRow: View {
    @ObservedObject private var log = UsageLog.shared

    var body: some View {
        let today = log.totals(since: Calendar.current.startOfDay(for: Date()))
        let month = log.totals(since: Calendar.current.dateInterval(of: .month, for: Date())?.start)
        VStack(alignment: .leading, spacing: 4) {
            Label("token 用量和费用", systemImage: "chart.pie")
            Text("今天 \(UsageView.summary(today))　本月 \(UsageView.summary(month))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 用量明细：按时间段合计，每个模型一行；点模型可以填价格
struct UsageView: View {
    @ObservedObject private var log = UsageLog.shared
    @State private var period: Period = .month
    @State private var confirmClear = false
    @State private var editing: PriceTarget?

    enum Period: String, CaseIterable, Identifiable {
        case today = "今天", week = "近 7 天", month = "本月", all = "全部"
        var id: String { rawValue }
        var start: Date? {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: Date())
            case .week: return cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: Date()))
            case .month: return cal.dateInterval(of: .month, for: Date())?.start
            case .all: return nil
            }
        }
    }

    struct PriceTarget: Identifiable {
        let provider: String
        let model: String
        var id: String { provider + "|" + model }
    }

    /// “12.3K token · $0.042”
    static func summary(_ totals: [String: UsageTotals]) -> String {
        let tokens = totals.values.reduce(0) { $0 + $1.totalTokens }
        let cost = UsageLog.cost(of: totals)
        var s = "\(UsageLog.formatTokens(tokens)) token"
        if tokens > 0 { s += " · " + UsageLog.format(cost.amounts) + (cost.missing ? "+" : "") }
        return s
    }

    private func providerName(_ id: String) -> String {
        ProviderCatalog.presets.first { $0.id == id }?.name ?? (id.hasPrefix("custom-") ? "自定义服务商" : id)
    }

    var body: some View {
        let totals = log.totals(since: period.start)
        let cost = UsageLog.cost(of: totals)
        let rows = totals.sorted { $0.value.totalTokens > $1.value.totalTokens }
        Form {
            Section {
                Picker("时间", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                let all = totals.values.reduce(into: UsageTotals()) { $0.add($1) }
                LabeledContent("请求次数", value: "\(all.requests)")
                LabeledContent("输入 token", value: UsageLog.formatTokens(all.input + all.cacheRead + all.cacheWrite))
                LabeledContent("输出 token", value: UsageLog.formatTokens(all.output))
                LabeledContent("费用") {
                    Text(UsageLog.format(cost.amounts)).monospacedDigit()
                }
                if cost.missing {
                    Label("有的模型还没填价格，费用里没算它们", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section {
                if rows.isEmpty {
                    Text("这段时间还没有用量").foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.key) { key, t in
                    let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                    let provider = parts.first ?? ""
                    let model = parts.count > 1 ? parts[1] : ""
                    let rowCost = UsageLog.cost(of: [key: t])
                    let price = PriceBook.price(provider: provider, model: model)
                    Button {
                        editing = PriceTarget(provider: provider, model: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(model).font(.body.weight(.medium)).lineLimit(1)
                                Spacer()
                                Text(rowCost.missing && rowCost.amounts.values.allSatisfy { $0 == 0 }
                                     ? "未填价格" : UsageLog.format(rowCost.amounts) + (rowCost.missing ? "+" : ""))
                                    .monospacedDigit()
                                    .foregroundStyle(rowCost.missing ? Color.orange : Color.primary)
                            }
                            Text("\(providerName(provider)) · \(t.requests) 次 · 输入 \(UsageLog.formatTokens(t.input + t.cacheRead + t.cacheWrite)) · 输出 \(UsageLog.formatTokens(t.output))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let price {
                                Text("\(price.symbol)\(Self.number(price.input)) / \(price.symbol)\(Self.number(price.output)) 每百万 token（输入 / 输出）")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("按模型")
            } footer: {
                Text("token 数是服务商在每次回复后报回来的。直连 Anthropic 时按官方价格计算（2026 年 11 月）；OpenRouter 用它报回来的实际扣费；其他服务商的价格各不相同，点模型填上每百万 token 的价格就会算出费用（之前没算的也会补上）。")
            }

            Section {
                Button("清空用量记录", role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle("用量和费用")
        .confirmationDialog("清空所有用量记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { log.clear() }
        } message: {
            Text("只删用量记录，填过的价格会保留。清空后不能恢复。")
        }
        .sheet(item: $editing) { target in
            PriceEditor(provider: target.provider, model: target.model)
        }
    }

    static func number(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%g", v)
    }
}

/// 填一个模型的价格（每百万 token）
private struct PriceEditor: View {
    let provider: String
    let model: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var log = UsageLog.shared
    @State private var input = ""
    @State private var output = ""
    @State private var cacheRead = ""
    @State private var currency = "USD"

    private var builtIn: ModelPrice? { PriceBook.builtIn(provider: provider, model: model) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("币种", selection: $currency) {
                        Text("美元 $").tag("USD")
                        Text("人民币 ¥").tag("CNY")
                    }
                    field("输入", $input)
                    field("输出", $output)
                    field("缓存命中（可不填）", $cacheRead)
                } header: {
                    Text(model)
                } footer: {
                    Text("单位：每百万 token。按服务商后台或官网标的价格填写。不填缓存价时按输入价的十分之一算。")
                }
                if builtIn != nil {
                    Section {
                        Button("恢复成官方价格") {
                            PriceBook.setCustom(nil, provider: provider, model: model)
                            log.objectWillChange.send()
                            dismiss()
                        }
                    }
                } else if PriceBook.custom(provider: provider, model: model) != nil {
                    Section {
                        Button("删除这个价格", role: .destructive) {
                            PriceBook.setCustom(nil, provider: provider, model: model)
                            log.objectWillChange.send()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("模型价格")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(Double(input) == nil || Double(output) == nil)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("0", text: text)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .frame(maxWidth: 140)
        }
    }

    private func fill() {
        guard let p = PriceBook.price(provider: provider, model: model) else { return }
        input = UsageView.number(p.input)
        output = UsageView.number(p.output)
        cacheRead = p.cacheRead.map(UsageView.number) ?? ""
        currency = p.currency
    }

    private func save() {
        guard let i = Double(input), let o = Double(output) else { return }
        PriceBook.setCustom(ModelPrice(input: i, output: o, cacheRead: Double(cacheRead), currency: currency),
                            provider: provider, model: model)
        // 让列表重新算费用
        log.objectWillChange.send()
        dismiss()
    }
}
