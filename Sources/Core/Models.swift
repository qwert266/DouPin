import Foundation
import SwiftData
import SwiftUI

enum WorkStatus: String, Codable {
    case pending      // 待拼
    case inProgress    // 拼制中
    case done          // 已完成

    var label: String {
        switch self {
        case .pending: return "待拼"
        case .inProgress: return "拼制中"
        case .done: return "已完成"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .gray
        case .inProgress: return .blue
        case .done: return .green
        }
    }
}

/// 图纸（同时承载作品记录与进度）
@Model
final class Pattern {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String = "未命名"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// photo / manual / template / import
    var source: String = "manual"
    var width: Int = 29
    var height: Int = 29
    /// 每格的官方色号 colorId（1...295），0 = 空格。行优先。
    var cells: [Int] = []
    /// 拼豆进度：每格是否已放置。长度 = width*height。
    var placed: [Bool] = []
    var statusRaw: String = WorkStatus.pending.rawValue
    var completedAt: Date?
    var startedAt: Date?
    /// 成品照片（JPEG 数据）
    var resultPhoto: Data?

    // MARK: - 功能融合新增字段（T01，全部带默认值以保证 SwiftData 轻量迁移）

    /// 照片转图纸的**原图**（JPEG，长边 ≤2048），支持原图对比模式
    var sourceImageData: Data? = nil
    /// 所属文件夹（弱引用，不使用 SwiftData 关系）
    var folderId: UUID? = nil
    /// 标签（P1）
    var tags: [String] = []
    /// 实际拼板宽；**0 视为等于 `width`**
    var boardWidth: Int = 0
    /// 实际拼板高；**0 视为等于 `height`**
    var boardHeight: Int = 0
    /// 图纸在板上的水平偏移
    var boardOffsetX: Int = 0
    /// 图纸在板上的垂直偏移
    var boardOffsetY: Int = 0
    /// 手动排序序号（拖动排序用）
    var sortOrder: Int = 0
    /// 拆板子图指向父图；非子图时为 nil
    var parentPatternId: UUID? = nil
    /// 拆板编号（如 `"R1C2"`）；非子图时为 nil
    var tileIndex: String? = nil

    var status: WorkStatus {
        get { WorkStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue; updatedAt = Date() }
    }

    init(name: String, width: Int, height: Int, cells: [Int], source: String) {
        self.id = UUID()
        self.name = name
        self.width = width
        self.height = height
        self.cells = cells
        self.placed = [Bool](repeating: false, count: width * height)
        self.source = source
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // MARK: - 统计

    /// 各色号用量（按用量降序）
    var beadCounts: [(color: BeadColor, count: Int)] {
        var dict: [Int: Int] = [:]
        for c in cells where c > 0 { dict[c, default: 0] += 1 }
        return dict
            .compactMap { id, count in BeadPalette.byId[id].map { ($0, count) } }
            .sorted { $0.count > $1.count }
    }

    var totalBeads: Int { cells.filter { $0 > 0 }.count }

    /// 已拼格数（只统计有色格）
    /// 网格数据是否自洽（宽度 × 高度 == cells.count）
    var isGridConsistent: Bool { cells.count == width * height && width > 0 && height > 0 }

    var placedCount: Int {
        guard isGridConsistent, placed.count == cells.count else { return 0 }
        var n = 0
        for i in cells.indices where cells[i] > 0 && placed[i] { n += 1 }
        return n
    }

    var progressPercent: Double {
        let total = totalBeads
        guard total > 0 else { return 0 }
        return Double(placedCount) / Double(total)
    }

    /// 某行是否全部完成（该行至少有一颗豆，且全部已拼）
    func isRowPlaced(_ row: Int) -> Bool {
        guard isGridConsistent, placed.count == cells.count else { return false }
        guard row >= 0 && row < height else { return false }
        var hasBead = false
        for x in 0..<width {
            let i = row * width + x
            if cells[i] > 0 {
                hasBead = true
                if !placed[i] { return false }
            }
        }
        return hasBead          // 全空行不算「已拼完」
    }

    /// 某行是否为空行（没有任何豆子）
    func isEmptyRow(_ row: Int) -> Bool {
        guard isGridConsistent else { return false }
        guard row >= 0 && row < height else { return true }
        for x in 0..<width where cells[row * width + x] > 0 { return false }
        return true
    }

    /// 标记整行已拼
    func placeRow(_ row: Int) {
        guard isGridConsistent, placed.count == cells.count else { return }
        guard row >= 0 && row < height else { return }
        for x in 0..<width {
            let i = row * width + x
            if cells[i] > 0 { placed[i] = true }
        }
        touch()
    }

    /// 标记某色号全部已拼
    func placeColor(colorId: Int) {
        // 越界双保险：网格需自洽且进度数组长度一致
        guard isGridConsistent, placed.count == cells.count else { return }
        for i in cells.indices where cells[i] == colorId { placed[i] = true }
        touch()
    }

    func touch() {
        updatedAt = Date()
        if status == .pending { status = .inProgress; startedAt = Date() }
        if progressPercent >= 1 && status != .done {
            status = .done
            completedAt = Date()
        }
    }

    /// 清空进度
    func resetProgress() {
        // 越界双保险：进度数组长度始终对齐 cells
        placed = [Bool](repeating: false, count: cells.count)
        status = .pending
        startedAt = nil
        completedAt = nil
        updatedAt = Date()
    }

    // MARK: - 变换

    /// 水平镜像
    ///
    /// - 说明（P2 修复）：镜像会改变每个格子的位置，原 `placed` 进度不再对应镜像后的网格，
    ///   因此镜像后清空进度，并把 `status` **回退到 `.pending`**（此前 done 状态不会退回，是 bug）。
    func mirrorHorizontally() {
        guard isGridConsistent else { return }
        var out = cells
        for y in 0..<height {
            for x in 0..<width {
                out[y * width + x] = cells[y * width + (width - 1 - x)]
            }
        }
        cells = out
        // 进度清空 + 状态回退（镜像后需重新拼）
        placed = [Bool](repeating: false, count: cells.count)
        statusRaw = WorkStatus.pending.rawValue
        startedAt = nil
        completedAt = nil
        touch()
    }

    /// 网格转 UIImage 缩略（列表预览用）
    var thumbnailImage: UIImage {
        PatternRenderer.renderThumb(cells: cells, width: width, height: height)
    }
}
