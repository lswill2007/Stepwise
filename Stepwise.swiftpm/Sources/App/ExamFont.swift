import Foundation

/// 正文字体：试卷上常见的样子，中文宋体、英文和数字 Times New Roman。
///
/// iPad 自带 Times New Roman，但没有宋体（系统能下载的“宋体-简”网页用不上），所以内置思源宋体
///（Noto Serif SC / HK，SIL 开源字体许可，见 Resources/Fonts/NotoSerifCJK-OFL.txt），
/// 只留常用的九千多个字和标点（GB2312 全部汉字 + Big5 常用字），由 Tools/subset_fonts.py 生成。
/// 字表以外的生僻字照旧用系统的黑体显示。
///
/// 排版都在网页里（RichText、导出 PDF），网页只能读自己目录里的文件，所以启动时把字体放到网页目录的 fonts 里
enum ExamFont {
    struct Face {
        let family: String
        let file: String
        let weight: Int
    }

    /// 界面是繁体时先用香港字形，简体字用简体字形补上；其余用简体字形（里面也有常用的繁体字）
    static let faces: [Face] = {
        let simplified = [Face(family: "ExamSong", file: "ExamSong-SC-Regular.otf", weight: 400),
                          Face(family: "ExamSong", file: "ExamSong-SC-Bold.otf", weight: 700)]
        guard UILanguage.isTraditional else { return simplified }
        return [Face(family: "ExamSong", file: "ExamSong-HK-Regular.otf", weight: 400),
                Face(family: "ExamSong", file: "ExamSong-HK-Bold.otf", weight: 700),
                Face(family: "ExamSongAlt", file: "ExamSong-SC-Regular.otf", weight: 400),
                Face(family: "ExamSongAlt", file: "ExamSong-SC-Bold.otf", weight: 700)]
    }()

    /// 原来的字体（系统黑体）：字体放不进去时、写画过的旧笔记都用它
    static let sansStack = #"-apple-system,"PingFang SC","Hiragino Sans GB","Helvetica Neue",sans-serif"#

    /// 英文、数字用的 Times New Roman。中文界面里弯引号“”、省略号、破折号不让它画：
    /// 它画出来是英文的窄引号，夹在汉字中间挤在一起；留给宋体画成占一个字宽的中文标点
    private static let latinFaces: [(weight: Int, style: String, name: String)] = [
        (400, "normal", "TimesNewRomanPSMT"), (700, "normal", "TimesNewRomanPS-BoldMT"),
        (400, "italic", "TimesNewRomanPS-ItalicMT"), (700, "italic", "TimesNewRomanPS-BoldItalicMT")
    ]
    private static let latinRange = "U+0-B6,U+B8-3FF,U+1E00-1EFF,U+2010-2013,U+2018-2019,U+2020-2022,U+2030-2044,U+20A0-20BF,U+2122"

    /// 试卷字体：英文数字 Times New Roman，中文宋体，字表以外的字用系统黑体
    static func serifStack(cjk: String = #""PingFang SC","Hiragino Sans GB""#) -> String {
        let latin = UILanguage.isEnglish ? "\"Times New Roman\"" : "ExamLatin"
        return "\(latin),ExamSong,ExamSongAlt,\"Times New Roman\",\(cjk),serif"
    }

    /// 网页里声明字体的样式（相对网页目录）
    static let fontFaceCSS: String = {
        var css = faces.map {
            "@font-face{font-family:\($0.family);font-weight:\($0.weight);src:url(fonts/\($0.file)) format(\"opentype\")}"
        }
        if !UILanguage.isEnglish {
            css += latinFaces.map {
                "@font-face{font-family:ExamLatin;font-weight:\($0.weight);font-style:\($0.style);src:local(\"\($0.name)\");unicode-range:\(latinRange)}"
            }
        }
        return css.joined(separator: "\n")
    }()

    private static func bundled(_ file: String) -> URL? {
        let name = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
        // 资源一般直接在 App 里；有的打包方式放在 App 里的一个 .bundle 里，也找一下
        // （不用 Bundle.module：找不到那个 bundle 时它会直接崩）
        let nested = (Bundle.main.urls(forResourcesWithExtension: "bundle", subdirectory: nil) ?? []).compactMap(Bundle.init(url:))
        for bundle in [Bundle.main] + nested {
            if let url = bundle.url(forResource: name, withExtension: ext)
                ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fonts") { return url }
        }
        return nil
    }

    /// 把这次要用的字体放进网页目录的 fonts 里（已经在、大小一样的不重放）。有一个放不进去就返回 false，网页照旧用系统字体
    static func install(into fonts: URL) -> Bool {
        let fm = FileManager.default
        for file in Set(faces.map(\.file)) {
            guard let source = bundled(file) else { return false }
            var target = fonts.appendingPathComponent(file)
            let size = { (url: URL) in (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value }
            if let have = size(target), have == size(source) { continue }
            do {
                try? fm.removeItem(at: target)
                try fm.copyItem(at: source, to: target)
                // 从 App 里随时能再放一份，不用占 iCloud / 电脑备份
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? target.setResourceValues(values)
            } catch {
                return false
            }
        }
        return true
    }
}
