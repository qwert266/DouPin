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
            UIColor(white: 0.95, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let side = size / CGFloat(max(width, height))
            let ox = (size - side * CGFloat(width)) / 2
            let oy = (size - side * CGFloat(height)) / 2
            for y in 0..<height {
                for x in 0..<width {
                    let v = cells[y * width + x]
                    let c = v > 0 ? BeadPalette.byId[v]?.uiColor ?? .clear : UIColor(white: 1, alpha: 1)
                    c.setFill()
                    ctx.fill(CGRect(x: ox + CGFloat(x) * side, y: oy + CGFloat(y) * side,
                                     width: side, height: side))
                }
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
