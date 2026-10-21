import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @Binding var showImport: Bool
    @Binding var showSettings: Bool
    @State private var renaming: QuestionSet?
    @State private var newTitle = ""

    var body: some View {
        List(selection: Binding(get: { store.selectedSetID }, set: { id in
            store.selectedSetID = id
            store.selectedQuestionID = store.set(id)?.questions.first(where: { !$0.status.isDone })?.id
                ?? store.set(id)?.questions.first?.id
        })) {
            ForEach(store.sets) { set in
                VStack(alignment: .leading, spacing: 4) {
                    Text(set.title).font(.headline).lineLimit(2)
                    HStack {
                        ProgressView(value: Double(set.doneCount), total: Double(max(set.questions.count, 1)))
                        Text("\(set.doneCount)/\(set.questions.count)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.vertical, 4)
                .tag(set.id)
                .contextMenu {
                    Button("重命名", systemImage: "pencil") {
                        newTitle = set.title
                        renaming = set
                    }
                    Button("删除", systemImage: "trash", role: .destructive) { store.deleteSet(set.id) }
                }
            }
            .onDelete { offsets in
                offsets.map { store.sets[$0].id }.forEach(store.deleteSet)
            }
        }
        .overlay {
            if store.sets.isEmpty {
                ContentUnavailableView {
                    Label("还没有题目", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("导入 PDF、图片或文字，AI 会自动把每道题分开")
                } actions: {
                    Button("导入题目") { showImport = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("题集")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImport = true } label: { Label("导入题目", systemImage: "plus") }
            }
            ToolbarItem(placement: .automatic) {
                Button { showSettings = true } label: { Label("设置", systemImage: "gearshape") }
            }
        }
        .alert("重命名题集", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $newTitle)
            Button("取消", role: .cancel) { renaming = nil }
            Button("确定") {
                if let id = renaming?.id, !newTitle.isEmpty { store.renameSet(id, to: newTitle) }
                renaming = nil
            }
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
                                    if q.isGenerated {
                                        Text("AI 新题").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
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
        switch status {
        case .todo: Image(systemName: "circle").foregroundStyle(.secondary)
        case .wrong: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .revealed: Image(systemName: "eye.circle.fill").foregroundStyle(.blue)
        }
    }
}
