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
            config = store.providers.first { $0.id == providerID }
            apiKey = Keychain.get(providerID) ?? ""
        }
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
            TextField("模型名称", text: c.model)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !c.wrappedValue.allModels.isEmpty {
                Picker("从列表选择", selection: c.model) {
                    ForEach(c.wrappedValue.allModels, id: \.self) { Text($0).tag($0) }
                }
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
                Text("已获取 \(c.wrappedValue.fetchedModels.count) 个模型").font(.caption).foregroundStyle(.secondary)
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
        guard let config else { return }
        fetching = true
        Task {
            defer { fetching = false }
            do {
                let models = try await LLMClient(config: config, apiKey: apiKey).listModels()
                self.config?.fetchedModels = models
                if self.config?.model.isEmpty == true, let first = models.first { self.config?.model = first }
                persist()
                testResult = models.isEmpty ? "服务商没有返回模型列表，请手动填写模型名称。" : nil
            } catch {
                testResult = error.localizedDescription
            }
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
