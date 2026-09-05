import PhotosUI
import SwiftData
import SwiftUI

// MARK: - 作品详情：图纸 / 进度打卡 / 板子引导

struct WorkDetailView: View {
    @Bindable var pattern: Pattern
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppState
    @ObservedObject private var board = AppState.shared.board

    @State private var mode: Mode = .pattern
    @State private var markMode = false
    @State private var resultItem: PhotosPickerItem?
    @State private var toast: String?
    @State private var showDeleteConfirm = false
    @State private var showResetConfirm = false
    @State private var showRename = false
    @State private var renameText = ""

    // 板子引导状态
    @State private var guideMode: GuideMode = .row
    @State private var guideRow = 0
    @State private var guideColorId: Int? = nil
    @State private var colorIndex = 0
    @State private var showGuideColorPicker = false
    @State private var boardBusy = false

    enum Mode: String, CaseIterable {
        case pattern = "图纸"
        case progress = "进度"
        case statistics = "统计"
        case guide = "板子引导"
    }

    enum GuideMode: String, CaseIterable {
        case row = "逐行"
        case color = "逐色"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("模式", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            switch mode {
            case .pattern: patternTab
            case .progress: progressTab
            case .statistics: statsTab
            case .guide: guideTab
            }
        }
        .navigationTitle(pattern.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = pattern.name
                        showRename = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button {
                        UIPasteboard.general.string = PatternRenderer.beadListText(
                            name: pattern.name, cells: pattern.cells)
                        toast = "豆子清单已复制"
                    } label: {
                        Label("复制豆子清单", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: Image(uiImage: exportImage),
                              preview: SharePreview(pattern.name, image: Image(uiImage: exportImage))) {
                        Label("导出图纸图片", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("清空拼制进度", systemImage: "arrow.counterclockwise")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除作品", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
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
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        self.toast = nil
                    }
            }
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("名称", text: $renameText)
            Button("确定") {
                let t = renameText.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { pattern.name = t; pattern.touch() }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("清空拼制进度？", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) { pattern.resetProgress() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有已拼标记将被清除")
        }
        .confirmationDialog("删除作品？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                context.delete(pattern)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「\(pattern.name)」及其进度将被永久删除")
        }
    }

    // MARK: - 图纸 Tab

    private var patternTab: some View {
        List {
            Section {
                ProgressGridView(cells: pattern.cells, width: pattern.width, height: pattern.height,
                                  placed: pattern.placed,
                                  onTap: markMode ? { i in toggleCell(i) } : nil)
                    .frame(maxHeight: 380)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .overlay(alignment: .topTrailing) {
                        if markMode {
                            Label("打卡模式", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                                .padding(14)
                        }
                    }
            }

            Section {
                HStack(spacing: 14) {
                    statCell("已拼", "\(pattern.placedCount)")
                    statCell("总数", "\(pattern.totalBeads)")
                    statCell("剩余", "\(pattern.totalBeads - pattern.placedCount)")
                    statCell("颜色", "\(pattern.beadCounts.count)")
                }
                .listRowInsets(EdgeInsets())
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: pattern.progressPercent)
                        .tint(pattern.progressPercent >= 1 ? .green : .pink)
                    Text("\(Int(pattern.progressPercent * 100))% · \(pattern.status.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            Section {
                Toggle("逐格打卡模式（点击格子标记已拼）", isOn: $markMode)
                NavigationLink {
                    EditorView(pattern: pattern)
                } label: {
                    Label("编辑图纸", systemImage: "paintbrush")
                }
            }

            if let photo = pattern.resultPhoto, let ui = UIImage(data: photo) {
                Section("成品") {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Button(role: .destructive) {
                        pattern.resultPhoto = nil
                    } label: {
                        Label("移除成品照片", systemImage: "trash")
                    }
                }
            } else {
                resultPhotoSection
            }
        }
        .onChange(of: resultItem) { _, item in
            guard item != nil else { return }
            loadResultPhoto()
        }
    }

    private var resultPhotoSection: some View {
        Section("成品照片") {
            PhotosPicker(selection: $resultItem, matching: .images) {
                Label(pattern.resultPhoto == nil ? "添加成品照片" : "更换成品照片",
                      systemImage: "camera")
            }
        }
    }

    // MARK: - 进度 Tab

    private var progressTab: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: pattern.progressPercent)
                        .tint(pattern.progressPercent >= 1 ? .green : .pink)
                    Text("\(pattern.placedCount) / \(pattern.totalBeads) 颗 · \(Int(pattern.progressPercent * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if pattern.status == .done {
                    Label("已完成！\(pattern.completedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("总进度")
            }

            Section {
                let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(0..<pattern.height, id: \.self) { row in
                        let done = pattern.isRowPlaced(row)
                        Button {
                            toggleRow(row)
                        } label: {
                            Text("第\(row + 1)行")
                                .font(.caption.weight(done ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    done ? Color.green.opacity(0.18) : Color(white: 0.94),
                                    in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(done ? .green : .primary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(done ? Color.green : Color.gray.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("逐行打卡")
            } footer: {
                Text("拼完一行点一下；点错了再点一次即可撤销该行。")
            }

            Section {
                ForEach(pattern.beadCounts, id: \.color.id) { item in
                    let placedN = placedCount(colorId: item.color.id)
                    let colorDone = placedN >= item.count
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(item.color.color)
                            .frame(width: 30, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.3)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mard \(item.color.mard)").font(.subheadline.monospaced().weight(.medium))
                            Text("\(placedN) / \(item.count) 颗")
                                .font(.caption)
                                .foregroundStyle(colorDone ? .green : .secondary)
                        }
                        Spacer()
                        if colorDone {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("全拼完") {
                                pattern.placeColor(colorId: item.color.id)
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("分色打卡")
            } footer: {
                Text("一种颜色一次买齐、一次拼完时，用右侧按钮整色打卡。")
            }
        }
    }

    // MARK: - 统计 Tab（色号用量表）

    private var statsTab: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    statCell("总颗粒", "\(pattern.totalBeads)")
                    statCell("颜色数", "\(pattern.beadCounts.count)")
                    statCell("规格", "\(pattern.width)×\(pattern.height)")
                }
                .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(pattern.beadCounts, id: \.color.id) { item in
                    statsRow(item)
                }
            } header: {
                Text("色号用量")
            } footer: {
                Text("对照色号顺序：Mard / 可可 / 漫漫 / 盼盼 / 米小窝；库存状态取自「豆仓」。")
            }

            Section {
                Button {
                    UIPasteboard.general.string = PatternRenderer.beadListText(
                        name: pattern.name, cells: pattern.cells)
                    toast = "豆子清单已复制"
                } label: {
                    Label("复制豆子清单", systemImage: "doc.on.doc")
                }
                Button {
                    UIPasteboard.general.string = StockStore.gapsText(pattern: pattern, context: context)
                    toast = "补货清单已复制"
                } label: {
                    Label("复制补货清单（按豆仓库存）", systemImage: "cart.badge.plus")
                }
            }
        }
    }

    private func statsRow(_ item: (color: BeadColor, count: Int)) -> some View {
        let stock = StockStore.stock(colorId: item.color.id, context: context)
        let gap = max(0, item.count - stock)
        let pct = pattern.totalBeads > 0
            ? Double(item.count) / Double(pattern.totalBeads) * 100 : 0
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 5)
                .fill(item.color.color)
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.3)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Mard \(item.color.mard)").font(.subheadline.weight(.medium))
                Text("可可 \(item.color.coco) · 漫漫 \(item.color.manman) · 盼盼 \(item.color.panpan) · 米小窝 \(item.color.mixiaowo)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(item.count) 颗")
                    .font(.headline.monospacedDigit())
                Text(String(format: "%.1f%%", pct))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if gap > 0 {
                    Text("缺 \(gap)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                } else {
                    Text("库存够")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: - 板子引导 Tab

    private var guideTab: some View {
        List {
            if !board.isConnected {
                Section {
                    ContentUnavailableView {
                        Label("拼豆板未连接", systemImage: "lightbulb")
                    } description: {
                        Text("到「拼豆板」标签连接设备后，可以在这里点亮当前行或当前颜色辅助定位。")
                    }
                    .frame(maxHeight: 260)
                }
            } else if pattern.beadCounts.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("图纸是空的", systemImage: "square.dashed")
                    } description: {
                        Text("先在「图纸」里编辑豆子颜色，再来用板子引导。")
                    }
                    .frame(maxHeight: 220)
                }
            } else {
                Section {
                    Picker("引导方式", selection: $guideMode) {
                        ForEach(GuideMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)

                if guideMode == .row {
                    rowGuideSections
                } else {
                    colorGuideSections
                }

                if board.isSending {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("正在发送引导图… \(Int(board.sendProgress * 100))%")
                                .font(.subheadline)
                            ProgressView(value: board.sendProgress)
                        }
                    }
                }

                quickControls
            }
        }
    }

    // MARK: 逐行引导

    @ViewBuilder
    private var rowGuideSections: some View {
        Section("当前行引导") {
            HStack {
                Button {
                    if guideRow > 0 { guideRow -= 1; sendRowGuide() }
                } label: {
                    Image(systemName: "chevron.left.circle.fill").font(.title2)
                }
                .disabled(guideRow <= 0 || boardBusy)

                Spacer()
                VStack(spacing: 2) {
                    Text("第 \(guideRow + 1) / \(pattern.height) 行")
                        .font(.title3.monospacedDigit().bold())
                    if pattern.isRowPlaced(guideRow) {
                        Text("本行已拼完").font(.caption).foregroundStyle(.green)
                    }
                }
                Spacer()

                Button {
                    if guideRow < pattern.height - 1 { guideRow += 1; sendRowGuide() }
                } label: {
                    Image(systemName: "chevron.right.circle.fill").font(.title2)
                }
                .disabled(guideRow >= pattern.height - 1 || boardBusy)
            }

            if let cid = guideColorId, let c = BeadPalette.byId[cid] {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(c.color)
                        .frame(width: 22, height: 22)
                    Text("仅显示 Mard \(c.mard)")
                        .font(.subheadline)
                    Spacer()
                    Button("取消分色") {
                        guideColorId = nil
                        sendRowGuide()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Button {
                sendRowGuide()
            } label: {
                Label("点亮当前行（含相邻行微亮）", systemImage: "light.beacon.max")
            }
            .disabled(boardBusy)

            Button {
                Task { await sendFullPreview() }
            } label: {
                Label("发送完整预览图", systemImage: "square.grid.3x3")
            }
            .disabled(boardBusy)

            Menu {
                ForEach(pattern.beadCounts, id: \.color.id) { item in
                    Button {
                        guideColorId = item.color.id
                        sendRowGuide()
                    } label: {
                        HStack {
                            Text("仅 \(item.color.mard)（\(item.count) 颗）")
                        }
                    }
                }
            } label: {
                Label("按颜色过滤当前行…", systemImage: "line.3.horizontal.decrease.circle")
            }
            .disabled(pattern.beadCounts.isEmpty)
        }

        Section {
            Button {
                finishRowAndAdvance()
            } label: {
                Label("本行拼完 → 下一行", systemImage: "checkmark.circle.badge.arrow.forward")
                    .font(.headline)
            }
            .disabled(boardBusy || guideRow >= pattern.height - 1 && pattern.isRowPlaced(guideRow))
        } header: {
            Text("打卡 + 前进")
        } footer: {
            Text("拼完当前行后点击，会自动标记该行已拼并点亮下一行。")
        }
    }

    // MARK: 逐色引导（PIXDOU 同款：一次只亮一种颜色）

    @ViewBuilder
    private var colorGuideSections: some View {
        Section {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(currentGuideColor.color)
                    .frame(width: 52, height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.3)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mard \(currentGuideColor.mard)")
                        .font(.title3.bold())
                    Text("第 \(colorIndex + 1) / \(pattern.beadCounts.count) 色 · 剩余 \(currentColorRemaining) 颗")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if currentColorRemaining == 0 {
                        Text("本色已拼完").font(.caption).foregroundStyle(.green)
                    }
                }
                Spacer()
            }

            Slider(value: Binding(
                get: { Double(colorIndex) },
                set: { setColorIndex(Int($0)) }),
                   in: 0...Double(max(0, pattern.beadCounts.count - 1)))

            HStack {
                Button {
                    setColorIndex(colorIndex - 1)
                } label: {
                    Image(systemName: "chevron.left.circle.fill").font(.title2)
                }
                .disabled(colorIndex <= 0 || boardBusy)

                Spacer()

                Button {
                    setColorIndex(colorIndex + 1)
                } label: {
                    Image(systemName: "chevron.right.circle.fill").font(.title2)
                }
                .disabled(colorIndex >= pattern.beadCounts.count - 1 || boardBusy)
            }
            .buttonStyle(.borderless)

            Button {
                sendColorGuide()
            } label: {
                Label("点亮本色（其余熄灭）", systemImage: "light.beacon.max")
            }
            .disabled(boardBusy)
        } header: {
            Text("逐色引导")
        } footer: {
            Text("板子只亮当前颜色未拼的格子；拼完点下方按钮打卡并自动跳到下一色。")
        }

        Section {
            Button {
                finishColorAndAdvance()
            } label: {
                Label("本色拼完 → 下一色", systemImage: "checkmark.circle.badge.arrow.forward")
                    .font(.headline)
            }
            .disabled(boardBusy)
        } footer: {
            Text("已拼的格子会熄灭；最后一色拼完后图纸即完成。")
        }
    }

    private var quickControls: some View {
        Section("快捷控制") {
            QuickBrightnessRow()
            QuickDisplayToggleRow()
        }
    }

    // MARK: - 动作

    private func statCell(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func placedCount(colorId: Int) -> Int {
        guard pattern.placed.count == pattern.cells.count else { return 0 }
        var n = 0
        for i in pattern.cells.indices where pattern.cells[i] == colorId && pattern.placed[i] { n += 1 }
        return n
    }

    private func toggleCell(_ i: Int) {
        guard i >= 0, i < pattern.cells.count, pattern.cells[i] > 0 else { return }
        pattern.placed[i].toggle()
        pattern.touch()
    }

    private func toggleRow(_ row: Int) {
        let done = pattern.isRowPlaced(row)
        for x in 0..<pattern.width {
            let i = row * pattern.width + x
            if pattern.cells[i] > 0 { pattern.placed[i] = !done }
        }
        pattern.touch()
    }

    private func finishRowAndAdvance() {
        pattern.placeRow(guideRow)
        if guideRow < pattern.height - 1 {
            guideRow += 1
            sendRowGuide()
        }
    }

    // MARK: 逐色引导动作

    /// 当前引导色（列表按用量降序，index 越界时夹到边界）
    private var currentGuideColor: BeadColor {
        let list = pattern.beadCounts
        let idx = min(max(0, colorIndex), max(0, list.count - 1))
        return list[idx].color
    }

    /// 当前色未拼的格数
    private var currentColorRemaining: Int {
        let list = pattern.beadCounts
        guard list.indices.contains(colorIndex) else { return 0 }
        let cid = list[colorIndex].color.id
        guard pattern.placed.count == pattern.cells.count else { return list[colorIndex].count }
        var n = 0
        for i in pattern.cells.indices where pattern.cells[i] == cid && !pattern.placed[i] { n += 1 }
        return n
    }

    private func setColorIndex(_ i: Int) {
        let count = pattern.beadCounts.count
        guard count > 0 else { return }
        let clamped = max(0, min(count - 1, i))
        guard clamped != colorIndex else { return }
        colorIndex = clamped
        sendColorGuide()
    }

    private func sendColorGuide() {
        guard pattern.beadCounts.indices.contains(colorIndex) else { return }
        let cid = pattern.beadCounts[colorIndex].color.id
        Task {
            boardBusy = true
            defer { boardBusy = false }
            let rgb = BoardImageBuilder.colorGuide(
                width: pattern.width, height: pattern.height, cells: pattern.cells,
                colorId: cid, placed: pattern.placed)
            try? await board.sendImage(width: pattern.width, height: pattern.height, rgb: rgb)
        }
    }

    private func finishColorAndAdvance() {
        guard pattern.beadCounts.indices.contains(colorIndex) else { return }
        let cid = pattern.beadCounts[colorIndex].color.id
        pattern.placeColor(colorId: cid)
        if colorIndex < pattern.beadCounts.count - 1 {
            colorIndex += 1
            sendColorGuide()
        } else {
            sendColorGuide()
        }
    }

    private func sendRowGuide() {
        Task {
            boardBusy = true
            defer { boardBusy = false }
            let rgb = BoardImageBuilder.rowGuideWithNeighbors(
                width: pattern.width, height: pattern.height, cells: pattern.cells,
                row: guideRow, colorId: guideColorId, placed: pattern.placed)
            try? await board.sendImage(width: pattern.width, height: pattern.height, rgb: rgb)
        }
    }

    private func sendFullPreview() async {
        let rgb = BoardImageBuilder.fullImage(width: pattern.width, height: pattern.height,
                                              cells: pattern.cells, placed: pattern.placed)
        try? await board.sendImage(width: pattern.width, height: pattern.height, rgb: rgb)
    }

    private var exportImage: UIImage {
        var opts = PatternRenderer.ExportOptions()
        opts.title = pattern.name
        return PatternRenderer.exportPattern(cells: pattern.cells, width: pattern.width,
                                             height: pattern.height, options: opts)
    }

    private func loadResultPhoto() {
        guard let item = resultItem else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let ui = UIImage(data: data),
               let jpeg = ui.jpegData(compressionQuality: 0.85) {
                pattern.resultPhoto = jpeg
                if pattern.status != .done {
                    pattern.status = .done
                }
                pattern.touch()
            }
            resultItem = nil
        }
    }
}

// MARK: - 进度感知网格（已拼格子暗显）

struct ProgressGridView: View {
    let cells: [Int]
    let width: Int
    let height: Int
    var placed: [Bool]? = nil
    var onTap: ((Int) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let side = min(size.width / CGFloat(width), size.height / CGFloat(height))
                let ox = (size.width - side * CGFloat(width)) / 2
                let oy = (size.height - side * CGFloat(height)) / 2

                for y in 0..<height {
                    for x in 0..<width {
                        let i = y * width + x
                        let v = cells[i]
                        var color: Color = v > 0 ? (BeadPalette.byId[v]?.color ?? .clear)
                                                  : Color(white: 0.97)
                        if v > 0, let placed, i < placed.count, placed[i] {
                            color = color.opacity(0.30)
                        }
                        let rect = CGRect(x: ox + CGFloat(x) * side, y: oy + CGFloat(y) * side,
                                          width: side + 0.5, height: side + 0.5)
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }

                if side > 4 {
                    var grid = Path()
                    for gx in stride(from: 10, to: width, by: 10) {
                        let x = ox + CGFloat(gx) * side
                        grid.move(to: CGPoint(x: x, y: oy))
                        grid.addLine(to: CGPoint(x: x, y: oy + side * CGFloat(height)))
                    }
                    for gy in stride(from: 10, to: height, by: 10) {
                        let y = oy + CGFloat(gy) * side
                        grid.move(to: CGPoint(x: ox, y: y))
                        grid.addLine(to: CGPoint(x: ox + side * CGFloat(width), y: y))
                    }
                    ctx.stroke(grid, with: .color(.gray.opacity(0.45)), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { g in
                        guard let onTap else { return }
                        let side = min(geo.size.width / CGFloat(width), geo.size.height / CGFloat(height))
                        let ox = (geo.size.width - side * CGFloat(width)) / 2
                        let oy = (geo.size.height - side * CGFloat(height)) / 2
                        let gx = Int((g.location.x - ox) / side)
                        let gy = Int((g.location.y - oy) / side)
                        guard gx >= 0, gx < width, gy >= 0, gy < height else { return }
                        onTap(gy * width + gx)
                    }
            )
        }
        .aspectRatio(CGFloat(width) / CGFloat(height), contentMode: .fit)
        .background(Color(white: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 引导页快捷亮度 / 显示开关（独立视图保证正确观察 BoardSession）

private struct QuickBrightnessRow: View {
    @ObservedObject var board = AppState.shared.board
    @State private var pct = 80
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("板子亮度", value: "\(pct)%")
            Slider(value: Binding(get: { Double(pct) }, set: { pct = Int($0) }),
                   in: 10...100, step: 5)
                .onChange(of: pct) { _, v in
                    task?.cancel()
                    task = Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        await board.setBrightness(level: board.level(forBrightnessPercent: v))
                    }
                }
        }
    }
}

private struct QuickDisplayToggleRow: View {
    @ObservedObject var board = AppState.shared.board
    @State private var on = true

    var body: some View {
        Toggle("点亮灯板", isOn: Binding(
            get: { on },
            set: { v in
                on = v
                Task { await board.setDisplay(v) }
            }))
    }
}

