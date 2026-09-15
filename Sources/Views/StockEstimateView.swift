import SwiftData
import SwiftUI

/// 消耗预估页面（PRD §5.2）
///
/// 入口：图纸详情 → 菜单「消耗预估」。
/// 展示：顶部汇总（总需豆量 / 库存总豆量 / 缺色种数）+ 三列明细（色号 | 需要 | 现有 | 差额）
///      + 缺色清单（一键复制）。
@MainActor
struct StockEstimateView: View {
    /// 目标图纸
    let pattern: Pattern
    @Environment(\.modelContext) private var context
    @Query(sort: \BeadStock.colorId) private var stocks: [BeadStock]

    /// 提示 toast
    @State private var toast: String?

    /// 预估结果（随库存变化重算）
    private var estimate: StockEstimate {
        StockEstimator.estimate(pattern: pattern, stocks: stocks)
    }

    var body: some View {
        List {
            if stocks.isEmpty {
                emptyStockSection
            } else {
                summarySection
                detailSection
                missingSection
                consumeSection
            }
        }
        .navigationTitle(L10n.s("消耗预估"))
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

    // MARK: - 空库存引导

    private var emptyStockSection: some View {
        Section {
            ContentUnavailableView {
                Label(L10n.s("还没有库存数据"), systemImage: "shippingbox")
            } description: {
                Text(L10n.s("先到「库存」标签录入色号数量，再回来查看这张图纸的缺色情况。"))
            } actions: {
                NavigationLink {
                    InventoryView()
                } label: {
                    Label(L10n.s("去录入库存"), systemImage: "square.stack.3d.up.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
            }
            .frame(maxHeight: 300)
        }
    }

    // MARK: - 顶部汇总

    private var summarySection: some View {
        Section(L10n.k(L10n.s("汇总"))) {
            HStack(spacing: 20) {
                summaryCell(L10n.s("总需豆量"), "\(estimate.totalNeed)")
                summaryCell(L10n.s("库存总豆量"), "\(estimate.totalHave)")
                summaryCell(L10n.s("缺色种数"), "\(estimate.shortCount)",
                            highlight: estimate.hasShortage)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func summaryCell(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(highlight ? .red : .primary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 明细三列

    private var detailSection: some View {
        Section {
            ForEach(estimate.rows) { row in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(row.color.color)
                        .frame(width: 28, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.3)))
                    Text(row.color.mard)
                        .font(.subheadline.monospaced().weight(.medium))
                        .frame(width: 52, alignment: .leading)
                    Spacer()
                    Text("\(row.need)")
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 46, alignment: .trailing)
                    Text("\(row.have)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                    Text(row.diff >= 0 ? "+\(row.diff)" : "\(row.diff)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(row.diff < 0 ? .red : .green)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        } header: {
            HStack {
                Text(L10n.s("明细"))
                Spacer()
                Text(L10n.s("色号 · 需要 · 现有 · 差额")).font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Text(L10n.s("差额 = 现有 − 需要；负数（不够）标红，正数（富余）标绿。"))
        }
    }

    // MARK: - 缺色清单

    private var missingSection: some View {
        Section {
            if estimate.hasShortage {
                ForEach(estimate.shortRows) { row in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(row.color.color)
                            .frame(width: 26, height: 26)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.3)))
                        Text(row.color.mard)
                            .font(.subheadline.monospaced().weight(.medium))
                        Spacer()
                        Text(L10n.p("缺 {0}", "\(row.shortage)"))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                Button {
                    UIPasteboard.general.string = StockEstimator.missingListText(estimate)
                    toast = L10n.s("缺色清单已复制")
                } label: {
                    Label(L10n.s("一键复制缺色清单"), systemImage: "doc.on.doc")
                }
            } else {
                Label(L10n.s("库存充足，无缺色 🎉"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        } header: {
            Text(L10n.s("缺色清单"))
        } footer: {
            Text(L10n.s("只列出不够的色号及缺口，可复制后发给卖家补豆。"))
        }
    }

    // MARK: - 便利扣减（次要动作，不写流水）

    private var consumeSection: some View {
        Section {
            Button(role: .destructive) {
                consume()
            } label: {
                Label(L10n.s("按本图纸用量扣减库存（便利）"), systemImage: "minus.circle")
            }
            .disabled(estimate.rows.isEmpty)
        } footer: {
            Text(L10n.s("仅按图纸用量一次性扣减已存在的色号；不记录出入库流水，扣减后可在库存页手动修正。"))
        }
    }

    private func consume() {
        var mutable: [BeadStock] = stocks
        let deducted = StockEstimator.consumeOnce(pattern: pattern, stocks: &mutable)
        // BeadStock 为 @Model 引用类型，`consumeOnce` 的原地修改已直接生效，这里只需保存
        try? context.save()
        toast = L10n.p("已按用量扣减 {0} 个色号", "\(deducted.count)")
    }
}
