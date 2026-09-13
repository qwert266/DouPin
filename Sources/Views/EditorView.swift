import SwiftData
import SwiftUI

// MARK: - 手绘 / 编辑画布

struct EditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let pattern: Pattern?
    var initialSize: Int = 29

    @StateObject private var model: EditorModel
    @State private var name: String
    @State private var showPaletteSheet = false
    @State private var showRename = false
    @State private var saved = false
    @State private var strokeActive = false

    // 缩放（编辑画布）
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero

    // 原图对比
    @State private var showCompare = false

    // 合并相近色 / 替换配色
    @State private var showMerge = false
    @State private var showReplace = false

    init(pattern: Pattern?, initialSize: Int = 29) {
        self.pattern = pattern
        self.initialSize = initialSize
        _model = StateObject(wrappedValue: EditorModel(
            width: pattern?.width ?? initialSize,
            height: pattern?.height ?? initialSize,
            cells: pattern?.cells))
        _name = State(initialValue: pattern?.name ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            if showCompare, let data = pattern?.sourceImageData {
                CompareGridView(cells: model.cells, width: model.width, height: model.height,
                                sourceImageData: data)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            } else {
                EditorCanvas(model: model,
                             scale: $scale,
                             offset: $offset,
                             onBeginStroke: beginStroke,
                             onCell: handleCell,
                             onEndStroke: { strokeActive = false })
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
            }

            toolBar
                .padding(.top, 10)

            colorStrip
                .padding(.vertical, 8)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(pattern == nil ? "手绘画布" : name.isEmpty ? "编辑图纸" : name)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    // 原图对比（仅照片来源可用）
                    Button {
                        showCompare.toggle()
                    } label: {
                        Label(showCompare ? "退出原图对比" : "原图对比",
                              systemImage: showCompare ? "square.split.1x2.slash" : "square.split.1x2")
                    }
                    .disabled(!(pattern?.hasSourceImage ?? false))

                    Button {
                        showReplace = true
                    } label: {
                        Label("替换配色", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!hasContent)

                    Button {
                        showMerge = true
                    } label: {
                        Label("合并相近色", systemImage: "circle.lefthalf.filled.righthalf.striped.horizontal")
                    }
                    .disabled(!hasContent)

                    Divider()

                    Button {
                        scale = 1; offset = .zero
                    } label: {
                        Label("复位缩放", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }

                if pattern != nil {
                    Button {
                        showRename = true
                    } label: {
                        Image(systemName: "pencil.circle")
                    }
                }
                Button {
                    save()
                } label: {
                    Text("保存").bold()
                }
                .disabled(!hasContent)
            }
        }
        .sheet(isPresented: $showPaletteSheet) {
            FullPaletteSheet(selectedId: $model.selectedColorId)
        }
        .sheet(isPresented: $showMerge) {
            ColorMergeSheet(model: model)
        }
        .sheet(isPresented: $showReplace) {
            ReplaceColorSheet(model: model)
        }
        .alert(pattern == nil ? "保存图纸" : "已保存", isPresented: $saved) {
            Button("好") { dismiss() }
        } message: {
            Text(pattern == nil ? "图纸已保存，可在「图纸」标签中查看" : "修改已保存")
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("名称", text: $name)
            Button("确定") {
                // P0-4 修复：写回名称并 touch()（此前为空闭包，改名无效）
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let pattern = pattern, !trimmed.isEmpty else { return }
                pattern.name = trimmed
                pattern.touch()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var hasContent: Bool { model.cells.contains { $0 > 0 } }

    // MARK: - 工具条

    private var toolBar: some View {
        HStack(spacing: 6) {
            ForEach(EditorTool.allCases, id: \.self) { t in
                Button {
                    model.tool = t
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: t.rawValue).font(.body)
                        Text(t.label).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(model.tool == t ? Color.pink.opacity(0.18) : Color(white: 0.95)))
                    .foregroundStyle(model.tool == t ? .pink : .primary)
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 32)

            Button {
                model.mirror.toggle()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "arrow.left.and.right.right").font(.body)
                    Text("镜像").font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(model.mirror ? Color.pink.opacity(0.18) : Color(white: 0.95)))
                .foregroundStyle(model.mirror ? .pink : .primary)
            }
            .buttonStyle(.plain)

            Button {
                model.showGuides.toggle()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "grid").font(.body)
                    Text("辅助线").font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(model.showGuides ? Color.pink.opacity(0.18) : Color(white: 0.95)))
                .foregroundStyle(model.showGuides ? .pink : .primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - 当前颜色 + 常用色带

    private var colorStrip: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if let c = BeadPalette.byId[model.selectedColorId] {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(c.color)
                        .frame(width: 30, height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.4)))
                    Text("Mard \(c.mard)").font(.footnote.monospaced().bold())
                }
                if let hi = model.highlightColorId, let c = BeadPalette.byId[hi] {
                    Spacer()
                    Button {
                        model.highlightColorId = nil
                    } label: {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3).fill(c.color).frame(width: 14, height: 14)
                            Text("高亮中，点此取消").font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                Spacer()
                Button {
                    if model.highlightColorId == model.selectedColorId {
                        model.highlightColorId = nil
                    } else {
                        model.highlightColorId = model.selectedColorId
                    }
                } label: {
                    Label("高亮", systemImage: "sparkle.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.selectedColorId == 0)
            }
            .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(BeadPalette.essentials48, id: \.self) { id in
                        if let c = BeadPalette.byId[id] {
                            ColorSwatch(color: c, selected: model.selectedColorId == id) {
                                model.selectedColorId = id
                                model.tool = .brush
                            }
                        }
                    }
                    Button {
                        showPaletteSheet = true
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "paintpalette.fill")
                            Text("全部").font(.caption2)
                        }
                        .frame(width: 40, height: 40)
                        .background(Color(white: 0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - 手势处理

    private func beginStroke() {
        if model.tool != .eyedropper { model.pushUndo() }
    }

    private func handleCell(_ index: Int) {
        switch model.tool {
        case .brush, .eraser:
            model.apply(tool: model.tool, at: index)
        case .eyedropper, .bucket:
            if !strokeActive {
                strokeActive = true
                model.apply(tool: model.tool, at: index)
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let pattern {
            pattern.name = trimmed.isEmpty ? pattern.name : trimmed
            pattern.width = model.width
            pattern.height = model.height
            pattern.cells = model.cells
            pattern.touch()
        } else {
            let p = Pattern(name: trimmed.isEmpty ? "手绘画布" : trimmed,
                            width: model.width, height: model.height,
                            cells: model.cells, source: "manual")
            context.insert(p)
        }
        saved = true
    }
}

// MARK: - 编辑画布（绘制 + 平移缩放 + 手势）

/// 编辑画布：在 `ZoomableGrid` 基础上叠加"绘画手势"。
///
/// - 单指：画笔/橡皮/吸管/填充（`DragGesture(minimumDistance: 0)`，命中检测考虑缩放/平移）。
/// - 双指：捏合缩放、拖动平移（`MagnifyGesture` + 双指 `DragGesture`）。
/// - 画布内容绘制复用 `ZoomableGrid`，保证与预览/对比页视觉一致。
private struct EditorCanvas: View {
    @ObservedObject var model: EditorModel
    @Binding var scale: CGFloat
    @Binding var offset: CGSize
    var onBeginStroke: () -> Void
    var onCell: (Int) -> Void
    var onEndStroke: () -> Void

    @State private var strokeStarted = false
    @State private var baseScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            // 只读渲染层（ZoomableGrid 负责格子绘制与缩放/平移变换）
            ZoomableGrid(cells: model.cells,
                         width: model.width,
                         height: model.height,
                         showGuides: model.showGuides,
                         highlightColorId: model.highlightColorId,
                         gestureEnabled: true,
                         scale: $scale,
                         offset: $offset)
                .overlay {
                    // 绘画手势层（透明）
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(paintGesture(in: geo.size))
                }
        }
        .background(Color(white: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 单指绘画手势：命中检测需把屏幕坐标反变换到网格坐标
    private func paintGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard let i = cellIndex(at: g.location, in: size) else { return }
                if !strokeStarted {
                    strokeStarted = true
                    onBeginStroke()
                }
                onCell(i)
            }
            .onEnded { _ in
                strokeStarted = false
                onEndStroke()
            }
    }

    /// 屏幕点 → 网格索引（含缩放/平移反变换）
    private func cellIndex(at point: CGPoint, in size: CGSize) -> Int? {
        guard model.width > 0, model.height > 0 else { return nil }
        let baseSide = min(size.width / CGFloat(model.width), size.height / CGFloat(model.height))
        let side = baseSide * scale
        guard side > 0 else { return nil }
        let gridW = side * CGFloat(model.width)
        let gridH = side * CGFloat(model.height)
        let ox = (size.width - gridW) / 2 + offset.width
        let oy = (size.height - gridH) / 2 + offset.height
        let gx = Int((point.x - ox) / side)
        let gy = Int((point.y - oy) / side)
        guard gx >= 0, gx < model.width, gy >= 0, gy < model.height else { return nil }
        return gy * model.width + gx
    }
}

// MARK: - 合并相近色（Sheet：阈值滑杆 + 预览 + 应用）

private struct ColorMergeSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    /// 归一化距离阈值（0…0.30）
    @State private var threshold: Double = 0.06

    private var mapping: [Int: Int] {
        ColorMerge.mergeSuggestions(cells: model.cells, threshold: threshold)
    }

    private var suggestions: [(from: BeadColor, to: BeadColor, count: Int)] {
        ColorMerge.suggestions(model.cells, threshold: threshold)
    }

    private var previewCells: [Int] {
        ColorMerge.applyMerge(cells: model.cells, mapping: mapping)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("相似度阈值", value: String(format: "%.3f", threshold))
                        Slider(value: $threshold, in: 0...0.30, step: 0.005)
                        Text("阈值越大合并越狠（0 = 不合并）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("阈值")
                }

                Section("预览") {
                    GridView(cells: previewCells, width: model.width, height: model.height)
                        .frame(maxHeight: 280)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

                Section {
                    if suggestions.isEmpty {
                        Text("当前阈值下无相近色可合并。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(suggestions, id: \.from.id) { item in
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 4).fill(item.from.color)
                                    .frame(width: 22, height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.3)))
                                Text("Mard \(item.from.mard)")
                                    .font(.subheadline.monospaced())
                                Text("×\(item.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "arrow.right").foregroundStyle(.pink)
                                RoundedRectangle(cornerRadius: 4).fill(item.to.color)
                                    .frame(width: 22, height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.3)))
                                Text("Mard \(item.to.mard)")
                                    .font(.subheadline.monospaced())
                            }
                        }
                    }
                } header: {
                    Text("合并明细（\(suggestions.count) 项）")
                }
            }
            .navigationTitle("合并相近色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用") {
                        guard !mapping.isEmpty else { dismiss(); return }
                        model.pushUndo()
                        model.cells = previewCells
                        dismiss()
                    }
                    .disabled(mapping.isEmpty)
                }
            }
        }
    }
}

// MARK: - 替换配色（Sheet：选原色号 + 新色号）

private struct ReplaceColorSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    @State private var fromId: Int = 0
    @State private var toId: Int = 0
    @State private var showFromPicker = false
    @State private var showToPicker = false

    /// 当前图纸中用到的色号（含数量），供"原色号"选择
    private var usedColors: [(color: BeadColor, count: Int)] {
        let counts = ColorMerge.counts(model.cells)
        return counts
            .compactMap { id, n in BeadPalette.byId[id].map { ($0, n) } }
            .sorted { $0.count > $1.count }
    }

    private var affected: Int {
        model.cells.filter { $0 == fromId }.count
    }

    var body: some View {
        NavigationStack {
            List {
                Section("原色号（要替换掉的）") {
                    ForEach(usedColors, id: \.color.id) { item in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 4).fill(item.color.color)
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.3)))
                            Text("Mard \(item.color.mard)").font(.subheadline.monospaced())
                            Spacer()
                            Text("×\(item.count)").font(.caption).foregroundStyle(.secondary)
                            if fromId == item.color.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.pink)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { fromId = item.color.id }
                    }
                }

                Section("新色号（替换为）") {
                    Button {
                        showToPicker = true
                    } label: {
                        HStack(spacing: 10) {
                            if let c = BeadPalette.byId[toId] {
                                RoundedRectangle(cornerRadius: 4).fill(c.color)
                                    .frame(width: 22, height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.3)))
                                Text("Mard \(c.mard)").font(.subheadline.monospaced())
                            } else {
                                Text("选择新色号").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    if fromId != 0 {
                        Button("替换为空（清空该色）") { toId = 0 }
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    LabeledContent("受影响格数", value: "\(affected) 格")
                }
            }
            .navigationTitle("替换配色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("应用") {
                        guard fromId != toId else { dismiss(); return }
                        model.pushUndo()
                        model.cells = ColorMerge.replaceColor(cells: model.cells, from: fromId, to: toId)
                        dismiss()
                    }
                    .disabled(fromId == 0 && toId == 0 || affected == 0)
                }
            }
            .sheet(isPresented: $showToPicker) {
                FullPaletteSheet(selectedId: $toId)
            }
        }
    }
}

// MARK: - 色板小组件

struct ColorSwatch: View {
    let color: BeadColor
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.color)
                .frame(width: 34, height: 34)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selected ? Color.pink : Color.gray.opacity(0.35), lineWidth: selected ? 3 : 1))
                .overlay(alignment: .bottom) {
                    Text(color.mard)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(color.brightness > 0.6 ? .black : .white)
                        .padding(1)
                }
        }
        .buttonStyle(.plain)
    }
}

extension BeadColor {
    /// 相对亮度（用于决定色号标注用黑字还是白字）
    var brightness: Double {
        (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255
    }
}

// MARK: - 全部色板（295 色，按字母分组）

struct FullPaletteSheet: View {
    @Binding var selectedId: Int
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var groups: [(letter: String, colors: [BeadColor])] {
        guard !searchText.isEmpty else { return BeadPalette.groups }
        let q = searchText.lowercased()
        return BeadPalette.groups.compactMap { g in
            let matched = g.colors.filter {
                $0.mard.lowercased().contains(q) ||
                $0.coco.lowercased().contains(q) ||
                $0.manman.lowercased().contains(q) ||
                $0.panpan.contains(q) ||
                $0.mixiaowo.contains(q)
            }
            return matched.isEmpty ? nil : (g.letter, matched)
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: .sectionHeaders) {
                    ForEach(groups, id: \.letter) { g in
                        Section {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(g.colors) { c in
                                    ColorSwatch(color: c, selected: selectedId == c.id) {
                                        selectedId = c.id
                                        dismiss()
                                    }
                                }
                            }
                        } header: {
                            Text(g.letter)
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .background(.bar)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .searchable(text: $searchText, prompt: "按色号搜索（Mard/可可/漫漫…）")
            .navigationTitle("色板 · 295 色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
