import Foundation
import SwiftUI
import UIKit

/// 网格 → 各种图像输出
enum PatternRenderer {

    // MARK: - 缩略图（列表用）

    static func renderThumb(cells: [Int], width: Int, height: Int, size: CGFloat = 64) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: fmt)
        return r.image { ctx in
            ctx.cgContext.setFillColor(UIColor(white: 0.95, alpha: 1).cgColor)
            ctx.cgContext.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let side = size / CGFloat(max(width, height))
            let ox = (size - side * CGFloat(width)) / 2
            let oy = (size - side * CGFloat(height)) / 2
            for y in 0..<height {
                for x in 0..<width {
                    let v = cells[y * width + x]
                    let c = v > 0 ? BeadPalette.byId[v]?.uiColor ?? .clear : UIColor(white: 1, alpha: 1)
                    c.setFill()
                    ctx.cgContext.fill(CGRect(x: ox + CGFloat(x) * side, y: oy + CGFloat(y) * side,
                                              width: side, height: side))
                }
            }
        }
    }

    // MARK: - 作品分享卡（竖版 2:3，对标 AI豆仓「作品集」分享）

    struct ShareCardOptions {
        var title: String = "未命名作品"
        /// 元信息行（尺寸 / 颗数 / 日期）
        var meta: String = ""
        init() {}
    }

    /// 生成作品分享卡：成品照片（有则用照片，否则图纸网格）+ 名称 + 元信息 + 色号用量 Top6 + 品牌落款。
    /// 竖版 540×810（2:3），适合直接分享到微信 / 小红书。
    static func shareCard(photo: UIImage?, cells: [Int], width: Int, height: Int,
                          options: ShareCardOptions) -> UIImage {
        let W: CGFloat = 540, H: CGFloat = 810
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let r = UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: fmt)
        return r.image { ctx in
            let cg = ctx.cgContext

            // 背景：品牌粉紫渐变
            let colors = [UIColor(red: 1.00, green: 0.38, blue: 0.55, alpha: 1).cgColor,
                          UIColor(red: 0.86, green: 0.32, blue: 0.90, alpha: 1).cgColor]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: W, y: H), options: [])
            }

            // 右上角装饰豆点（错落）
            let dotRows: [[Bool]] = [[true, false, true, true, false, true],
                                     [false, true, true, false, true, false],
                                     [true, true, false, true, false, true]]
            UIColor.white.withAlphaComponent(0.22).setFill()
            for (ri, row) in dotRows.enumerated() {
                for (ci, on) in row.enumerated() where on {
                    let rect = CGRect(x: W - 52 - CGFloat(ci) * 16, y: 22 + CGFloat(ri) * 16, width: 10, height: 10)
                    UIBezierPath(ovalIn: rect).fill()
                }
            }

            // 主图区（成品照片优先，否则图纸网格）
            let imgRect = CGRect(x: 34, y: 40, width: W - 68, height: 462)
            let clip = UIBezierPath(roundedRect: imgRect, cornerRadius: 26)
            cg.saveGState()
            clip.addClip()
            UIColor.white.setFill()
            cg.fill(imgRect)
            if let photo {
                drawAspectFill(photo, in: imgRect)
            } else {
                drawGrid(cells: cells, width: width, height: height, in: imgRect, cg: cg)
            }
            cg.restoreGState()
            UIColor.white.withAlphaComponent(0.38).setStroke()
            clip.lineWidth = 2
            clip.stroke()

            // 标题
            (options.title as NSString).draw(
                in: CGRect(x: 36, y: 524, width: W - 72, height: 40),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 30),
                                 .foregroundColor: UIColor.white])

            // 元信息
            (options.meta as NSString).draw(
                at: CGPoint(x: 36, y: 570),
                withAttributes: [.font: UIFont.systemFont(ofSize: 16),
                                 .foregroundColor: UIColor.white.withAlphaComponent(0.88)])

            // 色号用量 Top6
            let legend = Array(legendCounts(cells: cells).prefix(6))
            var x: CGFloat = 36
            let chipY: CGFloat = 612
            let chipW: CGFloat = 74, chipH: CGFloat = 58
            for item in legend {
                let chipRect = CGRect(x: x, y: chipY, width: chipW, height: chipH)
                UIColor.white.withAlphaComponent(0.18).setFill()
                UIBezierPath(roundedRect: chipRect, cornerRadius: 14).fill()

                item.color.uiColor.setFill()
                UIBezierPath(ovalIn: CGRect(x: x + 10, y: chipY + 9, width: 16, height: 16)).fill()
                (item.mard as NSString).draw(
                    at: CGPoint(x: x + 31, y: chipY + 9),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 13),
                                     .foregroundColor: UIColor.white])
                ("×\(item.count)" as NSString).draw(
                    at: CGPoint(x: x + 10, y: chipY + 32),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 12),
                                     .foregroundColor: UIColor.white.withAlphaComponent(0.9)])
                x += chipW + 8
            }

            // 落款
            ("豆拼 DouPin" as NSString).draw(
                at: CGPoint(x: 36, y: H - 54),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 15),
                                 .foregroundColor: UIColor.white.withAlphaComponent(0.92)])
            ("照片变图纸 · 图纸点亮拼豆板" as NSString).draw(
                at: CGPoint(x: 38, y: H - 34),
                withAttributes: [.font: UIFont.systemFont(ofSize: 11),
                                 .foregroundColor: UIColor.white.withAlphaComponent(0.7)])
        }
    }

    /// 等比填充绘制（配合裁剪实现 cover 效果）
    private static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        let iw = image.size.width, ih = image.size.height
        guard iw > 0, ih > 0 else { return }
        let scale = max(rect.width / iw, rect.height / ih)
        let dw = iw * scale, dh = ih * scale
        image.draw(in: CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2, width: dw, height: dh))
    }

    /// 在指定区域居中绘制图纸网格（空格浅灰、有色格实时色）
    private static func drawGrid(cells: [Int], width: Int, height: Int, in rect: CGRect, cg: CGContext) {
        guard width > 0, height > 0, cells.count >= width * height else { return }
        let side = min(rect.width / CGFloat(width), rect.height / CGFloat(height))
        let ox = rect.minX + (rect.width - side * CGFloat(width)) / 2
        let oy = rect.minY + (rect.height - side * CGFloat(height)) / 2
        for y in 0..<height {
            for x in 0..<width {
                let v = cells[y * width + x]
                let c = v > 0 ? (BeadPalette.byId[v]?.uiColor ?? .white) : UIColor(white: 0.97, alpha: 1)
                c.setFill()
                cg.fill(CGRect(x: ox + CGFloat(x) * side, y: oy + CGFloat(y) * side,
                               width: side + 0.5, height: side + 0.5))
            }
        }
    }

    // MARK: - 图纸导出（网格 + 色号标注 + 图例）
    struct ExportOptions {
        var cellSize: CGFloat = 24
        var showGrid = true
        var showGuides = true      // 每 10 格加粗辅助线
        var showLabels = true      // 格子里写色号
        var showLegend = true      // 底部图例（色号、色块、数量）
        var title: String = ""
        init() {}
    }

    static func exportPattern(cells: [Int], width: Int, height: Int, options: ExportOptions) -> UIImage {
        let cell = options.showLabels ? max(28, options.cellSize) : options.cellSize
        let margin: CGFloat = 16
        let headerH: CGFloat = options.title.isEmpty ? 0 : 56
        let legend = options.showLegend ? legendCounts(cells: cells) : []
        let legendCols = 6
        let legendRows = legend.isEmpty ? 0 : (legend.count + legendCols - 1) / legendCols
        let legendRowH: CGFloat = 40
        let legendH = legendRows == 0 ? 0 : CGFloat(legendRows) * legendRowH + 24

        let canvasW = margin * 2 + cell * CGFloat(width)
        let canvasH = margin * 2 + headerH + cell * CGFloat(height) + legendH
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 2
        let r = UIGraphicsImageRenderer(size: CGSize(width: canvasW, height: canvasH), format: fmt)
        return r.image { ctx in
            let cg = ctx.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

            var y0 = margin
            if !options.title.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 20),
                    .foregroundColor: UIColor.black
                ]
                (options.title as NSString).draw(at: CGPoint(x: margin, y: margin), withAttributes: attrs)
                let sub = "宽 \(width) × 高 \(height) 格 · 共 \(cells.filter { $0 > 0 }.count) 颗 · 豆拼 DouPin"
                let subAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13),
                    .foregroundColor: UIColor.darkGray
                ]
                (sub as NSString).draw(at: CGPoint(x: margin, y: margin + 26), withAttributes: subAttrs)
                y0 += headerH
            }

            let grid = CGRect(x: margin, y: y0, width: cell * CGFloat(width), height: cell * CGFloat(height))

            // 色块
            for gy in 0..<height {
                for gx in 0..<width {
                    let v = cells[gy * width + gx]
                    let c = v > 0 ? BeadPalette.byId[v]?.uiColor ?? .white : UIColor(white: 0.97, alpha: 1)
                    c.setFill()
                    cg.fill(CGRect(x: grid.minX + CGFloat(gx) * cell, y: grid.minY + CGFloat(gy) * cell,
                                   width: cell + 0.5, height: cell + 0.5))
                }
            }

            // 网格线
            if options.showGrid {
                UIColor(white: 0.78, alpha: 1).setStroke()
                cg.setLineWidth(0.5)
                for gx in 0...width {
                    let x = grid.minX + CGFloat(gx) * cell
                    cg.move(to: CGPoint(x: x, y: grid.minY))
                    cg.addLine(to: CGPoint(x: x, y: grid.maxY))
                }
                for gy in 0...height {
                    let y = grid.minY + CGFloat(gy) * cell
                    cg.move(to: CGPoint(x: grid.minX, y: y))
                    cg.addLine(to: CGPoint(x: grid.maxX, y: y))
                }
                cg.strokePath()
            }

            // 辅助线（每 10 格）
            if options.showGuides {
                UIColor(white: 0.35, alpha: 1).setStroke()
                cg.setLineWidth(1.4)
                for gx in stride(from: 10, to: width, by: 10) {
                    let x = grid.minX + CGFloat(gx) * cell
                    cg.move(to: CGPoint(x: x, y: grid.minY))
                    cg.addLine(to: CGPoint(x: x, y: grid.maxY))
                }
                for gy in stride(from: 10, to: height, by: 10) {
                    let y = grid.minY + CGFloat(gy) * cell
                    cg.move(to: CGPoint(x: grid.minX, y: y))
                    cg.addLine(to: CGPoint(x: grid.maxX, y: y))
                }
                cg.strokePath()
            }

            // 色号标注
            if options.showLabels {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: min(9, cell * 0.32), weight: .medium),
                    .foregroundColor: UIColor.black
                ]
                for gy in 0..<height {
                    for gx in 0..<width {
                        let v = cells[gy * width + gx]
                        guard v > 0, let bc = BeadPalette.byId[v] else { continue }
                        let s = bc.mard as NSString
                        let sz = s.size(withAttributes: attrs)
                        let px = grid.minX + CGFloat(gx) * cell + (cell - sz.width) / 2
                        let py = grid.minY + CGFloat(gy) * cell + (cell - sz.height) / 2
                        s.draw(at: CGPoint(x: px, y: py), withAttributes: attrs)
                    }
                }
            }

            // 图例
            if !legend.isEmpty {
                let ly0 = y0 + cell * CGFloat(height) + 24
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 11),
                    .foregroundColor: UIColor.black
                ]
                for (i, item) in legend.enumerated() {
                    let col = i % legendCols
                    let row = i / legendCols
                    let x = margin + CGFloat(col) * (canvasW - margin * 2) / CGFloat(legendCols)
                    let y = ly0 + CGFloat(row) * legendRowH
                    let rect = CGRect(x: x, y: y, width: 18, height: 18)
                    item.color.uiColor.setFill()
                    cg.fill(rect)
                    ("\(item.mard) ×\(item.count)" as NSString).draw(
                        at: CGPoint(x: x + 22, y: y + 2), withAttributes: attrs)
                }
            }
        }
    }

    private static func legendCounts(cells: [Int]) -> [(mard: String, count: Int, color: BeadColor)] {
        var counts: [Int: Int] = [:]
        for c in cells where c > 0 { counts[c, default: 0] += 1 }
        return counts
            .compactMap { id, n in BeadPalette.byId[id].map { ($0.mard, n, $0) } }
            .sorted { $0.count > $1.count }
    }

    /// 豆子清单文本（可复制）
    static func beadListText(name: String, cells: [Int]) -> String {
        let legend = legendCounts(cells: cells)
        var lines = ["【\(name)】豆子清单", ""]
        var total = 0
        for (i, item) in legend.enumerated() {
            lines.append("\(i + 1). \(item.mard) × \(item.count)")
            total += item.count
        }
        lines.append("")
        lines.append("共 \(legend.count) 种颜色，\(total) 颗")
        return lines.joined(separator: "\n")
    }
}
