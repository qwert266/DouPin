import Foundation

/// 消耗预估服务（无状态 Service）
///
/// 依据架构师 §A.5.3 与 §B.8：
/// - 核心计算复用值类型 `StockEstimate.init(pattern:stocks:)`（已在 `Models+Inventory.swift` 实现）；
/// - 本 Service 提供**薄封装**与若干扩展能力（快速查表 / 缺色清单文本 / 一次性扣减）。
///
/// 说明：PRD §7 明确**不做「出入库流水」**；`consumeOnce` 仅作为**便利动作**
/// （按图纸用量直接扣减库存），不写任何流水记录，UI 上应作为**次要按钮**呈现。
enum StockEstimator {

    // MARK: - 预估

    /// 计算图纸的消耗预估
    /// - Parameters:
    ///   - pattern: 目标图纸（读取其 `beadCounts`）
    ///   - stocks: 库存列表
    /// - Returns: 预估结果（含明细 / 汇总 / 缺色清单）
    static func estimate(pattern: Pattern, stocks: [BeadStock]) -> StockEstimate {
        StockEstimate(pattern: pattern, stocks: stocks)
    }

    /// 计算指定用量明细的消耗预估
    /// - Parameters:
    ///   - name: 图纸名称（缺色清单标题用）
    ///   - counts: 各色号用量（通常来自 `pattern.beadCounts`）
    ///   - stocks: 库存列表
    /// - Returns: 预估结果
    static func estimate(name: String,
                         counts: [(color: BeadColor, count: Int)],
                         stocks: [BeadStock]) -> StockEstimate {
        StockEstimate(name: name, counts: counts, stocks: stocks)
    }

    // MARK: - 扩展能力

    /// 库存列表 → `colorId: quantity` 快速查表（相同色号多次出现时数量累加）
    /// - Parameter stocks: 库存列表
    /// - Returns: 色号到数量的字典
    static func stocksMap(_ stocks: [BeadStock]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for s in stocks where s.colorId > 0 {
            map[s.colorId, default: 0] += s.quantity
        }
        return map
    }

    /// 可复制的缺色清单文本（PRD §5.2）
    ///
    /// 与 `StockEstimate.shortText` 语义一致，此处作为服务层入口，方便 UI 直接调用。
    /// - Parameter estimate: 预估结果
    /// - Returns: 多行文本
    static func missingListText(_ estimate: StockEstimate) -> String {
        estimate.shortText
    }

    /// 按图纸用量**一次性扣减**库存（便利动作，**不写流水记录**）
    ///
    /// 语义：
    /// - 仅扣减库存中**已存在**的色号（`quantity - need`，钳制为 ≥ 0）；
    /// - 库存中不存在的色号**跳过**（不新增 0 库存记录）；
    /// - 返回被实际扣减的色号明细，供 UI 展示。
    ///
    /// ⚠️ 使用方（View）需在 `@MainActor` 上调用（触碰 SwiftData 模型）。
    ///
    /// - Parameters:
    ///   - pattern: 目标图纸（读取其 `beadCounts`）
    ///   - stocks: 库存列表（inout，原地修改）
    /// - Returns: 实际扣减的明细 `(colorId, deducted, remaining)`
    @discardableResult
    static func consumeOnce(pattern: Pattern,
                            stocks: inout [BeadStock]) -> [(colorId: Int, deducted: Int, remaining: Int)] {
        var index: [Int: BeadStock] = [:]
        for s in stocks where s.colorId > 0 {
            index[s.colorId] = s
        }

        var result: [(colorId: Int, deducted: Int, remaining: Int)] = []
        for item in pattern.beadCounts {
            guard let stock = index[item.color.id] else { continue }
            let deduct = min(stock.quantity, item.count)
            guard deduct > 0 else { continue }
            stock.setQuantity(stock.quantity - deduct)
            result.append((colorId: item.color.id, deducted: deduct, remaining: stock.quantity))
        }
        return result
    }
}
