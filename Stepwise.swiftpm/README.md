# Stepwise · AI 刷题助手（iPad）

导入题目文件 → AI 自动拆成一道道题 → 整个题集是一本笔记本，在题目下面直接手写 → 批改写在页边和笔迹上，提示一档一档给，圈出某一步可以单独问 → 做完总结技巧或出变式题。

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
| 模型 | OpenAI、Claude、Gemini、DeepSeek、通义千问、Kimi、智谱 GLM、豆包、Grok，以及 OpenRouter、AIHubMix、302.AI、DMXAPI、硅基流动等聚合平台和任意 OpenAI 兼容接口。模型浏览器可以搜索、按厂商筛选、标出能看图的模型；星标常用模型后，做题时右上角的菜单只显示常用模型。批改与提示、出新题可以各选一个单独的模型。 |
| 导入 | PDF、图片、文本（支持 GBK 编码）、相册多选、系统文档扫描、直接粘贴。扫描版 PDF 自动按图片识别，也可以手动打开“按图片识别 PDF”（适合有公式或图形的题）。 |
| 拆题 | 可以写拆分要求（如“每个小问单独成题”）。选择题的选项一定放进题干，漏了会自动补全；拆错了可以手动编辑题目。原文带的答案会作为参考答案，只给 AI 判题用，不会显示。长文件会分段处理。 |
| 公式 | 题目、批改（包括手写纸上的短评）、提示、解答、AI 出的新题都用 LaTeX 书写，用 KaTeX 排版：分数、根式、方程组、对齐推导、矩阵、积分、向量、角度等都能显示；化学式和方程式（$\ce{...}$，含反应条件）也支持。支持深色模式，过长的公式可以左右滑动。KaTeX 已打包在 App 里，离线也能正常显示公式。 |
| 作答 | 默认用 Apple Pencil 手写（需要支持图片的模型），手指用来翻页：每道题下面是横线纸，写到底部自动加长，也可以点“加长”；底部工具条有笔、橡皮、框选、圈出来问、撤销，双击笔身切换橡皮擦，按住笔身侧边（Apple Pencil Pro）临时擦除；没有 Apple Pencil 时可以在工具条里允许手指书写。键盘作答可在设置里开启（写了 $...$ 会显示公式预览）。写到一半切题或退出，草稿和笔迹都会自动保存。 |
| 批改 | 对了 → 页边一个红勾 + 下一题（点开看说明）；错了 → 指出哪一步错了，但不直接给答案。手写作答发给 AI 时左边印上行号，AI 指出错在第几行，App 在那一行下面画红色波浪线、写上短评，页边用同样的序号（①②③）列出；短评里的公式用 KaTeX 排版（`InkAnnotations` 把 RichText 叠在手写纸上）。可以打开“快速批改”让模型少思考。 |
| 页边 | 页边只放一张当前的批注（批改、提示、圈选提问的回答，页面宽时还有完整答案，和自己的作答并排对照），之前的收成一排小标签，点哪个看哪个。 |
| 提示 | 分三档：思路方向 → 关键一步 → 下一步写什么，按钮上写着下一档是什么，之后一直是“下一步写什么”；旁边的“说说卡在哪”可以先写下卡在哪里再要提示。“看答案”给出完整过程。 |
| 圈出来问 | 工具条上的“圈出来问”：用笔圈住自己写的某一步，选常用问题或写下想问的，AI 只针对圈住的地方回答（没做完时不给最终答案），回答贴在页边，手写区上用蓝框标出问的是哪里；接着写字时蓝框自动隐藏，点页边的“问”标签再显示。 |
| 界面 | 纸和笔的配色：米白纸色页面，墨蓝主色（`Assets.xcassets/AccentColor`），红笔批改、蓝笔答案、便签黄提示（`Ink`，在 `Views/Components.swift`）。不用彩色卡片和胶囊按钮；支持深色模式，手写纸上的批注始终用浅色模式的颜色。 |
| 通过后 | 快捷按钮（默认：出类似题、出更难的题、总结做题技巧、讲讲解题思路、别的解法、易错点）可以在设置里增删、改文字、调整顺序，也可以自由提问。AI 出的变式题会自动插到当前题后面，并记住原题的作答记录，批改时特别留意同样的错误。 |
| 错题本 | 每题右上角可以加入错题本；在错题本里 2 轮以内（每次检查或提示算一轮）做对，就自动移出。 |
| 备份 | 设置 → 导出题目和做题记录：选择题集，导出成一个 JSON 文件（含作答记录、图片和手写笔迹，不含 API Key 和设置）。导入只新增，本机已有的题集会作为副本导入。 |

API Key 存在系统钥匙串里；题库、图片和手写笔迹存在 App 的文稿目录。

发给 AI 的不是整段对话：之前的批改和提示会整理成一段简短的作答记录（`Tutor.progressSummary`），对话再长回复速度也不变。

## 代码结构

```
Sources/App/
  App.swift              入口和三栏布局
  AppStore.swift         题库状态、保存、批改/提示/答案/对话/拆题流程、发给模型的上下文、错题本
  Models.swift           题集、题目、消息、快捷操作的数据结构
  LLMClient.swift        三种接口格式的流式请求（OpenAI 兼容 / Anthropic / Gemini）
  Tutor.swift            全部提示词和模型输出解析（想调整 AI 行为改这里）
  Views/RichText.swift   Markdown + LaTeX 公式显示
  KatexAssets.swift      内嵌的 KaTeX 0.16.9（MIT 许可），由 Tools/embed_katex.py 生成
  Providers.swift        服务商预设、模型分类（厂商、能否看图、是否能对话）
  Importer.swift         PDF/图片/文本读取与分段
  Storage.swift          钥匙串、图片存储、图片压缩、手写笔迹
  Backup.swift           导出 / 导入题目和做题记录
  Assets.xcassets        主色 AccentColor（App 图标用 Swift Playgrounds 自带的叶子占位图标，在 Package.swift 里设置）
  Views/
    Notebook.swift       笔记本做题页：题目、手写区上的批注、页边批注、圈选提问
    Handwriting.swift    手写区（PencilKit）、工具条、导出带行号的手写图片
    Components.swift     通用组件和纸笔配色 Ink
    ListViews.swift      左侧题集、分级文件夹、题目目录、错题本
    Messages.swift       完整记录里的消息、编辑题目
    ImportView.swift     导入题目
    SettingsView.swift   设置；ModelBrowser.swift 模型浏览器；ConsentView.swift 首次使用说明
```

## 升级 KaTeX

```bash
curl -L https://registry.npmjs.org/katex/-/katex-<版本>.tgz | tar -xz
python3 Tools/embed_katex.py package <版本>
```

更新日志见仓库根目录的 README.md。

## 目前的限制
- 不能直接导入 Word 文档，请先导出为 PDF。
- DeepSeek 等纯文本模型不能看手写作答或图片题。
