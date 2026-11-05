import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var showConsent = false
    @State private var showImporter = false
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
                    Text("一分钟内有操作（写字、翻页、点按）的时间算作学习，停下来不动的时间不算。只记在本机。")
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
                    Text("时钟浮在页面上，颜色和系统深浅色相反，看得清楚；可以拖到任何位置，双指缩放。")
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
                    Text("API Key 保存在本机钥匙串中，只会发送给对应服务商的接口地址。Stepwise 不收集任何数据。")
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showConsent) { ConsentView() }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
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
                    Text("快速批改")
                    Text("检查答案和给提示时让模型少思考").font(.caption).foregroundStyle(.secondary)
                }
            }

            modelOverride("批改与提示模型", providerID: $store.gradingProviderID, model: $store.gradingModel,
                          resolved: store.gradingProvider)

            Toggle(isOn: $store.presolveAnswers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("预先求解答案")
                    Text("没有参考答案的题，在你做题时由 AI 在后台先解出来，批改时只需对答案，更快也更准。每题多用一次 API，使用出新题模型（没设置时用当前模型）").font(.caption).foregroundStyle(.secondary)
                }
            }

            Toggle("显示用时", isOn: $store.showTiming)
        } header: {
            Text("批改速度")
        } footer: {
            Text("可以单独选一个反应快的模型专门检查答案和给提示，例如 deepseek-chat、Claude Haiku、Gemini Flash；看完整答案和继续对话仍使用当前模型。模型不支持快速批改时会自动按正常方式请求。")
        }
    }

    /// 单独给某项用途选模型：先选服务商，再选模型；不选则跟随当前模型
    @ViewBuilder
    private func modelOverride(_ title: String, providerID: Binding<String?>, model: Binding<String>,
                               resolved: ProviderConfig?, recommend: ModelBrowser.Recommend = .fastVision) -> some View {
        Picker(title, selection: Binding(
            get: { providerID.wrappedValue ?? "" },
            set: { id in
                providerID.wrappedValue = id.isEmpty ? nil : id
                // 换服务商时默认选它当前的模型
                if let p = store.providers.first(where: { $0.id == id }) { model.wrappedValue = p.model }
            })) {
            Text("跟随当前模型").tag("")
            ForEach(store.providers.filter(\.hasKey)) { p in
                Text(p.name).tag(p.id)
            }
        }

        if let id = providerID.wrappedValue, let p = store.providers.first(where: { $0.id == id }) {
            NavigationLink {
                ModelBrowser(title: title, models: p.allModels, selection: model, favorites: favoritesBinding(for: p.id),
                             recommend: recommend)
            } label: {
                LabeledContent("模型", value: model.wrappedValue.isEmpty ? "未选择" : model.wrappedValue)
            }
            if resolved == nil {
                Label("请选择一个模型，否则会继续使用当前模型", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
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
            Text("做对或看完答案后，题目下方会显示这些快捷操作，可以增删、改文字、调整顺序。出新题建议选推理能力强的模型（名字里常带 pro、opus、reasoner、thinking）。新题会记住原题的作答记录，批改时会特别留意你在原题上犯过的错。")
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
                .onChange(of: apiKey) { Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: providerID) }
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
