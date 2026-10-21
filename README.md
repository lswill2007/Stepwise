# Stepwise · AI 刷题助手（iPad）

导入题目文件，AI 把每道题拆开；逐题作答、检查、一步步提示、看完整答案；通过后还能继续和 AI 聊这道题，或者让它再出一道新题。

- 支持 OpenAI、Claude、Gemini、DeepSeek、通义千问、Kimi、智谱、豆包、Grok、OpenRouter、硅基流动，以及任意 OpenAI 兼容接口，使用你自己的 API Key
- 导入 PDF、图片、文本，或者扫描纸质题目；公式多的 PDF 会自动按图片识别
- 公式用 LaTeX + KaTeX 排版，KaTeX 已打包在 App 内，离线也能显示
- 支持 Apple Pencil 手写作答，手写板可以拖动调整高度、双指缩放，还能全屏书写

## 在 iPad 上使用（不需要 Mac）

1. 在 App Store 安装免费的 **Swift Playgrounds**（需要 iPadOS 17 或更高版本）。
2. 用 iPad 的 Safari 打开本页面，点绿色的 **Code** 按钮 → **Download ZIP**。
3. 打开“文件” App → “下载”，点一下 ZIP 文件解压。
4. 进入解压出来的文件夹，点 **Stepwise.swiftpm**，会用 Swift Playgrounds 打开。
5. 点右上角 ▶︎ 运行。第一次编译需要一两分钟。

第一次打开时会进入设置：选择服务商，粘贴 API Key，选好模型，再点“设为当前使用”。

## 用 Mac + Xcode 安装成独立 App

用 Xcode 打开 `Stepwise.swiftpm`，用数据线连接 iPad，在 Signing & Capabilities 里选择你的 Apple ID 团队，然后运行。用免费 Apple ID 签名的 App 7 天后会失效，到时连上 Mac 重新运行一次即可。

## 目录

```
Stepwise.swiftpm/
  Package.swift          App 配置
  Sources/App/           全部源代码（说明见 Stepwise.swiftpm/README.md）
  Tools/embed_katex.py   重新打包 KaTeX 的脚本
```

KaTeX 0.16.9 以 MIT 许可内嵌在 `Sources/App/KatexAssets.swift` 中。
