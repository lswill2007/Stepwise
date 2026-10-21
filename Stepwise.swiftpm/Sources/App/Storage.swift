import Foundation
import Security
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// API Key 只存在系统钥匙串里，不写进普通文件。
enum Keychain {
    private static let service = "com.lswill2007.stepwise.apikeys"

    static func get(_ account: String) -> String? {
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
    static let directory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let cache = NSCache<NSString, CGImage>()

    static func save(_ jpeg: Data) -> String {
        let id = UUID().uuidString + ".jpg"
        try? jpeg.write(to: directory.appendingPathComponent(id), options: .atomic)
        return id
    }

    static func load(_ id: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(id))
    }

    static func cgImage(_ id: String) -> CGImage? {
        if let cached = cache.object(forKey: id as NSString) { return cached }
        guard let data = load(id), let image = ImageUtil.cgImage(from: data) else { return nil }
        cache.setObject(image, forKey: id as NSString)
        return image
    }

    static func delete(_ ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id))
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
}
