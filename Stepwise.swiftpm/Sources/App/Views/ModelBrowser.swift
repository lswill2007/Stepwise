import SwiftUI

/// 选择模型：支持搜索、按厂商分组、标记常用。聚合平台动辄几百个模型，用下拉菜单根本选不了。
struct ModelBrowser: View {
    let title: String
    let models: [String]
    @Binding var selection: String
    @Binding var favorites: [String]
    /// 点“获取模型列表”时调用；为 nil 时不显示这个按钮
    var onFetch: (() async -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var family: ModelInfo.Family?
    @State private var showNonChat = false
    @State private var visionOnly = false
    @State private var customName = ""
    @State private var fetching = false

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return models.filter { m in
            (showNonChat || !ModelInfo.isNonChat(m))
                && (!visionOnly || ModelInfo.likelyVision(m))
                && (family == nil || ModelInfo.family(m) == family)
                && (q.isEmpty || m.lowercased().contains(q))
        }
    }

    /// 列表里实际出现的厂商（用于筛选按钮）
    private var families: [ModelInfo.Family] {
        let present = Set(models.filter { showNonChat || !ModelInfo.isNonChat($0) }.map(ModelInfo.family))
        return ModelInfo.Family.allCases.filter(present.contains)
    }

    var body: some View {
        let list = filtered
        let favoriteRows = list.filter(favorites.contains)
        let grouped = Dictionary(grouping: list.filter { !favorites.contains($0) }, by: ModelInfo.family)

        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterChip("全部", selected: family == nil) { family = nil }
                        ForEach(families, id: \.self) { f in
                            filterChip(f.rawValue, selected: family == f) { family = (family == f) ? nil : f }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Toggle("只看支持看图的模型", isOn: $visionOnly)
                Toggle("显示绘图、语音、向量等模型", isOn: $showNonChat)
            } footer: {
                Text("“看图”是根据模型名称推测的。手写作答和图片题需要能看图的模型。点 ☆ 把模型加入常用，做题时右上角的菜单只显示常用模型。")
            }

            if !favoriteRows.isEmpty {
                Section("常用") {
                    ForEach(favoriteRows, id: \.self, content: row)
                }
            }

            ForEach(ModelInfo.Family.allCases, id: \.self) { f in
                if let rows = grouped[f], !rows.isEmpty {
                    Section("\(f.rawValue)（\(rows.count)）") {
                        ForEach(rows, id: \.self, content: row)
                    }
                }
            }

            if list.isEmpty {
                Section {
                    Text(models.isEmpty ? "还没有模型列表。点右上角“获取模型列表”，或在下面直接填写模型名称。" : "没有符合条件的模型")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    TextField("手动填写模型名称", text: $customName)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit(useCustom)
                    Button("使用", action: useCustom)
                        .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("列表里没有的模型可以直接填写名称，以服务商后台显示的为准。")
            }
        }
        .searchable(text: $query, prompt: "搜索模型，例如 claude、gpt-5、qwen")
        .navigationTitle(title)
        .toolbar {
            if let onFetch {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        fetching = true
                        Task {
                            await onFetch()
                            fetching = false
                        }
                    } label: {
                        if fetching {
                            ProgressView()
                        } else {
                            Label("获取模型列表", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(fetching)
                }
            }
        }
    }

    private func row(_ model: String) -> some View {
        let isFavorite = favorites.contains(model)
        return HStack(spacing: 10) {
            Button {
                selection = model
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                        .opacity(model == selection ? 1 : 0)
                    Text(model)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    if ModelInfo.likelyVision(model) {
                        Text("看图")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.teal.opacity(0.15), in: Capsule())
                            .foregroundStyle(.teal)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if isFavorite { favorites.removeAll { $0 == model } } else { favorites.append(model) }
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "取消常用" : "加入常用")
        }
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func useCustom() {
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        selection = name
        dismiss()
    }
}
