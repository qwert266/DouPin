import SwiftData
import SwiftUI

/// 库存 Tab 主页面（PRD §3.1 / §4.1）
///
/// 功能：
/// - 顶部搜索栏：按色号（Mard/可可/漫漫…）模糊匹配 + 色系首字母筛选；
/// - 列表：色块 + 色号 + 数量 + 缺色标识（`isLow` 时标红）；
/// - 排列：按 Mard 系列顺序（A→B→C…→Z）；
/// - 右上角「+」菜单：逐条添加 / 批量导入；
/// - 行编辑：点按编辑数量、滑动删除；
/// - 底部：库存总览（已录入色号数 / 总豆量）；
/// - 空状态：`ContentUnavailableView` 引导录入。
@MainActor
struct InventoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BeadStock.colorId) private var stocks: [BeadStock]

    /// 批量导入 Sheet 展示开关
    @State private var showImport = false
    /// 逐条添加 Sheet 展示开关
    @State private var showAdd = false
    /// 编辑中的库存条目
    @State private var editing: BeadStock?
    /// 待删除的库存条目（用于二次确认）
    @State private var pendingDelete: BeadStock?
    /// 搜索文本
    @State private var searchText = ""
    /// 色系筛选（空 = 全部）
    @State private var seriesFilter = ""
    /// 提示 toast
    @State private var toast: String?

    /// 全部色系首字母（A…Z，按现有数据出现的系列生成）
    private var allSeries: [String] {
        BeadPalette.groups.map { $0.letter }
    }

    /// 经过搜索 + 系列筛选后、按 Mard 顺序排列的库存
    private var filteredStocks: [BeadStock] {
        // 先按 colorId 映射到 BeadColor，保证 Mard 顺序
        var list = stocks.compactMap { s -> (stock: BeadStock, color: BeadColor)? in
            guard let c = BeadPalette.byId[s.colorId] else { return nil }
            return (s, c)
        }
        // 系列筛选
        if !seriesFilter.isEmpty {
            list = list.filter { String($0.color.mard.prefix(1)) == seriesFilter }
        }
        // 模糊匹配（Mard / 可可 / 漫漫 / 盼盼 / 米小窝）
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { entry in
                let c = entry.color
                return c.mard.lowercased().contains(q)
                    || c.coco.lowercased().contains(q)
                    || c.manman.lowercased().contains(q)
                    || c.panpan.lowercased().contains(q)
                    || c.mixiaowo.lowercased().contains(q)
            }
        }
        // 按 colorId（等价 Mard 顺序）升序
        return list.map { $0.stock }.sorted { $0.colorId < $1.colorId }
    }

    /// 总豆量（所有库存数量之和）
    private var totalQuantity: Int {
        stocks.reduce(0) { $0 + $1.quantity }
    }

    var body: some View {
        NavigationStack {
            Group {
                if stocks.isEmpty {
                    emptyState
                } else {
                    stockList
                }
            }
            .navigationTitle("库存")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    addMenu
                }
            }
            .searchable(text: $searchText, prompt: "搜索色号（Mard/可可/漫漫…）")
        }
        .sheet(isPresented: $showAdd) {
            StockQuickAddView { msg in toast = msg }
        }
        .sheet(isPresented: $showImport) {
            StockImportView { msg in toast = msg }
        }
        .sheet(item: $editing) { stock in
            StockQuantityEditSheet(stock: stock) { msg in toast = msg }
        }
        .confirmationDialog("删除该色号库存？",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let s = pendingDelete { delete(s) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { "将移除 \($0.displayName) 的库存记录" } ?? "")
        }
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

    // MARK: - 列表

    private var stockList: some View {
        List {
            // 渐变英雄统计条
            Section {
                inventoryHero
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // 色系筛选
            Section {
                seriesPicker
            }

            Section {
                ForEach(filteredStocks) { stock in
                    stockRow(stock)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = stock }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDelete = stock
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                editing = stock
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .cardRow()
                }
            } footer: {
                if filteredStocks.isEmpty {
                    Text("没有匹配的色号")
                }
            }
        }
        .themedListPage()
    }

    /// 顶部英雄统计：品牌渐变 + 豆点装饰 + 三栏数字
    private var inventoryHero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.brand)
            BeadDots()
                .padding(.top, 14).padding(.trailing, 16)
            HStack(spacing: 0) {
                heroCell("\(stocks.count)", "已录入色号")
                heroCell("\(totalQuantity)", "总豆量")
                heroCell("\(lowCount)", lowCount > 0 ? "缺色 ⚠︎" : "缺色")
            }
            .padding(.vertical, 16)
        }
        .frame(height: 84)
        .shadow(color: Theme.accent.opacity(0.22), radius: 10, y: 4)
    }

    /// 低于阈值的色号数
    private var lowCount: Int { stocks.filter { $0.isLow }.count }

    private func heroCell(_ value: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }

    /// 色系筛选（分段滚动）
    private var seriesPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "全部", active: seriesFilter.isEmpty) { seriesFilter = "" }
                ForEach(allSeries, id: \.self) { letter in
                    chip(title: letter, active: seriesFilter == letter) { seriesFilter = letter }
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(active ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(active ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.cardFill), in: Capsule())
                .foregroundStyle(active ? .white : Color.primary)
                .overlay(Capsule().stroke(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    /// 单行库存（立体小豆 + 数量胶囊，对标 AI豆仓 色号卡观感）
    private func stockRow(_ stock: BeadStock) -> some View {
        let color = BeadPalette.byId[stock.colorId]
        let low = stock.quantity == 0 || stock.isLow
        return HStack(spacing: 12) {
            Group {
                if let c = color {
                    BeadDot(color: c, size: 38)
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 38, height: 38)
                }
            }
            .shadow(color: .black.opacity(0.10), radius: 2, y: 1.5)

            VStack(alignment: .leading, spacing: 3) {
                Text("Mard \(stock.displayName)")
                    .font(.subheadline.monospaced().weight(.medium))
                if low {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(stock.quantity == 0 ? "缺色（库存为 0）" : "低于阈值 \(stock.threshold)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color(red: 1.00, green: 0.42, blue: 0.34), in: Capsule())
                } else {
                    Text("充足")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(stock.quantity)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(low ? Color(red: 1.00, green: 0.42, blue: 0.34) : .primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(
                    low ? AnyShapeStyle(Color(red: 1.00, green: 0.42, blue: 0.34).opacity(0.12))
                        : AnyShapeStyle(Theme.pageFill),
                    in: Capsule())
        }
        .opacity(stock.quantity == 0 ? 0.75 : 1)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        ContentUnavailableView {
            Label("库存还是空的", systemImage: "shippingbox")
        } description: {
            Text("可以先「逐条添加」几个常用色号，或把一段「色号 数量」文本「批量导入」。")
        } actions: {
            Button {
                showAdd = true
            } label: {
                Label("逐条添加", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)

            Button {
                showImport = true
            } label: {
                Label("批量导入", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 顶部「+」菜单

    private var addMenu: some View {
        Menu {
            Button {
                showAdd = true
            } label: {
                Label("逐条添加", systemImage: "plus.circle")
            }
            Button {
                showImport = true
            } label: {
                Label("批量导入", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
        }
    }

    // MARK: - 增删

    private func delete(_ stock: BeadStock) {
        context.delete(stock)
        try? context.save()
        toast = "已删除 \(stock.displayName)"
    }
}

// MARK: - 逐条添加 Sheet

/// 逐条添加库存：复用 `FullPaletteSheet` 选色号 → 输入数量 → 保存（可连续添加）
@MainActor
struct StockQuickAddView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BeadStock.colorId) private var stocks: [BeadStock]

    /// 保存成功回调（用于外层 toast）
    var onSaved: (String) -> Void = { _ in }

    @State private var selectedId: Int = 199
    @State private var quantityText = ""
    @State private var showPalette = false
    /// 本次会话已连续添加的条数
    @State private var addedCount = 0

    private var selectedColor: BeadColor? { BeadPalette.byId[selectedId] }
    private var quantity: Int { Int(quantityText.trimmingCharacters(in: .whitespaces)) ?? 0 }
    private var canSave: Bool { BeadPalette.byId[selectedId] != nil && quantity >= 0 && !quantityText.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("色号") {
                    Button {
                        showPalette = true
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedColor?.color ?? Color.gray.opacity(0.3))
                                .frame(width: 40, height: 40)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedColor.map { "Mard \($0.mard)" } ?? "点击选择色号")
                                    .font(.headline)
                                Text("从 295 色板中挑选")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("数量") {
                    TextField("例如 500", text: $quantityText)
                        .keyboardType(.numberPad)
                    if let c = selectedColor, let existing = existingStock(c.id) {
                        Text("该色号已有库存 \(existing.quantity) 颗（保存将累加）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if addedCount > 0 {
                    Section {
                        Label("本次已添加 \(addedCount) 条", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("逐条添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showPalette) {
                FullPaletteSheet(selectedId: $selectedId)
            }
        }
    }

    /// 查已存在的同色号库存
    private func existingStock(_ colorId: Int) -> BeadStock? {
        stocks.first { $0.colorId == colorId }
    }

    /// 保存（累加语义）；保存后清空数量，方便连续添加
    private func save() {
        guard canSave else { return }
        let isUpdate = existingStock(selectedId) != nil
        if let existing = existingStock(selectedId) {
            existing.addQuantity(quantity)
        } else {
            context.insert(BeadStock(colorId: selectedId, quantity: quantity))
        }
        try? context.save()
        addedCount += 1
        let mard = BeadPalette.byId[selectedId]?.mard ?? ""
        onSaved(isUpdate ? "已更新 \(mard)" : "已新增 \(mard)")
        quantityText = ""
    }
}

// MARK: - 库存数量编辑 Sheet

/// 编辑单个色号的数量（覆盖式）
@MainActor
struct StockQuantityEditSheet: View {
    @Bindable var stock: BeadStock
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var onSaved: (String) -> Void = { _ in }

    @State private var quantityText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(BeadPalette.byId[stock.colorId]?.color ?? Color.gray.opacity(0.3))
                            .frame(width: 40, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
                        Text("Mard \(stock.displayName)")
                            .font(.headline.monospaced())
                    }
                }
                Section("数量（覆盖）") {
                    TextField("数量", text: $quantityText)
                        .keyboardType(.numberPad)
                }
                Section {
                    Button(role: .destructive) {
                        context.delete(stock)
                        try? context.save()
                        onSaved("已删除 \(stock.displayName)")
                        dismiss()
                    } label: {
                        Label("删除该色号库存", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("编辑库存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        stock.setQuantity(Int(quantityText.trimmingCharacters(in: .whitespaces)) ?? 0)
                        try? context.save()
                        onSaved("已更新 \(stock.displayName)")
                        dismiss()
                    }
                }
            }
            .onAppear { quantityText = "\(stock.quantity)" }
        }
    }
}
