import Foundation
import os

/// 数据根目录：题库、笔记、文件夹、图片、手写笔迹都存在这里。
/// 默认是 App 沙盒里的 Documents；也可以在设置里选一个“文件”App 里的文件夹（iCloud 云盘或“我的 iPad”），
/// 这样更新或重新安装 App 之后，重新选同一个文件夹就能读到原来的数据。
enum DataLocation {
    /// 根目录下 Stepwise 自己的文件和文件夹（其他名字的文件一概不碰）
    static let libraryFile = "library.json"
    static let foldersFile = "folders.json"
    static let notesFile = "notes.json"
    static let imagesFolder = "images"
    static let drawingsFolder = "drawings"
    /// API Key、服务商和选的模型（只在用户选的文件夹里有，见 SettingsFile）
    static let settingsFile = "settings.json"
    static let jsonFiles = [foldersFile, notesFile, libraryFile]
    static let ownNames: Set<String> = [libraryFile, foldersFile, notesFile, settingsFile, imagesFolder, drawingsFolder]

    /// 选定的文件夹存成 bookmark 放在 UserDefaults；重装 App 后会清空，需要重新选
    private static let bookmarkKey = "dataFolderBookmark"

    static let defaultRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    private struct State {
        var root: URL
        /// 用户选的文件夹（正在访问中）；nil 表示用 App 内默认位置
        var custom: URL?
        var bootstrapped = false
        /// 启动时没能打开之前选的文件夹（提示用户重新选择）
        var problem: String?
    }

    /// 保存题库的后台任务也会读根目录，所以加锁
    private static let state = OSAllocatedUnfairLock(initialState: State(root: defaultRoot))

    static var root: URL { state.withLock { $0.root } }
    static var customFolder: URL? { state.withLock { $0.custom } }
    static var isCustom: Bool { customFolder != nil }
    static var launchProblem: String? { state.withLock { $0.problem } }

    static func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    static var imagesDirectory: URL { root.appendingPathComponent(imagesFolder, isDirectory: true) }
    static var drawingsDirectory: URL { root.appendingPathComponent(drawingsFolder, isDirectory: true) }

    // MARK: - 启动

    /// 启动时（读数据之前）调用一次：解析 bookmark，开始访问选定的文件夹
    static func bootstrap() {
        let done = state.withLock { s -> Bool in
            defer { s.bootstrapped = true }
            return s.bootstrapped
        }
        guard !done, let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: bookmarkResolveOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
            let accessing = folder.startAccessingSecurityScopedResource()
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                if accessing { folder.stopAccessingSecurityScopedResource() }
                throw LocationError(message: accessing ? "文件夹不存在" : "没有访问权限")
            }
            // 文件夹被移动或改名后 bookmark 过期：用新位置重新存一份
            if stale, let fresh = try? folder.bookmarkData(options: bookmarkCreateOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
            state.withLock { $0.root = folder; $0.custom = folder }
            startDownloading(folder)
        } catch {
            // 打不开就先用 App 内的位置，bookmark 留着，下次启动再试（例如 iCloud 暂时不可用）
            state.withLock { $0.problem = "找不到之前选的储存文件夹（\(error.localizedDescription)）。这次先用 App 内的位置，这里的数据和那个文件夹里的不是同一份。请到“设置 › 文件储存位置”重新选择那个文件夹。" }
        }
    }

    private static var bookmarkCreateOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    private static var bookmarkResolveOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    // MARK: - 切换

    /// 改用选定的文件夹（调用方已经处理好数据：复制过去，或者文件夹里本来就有）
    static func adopt(_ folder: URL) throws {
        // 从文件选择器拿到的地址要先开始访问才能存 bookmark；之后一直访问到切走为止
        let accessing = folder.startAccessingSecurityScopedResource()
        do {
            let bookmark = try folder.bookmarkData(options: bookmarkCreateOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            if accessing { folder.stopAccessingSecurityScopedResource() }
            throw LocationError(message: "无法记住这个文件夹：\(error.localizedDescription)")
        }
        let old = state.withLock { s -> URL? in
            let old = s.custom
            s.root = folder; s.custom = folder; s.problem = nil
            return old
        }
        if let old, old.standardizedFileURL != folder.standardizedFileURL { old.stopAccessingSecurityScopedResource() }
    }

    /// 改回 App 内默认位置
    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        let old = state.withLock { s -> URL? in
            let old = s.custom
            s.root = defaultRoot; s.custom = nil; s.problem = nil
            return old
        }
        old?.stopAccessingSecurityScopedResource()
    }

    static func isSame(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - 显示

    /// 设置里显示的位置，例如“iCloud 云盘 › Stepwise 数据”
    static func describe(_ folder: URL?) -> String {
        guard let folder else { return "App 内（默认）" }
        let path = folder.standardizedFileURL.path
        if let range = path.range(of: "/Mobile Documents/com~apple~CloudDocs") {
            let rest = path[range.upperBound...].split(separator: "/").joined(separator: " › ")
            return rest.isEmpty ? "iCloud 云盘" : "iCloud 云盘 › \(rest)"
        }
        if path.contains("/Mobile Documents/") {
            return "iCloud 云盘 › \(folder.lastPathComponent)"
        }
        // “我的 iPad”下的文件夹在 File Provider Storage 里
        if let range = path.range(of: "/File Provider Storage") {
            let rest = path[range.upperBound...].split(separator: "/").joined(separator: " › ")
            return rest.isEmpty ? "我的 iPad" : "我的 iPad › \(rest)"
        }
        return FileManager.default.displayName(atPath: path)
    }

    // MARK: - 检查文件夹里有什么

    enum Contents {
        /// 空文件夹（或只有上次没复制完的 Stepwise 图片和笔迹）：可以把当前数据复制过去
        case empty
        /// 已经有 Stepwise 数据
        case stepwise(DataSummary)
        /// 有其他文件：为了不弄乱用户的文件，不在这里存
        case otherFiles([String])
    }

    struct DataSummary {
        var sets = 0
        var questions = 0
        var notes = 0
        var folders = 0
        /// 包括笔记的练习题集
        var allSets = 0
        /// 有 settings.json（API Key 和模型设置）
        var hasSettings = false
        /// 有文件在 iCloud 里还没下载、或者读不出来
        var unreadable = false

        /// 只有空的题库文件（例如换位置之前存下的空列表），当成空文件夹
        var isEmpty: Bool { allSets == 0 && notes == 0 && folders == 0 && !hasSettings && !unreadable }

        var text: String {
            if unreadable && sets == 0 && notes == 0 { return "Stepwise 数据（暂时读不出内容，可能还没从 iCloud 下载完）" }
            return "\(sets) 个题集（\(questions) 道题）、\(notes) 篇笔记" + (hasSettings ? "，以及 API Key 和模型设置" : "")
        }
    }

    /// 在后台调用：iCloud 文件可能要先下载
    static func inspect(_ folder: URL) -> Contents {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // 没下载的 iCloud 文件显示成“.library.json.icloud”
        func realName(_ name: String) -> String {
            guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return name }
            return String(name.dropFirst().dropLast(".icloud".count))
        }
        let visible = names.map(realName).filter { !$0.hasPrefix(".") }
        if visible.contains(where: { jsonFiles.contains($0) || $0 == settingsFile }) {
            let s = summary(of: folder)
            if !s.isEmpty { return .stepwise(s) }
        }
        // 题库读不出来时留下的备份（library-backup-…json）也算 Stepwise 自己的文件
        let others = visible.filter { !ownNames.contains($0) && !$0.hasPrefix("library-backup-") }
        return others.isEmpty ? .empty : .otherFiles(others)
    }

    /// 读出文件夹里有多少题集和笔记（给用户确认用）
    static func summary(of folder: URL) -> DataSummary {
        var s = DataSummary()
        startDownloading(folder)
        let library = folder.appendingPathComponent(libraryFile)
        if exists(library) {
            if let data = try? read(library), let sets = try? JSONDecoder().decode([QuestionSet].self, from: data) {
                let own = sets.filter { $0.noteID == nil }
                s.sets = own.count
                s.questions = own.reduce(0) { $0 + $1.questions.count }
                s.allSets = sets.count
            } else {
                s.unreadable = true
            }
        }
        s.hasSettings = exists(folder.appendingPathComponent(settingsFile))
        let folders = folder.appendingPathComponent(foldersFile)
        if exists(folders) {
            if let data = try? read(folders), let list = try? JSONDecoder().decode([Folder].self, from: data) {
                s.folders = list.count
            } else {
                s.unreadable = true
            }
        }
        let notes = folder.appendingPathComponent(notesFile)
        if exists(notes) {
            if let data = try? read(notes), let docs = try? JSONDecoder().decode([NoteDoc].self, from: data) {
                s.notes = docs.count
            } else {
                s.unreadable = true
            }
        }
        return s
    }

    /// 把 Stepwise 的数据从一个根目录复制到另一个（只复制，不删除原来的）。
    /// 先复制图片和笔迹，最后写题库：中途失败时目标文件夹里没有题库文件，不会被当成一份完整的数据。
    static func copyData(from source: URL, to target: URL) throws {
        let sourceAccess = source.startAccessingSecurityScopedResource()
        let targetAccess = target.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { source.stopAccessingSecurityScopedResource() }
            if targetAccess { target.stopAccessingSecurityScopedResource() }
        }
        let fm = FileManager.default
        for folder in [imagesFolder, drawingsFolder] {
            let from = source.appendingPathComponent(folder, isDirectory: true)
            let to = target.appendingPathComponent(folder, isDirectory: true)
            let files = (try? fm.contentsOfDirectory(atPath: from.path)) ?? []
            for name in files where !name.hasPrefix(".") {
                try write(try read(from.appendingPathComponent(name)), to: to.appendingPathComponent(name))
            }
        }
        for name in jsonFiles {
            let from = source.appendingPathComponent(name)
            guard exists(from) else { continue }
            let data = try read(from)
            let to = target.appendingPathComponent(name)
            try write(data, to: to)
            // 读回来核对一遍，确认写完整了
            guard (try? read(to)) == data else {
                throw LocationError(message: "复制 \(name) 后核对不一致，请再试一次。")
            }
        }
    }

    // MARK: - 读写

    /// 让 iCloud 先把文件夹里的文件下载到本机（不等待）
    static func startDownloading(_ folder: URL) {
        let fm = FileManager.default
        guard fm.isUbiquitousItem(at: folder) else { return }
        guard let items = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items {
            try? fm.startDownloadingUbiquitousItem(at: item)
        }
    }

    /// App 内默认位置不需要协调；用户选的文件夹（可能在 iCloud 里、可能有别的 App 在读写）都用 NSFileCoordinator。
    private static func needsCoordination(_ url: URL) -> Bool {
        !url.standardizedFileURL.path.hasPrefix(defaultRoot.standardizedFileURL.path)
    }

    static func exists(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        // 还没下载的 iCloud 文件
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fm.fileExists(atPath: placeholder.path)
    }

    /// 读文件；iCloud 里还没下载的文件会先下载（协调读取会等下载完成）
    static func read(_ url: URL) throws -> Data {
        guard needsCoordination(url) else { return try Data(contentsOf: url) }
        if FileManager.default.isUbiquitousItem(at: url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        var result: Result<Data, Error> = .failure(LocationError(message: "无法读取 \(url.lastPathComponent)"))
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { actual in
            result = Result { try Data(contentsOf: actual) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    /// 原子写入（先写临时文件再替换），所在文件夹不存在时先建好
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard needsCoordination(url) else { return try data.write(to: url, options: .atomic) }
        var result: Result<Void, Error> = .success(())
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { actual in
            result = Result { try data.write(to: actual, options: .atomic) }
        }
        if let coordError { throw coordError }
        try result.get()
    }

    static func remove(_ url: URL) {
        guard needsCoordination(url) else { try? FileManager.default.removeItem(at: url); return }
        guard exists(url) else { return }
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { actual in
            try? FileManager.default.removeItem(at: actual)
        }
    }
}

struct LocationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 存在储存文件夹里的模型设置（settings.json）：服务商（含选的模型、常用模型）、API Key、各用途的模型。
/// 重装 App 后钥匙串和设置可能都没了，选回同一个文件夹就能恢复。注意 API Key 在这个文件里没有加密。
struct SettingsFile: Codable {
    var version = 1
    var providers: [ProviderConfig]
    /// 服务商 id → API Key
    var apiKeys: [String: String]
    var activeProviderID: String
    var gradingProviderID: String?
    var gradingModel: String
    var questionProviderID: String?
    var questionModel: String
    var noteProviderID: String?
    var noteModel: String
    var quickGrading: Bool?
}
