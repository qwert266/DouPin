import Foundation
import UIKit

/// PDF 导出：把网格图纸渲染为 A4 分页 PDF（PRD §5.8 / 架构师 §A.2）。
///
/// 设计说明：
/// - 依据架构师 §A.2 选型，使用 **`UIGraphicsPDFRenderer`**（UIKit）生成矢量排版 PDF，
///   **不使用 PDFKit**；与现有 `PatternRenderer`（`UIGraphicsImageRenderer`）风格同源。
/// - A4 点尺寸：595.2 × 841.8 pt（72 dpi）。当图纸超过一页时按 A4 自动分页，
///   每页绘制页眉（标题 + "第 X/Y 页"）、网格线 + 色号标注；图例放在**最后一页底部**。
/// - 纯函数：输入 `cells/width/height/options`，输出 `Data?`（失败返回 `nil`，不抛异常）。
///
/// 并发约定：本类型为无状态 `enum + static func`，仅使用值类型参数与 `Data` 返回，
/// 可在任意线程/`Task.detached` 调用（不涉及 `UIImage` 跨 actor 传递）。
enum PDFExporter {

    // MARK: - 选项

    /// PDF 导出选项
    struct PDFOptions {
        /// 单格边长（pt）。打印用默认 20pt（约 7mm）。
        var cellSize: CGFloat = 20
        /// 是否在格内标注色号（Mard）
        var showLabels: Bool = true
        /// 是否在最后一页底部绘制图例（色号 ↔ 颜色）
        var showLegend: Bool = true
        /// 标题（每页页眉左侧；为空则不画标题）
        var title: String = ""
        /// 页边距（pt）
        var pageMargin: CGFloat = 24
        /// 目标板尺寸（格）。用于页脚标注"板尺寸"，非分页依据（分页按 A4 可容纳格数）
        var boardSize: Int = 29

        /// 默认构造
        init() {}
    }

    // MARK: - 常量（A4 @72dpi）

    /// A4 宽度（pt）
    static let a4Width: CGFloat = 595.2
    /// A4 高度（pt）
    static let a4Height: CGFloat = 841.8

    /// 页眉高度（pt）：用于放标题与页码
    private static let headerHeight: CGFloat = 36
    /// 页脚高度（pt）：用于放"第 X/Y 页"
    private static let footerHeight: CGFloat = 24

    // MARK: - 分页模型

    /// 单页可容纳的格子信息
    private struct PagePlan {
        /// 该页起始列（母图列坐标）
        let colStart: Int
        /// 该页起始行（母图行坐标）
        let rowStart: Int
        /// 该页列数
        let cols: Int
        /// 该页行数
        let rows: Int
    }

    // MARK: - 主入口

    /// 生成 A4 分页 PDF 的 `Data`。
    ///
    /// - Parameters:
    ///   - cells: 网格数据（行优先，`0` 表示空格）
    ///   - width: 图纸列数
    ///   - height: 图纸行数
    ///   - options: 导出选项
    /// - Returns: PDF 数据；`cells` 与尺寸不一致/为空时返回 `nil`
    static func exportPattern(cells: [Int], width: Int, height: Int, options: PDFOptions) -> Data? {
        // 参数校验：尺寸合法且 cells 数量匹配
        guard width > 0, height > 0, cells.count >= width * height else { return nil }

        let cell = max(4, options.cellSize)
        let margin = max(0, options.pageMargin)

        // 可用绘制区（扣除页边距 + 页眉 + 页脚）
        let availW = a4Width - margin * 2
        let availH = a4Height - margin * 2 - headerHeight - footerHeight
        guard availW > cell, availH > cell else { return nil }

        // 每页可容纳的格数
        let colsPerPage = max(1, Int(availW / cell))
        let rowsPerPage = max(1, Int(availH / cell))

        // 计算分页计划
        let plans = makePagePlans(width: width, height: height,
                                  colsPerPage: colsPerPage, rowsPerPage: rowsPerPage)
        let totalPages = plans.count
        guard totalPages > 0 else { return nil }

        // 图例（仅最后一页绘制）
        let legend = options.showLegend ? legendItems(cells: cells) : []

        let bounds = CGRect(x: 0, y: 0, width: a4Width, height: a4Height)
        let format = UIGraphicsPDFRendererFormat()
        // 元数据（可选，便于打印/分享时识别）
        format.documentInfo = [
            kCGPDFContextTitle as String: options.title.isEmpty ? L10n.s("豆绘小栈图纸") : options.title,
            kCGPDFContextCreator as String: L10n.s("豆绘小栈")
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        let data = renderer.pdfData { ctx in
            for (index, plan) in plans.enumerated() {
                // beginPage()：开启新的一页（A4 尺寸由 renderer.bounds 决定）
                ctx.beginPage()
                let cg = ctx.cgContext

                // 白底（避免某些查看器默认透明）
                UIColor.white.setFill()
                cg.fill(bounds)

                let pageNo = index + 1
                let isLastPage = pageNo == totalPages

                // 网格起始原点（页边距 + 页眉）
                let originX = margin
                let originY = margin + headerHeight

                drawHeader(ctx: cg, options: options,
                           pageNo: pageNo, totalPages: totalPages,
                           originX: originX, originY: margin)
                drawGrid(cg: cg, cells: cells, width: width,
                         plan: plan, cell: cell,
                         originX: originX, originY: originY, options: options)

                // 图例（仅最后一页）
                if isLastPage, !legend.isEmpty {
                    let gridBottom = originY + CGFloat(plan.rows) * cell
                    let legendTop = gridBottom + 16
                    drawLegend(cg: cg, items: legend,
                               topY: legendTop,
                               originX: originX, availW: availW,
                               pageBottom: a4Height - margin - footerHeight)
                }

                drawFooter(cg: cg, pageNo: pageNo, totalPages: totalPages,
                           plan: plan, options: options,
                           originX: originX, availW: availW)
            }
        }
        return data
    }

    /// 把 PDF 数据写入临时文件（供 `ShareLink` 分享）。
    ///
    /// - Parameters:
    ///   - data: PDF 数据
    ///   - name: 文件名（不含扩展名；非法字符会被替换）
    /// - Returns: 临时文件 URL；写入失败返回 `nil`
    static func writePDFToTemp(_ data: Data, name: String) -> URL? {
        let safeName = sanitizeFileName(name)
        let fileName = safeName.isEmpty ? L10n.s("豆绘小栈图纸.pdf") : "\(safeName).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            // 覆盖旧同名临时文件
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 便利方法：一步生成 PDF 并写入临时文件。
    ///
    /// - Returns: 临时文件 URL；生成或写入失败返回 `nil`
    static func exportToTempFile(cells: [Int], width: Int, height: Int,
                                 options: PDFOptions, name: String) -> URL? {
        guard let data = exportPattern(cells: cells, width: width, height: height, options: options) else {
            return nil
        }
        return writePDFToTemp(data, name: name)
    }

    // MARK: - 分页计算

    /// 生成分页计划：按 A4 每页可容纳格数把 `width × height` 切成若干页。
    ///
    /// 说明：分页按"先行后列"的块状切分——先横向铺满 `colsPerPage` 列，
    /// 再纵向铺满 `rowsPerPage` 行；一页填满后进入下一页。这样每页内容连续、便于对照打印。
    private static func makePagePlans(width: Int, height: Int,
                                      colsPerPage: Int, rowsPerPage: Int) -> [PagePlan] {
        var plans: [PagePlan] = []
        // 横向分段数 / 纵向分段数
        let colChunks = (width + colsPerPage - 1) / colsPerPage
        let rowChunks = (height + rowsPerPage - 1) / rowsPerPage
        for rc in 0..<rowChunks {
            let rowStart = rc * rowsPerPage
            let rows = min(rowsPerPage, height - rowStart)
            guard rows > 0 else { continue }
            for cc in 0..<colChunks {
                let colStart = cc * colsPerPage
                let cols = min(colsPerPage, width - colStart)
                guard cols > 0 else { continue }
                plans.append(PagePlan(colStart: colStart, rowStart: rowStart,
                                      cols: cols, rows: rows))
            }
        }
        return plans
    }

    // MARK: - 绘制

    /// 绘制页眉：标题（左）+ "第 X/Y 页"（右）
    private static func drawHeader(ctx: CGContext, options: PDFOptions,
                                   pageNo: Int, totalPages: Int,
                                   originX: CGFloat, originY: CGFloat) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 14),
            .foregroundColor: UIColor.black
        ]
        let titleText = options.title.isEmpty ? L10n.s("豆绘小栈图纸") : options.title
        (titleText as NSString).draw(at: CGPoint(x: originX, y: originY + 4),
                                     withAttributes: titleAttrs)

        let pageAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.darkGray
        ]
        let pageText = L10n.p("第 {0}/{1} 页", "\(pageNo)", "\(totalPages)") as NSString
        let size = pageText.size(withAttributes: pageAttrs)
        let x = a4Width - options.pageMargin - size.width
        pageText.draw(at: CGPoint(x: x, y: originY + 6), withAttributes: pageAttrs)
    }

    /// 绘制一页的网格：色块 + 网格线 + 色号标注
    private static func drawGrid(cg: CGContext, cells: [Int], width: Int,
                                 plan: PagePlan, cell: CGFloat,
                                 originX: CGFloat, originY: CGFloat,
                                 options: PDFOptions) {
        // 色块
        for r in 0..<plan.rows {
            for c in 0..<plan.cols {
                let gx = plan.colStart + c
                let gy = plan.rowStart + r
                let idx = gy * width + gx
                guard idx >= 0, idx < cells.count else { continue }
                let v = cells[idx]
                let color = v > 0 ? (BeadPalette.byId[v]?.uiColor ?? .white)
                                  : UIColor(white: 0.97, alpha: 1)
                color.setFill()
                cg.fill(CGRect(x: originX + CGFloat(c) * cell,
                               y: originY + CGFloat(r) * cell,
                               width: cell + 0.4, height: cell + 0.4))
            }
        }

        // 网格线
        UIColor(white: 0.78, alpha: 1).setStroke()
        cg.setLineWidth(0.4)
        let gridW = CGFloat(plan.cols) * cell
        let gridH = CGFloat(plan.rows) * cell
        for c in 0...plan.cols {
            let x = originX + CGFloat(c) * cell
            cg.move(to: CGPoint(x: x, y: originY))
            cg.addLine(to: CGPoint(x: x, y: originY + gridH))
        }
        for r in 0...plan.rows {
            let y = originY + CGFloat(r) * cell
            cg.move(to: CGPoint(x: originX, y: y))
            cg.addLine(to: CGPoint(x: originX + gridW, y: y))
        }
        cg.strokePath()

        // 色号标注（仅当格够大，避免糊成一团）
        guard options.showLabels, cell >= 14 else { return }
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: min(9, cell * 0.32), weight: .medium),
            .foregroundColor: UIColor.black
        ]
        for r in 0..<plan.rows {
            for c in 0..<plan.cols {
                let gx = plan.colStart + c
                let gy = plan.rowStart + r
                let idx = gy * width + gx
                guard idx >= 0, idx < cells.count else { continue }
                let v = cells[idx]
                guard v > 0, let bc = BeadPalette.byId[v] else { continue }
                let s = bc.mard as NSString
                let sz = s.size(withAttributes: labelAttrs)
                let px = originX + CGFloat(c) * cell + (cell - sz.width) / 2
                let py = originY + CGFloat(r) * cell + (cell - sz.height) / 2
                s.draw(at: CGPoint(x: px, y: py), withAttributes: labelAttrs)
            }
        }
    }

    /// 绘制图例（色块 + "色号 ×数量"）
    private static func drawLegend(cg: CGContext, items: [LegendItem],
                                   topY: CGFloat, originX: CGFloat, availW: CGFloat,
                                   pageBottom: CGFloat) {
        guard !items.isEmpty, topY < pageBottom - 20 else { return }

        // 标题
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 11),
            .foregroundColor: UIColor.black
        ]
        (L10n.s("图例") as NSString).draw(at: CGPoint(x: originX, y: topY), withAttributes: titleAttrs)

        let cols = 3
        let rowH: CGFloat = 18
        let colW = availW / CGFloat(cols)
        let attr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.black
        ]
        let startY = topY + 16
        for (i, item) in items.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = originX + CGFloat(col) * colW
            let y = startY + CGFloat(row) * rowH
            // 超出可用区则停止（防止压到页脚）
            if y + rowH > pageBottom { break }
            item.color.uiColor.setFill()
            cg.fill(CGRect(x: x, y: y, width: 12, height: 12))
            UIColor(white: 0.6, alpha: 1).setStroke()
            cg.setLineWidth(0.4)
            cg.stroke(CGRect(x: x, y: y, width: 12, height: 12))
            ("\(item.mard) ×\(item.count)" as NSString).draw(
                at: CGPoint(x: x + 15, y: y + 1), withAttributes: attr)
        }
    }

    /// 绘制页脚：板尺寸/尺寸说明（左）+ 页码（右，冗余强化）
    private static func drawFooter(cg: CGContext, pageNo: Int, totalPages: Int,
                                   plan: PagePlan, options: PDFOptions,
                                   originX: CGFloat, availW: CGFloat) {
        let attr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.gray
        ]
        let info = L10n.p("板尺寸 {0}×{1} · 本页 行{2}-{3} 列{4}-{5}", "\(options.boardSize)", "\(options.boardSize)", "\(plan.rowStart + 1)", "\(plan.rowStart + plan.rows)", "\(plan.colStart + 1)", "\(plan.colStart + plan.cols)")
        (info as NSString).draw(at: CGPoint(x: originX, y: a4Height - options.pageMargin - footerHeight + 8),
                                withAttributes: attr)

        let pageText = L10n.p("第 {0}/{1} 页", "\(pageNo)", "\(totalPages)") as NSString
        let size = pageText.size(withAttributes: attr)
        pageText.draw(at: CGPoint(x: a4Width - options.pageMargin - size.width,
                                  y: a4Height - options.pageMargin - footerHeight + 8),
                      withAttributes: attr)
    }

    // MARK: - 图例数据

    /// 图例条目
    private struct LegendItem {
        let mard: String
        let count: Int
        let color: BeadColor
    }

    /// 由 cells 统计图例（按用量降序）
    private static func legendItems(cells: [Int]) -> [LegendItem] {
        var counts: [Int: Int] = [:]
        for c in cells where c > 0 { counts[c, default: 0] += 1 }
        return counts
            .compactMap { id, n in BeadPalette.byId[id].map { LegendItem(mard: $0.mard, count: n, color: $0) } }
            .sorted { $0.count > $1.count }
    }

    // MARK: - 工具

    /// 清理文件名中的非法字符（`/`、`\`、`:` 等）
    private static func sanitizeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return trimmed.components(separatedBy: invalid).joined(separator: "_")
    }
}
