# Stepwise · AI 刷题助手（iPad）

- **做题**：导入题目文件 → AI 自动拆成一道道题 → 整个题集是一本笔记本，在题目下面直接手写 → 批改写在页边和笔迹上，提示一档一档给，圈出某一步可以单独问 → 做完总结技巧或出变式题。
- **笔记**：导入课件、讲义或教材 → AI 按要求整理成可编辑的笔记 → 在笔记上写字、画荧光笔，圈住一段提问，回答写在页边 → 没有例题的知识点后面加练习题，直接手写、批改 → 做题卡住时先引导回笔记看相关知识点。
- **学习工具**：自动统计学习时间、学习日志和 AI 周报、浮动时钟。

## 怎么运行

**方式一：直接在 iPad 上（不需要 Mac）**
1. 在 iPad 的 App Store 安装免费的 **Swift Playgrounds**。
2. 把整个 `Stepwise.swiftpm` 文件夹放到 iPad 上（隔空投送、iCloud 云盘，或压缩后传过去在“文件”里解压）。
3. 在“文件”里点开它，会用 Swift Playgrounds 打开，点 ▶︎ 运行。

**方式二：Mac + Xcode**
1. 安装 Xcode（App Store）。
2. 用 Xcode 打开 `Stepwise.swiftpm` 文件夹，选 iPad 模拟器或连接的 iPad，点运行。

首次打开会进入设置：选一个服务商，粘贴 API Key，选好模型，点“设为当前使用”。申请 API Key、选模型的详细教程见仓库根目录的 README.md。

## 功能

| 环节 | 说明 |
|---|---|
| 模型 | OpenAI、Claude、Gemini、DeepSeek、通义千问、Kimi、智谱 GLM、豆包、Grok，以及 OpenRouter、AIHubMix、302.AI、DMXAPI、硅基流动等聚合平台和任意 OpenAI 兼容接口。模型浏览器可以搜索、按厂商筛选、标出能看图的模型；星标常用模型后，做题时右上角的菜单只显示常用模型。批改与提示、出新题、整理笔记可以各选一个单独的模型；选模型时，批改推荐快速看图的模型，整理笔记推荐上下文长、能力强的模型（`ModelInfo.longContextScore`）。 |
| 导入 | PDF、图片、文本（支持 GBK 编码）、相册多选、系统文档扫描、直接粘贴。扫描版 PDF 自动按图片识别，也可以手动打开“按图片识别 PDF”（适合有公式或图形的题）。 |
| 拆题 | 可以写拆分要求（如“每个小问单独成题”）。选择题的选项一定放进题干，漏了会自动补全；拆错了可以手动编辑题目。原文带的答案会作为参考答案，只给 AI 判题用，不会显示。长文件会分段处理。 |
| 公式 | 题目、批改（包括每一处错误的说明）、提示、解答、AI 出的新题都用 LaTeX 书写，用 KaTeX 排版：分数、根式、方程组、对齐推导、矩阵、积分、向量、角度等都能显示；化学式和方程式（$\ce{...}$，含反应条件）也支持。支持深色模式，过长的公式可以左右滑动。KaTeX 已打包在 App 里，离线也能正常显示公式。 |
| 作答 | 默认用 Apple Pencil 手写（需要支持图片的模型），手指用来翻页：每道题下面是横线纸，写到底部自动加长，也可以点“加长”；底部工具栏（`InkPalette`）贴在页面最下沿，开始书写时（`InkTools.writingBegan`，画布开始用工具时发出）自动缩成底边的小标签，点一下展开，也可以手动收起；有笔、荧光笔、橡皮、框选、圈出来问、撤销 / 重做，再点一次已选中的工具展开参数面板（`InkOptionsPanel`，参数都在 `InkTools` 里、存在 UserDefaults）。笔有钢笔 / 圆珠笔 / 签字笔（PencilKit 的 fountainPen / monoline / pen）和任意颜色；压力灵敏度、笔尖扁平度、画笔稳定性是 PencilKit 没有的，写完一笔后由 `InkShape` 重新整理这一笔（平滑点的位置、按压力和笔画方向重算每个点的粗细），换笔画时自己记撤销，一笔仍然是一步撤销。双击笔身切换橡皮擦，按住笔身侧边（Apple Pencil Pro）临时擦除；没有 Apple Pencil 时可以在工具条里允许手指书写。键盘作答可在设置里开启（写了 $...$ 会显示公式预览）。写到一半切题或退出，草稿和笔迹都会自动保存。 |
| 批改 | 对了 → 页边一个红勾 + 下一题（点开看说明）；错了 → 指出哪一步错了，但不直接给答案。手写作答发给 AI 时左边印上行号，AI 指出错在第几行，App 在那一行下面画一道淡淡的红色波浪线、标上序号（`InkAnnotations`，只定位不写字），每一处的说明写在页边，序号对得上，公式用 KaTeX 排版。批注不是笔迹，橡皮擦不到：手写区跟着书写手势看橡皮经过哪一行（`HandwritingModel.onEraserTouch`），擦过的记在 `ChatMessage.erasedMarks`，页边可以“全部显示”恢复。可以打开“快速批改”让模型少思考。 |
| 页边 | 页边只放一张当前的批注（批改、提示、圈选提问的回答，页面宽时还有完整答案，和自己的作答并排对照），之前的收成一排小标签，点哪个看哪个。完整答案可以“放大到题目下方”全宽显示，再“放回页边”；选择存在 `solutionBelow` 里。 |
| 提示 | 分三档：思路方向 → 关键一步 → 下一步写什么，按钮上写着下一档是什么，之后一直是“下一步写什么”；旁边的“说说卡在哪”可以先写下卡在哪里再要提示。“看答案”给出完整过程。 |
| 圈出来问 | 工具条上的“圈出来问”：用笔圈住自己写的某一步，选常用问题或写下想问的，AI 只针对圈住的地方回答（没做完时不给最终答案），回答贴在页边，手写区上用蓝框标出问的是哪里；接着写字时蓝框自动隐藏，点页边的“问”标签再显示。 |
| 界面 | 纸和笔的配色：米白纸色页面，墨蓝主色（`Assets.xcassets/AccentColor`），红笔批改、蓝笔答案、便签黄提示（`Ink`，在 `Views/Components.swift`）。不用彩色卡片和胶囊按钮；支持深色模式，手写纸上的批注始终用浅色模式的颜色。 |
| 通过后 | 做完之后的快捷操作在每道题右上角的 ⋯ 菜单里（页面上不放按钮，保持简洁）。默认有出类似题、出更难的题、总结做题技巧、讲讲解题思路、别的解法、易错点，可以在设置里增删、改文字、调整顺序，也可以自由提问。AI 出的变式题会自动插到当前题后面，并记住原题的作答记录，批改时特别留意同样的错误。 |
| 笔记 | 左侧“笔记”→ 导入资料生成笔记：PDF / 图片 / 文字 + 整理要求（`Tutor.noteSystem`），默认跟随当前模型，可以在设置 → 笔记里单独选一个整理长资料能力强的模型。AI 按 `<note>` 一块一块输出，流式写完一块就加进笔记；例题分三档（`NoteExerciseLevel`）：不出、必要时出（资料里没有例题的重要知识点后面输出一道 `<exercise>`）、更多例题（每个重要知识点后面 1–2 道）。每个小节下面有“出例题”，可以针对这一小节出 1–3 道，依次插在小节后面。笔记块可以编辑（Markdown + LaTeX）、加块、移动、删除；选中文字后可以解释、举例、出练习题或自由提问（`Tutor.noteAskOptions`），回答插在那一块下面。练习题存在一个隐藏的题集里（`QuestionSet.noteID`），所以批改、提示、红笔标错、圈出来问都和做题页一样。笔记存在 `notes.json`。 |
| 笔记上写画 | 每个笔记块上盖一层 PencilKit 画布，书写手势挂在下面的文字视图上（`InkHost`），所以手指照样能选字、翻页、点按钮。笔记文字按固定纸宽排版再整体缩放（`NotePaper`），页面宽窄变化时笔迹位置不会错。纸宽存在 `NoteDoc.paperWidth`：新笔记 540，旧笔记 460；旧笔记上没有涂鸦和圈注时，打开会自动换成新纸宽（`upgradePaperIfClean`），写画过的保持原样（`RichTone.legacy`，换行方式也不变）。排版：正文居中，页边有展开的批注时正文和页边一起居中（正文左移），批注都收起后回到正中，收起的批注小图标挂在那一块右边。行内公式连同后面的标点不拆行（`.im`），比一行还宽时才拆；表格尽量不换行；独立公式稍微超宽时自动缩小（`fit()`）。笔、荧光笔的颜色粗细在 `InkTools` 里。 |
| 圈出来问（笔记） | 用“圈出来问”在笔记上圈一段：圈住的文字和笔迹截图（`WKWebView.takeSnapshot`）一起发给 AI，回答存成 `NoteComment`，写在右侧页边；可以收起、放大、记到笔记。记到笔记（`saveCommentToNote`）和选中提问回答块的“整理进笔记”（`integrateAnswer`）都不照抄：用整理笔记模型，把这一节原文、整份笔记、问题和回答一起发过去（`Tutor.noteIntegrateSystem` / `noteIntegrateInstruction`），原文带行号发过去，让它说出插在哪一行后面、写一段顺着原文讲的解释（`<after>` / `<insert>`，`Tutor.insertNote` 插入，避开公式、表格、代码块中间）。原文不改；这一块上有笔迹或圈时，用 `NoteLayoutProbe` 在屏幕外按纸宽排版，量出插入点和多出来的高度，把下面的笔迹（`PKDrawing.shifted`）和圈一起往下挪；量不出来就单独成一块接在后面。 |
| 卡住时看笔记 | `NoteGuide.swift`：做错或要提示时，把同一个文件夹里笔记的小节编号发给批改模型，让它挑出关联度很高的一节、摘出重点句和极简总结；笔记页用临时荧光笔（`RichText` 的 `highlight`）标出重点，页边可以“详细记录”或回到题目。 |
| 学习时间 | `Study.swift`：窗口上挂一个永远不识别成功的手势，只记“有触摸”；每秒检查一次，一分钟内有操作就把这一秒记进当天（`studyDaily`，存在 UserDefaults）。学习日志按周显示，周报用当前模型生成。 |
| 时钟 | `FloatingClock`：颜色和系统深浅色相反，位置和大小存在 `clockX` / `clockY` / `clockScale`。 |
| 错题本 | 每题右上角可以加入错题本；在错题本里 2 轮以内（每次检查或提示算一轮）做对，就自动移出。 |
| 备份 | 设置 → 导出题目和做题记录：选择题集和笔记，导出成一个 JSON 文件（含作答记录、笔记、图片和手写笔迹，不含 API Key 和设置）。导入只新增，本机已有的题集和笔记会作为副本导入。 |

学习时间（`studyDaily`）、周报、时钟位置存在 UserDefaults，不进备份。API Key 存在系统钥匙串里；题库（`library.json`）、笔记（`notes.json`）、文件夹（`folders.json`）、图片和手写笔迹存在 App 的文稿目录。

发给 AI 的不是整段对话：之前的批改和提示会整理成一段简短的作答记录（`Tutor.progressSummary`），对话再长回复速度也不变。

## 代码结构

```
Sources/App/
  App.swift              入口和三栏布局
  AppStore.swift         题库状态、保存、批改/提示/答案/对话/拆题流程、发给模型的上下文、错题本、各用途用哪个模型
  Models.swift           题集、题目、消息、快捷操作的数据结构
  LLMClient.swift        三种接口格式的流式请求（OpenAI 兼容 / Anthropic / Gemini）
  Tutor.swift            全部提示词和模型输出解析（想调整 AI 行为改这里）
  Views/RichText.swift   Markdown + LaTeX 公式显示
  KatexAssets.swift      内嵌的 KaTeX 0.16.9（MIT 许可），由 Tools/embed_katex.py 生成
  Providers.swift        服务商预设、模型分类（厂商、能否看图、是否能对话）、推荐模型（快速看图、整理长资料）
  Importer.swift         PDF/图片/文本读取与分段
  Storage.swift          钥匙串、图片存储、图片压缩、手写笔迹
  Backup.swift           导出 / 导入题目、做题记录和笔记
  Notes.swift            笔记模式的提示词和输出解析（<note>、<exercise>、选中提问的固定选项）
  NoteStore.swift        笔记的增删改、生成笔记、选中提问、圈出来问、练习题编号
  NoteGuide.swift        做题卡住时找相关笔记、临时荧光笔、详细记录
  Study.swift            学习时间统计、学习日志和周报、浮动时钟
  InkShape.swift         笔的手感参数：稳定性平滑、压力灵敏度、扁平笔尖的粗细计算
  Assets.xcassets        主色 AccentColor（App 图标用 Swift Playgrounds 自带的叶子占位图标，在 Package.swift 里设置）
  Views/
    Notebook.swift       笔记本做题页：题目、手写区上的批注、页边批注、圈选提问
    Handwriting.swift    手写区（PencilKit）、工具栏和参数面板、导出带行号的手写图片
    Components.swift     通用组件和纸笔配色 Ink
    ListViews.swift      左侧题集、分级文件夹、题目目录、错题本
    Messages.swift       完整记录里的消息、编辑题目
    ImportView.swift     导入题目
    NoteViews.swift      笔记：导入资料生成笔记、目录、笔记页（文字块、练习块、选中提问）
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
