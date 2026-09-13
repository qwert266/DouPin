import Foundation

/// 拆板算法（纯函数，无状态）。
///
/// 依据架构师 §A.5.2「拆板算法（含边界与非整除）」与 PRD §5.3「拆板」：
/// 把一张大图纸按「实体豆板尺寸」切分成多块子图，每块带编号（如 `R1C2`）与接缝对齐提示
/// （"右接 R1C2 / 下接 R2C1"），供逐块上板拼、逐块打卡。
///
/// 关键边界：
/// 1. `overlap == 0`（默认）：严格切分，末行/末列可小于板尺寸（`min()` 截断）。
/// 2. `overlap > 0`：相邻块保留重叠行/列，步进 = 板尺寸 - overlap；末块仍用 `min()` 截断。
/// 3. 图纸小于板尺寸：`cols = rows = 1`，单块即为原图。
/// 4. 板尺寸非法（≤0）时防御性返回空结果，绝不越界。
/// 5. 所有下标均由 `min()` 派生，恒满足 `x0 + tileW ≤ width`、`y0 + tileH ≤ height`。
enum BoardSplitter {

    /// 单块拆板结果（值类型）
    ///
    /// 遵循 `Identifiable`（`id = index`）以支持 SwiftUI `.sheet(item:)` 预览。
    struct SplitTile: Identifiable {
        /// 身份（等于编号 `index`，全局唯一）
        var id: String { index }
        /// 编号，形如 `"R1C2"`（第 1 行第 2 列）
        let index: String
        /// 行序号（从 0 起）
        let row: Int
        /// 列序号（从 0 起）
        let col: Int
        /// 在母图中的起始 x（列）
        let x0: Int
        /// 在母图中的起始 y（行）
        let y0: Int
        /// 本块实际宽度（末列可能小于板宽）
        let width: Int
        /// 本块实际高度（末行可能小于板高）
        let height: Int
        /// 本块裁剪出的网格数据（行优先，长度 = width * height）
        let cells: [Int]
        /// 接缝对齐提示文案，如 `["右接 R1C2", "下接 R2C1"]`（边界块可能为空）
        let edgeHints: [String]
        /// 本块各色号用量（按用量降序）
        let beadCounts: [(color: BeadColor, count: Int)]

        /// 本块豆子总数（空格不计）
        var beadTotal: Int { cells.filter { $0 > 0 }.count }

        /// 本块使用颜色种数
        var colorCount: Int { beadCounts.count }
    }

    /// 拆板整体结果（值类型）
    struct SplitResult {
        /// 全部子块（按先行后列顺序）
        let tiles: [SplitTile]
        /// 列向拆分数
        let cols: Int
        /// 行向拆分数
        let rows: Int
        /// 采用的板宽
        let boardW: Int
        /// 采用的板高
        let boardH: Int
        /// 母图宽（列数）
        let sourceWidth: Int
        /// 母图高（行数）
        let sourceHeight: Int

        /// 子块总数（= cols * rows，理论上等于 tiles.count）
        var tileCount: Int { tiles.count }
        /// 是否需要拆分（多于一块）
        var needsSplit: Bool { tiles.count > 1 }
    }

    // MARK: - 主流程

    /// 拆板主流程。
    ///
    /// - Parameters:
    ///   - cells: 母图网格（行优先，0 表示空格）
    ///   - width: 母图宽（列数）
    ///   - height: 母图高（行数）
    ///   - boardW: 板宽（列数），非法（≤0）时按 1 处理并返回空
    ///   - boardH: 板高（行数），非法（≤0）时按 1 处理并返回空
    ///   - overlap: 相邻块重叠行/列数（默认 0 = 严格切分）
    /// - Returns: 拆板结果；输入非法时 `tiles` 为空
    static func split(cells: [Int],
                      width: Int,
                      height: Int,
                      boardW: Int,
                      boardH: Int,
                      overlap: Int = 0) -> SplitResult {
        // 防御：图纸尺寸非法或网格长度不匹配 → 空结果
        guard width > 0, height > 0, cells.count == width * height else {
            return SplitResult(tiles: [], cols: 0, rows: 0,
                               boardW: boardW, boardH: boardH,
                               sourceWidth: width, sourceHeight: height)
        }
        // 防御：板尺寸非法 → 空结果（不做任何下标运算）
        guard boardW > 0, boardH > 0 else {
            return SplitResult(tiles: [], cols: 0, rows: 0,
                               boardW: boardW, boardH: boardH,
                               sourceWidth: width, sourceHeight: height)
        }

        // 步进：重叠时减小步进；clamp 到 [1, board] 保证 step > 0，杜绝除零/死循环
        let stepW = max(1, min(boardW, boardW - overlap))
        let stepH = max(1, min(boardH, boardH - overlap))

        // 拆分数（向上取整）
        let cols = (width + stepW - 1) / stepW
        let rows = (height + stepH - 1) / stepH

        var tiles: [SplitTile] = []
        tiles.reserveCapacity(cols * rows)

        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = c * stepW
                let y0 = r * stepH
                // 末行/末列以 min() 截断，保证不越界
                let tileW = min(boardW, width - x0)
                let tileH = min(boardH, height - y0)
                // 防御：无有效区域则跳过（理论上不会触发）
                guard tileW > 0, tileH > 0 else { continue }

                // 裁剪本块网格（行优先）
                var tileCells = [Int](repeating: 0, count: tileW * tileH)
                for ty in 0..<tileH {
                    let srcRow = (y0 + ty) * width
                    let dstRow = ty * tileW
                    for tx in 0..<tileW {
                        tileCells[dstRow + tx] = cells[srcRow + (x0 + tx)]
                    }
                }

                let index = "R\(r + 1)C\(c + 1)"
                tiles.append(SplitTile(
                    index: index,
                    row: r,
                    col: c,
                    x0: x0,
                    y0: y0,
                    width: tileW,
                    height: tileH,
                    cells: tileCells,
                    edgeHints: edgeHints(row: r, col: c, rows: rows, cols: cols),
                    beadCounts: beadCounts(tileCells)
                ))
            }
        }

        return SplitResult(tiles: tiles, cols: cols, rows: rows,
                           boardW: boardW, boardH: boardH,
                           sourceWidth: width, sourceHeight: height)
    }

    /// 便捷重载：直接拆一张图纸。
    /// - Parameters:
    ///   - pattern: 源图纸
    ///   - boardW: 板宽（默认取图纸 `effectiveBoardWidth`）
    ///   - boardH: 板高（默认取图纸 `effectiveBoardHeight`）
    ///   - overlap: 重叠行/列，默认 0
    static func split(pattern: Pattern,
                      boardW: Int? = nil,
                      boardH: Int? = nil,
                      overlap: Int = 0) -> SplitResult {
        split(cells: pattern.cells,
              width: pattern.width,
              height: pattern.height,
              boardW: boardW ?? pattern.effectiveBoardWidth,
              boardH: boardH ?? pattern.effectiveBoardHeight,
              overlap: overlap)
    }

    // MARK: - 辅助

    /// 生成接缝对齐提示（右接 / 下接）
    /// - Parameters:
    ///   - row: 当前行序号（0 起）
    ///   - col: 当前列序号（0 起）
    ///   - rows: 总行数
    ///   - cols: 总列数
    /// - Returns: 提示文案数组，如 `["右接 R1C2", "下接 R2C1"]`
    static func edgeHints(row: Int, col: Int, rows: Int, cols: Int) -> [String] {
        var hints: [String] = []
        if col + 1 < cols {
            hints.append("右接 R\(row + 1)C\(col + 2)")
        }
        if row + 1 < rows {
            hints.append("下接 R\(row + 2)C\(col + 1)")
        }
        return hints
    }

    /// 统计单块各色号用量（按用量降序；0 不计）
    /// - Parameter cells: 单块网格
    /// - Returns: `(color, count)` 数组
    static func beadCounts(_ cells: [Int]) -> [(color: BeadColor, count: Int)] {
        var dict: [Int: Int] = [:]
        for c in cells where c > 0 { dict[c, default: 0] += 1 }
        return dict
            .compactMap { id, count in BeadPalette.byId[id].map { ($0, count) } }
            .sorted { $0.count > $1.count }
    }
}
