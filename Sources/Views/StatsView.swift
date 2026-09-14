import SwiftData
import SwiftUI

// MARK: - 数据中心（对标 AI豆仓「记录与数据统计」）

/// 全局数据统计页：全部指标由现有数据**派生**（图纸 cells 聚合 + 库存对比），
/// 不新增任何数据模型、不写流水记录，零迁移成本。
///
/// 模块：
/// 1. 总览英雄卡（图纸数 / 累计颗数 / 已完成 / 已录入色号）
/// 2. 补豆清单（全部图纸需求 vs 库存，输出「需 / 有 / 缺」+ 一键复制）
/// 3. 消耗排行 Top 15（聚合所有图纸用色，"哪些色号用得最快"）
/// 4. 库存色系分布（按 Mard 系列首字母的水平条）
/// 5. 最近完成的作品（横滚卡）
@MainActor
struct StatsView: View {
    @Query(sort: \Pattern.updatedAt, order: .reverse) private var patterns: [Pattern]
    @Query private var stocks: [BeadStock]

    /// 复制反馈 toast
    @State private var toast: String?

    // MARK: - 派生数据（聚合）

    /// 聚合所有图纸的色号用量，降序
    private var aggregatedUsage: [(color: BeadColor, count: Int)] {
        var dict: [Int: Int] = [:]
        for p in patterns {
            for c in p.cells where c > 0 { dict[c, default: 0] += 1 }
        }
        return dict.compactMap { id, n in BeadPalette.byId[id].map { ($0, n) } }
            .sorted { $0.count > $1.count }
    }

    /// 所有图纸累计颗数
    private var totalBeads: Int { patterns.reduce(0) { $0 + $1.totalBeads } }

    private var donePatterns: [Pattern] {
        patterns
            .filter { $0.status == .done }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// 补豆清单行：聚合需求 vs 库存
    struct RestockRow: Identifiable {
        let id: Int
        let color: BeadColor
        let need: Int
        let have: Int
        var shortage: Int { max(0, need - have) }
    }

    /// 全部图纸聚合需求 vs 库存 → 缺色行（按缺口降序）
    private var restockRows: [RestockRow] {
        var needMap: [Int: Int] = [:]
        for p in patterns {
            for c in p.cells where c > 0 { needMap[c, default: 0] += 1 }
        }
        var haveMap: [Int: Int] = [:]
        for s in stocks where s.colorId > 0 { haveMap[s.colorId, default: 0] += s.quantity }
        return needMap.compactMap { id, need -> RestockRow? in
            guard let color = BeadPalette.byId[id] else { return nil }
            return RestockRow(id: id, color: color, need: need, have: haveMap[id] ?? 0)
        }
        .filter { $0.shortage > 0 }
        .sorted { $0.shortage > $1.shortage }
    }

    /// 总缺口颗数
    private var totalShortage: Int { restockRows.reduce(0) { $0 + $1.shortage } }

    /// 库存色系分布：Mard 首字母 → 豆量
    struct SeriesRow: Identifiable {
        let id: String
        let total: Int
        let colors: Int
    }

    private var seriesDistribution: [SeriesRow] {
        var map: [String: (total: Int, colors: Int)] = [:]
        for s in stocks {
            guard let mard = s.color?.mard, let letter = mard.first else { continue }
            let key = String(letter)
            let cur = map[key] ?? (0, 0)
            map[key] = (cur.total + s.quantity, cur.colors + 1)
        }
        return map.sorted { $0.value.total > $1.value.total }
            .map { SeriesRow(id: $0.key, total: $0.value.total, colors: $0.value.colors) }
    }

    /// 色系分布最大值（条形归一化用）
    private var seriesMax: Int { seriesDistribution.map { $0.total }.max() ?? 1 }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                heroCard
                restockCard
                rankingCard
                seriesCard
                if !donePatterns.isEmpty { recentCard }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Theme.pageFill)
        .navigationTitle("数据中心")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        self.toast = nil
                    }
            }
        }
    }

    // MARK: 总览英雄卡

    private var heroCard: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.brand)
            BeadDots()
                .padding(.top, 18).padding(.trailing, 20)
            VStack(alignment: .leading, spacing: 14) {
                Label("创作总览", systemImage: "chart.pie.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 0) {
                    heroStat("\(patterns.count)", "图纸")
                    heroStat("\(totalBeads)", "累计颗数")
                    heroStat("\(donePatterns.count)", "已完成")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 140)
        .shadow(color: Theme.accent.opacity(0.25), radius: 12, y: 5)
    }

    private func heroStat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 补豆清单（AI豆仓：数据驱动的补货决策）

    private var restockCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("补豆清单", systemImage: "cart.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                if !restockRows.isEmpty {
                    Button {
                        copyRestockList()
                    } label: {
                        Label("复制清单", systemImage: "doc.on.doc")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.brand, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if restockRows.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    Text("库存充足，暂时不需要补豆")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
                Text("缺 \(restockRows.count) 种色号 · 共 \(totalShortage) 颗（按全部图纸需求汇总）")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(restockRows.prefix(12)) { row in
                    HStack(spacing: 10) {
                        BeadDot(color: row.color, size: 22)
                        Text(row.color.mard)
                            .font(.caption.monospaced().weight(.semibold))
                            .frame(minWidth: 34, alignment: .leading)
                        Text("需\(row.need) · 有\(row.have)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("缺 \(row.shortage)")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color(red: 1.0, green: 0.42, blue: 0.34), in: Capsule())
                    }
                    .padding(.vertical, 2)
                }
                if restockRows.count > 12 {
                    Text("还有 \(restockRows.count - 12) 种缺口，点「复制清单」查看全部")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .cardStyle()
    }

    /// 复制补豆清单文本（沿用消耗预估清单格式）
    private func copyRestockList() {
        var lines = ["【豆绘小栈】补豆清单（全部图纸汇总）"]
        for row in restockRows {
            lines.append("\(row.color.mard)  需\(row.need) 有\(row.have) 缺\(row.shortage)")
        }
        lines.append("共 \(restockRows.count) 种色号，缺 \(totalShortage) 颗")
        UIPasteboard.general.string = lines.joined(separator: "\n")
        toast = "补豆清单已复制"
    }

    // MARK: 消耗排行 Top 15（AI豆仓：消耗排行，看清哪些色号用得最快）

    private var rankingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("消耗排行", systemImage: "flame.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            if aggregatedUsage.isEmpty {
                Text("还没有图纸用量数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                let top = Array(aggregatedUsage.prefix(15))
                let maxCount = top.first?.count ?? 1
                ForEach(top.indices, id: \.self) { idx in
                    let item = top[idx]
                    HStack(spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(idx < 3 ? .white : .secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                idx < 3 ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(Color.secondary.opacity(0.12)),
                                in: Circle()
                            )
                        BeadDot(color: item.color, size: 20)
                        Text(item.color.mard)
                            .font(.caption.monospaced().weight(.semibold))
                            .frame(minWidth: 34, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.10))
                                Capsule()
                                    .fill(LinearGradient(
                                        colors: [item.color.color.opacity(0.75), item.color.color],
                                        startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, geo.size.width * CGFloat(item.count) / CGFloat(maxCount)))
                            }
                        }
                        .frame(height: 10)
                        Text("\(item.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .cardStyle()
    }

    // MARK: 库存色系分布

    private var seriesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("库存色系分布", systemImage: "paintpalette.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            if seriesDistribution.isEmpty {
                Text("还没有库存数据，去「库存」Tab 录入")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(seriesDistribution) { item in
                    HStack(spacing: 10) {
                        Text(item.id)
                            .font(.caption.bold())
                            .frame(width: 22, height: 22)
                            .background(Theme.mint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(.white)
                        GeometryReader { geo in
                            Capsule()
                                .fill(Theme.mint)
                                .frame(width: max(6, geo.size.width * CGFloat(item.total) / CGFloat(max(seriesMax, 1))))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Capsule().fill(Color.secondary.opacity(0.10)), alignment: .leading)
                        }
                        .frame(height: 10)
                        Text("\(item.total)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 40, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .cardStyle()
    }

    // MARK: 最近完成

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("最近完成", systemImage: "party.popper.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(donePatterns.prefix(10)) { p in
                        NavigationLink {
                            WorkDetailView(pattern: p)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(uiImage: p.thumbnailImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 84)
                                    .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(p.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if let date = p.completedAt {
                                    Text(date.formatted(.dateTime.month().day()))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .frame(width: 120)
                            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }
}

// MARK: - 豆子圆点（带高光的立体豆，对标 AI豆仓 / PIXDOU 的色块观感）

/// 单颗拼豆：圆点 + 顶部高光 + 细描边，任何底色上都立体可见。
struct BeadDot: View {
    let color: BeadColor
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(color.color)
            .frame(width: size, height: size)
            .overlay(
                // 顶部高光：白色径向渐变小椭圆
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.62, height: size * 0.38)
                    .offset(y: -size * 0.18)
            )
            .overlay(Circle().stroke(.black.opacity(0.10), lineWidth: 0.5))
    }
}
