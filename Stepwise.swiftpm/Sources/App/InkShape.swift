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

// MARK: - 飞线

extension InkShape {
    /// 笔画上的一个点：位置，和从落笔算起过了多久（秒）
    struct Sample {
        var location: CGPoint
        var time: TimeInterval
    }

    /// 一步跨出去至少这么远才可能是飞线
    static let spikeMinJump: CGFloat = 120
    /// 手写不出这么快的一步（每秒多少 pt；约每秒六米。见过的飞线是十万以上；甩得再快的一笔也就每秒两三米）
    static let spikeMinSpeed: CGFloat = 25_000
    /// 两个点的时间一样、算不出快慢时，要跨得更远才算
    static let spikeMinJumpUntimed: CGFloat = 240
    /// 飞出去的那一头最多几个点
    static let spikeMaxPoints = 3

    /// 去掉笔画里的“飞线”：Apple Pencil 落笔（或抬笔）的那一下，偶尔会报来一个离得很远的点
    ///（手掌同时碰到屏幕、屏幕贴膜、充电干扰时都见过），PencilKit 照着画，纸上就多出一条从这一笔拉到远处的笔直细线。
    ///
    /// 认的是“不可能写出来的一步”：一步跨出很远、快得手写不出来，而且跨过去的那一头只有一两个点，
    /// 笔画的其余部分都在另一头正常地写着（或者跨出去马上又跨回来）。很快地划一条长线不会被认成飞线：
    /// 那样每一步都差不多长，不是只有孤零零的一步。
    ///
    /// 宁可留着一条飞线，也不能动写对了的笔画：整笔绝不删掉，去掉飞出去的点以后剩不下一笔像样的（不到两个点），
    /// 或者这一笔本来就只有两三个点（很快地划一条直线，PencilKit 只留两三个点，和飞线分不出来），都原样留着。
    ///
    /// 返回要留下的点的下标；没有飞线（或者拿不准）返回 nil
    static func withoutSpikes(_ points: [Sample]) -> [Int]? {
        guard points.count >= 4 else { return nil }
        var keep = Array(points.indices)
        var changed = false
        // 一次去掉一处，去掉以后再从头看；一笔里最多也就两三处
        for _ in 0..<6 {
            guard keep.count >= 2, let cut = spike(in: keep.map { points[$0] }) else { break }
            keep.removeSubrange(cut)
            changed = true
        }
        guard changed, keep.count >= 2 else { return nil }
        return keep
    }

    /// 找一处飞线：返回要去掉的那几个点
    private static func spike(in p: [Sample]) -> Range<Int>? {
        let n = p.count
        guard n >= 2 else { return nil }
        func length(_ i: Int) -> CGFloat { distance(p[i].location, p[i + 1].location) }
        func isJump(_ i: Int) -> Bool {
            let l = length(i)
            guard l >= spikeMinJump else { return false }
            let dt = CGFloat(p[i + 1].time - p[i].time)
            return dt > 0 ? l / dt >= spikeMinSpeed : l >= spikeMinJumpUntimed
        }
        /// 这几个点挤在一起（相对跨出去的那一步来说）
        func compact(_ range: ClosedRange<Int>, against jump: CGFloat) -> Bool {
            range.allSatisfy { distance(p[$0].location, p[range.lowerBound].location) <= jump * 0.25 }
        }
        let jumps = (0..<(n - 1)).filter(isJump)
        guard let first = jumps.first, let last = jumps.last else { return nil }

        // 跨出去又跨回来：中间那一两个点是飞出去的
        for (a, b) in zip(jumps, jumps.dropFirst()) where b - a <= spikeMaxPoints {
            let back = distance(p[a].location, p[b + 1].location)
            if back <= min(length(a), length(b)) * 0.35 { return (a + 1)..<(b + 1) }
        }
        // 开头的一两个点在远处，然后一步跨到真正落笔的地方接着写
        if first < spikeMaxPoints, n - (first + 1) >= first + 1, compact(0...first, against: length(first)),
           first + 2 >= n || length(first + 1) <= length(first) * 0.35 {
            return 0..<(first + 1)
        }
        // 写得好好的，最后一步跨到远处
        let tail = n - 1 - last
        if tail <= spikeMaxPoints, last + 1 >= tail, compact((last + 1)...(n - 1), against: length(last)),
           last == 0 || length(last - 1) <= length(last) * 0.35 {
            return (last + 1)..<n
        }
        return nil
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
