# Stepwise · AI 刷题助手（iPad）

导入题目文件 → AI 自动拆成一道道题 → 逐题作答、检查、提示、看答案 → 通过后继续和 AI 聊这道题或让它出新题。

## 怎么运行

**方式一：直接在 iPad 上（不需要 Mac）**
1. 在 iPad 的 App Store 安装免费的 **Swift Playgrounds**。
2. 把整个 `Stepwise.swiftpm` 文件夹放到 iPad 上（隔空投送、iCloud 云盘，或压缩后传过去在“文件”里解压）。
3. 在“文件”里点开它，会用 Swift Playgrounds 打开，点 ▶︎ 运行。

**方式二：Mac + Xcode**
1. 安装 Xcode（App Store）。
2. 用 Xcode 打开 `Stepwise.swiftpm` 文件夹，选 iPad 模拟器或连接的 iPad，点运行。

首次打开会进入设置：选一个服务商，粘贴 API Key，选好模型，点“设为当前使用”。

## 功能

| 环节 | 说明 |
|---|---|
| 模型 | OpenAI、Claude、Gemini、DeepSeek、通义千问、Kimi、智谱 GLM、豆包、Grok、OpenRouter、硅基流动，以及任意 OpenAI 兼容接口。每家都可以“获取模型列表”，做题时右上角随时切换模型。 |
| 导入 | PDF、图片、文本（支持 GBK 编码）、相册多选、系统文档扫描、直接粘贴。扫描版 PDF 自动按图片识别，也可以手动打开“按图片识别 PDF”（适合有公式或图形的题）。 |
| 拆题 | 可以写拆分要求（如“每个小问单独成题”）。原文带的答案会作为参考答案，只给 AI 判题用，不会显示。长文件会分段处理。 |
| 公式 | 题目、批改、提示、解答、AI 出的新题都用 LaTeX 书写，用 KaTeX 排版：分数、根式、方程组、对齐推导、矩阵、积分、向量、角度等都能显示；化学式和方程式（$\ce{...}$，含反应条件）也支持。支持深色模式，过长的公式可以左右滑动。KaTeX 已打包在 App 里，离线也能正常显示公式。 |
| 作答 | 键盘输入（有常用符号栏，写了 $...$ 会显示公式预览），或用 Apple Pencil/手指手写（手写需要支持图片的模型）。 |
| 检查 | 对了 → “很好！”+ 下一题；错了 → 指出哪一步错了，但不直接给答案。 |
| 提示 | “需要进一步提示”可以一直点，每次比上次更具体一点。“给出完整答案”给出完整过程。 |
| 通过后 | 快捷按钮：总结做题技巧、讲讲解题思路、别的解法、易错点、出类似题、出更难的题，也可以自由提问。AI 出的新题会自动插到当前题后面，点“去做这道题”就能直接做。 |

API Key 存在系统钥匙串里；题库和图片存在 App 的文稿目录。

## 代码结构

```
Sources/App/
  App.swift              入口和三栏布局
  AppStore.swift         题库状态、保存、批改/提示/答案/对话/拆题流程
  LLMClient.swift        三种接口格式的流式请求（OpenAI 兼容 / Anthropic / Gemini）
  Tutor.swift            全部提示词和模型输出解析（想调整 AI 行为改这里）
  Views/RichText.swift   Markdown + LaTeX 公式显示
  KatexAssets.swift      内嵌的 KaTeX 0.16.9（MIT 许可），由 Tools/embed_katex.py 生成
  Providers.swift        服务商预设
  Importer.swift         PDF/图片/文本读取与分段
  Storage.swift          钥匙串、图片存储、图片压缩
  Views/                 界面
```

## 升级 KaTeX

```bash
curl -L https://registry.npmjs.org/katex/-/katex-<版本>.tgz | tar -xz
python3 Tools/embed_katex.py package <版本>
```

## 目前的限制
- 不能直接导入 Word 文档，请先导出为 PDF。
- DeepSeek 等纯文本模型不能看手写作答或图片题。
