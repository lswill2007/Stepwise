import Foundation
import CoreGraphics

/// 笔的手感参数：写完一笔后按这些参数重新整理笔画（PencilKit 本身不提供这些调节）。
/// 只用到几何计算，工具栏里的预览也用同一套算法，看到的就是写出来的样子
enum InkShape {
    struct Point {
        var location: CGPoint
        /// 笔的压力，0–1 左右；手指书写时是固定值
        var force: CGFloat
        var size: CGFloat
    }

    /// 笔尖的角度（扁平笔尖斜着拿，像书法笔、钢笔）：屏幕坐标 y 向下，
    /// -30° 是笔尖边往右上斜：横画偏细、竖画粗，“/”最细、“\”最粗
    static let nibAngle: CGFloat = -.pi / 6

    /// PencilKit 的笔（.pen / .monoline）画出来的粗细 ≈ 2 ×（点的 size − 2）：size 3 只有 2pt，size 2 几乎看不见。
    /// 所以粗细都在“看得到的粗细”（size − 2）上调，再换回 size，不然稍微调细一点笔画就细成一根线
    static let sizeOffset: CGFloat = 2

    /// 默认参数：不需要重新整理
    static func isDefault(pressure: Double, flatness: Double, stability: Double) -> Bool {
        abs(pressure - 0.5) < 0.01 && flatness < 0.01 && stability < 0.01
    }

    /// 稳定性：把抖动的点平滑掉，0 不变，1 最平滑；两端的点不动
    static func smooth(_ points: [Point], stability: Double) -> [Point] {
        let radius = Int((stability * 6).rounded())
        guard radius > 0, points.count > 2 else { return points }
        var result = points
        for i in 1..<(points.count - 1) {
            let r = min(radius, i, points.count - 1 - i)
            guard r > 0 else { continue }
            var x: CGFloat = 0, y: CGFloat = 0
            for j in (i - r)...(i + r) {
                x += points[j].location.x
                y += points[j].location.y
            }
            let n = CGFloat(2 * r + 1)
            result[i].location = CGPoint(x: x / n, y: y / n)
        }
        return result
    }

    /// 每个点的粗细（返回 PKStrokePoint 的 size）：压力灵敏度、笔尖扁平度，以及钢笔自带的笔锋
    /// - pressure：0 完全不随压力变化，0.5 系统默认，1 压力影响很大
    /// - flatness：0 圆笔尖，1 很扁：顺着笔尖方向写很细，垂直方向写很粗
    /// - nib：钢笔自带的粗细变化，0 没有；0.6 时最细的方向是最粗的四成。各个方向平均下来粗细不变，
    ///   只是横细竖粗，写的时候看到多粗，写完大体还是多粗
    static func widths(_ points: [Point], pressure: Double, flatness: Double, nib: Double = 0) -> [CGFloat] {
        guard !points.isEmpty else { return [] }
        // 看得到的粗细
        var visible = points.map { max($0.size - sizeOffset, 0.2) }
        let median = visible.sorted()[visible.count / 2]
        let maxForce = max(points.map(\.force).max() ?? 1, 0.01)
        for i in visible.indices {
            if pressure < 0.5 {
                // 越低越接近统一粗细
                let t = CGFloat(pressure / 0.5)
                visible[i] = median + (visible[i] - median) * t
            } else if pressure > 0.5 {
                let t = CGFloat((pressure - 0.5) / 0.5)
                let nf = points[i].force / maxForce
                visible[i] *= 1 + t * (0.3 + 1.4 * nf - 1)
            }
        }
        if (flatness > 0 || nib > 0), points.count > 2 {
            let across = smoothed(acrossNib(points))
            if nib > 0 {
                // 钢笔：按方向分粗细，再整体放大，让各个方向平均下来和写的时候一样粗。
                // 按所有方向的平均算，不按这一笔自己的平均：不然一笔直线怎么写都一样粗，分不出横细竖粗
                let thin = CGFloat(1 - nib)
                let mean = thin + (1 - thin) * 2 / .pi
                for i in visible.indices { visible[i] *= (thin + (1 - thin) * across[i]) / mean }
            }
            if flatness > 0 {
                for i in visible.indices { visible[i] *= 1 - CGFloat(flatness) * 0.75 * (1 - across[i]) }
            }
        }
        return visible.map { max($0, 0.4) + sizeOffset }
    }

    /// 每个点的笔画方向和笔尖方向差多少：0 顺着笔尖（最细），1 垂直（最粗）。
    /// 用前后各隔两个点的方向，太短分不出方向的点当作中间值
    private static func acrossNib(_ points: [Point]) -> [CGFloat] {
        points.indices.map { i in
            let a = points[max(i - 2, 0)].location
            let b = points[min(i + 2, points.count - 1)].location
            let dx = b.x - a.x, dy = b.y - a.y
            guard dx * dx + dy * dy > 0.25 else { return 0.7 }
            return abs(sin(atan2(dy, dx) - nibAngle))
        }
    }

    /// 粗细沿着笔画平滑过渡，不会一个点粗一个点细
    private static func smoothed(_ values: [CGFloat], radius: Int = 3) -> [CGFloat] {
        guard values.count > 2 else { return values }
        return values.indices.map { i in
            let lo = max(i - radius, 0), hi = min(i + radius, values.count - 1)
            return values[lo...hi].reduce(0, +) / CGFloat(hi - lo + 1)
        }
    }
}
