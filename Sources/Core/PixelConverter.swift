import CoreGraphics
import Foundation
import UIKit

/// 照片 → 拼豆色号网格
enum PixelConverter {

    struct Options {
        /// 目标最大边格数（8...104，未指定精确宽高时的等比兜底）
        var maxSide: Int = 28
        /// 精确网格宽（>0 时使用，忽略长宽比）
        var gridWidth: Int = 0
        /// 精确网格高（>0 时使用，忽略长宽比）
        var gridHeight: Int = 0
        /// 限色数（<=0 表示全部 295 色）
        var colorLimit: Int = 24
        /// 白底转空格（logo/线稿友好）
        var whiteToEmpty: Bool = true
        init() {}
    }

    struct Result {
        let width: Int
        let height: Int
        let cells: [Int]
    }

    /// 主流程：图片 → 网格
    static func convert(image: UIImage, options: Options) -> Result {
        guard let cg = image.cgImage else { return Result(width: 0, height: 0, cells: []) }

        // 按精确宽高或长宽比计算网格尺寸
        let srcW = CGFloat(cg.width), srcH = CGFloat(cg.height)
        let side = max(8, min(104, options.maxSide))
        let gwExact = options.gridWidth > 0
        let ghExact = options.gridHeight > 0
        var gw: Int, gh: Int
        if gwExact && ghExact {
            gw = max(8, min(104, options.gridWidth))
            gh = max(8, min(104, options.gridHeight))
        } else if srcW >= srcH {
            gw = side
            gh = max(8, Int(round(CGFloat(side) * srcH / srcW)))
        } else {
            gh = side
            gw = max(8, Int(round(CGFloat(side) * srcW / srcH)))
        }

        guard let ctx = CGContext(data: nil, width: gw, height: gh, bitsPerComponent: 8,
                                  bytesPerRow: gw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Result(width: 0, height: 0, cells: [])
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        guard let data = ctx.data else { return Result(width: 0, height: 0, cells: []) }

        let buf = data.bindMemory(to: UInt8.self, capacity: gw * gh * 4)
        var cells = [Int](repeating: 0, count: gw * gh)
        let pal = candidates(for: options.colorLimit)   // 常用色子集，避免生僻色号
        // 上下翻转（CG 原点在左下）
        for y in 0..<gh {
            let srcRow = gh - 1 - y
            for x in 0..<gw {
                let off = (srcRow * gw + x) * 4
                let r = buf[off], g = buf[off+1], b = buf[off+2], a = buf[off+3]
                if a < 128 { continue }   // 透明 → 空格
                if options.whiteToEmpty && r > 235 && g > 235 && b > 235 { continue }
                cells[y * gw + x] = nearestColorId(r: r, g: g, b: b, palette: pal)
            }
        }

        if options.colorLimit > 0 {
            cells = limitColors(cells, limit: options.colorLimit)
        }
        return Result(width: gw, height: gh, cells: cells)
    }

    // MARK: - 颜色匹配

    /// 依限色目标返回常用色候选子集（nil 表示全 295 色）
    private static func candidates(for limit: Int) -> [BeadColor]? {
        let ids: [Int]
        switch limit {
        case 48: ids = BeadPalette.essentials48
        case 24: ids = BeadPalette.essentials24
        case 16: ids = BeadPalette.essentials16
        default: ids = limit > 0 ? Array(BeadPalette.byId.keys) : []
        }
        return ids.isEmpty ? nil : ids.compactMap { BeadPalette.byId[$0] }
    }

    /// 加权 RGB 距离匹配最近色号（限 palette 子集时传 palette）
    static func nearestColorId(r: UInt8, g: UInt8, b: UInt8, palette: [BeadColor]?) -> Int {
        let candidates = palette ?? BeadPalette.all
        var bestId = candidates[0].id
        var bestDist = Double.greatestFiniteMagnitude
        let dr0 = Double(r), dg0 = Double(g), db0 = Double(b)
        for c in candidates {
            let dr = Double(c.r) - dr0, dg = Double(c.g) - dg0, db = Double(c.b) - db0
            let dist = 0.299*dr*dr + 0.587*dg*dg + 0.114*db*db
            if dist < bestDist { bestDist = dist; bestId = c.id }
        }
        return bestId
    }

    // MARK: - 限色

    /// 把用量最少的颜色并入最接近的常用色，直到颜色数 <= limit
    static func limitColors(_ cells: [Int], limit: Int) -> [Int] {
        var counts: [Int: Int] = [:]
        for c in cells where c > 0 { counts[c, default: 0] += 1 }
        guard counts.count > limit else { return cells }

        var mapping: [Int: Int] = [:]   // 稀有色 → 目标色
        var active = counts             // 仍然存活的色

        while active.count > limit {
            guard let rare = active.min(by: { $0.value < $1.value }),
                  let rareColor = BeadPalette.byId[rare.key] else { break }
            active.removeValue(forKey: rare.key)

            var nearestId: Int? = nil
            var nearestDist = Double.greatestFiniteMagnitude
            for (id, _) in active {
                guard let c = BeadPalette.byId[id] else { continue }
                let dr = Double(c.r) - Double(rareColor.r)
                let dg = Double(c.g) - Double(rareColor.g)
                let db = Double(c.b) - Double(rareColor.b)
                let dist = 0.299*dr*dr + 0.587*dg*dg + 0.114*db*db
                if dist < nearestDist { nearestDist = dist; nearestId = id }
            }
            if let n = nearestId {
                mapping[rare.key] = n
                active[n, default: 0] += rare.value
            } else {
                mapping[rare.key] = 0
            }
        }
        return cells.map { mapping[$0] ?? $0 }
    }
}
