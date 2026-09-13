import Foundation
import SwiftData

// MARK: - 图纸文件夹

/// 图纸文件夹（一级，不做多级嵌套）
///
/// 设计说明（架构师 §A.4.2 / §B.8 约定）：
/// - 与 `Pattern` 之间**不使用 SwiftData `@Relationship`**，改用 `Pattern.folderId: UUID?` 弱引用，
///   避免关系（Relationship）带来的删除级联复杂度。
/// - 删除文件夹时**不级联删除图纸**，由调用方手动把其下图纸的 `folderId` 置为 `nil`（见 `BeadStockDefaults` 之外的调用点）。
@Model
final class PatternFolder {
    /// 唯一标识
    @Attribute(.unique) var id: UUID = UUID()
    /// 文件夹名称（默认「新建文件夹」）
    var name: String = "新建文件夹"
    /// 排序序号（拖动排序用，越小越靠前）
    var sortOrder: Int = 0
    /// 创建时间
    var createdAt: Date = Date()

    /// 便利构造：指定名称创建文件夹
    /// - Parameters:
    ///   - name: 文件夹名称
    ///   - sortOrder: 排序序号，默认 0
    init(name: String, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    /// 默认无参构造（SwiftData 需要）
    init() {
        self.id = UUID()
        self.name = "新建文件夹"
        self.sortOrder = 0
        self.createdAt = Date()
    }

    /// 重命名文件夹
    /// - Parameter newName: 新名称（去除首尾空白；为空则保持原名）
    func rename(to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.name = trimmed
    }
}

// MARK: - 库存

/// 库存记录（**一个色号一条记录**）
///
/// 设计说明：`colorId` 为内部统一口径的官方色号（1…295，0 恒表示空格）；
/// 查询/更新 O(1)，比聚合数组更简单（架构师 §A.4.2）。
@Model
final class BeadStock {
    /// 唯一标识
    @Attribute(.unique) var id: UUID = UUID()
    /// 官方色号（1…295，对应 `BeadPalette`）
    var colorId: Int = 0
    /// 现有数量
    var quantity: Int = 0
    /// 缺色预警阈值（0 = 仅当数量为 0 才算缺）
    var threshold: Int = 0
    /// 最近更新时间
    var updatedAt: Date = Date()

    /// 便利构造
    /// - Parameters:
    ///   - colorId: 官方色号（1…295）
    ///   - quantity: 现有数量
    ///   - threshold: 缺色预警阈值，默认 0
    init(colorId: Int, quantity: Int, threshold: Int = 0) {
        self.id = UUID()
        self.colorId = colorId
        self.quantity = max(0, quantity)
        self.threshold = max(0, threshold)
        self.updatedAt = Date()
    }

    /// 默认无参构造（SwiftData 需要）
    init() {
        self.id = UUID()
        self.colorId = 0
        self.quantity = 0
        self.threshold = 0
        self.updatedAt = Date()
    }

    /// 对应的色板颜色（色号无效时返回 nil）
    var color: BeadColor? { BeadPalette.byId[colorId] }

    /// 展示用色号（如 "A1"；无效色号回落为 "?"）
    var displayName: String { color?.mard ?? "?" }

    /// 当前是否构成「缺色」（数量 ≤ 阈值）
    var isLow: Bool { quantity <= max(0, threshold) }

    /// 覆盖式设置数量（负值钳制为 0）
    /// - Parameter newQuantity: 新数量
    func setQuantity(_ newQuantity: Int) {
        self.quantity = max(0, newQuantity)
        self.updatedAt = Date()
    }

    /// 累加数量（用于批量导入「累加」语义；负值钳制为 0）
    /// - Parameter delta: 增量（可为负，结果不小于 0）
    func addQuantity(_ delta: Int) {
        self.quantity = max(0, self.quantity + delta)
        self.updatedAt = Date()
    }
}

// MARK: - 消耗预估结果（值类型）

/// 消耗预估结果（**值类型 struct**，非 `@Model`）
///
/// 依据架构师 §A.5.3 算法：按图纸 `beadCounts`（用量降序）逐色号与库存对比，
/// 生成「需 / 有 / 差」明细、汇总与可复制的缺色清单文本。
struct StockEstimate {
    /// 单行预估（一色号一行）
    struct Row: Identifiable {
        /// 官方色号（`BeadColor.id`），同时作为列表身份
        let id: Int
        /// 色板颜色
        let color: BeadColor
        /// 需求数量
        let need: Int
        /// 现有数量
        let have: Int

        /// 差额（正 = 富余，负 = 缺口）
        var diff: Int { have - need }
        /// 是否不足（缺口）
        var isShort: Bool { diff < 0 }
        /// 缺口绝对值（不足时 > 0，否则 0）
        var shortage: Int { diff < 0 ? -diff : 0 }
    }

    /// 全部明细行（按需求数量降序）
    let rows: [Row]
    /// 总需求量
    let totalNeed: Int
    /// 库存总豆量（所有库存条目数量之和）
    let totalHave: Int
    /// 不足的明细行（保持降序）
    let shortRows: [Row]
    /// 图纸名称（用于缺色清单标题）
    let patternName: String

    /// 缺色种数
    var shortCount: Int { shortRows.count }
    /// 是否存在缺色
    var hasShortage: Bool { !shortRows.isEmpty }

    /// 缺色清单（可复制文本）
    ///
    /// 形如：
    /// ```
    /// 【图纸名】缺色清单
    /// A1  需100 有20 缺80
    /// 共 1 种色号不足
    /// ```
    var shortText: String {
        guard hasShortage else { return "【\(patternName)】库存充足，无缺色 🎉" }
        var lines: [String] = ["【\(patternName)】缺色清单"]
        for row in shortRows {
            lines.append("\(row.color.mard)  需\(row.need) 有\(row.have) 缺\(row.shortage)")
        }
        lines.append("共 \(shortCount) 种色号不足")
        return lines.joined(separator: "\n")
    }

    /// 便利构造：由图纸与库存列表计算预估结果
    ///
    /// - Parameters:
    ///   - pattern: 目标图纸（读取其 `beadCounts`）
    ///   - stocks: 库存列表（`BeadStock`，一色号一条；数量取 `quantity`）
    ///
    /// 性能：库存 ≤295 条，先构建 `[colorId: quantity]` 字典，再单次遍历，O(n)。
    init(pattern: Pattern, stocks: [BeadStock]) {
        self.init(name: pattern.name, counts: pattern.beadCounts, stocks: stocks)
    }

    /// 便利构造：由图纸名称、用量明细与库存列表计算预估结果
    ///
    /// - Parameters:
    ///   - name: 图纸名称（缺色清单标题用）
    ///   - counts: 各色号用量（`(color, count)`，通常来自 `pattern.beadCounts`，降序）
    ///   - stocks: 库存列表
    init(name: String, counts: [(color: BeadColor, count: Int)], stocks: [BeadStock]) {
        // 库存 → 字典，便于 O(1) 查询
        var stockMap: [Int: Int] = [:]
        var totalHaveSum = 0
        for stock in stocks {
            stockMap[stock.colorId, default: 0] += stock.quantity
            totalHaveSum += stock.quantity
        }

        // 逐色号生成明细行（保持 counts 原有顺序，传入通常已按用量降序）
        var builtRows: [Row] = []
        var needSum = 0
        for item in counts {
            let need = item.count
            let have = stockMap[item.color.id] ?? 0
            needSum += need
            builtRows.append(Row(id: item.color.id, color: item.color, need: need, have: have))
        }

        self.patternName = name
        self.rows = builtRows
        self.totalNeed = needSum
        self.totalHave = totalHaveSum
        self.shortRows = builtRows.filter { $0.isShort }
    }

    /// 空结果（无图纸/无用量时使用）
    static func empty(patternName: String = "未命名") -> StockEstimate {
        StockEstimate(name: patternName, counts: [], stocks: [])
    }
}

// MARK: - 拆板结果记录（P1，可选）

/// 拆板结果记录（**值类型 struct**，非 `@Model`）
///
/// 依据 PRD §6.2 / 架构师 §A.4.2：记录一次拆板的来源图纸、板尺寸与各子图 id，
/// 便于后续「父图 → 子图」汇总展示与重拆（P1）。当前不参与持久化，仅作为内存态 DTO。
struct TileSplit: Identifiable {
    /// 唯一标识
    let id: UUID
    /// 源图纸 id
    let sourcePatternId: UUID
    /// 板宽
    let boardW: Int
    /// 板高
    let boardH: Int
    /// 重叠行/列（步进 = 板尺寸 - overlap）
    let overlap: Int
    /// 各子图 `Pattern.id` 列表（顺序与拆板行列一致）
    let tileRefs: [UUID]
    /// 创建时间
    let createdAt: Date

    /// 便利构造
    init(sourcePatternId: UUID,
         boardW: Int,
         boardH: Int,
         overlap: Int = 0,
         tileRefs: [UUID] = [],
         createdAt: Date = Date()) {
        self.id = UUID()
        self.sourcePatternId = sourcePatternId
        self.boardW = boardW
        self.boardH = boardH
        self.overlap = overlap
        self.tileRefs = tileRefs
        self.createdAt = createdAt
    }

    /// 子图数量
    var tileCount: Int { tileRefs.count }
}
