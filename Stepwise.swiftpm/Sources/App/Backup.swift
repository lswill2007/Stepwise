import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 导出 / 导入用的备份文件：题集、作答和对话记录、图片、写了一半的手写笔迹，打包成一个 JSON 文件。
/// 不包含 API Key 和设置。
struct LibraryBackup: Codable {
    static let formatName = "stepwise-backup"

    var format = LibraryBackup.formatName
    var version = 1
    var exportedAt = Date()
    var sets: [QuestionSet]
    /// 图片文件名 → JPEG 数据
    var images: [String: Data]
    /// 题目 id → 手写笔迹（PencilKit 数据）
    var drawings: [String: Data]
    /// 题集所在的文件夹（连同上级文件夹），导入后保持同样的分类；旧版本的备份没有
    var folders: [Folder]?
    /// 笔记；笔记里的练习题在 sets 里（noteID 指向笔记）。旧版本的备份没有
    var notes: [NoteDoc]?

    /// notes：要一起导出的笔记，它们的练习题集由调用方放进 sets
    init(sets: [QuestionSet], folders allFolders: [Folder] = [], notes: [NoteDoc] = []) {
        self.sets = sets
        self.notes = notes.isEmpty ? nil : notes
        var needed: [Folder] = []
        for set in sets {
            var current = allFolders.first { $0.id == set.folderID }
            while let f = current, !needed.contains(where: { $0.id == f.id }) {
                needed.append(f)
                current = allFolders.first { $0.id == f.parentID }
            }
        }
        self.folders = needed.isEmpty ? nil : needed
        var images: [String: Data] = [:]
        for id in sets.flatMap(Self.imageIDs) {
            images[id] = ImageStore.load(id)
        }
        self.images = images
        var drawings: [String: Data] = [:]
        for q in sets.flatMap(\.questions) {
            drawings[q.id.uuidString] = DrawingStore.load(q.id)
        }
        self.drawings = drawings
    }

    /// 题集用到的所有图片：题目原图、作答和对话里的图片（包括重新练习之前的记录）
    static func imageIDs(in set: QuestionSet) -> [String] {
        set.questions.flatMap { q in
            q.imageIDs + q.messages.flatMap(\.imageIDs) + (q.previousAttempts ?? []).flatMap { $0.flatMap(\.imageIDs) }
        }
    }

    /// 写到临时文件，文件名带上日期
    func write() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let questionSets = sets.filter { $0.noteID == nil }
        let noteCount = notes?.count ?? 0
        let name = questionSets.count == 1 && noteCount == 0 ? questionSets[0].title
            : noteCount == 1 && questionSets.isEmpty ? notes![0].title
            : [questionSets.isEmpty ? nil : "\(questionSets.count) 个题集", noteCount == 0 ? nil : "\(noteCount) 篇笔记"]
                .compactMap { $0 }.joined(separator: " ")
        let safeName = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stepwise 备份 \(safeName) \(formatter.string(from: exportedAt)).json")
        // 日期格式和题库文件 library.json 一致，导入后时间一点不差
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        return url
    }

    static func read(from url: URL) throws -> LibraryBackup {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let backup = try? JSONDecoder().decode(LibraryBackup.self, from: data), backup.format == formatName else {
            throw BackupError(message: "这不是 Stepwise 导出的备份文件。要导入新的题目，请在左侧点“+”导入题目文件。")
        }
        return backup
    }
}

struct BackupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 分享时才生成备份文件（可以存到“文件”、隔空投送到另一台 iPad）
struct BackupFile: Transferable {
    let sets: [QuestionSet]
    var folders: [Folder] = []
    var notes: [NoteDoc] = []

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            SentTransferredFile(try LibraryBackup(sets: file.sets, folders: file.folders, notes: file.notes).write())
        }
    }
}

extension AppStore {
    struct ImportResult {
        var sets = 0
        var questions = 0
        /// 本机已有、作为副本导入的题集数
        var copies = 0
        var notes = 0
    }

    /// 导入备份：只新增，不覆盖本机已有的内容。
    /// 本机已有的题集作为副本导入，题集、题目和图片都换成新的 id，删除其中一份不影响另一份。
    /// select：导入后选中第一个题集。从设置里导入时不选中，否则正在显示的题目页会被替换，设置也会跟着关掉。
    func importBackup(_ backup: LibraryBackup, select: Bool = true) -> ImportResult {
        let existingSetIDs = Set(sets.map(\.id))
        let existingQuestionIDs = Set(sets.flatMap { $0.questions.map(\.id) })
        var result = ImportResult()
        var imported: [QuestionSet] = []
        // 副本导入时换了 id：笔记要跟着找到自己的练习题集和练习题
        var setIDMap: [UUID: UUID] = [:]
        var questionIDMap: [UUID: UUID] = [:]
        // 先补上本机没有的文件夹；文件夹 id 一样就是同一个文件夹
        for f in backup.folders ?? [] where !folders.contains(where: { $0.id == f.id }) {
            folders.append(f)
        }
        repairFolders()

        for var set in backup.sets {
            let originalIDs = set.questions.map(\.id)
            let clash = existingSetIDs.contains(set.id) || originalIDs.contains(where: existingQuestionIDs.contains)
            // 副本要换新的图片文件名；文件名不安全（例如带路径）的图片也一律换掉，不能写到图片目录外面
            var imageMap: [String: String] = [:]
            for id in Set(LibraryBackup.imageIDs(in: set)) where clash || !Self.isSafeFileName(id) {
                imageMap[id] = UUID().uuidString + ".jpg"
            }
            var idMap: [UUID: UUID] = [:]
            if clash {
                for id in originalIDs { idMap[id] = UUID() }
                let newID = UUID()
                setIDMap[set.id] = newID
                set.id = newID
                set.title += "（导入）"
                if set.noteID == nil { result.copies += 1 }
            }
            questionIDMap.merge(idMap) { $1 }
            if clash || !imageMap.isEmpty {
                for i in set.questions.indices {
                    Self.remap(&set.questions[i], ids: idMap, images: imageMap)
                }
            }
            // 图片：文件名本身是 UUID，本机已有同名文件就是同一张图
            for id in Set(LibraryBackup.imageIDs(in: set)) {
                let original = imageMap.first { $0.value == id }?.key ?? id
                if ImageStore.load(id) == nil, let data = backup.images[original] {
                    ImageStore.save(data, id: id)
                }
            }
            // 写了一半的手写笔迹
            for (original, q) in zip(originalIDs, set.questions) {
                if let data = backup.drawings[original.uuidString], !DrawingStore.exists(q.id) {
                    DrawingStore.save(data, for: q.id)
                }
            }
            if set.noteID == nil {
                result.sets += 1
                result.questions += set.questions.count
            }
            imported.append(set)
        }

        // 笔记：本机已有同一篇时作为副本导入；练习题集和练习题跟着换过的 id
        var importedNotes: [NoteDoc] = []
        for var doc in backup.notes ?? [] {
            let oldNoteID = doc.id
            if notes.contains(where: { $0.id == doc.id }) {
                doc.id = UUID()
                doc.title += "（导入）"
            }
            doc.exerciseSetID = setIDMap[doc.exerciseSetID] ?? doc.exerciseSetID
            for i in doc.blocks.indices {
                if let q = doc.blocks[i].questionID { doc.blocks[i].questionID = questionIDMap[q] ?? q }
            }
            for i in imported.indices where imported[i].id == doc.exerciseSetID || imported[i].noteID == oldNoteID {
                imported[i].noteID = doc.id
            }
            importedNotes.append(doc)
        }
        notes.insert(contentsOf: importedNotes, at: 0)
        result.notes = importedNotes.count

        sets.insert(contentsOf: imported, at: 0)
        if select, let first = imported.first(where: { $0.noteID == nil }) {
            selectedSetID = first.id
            selectedQuestionID = first.questions.first(where: { !$0.status.isDone })?.id ?? first.questions.first?.id
        }
        saveNow()
        return result
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
    }

    /// 副本导入时替换题目里的 id：题目本身、对话里出的新题链接、所有图片
    private static func remap(_ q: inout Question, ids: [UUID: UUID], images: [String: String]) {
        func remap(_ m: inout ChatMessage) {
            m.imageIDs = m.imageIDs.map { images[$0] ?? $0 }
            m.generatedQuestionIDs = m.generatedQuestionIDs.map { ids[$0] ?? $0 }
        }
        q.id = ids[q.id] ?? q.id
        q.imageIDs = q.imageIDs.map { images[$0] ?? $0 }
        for i in q.messages.indices { remap(&q.messages[i]) }
        if var attempts = q.previousAttempts {
            for a in attempts.indices {
                for m in attempts[a].indices { remap(&attempts[a][m]) }
            }
            q.previousAttempts = attempts
        }
    }
}
