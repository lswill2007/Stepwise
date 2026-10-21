import SwiftUI

enum AppInfo {
    static let privacyPolicyURL = URL(string: "https://lswill2007.github.io/Stepwise/privacy.html")!
    static let supportURL = URL(string: "https://lswill2007.github.io/Stepwise/")!
}

/// 首次使用 AI 功能前的数据发送说明。用户明确同意后才会把题目和作答发给第三方 AI 服务商。
struct ConsentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "hand.raised.square.on.square")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                        Text("使用前请了解")
                            .font(.largeTitle.bold())
                        Text("Stepwise 借助你选择的 AI 服务批改作业、给出提示。开始之前，请先了解你的数据会去哪里。")
                            .foregroundStyle(.secondary)
                    }

                    item(icon: "arrow.up.forward.app",
                         title: "会发送给你选择的 AI 服务商",
                         text: "导入题目、检查答案、请求提示或继续对话时，题目内容、你的作答（包括手写图片）和对话记录会发送给你在设置里选择的 AI 服务商（例如 OpenAI、Anthropic、Google、DeepSeek 等），用来生成批改和讲解。这些服务商会按照各自的隐私政策处理数据。")
                    item(icon: "iphone",
                         title: "其他数据只保存在本机",
                         text: "题库、作答记录和手写笔迹只保存在这台 iPad 上；API Key 保存在系统钥匙串里，只会发送给对应的服务商。")
                    item(icon: "eye.slash",
                         title: "Stepwise 不收集任何数据",
                         text: "没有账号、没有服务器、没有广告和追踪，开发者无法看到你的任何内容。")
                    item(icon: "exclamationmark.bubble",
                         title: "请不要上传敏感个人信息",
                         text: "题目文件里如果有姓名、学号等个人信息，导入前最好先去掉。")

                    Button {
                        openURL(AppInfo.privacyPolicyURL)
                    } label: {
                        Label("查看完整隐私政策", systemImage: "doc.text")
                    }
                }
                .padding(28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        store.setAIConsent(true)
                        dismiss()
                    } label: {
                        Text("同意并继续")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("暂不同意") {
                        store.setAIConsent(false)
                        dismiss()
                    }
                    .foregroundStyle(.secondary)

                    Text("不同意也可以浏览已有的题目，但无法使用 AI 批改、提示和导入功能。可以随时在设置里重新选择。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .interactiveDismissDisabled()
    }

    private func item(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
