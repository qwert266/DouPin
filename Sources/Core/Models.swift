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
    var placedCount: Int {
        guard placed.count == cells.count else { return 0 }
        var n = 0
        for i in cells.indices where cells[i] > 0 && placed[i] { n += 1 }
        return n
    }

    var progressPercent: Double {
        let total = totalBeads
        guard total > 0 else { return 0 }
        return Double(placedCount) / Double(total)
    }

    /// 某行是否全部完成
    func isRowPlaced(_ row: Int) -> Bool {
        guard row >= 0 && row < height else { return false }
        for x in 0..<width {
            let i = row * width + x
            if cells[i] > 0 && !placed[i] { return false }
        }
        return true
    }

    /// 标记整行已拼
    func placeRow(_ row: Int) {
        guard row >= 0 && row < height else { return }
        for x in 0..<width {
            let i = row * width + x
            if cells[i] > 0 { placed[i] = true }
        }
        touch()
    }

    /// 标记某色号全部已拼
    func placeColor(colorId: Int) {
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
        placed = [Bool](repeating: false, count: cells.count)
        status = .pending
        startedAt = nil
        completedAt = nil
        updatedAt = Date()
    }

    // MARK: - 变换

    /// 水平镜像
    func mirrorHorizontally() {
        var out = cells
        for y in 0..<height {
            for x in 0..<width {
                out[y * width + x] = cells[y * width + (width - 1 - x)]
            }
        }
        cells = out
        placed = [Bool](repeating: false, count: cells.count)
        touch()
    }

    /// 网格转 UIImage 缩略（列表预览用）
    var thumbnailImage: UIImage {
        PatternRenderer.renderThumb(cells: cells, width: width, height: height)
    }
}
