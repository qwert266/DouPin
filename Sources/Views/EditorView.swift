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
            EditorCanvas(model: model,
                         onBeginStroke: beginStroke,
                         onCell: handleCell,
                         onEndStroke: { strokeActive = false })
                .padding(.horizontal, 8)
                .padding(.top, 8)

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
        .alert(pattern == nil ? "保存图纸" : "已保存", isPresented: $saved) {
            Button("好") { dismiss() }
        } message: {
            Text(pattern == nil ? "图纸已保存，可在「图纸」标签中查看" : "修改已保存")
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("名称", text: $name)
            Button("确定") {}
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

// MARK: - 编辑画布（绘制 + 手势）

private struct EditorCanvas: View {
    @ObservedObject var model: EditorModel
    var onBeginStroke: () -> Void
    var onCell: (Int) -> Void
    var onEndStroke: () -> Void

    @State private var strokeStarted = false

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let side = min(size.width / CGFloat(model.width), size.height / CGFloat(model.height))
                let ox = (size.width - side * CGFloat(model.width)) / 2
                let oy = (size.height - side * CGFloat(model.height)) / 2

                for y in 0..<model.height {
                    for x in 0..<model.width {
                        let v = model.cells[y * model.width + x]
                        var color: Color = v > 0 ? (BeadPalette.byId[v]?.color ?? .clear)
                                                  : Color(white: 0.97)
                        if let hi = model.highlightColorId, v != hi {
                            color = v > 0 ? color.opacity(0.22) : color.opacity(0.55)
                        }
                        let rect = CGRect(x: ox + CGFloat(x) * side, y: oy + CGFloat(y) * side,
                                          width: side + 0.5, height: side + 0.5)
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }

                if model.showGuides && side > 4 {
                    var grid = Path()
                    for gx in stride(from: 10, to: model.width, by: 10) {
                        let x = ox + CGFloat(gx) * side
                        grid.move(to: CGPoint(x: x, y: oy))
                        grid.addLine(to: CGPoint(x: x, y: oy + side * CGFloat(model.height)))
                    }
                    for gy in stride(from: 10, to: model.height, by: 10) {
                        let y = oy + CGFloat(gy) * side
                        grid.move(to: CGPoint(x: ox, y: y))
                        grid.addLine(to: CGPoint(x: ox + side * CGFloat(model.width), y: y))
                    }
                    ctx.stroke(grid, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard let i = model.cellIndex(at: g.location, in: geo.size) else { return }
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
            )
        }
        .background(Color(white: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
