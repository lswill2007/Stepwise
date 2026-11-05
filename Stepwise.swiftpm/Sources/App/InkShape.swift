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
    /// -45° 是往右上，所以“/”方向的笔画最细，“\”方向的最粗
    static let nibAngle: CGFloat = -.pi / 4

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

    /// 每个点的粗细：压力灵敏度和笔尖扁平度
    /// - pressure：0 完全不随压力变化，0.5 系统默认，1 压力影响很大
    /// - flatness：0 圆笔尖，1 很扁：顺着笔尖方向写很细，垂直方向写很粗
    static func widths(_ points: [Point], pressure: Double, flatness: Double) -> [CGFloat] {
        guard !points.isEmpty else { return [] }
        let sizes = points.map(\.size)
        let median = sizes.sorted()[sizes.count / 2]
        let maxForce = max(points.map(\.force).max() ?? 1, 0.01)
        return points.indices.map { i in
            var w = sizes[i]
            if pressure < 0.5 {
                // 越低越接近统一粗细
                let t = CGFloat(pressure / 0.5)
                w = median + (w - median) * t
            } else if pressure > 0.5 {
                let t = CGFloat((pressure - 0.5) / 0.5)
                let nf = points[i].force / maxForce
                w *= 1 + t * (0.3 + 1.4 * nf - 1)
            }
            if flatness > 0, points.count > 1 {
                let a = points[max(i - 1, 0)].location
                let b = points[min(i + 1, points.count - 1)].location
                let dx = b.x - a.x, dy = b.y - a.y
                if dx * dx + dy * dy > 0.01 {
                    // 顺着笔尖方向（夹角 0）最细
                    let angle = atan2(dy, dx) - nibAngle
                    let across = abs(sin(angle))
                    w *= 1 - CGFloat(flatness) * 0.75 * (1 - across)
                }
            }
            return max(w, 0.8)
        }
    }
}
