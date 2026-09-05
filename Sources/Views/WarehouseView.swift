import SwiftData
import SwiftUI

// MARK: - 豆仓标签页：库存管理（手动入库 / 按图纸入库 / 按图纸扣减 / 补货清单）

struct WarehouseView: View {
    var body: some View {
        NavigationStack {
            WarehousePanel()
                .navigationTitle("豆仓")
        }
    }
}

private struct WarehousePanel: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BeadStock.colorId, order: .forward) private var stocks: [BeadStock]
    @Query(sort: \Pattern.updatedAt, order: .reverse) private var patterns: [Pattern]

    @State private var showManualStockIn = false
    @State private var showPatternPicker = false
    @State private var showGapsResult = false
    @State private var gapTarget: Pattern?
    @State private var editingStock: BeadStock?
    @State private var actionMode: StockAction = .stockIn
    @State private var deductTarget: Pattern?
    @State private var showDeductConfirm = false
    @State private var toast: String?

    enum StockAction: String {
        case stockIn = "入库"
        case deduct = "扣减"
        case replenish = "补货清单"
    }

    var body: some View {
        List {
            summarySection
            actionSection
            stockListSection
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        self.toast = nil
                    }
            }
        }
        .sheet(isPresented: $showManualStockIn) {
            ManualStockInView()
        }
        .sheet(isPresented: $showPatternPicker) {
            PatternPickerSheet(patterns: patterns) { p in
                showPatternPicker = false
                handlePick(p)
            }
        }
        .sheet(isPresented: $showGapsResult) {
            if let gapTarget {
                GapsSheet(pattern: gapTarget)
            }
        }
        .sheet(item: $editingStock) { s in
            StockAdjustSheet(stock: s)
        }
        .confirmationDialog("按图纸扣减库存？", isPresented: $showDeductConfirm, titleVisibility: .visible) {
            Button("扣减", role: .destructive) {
                if let p = deductTarget {
                    StockStore.deduct(pattern: p, context: context)
                    toast = "已按「\(p.name)」需求扣减库存"
                }
                deductTarget = nil
            }
            Button("取消", role: .cancel) { deductTarget = nil }
        } message: {
            if let p = deductTarget {
                Text("将按「\(p.name)」的豆子用量从豆仓扣减（下限 0）。")
            }
        }
    }

    // MARK: - 概览

    private var totalStock: Int { stocks.reduce(0) { $0 + $1.count } }

    private var summarySection: some View {
        Section {
            HStack(spacing: 20) {
                stat("色号", "\(stocks.count)")
                stat("颗粒", "\(totalStock)")
                stat("图纸", "\(patterns.count)")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            Button {
                showManualStockIn = true
            } label: {
                Label("手动入库", systemImage: "plus.circle.fill")
            }

            Button {
                actionMode = .stockIn
                showPatternPicker = true
            } label: {
                Label("按图纸入库", systemImage: "tray.and.arrow.down.fill")
            }
            .disabled(patterns.isEmpty)

            Button {
                actionMode = .deduct
                showPatternPicker = true
            } label: {
                Label("按图纸扣减", systemImage: "tray.and.arrow.up.fill")
            }
            .disabled(patterns.isEmpty)

            Button {
                actionMode = .replenish
                showPatternPicker = true
            } label: {
                Label("生成补货清单", systemImage: "cart.fill.badge.plus")
            }
            .disabled(patterns.isEmpty)
        } header: {
            Text("入库 / 扣减")
        } footer: {
            Text("按图纸入库：把买好的豆子按图纸需求量补足登记；拼完作品后用「按图纸扣减」把用掉的豆子从豆仓里减掉。")
        }
    }

    private func handlePick(_ pattern: Pattern) {
        switch actionMode {
        case .stockIn:
            StockStore.stockIn(pattern: pattern, context: context)
            toast = "已按「\(pattern.name)」需求入库"
        case .deduct:
            deductTarget = pattern
            showDeductConfirm = true
        case .replenish:
            gapTarget = pattern
            showGapsResult = true
        }
    }

    // MARK: - 库存明细

    private var stockListSection: some View {
        Section {
            if stocks.isEmpty {
                ContentUnavailableView {
                    Label("豆仓还是空的", systemImage: "shippingbox")
                } description: {
                    Text("先入库：可以按图纸需求一键登记，也可以手动选色号入库。")
                }
                .frame(maxHeight: 220)
            } else {
                ForEach(stocks) { s in
                    if let c = BeadPalette.byId[s.colorId] {
                        Button {
                            editingStock = s
                        } label: {
                            stockRow(c, s.count)
                        }
                        .tint(.primary)
                    }
                }
                .onDelete(perform: removeStocks)
            }
        } header: {
            HStack {
                Text("库存明细")
                Spacer()
                Text("共 \(totalStock) 颗")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("点击行可调整数量；左滑删除该色号记录。")
        }
    }

    private func stockRow(_ c: BeadColor, _ count: Int) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5)
                .fill(c.color)
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.3)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Mard \(c.mard)").font(.subheadline.weight(.medium))
                Text("可可 \(c.coco) · 漫漫 \(c.manman) · 盼盼 \(c.panpan) · 米小窝 \(c.mixiaowo)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(count)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.pink)
            Text("颗").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func removeStocks(at offsets: IndexSet) {
        for i in offsets { context.delete(stocks[i]) }
        try? context.save()
    }
}

// MARK: - 图纸选择器（入库 / 扣减 / 补货共用）

private struct PatternPickerSheet: View {
    let patterns: [Pattern]
    let onPick: (Pattern) -> Void

    var body: some View {
        NavigationStack {
            List(patterns) { p in
                Button {
                    onPick(p)
                } label: {
                    PatternRow(pattern: p)
                }
                .tint(.primary)
            }
            .navigationTitle("选择图纸")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if patterns.isEmpty {
                    ContentUnavailableView("暂无图纸", systemImage: "square.grid.3x3")
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - 手动入库：选色号 → 填数量

private struct ManualStockInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var pickedColor: BeadColor?

    var filtered: [BeadColor] {
        guard !search.isEmpty else { return BeadPalette.all }
        let q = search.uppercased()
        return BeadPalette.all.filter {
            $0.mard.uppercased().contains(q) || $0.coco.uppercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { c in
                Button {
                    pickedColor = c
                } label: {
                    colorRow(c)
                }
                .tint(.primary)
            }
            .searchable(text: $search, prompt: "搜 Mard / 可可色号")
            .navigationTitle("选择色号")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $pickedColor) { c in
                ManualStockInDetail(color: c, onDone: { dismiss() })
            }
        }
    }

    private func colorRow(_ c: BeadColor) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5)
                .fill(c.color)
                .frame(width: 30, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.3)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Mard \(c.mard)").font(.subheadline.weight(.medium))
                Text("可可 \(c.coco) · 漫漫 \(c.manman) · 盼盼 \(c.panpan) · 米小窝 \(c.mixiaowo)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "plus.circle")
                .font(.caption)
                .foregroundStyle(.pink)
        }
    }
}

private struct ManualStockInDetail: View {
    @Environment(\.modelContext) private var context
    let color: BeadColor
    var onDone: () -> Void

    @State private var countText = "100"
    @State private var currentStock = 0

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.color)
                        .frame(width: 52, height: 52)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.3)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mard \(color.mard)").font(.title3.bold())
                        Text("可可 \(color.coco) · 漫漫 \(color.manman) · 盼盼 \(color.panpan) · 米小窝 \(color.mixiaowo)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(currentStock)").font(.headline.monospacedDigit())
                        Text("现有").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Section("入库数量") {
                TextField("数量", text: $countText)
                    .keyboardType(.numberPad)
                    .font(.title2.monospacedDigit())
                HStack(spacing: 8) {
                    quickSet("50")
                    quickSet("100")
                    quickSet("500")
                    quickSet("1000")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Section {
                Button {
                    let n = Int(countText) ?? 0
                    guard n > 0 else { return }
                    StockStore.adjust(colorId: color.id, delta: n, context: context)
                    onDone()
                } label: {
                    Label("入库 \(countText.isEmpty ? "" : countText) 颗", systemImage: "tray.and.arrow.down.fill")
                        .font(.headline)
                }
            }
        }
        .navigationTitle("手动入库")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            currentStock = StockStore.stock(colorId: color.id, context: context)
        }
    }

    private func quickSet(_ v: String) -> some View {
        Button(v) { countText = v }
    }
}

// MARK: - 库存数量调整

private struct StockAdjustSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var stock: BeadStock

    @State private var countText = ""

    var color: BeadColor? { BeadPalette.byId[stock.colorId] }

    var body: some View {
        NavigationStack {
            Form {
                if let c = color {
                    Section {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(c.color)
                                .frame(width: 52, height: 52)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.3)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Mard \(c.mard)").font(.title3.bold())
                                Text("可可 \(c.coco) · 漫漫 \(c.manman) · 盼盼 \(c.panpan) · 米小窝 \(c.mixiaowo)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }

                Section("当前库存") {
                    Text("\(stock.count)")
                        .font(.title.monospacedDigit().bold())
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Section("快速增减") {
                    HStack(spacing: 8) {
                        quickAdjust("−100", -100)
                        quickAdjust("−10", -10)
                        quickAdjust("+10", 10)
                        quickAdjust("+100", 100)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Section("设为精确数量") {
                    TextField("数量", text: $countText)
                        .keyboardType(.numberPad)
                        .font(.title3.monospacedDigit())
                    Button {
                        let n = Int(countText) ?? -1
                        guard n >= 0 else { return }
                        StockStore.setCount(colorId: stock.colorId, count: n, context: context)
                        dismiss()
                    } label: {
                        Label("保存", systemImage: "checkmark.circle.fill")
                    }
                    .disabled(Int(countText) == nil)
                }
            }
            .navigationTitle("调整库存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func quickAdjust(_ label: String, _ delta: Int) -> some View {
        Button(label) {
            StockStore.adjust(colorId: stock.colorId, delta: delta, context: context)
        }
    }
}

// MARK: - 补货清单结果

private struct GapsSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let pattern: Pattern

    var gaps: [StockGap] { StockStore.gaps(pattern: pattern, context: context) }
    var totalMissing: Int { gaps.reduce(0) { $0 + $1.missing } }

    var body: some View {
        NavigationStack {
            List {
                if gaps.isEmpty {
                    ContentUnavailableView {
                        Label("库存充足", systemImage: "checkmark.seal.fill")
                    } description: {
                        Text("「\(pattern.name)」所需的所有色号库存都够，不用补货。")
                    }
                } else {
                    Section {
                        ForEach(gaps) { g in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(g.color.color)
                                    .frame(width: 34, height: 34)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.3)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mard \(g.color.mard)").font(.subheadline.weight(.medium))
                                    Text("可可 \(g.color.coco) · 漫漫 \(g.color.manman)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("缺 \(g.missing)")
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(.red)
                                    Text("需求 \(g.needed) · 库存 \(g.stock)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("共缺 \(gaps.count) 种颜色，\(totalMissing) 颗")
                    } footer: {
                        Text("点右上角复制，发给店家即可按单补货。")
                    }
                }
            }
            .navigationTitle("补货清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = StockStore.gapsText(pattern: pattern, context: context)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
