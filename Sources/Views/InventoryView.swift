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

    // MARK: 多豆仓（分区）
    /// 当前豆仓（"" = 默认仓「我的豆仓」）；跨会话记忆
    @AppStorage("activeBinName") private var activeBin = ""
    /// 豆仓管理 Sheet
    @State private var showBinManager = false
    /// 新建豆仓弹窗
    @State private var showNewBinAlert = false
    @State private var newBinName = ""

    /// 全部色系首字母（A…Z，按现有数据出现的系列生成）
    private var allSeries: [String] {
        BeadPalette.groups.map { $0.letter }
    }

    /// 经过「豆仓 + 搜索 + 色系」筛选后、按 Mard 顺序排列的库存
    private var filteredStocks: [BeadStock] {
        // 先按 colorId 映射到 BeadColor，保证 Mard 顺序
        var list = stocks.compactMap { s -> (stock: BeadStock, color: BeadColor)? in
            guard let c = BeadPalette.byId[s.colorId] else { return nil }
            return (s, c)
        }
        // 豆仓筛选
        list = list.filter { $0.stock.binName == activeBin }
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

    /// 当前豆仓的库存条目
    private var currentBinStocks: [BeadStock] {
        stocks.filter { $0.binName == activeBin }
    }

    /// 当前豆仓总豆量
    private var totalQuantity: Int {
        currentBinStocks.reduce(0) { $0 + $1.quantity }
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
            .navigationTitle(L10n.s("库存"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BoardConnectCapsule()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addMenu
                }
            }
            .searchable(text: $searchText, prompt: L10n.s("搜索色号（Mard/可可/漫漫…）"))
        }
        .sheet(isPresented: $showAdd) {
            StockQuickAddView(onSaved: { msg in toast = msg }, binName: activeBin)
        }
        .sheet(isPresented: $showImport) {
            StockImportView(onFinished: { msg in toast = msg }, binName: activeBin)
        }
        .sheet(isPresented: $showBinManager) {
            BinManagerSheet(activeBin: $activeBin, onFinished: { msg in toast = msg })
        }
        .sheet(item: $editing) { stock in
            StockQuantityEditSheet(stock: stock) { msg in toast = msg }
        }
        .alert(L10n.s("新建豆仓"), isPresented: $showNewBinAlert) {
            TextField(L10n.s("仓名，如「Mard 主仓」"), text: $newBinName)
            Button(L10n.s("创建")) { createBin() }
            Button(L10n.s("取消"), role: .cancel) { newBinName = "" }
        } message: {
            Text(L10n.s("按品牌或用途给豆子分区，各仓独立管理与统计。"))
        }
        .confirmationDialog(L10n.s("删除该色号库存？"),
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(L10n.s("删除"), role: .destructive) {
                if let s = pendingDelete { delete(s) }
                pendingDelete = nil
            }
            Button(L10n.s("取消"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { L10n.p("将移除 {0} 的库存记录", "\($0.displayName)") } ?? "")
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
            // 渐变英雄统计条（当前豆仓）
            Section {
                inventoryHero
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // 多豆仓切换
            Section {
                binBar
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
                                Label(L10n.s("删除"), systemImage: "trash")
                            }
                            Button {
                                editing = stock
                            } label: {
                                Label(L10n.s("编辑"), systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .cardRow()
                }
            } footer: {
                if filteredStocks.isEmpty {
                    Text(currentBinStocks.isEmpty
                         ? L10n.p("「{0}」还没有库存，点右上角「+」添加或批量导入", "\(BeadBinCatalog.displayName(activeBin))")
                         : L10n.s("没有匹配的色号"))
                }
            }
        }
        .themedListPage()
    }

    // MARK: - 多豆仓切换条

    /// 仓名 chips：默认仓 + 自定义仓 + 新建 + 管理
    private var binBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                binChip(name: "", label: BeadBinCatalog.defaultName, icon: "tray.full.fill")
                ForEach(BeadBinCatalog.customBinNames(from: stocks), id: \.self) { raw in
                    binChip(name: raw, label: raw, icon: "shippingbox.fill")
                }
                Button {
                    newBinName = ""
                    showNewBinAlert = true
                } label: {
                    Label(L10n.s("新建仓"), systemImage: "plus")
                        .font(.caption.bold())
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Theme.cardFill, in: Capsule())
                        .foregroundStyle(Theme.accent)
                        .overlay(Capsule().stroke(Theme.accent.opacity(0.35)))
                }
                .buttonStyle(.plain)

                Button {
                    showBinManager = true
                } label: {
                    Label(L10n.s("管理"), systemImage: "slider.horizontal.3")
                        .font(.caption.bold())
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Theme.cardFill, in: Capsule())
                        .foregroundStyle(.secondary)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func binChip(name: String, label: String, icon: String) -> some View {
        let active = activeBin == name
        let count = stocks.filter { $0.binName == name }.count
        return Button {
            activeBin = name
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2.bold())
                Text(label).font(.caption.weight(active ? .bold : .regular))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(active ? .white.opacity(0.85) : .secondary)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(active ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.cardFill), in: Capsule())
            .foregroundStyle(active ? .white : Color.primary)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    /// 新建豆仓：仅登记仓名（库存为空，录入时归入）
    private func createBin() {
        let name = newBinName.trimmingCharacters(in: .whitespacesAndNewlines)
        newBinName = ""
        guard !name.isEmpty, name != BeadBinCatalog.defaultName else { return }
        activeBin = name
        toast = L10n.p("已切到新仓「{0}」，录入的豆子会归入此仓", "\(name)")
    }

    /// 顶部英雄统计：品牌渐变 + 豆点装饰 + 当前仓名 + 三栏数字
    private var inventoryHero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.brand)
            BeadDots()
                .padding(.top, 14).padding(.trailing, 16)
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox.fill").font(.caption2.bold())
                    Text(L10n.p("当前豆仓 · {0}", "\(BeadBinCatalog.displayName(activeBin))"))
                        .font(.caption.bold())
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.92))

                HStack(spacing: 0) {
                    heroCell("\(currentBinStocks.count)", L10n.s("已录入色号"))
                    heroCell("\(totalQuantity)", L10n.s("总豆量"))
                    heroCell("\(lowCount)", lowCount > 0 ? L10n.s("缺色 ⚠︎") : L10n.s("缺色"))
                }
            }
            .padding(16)
        }
        .frame(height: 104)
        .shadow(color: Theme.accent.opacity(0.22), radius: 10, y: 4)
    }

    /// 当前仓低于阈值的色号数
    private var lowCount: Int { currentBinStocks.filter { $0.isLow }.count }

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
                chip(title: L10n.s("全部"), active: seriesFilter.isEmpty) { seriesFilter = "" }
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
                        Text(stock.quantity == 0 ? L10n.s("缺色（库存为 0）") : L10n.p("低于阈值 {0}", "\(stock.threshold)"))
                    }
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color(red: 1.00, green: 0.42, blue: 0.34), in: Capsule())
                } else {
                    Text(L10n.s("充足"))
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
            Label(L10n.s("库存还是空的"), systemImage: "shippingbox")
        } description: {
            Text(L10n.s("可以先「逐条添加」几个常用色号，或把一段「色号 数量」文本「批量导入」。豆子多的话，还能按品牌/用途建多个豆仓分区管理。"))
        } actions: {
            Button {
                showAdd = true
            } label: {
                Label(L10n.s("逐条添加"), systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)

            Button {
                showImport = true
            } label: {
                Label(L10n.s("批量导入"), systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)

            Button {
                newBinName = ""
                showNewBinAlert = true
            } label: {
                Label(L10n.s("新建豆仓"), systemImage: "shippingbox")
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
                Label(L10n.s("逐条添加"), systemImage: "plus.circle")
            }
            Button {
                showImport = true
            } label: {
                Label(L10n.s("批量导入"), systemImage: "doc.on.clipboard")
            }
            Divider()
            Button {
                showBinManager = true
            } label: {
                Label(L10n.s("管理豆仓"), systemImage: "shippingbox")
            }
            Button {
                newBinName = ""
                showNewBinAlert = true
            } label: {
                Label(L10n.s("新建豆仓"), systemImage: "plus.rectangle.on.folder")
            }
        } label: {
            Image(systemName: "plus.circle.fill")
        }
    }

    // MARK: - 增删

    private func delete(_ stock: BeadStock) {
        context.delete(stock)
        try? context.save()
        toast = L10n.p("已删除 {0}", "\(stock.displayName)")
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

    /// 目标豆仓（"" = 默认仓）；新增条目归入该仓，同色号查重也限定在该仓内
    var binName: String = ""

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
                Section(L10n.k(L10n.s("色号"))) {
                    Button {
                        showPalette = true
                    } label: {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedColor?.color ?? Color.gray.opacity(0.3))
                                .frame(width: 40, height: 40)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedColor.map { "Mard \($0.mard)" } ?? L10n.s("点击选择色号"))
                                    .font(.headline)
                                Text(L10n.s("从 295 色板中挑选"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section(L10n.k(L10n.s("数量"))) {
                    TextField(L10n.s("例如 500"), text: $quantityText)
                        .keyboardType(.numberPad)
                    if let c = selectedColor, let existing = existingStock(c.id) {
                        Text(L10n.p("该色号在本仓已有 {0} 颗（保存将累加）", "\(existing.quantity)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent(L10n.k(L10n.s("归入豆仓")), value: BeadBinCatalog.displayName(binName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if addedCount > 0 {
                    Section {
                        Label(L10n.p("本次已添加 {0} 条", "\(addedCount)"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle(L10n.s("逐条添加"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.s("完成")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.s("保存")) { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showPalette) {
                FullPaletteSheet(selectedId: $selectedId)
            }
        }
    }

    /// 查当前仓内已存在的同色号库存
    private func existingStock(_ colorId: Int) -> BeadStock? {
        stocks.first { $0.colorId == colorId && $0.binName == binName }
    }

    /// 保存（累加语义）；保存后清空数量，方便连续添加
    private func save() {
        guard canSave else { return }
        let isUpdate = existingStock(selectedId) != nil
        if let existing = existingStock(selectedId) {
            existing.addQuantity(quantity)
        } else {
            context.insert(BeadStock(colorId: selectedId, quantity: quantity, binName: binName))
        }
        try? context.save()
        addedCount += 1
        let mard = BeadPalette.byId[selectedId]?.mard ?? ""
        onSaved(isUpdate ? L10n.p("已更新 {0}", "\(mard)") : L10n.p("已新增 {0}", "\(mard)"))
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
                Section(L10n.k(L10n.s("数量（覆盖）"))) {
                    TextField(L10n.s("数量"), text: $quantityText)
                        .keyboardType(.numberPad)
                }
                Section {
                    Button(role: .destructive) {
                        context.delete(stock)
                        try? context.save()
                        onSaved(L10n.p("已删除 {0}", "\(stock.displayName)"))
                        dismiss()
                    } label: {
                        Label(L10n.s("删除该色号库存"), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(L10n.s("编辑库存"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.s("取消")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.s("保存")) {
                        stock.setQuantity(Int(quantityText.trimmingCharacters(in: .whitespaces)) ?? 0)
                        try? context.save()
                        onSaved(L10n.p("已更新 {0}", "\(stock.displayName)"))
                        dismiss()
                    }
                }
            }
            .onAppear { quantityText = "\(stock.quantity)" }
        }
    }
}

// MARK: - 豆仓管理 Sheet（对标 AI豆仓「多豆仓分区」）

/// 豆仓管理：新建 / 切换 / 重命名 / 解散（库存归回默认仓，不删数据）。
@MainActor
struct BinManagerSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BeadStock.colorId) private var stocks: [BeadStock]

    /// 当前选中仓（双向绑定到外层 `@AppStorage`）
    @Binding var activeBin: String
    var onFinished: (String) -> Void = { _ in }

    @State private var newName = ""
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var pendingDissolve: String?

    private var customBins: [String] { BeadBinCatalog.customBinNames(from: stocks) }

    private func count(_ raw: String) -> Int {
        stocks.filter { $0.binName == raw }.count
    }

    private func total(_ raw: String) -> Int {
        stocks.filter { $0.binName == raw }.reduce(0) { $0 + $1.quantity }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        TextField(L10n.s("仓名，如「漫漫 补充仓」"), text: $newName)
                            .textFieldStyle(.plain)
                        Button {
                            createBin()
                        } label: {
                            Label(L10n.s("创建"), systemImage: "plus.circle.fill")
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text(L10n.s("新建豆仓"))
                } footer: {
                    Text(L10n.s("按品牌或用途分区后，各仓的色号与豆量独立管理与统计；补豆清单仍按全部豆仓汇总。"))
                }

                Section {
                    binRow(name: "", label: BeadBinCatalog.defaultName, icon: "tray.full.fill",
                           deletable: false)
                } header: {
                    Text(L10n.s("默认仓"))
                } footer: {
                    Text(L10n.s("删除自定义仓时，其中的库存会归回默认仓，不会丢数据。"))
                }

                if !customBins.isEmpty {
                    Section(L10n.pk(L10n.s("自定义豆仓（{0}）"), "\(customBins.count)")) {
                        ForEach(customBins, id: \.self) { raw in
                            binRow(name: raw, label: raw, icon: "shippingbox.fill", deletable: true)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDissolve = raw
                                    } label: {
                                        Label(L10n.s("解散"), systemImage: "trash")
                                    }
                                    Button {
                                        renaming = raw
                                        renameText = raw
                                    } label: {
                                        Label(L10n.s("重命名"), systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }
            }
            .themedListPage()
            .navigationTitle(L10n.s("豆仓管理"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.s("完成")) { dismiss() }
                }
            }
            .alert(L10n.s("重命名豆仓"), isPresented: Binding(get: { renaming != nil },
                                               set: { if !$0 { renaming = nil } })) {
                TextField(L10n.s("新的仓名"), text: $renameText)
                Button(L10n.s("保存")) { applyRename() }
                Button(L10n.s("取消"), role: .cancel) { renaming = nil }
            } message: {
                Text(L10n.s("重命名后，该仓内所有色号记录一并更新。"))
            }
            .confirmationDialog(L10n.s("解散该豆仓？"),
                                isPresented: Binding(get: { pendingDissolve != nil },
                                                     set: { if !$0 { pendingDissolve = nil } }),
                                titleVisibility: .visible) {
                Button(L10n.s("解散，库存归回默认仓"), role: .destructive) { dissolve() }
                Button(L10n.s("取消"), role: .cancel) { pendingDissolve = nil }
            } message: {
                Text(pendingDissolve.map { L10n.p("「{0}」中的库存会移动到「{1}」，记录不会删除。", "\($0)", "\(BeadBinCatalog.defaultName)") } ?? "")
            }
        }
    }

    /// 单行豆仓：点按切换为当前仓
    private func binRow(name: String, label: String, icon: String, deletable: Bool) -> some View {
        let active = activeBin == name
        return Button {
            activeBin = name
            onFinished(L10n.p("已切到「{0}」", "\(BeadBinCatalog.displayName(name))"))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(active ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.mint),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(active ? .bold : .medium))
                        .foregroundStyle(.primary)
                    Text(L10n.p("{0} 个色号 · {1} 颗", "\(count(name))", "\(total(name))"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Text(L10n.s("当前"))
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.brand, in: Capsule())
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 动作

    private func createBin() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        newName = ""
        guard !name.isEmpty, name != BeadBinCatalog.defaultName else { return }
        activeBin = name
        onFinished(L10n.p("已新建并切到「{0}」", "\(name)"))
    }

    private func applyRename() {
        guard let old = renaming else { return }
        let newValue = renameText
        renaming = nil
        let n = BeadBinCatalog.rename(in: stocks, from: old, to: newValue)
        try? context.save()
        // 当前仓若被重命名，跟随更新选中态
        if activeBin == old {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            activeBin = (trimmed == BeadBinCatalog.defaultName) ? "" : trimmed
        }
        onFinished(n > 0 ? L10n.p("已重命名为「{0}」", "\(BeadBinCatalog.displayName(newValue))") : L10n.s("没有需要更新的记录"))
    }

    private func dissolve() {
        guard let raw = pendingDissolve else { return }
        pendingDissolve = nil
        let n = BeadBinCatalog.dissolve(in: stocks, bin: raw)
        try? context.save()
        if activeBin == raw { activeBin = "" }
        onFinished(n > 0 ? L10n.p("「{0}」的 {1} 条库存已归回默认仓", "\(raw)", "\(n)") : L10n.s("该仓没有库存记录"))
    }
}
