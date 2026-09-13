import Foundation

/// 颜色距离与「合并相近色」/「替换整套配色」（纯函数，无状态，不抛异常，不改动输入）。
///
/// 依据架构师 §A.5.1：加权平方欧氏距离 `0.299*dr² + 0.587*dg² + 0.114*db²`（沿用现有风格），
/// 归一化到 `0…1`（除以最大可能 255² = 65025），供阈值滑杆 `0…0.30` 使用。
/// 合并策略：用量降序取代表色（用量最大者优先当代表色，保证合并后主色不变），
/// 其余色若与代表色归一化距离 ≤ 阈值则并入。
enum ColorMerge {

    // MARK: - 颜色距离

    /// 加权平方欧氏距离（0.299/0.587/0.114 加权，与 `Palette`/`limitColors` 现有一致）
    /// - Parameters:
    ///   - a: 颜色 A
    ///   - b: 颜色 B
    /// - Returns: 距离（未归一化，范围 0…65025）
    static func dist(_ a: BeadColor, _ b: BeadColor) -> Double {
        let dr = Double(a.r) - Double(b.r)
        let dg = Double(a.g) - Double(b.g)
        let db = Double(a.b) - Double(b.b)
        return 0.299 * dr * dr + 0.587 * dg * dg + 0.114 * db * db
    }

    /// 归一化距离（除以最大可能 255² = 65025），范围 0…1
    /// - Parameters:
    ///   - a: 颜色 A
    ///   - b: 颜色 B
    /// - Returns: 归一化距离
    static func norm(_ a: BeadColor, _ b: BeadColor) -> Double {
        dist(a, b) / 65025.0
    }

    /// 按色号取色板颜色（无效返回 nil）
    private static func color(_ id: Int) -> BeadColor? {
        BeadPalette.byId[id]
    }

    // MARK: - 合并相近色

    /// 计算「稀有色 → 代表色」的合并映射。
    ///
    /// 算法（贪心代表色聚类）：
    /// 1. 统计各色号用量；
    /// 2. 候选色按用量降序（用量大的优先当代表色，更符合直觉）；
    /// 3. 依次把尚未并入任何代表色的色作为新代表色，再把它之后归一化距离 ≤ 阈值者并入；
    /// 4. 返回 `mapping`（被并入色 → 代表色 id）；代表色自身不出现在 mapping 中。
    ///
    /// - Parameters:
    ///   - cells: 当前图纸网格
    ///   - threshold: 归一化距离阈值（建议 0…0.30）
    /// - Returns: 合并映射 `[被并入色 id: 代表色 id]`；无合并时为空字典
    static func mergeSuggestions(cells: [Int], threshold: Double) -> [Int: Int] {
        let counts = counts(cells)
        guard counts.count > 1 else { return [:] }

        // 用量降序 → 代表色优先级
        let ordered = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }.map { $0.key }

        var assigned = Set<Int>()          // 已分配（代表色或被并入色）
        var mapping: [Int: Int] = [:]

        for (i, repId) in ordered.enumerated() {
            guard !assigned.contains(repId), let repColor = color(repId) else { continue }
            assigned.insert(repId)
            // 与"其后、未分配"的色比较，符合则并入当前代表色
            for j in (i + 1)..<ordered.count {
                let otherId = ordered[j]
                guard !assigned.contains(otherId), let otherColor = color(otherId) else { continue }
                if norm(repColor, otherColor) <= threshold {
                    mapping[otherId] = repId
                    assigned.insert(otherId)
                }
            }
        }
        return mapping
    }

    /// 应用合并映射到网格（纯函数，不改动输入）。
    /// - Parameters:
    ///   - cells: 原网格
    ///   - mapping: 合并映射（`被并入色 → 代表色`）
    /// - Returns: 应用后的新网格
    static func applyMerge(cells: [Int], mapping: [Int: Int]) -> [Int] {
        guard !mapping.isEmpty else { return cells }
        return cells.map { mapping[$0] ?? $0 }
    }

    /// 生成给 UI 预览的合并建议列表（"XX 将被合并到 YY"）。
    /// - Parameters:
    ///   - cells: 当前图纸网格
    ///   - threshold: 归一化距离阈值
    /// - Returns: 建议数组（按被并入色原用量降序），含 from/to 颜色与 from 的数量
    static func suggestions(_ cells: [Int], threshold: Double) -> [(from: BeadColor, to: BeadColor, count: Int)] {
        let mapping = mergeSuggestions(cells: cells, threshold: threshold)
        guard !mapping.isEmpty else { return [] }
        let counts = counts(cells)

        var out: [(from: BeadColor, to: BeadColor, count: Int)] = []
        for (fromId, toId) in mapping {
            guard let fromColor = color(fromId), let toColor = color(toId) else { continue }
            out.append((from: fromColor, to: toColor, count: counts[fromId] ?? 0))
        }
        // 按被并入色原用量降序展示
        return out.sorted { $0.count > $1.count }
    }

    // MARK: - 替换整套配色

    /// 全图把 `from` 色号替换为 `to` 色号（含空格替换：`from == 0` 表示把空替换成 `to`）。
    /// - Parameters:
    ///   - cells: 原网格
    ///   - from: 原色号（0 = 空格）
    ///   - to: 新色号（0 = 清空）
    /// - Returns: 替换后的新网格
    static func replaceColor(cells: [Int], from: Int, to: Int) -> [Int] {
        guard from != to else { return cells }
        return cells.map { $0 == from ? to : $0 }
    }

    // MARK: - 辅助

    /// 统计各色号用量（0 不计）
    /// - Parameter cells: 网格
    /// - Returns: `[色号: 用量]`
    static func counts(_ cells: [Int]) -> [Int: Int] {
        var dict: [Int: Int] = [:]
        for c in cells where c > 0 { dict[c, default: 0] += 1 }
        return dict
    }
}
