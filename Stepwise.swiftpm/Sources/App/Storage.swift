import Foundation
import Security
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// API Key 存在系统钥匙串里；选了文件储存位置时，另外在那个文件夹的 settings.json 里存一份（见 SettingsFile）。
enum Keychain {
    private static let service = "com.lswill2007.stepwise.apikeys"

    /// 读过的 Key 记在内存里：界面每次刷新都要看哪家填了 Key（模型菜单），每次都查钥匙串会让页面一刷新就卡一下。
    /// 所有写入都走 set，记下的不会过时
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func get(_ account: String) -> String? {
        lock.lock()
        let cached = cache[account]
        lock.unlock()
        if let cached { return cached }
        let value = read(account)
        lock.lock()
        cache[account] = .some(value)
        lock.unlock()
        return value
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        lock.lock()
        cache[account] = .some(value.isEmpty ? nil : value)
        lock.unlock()
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// 图片单独存成文件，题库 JSON 里只记录文件名。
enum ImageStore {
    /// 在数据根目录下（见 DataLocation），换了储存位置就跟着换
    static var directory: URL { DataLocation.imagesDirectory }

    private static let cache = NSCache<NSString, CGImage>()

    /// 换了储存位置后清空缓存
    static func clearCache() { cache.removeAllObjects() }

    static func save(_ jpeg: Data) -> String {
        let id = UUID().uuidString + ".jpg"
        try? DataLocation.write(jpeg, to: directory.appendingPathComponent(id))
        return id
    }

    static func load(_ id: String) -> Data? {
        let url = directory.appendingPathComponent(id)
        guard DataLocation.exists(url) else { return nil }
        return try? DataLocation.read(url)
    }

    /// 有没有这张图（不读出来）
    static func exists(_ id: String) -> Bool {
        DataLocation.exists(directory.appendingPathComponent(id))
    }

    /// 按指定文件名保存（导入备份时用）
    static func save(_ data: Data, id: String) {
        try? DataLocation.write(data, to: directory.appendingPathComponent(id))
    }

    static func cgImage(_ id: String) -> CGImage? {
        if let cached = cache.object(forKey: id as NSString) { return cached }
        guard let data = load(id), let image = ImageUtil.cgImage(from: data) else { return nil }
        cache.setObject(image, forKey: id as NSString)
        return image
    }

    static func delete(_ ids: [String]) {
        for id in ids {
            DataLocation.remove(directory.appendingPathComponent(id))
        }
    }
}

/// 只用 ImageIO / CoreGraphics，iPad 和 Mac 通用。
enum ImageUtil {
    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 缩放到最长边不超过 maxPixel 并转成 JPEG，控制发送给模型的体积。
    static func normalizedJPEG(_ data: Data, maxPixel: Int = 1600) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpeg(image)
    }

    /// 缩到最长边不超过 maxPixel 再压成 JPEG，只压一次（以前先压一次整张大图、再解开缩小、再压一次）
    static func jpeg(_ image: CGImage, maxPixel: Int) -> Data? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel, maxPixel > 0 else { return jpeg(image) }
        let fit = Double(maxPixel) / Double(longest)
        let width = max(1, Int((Double(image.width) * fit).rounded())), height = max(1, Int((Double(image.height) * fit).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        return ctx.makeImage().flatMap { jpeg($0) }
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.75) -> Data? {
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flattenedOnWhite(image), [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }

    /// 透明背景（如手写板导出）在 JPEG 里会变黑，先铺一层白底。
    static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// 写得多的手写图片切成上下几段，分头同时识别：识别时间主要花在模型逐字写出转写上，一段长的要等很久，
    /// 几段一起写快得多。只在整排像素都没有笔迹的空白处切（切不到字、分式、大括号），每段带着自己左边的行号；
    /// 笔迹不到 minBands 块（大约几行）或找不到空白时原样返回一张
    static func horizontalStrips(_ data: Data, maxStrips: Int = 4, bandsPerStrip: Int = 3, minBands: Int = 8) -> [Data] {
        guard maxStrips > 1, let image = cgImage(from: data) else { return [data] }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let raw = ctx.data else { return [data] }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        let pixels = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // 哪些像素算“笔迹”：三个颜色里最暗的一个够暗才算（黄色、红色笔也算；浅蓝横线、浅灰竖线不算）。
        // 位图第一排就是图片最上面一排
        var dark = [Bool](repeating: false, count: width * height)
        var column = [Int](repeating: 0, count: width)
        for y in 0..<height {
            let row = pixels + y * width * 4
            for x in 0..<width {
                let p = row + x * 4
                if min(p[0], p[1], p[2]) < 160 {
                    dark[y * width + x] = true
                    column[x] += 1
                }
            }
        }
        // 从上到下贯穿大半张图的竖线（行号旁的分隔线；旧图片里是深色的）不算笔迹，不然每排都“有字”，找不到空白
        let rule = column.map { $0 > height / 2 }
        var ink = [Int](repeating: 0, count: height)
        for y in 0..<height {
            var count = 0
            for x in 0..<width where dark[y * width + x] && !rule[x] { count += 1 }
            ink[y] = count
        }
        // 连在一起有笔迹的几排是一块（一行字连同它的行号）；空白太窄的缝不切，免得切到挨得很近的上下标
        let minGap = max(4, height / 300)
        var bands: [(top: Int, bottom: Int, mass: Int)] = []
        var y = 0
        while y < height {
            guard ink[y] > 1 else { y += 1; continue }
            var end = y, mass = 0
            while end < height && ink[end] > 1 { mass += ink[end]; end += 1 }
            if let last = bands.last, y - last.bottom < minGap {
                bands[bands.count - 1] = (last.top, end, last.mass + mass)
            } else {
                bands.append((y, end, mass))
            }
            y = end
        }
        // 只有一两排像素高的是横线（旧图片里横线是深色的），不算一行字
        let lines = bands.filter { $0.bottom - $0.top > 3 }.count
        guard lines >= minBands else { return [data] }
        let count = min(maxStrips, max(2, lines / bandsPerStrip))
        // 按笔迹多少平均分：每段要写出的字差不多，几段差不多同时写完
        let total = bands.reduce(0) { $0 + $1.mass }
        var cuts: [Int] = [0]
        var sum = 0
        for i in 0..<(bands.count - 1) {
            sum += bands[i].mass
            let target = Double(total) * Double(cuts.count) / Double(count)
            if cuts.count < count && Double(sum) >= target {
                cuts.append((bands[i].bottom + bands[i + 1].top) / 2)
            }
        }
        cuts.append(height)
        guard cuts.count > 2 else { return [data] }
        let strips = zip(cuts, cuts.dropFirst()).compactMap { top, bottom -> Data? in
            image.cropping(to: CGRect(x: 0, y: top, width: width, height: bottom - top)).flatMap { jpeg($0, quality: 0.85) }
        }
        return strips.count == cuts.count - 1 ? strips : [data]
    }
}

/// 每道题写了一半的手写笔迹（PencilKit 数据），保存在本机，切题或退出 App 都不会丢
enum DrawingStore {
    /// 在数据根目录下（见 DataLocation），换了储存位置就跟着换
    static var directory: URL { DataLocation.drawingsDirectory }

    private static func url(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".drawing")
    }

    /// 写字停下时在后台写盘（整页笔迹编码、写文件不占主线程，下一笔落下时不卡）。
    /// 读、写、删都排在这一条队列上，读到的一定是最后写进去的
    private static let queue = DispatchQueue(label: "com.lswill2007.stepwise.drawings", qos: .utility)

    static func exists(_ id: UUID) -> Bool {
        let url = url(id)
        return queue.sync { DataLocation.exists(url) }
    }

    static func load(_ id: UUID) -> Data? {
        let url = url(id)
        return queue.sync {
            guard DataLocation.exists(url) else { return nil }
            return try? DataLocation.read(url)
        }
    }

    /// data 为 nil 表示没有笔迹，删除文件
    static func save(_ data: Data?, for id: UUID) {
        let url = url(id)
        queue.sync { write(data, to: url) }
    }

    /// 在后台编码、写盘；地址现在就定下来（等待期间换了储存位置，也不会写到新位置去）
    static func saveInBackground(for id: UUID, encode: @escaping @Sendable () -> Data?) {
        let url = url(id)
        queue.async { write(encode(), to: url) }
    }

    /// 等排着的写盘都写完（退到后台、换储存位置之前）
    static func flush() {
        queue.sync {}
    }

    private static func write(_ data: Data?, to url: URL) {
        if let data {
            try? DataLocation.write(data, to: url)
        } else {
            DataLocation.remove(url)
        }
    }

    static func delete(_ ids: [UUID]) {
        for id in ids { save(nil, for: id) }
    }
}
