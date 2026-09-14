import CoreGraphics
import Foundation
import UIKit

/// 照片 → 拼豆色号网格
///
/// 转图质量三板斧（对标竞品"色号识别算法"）：
/// 1. **Lab 感知均匀匹配**：旧版用加权 RGB 欧氏距离（0.299/0.587/0.114），
///    RGB 空间感知不均匀——同距离下蓝色偏差人眼几乎无感、绿色偏差刺眼，
///    导致"颜色都转不对"（肤色偏红、灰阶发绿、暗部一团黑）。现改为 CIE Lab 空间 ΔE76，
///    与人眼感知一致性远高于任何 RGB 权重。
/// 2. **自动亮度归一化**：以 luma 的 p5/p95 分位做线性拉伸。暗拍/逆光/过曝照片
///    不再需要手动调，转出来不再糊成一片黑豆/白豆。
/// 3. **伽马正确的分块平均**：先渲染到中间尺寸（长边 160），目标格 = 块内像素
///    先亮度校正 → sRGB 展开为线性光 → 平均 → 压回 sRGB。直接在 sRGB 空间平均
///    会让暗部细节被"平均掉"（视觉上暗块更大、更糊）。
enum PixelConverter {

    struct Options {
        /// 目标最大边格数（8...104）
        var maxSide: Int = 28
        /// 限色数（<=0 表示全部 295 色）
        var colorLimit: Int = 24
        /// 白底转空格（logo/线稿友好）
        var whiteToEmpty: Bool = true
        /// 自动亮度归一化（默认开；用户手动调过亮度时可在调用侧关掉）
        var autoLevels: Bool = true
        /// 允许使用的色号（nil = 全色板）。来自「设置 → 色板档位」
        /// （如 221 色套装、或「仅我的库存色」），确保转出来的色号都买得到。
        var allowedColorIds: [Int]? = nil
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

        // ---- 目标网格尺寸（按长宽比） ----
        let srcW = CGFloat(cg.width), srcH = CGFloat(cg.height)
        let side = CGFloat(max(8, min(104, options.maxSide)))
        var gw: Int, gh: Int
        if srcW >= srcH {
            gw = Int(side)
            gh = max(8, Int(round(side * srcH / srcW)))
        } else {
            gh = Int(side)
            gw = max(8, Int(round(side * srcW / srcH)))
        }

        // ---- 中间渲染（长边 160）：亮度统计 + 分块平均的采样基底 ----
        let midLong = 160
        var midW: Int, midH: Int
        if srcW >= srcH {
            midW = midLong
            midH = max(gw, Int(round(CGFloat(midLong) * srcH / srcW)))
        } else {
            midH = midLong
            midW = max(gh, Int(round(CGFloat(midLong) * srcW / srcH)))
        }
        guard let midBuf = renderRGBA(cg, width: midW, height: midH) else {
            return Result(width: 0, height: 0, cells: [])
        }

        // ---- 自动亮度归一化（luma p5/p95 线性拉伸） ----
        var lo: Double = 0, hi: Double = 255
        if options.autoLevels {
            var lumas: [Double] = []
            lumas.reserveCapacity(midW * midH)
            for i in 0..<(midW * midH) {
                let off = i * 4
                guard midBuf[off + 3] >= 128 else { continue }
                let r = Double(midBuf[off]), g = Double(midBuf[off + 1]), b = Double(midBuf[off + 2])
                lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
            if lumas.count > 32 {
                lumas.sort()
                let p5 = lumas[lumas.count / 20]
                let p95 = lumas[min(lumas.count - 1, lumas.count * 19 / 20)]
                // 留 8 级余量，防止拉伸到满幅；范围过小（纯色图）不拉伸
                lo = max(0, p5 - 8)
                hi = min(255, p95 + 8)
                if hi - lo < 30 { lo = 0; hi = 255 }
            }
        }
        let range = max(1.0, hi - lo)

        // ---- 候选色集 + 色板 Lab 缓存 ----
        let pal = candidates(for: options.colorLimit, allowed: options.allowedColorIds)
        let palLab: [(id: Int, l: Double, a: Double, b2: Double)] =
            (pal ?? BeadPalette.all).map { c in
                let l = lab(r: Double(c.r), g: Double(c.g), b: Double(c.b))
                return (c.id, l.l, l.a, l.b)
            }

        // ---- 分块平均 + 匹配 ----
        var cells = [Int](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            // 目标行在中间图上的覆盖区间（浮点，四舍五入边界）
            let y0 = Int((Double(gy) * Double(midH) / Double(gh)).rounded(.down))
            let y1 = max(y0 + 1, Int((Double(gy + 1) * Double(midH) / Double(gh)).rounded(.down)))
            for gx in 0..<gw {
                let x0 = Int((Double(gx) * Double(midW) / Double(gw)).rounded(.down))
                let x1 = max(x0 + 1, Int((Double(gx + 1) * Double(midW) / Double(gw)).rounded(.down)))

                var sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0, n = 0.0
                for y in y0..<min(y1, midH) {
                    for x in x0..<min(x1, midW) {
                        let off = (y * midW + x) * 4
                        let a = Double(midBuf[off + 3])
                        guard a > 0 else { continue }
                        // 亮度校正（0-255 内 clamp）
                        let r = clamp255((Double(midBuf[off]) - lo) * 255.0 / range)
                        let g = clamp255((Double(midBuf[off + 1]) - lo) * 255.0 / range)
                        let b = clamp255((Double(midBuf[off + 2]) - lo) * 255.0 / range)
                        // sRGB → linear 再平均（伽马正确），权重按 alpha
                        let w = a / 255.0
                        sr += srgbToLinear(r / 255.0) * w
                        sg += srgbToLinear(g / 255.0) * w
                        sb += srgbToLinear(b / 255.0) * w
                        sa += w
                        n += 1
                    }
                }
                guard n > 0, sa > 0 else { continue }   // 全透明 → 空格
                let alphaCoverage = sa / n
                if alphaCoverage < 0.5 { continue }      // 透明为主 → 空格

                // linear 平均 → 压回 sRGB
                let r8 = linearToSrgb(sr / sa) * 255.0
                let g8 = linearToSrgb(sg / sa) * 255.0
                let b8 = linearToSrgb(sb / sa) * 255.0

                // 白底转空（用平均后的实际像素值，阈值略收紧避免误删浅色主体）
                if options.whiteToEmpty && r8 > 240 && g8 > 240 && b8 > 240 { continue }

                let lab = lab(r: r8, g: g8, b: b8)
                var bestId = palLab[0].id
                var bestDist = Double.greatestFiniteMagnitude
                for p in palLab {
                    let dl = lab.l - p.l, da = lab.a - p.a, db = lab.b - p.b2
                    let dist = dl * dl + da * da + db * db
                    if dist < bestDist { bestDist = dist; bestId = p.id }
                }
                cells[gy * gw + gx] = bestId
            }
        }

        // 限色收敛（Lab 距离）
        if options.colorLimit > 0 {
            cells = limitColors(cells, limit: options.colorLimit)
        }
        return Result(width: gw, height: gh, cells: cells)
    }

    // MARK: - 颜色匹配（对外保留，内部走 Lab）

    /// Lab ΔE76 最近色号匹配（palette 为 nil 时用全 295 色）
    static func nearestColorId(r: UInt8, g: UInt8, b: UInt8, palette: [BeadColor]?) -> Int {
        let cand = (palette ?? BeadPalette.all).map { c -> (id: Int, l: Double, a: Double, b2: Double) in
            let l = lab(r: Double(c.r), g: Double(c.g), b: Double(c.b))
            return (c.id, l.l, l.a, l.b)
        }
        let lab0 = lab(r: Double(r), g: Double(g), b: Double(b))
        var bestId = cand[0].id
        var bestDist = Double.greatestFiniteMagnitude
        for p in cand {
            let dl = lab0.l - p.l, da = lab0.a - p.a, db = lab0.b - p.b2
            let dist = dl * dl + da * da + db * db
            if dist < bestDist { bestDist = dist; bestId = p.id }
        }
        return bestId
    }

    // MARK: - 限色

    /// 把用量最少的颜色并入最接近的常用色，直到颜色数 <= limit（Lab 距离）
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

            let rareLab = lab(r: Double(rareColor.r), g: Double(rareColor.g), b: Double(rareColor.b))
            var nearestId: Int? = nil
            var nearestDist = Double.greatestFiniteMagnitude
            for (id, _) in active {
                guard let c = BeadPalette.byId[id] else { continue }
                let l = lab(r: Double(c.r), g: Double(c.g), b: Double(c.b))
                let dl = rareLab.l - l.l, da = rareLab.a - l.a, db = rareLab.b - l.b
                let dist = dl * dl + da * da + db * db
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

    // MARK: - 依限色目标返回常用色候选子集（nil 表示全 295 色）

    /// 设计意图（P1-1 修正）：
    /// - `48 / 24 / 16`：返回**精选常用色子集**，先一步收窄到易买、常见的色号，避免匹配到生僻色；
    /// - `32 / 64 / 0`：返回 `nil`（全色板），不在此处收窄——由 `limitColors` 精确收敛。
    ///
    /// - Parameter allowed: 「设置 → 色板档位」允许的色号（nil = 不限制）。
    ///   与常用色子集取交集；若交集为空（档位里没有常用色，理论不会发生），
    ///   直接退化为 allowed 本身，保证至少能选色。
    private static func candidates(for limit: Int, allowed: [Int]?) -> [BeadColor]? {
        let ids: [Int]
        switch limit {
        case 48: ids = BeadPalette.essentials48
        case 24: ids = BeadPalette.essentials24
        case 16: ids = BeadPalette.essentials16
        default: ids = []   // 32 / 64 / 0 → 全色板
        }

        var palette: [BeadColor]? = ids.isEmpty ? nil : ids.compactMap { BeadPalette.byId[$0] }

        if let allowed, !allowed.isEmpty {
            let allowSet = Set(allowed)
            if let existing = palette {
                let filtered = existing.filter { allowSet.contains($0.id) }
                palette = filtered.isEmpty ? allowed.compactMap { BeadPalette.byId[$0] } : filtered
            } else {
                palette = allowed.compactMap { BeadPalette.byId[$0] }
            }
        }
        return palette
    }

    // MARK: - 色彩空间工具

    /// 渲染 CGImage 为 RGBA8888（premultiplied）buffer
    private static func renderRGBA(_ cg: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // 拷贝出来，避免依赖 CGContext 生命周期
        let n = width * height * 4
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n { out[i] = p[i] }
        return out
    }

    /// sRGB（0-1）→ 线性光
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// 线性光 → sRGB（0-1）
    static func linearToSrgb(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(max(0, c), 1.0 / 2.4) - 0.055
    }

    /// 0-255 RGB → CIE Lab（D65 白点）
    static func lab(r: Double, g: Double, b: Double) -> (l: Double, a: Double, b: Double) {
        let rl = srgbToLinear(clamp01(r / 255.0))
        let gl = srgbToLinear(clamp01(g / 255.0))
        let bl = srgbToLinear(clamp01(b / 255.0))
        let x = rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375
        let y = rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750
        let z = rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041
        let xn = 0.95047, yn = 1.0, zn = 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0) }
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
    private static func clamp255(_ v: Double) -> Double { min(255, max(0, v)) }
}
