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

    // T04：PDF 导出 / 文件夹 / 标签
    @State private var pdfURL: URL?
    @State private var showMoveFolder = false
    @State private var showTagEditor = false
    @State private var newTagText = ""
    @Query private var folders: [PatternFolder]

    // 板子引导状态
    @State private var guideRow = 0
    @State private var guideColorId: Int? = nil
    @State private var showGuideColorPicker = false
    @State private var boardBusy = false
    /// 快速发送面板（完整预览 / 分色点亮）
    @State private var sendSheetPattern: Pattern?

    // 拼豆模式（图纸 Tab 的网格显示选项）
    /// 格内显示 Mard 色号（放大后可见）
    @State private var showLabels = true
    /// 白色模式：全部有色格去色显示，只看形状
    @State private var whiteMode = false
    /// 显示高亮色号（其余弱化）
    @State private var highlightColorId: Int? = nil

    enum Mode: String, CaseIterable {
        case pattern = "图纸"
        case progress = "进度"
        case guide = "板子引导"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.s("模式"), selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text(L10n.s($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            switch mode {
            case .pattern: patternTab
            case .progress: progressTab
            case .guide: guideTab
            }
        }
        .navigationTitle(pattern.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sendSheetPattern) { p in
            BoardSendSheet(pattern: p)
        }
        .toolbar {
            // 右上角一键连接（全局统一组件）
            ToolbarItem(placement: .topBarTrailing) {
                BoardConnectCapsule()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        sendSheetPattern = pattern
                    } label: {
                        Label(L10n.s("开始拼豆（发送拼豆板）"), systemImage: "lightbulb.max")
                    }
                    Button {
                        renameText = pattern.name
                        showRename = true
                    } label: {
                        Label(L10n.s("重命名"), systemImage: "pencil")
                    }
                    Button {
                        UIPasteboard.general.string = PatternRenderer.beadListText(
                            name: pattern.name, cells: pattern.cells)
                        toast = L10n.s("豆子清单已复制")
                    } label: {
                        Label(L10n.s("复制豆子清单"), systemImage: "doc.on.doc")
                    }
                    NavigationLink {
                        StockEstimateView(pattern: pattern)
                    } label: {
                        Label(L10n.s("消耗预估"), systemImage: "shippingbox")
                    }
                    NavigationLink {
                        SplitBoardView(pattern: pattern)
                    } label: {
                        Label(L10n.s("拆板"), systemImage: "square.split.2x2")
                    }
                    ShareLink(item: Image(uiImage: exportImage),
                              preview: SharePreview(pattern.name, image: Image(uiImage: exportImage))) {
                        Label(L10n.s("导出图纸图片"), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        exportPDF()
                    } label: {
                        Label(L10n.s("导出 PDF"), systemImage: "doc.richtext")
                    }
                    if let pdfURL {
                        ShareLink(item: pdfURL) {
                            Label(L10n.p("分享 PDF（{0}.pdf）", "\(pattern.name)"), systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                    Button {
                        showMoveFolder = true
                    } label: {
                        Label(L10n.s("移动到文件夹"), systemImage: "folder")
                    }
                    Button {
                        showTagEditor = true
                    } label: {
                        Label(L10n.s("编辑标签"), systemImage: "tag")
                    }
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label(L10n.s("清空拼制进度"), systemImage: "arrow.counterclockwise")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(L10n.s("删除作品"), systemImage: "trash")
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
        .alert(L10n.s("重命名"), isPresented: $showRename) {
            TextField(L10n.s("名称"), text: $renameText)
            Button(L10n.s("确定")) {
                let t = renameText.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { pattern.name = t; pattern.touch() }
            }
            Button(L10n.s("取消"), role: .cancel) {}
        }
        .sheet(isPresented: $showMoveFolder) {
            MoveFolderSheet(pattern: pattern, folders: folders)
        }
        .sheet(isPresented: $showTagEditor) {
            TagEditorSheet(pattern: pattern)
        }
        .confirmationDialog(L10n.s("清空拼制进度？"), isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button(L10n.s("清空"), role: .destructive) { pattern.resetProgress() }
            Button(L10n.s("取消"), role: .cancel) {}
        } message: {
            Text(L10n.s("所有已拼标记将被清除"))
        }
        .confirmationDialog(L10n.s("删除作品？"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L10n.s("删除"), role: .destructive) {
                context.delete(pattern)
                dismiss()
            }
            Button(L10n.s("取消"), role: .cancel) {}
        } message: {
            Text(L10n.p("「{0}」及其进度将被永久删除", "\(pattern.name)"))
        }
    }

    // MARK: - 图纸 Tab

    private var patternTab: some View {
        List {
            if pattern.isTile {
                Section {
                    Label(L10n.p("属于「{0}」的第 {1} 块", "\(pattern.name.replacingOccurrences(of: " \(pattern.tileIndex ?? "")", with: ""))", "\(pattern.tileIndex ?? "")"),
                          systemImage: "square.split.2x2")
                        .font(.subheadline)
                        .foregroundStyle(.pink)
                }
            }

            Section {
                ProgressGridView(cells: pattern.cells, width: pattern.width, height: pattern.height,
                                  placed: pattern.placed,
                                  showLabels: showLabels,
                                  whiteMode: whiteMode,
                                  highlightColorId: highlightColorId,
                                  onTap: markMode ? { i in toggleCell(i) } : nil)
                    .frame(maxHeight: 380)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .overlay(alignment: .topTrailing) {
                        if markMode {
                            Label(L10n.s("打卡模式"), systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                                .padding(14)
                        }
                    }

                // 显示控制：高亮模式 / 色号 / 全显（对标 PIXDOU 拼豆模式）
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(L10n.s("高亮模式"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(L10n.s("高亮模式"), selection: $whiteMode) {
                            Text(L10n.s("原色")).tag(false)
                            Text(L10n.s("白色")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 170)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        chipButton(L10n.s("色号"), icon: "textformat.abc", active: showLabels) {
                            showLabels.toggle()
                        }
                        chipButton(L10n.s("全显"), icon: "arrow.up.left.and.arrow.down.right", active: false) {
                            highlightColorId = nil
                            whiteMode = false
                        }
                        if let hi = highlightColorId, let c = BeadPalette.byId[hi] {
                            HStack(spacing: 5) {
                                BeadDot(color: c, size: 16)
                                Text(L10n.p("仅 {0}", "\(c.mard)"))
                                    .font(.caption.bold())
                                Button {
                                    highlightColorId = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill").font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                            .foregroundStyle(Theme.accent)
                        }
                        Spacer()
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 10, trailing: 14))
            } header: {
                Text(L10n.s("图纸 · 拼豆模式"))
            } footer: {
                Text(L10n.s("放大网格后格内会显示 Mard 色号；「白色」模式去掉颜色只看形状，适合确认轮廓。"))
            }

            // 色号统计条：点色块高亮该色（对标 PIXDOU「色号统计 / 点击下方色块高亮显示」）
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(pattern.beadCounts, id: \.color.id) { item in
                            colorStatChip(item.color, count: item.count)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
            } header: {
                Text(L10n.p("色号统计（共 {0} 种颜色）", "\(pattern.beadCounts.count)"))
            } footer: {
                Text(L10n.s("点击下方色块高亮显示；再点一次或点「全显」恢复。"))
            }

            Section {
                HStack(spacing: 14) {
                    statCell(L10n.s("已拼"), "\(pattern.placedCount)")
                    statCell(L10n.s("总数"), "\(pattern.totalBeads)")
                    statCell(L10n.s("剩余"), "\(pattern.totalBeads - pattern.placedCount)")
                    statCell(L10n.s("颜色"), "\(pattern.beadCounts.count)")
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
                Toggle(L10n.s("逐格打卡模式（点击格子标记已拼）"), isOn: $markMode)
                NavigationLink {
                    EditorView(pattern: pattern)
                } label: {
                    Label(L10n.s("编辑图纸"), systemImage: "paintbrush")
                }
            }

            if let photo = pattern.resultPhoto, let ui = UIImage(data: photo) {
                Section(L10n.k("成品")) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Button(role: .destructive) {
                        pattern.resultPhoto = nil
                    } label: {
                        Label(L10n.s("移除成品照片"), systemImage: "trash")
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
        Section(L10n.k("成品照片")) {
            PhotosPicker(selection: $resultItem, matching: .images) {
                Label(pattern.resultPhoto == nil ? L10n.s("添加成品照片") : L10n.s("更换成品照片"),
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
                    Text(L10n.p("{0} / {1} 颗 · {2}%", "\(pattern.placedCount)", "\(pattern.totalBeads)", "\(Int(pattern.progressPercent * 100))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if pattern.status == .done {
                    Label(L10n.p("已完成！{0}", "\(pattern.completedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")"),
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text(L10n.s("总进度"))
            }

            Section {
                let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(0..<pattern.height, id: \.self) { row in
                        let done = pattern.isRowPlaced(row)
                        Button {
                            toggleRow(row)
                        } label: {
                            Text(L10n.p("第{0}行", "\(row + 1)"))
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
                Text(L10n.s("逐行打卡"))
            } footer: {
                Text(L10n.s("拼完一行点一下；点错了再点一次即可撤销该行。"))
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
                            Text(L10n.p("{0} / {1} 颗", "\(placedN)", "\(item.count)"))
                                .font(.caption)
                                .foregroundStyle(colorDone ? .green : .secondary)
                        }
                        Spacer()
                        if colorDone {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button(L10n.s("全拼完")) {
                                pattern.placeColor(colorId: item.color.id)
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text(L10n.s("分色打卡"))
            } footer: {
                Text(L10n.s("一种颜色一次买齐、一次拼完时，用右侧按钮整色打卡。"))
            }
        }
    }

    // MARK: - 板子引导 Tab

    private var guideTab: some View {
        List {
            if !board.isConnected {
                Section {
                    ContentUnavailableView {
                        Label(L10n.s("拼豆板未连接"), systemImage: "lightbulb")
                    } description: {
                        Text(L10n.s("点右上角「连接」按钮连上拼豆板后，可以在这里点亮当前行辅助定位。"))
                    }
                    .frame(maxHeight: 260)
                }
            } else {
                Section(L10n.k("当前行引导")) {
                    HStack {
                        Button {
                            if guideRow > 0 { guideRow -= 1; sendRowGuide() }
                        } label: {
                            Image(systemName: "chevron.left.circle.fill").font(.title2)
                        }
                        .disabled(guideRow <= 0 || boardBusy)

                        Spacer()
                        VStack(spacing: 2) {
                            Text(L10n.p("第 {0} / {1} 行", "\(guideRow + 1)", "\(pattern.height)"))
                                .font(.title3.monospacedDigit().bold())
                            if pattern.isRowPlaced(guideRow) {
                                Text(L10n.s("本行已拼完")).font(.caption).foregroundStyle(.green)
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
                            Text(L10n.p("仅显示 Mard {0}", "\(c.mard)"))
                                .font(.subheadline)
                            Spacer()
                            Button(L10n.s("取消分色")) {
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
                        Label(L10n.s("点亮当前行（含相邻行微亮）"), systemImage: "light.beacon.max")
                    }
                    .disabled(boardBusy)

                    Button {
                        Task { await sendFullPreview() }
                    } label: {
                        Label(L10n.s("发送完整预览图"), systemImage: "square.grid.3x3")
                    }
                    .disabled(boardBusy)

                    Menu {
                        ForEach(pattern.beadCounts, id: \.color.id) { item in
                            Button {
                                guideColorId = item.color.id
                                sendRowGuide()
                            } label: {
                                HStack {
                                    Text(L10n.p("仅 {0}（{1} 颗）", "\(item.color.mard)", "\(item.count)"))
                                }
                            }
                        }
                    } label: {
                        Label(L10n.s("按颜色过滤当前行…"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .disabled(pattern.beadCounts.isEmpty)
                }

                // 分色引导（全图）：选一种颜色，灯板全图只亮该色的位置（PIXDOU 同款）
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pattern.usageRows) { row in
                                colorChip(row)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                    }

                    HStack(spacing: 10) {
                        Button {
                            sendColorGuide()
                        } label: {
                            Label(L10n.s("点亮该色"), systemImage: "lightbulb.max.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .frame(height: 20)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(
                                    guideColorId == nil ? AnyShapeStyle(Color.secondary.opacity(0.35)) : AnyShapeStyle(Theme.sky),
                                    in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(guideColorId == nil || boardBusy)

                        Button {
                            finishColorAndAdvance()
                        } label: {
                            Label(L10n.s("此色拼完 → 下一色"), systemImage: "checkmark.circle.badge.arrow.forward")
                                .font(.subheadline.bold())
                                .foregroundStyle(Theme.accent)
                                .frame(height: 20)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(Theme.accent.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(guideColorId == nil || boardBusy)
                    }
                } header: {
                    Text(L10n.s("分色引导 · 全图点亮"))
                } footer: {
                    Text(L10n.s("只点亮选中色号在全图中的位置。逐颗拼完可到「进度」打卡；整色拼完点「此色拼完」自动打卡并点亮下一色（未拼颗数多的优先）。"))
                }

                Section {
                    Button {
                        finishRowAndAdvance()
                    } label: {
                        Label(L10n.s("本行拼完 → 下一行"), systemImage: "checkmark.circle.badge.arrow.forward")
                            .font(.headline)
                    }
                    .disabled(boardBusy || guideRow >= pattern.height - 1 && pattern.isRowPlaced(guideRow))
                } header: {
                    Text(L10n.s("打卡 + 前进"))
                } footer: {
                    Text(L10n.s("拼完当前行后点击，会自动标记该行已拼并点亮下一行。"))
                }

                if board.isSending {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.p("正在发送引导图… {0}%", "\(Int(board.sendProgress * 100))"))
                                .font(.subheadline)
                            ProgressView(value: board.sendProgress)
                        }
                    }
                }

                quickControls
            }
        }
    }

    private var quickControls: some View {
        Section(L10n.k("快捷控制")) {
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

    /// 小胶囊开关（色号 / 全显）
    private func chipButton(_ title: String, icon: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2.bold())
                Text(title).font(.caption.weight(active ? .bold : .regular))
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(active ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.cardFill), in: Capsule())
            .foregroundStyle(active ? .white : Color.primary)
            .overlay(Capsule().stroke(active ? Color.clear : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    /// 色号统计块：色块 + 色号 + 数量；点按高亮该色
    private func colorStatChip(_ color: BeadColor, count: Int) -> some View {
        let active = highlightColorId == color.id
        return Button {
            highlightColorId = active ? nil : color.id
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.color)
                    .frame(width: 46, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(active ? Theme.accent : Color.gray.opacity(0.25),
                                    lineWidth: active ? 3 : 1)
                    )
                Text(color.mard)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(active ? Theme.accent : Color.primary)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56)
            .padding(.vertical, 6)
            .background(active ? AnyShapeStyle(Theme.accent.opacity(0.10)) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
        Haptics.tap()
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

    /// 全图分色引导：灯板只亮选中色号的位置（不分行走）
    private func sendColorGuide() {
        guard let cid = guideColorId else { return }
        Task {
            boardBusy = true
            defer { boardBusy = false }
            let rgb = BoardImageBuilder.colorGuide(
                width: pattern.width, height: pattern.height, cells: pattern.cells,
                colorId: cid, placed: pattern.placed)
            try? await board.sendImage(width: pattern.width, height: pattern.height, rgb: rgb)
        }
    }

    /// 分色引导的色号 chip
    private func colorChip(_ row: BeadUsageRow) -> some View {
        let active = guideColorId == row.color.id
        return Button {
            guideColorId = row.color.id
        } label: {
            HStack(spacing: 6) {
                BeadDot(color: row.color, size: 20)
                Text(row.color.mard)
                    .font(.caption.monospaced().weight(.semibold))
                Text(L10n.p("剩{0}", "\(row.remaining)"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(active ? AnyShapeStyle(Theme.brand.opacity(0.14)) : AnyShapeStyle(Theme.cardFill), in: Capsule())
            .overlay(Capsule().stroke(active ? Theme.accent : Color.secondary.opacity(0.15), lineWidth: active ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    /// 整色打卡并点亮下一色（未拼颗数最多的优先）
    private func finishColorAndAdvance() {
        guard let cid = guideColorId else { return }
        pattern.placeColor(colorId: cid)
        if let next = pattern.usageRows.first(where: { $0.remaining > 0 && $0.color.id != cid }) {
            guideColorId = next.color.id
        }
        sendColorGuide()
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

    /// 导出 A4 分页 PDF 到临时文件（供上方 `ShareLink` 分享；T04）。
    private func exportPDF() {
        var opts = PDFExporter.PDFOptions()
        opts.title = pattern.name
        opts.showLabels = true
        opts.showLegend = true
        opts.boardSize = pattern.effectiveBoardWidth
        if let url = PDFExporter.exportToTempFile(cells: pattern.cells,
                                                  width: pattern.width,
                                                  height: pattern.height,
                                                  options: opts,
                                                  name: pattern.name) {
            pdfURL = url
            toast = L10n.s("PDF 已生成，可点「分享 PDF」导出")
        } else {
            toast = L10n.s("PDF 生成失败，请重试")
        }
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

// MARK: - 进度感知网格（已拼格子暗显 + 格内色号 + 原色/白色/高亮）

/// 图纸网格（对标 PIXDOU「拼豆模式」）：
/// - 已拼格子暗显；
/// - `showLabels`：格子足够大时在格内绘制 Mard 色号（放大后可见，无需来回对图例）；
/// - `whiteMode`：所有有色格统一白色（去掉颜色只看形状结构），空格保持浅灰；
/// - `highlightColorId`：只强调该色号，其余弱化（配合底部色号统计条点选）。
struct ProgressGridView: View {
    let cells: [Int]
    let width: Int
    let height: Int
    var placed: [Bool]? = nil
    var showLabels: Bool = false
    var whiteMode: Bool = false
    var highlightColorId: Int? = nil
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
                        if v > 0 && (whiteMode || (highlightColorId != nil && v != highlightColorId)) {
                            // 白色模式 / 非高亮色号：去色显示（保留微弱色相以区分相邻格）
                            color = whiteMode ? Color.white : color.opacity(0.18)
                        }
                        if v > 0, let placed, i < placed.count, placed[i] {
                            color = color.opacity(0.30)
                        }
                        let rect = CGRect(x: ox + CGFloat(x) * side, y: oy + CGFloat(y) * side,
                                          width: side + 0.5, height: side + 0.5)
                        ctx.fill(Path(rect), with: .color(color))

                        // 空格在白色模式下需描边，否则与白格无法区分
                        if whiteMode && v == 0 {
                            ctx.stroke(Path(rect.insetBy(dx: 0.25, dy: 0.25)),
                                       with: .color(.gray.opacity(0.18)), lineWidth: 0.5)
                        }
                    }
                }

                // 格内色号（格子 ≥ 20pt 才画，避免糊成一片）
                if showLabels && side >= 20 {
                    let font = Font.system(size: min(side * 0.30, 11), weight: .semibold, design: .monospaced)
                    for y in 0..<height {
                        for x in 0..<width {
                            let i = y * width + x
                            let v = cells[i]
                            guard v > 0, let c = BeadPalette.byId[v] else { continue }
                            let iDim = highlightColorId == nil || v == highlightColorId
                            let text = Text(c.mard)
                                .font(font)
                                .foregroundStyle(c.brightness > 0.62 ? Color.black.opacity(iDim ? 0.75 : 0.25)
                                                                     : Color.white.opacity(iDim ? 0.92 : 0.35))
                            ctx.draw(text, at: CGPoint(x: ox + (CGFloat(x) + 0.5) * side,
                                                       y: oy + (CGFloat(y) + 0.5) * side),
                                     anchor: .center)
                        }
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
            LabeledContent(L10n.k("板子亮度"), value: "\(pct)%")
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
        Toggle(L10n.s("点亮灯板"), isOn: Binding(
            get: { on },
            set: { v in
                on = v
                Task { await board.setDisplay(v) }
            }))
    }
}

// MARK: - 移动到文件夹（T04）

/// 移动图纸到文件夹的弹窗：列出全部文件夹 + 「移出文件夹」。
struct MoveFolderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let pattern: Pattern
    let folders: [PatternFolder]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        pattern.assignFolder(nil)
                        dismiss()
                    } label: {
                        HStack {
                            Label(L10n.s("移出文件夹"), systemImage: "tray")
                            Spacer()
                            if pattern.folderId == nil {
                                Image(systemName: "checkmark").foregroundStyle(.pink)
                            }
                        }
                    }
                }
                Section(L10n.k("文件夹")) {
                    if folders.isEmpty {
                        Text(L10n.s("还没有文件夹，可到「图纸 → 文件夹」新建"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(folders) { folder in
                            Button {
                                pattern.assignFolder(folder.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Label(folder.name, systemImage: "folder")
                                    Spacer()
                                    if pattern.folderId == folder.id {
                                        Image(systemName: "checkmark").foregroundStyle(.pink)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.s("移动到文件夹"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.s("完成")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - 编辑标签（T04）

/// 编辑图纸标签的弹窗：展示现有标签（可删）+ 输入新标签（可加）。
struct TagEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let pattern: Pattern

    @State private var newTag = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if pattern.tags.isEmpty {
                        Text(L10n.s("还没有标签")).foregroundStyle(.secondary)
                    } else {
                        ForEach(pattern.tags, id: \.self) { tag in
                            HStack {
                                Label(tag, systemImage: "tag.fill")
                                Spacer()
                                Button(role: .destructive) {
                                    pattern.removeTag(tag)
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text(L10n.s("现有标签"))
                }

                Section {
                    HStack {
                        TextField(L10n.s("输入标签"), text: $newTag)
                        Button(L10n.s("添加")) {
                            pattern.addTag(newTag)
                            newTag = ""
                        }
                        .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text(L10n.s("新增标签"))
                } footer: {
                    Text(L10n.s("标签用于「图纸 → 标签」分段筛选。"))
                }
            }
            .navigationTitle(L10n.s("编辑标签"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.s("完成")) { dismiss() }
                }
            }
        }
    }
}

