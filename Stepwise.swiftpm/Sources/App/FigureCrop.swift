import Foundation
import CoreGraphics
import PDFKit

/// 题目里的一个图形：模型给出的大致位置。page 为 nil 表示和题干在同一张图片上。
struct FigureBox: Equatable {
    var page: Int?
    /// 左、上、右、下，按模型原样记下（一般是百分比，也兼容 0–1、千分比和像素）
    var values: [Double]
}

/// 从整页图片里截出题目的图形。模型给的位置只是大概：在本机按像素找到图形实际的边界，
/// 框小了补全（连同图上的字母、标注），框大了收紧到图形本身。
enum FigureCrop {

    // MARK: 解析 figure 属性

    /// 旧格式 figure="1"（只说有图）；新格式 figure="左,上,右,下"，可带“图片序号:”前缀，几个图用分号隔开
    static func parse(_ attribute: String?) -> (hasFigure: Bool, boxes: [FigureBox]) {
        guard let raw = attribute?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return (false, []) }
        if ["0", "false", "no", "none"].contains(raw.lowercased()) { return (false, []) }
        var boxes: [FigureBox] = []
        for part in raw.split(whereSeparator: { $0 == ";" || $0 == "；" || $0 == "|" }) {
            var text = Substring(part)
            var page: Int?
            if let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                page = Int(text[..<colon].filter(\.isNumber))
                text = text[text.index(after: colon)...]
            }
            let numbers = text.split(whereSeparator: { ",，、 ".contains($0) })
                .compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "%()[]（）"))) }
            if numbers.count == 4 { boxes.append(FigureBox(page: page, values: numbers)) }
        }
        return (true, boxes)
    }

    /// 换算成 0–1 的矩形（原点在左上角）
    static func normalizedRect(_ v: [Double], width: Int, height: Int) -> CGRect? {
        guard v.count == 4, v.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        var (l, t, r, b) = (v[0], v[1], v[2], v[3])
        let largest = max(l, t, r, b)
        let (sx, sy): (Double, Double)
        if largest <= 1.0001 { (sx, sy) = (1, 1) }
        else if largest <= 100.0001 { (sx, sy) = (100, 100) }
        else if largest <= 1000.0001 { (sx, sy) = (1000, 1000) }
        else { (sx, sy) = (Double(width), Double(height)) }
        l /= sx; r /= sx; t /= sy; b /= sy
        if r <= l || b <= t {
            // 有的模型写成 左,上,宽,高
            guard r > 0, b > 0, l + r <= 1.0001, t + b <= 1.0001 else { return nil }
            r += l; b += t
        }
        let rect = CGRect(x: l, y: t, width: r - l, height: b - t).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !rect.isNull, rect.width >= 0.02, rect.height >= 0.02 else { return nil }
        return rect
    }

    // MARK: 截图

    /// 截出一个图形。位置明显不对（框里没有笔画）时返回 nil，由调用方退回整页。
    static func crop(_ pageJPEG: Data, box: FigureBox) -> Data? {
        guard let image = ImageUtil.cgImage(from: pageJPEG),
              let target = normalizedRect(box.values, width: image.width, height: image.height),
              let map = InkMap(image) else { return nil }
        let r = map.dilation
        let guess = CGRect(x: target.minX * Double(map.width), y: target.minY * Double(map.height),
                           width: target.width * Double(map.width), height: target.height * Double(map.height))

        var found = CGRect.null
        for c in map.components(dilatedBy: r) {
            // 铺满整页的（页面边框、照片背景）不算
            if c.width > Double(map.width) * 0.9 && c.height > Double(map.height) * 0.9 { continue }
            let overlap = c.intersection(guess)
            guard !overlap.isNull else { continue }
            let centerInside = guess.contains(CGPoint(x: c.midX, y: c.midY))
            if centerInside || overlap.width * overlap.height >= 0.5 * c.width * c.height {
                found = found.union(c)
            }
        }
        guard !found.isNull else { return nil }

        // 图形和旁边的文字挨得太近会连成一片：最多比模型的框向外多出页面的 8%，不至于把整段文字截进来
        let allowed = guess.insetBy(dx: -0.08 * Double(map.width), dy: -0.08 * Double(map.height))
        found = found.intersection(allowed)
        // 连到了一大片（比如套住整页的表格），而模型框得并不大：还是按模型的框截
        let pageArea = Double(map.width * map.height)
        if found.isNull || (found.width * found.height > 0.7 * pageArea && guess.width * guess.height < 0.35 * pageArea) {
            found = guess
        }
        let pad = Double(max(map.width, map.height)) * 0.012
        let inWork = found.insetBy(dx: -pad, dy: -pad)
        let toImage = Double(image.width) / Double(map.width)
        let rect = CGRect(x: inWork.minX * toImage, y: inWork.minY * toImage,
                          width: inWork.width * toImage, height: inWork.height * toImage)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 24, rect.height >= 24, let cropped = image.cropping(to: rect) else { return nil }
        return ImageUtil.jpeg(cropped, quality: 0.85)
    }

    // MARK: 文字版 PDF 有没有图形

    /// 去掉文字层覆盖的地方以后，页面上还剩一块不小的笔画（几何图、函数图像、电路图、表格），就算有图形。
    /// 这种 PDF 按文字导入会把图丢掉。
    static func pageHasFigure(_ page: PDFPage) -> Bool {
        guard page.rotation % 360 == 0 else { return false }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return false }
        let scale = 420 / max(bounds.width, bounds.height)
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 10, h > 10, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage(), var map = InkMap(image) else { return false }

        // 擦掉每一行文字
        let lines = page.selection(for: bounds)?.selectionsByLine() ?? []
        for line in lines {
            let b = line.bounds(for: page)
            guard b.width > 0, b.height > 0 else { continue }
            let x0 = Int(((b.minX - bounds.minX) * scale).rounded(.down)) - 1
            let x1 = Int(((b.maxX - bounds.minX) * scale).rounded(.up)) + 1
            let y0 = Int(((bounds.maxY - b.maxY) * scale).rounded(.down)) - 1
            let y1 = Int(((bounds.maxY - b.minY) * scale).rounded(.up)) + 1
            map.clear(x0: x0, y0: y0, x1: x1, y1: y1)
        }
        let minW = Double(w) * 0.08, minH = Double(h) * 0.08
        return map.components(dilatedBy: max(2, map.dilation / 2)).contains { $0.width >= minW && $0.height >= minH }
    }
}

/// 缩小后的灰度图里哪些像素是笔画：比周围纸面明显更深。照片偏灰、有阴影也能分出来。
struct InkMap {
    let width: Int
    let height: Int
    private(set) var ink: [Bool]
    /// 把同一个图形里断开的线条、标注连起来的距离（像素）
    var dilation: Int { max(3, Int((Double(max(width, height)) * 0.009).rounded())) }

    init?(_ image: CGImage, maxSide: Int = 560) {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var gray = [UInt8](repeating: 255, count: w * h)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // 纸面亮度：每 20×20 一块取最亮的，再和相邻的块取最亮的
        let block = 20
        let bw = (w + block - 1) / block, bh = (h + block - 1) / block
        var blockMax = [UInt8](repeating: 0, count: bw * bh)
        for y in 0..<h {
            let row = y * w, brow = (y / block) * bw
            for x in 0..<w {
                let v = gray[row + x]
                if v > blockMax[brow + x / block] { blockMax[brow + x / block] = v }
            }
        }
        var paper = [UInt8](repeating: 0, count: bw * bh)
        for by in 0..<bh {
            for bx in 0..<bw {
                var m: UInt8 = 0
                for ny in max(0, by - 1)...min(bh - 1, by + 1) {
                    for nx in max(0, bx - 1)...min(bw - 1, bx + 1) where blockMax[ny * bw + nx] > m {
                        m = blockMax[ny * bw + nx]
                    }
                }
                paper[by * bw + bx] = m
            }
        }
        var ink = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let row = y * w, brow = (y / block) * bw
            for x in 0..<w where Int(paper[brow + x / block]) - Int(gray[row + x]) > 45 {
                ink[row + x] = true
            }
        }
        width = w
        height = h
        self.ink = ink
    }

    mutating func clear(x0: Int, y0: Int, x1: Int, y1: Int) {
        let xs = max(0, x0), xe = min(width, x1), ys = max(0, y0), ye = min(height, y1)
        guard xs < xe, ys < ye else { return }
        for y in ys..<ye {
            for x in xs..<xe { ink[y * width + x] = false }
        }
    }

    /// 笔画向外扩 r 像素后连成的一块块，返回每块的外框（缩小图里的坐标，已含扩出的 r）
    func components(dilatedBy r: Int) -> [CGRect] {
        let w = width, h = height
        // 先横向、再纵向：r 像素以内有笔画就算
        var horizontal = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let row = y * w
            var last = -Int.max / 2
            for x in 0..<w {
                if ink[row + x] { last = x }
                if x - last <= r { horizontal[row + x] = true }
            }
            last = Int.max / 2
            for x in stride(from: w - 1, through: 0, by: -1) {
                if ink[row + x] { last = x }
                if last - x <= r { horizontal[row + x] = true }
            }
        }
        var grown = [Bool](repeating: false, count: w * h)
        for x in 0..<w {
            var last = -Int.max / 2
            for y in 0..<h {
                if horizontal[y * w + x] { last = y }
                if y - last <= r { grown[y * w + x] = true }
            }
            last = Int.max / 2
            for y in stride(from: h - 1, through: 0, by: -1) {
                if horizontal[y * w + x] { last = y }
                if last - y <= r { grown[y * w + x] = true }
            }
        }

        var seen = [Bool](repeating: false, count: w * h)
        var result: [CGRect] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where grown[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var minX = w, minY = h, maxX = 0, maxY = 0
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                if x > 0, grown[p - 1], !seen[p - 1] { seen[p - 1] = true; stack.append(p - 1) }
                if x < w - 1, grown[p + 1], !seen[p + 1] { seen[p + 1] = true; stack.append(p + 1) }
                if y > 0, grown[p - w], !seen[p - w] { seen[p - w] = true; stack.append(p - w) }
                if y < h - 1, grown[p + w], !seen[p + w] { seen[p + w] = true; stack.append(p + w) }
            }
            result.append(CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        }
        return result
    }
}
