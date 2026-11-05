import SwiftUI

// MARK: - 学习时间

/// 自动统计学习时间：一分钟内有操作（点、写、翻页、打字）的时间算学习，长时间不动的不算。
/// 按天记在本机，设置首页实时显示累计，可以让 AI 写周报
@MainActor
final class StudyTracker: ObservableObject {
    /// 停多久不动就不算学习
    static let idleLimit: TimeInterval = 60

    /// 日期（yyyy-MM-dd）→ 学习秒数
    @Published private(set) var daily: [String: Double]
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
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        if Int(now.timeIntervalSince1970) % 10 == 0 { NSLog("DBG tick %f idle %f", dt, now.timeIntervalSince(lastActivity)) }
        lastTick = now
        // 退到后台再回来时中间那段不算；一分钟内没有操作也不算
        guard dt > 0, dt < 5, now.timeIntervalSince(lastActivity) <= Self.idleLimit else { return }
        daily[Self.key(now), default: 0] += dt
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
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
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

/// 浮在页面上的时钟：颜色和系统深浅色反过来（浅色模式黑底白字，深色模式白底黑字），对比度高；
/// 可以拖到任何位置，双指缩放大小
struct FloatingClock: View {
    @AppStorage("clockX") private var x: Double = 0.85
    @AppStorage("clockY") private var y: Double = 0.06
    @AppStorage("clockScale") private var scale: Double = 1
    @Environment(\.colorScheme) private var colorScheme
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let s = min(max(scale * pinch, 0.6), 3)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.system(size: 28 * s, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 14 * s)
                    .padding(.vertical, 6 * s)
                    // 和系统色调反过来：高对比度
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .background(colorScheme == .dark ? Color.white : Color.black, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            }
            .position(x: geo.size.width * x + drag.width, y: geo.size.height * y + drag.height)
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        x = min(max(x + value.translation.width / geo.size.width, 0.05), 0.95)
                        y = min(max(y + value.translation.height / geo.size.height, 0.03), 0.97)
                    }
                    .simultaneously(with: MagnificationGesture()
                        .updating($pinch) { value, state, _ in state = value }
                        .onEnded { scale = min(max(scale * $0, 0.6), 3) })
            )
            .accessibilityLabel("时钟，可以拖动和缩放")
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
            lines.append("\(StudyTracker.key(day))：学习 \(StudyTracker.duration(tracker.seconds(on: day)))，做了 \(st.questions) 道题，作答 \(st.submissions) 次，做对 \(st.correct) 次，提示 \(st.hints) 次")
        }
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? start
        var hard: [String] = []
        for set in sets {
            for q in set.questions {
                let week = q.messages.filter { $0.createdAt >= start && $0.createdAt < end }
                let wrong = week.filter { $0.kind == .verdictWrong }.count
                let hints = week.filter { $0.kind == .hint }.count
                guard wrong + hints > 0 else { continue }
                hard.append("- 「\(set.noteID.flatMap { note($0)?.title } ?? set.title)」第 \(q.label) 题（错 \(wrong) 次，提示 \(hints) 次）：\(Tutor.clip(Tutor.plainPreview(q.content), 80))")
            }
        }
        var s = "【每天】\n" + lines.joined(separator: "\n")
        s += "\n\n【这周卡住过的题】\n" + (hard.isEmpty ? "没有" : hard.prefix(12).joined(separator: "\n"))
        s += "\n\n【错题本】现在有 \(starredEntries.count) 道"
        if !notes.isEmpty {
            s += "\n\n【笔记】" + notes.prefix(8).map(\.title).joined(separator: "、")
        }
        return s
    }

    static let weeklySystem = """
    你是一位温和、具体的学习教练，根据学生这一周在 App 里的学习记录写一份周报。
    结构（Markdown，用 ### 小标题）：本周概况（2–3 句，点出总时长和节奏）、做得好的地方、需要加强的地方（结合卡住过的题，说出具体知识点）、下周建议（3 条以内，可执行）。
    语气鼓励但不空泛，不编造记录里没有的内容，不超过 400 字。
    """
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
                    Text(weekOffset == 0 ? "本周" : weekOffset == 1 ? "上周" : "\(weekOffset) 周前").textCase(nil)
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
        // 日期、星期用中文显示
        .environment(\.locale, Locale(identifier: "zh_CN"))
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
                Text("已使用 Stepwise 学习")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    number(tracker.studyDays, "天")
                    number(total / 3600, "小时")
                    number(total % 3600 / 60, "分钟")
                }
                Text("今天 \(StudyTracker.duration(tracker.todaySeconds))")
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
