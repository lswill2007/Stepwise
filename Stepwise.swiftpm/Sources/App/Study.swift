import SwiftUI

// MARK: - 学习时间

/// 自动统计学习时间：一分钟内有操作（点、写、翻页、打字）的时间算学习，长时间不动的不算。
/// 按天记在本机，设置首页实时显示累计，可以让 AI 写周报
@MainActor
final class StudyTracker: ObservableObject {
    /// 停多久不动就不算学习
    static let idleLimit: TimeInterval = 60

    /// 日期（yyyy-MM-dd）→ 学习秒数。
    /// 不用 @Published：它每秒都在涨，每秒通知一次会让整个 App 每秒重算一遍界面，写字、翻页时隔一秒卡一下。
    /// 界面上只显示到分钟，分钟数变了才通知；要每秒刷新的地方自己用 TimelineView 读
    private(set) var daily: [String: Double]
    /// 周（这一周星期一的日期）→ AI 写的周报
    @Published var weeklyReports: [String: String] {
        didSet { UserDefaults.standard.set(weeklyReports, forKey: "studyWeeklyReports") }
    }

    private var lastActivity = Date.distantPast
    private var lastTick = Date()
    private var lastSaved = Date()
    private var timer: Timer?

    init() {
        daily = UserDefaults.standard.dictionary(forKey: "studyDaily") as? [String: Double] ?? [:]
        weeklyReports = UserDefaults.standard.dictionary(forKey: "studyWeeklyReports") as? [String: String] ?? [:]
        // 从储存文件夹恢复了学习时间：和内存里还没保存的合并，按天取较大的值
        NotificationCenter.default.addObserver(forName: .stepwisePreferencesRestored, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mergeRestored() }
        }
    }

    private func mergeRestored() {
        let restored = UserDefaults.standard.dictionary(forKey: "studyDaily") as? [String: Double] ?? [:]
        objectWillChange.send()
        daily.merge(restored) { max($0, $1) }
        let reports = UserDefaults.standard.dictionary(forKey: "studyWeeklyReports") as? [String: String] ?? [:]
        if reports != weeklyReports { weeklyReports.merge(reports) { $1 } }
        save()
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// 有操作：点、写、拖动
    func touch() { lastActivity = Date() }

    func start() {
        guard timer == nil else { return }
        lastTick = Date()
        // 加进 common 模式：上下翻页（手指拖着、松手滑行）时也照常计时。
        // 以前翻页时计时器停着，翻了 5 秒以上，这段时间整个不算
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        // 退到后台再回来时中间那段不算；一分钟内没有操作也不算
        guard dt > 0, dt < 5, now.timeIntervalSince(lastActivity) <= Self.idleLimit else { return }
        let key = Self.key(now)
        let minutes = Int((daily[key] ?? 0) / 60)
        daily[key, default: 0] += dt
        if Int((daily[key] ?? 0) / 60) != minutes { objectWillChange.send() }
        if now.timeIntervalSince(lastSaved) > 20 { save() }
    }

    func save() {
        lastSaved = Date()
        UserDefaults.standard.set(daily, forKey: "studyDaily")
    }

    var totalSeconds: Double { daily.values.reduce(0, +) }
    /// 学过（超过一分钟）的天数
    var studyDays: Int { daily.values.filter { $0 >= 60 }.count }
    var todaySeconds: Double { daily[Self.key(Date())] ?? 0 }

    func seconds(on date: Date) -> Double { daily[Self.key(date)] ?? 0 }

    /// “3 小时 25 分钟”
    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(minutes) 分钟") }
        return String(localized: "\(minutes / 60) 小时 \(minutes % 60) 分钟")
    }
}

/// 看整个窗口里的触摸（笔和手指都算），只记下“有操作”，不拦截任何触摸
struct ActivityDetector: View {
    let onTouch: () -> Void

    var body: some View {
        #if os(iOS)
        ActivityDetectorView(onTouch: onTouch).allowsHitTesting(false)
        #else
        Color.clear
        #endif
    }
}

#if os(iOS)
private struct ActivityDetectorView: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> SpyHost {
        let view = SpyHost()
        view.onTouch = onTouch
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: SpyHost, context: Context) {
        uiView.onTouch = onTouch
    }

    /// 放进窗口后，把手势挂到整个窗口上
    final class SpyHost: UIView {
        var onTouch: () -> Void = {}
        private var spy: TouchSpy?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, spy == nil else { return }
            let spy = TouchSpy { [weak self] in self?.onTouch() }
            window.addGestureRecognizer(spy)
            self.spy = spy
        }
    }
}

/// 永远不识别成功的手势：只用来知道有触摸，不影响其他手势和书写
private final class TouchSpy: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { handler() }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { handler() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif

// MARK: - 时钟

/// 浮在页面上的时钟：液态玻璃，文字颜色跟随系统深浅色（iPadOS 26 以前用毛玻璃）；
/// 拖动时跟着手指走，松手后贴到最近的一个角：左上角在顶栏下面、下面的角在工具栏上面；双指缩放大小。
/// 拖到右上角就收进顶栏（TopBarClock），不再浮在页面上——以前浮在右上角时会挡住题目右上角的“加入收藏”
struct FloatingClock: View {
    /// 贴在哪个角：x < 0.5 是左边，y < 0.5 是上面（以前存的是任意位置，按离哪个角近换算）
    @AppStorage("clockX") private var x: Double = 0.85
    @AppStorage("clockY") private var y: Double = 0.06
    @AppStorage("clockScale") private var scale: Double = 1
    /// 松手时从手指的位置滑回角上，不是一下跳过去
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.3))) private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @State private var size = CGSize(width: 100, height: 44)

    /// 离边的距离：上面让出顶栏（标题和右上角按钮），下面让出底部的工具栏
    private static let topInset: CGFloat = 64
    private static let bottomInset: CGFloat = 100
    private static let sideInset: CGFloat = 20

    /// 贴在某个角时，时钟中心的位置
    private func anchor(left: Bool, top: Bool, in area: CGSize) -> CGPoint {
        CGPoint(x: left ? Self.sideInset + size.width / 2 : area.width - Self.sideInset - size.width / 2,
                y: top ? Self.topInset + size.height / 2 : area.height - Self.bottomInset - size.height / 2)
    }

    var body: some View {
        GeometryReader { geo in
            if !TopBarClock.isDocked(x: x, y: y) {
                floating(in: geo)
            }
        }
    }

    private func floating(in geo: GeometryProxy) -> some View {
        Group {
            let s = min(max(scale * pinch, 0.6), 3)
            let home = anchor(left: x < 0.5, top: y < 0.5, in: geo.size)
            // 只显示到分钟：每分钟刷新一次就够，每秒重画玻璃效果白白占用写字的时间
            TimelineView(.everyMinute) { context in
                ClockFace(date: context.date, scale: s)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .position(x: home.x + drag.width, y: home.y + drag.height)
            .animation(.spring(duration: 0.3), value: home)
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        // 松手的位置（算上甩出去的速度）离哪个角近就贴到哪个角
                        let end = CGPoint(x: home.x + value.predictedEndTranslation.width,
                                          y: home.y + value.predictedEndTranslation.height)
                        x = end.x < geo.size.width / 2 ? 0 : 1
                        y = end.y < geo.size.height / 2 ? 0 : 1
                    }
                    .simultaneously(with: MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { scale = min(max(scale * $0, 0.6), 3) })
            )
            .accessibilityLabel("时钟，可以拖动和缩放")
        }
    }
}

/// 时钟在右上角时放在顶栏里（和全屏、模型菜单同一行），不挡页面上的东西。
/// 点一下可以把它移到别的角，移出去以后又浮在页面上、可以拖动缩放
struct TopBarClock: View {
    @AppStorage("clockEnabled") private var enabled = false
    @AppStorage("clockX") private var x: Double = 0.85
    @AppStorage("clockY") private var y: Double = 0.06

    /// 右上角就是收进顶栏
    static func isDocked(x: Double, y: Double) -> Bool { x >= 0.5 && y < 0.5 }

    var body: some View {
        if enabled && Self.isDocked(x: x, y: y) {
            Menu {
                Button("移到左上角", systemImage: "arrow.up.left") { move(left: true, top: true) }
                Button("移到左下角", systemImage: "arrow.down.left") { move(left: true, top: false) }
                Button("移到右下角", systemImage: "arrow.down.right") { move(left: false, top: false) }
            } label: {
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
            }
            .accessibilityLabel("时钟")
            .accessibilityHint(L("点一下可以移到别的角"))
        }
    }

    private func move(left: Bool, top: Bool) {
        withAnimation(.spring(duration: 0.3)) {
            x = left ? 0 : 1
            y = top ? 0 : 1
        }
    }
}

/// 时钟的样子：液态玻璃胶囊，文字跟随系统颜色
private struct ClockFace: View {
    let date: Date
    let scale: CGFloat

    var body: some View {
        let label = Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .font(.system(size: 28 * scale, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(.horizontal, 14 * scale)
            .padding(.vertical, 6 * scale)
        if #available(iOS 26.0, macOS 26.0, *) {
            label.glassEffect(.regular, in: Capsule())
        } else {
            label
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
    }
}

// MARK: - 学习日志和周报

extension AppStore {
    struct DayStats {
        var submissions = 0
        var correct = 0
        var hints = 0
        var questions = 0
    }

    /// 某一天的做题情况：交了几次作答、做对几次、要了几次提示、做了几道题
    func dayStats(_ date: Date) -> DayStats {
        let cal = Calendar.current
        var stats = DayStats()
        for set in sets {
            for q in set.questions {
                let today = q.messages.filter { cal.isDate($0.createdAt, inSameDayAs: date) }
                guard !today.isEmpty else { continue }
                stats.questions += 1
                stats.submissions += today.filter { $0.kind == .submission }.count
                stats.correct += today.filter { $0.kind == .verdictCorrect }.count
                stats.hints += today.filter { $0.kind == .hint }.count
            }
        }
        return stats
    }

    /// 写周报给 AI 的材料：每天的学习时间和做题情况、这周做错或要过提示的题、笔记
    func weekMaterial(start: Date, tracker: StudyTracker) -> String {
        let cal = Calendar.current
        var lines: [String] = []
        for i in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: i, to: start) else { continue }
            let st = dayStats(day)
            let time = StudyTracker.duration(tracker.seconds(on: day))
            lines.append(Tutor.pick(
                "\(StudyTracker.key(day))：学习 \(time)，做了 \(st.questions) 道题，作答 \(st.submissions) 次，做对 \(st.correct) 次，提示 \(st.hints) 次",
                "\(StudyTracker.key(day)): studied \(time), \(Tutor.count(st.questions, "question", "questions")), "
                    + "\(Tutor.count(st.submissions, "attempt", "attempts")), \(st.correct) correct, \(Tutor.count(st.hints, "hint", "hints"))"))
        }
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? start
        var hard: [String] = []
        for set in sets {
            for q in set.questions {
                let week = q.messages.filter { $0.createdAt >= start && $0.createdAt < end }
                let wrong = week.filter { $0.kind == .verdictWrong }.count
                let hints = week.filter { $0.kind == .hint }.count
                guard wrong + hints > 0 else { continue }
                let title = set.noteID.flatMap { note($0)?.title } ?? set.title
                let preview = Tutor.clip(Tutor.plainPreview(q.content), 80)
                hard.append(Tutor.pick("- 「\(title)」第 \(q.label) 题（错 \(wrong) 次，提示 \(hints) 次）：\(preview)",
                                       "- \"\(title)\" question \(q.label) (\(wrong) wrong, \(Tutor.count(hints, "hint", "hints"))): \(preview)"))
            }
        }
        var s = Tutor.pick("【每天】\n", "[Each day]\n") + lines.joined(separator: "\n")
        s += Tutor.pick("\n\n【这周卡住过的题】\n", "\n\n[Questions they got stuck on this week]\n")
            + (hard.isEmpty ? Tutor.pick("没有", "None") : hard.prefix(12).joined(separator: "\n"))
        s += Tutor.pick("\n\n【收藏的题】现在有 \(starredCount) 道", "\n\n[Favorites] \(Tutor.count(starredCount, "question", "questions")) now")
        if !notes.isEmpty {
            s += Tutor.pick("\n\n【笔记】", "\n\n[Notes] ") + notes.prefix(8).map(\.title).joined(separator: Tutor.pick("、", ", "))
        }
        return s
    }

    static var weeklySystem: String {
        Tutor.pick("""
        你是一位温和、具体的学习教练，根据学生这一周在 App 里的学习记录写一份周报。
        结构（Markdown，用 ### 小标题）：本周概况（2–3 句，点出总时长和节奏）、做得好的地方、需要加强的地方（结合卡住过的题，说出具体知识点）、下周建议（3 条以内，可执行）。
        语气鼓励但不空泛，不编造记录里没有的内容，不超过 400 字。
        """, """
        You are a warm, specific study coach. Based on the student's study record in the app this week, write a weekly report.
        Structure (Markdown, ### subheadings): This week at a glance (2–3 sentences on total time and pace), What went well, What to work on (refer to the questions they got stuck on and name the specific concepts), Suggestions for next week (at most 3, actionable).
        Be encouraging but not vague, don't invent anything that isn't in the record, and keep it under 250 words.
        """)
    }
}

/// 设置里的“学习日志”：最近两周每天的学习时间、做题情况，和 AI 周报
struct StudyLogView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var tracker: StudyTracker
    @State private var weekOffset = 0
    @State private var writing = false
    @State private var streaming = ""

    private var weekStart: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return cal.date(byAdding: .day, value: -7 * weekOffset, to: start) ?? start
    }

    var body: some View {
        List {
            Section {
                let days = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
                let maxSeconds = max(days.map { tracker.seconds(on: $0) }.max() ?? 0, 1800)
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(days, id: \.self) { day in
                        let sec = tracker.seconds(on: day)
                        VStack(spacing: 4) {
                            Text(sec >= 60 ? "\(Int(sec / 60))′" : "").font(.caption2).foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Calendar.current.isDateInToday(day) ? Ink.pen : Ink.pen.opacity(0.45))
                                .frame(height: max(3, 110 * sec / maxSeconds))
                            Text(day, format: .dateTime.weekday(.narrow)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 150)
                .padding(.vertical, 6)
                ForEach(days.reversed(), id: \.self) { day in
                    let st = store.dayStats(day)
                    let sec = tracker.seconds(on: day)
                    if sec >= 60 || st.questions > 0 {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(day, format: .dateTime.month().day().weekday(.wide))
                                Spacer()
                                Text(StudyTracker.duration(sec)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            if st.questions > 0 {
                                Text("做了 \(st.questions) 道题 · 作答 \(st.submissions) 次 · 做对 \(st.correct) 次 · 提示 \(st.hints) 次")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Button { weekOffset += 1 } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(weekOffset == 0 ? L("本周") : weekOffset == 1 ? L("上周") : String(localized: "\(weekOffset) 周前")).textCase(nil)
                    Spacer()
                    Button { weekOffset -= 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(weekOffset == 0)
                }
                .buttonStyle(.borderless)
            }

            Section {
                let key = StudyTracker.key(weekStart)
                if writing {
                    if streaming.isEmpty {
                        HStack { ProgressView(); Text("正在写周报…").foregroundStyle(.secondary) }
                    } else {
                        RichText(streaming)
                    }
                } else if let report = tracker.weeklyReports[key] {
                    RichText(report)
                    Button("重新生成") { write(key: key) }
                } else {
                    Button {
                        write(key: key)
                    } label: {
                        Label("生成这周的学习周报", systemImage: "doc.text")
                    }
                }
            } header: {
                Text("周报")
            } footer: {
                Text("周报由当前模型根据这周的学习时间、做题记录和错题写成，只在本机保存。")
            }
        }
        .navigationTitle("学习日志")
    }

    private func write(key: String) {
        guard let client = try? store.makeClient(for: .chat) else { return }
        let material = store.weekMaterial(start: weekStart, tracker: tracker)
        writing = true
        streaming = ""
        Task {
            var full = ""
            do {
                for try await piece in client.stream(system: AppStore.weeklySystem,
                                                     messages: [LLMMessage(role: .user, parts: [.text(material)])]) {
                    full += piece
                    streaming = full
                }
                if !full.isEmpty { tracker.weeklyReports[key] = full.trimmingCharacters(in: .whitespacesAndNewlines) }
            } catch {
                store.errorMessage = error.localizedDescription
            }
            writing = false
        }
    }
}

/// 设置首页最上面：“已经用 Stepwise 学了 …”，实时更新
struct StudySummaryRow: View {
    @EnvironmentObject var tracker: StudyTracker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let total = Int(tracker.totalSeconds)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("已使用 Stepwise 学习"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    number(tracker.studyDays, L("天"))
                    number(total / 3600, L("小时"))
                    number(total % 3600 / 60, L("分钟"))
                }
                Text(String(localized: "今天 \(StudyTracker.duration(tracker.todaySeconds))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func number(_ n: Int, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(n)").font(.title.weight(.semibold)).monospacedDigit()
            Text(unit).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.trailing, 8)
    }
}
