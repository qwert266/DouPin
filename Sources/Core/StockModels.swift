import Foundation
import SwiftData

/// 豆仓库存：按官方色号记录颗粒数量
@Model
final class BeadStock {
    @Attribute(.unique) var colorId: Int
    var count: Int
    var updatedAt: Date = Date()

    init(colorId: Int, count: Int) {
        self.colorId = colorId
        self.count = count
        self.updatedAt = Date()
    }
}

/// 补货清单条目：需求量超出库存的部分
struct StockGap: Identifiable {
    let color: BeadColor
    let needed: Int
    let stock: Int
    var missing: Int { max(0, needed - stock) }
    var id: Int { color.id }
}

/// 库存操作服务：入库 / 扣减 / 补货计算
@MainActor
enum StockStore {

    /// 某色号当前库存（无记录视为 0）
    static func stock(colorId: Int, context: ModelContext) -> Int {
        var d = FetchDescriptor<BeadStock>(predicate: #Predicate { $0.colorId == colorId })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.count ?? 0
    }

    /// 库存增减（正数入库，负数出库，下限 0）
    static func adjust(colorId: Int, delta: Int, context: ModelContext) {
        var d = FetchDescriptor<BeadStock>(predicate: #Predicate { $0.colorId == colorId })
        d.fetchLimit = 1
        if let item = try? context.fetch(d).first {
            item.count = max(0, item.count + delta)
            item.updatedAt = Date()
        } else if delta > 0 {
            context.insert(BeadStock(colorId: colorId, count: delta))
        }
        try? context.save()
    }

    /// 把库存精确设为某个值
    static func setCount(colorId: Int, count: Int, context: ModelContext) {
        let n = max(0, count)
        var d = FetchDescriptor<BeadStock>(predicate: #Predicate { $0.colorId == colorId })
        d.fetchLimit = 1
        if let item = try? context.fetch(d).first {
            item.count = n
            item.updatedAt = Date()
        } else if n > 0 {
            context.insert(BeadStock(colorId: colorId, count: n))
        }
        try? context.save()
    }

    /// 按图纸需求入库：每种色补足到需求量（库存已超出则不动）
    static func stockIn(pattern: Pattern, context: ModelContext) {
        for item in pattern.beadCounts {
            let cur = stock(colorId: item.color.id, context: context)
            if cur < item.count {
                adjust(colorId: item.color.id, delta: item.count - cur, context: context)
            }
        }
    }

    /// 按图纸需求扣减：每种色减去需求量（下限 0）
    static func deduct(pattern: Pattern, context: ModelContext) {
        for item in pattern.beadCounts {
            adjust(colorId: item.color.id, delta: -item.count, context: context)
        }
    }

    /// 补货清单：需求量超出库存的色号
    static func gaps(pattern: Pattern, context: ModelContext) -> [StockGap] {
        pattern.beadCounts.map { item in
            StockGap(color: item.color, needed: item.count,
                     stock: stock(colorId: item.color.id, context: context))
        }
        .filter { $0.missing > 0 }
    }

    /// 补货清单文本（可直接复制发给店家）
    static func gapsText(pattern: Pattern, context: ModelContext) -> String {
        let list = gaps(pattern: pattern, context: context)
        var lines = ["【\(pattern.name)】补货清单", ""]
        for (i, g) in list.enumerated() {
            lines.append("\(i + 1). Mard \(g.color.mard) × \(g.missing)（需求 \(g.needed)，库存 \(g.stock)）")
        }
        let total = list.reduce(0) { $0 + $1.missing }
        lines.append("")
        lines.append(list.isEmpty ? "库存充足，无需补货" : "共缺 \(list.count) 种颜色，\(total) 颗")
        return lines.joined(separator: "\n")
    }
}
