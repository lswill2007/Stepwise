import Foundation
import PDFKit
import CoreGraphics
import UniformTypeIdentifiers

/// 导入的原始材料：若干页文字和/或若干张图片（JPEG）
struct ImportedMaterial {
    var name: String
    var textPages: [String] = []
    var images: [Data] = []
    var pdfData: Data?

    var isEmpty: Bool { textPages.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && images.isEmpty }

    var summary: String {
        var parts: [String] = []
        let chars = textPages.reduce(0) { $0 + $1.count }
        if chars > 0 { parts.append("\(textPages.count) 页文字，约 \(chars) 字") }
        if !images.isEmpty { parts.append("\(images.count) 张图片") }
        return parts.joined(separator: "，")
    }
}

/// 一次发给模型拆分的片段。图片较多或文字较长时分多次处理，避免超出输出长度。
struct SplitChunk {
    var text: String
    var images: [Data]
}

enum Importer {
    static let maxPDFPagesAsImages = 30

    static func load(url: URL) throws -> ImportedMaterial {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let name = url.deletingPathExtension().lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension.lowercased())

        if type?.conforms(to: .pdf) == true {
            return try loadPDF(data: data, name: name, mode: .auto)
        }
        if type?.conforms(to: .image) == true {
            guard let jpeg = ImageUtil.normalizedJPEG(data) else { throw LLMError(message: "无法读取这张图片") }
            return ImportedMaterial(name: name, images: [jpeg])
        }
        if type?.conforms(to: .rtf) == true,
           let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return ImportedMaterial(name: name, textPages: [attributed.string])
        }
        if let text = decodeText(data) {
            return ImportedMaterial(name: name, textPages: [text])
        }
        throw LLMError(message: "不支持这种文件。请导入 PDF、图片或文本文件（Word 文档可以先导出为 PDF）。")
    }

    enum PDFMode {
        case auto    // 自动判断：扫描件或公式多的按图片
        case text    // 用户选择按文字
        case images  // 用户选择按图片
    }

    /// 按图片识别时把每页渲染成图片交给模型，适合扫描件或含公式、图形的 PDF。
    static func loadPDF(data: Data, name: String, mode: PDFMode) throws -> ImportedMaterial {
        guard let doc = PDFDocument(data: data) else { throw LLMError(message: "无法打开这个 PDF") }
        var material = ImportedMaterial(name: name, pdfData: data)
        let pages = (0..<doc.pageCount).compactMap { doc.page(at: $0) }
        let texts = pages.map { $0.string ?? "" }
        let totalChars = texts.reduce(0) { $0 + $1.trimmingCharacters(in: .whitespacesAndNewlines).count }
        // 几乎没有文字层的视为扫描件，只能按图片
        let looksScanned = totalChars < max(20, pages.count * 30)
        let useImages: Bool
        switch mode {
        case .images: useImages = true
        case .text: useImages = looksScanned
        case .auto: useImages = looksScanned || (looksFormulaHeavy(texts) && pages.count <= maxPDFPagesAsImages)
        }

        if useImages {
            guard pages.count <= maxPDFPagesAsImages else {
                throw LLMError(message: "PDF 有 \(pages.count) 页，按图片识别最多支持 \(maxPDFPagesAsImages) 页，请拆分后再导入。")
            }
            material.images = pages.compactMap(render)
        } else {
            material.textPages = texts
        }
        return material
    }

    /// 公式在 PDF 文字层里会被拆成大量零碎短行（上下标、分子分母各占一行），这类 PDF 按文字导入会丢失公式结构。
    static func looksFormulaHeavy(_ texts: [String]) -> Bool {
        let lines = texts.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 20 else { return false }
        let short = lines.filter { $0.count <= 3 }.count
        return Double(short) / Double(lines.count) > 0.12
    }

    static func render(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2.5, 1800 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage().flatMap { ImageUtil.jpeg($0) }
    }

    static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        // 中文 Windows 常见的 GBK / GB18030 编码
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(data: data, encoding: .utf16)
    }

    /// 分段发给模型。相邻两段重叠一页，避免“题目在这一页、解析在下一页”被切开；重复的题目在合并时去重。
    static func chunks(for material: ImportedMaterial, maxChars: Int = 6000, imagesPerChunk: Int = 4) -> [SplitChunk] {
        var result: [SplitChunk] = []

        // 文字：按页累积到 maxChars，下一段从上一段的最后一页开始
        let pages = material.textPages.flatMap { page -> [String] in
            page.count > maxChars ? splitLong(page, maxChars: maxChars) : [page]
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var start = 0
        while start < pages.count {
            var end = start
            var length = pages[start].count
            while end + 1 < pages.count && length + pages[end + 1].count <= maxChars {
                end += 1
                length += pages[end].count
            }
            result.append(SplitChunk(text: pages[start...end].joined(separator: "\n"), images: []))
            if end + 1 >= pages.count { break }
            start = end > start ? end : end + 1
        }

        // 图片：每段 imagesPerChunk 页，重叠一页
        let images = material.images
        if !images.isEmpty {
            var first = 0
            while true {
                let last = min(first + imagesPerChunk, images.count)
                result.append(SplitChunk(text: "", images: Array(images[first..<last])))
                if last >= images.count { break }
                first = last - 1
            }
        }
        return result
    }

    /// 单页过长时按行切开
    private static func splitLong(_ text: String, maxChars: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count > maxChars && !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
