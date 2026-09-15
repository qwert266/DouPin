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
        /// 灰世界自动白平衡（默认开）：消除室内暖光/冷光造成的整体色偏
        var autoWhiteBalance: Bool = true
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
        guard var midBuf = renderRGBA(cg, width: midW, height: midH) else {
            return Result(width: 0, height: 0, cells: [])
        }

        // ---- 灰世界白平衡（消除整体色偏：暖光偏黄 / 冷光偏蓝）----
        //
        // 室内照片常整体偏色；色差公式再准，也会把"整张都偏黄"照实转成偏黄的豆色。
        // 灰世界假设：场景平均反射为中性灰 → 用各通道均值求增益，按 0.8 强度混合，
        // 并把单通道增益限制在 0.75…1.35，避免把本来就有主色调的画面（如整片蓝天）拉灰。
        if options.autoWhiteBalance {
            var sumR = 0.0, sumG = 0.0, sumB = 0.0, cnt = 0.0
            for i in 0..<(midW * midH) {
                let off = i * 4
                guard midBuf[off + 3] >= 128 else { continue }
                sumR += Double(midBuf[off]); sumG += Double(midBuf[off + 1]); sumB += Double(midBuf[off + 2])
                cnt += 1
            }
            if cnt > 32 {
                let mR = sumR / cnt, mG = sumG / cnt, mB = sumB / cnt
                let mean = (mR + mG + mB) / 3
                if mean > 1, mR > 1, mG > 1, mB > 1 {
                    let strength = 0.8
                    func gain(_ m: Double) -> Double {
                        let g = (mean / m) * strength + (1 - strength)
                        return min(1.35, max(0.75, g))
                    }
                    let gR = gain(mR), gG = gain(mG), gB = gain(mB)
                    // 增益偏离 1 极小则跳过，省掉一次全图遍历
                    if abs(gR - 1) > 0.01 || abs(gG - 1) > 0.01 || abs(gB - 1) > 0.01 {
                        var lutR = [UInt8](repeating: 0, count: 256)
                        var lutG = [UInt8](repeating: 0, count: 256)
                        var lutB = [UInt8](repeating: 0, count: 256)
                        for v in 0...255 {
                            lutR[v] = UInt8(min(255, max(0, Double(v) * gR)).rounded())
                            lutG[v] = UInt8(min(255, max(0, Double(v) * gG)).rounded())
                            lutB[v] = UInt8(min(255, max(0, Double(v) * gB)).rounded())
                        }
                        for i in 0..<(midW * midH) {
                            let off = i * 4
                            guard midBuf[off + 3] > 0 else { continue }
                            midBuf[off] = lutR[Int(midBuf[off])]
                            midBuf[off + 1] = lutG[Int(midBuf[off + 1])]
                            midBuf[off + 2] = lutB[Int(midBuf[off + 2])]
                        }
                    }
                }
            }
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
        let palLab: [(id: Int, lab: LabColor)] =
            (pal ?? BeadPalette.all).map { c in
                (c.id, ColorScience.lab(r8: Double(c.r), g8: Double(c.g), b8: Double(c.b)))
            }
        var labById: [Int: LabColor] = [:]
        labById.reserveCapacity(palLab.count)
        for p in palLab { labById[p.id] = p.lab }

        // ---- 分块平均 + 匹配 ----
        var cells = [Int](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            // 目标行在中间图上的覆盖区间（浮点，四舍五入边界）
            let y0 = Int((Double(gy) * Double(midH) / Double(gh)).rounded(.down))
            let y1 = max(y0 + 1, Int((Double(gy + 1) * Double(midH) / Double(gh)).rounded(.down)))
            for gx in 0..<gw {
                let x0 = Int((Double(gx) * Double(midW) / Double(gw)).rounded(.down))
                let x1 = max(x0 + 1, Int((Double(gx + 1) * Double(midW) / Double(gw)).rounded(.down)))

                // ---- 块内抗混色采样：按亮度截尾均值（剔除最亮/最暗各 25%）----
                //
                // 直接平均会被边缘像素与高光/阴影污染：例如黑色描边渗进浅色区、
                // 反光把颜色拉白、阴影把颜色压黑——这是"颜色识别不准"的常见来源。
                // 先按亮度排序、剔除两端各 25% 再平均，抗污染且不丢主色调。
                var samples: [(luma: Double, r: Double, g: Double, b: Double, w: Double)] = []
                samples.reserveCapacity(max(1, (y1 - y0) * (x1 - x0)))
                for y in y0..<min(y1, midH) {
                    for x in x0..<min(x1, midW) {
                        let off = (y * midW + x) * 4
                        let a = Double(midBuf[off + 3])
                        guard a > 0 else { continue }
                        // 亮度校正（0-255 内 clamp）
                        let r = clamp255((Double(midBuf[off]) - lo) * 255.0 / range)
                        let g = clamp255((Double(midBuf[off + 1]) - lo) * 255.0 / range)
                        let b = clamp255((Double(midBuf[off + 2]) - lo) * 255.0 / range)
                        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        samples.append((luma, r, g, b, a / 255.0))
                    }
                }
                guard !samples.isEmpty else { continue }
                var alphaSum = 0.0
                for smp in samples { alphaSum += smp.w }
                if alphaSum / Double(samples.count) < 0.5 { continue }   // 透明为主 → 空格

                samples.sort { $0.luma < $1.luma }
                let cut = samples.count >= 8 ? samples.count / 4 : 0
                let startIdx = cut
                let endIdx = max(startIdx + 1, samples.count - cut)

                var sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0
                for i in startIdx..<endIdx {
                    let smp = samples[i]
                    sr += srgbToLinear(smp.r / 255.0) * smp.w
                    sg += srgbToLinear(smp.g / 255.0) * smp.w
                    sb += srgbToLinear(smp.b / 255.0) * smp.w
                    sa += smp.w
                }
                guard sa > 0 else { continue }

                // linear 平均 → 压回 sRGB
                let r8 = linearToSrgb(sr / sa) * 255.0
                let g8 = linearToSrgb(sg / sa) * 255.0
                let b8 = linearToSrgb(sb / sa) * 255.0

                // 白底转空（用平均后的实际像素值，阈值略收紧避免误删浅色主体）
                if options.whiteToEmpty && r8 > 240 && g8 > 240 && b8 > 240 { continue }

                // ---- 匹配：粗筛（彩度加权 ΔE76 取前 3）→ 精筛（CIEDE2000）----
                //
                // 全量 ΔE00 匹配每格要算 295 次三角/幂运算（上万格就明显卡顿）；
                // 先用廉价距离取前 3 名、再对这 3 个算 ΔE00——两者排序高度一致，
                // 结果与全量 ΔE00 等价，但每格只需 3 次 ΔE00。
                let lab = ColorScience.lab(r8: r8, g8: g8, b8: b8)
                var f1 = Double.greatestFiniteMagnitude, i1 = palLab[0].id
                var f2 = Double.greatestFiniteMagnitude, i2 = i1
                var f3 = Double.greatestFiniteMagnitude, i3 = i1
                for p in palLab {
                    let d = ColorScience.deltaEFilter(lab, p.lab)
                    if d < f1 {
                        i3 = i2; f3 = f2
                        i2 = i1; f2 = f1
                        i1 = p.id; f1 = d
                    } else if d < f2 {
                        i3 = i2; f3 = f2
                        i2 = p.id; f2 = d
                    } else if d < f3 {
                        i3 = p.id; f3 = d
                    }
                }
                var bestId = i1
                var bestDist = Double.greatestFiniteMagnitude
                for cid in [i1, i2, i3] {
                    guard let pl = labById[cid] else { continue }
                    let d = ColorScience.deltaE2000(lab, pl)
                    if d < bestDist { bestDist = d; bestId = cid }
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

    /// 最近色号匹配：彩度加权粗筛取前 3 → CIEDE2000 精筛（palette 为 nil 时用全 295 色）
    static func nearestColorId(r: UInt8, g: UInt8, b: UInt8, palette: [BeadColor]?) -> Int {
        let cand = (palette ?? BeadPalette.all).map { c in
            (id: c.id, lab: ColorScience.lab(r8: Double(c.r), g8: Double(c.g), b8: Double(c.b)))
        }
        guard !cand.isEmpty else { return 0 }
        let lab0 = ColorScience.lab(r8: Double(r), g8: Double(g), b8: Double(b))

        var f1 = Double.greatestFiniteMagnitude, i1 = cand[0].id
        var f2 = Double.greatestFiniteMagnitude, i2 = i1
        var f3 = Double.greatestFiniteMagnitude, i3 = i1
        for p in cand {
            let d = ColorScience.deltaEFilter(lab0, p.lab)
            if d < f1 {
                i3 = i2; f3 = f2; i2 = i1; f2 = f1; i1 = p.id; f1 = d
            } else if d < f2 {
                i3 = i2; f3 = f2; i2 = p.id; f2 = d
            } else if d < f3 {
                i3 = p.id; f3 = d
            }
        }
        var bestId = i1
        var bestDist = Double.greatestFiniteMagnitude
        for cid in [i1, i2, i3] {
            guard let p = cand.first(where: { $0.id == cid }) else { continue }
            let d = ColorScience.deltaE2000(lab0, p.lab)
            if d < bestDist { bestDist = d; bestId = cid }
        }
        return bestId
    }

    // MARK: - 限色

    /// 限色收敛：以「视觉损失最小」为准合并颜色，直到颜色数 <= limit。
    ///
    /// 与旧版（只砍"用量最少"的颜色）的区别：
    /// - 合并代价 = **频次 × (1 + ΔE00)**：既要数量少，也要颜色接近；
    ///   不会为了凑数把一块显眼的少量色硬并到远处色号上（旧版常见"大面积错色"）；
    /// - 距离用 CIEDE2000（感知一致），且对每个色号预计算前 8 个近邻（一次 O(k²)），
    ///   合并循环里只查缓存，整轮开销远低于每轮重算全对距离。
    static func limitColors(_ cells: [Int], limit: Int) -> [Int] {
        var counts: [Int: Int] = [:]
        for c in cells where c > 0 { counts[c, default: 0] += 1 }
        guard counts.count > limit else { return cells }

        // Lab 缓存
        var labs: [Int: LabColor] = [:]
        labs.reserveCapacity(counts.count)
        for id in counts.keys {
            guard let c = BeadPalette.byId[id] else { continue }
            labs[id] = ColorScience.lab(r8: Double(c.r), g8: Double(c.g), b8: Double(c.b))
        }

        // 预计算近邻表（ΔE00 升序取前 8）：只在开始时算一次
        let ids = Array(counts.keys)
        var neighbors: [Int: [(id: Int, d: Double)]] = [:]
        neighbors.reserveCapacity(ids.count)
        for id in ids {
            guard let l0 = labs[id] else { continue }
            var list: [(id: Int, d: Double)] = []
            list.reserveCapacity(ids.count - 1)
            for oid in ids where oid != id {
                guard let l1 = labs[oid] else { continue }
                list.append((oid, ColorScience.deltaE2000(l0, l1)))
            }
            list.sort { $0.d < $1.d }
            neighbors[id] = Array(list.prefix(8))
        }

        var mapping: [Int: Int] = [:]   // 被合并色 → 目标色
        var active = counts

        while active.count > limit {
            var bestFrom = -1
            var bestTo = -1
            var bestCost = Double.greatestFiniteMagnitude

            for (id, count) in active {
                guard let cands = neighbors[id] else { continue }
                // 取最近的"仍然存活"的色号
                var target = -1
                var dist = Double.greatestFiniteMagnitude
                for cand in cands where cand.id != id {
                    if active[cand.id] != nil {
                        target = cand.id
                        dist = cand.d
                        break
                    }
                }
                guard target >= 0, dist.isFinite else { continue }
                let cost = Double(count) * (1 + dist)
                if cost < bestCost {
                    bestCost = cost
                    bestFrom = id
                    bestTo = target
                }
            }

            guard bestFrom >= 0, bestTo >= 0 else { break }
            mapping[bestFrom] = bestTo
            active[bestTo, default: 0] += active[bestFrom] ?? 0
            active.removeValue(forKey: bestFrom)
        }

        // 链式映射收敛（A→B→C 需压成 A→C）
        func resolve(_ id: Int) -> Int {
            var cur = id
            var guardCount = 0
            while let next = mapping[cur], guardCount < 64 {
                cur = next
                guardCount += 1
            }
            return cur
        }
        return cells.map { $0 > 0 ? resolve($0) : $0 }
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

    // 说明：sRGB → CIE Lab 与色差（ΔE76 / CIEDE2000）已统一到 `ColorScience`，
    // 避免两处实现漂移（旧版本地 lab() 使用的 0.008856 阈值已被 ColorScience 的
    // 216/24389 精确阈值取代）。
    private static func clamp255(_ v: Double) -> Double { min(255, max(0, v)) }
}
