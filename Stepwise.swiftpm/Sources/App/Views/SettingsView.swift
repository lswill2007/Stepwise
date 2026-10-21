import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var showConsent = false

    var body: some View {
        NavigationStack(path: $path) {
            Form {
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

            Picker("批改与提示模型", selection: Binding(
                get: { store.gradingProviderID ?? "" },
                set: { id in
                    store.gradingProviderID = id.isEmpty ? nil : id
                    // 换服务商时默认选它当前的模型
                    if let p = store.providers.first(where: { $0.id == id }) { store.gradingModel = p.model }
                })) {
                Text("跟随当前模型").tag("")
                ForEach(store.providers.filter(\.hasKey)) { p in
                    Text(p.name).tag(p.id)
                }
            }

            if let id = store.gradingProviderID, let p = store.providers.first(where: { $0.id == id }) {
                NavigationLink {
                    ModelBrowser(title: "批改与提示模型", models: p.allModels,
                                 selection: $store.gradingModel,
                                 favorites: favoritesBinding(for: p.id))
                } label: {
                    LabeledContent("模型", value: store.gradingModel.isEmpty ? "未选择" : store.gradingModel)
                }
                if store.gradingProvider == nil {
                    Label("请选择一个模型，否则会继续使用当前模型", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Toggle("显示用时", isOn: $store.showTiming)
        } header: {
            Text("批改速度")
        } footer: {
            Text("可以单独选一个反应快的模型专门检查答案和给提示，例如 deepseek-chat、Claude Haiku、Gemini Flash；看完整答案和继续对话仍使用当前模型。模型不支持快速批改时会自动按正常方式请求。")
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
