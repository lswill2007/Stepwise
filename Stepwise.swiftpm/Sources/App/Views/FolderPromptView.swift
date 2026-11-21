import SwiftUI

/// 第一次打开时请用户选储存位置：默认是“我的 iPad › Stepwise Files”。
/// App 自己不能直接在“我的 iPad”里建文件夹，要用户在文件选择器里点一下“我的 iPad”；
/// 选好后在那里找 Stepwise Files，没有就新建，然后自动读取里面的数据（重装 App 后 API Key 和设置也一起回来）
struct FolderPromptView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var working = false
    @State private var result: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("数据存在哪里")
                            .font(.largeTitle.bold())
                        Text("Stepwise 把题目、笔记、手写笔迹和设置存在“我的 iPad › \(DataLocation.defaultFolderName)”文件夹里。删除或重新安装 App 后，再选一次“我的 iPad”就能读回原来的数据。")
                            .foregroundStyle(.secondary)
                    }
                    if let result {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Ink.green)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            step(1, L("点下面的“选择我的 iPad”。"))
                            step(2, L("在弹出的窗口左边点“我的 iPad”。"))
                            step(3, String(localized: "点右上角的“打开”。有 \(DataLocation.defaultFolderName) 文件夹就读取里面的数据，没有就新建一个。"))
                        }
                    }
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if result != nil {
                        Button {
                            dismiss()
                        } label: {
                            Text("开始使用").font(.headline).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button {
                            failure = nil
                            showPicker = true
                        } label: {
                            HStack(spacing: 8) {
                                if working { ProgressView().tint(.white) }
                                Text(working ? L("正在读取…") : L("选择我的 iPad")).font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(working)
                        Button("暂时存在 App 内") { dismiss() }
                            .disabled(working)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .interactiveDismissDisabled(working)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { picked in
            switch picked {
            case .success(let url): use(url)
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.callout.weight(.semibold)).monospacedDigit()
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func use(_ url: URL) {
        working = true
        Task {
            do {
                result = try await store.useFolder(url)
            } catch {
                failure = error.localizedDescription
            }
            working = false
        }
    }
}
