import Foundation
import SwiftData

/// 图纸工厂：统一创建 `Pattern`（尤其拆板子图）。
///
/// 依据架构师 §A.5.2「保存子图」与 PRD Q9/Q10：
/// 拆板子图写入 `parentPatternId`（父图 id）、`tileIndex`（如 `"R1C2"`）、
/// `source = "split"`、`placed` 全 `false`（独立进度、独立打卡），`sortOrder` 递增。
/// 父图通过子图汇总展示"X/N 块已完成"。
///
/// 并发约定（§B.8）：SwiftData 只在 `@MainActor` 上读写，故本类型标注 `@MainActor`。
@MainActor
enum PatternFactory {

    // MARK: - 拆板子图

    /// 由单个拆板块创建子图 `Pattern`（**已插入 context，未 save**）。
    ///
    /// - Parameters:
    ///   - source: 源（父）图纸
    ///   - tile: 拆板单块结果
    ///   - context: SwiftData 上下文（主线程）
    /// - Returns: 新建并已 `insert` 的子图 `Pattern`
    static func makeSplitTile(from source: Pattern,
                              tile: BoardSplitter.SplitTile,
                              context: ModelContext) -> Pattern {
        let tileName = "\(source.name) \(tile.index)"
        let pattern = Pattern(name: tileName,
                              width: tile.width,
                              height: tile.height,
                              cells: tile.cells,
                              source: "split")
        // 拆板关联信息
        pattern.parentPatternId = source.id
        pattern.tileIndex = tile.index
        // 板尺寸 = 子图尺寸（子图即为一块板）
        pattern.boardWidth = tile.width
        pattern.boardHeight = tile.height
        pattern.boardOffsetX = 0
        pattern.boardOffsetY = 0
        // 排序序号：保证父图内按「先行后列」稳定排序；用大基数避免与父图/其他图冲突
        pattern.sortOrder = source.sortOrder * 1_000_000 + tile.row * 1_000 + tile.col
        // 进度全 false（Pattern.init 已按 width*height 初始化，显式重申以防变更）
        pattern.placed = [Bool](repeating: false, count: tile.width * tile.height)
        context.insert(pattern)
        return pattern
    }

    /// 保存整体拆板结果的全部子图（**已插入 context，未 save**）。
    ///
    /// - Parameters:
    ///   - result: 拆板整体结果
    ///   - source: 源（父）图纸
    ///   - context: SwiftData 上下文
    /// - Returns: 新建的子图数组（顺序与 `result.tiles` 一致）
    static func saveAllTiles(_ result: BoardSplitter.SplitResult,
                             from source: Pattern,
                             context: ModelContext) -> [Pattern] {
        guard !result.tiles.isEmpty else { return [] }
        var created: [Pattern] = []
        created.reserveCapacity(result.tiles.count)
        for tile in result.tiles {
            created.append(makeSplitTile(from: source, tile: tile, context: context))
        }
        return created
    }

    // MARK: - 进度汇总

    /// 父图拆板进度汇总文案（"X/N 块已完成"）。
    ///
    /// 判定"已完成"：子图 `status == .done`（进度 100%）或 `progressPercent >= 1`。
    ///
    /// - Parameters:
    ///   - root: 父图
    ///   - tiles: 该父图的全部子图
    /// - Returns: 汇总文案；无子图时返回"未拆板"
    static func splitProgressSummary(root: Pattern, tiles: [Pattern]) -> String {
        guard !tiles.isEmpty else { return "未拆板" }
        let done = tiles.filter { $0.status == .done || $0.progressPercent >= 1 }.count
        return "\(done)/\(tiles.count) 块已完成"
    }
}
