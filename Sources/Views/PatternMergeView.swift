import SwiftData
import SwiftUI

// MARK: - 合并图纸（对标 PIXDOU「多图合并排版」）

/// 把 2～9 张已有图纸按「横向并排 / 纵向堆叠 / 两列网格」合并成一张大图纸。
///
/// - 选中顺序即拼接顺序（点击先后）；
/// - 图纸之间插入 `gap` 格空白（0），可在预览里实时看效果；
/// - 生成的新图纸进入正常图纸库，可继续编辑 / 拆板 / 打印。
@MainActor
struct PatternMergeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Pattern.updatedAt, order: .reverse) private var patterns: [Pattern]

    // MARK: 状态

    /// 拼接方式
    enum MergeLayout: String, CaseIterable, Identifiable {
        case horizontal = "横向并排"
        case vertical = "纵向堆叠"
        case grid = "两列网格"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .horizontal: return "rectangle.split.2x1"
            case .vertical: return "rectangle.split.1x2"
            case .grid: return "square.grid.2x2"
            }
        }
    }

    /// 选中图纸 id（按点击顺序，先点先拼）
    @State private var pickedIds: [UUID] = []
    @State private var layout: MergeLayout = .horizontal
    /// 图纸间隔空白格数（0～3）
    @State private var gap: Int = 1
    @State private var mergedName: String = "合并图纸"

    /// 生成结果（用于 push 到作品详情）
    @State private var created: Pattern?
    @State private var navigateToResult = false
    /// 生成反馈
    @State private var toast: String?

    /// 按选中顺序取图纸（忽略已被删除的）
    private var picked: [Pattern] {
        pickedIds.compactMap { id in patterns.first { $0.id == id } }
    }

    /// 合并后的网格（预览与生成共用）
    private var mergedGrid: (cells: [Int], w: Int, h: Int)? {
        Self.merge(patterns: picked, layout: layout, gap: gap)
    }

    /// 合并后的总颗数（估算用）
    private var mergedBeadCount: Int { mergedGrid?.cells.filter { $0 > 0 }.count ?? 0 }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                pickSection
                layoutSection
                previewSection
                createButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Theme.pageFill)
        .navigationTitle("合并图纸")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToResult) {
            if let created {
                WorkDetailView(pattern: created)
            }
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

    // MARK: 选图纸（多选缩略图网格）

    private var pickSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("选择图纸", systemImage: "square.on.square.dashed")
                    .font(.subheadline.bold())
                Spacer()
                Text("已选 \(pickedIds.count)/9")
                    .font(.caption)
                    .foregroundStyle(pickedIds.isEmpty ? .secondary : Theme.accent)
            }

            if patterns.isEmpty {
                Text("还没有图纸，先去创建")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                    ForEach(patterns.prefix(60)) { p in
                        pickCell(p)
                    }
                }
            }
        }
        .cardStyle()
    }

    private func pickCell(_ p: Pattern) -> some View {
        let order = pickedIds.firstIndex(of: p.id)
        let pickedFlag = order != nil
        return Button {
            toggle(p)
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: p.thumbnailImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 64)
                        .frame(maxWidth: .infinity)
                        .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if let order {
                        Text("\(order + 1)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Theme.brand, in: Circle())
                            .offset(x: 6, y: -6)
                    }
                }
                Text(p.name)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(8)
            .background(
                pickedFlag ? AnyShapeStyle(Theme.brand.opacity(0.10)) : AnyShapeStyle(Theme.cardFill),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(pickedFlag ? Theme.accent : Color.secondary.opacity(0.12),
                            lineWidth: pickedFlag ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 勾选 / 取消（上限 9 张，保证合并网格不会过大）
    private func toggle(_ p: Pattern) {
        if let idx = pickedIds.firstIndex(of: p.id) {
            pickedIds.remove(at: idx)
        } else if pickedIds.count < 9 {
            pickedIds.append(p.id)
        }
    }

    // MARK: 拼接方式

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("拼接方式", systemImage: "rectangle.compress.vertical")
                .font(.subheadline.bold())

            Picker("拼接方式", selection: $layout) {
                ForEach(MergeLayout.allCases) { l in
                    Label(l.rawValue, systemImage: l.icon).tag(l)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $gap, in: 0...3) {
                LabeledContent("图纸间隔", value: "\(gap) 格空白")
            }
            .font(.subheadline)

            TextField("合并图纸名称", text: $mergedName)
                .font(.subheadline)
                .textFieldStyle(.roundedBorder)
        }
        .cardStyle()
    }

    // MARK: 预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("实时预览", systemImage: "eye")
                    .font(.subheadline.bold())
                Spacer()
                if let g = mergedGrid {
                    Text("\(g.w) × \(g.h) 格 · 约 \(mergedBeadCount) 颗")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let g = mergedGrid {
                Image(uiImage: PatternRenderer.renderThumb(cells: g.cells, width: g.w, height: g.h, size: 480))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("选 2 张以上图纸开始合并")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }
        }
        .cardStyle()
    }

    // MARK: 生成

    private var createButton: some View {
        Button {
            createMerged()
        } label: {
            Label("生成合并图纸", systemImage: "plus.square.on.square")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    pickedIds.count >= 2 ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.secondary.opacity(0.3)),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(pickedIds.count < 2)
    }

    private func createMerged() {
        guard let g = mergedGrid, g.w > 0, g.h > 0 else { return }
        let name = mergedName.trimmingCharacters(in: .whitespaces)
        let p = Pattern(name: name.isEmpty ? "合并图纸" : name,
                        width: g.w, height: g.h, cells: g.cells, source: "manual")
        context.insert(p)
        try? context.save()
        created = p
        navigateToResult = true
        toast = "已生成合并图纸"
    }

    // MARK: - 合并算法（纯函数，供预览与生成共用）

    /// 按布局把多张图纸合并为一张网格。
    /// - 图纸间以 `gap` 格空白分隔；
    /// - 行/列尺寸取同方向最大值，短图余下区域保持空格；
    /// - 网格不一致（宽×高 ≠ cells 数）的图纸自动跳过。
    static func merge(patterns: [Pattern], layout: MergeLayout, gap: Int) -> (cells: [Int], w: Int, h: Int)? {
        let items = patterns.filter { $0.isGridConsistent }
        guard !items.isEmpty else { return nil }

        switch layout {
        case .horizontal:
            let h = items.map(\.height).max()!
            let w = items.map(\.width).reduce(0) { $0 + $1 } + gap * (items.count - 1)
            guard w > 0, h > 0, w * h <= 4096 else { return nil }
            var cells = [Int](repeating: 0, count: w * h)
            var x = 0
            for p in items {
                for y in 0..<p.height {
                    for dx in 0..<p.width {
                        cells[y * w + x + dx] = p.cells[y * p.width + dx]
                    }
                }
                x += p.width + gap
            }
            return (cells, w, h)

        case .vertical:
            let w = items.map(\.width).max()!
            let h = items.map(\.height).reduce(0) { $0 + $1 } + gap * (items.count - 1)
            guard w > 0, h > 0, w * h <= 4096 else { return nil }
            var cells = [Int](repeating: 0, count: w * h)
            var y = 0
            for p in items {
                for dy in 0..<p.height {
                    for x in 0..<p.width {
                        cells[(y + dy) * w + x] = p.cells[dy * p.width + x]
                    }
                }
                y += p.height + gap
            }
            return (cells, w, h)

        case .grid:
            // 两列网格：奇偶分列，行高取同行最大，列宽取同列最大
            let col0 = items.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
            let col1 = items.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }
            let rowCount = max((items.count + 1) / 2, 1)
            let w0 = col0.map(\.width).max() ?? 0
            let w1 = col1.map(\.width).max() ?? 0
            let w = w0 + gap + w1
            var h = 0
            var rowHeights: [Int] = []
            for r in 0..<rowCount {
                let rh = max(r < col0.count ? col0[r].height : 0,
                             r < col1.count ? col1[r].height : 0)
                rowHeights.append(rh)
                h += rh
            }
            h += gap * (rowCount - 1)
            guard w > 0, h > 0, w * h <= 4096 else { return nil }

            var cells = [Int](repeating: 0, count: w * h)
            var y = 0
            for r in 0..<rowCount {
                if r < col0.count {
                    let p = col0[r]
                    for dy in 0..<p.height {
                        for x in 0..<p.width { cells[(y + dy) * w + x] = p.cells[dy * p.width + x] }
                    }
                }
                if r < col1.count {
                    let p = col1[r]
                    let xOff = w0 + gap
                    for dy in 0..<p.height {
                        for x in 0..<p.width { cells[(y + dy) * w + xOff + x] = p.cells[dy * p.width + x] }
                    }
                }
                y += rowHeights[r] + gap
            }
            return (cells, w, h)
        }
    }
}
