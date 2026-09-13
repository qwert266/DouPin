import Foundation

// MARK: - Pattern 板尺寸 / 拆分相关计算属性与方法
//
// ⚠️ 重要说明（SwiftData 限制）：
// SwiftData 的 `@Model` **不支持在 extension 里声明持久化存储属性**。
// 因此 10 个新增持久化字段（sourceImageData / folderId / tags / boardWidth / boardHeight /
// boardOffsetX / boardOffsetY / sortOrder / parentPatternId / tileIndex）全部声明在
// `Sources/Core/Models.swift` 的 `Pattern` 类**内部**（且均带默认值，保证轻量迁移）。
//
// 本文件只承载**计算属性与便捷方法**（非持久化），保持 `Models.swift` 主体结构清晰。
//
// 语义（架构师 §A.4.1）：
// - `width/height` = 图纸行列数（像素化网格）。
// - `boardWidth/boardHeight + offset` = 图纸在实体板上的落位。
// - `boardWidth == 0` 视为「与图纸尺寸相同」（向后兼容旧数据）。

extension Pattern {

    // MARK: - 板尺寸

    /// 实际拼板宽度：`boardWidth > 0` 时取之，否则回落到图纸宽度 `width`
    var effectiveBoardWidth: Int {
        boardWidth > 0 ? boardWidth : width
    }

    /// 实际拼板高度：`boardHeight > 0` 时取之，否则回落到图纸高度 `height`
    var effectiveBoardHeight: Int {
        boardHeight > 0 ? boardHeight : height
    }

    /// 是否显式设置了板尺寸（即存在有效的 boardWidth/boardHeight）
    var hasExplicitBoard: Bool {
        boardWidth > 0 || boardHeight > 0
    }

    /// 板尺寸是否可容纳图纸（不含偏移）：板宽 ≥ 图纸宽 且 板高 ≥ 图纸高
    var isBoardLargeEnough: Bool {
        effectiveBoardWidth >= width && effectiveBoardHeight >= height
    }

    // MARK: - 拆板子图

    /// 是否为拆板子图（同时具备父图 id 与拆板编号）
    var isTile: Bool {
        parentPatternId != nil && tileIndex != nil
    }

    /// 是否为拆板父图（拥有子图 id 关联的来源标记）
    /// - 说明：父图本身通过 `source == "split-parent"` 或存在子图（外部查询）判定；
    ///   这里仅表示"非子图且存在拆板编号的可能性"的便捷判断，供 UI 分支使用。
    var isSplitRootCandidate: Bool {
        parentPatternId == nil && tileIndex == nil
    }

    /// 所属文件夹 id（弱引用；无归属返回 nil）
    var folder: UUID? { folderId }

    // MARK: - 板上落位（防越界钳制）

    /// 图纸在板上的落位矩形 `(x, y, w, h)`（单位：格）
    ///
    /// - 防越界：偏移量钳制到 `[0, boardW - 图纸宽]`；若图纸本身大于板，
    ///   则落位宽高钳制为板尺寸（左上对齐，超出部分在渲染/引导时天然被裁剪）。
    /// - 返回的 `w/h` 为**图纸可见宽度/高度**（已按板尺寸与偏移钳制）。
    var clampedBoardRect: (x: Int, y: Int, w: Int, h: Int) {
        let boardW = max(1, effectiveBoardWidth)
        let boardH = max(1, effectiveBoardHeight)

        // 可见宽高：图纸宽高与板尺寸取较小值（防图纸大于板）
        let w = min(width, boardW)
        let h = min(height, boardH)

        // 偏移钳制：允许范围为 [0, 板尺寸 - 可见宽高]
        let maxX = max(0, boardW - w)
        let maxY = max(0, boardH - h)
        let x = min(max(0, boardOffsetX), maxX)
        let y = min(max(0, boardOffsetY), maxY)

        return (x: x, y: y, w: w, h: h)
    }

    /// 板上落位矩形的偏移起点（`clampedBoardRect` 的 `x`）
    var boardOriginX: Int { clampedBoardRect.x }

    /// 板上落位矩形的偏移起点（`clampedBoardRect` 的 `y`）
    var boardOriginY: Int { clampedBoardRect.y }

    /// 指定板坐标 (bx, by) 是否落在图纸有效区内
    /// - Parameters:
    ///   - bx: 板坐标 x
    ///   - by: 板坐标 y
    /// - Returns: 落在图纸有效区内返回 true
    func containsBoardPoint(bx: Int, by: Int) -> Bool {
        let rect = clampedBoardRect
        return bx >= rect.x && bx < rect.x + rect.w
            && by >= rect.y && by < rect.y + rect.h
    }

    /// 把板坐标 (bx, by) 映射为图纸内部索引（行优先）；越界返回 nil
    /// - Parameters:
    ///   - bx: 板坐标 x
    ///   - by: 板坐标 y
    /// - Returns: `cells` 中的索引；不在有效区内返回 nil
    func gridIndex(fromBoardX bx: Int, boardY by: Int) -> Int? {
        guard isGridConsistent else { return nil }
        let rect = clampedBoardRect
        guard bx >= rect.x, bx < rect.x + rect.w,
              by >= rect.y, by < rect.y + rect.h else { return nil }
        let gx = bx - rect.x
        let gy = by - rect.y
        guard gx >= 0, gx < width, gy >= 0, gy < height else { return nil }
        return gy * width + gx
    }

    // MARK: - 板尺寸便捷方法

    /// 设置实际拼板尺寸（传 0 或负数表示「与图纸尺寸相同」）
    /// - Parameters:
    ///   - boardW: 板宽
    ///   - boardH: 板高
    func setBoardSize(width boardW: Int, height boardH: Int) {
        self.boardWidth = max(0, boardW)
        self.boardHeight = max(0, boardH)
        touch()
    }

    /// 设置图纸在板上的偏移（会被后续 `clampedBoardRect` 钳制）
    /// - Parameters:
    ///   - x: 水平偏移
    ///   - y: 垂直偏移
    func setBoardOffset(x: Int, y: Int) {
        self.boardOffsetX = max(0, x)
        self.boardOffsetY = max(0, y)
        touch()
    }

    /// 把图纸居中放置到当前板上（依据 `effectiveBoard*` 计算偏移）
    func centerOnBoard() {
        let rect = clampedBoardRect
        let boardW = max(1, effectiveBoardWidth)
        let boardH = max(1, effectiveBoardHeight)
        self.boardOffsetX = max(0, (boardW - rect.w) / 2)
        self.boardOffsetY = max(0, (boardH - rect.h) / 2)
        touch()
    }

    // MARK: - 来源与外键便捷方法

    /// 是否为照片转图纸来源（存在原图数据）
    var hasSourceImage: Bool { sourceImageData != nil }

    /// 关联到文件夹（传 nil 表示移出）
    /// - Parameter id: 目标文件夹 id
    func assignFolder(_ id: UUID?) {
        self.folderId = id
        touch()
    }

    /// 追加一个标签（去重、去除空白；空字符串忽略）
    /// - Parameter tag: 标签文本
    func addTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        touch()
    }

    /// 移除一个标签
    /// - Parameter tag: 标签文本
    func removeTag(_ tag: String) {
        guard let idx = tags.firstIndex(of: tag) else { return }
        tags.remove(at: idx)
        touch()
    }

    /// 标记为拆板子图
    /// - Parameters:
    ///   - parentId: 父图 id
    ///   - index: 拆板编号（如 "R1C2"）
    func markAsTile(parentId: UUID, tileIndex index: String) {
        self.parentPatternId = parentId
        self.tileIndex = index
        touch()
    }
}
