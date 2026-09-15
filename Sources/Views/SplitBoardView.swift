import SwiftData
import SwiftUI

/// 拆板设置 + 结果预览。
///
/// 依据 PRD §5.3「拆板」：
/// - 设置：板尺寸（预设 16×16 / 20×20 / 29×29 + 自定义 W×H）、重叠行（默认 0）；
///   实时显示预计拆成几块（`cols × rows`）。
/// - 结果：用拼板布局图展示整体（每块不同描边 + 编号），逐块列出编号/尺寸/用色数/豆子数/接缝提示。
/// - 保存：调 `PatternFactory.saveAllTiles` 保存全部子图。
struct SplitBoardView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let pattern: Pattern

    /// 默认板尺寸（全局设置，供拆板/上传共用）
    @AppStorage("defaultBoardSide") private var defaultBoardSide = 29

    // 设置态
    @State private var boardW = 29
    @State private var boardH = 29
    @State private var overlap = 0
    @State private var showCustom = false

    // 结果态
    @State private var result: BoardSplitter.SplitResult?
    @State private var previewTile: BoardSplitter.SplitTile?
    @State private var savedCount: Int?
    @State private var saveError: String?

    private let presets = [16, 20, 29]

    var body: some View {
        List {
            settingsSection
            if let result {
                if result.tiles.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label(L10n.s("无法拆板"), systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(L10n.s("图纸尺寸或板尺寸不合法（需 > 0）。"))
                        }
                        .frame(maxHeight: 200)
                    }
                } else if !result.needsSplit {
                    singleTileSection(result)
                } else {
                    layoutSection(result)
                    tilesSection(result)
                    saveSection(result)
                }
            }
        }
        .navigationTitle(L10n.s("拆板"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadDefaults)
        .onChange(of: boardW) { _, _ in recompute() }
        .onChange(of: boardH) { _, _ in recompute() }
        .onChange(of: overlap) { _, _ in recompute() }
        .sheet(item: $previewTile) { tile in
            tilePreviewSheet(tile)
        }
        .alert(L10n.s("已保存"), isPresented: Binding(get: { savedCount != nil },
                                            set: { if !$0 { savedCount = nil } })) {
            Button(L10n.s("好")) { dismiss() }
        } message: {
            Text(L10n.p("已保存 {0} 块子图，可在「图纸」中逐块查看与打卡。", "\(savedCount ?? 0)"))
        }
        .alert(L10n.s("保存失败"), isPresented: Binding(get: { saveError != nil },
                                             set: { if !$0 { saveError = nil } })) {
            Button(L10n.s("好"), role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - 设置区

    private var settingsSection: some View {
        Section {
            HStack {
                Text(L10n.s("板尺寸预设"))
                Spacer()
                ForEach(presets, id: \.self) { side in
                    Button("\(side)×\(side)") {
                        boardW = side
                        boardH = side
                        showCustom = false
                        defaultBoardSide = side
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(boardW == side && boardH == side ? .pink : .gray)
                }
            }

            Toggle(L10n.s("自定义板尺寸"), isOn: $showCustom)

            if showCustom {
                Stepper(value: $boardW, in: 1...104) {
                    LabeledContent(L10n.k(L10n.s("板宽")), value: L10n.p("{0} 格", "\(boardW)"))
                }
                Stepper(value: $boardH, in: 1...104) {
                    LabeledContent(L10n.k(L10n.s("板高")), value: L10n.p("{0} 格", "\(boardH)"))
                }
            }

            Stepper(value: $overlap, in: 0...maxOverlap) {
                LabeledContent(L10n.k(L10n.s("重叠行（对齐用）")), value: L10n.p("{0} 行", "\(overlap)"))
            }

            HStack {
                Label(L10n.s("预计拆分为"), systemImage: "square.grid.3x3.square")
                Spacer()
                Text(estimatedText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.pink)
            }
        } header: {
            Text(L10n.s("拆板设置"))
        } footer: {
            Text(L10n.p("默认严格切分（重叠 0）。图纸 {0}×{1} 格。", "\(pattern.width)", "\(pattern.height)"))
        }
    }

    /// 最大可调重叠（最小板边 - 1，且不小于 0），防止步进 ≤ 0
    private var maxOverlap: Int {
        max(0, min(boardW, boardH) - 1)
    }

    private var estimatedText: String {
        let r = BoardSplitter.split(cells: pattern.cells, width: pattern.width, height: pattern.height,
                                    boardW: boardW, boardH: boardH, overlap: overlap)
        guard !r.tiles.isEmpty else { return "—" }
        return L10n.p("{0} × {1} = {2} 块", "\(r.cols)", "\(r.rows)", "\(r.tiles.count)")
    }

    // MARK: - 单块提示

    private func singleTileSection(_ result: BoardSplitter.SplitResult) -> some View {
        Section {
            ContentUnavailableView {
                Label(L10n.s("无需拆分"), systemImage: "checkmark.circle")
            } description: {
                Text(L10n.p("图纸不超过一块板（{0}×{1}），无需拆分。", "\(boardW)", "\(boardH)"))
            }
            .frame(maxHeight: 200)
        }
    }

    // MARK: - 拼板布局图

    private func layoutSection(_ result: BoardSplitter.SplitResult) -> some View {
        Section(L10n.k(L10n.s("拼板布局"))) {
            Canvas { ctx, size in
                drawLayout(ctx: &ctx, size: size, result: result)
            }
            .frame(height: 240)
            .background(Color(white: 0.96))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            Text(L10n.s("虚线为板边界，每块左上角为编号（R行C列）。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func drawLayout(ctx: inout GraphicsContext, size: CGSize, result: BoardSplitter.SplitResult) {
        let totalW = CGFloat(result.sourceWidth)
        let totalH = CGFloat(result.sourceHeight)
        let scale = min(size.width / (totalW + 2), size.height / (totalH + 2))
        let ox = (size.width - totalW * scale) / 2
        let oy = (size.height - totalH * scale) / 2

        // 整体底色
        let bg = CGRect(x: ox, y: oy, width: totalW * scale, height: totalH * scale)
        ctx.fill(Path(bg), with: .color(Color(white: 0.9)))

        // 每块：填充淡色 + 描边 + 编号
        for (i, tile) in result.tiles.enumerated() {
            let rect = CGRect(x: ox + CGFloat(tile.x0) * scale,
                              y: oy + CGFloat(tile.y0) * scale,
                              width: CGFloat(tile.width) * scale,
                              height: CGFloat(tile.height) * scale)
            let hue = Double(i % 8) / 8.0
            ctx.fill(Path(rect), with: .color(Color(hue: hue, saturation: 0.25, brightness: 0.95)))
            ctx.stroke(Path(rect), with: .color(.pink), lineWidth: 1.2)

            // 编号
            let label = Text(tile.index)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
            ctx.draw(label, at: CGPoint(x: rect.minX + rect.width / 2, y: rect.minY + 10))
        }
    }

    // MARK: - 子块列表

    private func tilesSection(_ result: BoardSplitter.SplitResult) -> some View {
        Section(L10n.pk(L10n.s("子块（{0} 块）"), "\(result.tiles.count)")) {
            ForEach(result.tiles, id: \.index) { tile in
                Button {
                    previewTile = tile
                } label: {
                    HStack(spacing: 12) {
                        // 缩略图
                        Image(uiImage: PatternRenderer.renderThumb(cells: tile.cells,
                                                                   width: tile.width,
                                                                   height: tile.height,
                                                                   size: 48))
                            .resizable()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(tile.index)
                                .font(.subheadline.monospaced().bold())
                            Text(L10n.p("{0}×{1} · {2} 色 · {3} 颗", "\(tile.width)", "\(tile.height)", "\(tile.colorCount)", "\(tile.beadTotal)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !tile.edgeHints.isEmpty {
                                Text(tile.edgeHints.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.pink)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 保存区

    private func saveSection(_ result: BoardSplitter.SplitResult) -> some View {
        Section {
            Button {
                saveAll(result)
            } label: {
                Label(L10n.p("保存全部子图（{0} 块）", "\(result.tiles.count)"), systemImage: "square.and.arrow.down")
                    .font(.headline)
            }
        } footer: {
            Text(L10n.s("每块子图独立保存为图纸，可逐块上板拼、逐块打卡。"))
        }
    }

    // MARK: - 单块预览

    private func tilePreviewSheet(_ tile: BoardSplitter.SplitTile) -> some View {
        NavigationStack {
            List {
                Section(L10n.k(L10n.s("预览"))) {
                    GridView(cells: tile.cells, width: tile.width, height: tile.height)
                        .frame(maxHeight: 320)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                Section(L10n.k(L10n.s("信息"))) {
                    LabeledContent(L10n.k(L10n.s("编号")), value: tile.index)
                    LabeledContent(L10n.k(L10n.s("尺寸")), value: "\(tile.width) × \(tile.height)")
                    LabeledContent(L10n.k(L10n.s("豆子总数")), value: L10n.p("{0} 颗", "\(tile.beadTotal)"))
                    LabeledContent(L10n.k(L10n.s("使用颜色")), value: L10n.p("{0} 种", "\(tile.colorCount)"))
                    if !tile.edgeHints.isEmpty {
                        LabeledContent(L10n.k(L10n.s("接缝")), value: tile.edgeHints.joined(separator: " / "))
                    }
                }
                Section(L10n.k(L10n.s("用色清单"))) {
                    ForEach(tile.beadCounts, id: \.color.id) { item in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(item.color.color)
                                .frame(width: 26, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.3)))
                            Text("Mard \(item.color.mard)")
                                .font(.subheadline.monospaced())
                            Spacer()
                            Text(L10n.p("{0} 颗", "\(item.count)"))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(tile.index)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.s("完成")) { previewTile = nil }
                }
            }
        }
    }

    // MARK: - 动作

    private func loadDefaults() {
        let side = max(1, defaultBoardSide)
        boardW = side
        boardH = side
        recompute()
    }

    private func recompute() {
        // 板变小后重叠可能越界，先钳制
        if overlap > maxOverlap { overlap = maxOverlap }
        result = BoardSplitter.split(cells: pattern.cells,
                                     width: pattern.width,
                                     height: pattern.height,
                                     boardW: boardW,
                                     boardH: boardH,
                                     overlap: overlap)
    }

    private func saveAll(_ result: BoardSplitter.SplitResult) {
        guard !result.tiles.isEmpty else { return }
        let created = PatternFactory.saveAllTiles(result, from: pattern, context: context)
        guard !created.isEmpty else {
            saveError = L10n.s("未生成任何子图，请检查图纸数据。")
            return
        }
        do {
            try context.save()
            savedCount = created.count
        } catch {
            saveError = L10n.p("保存失败：{0}", "\(error.localizedDescription)")
        }
    }
}
