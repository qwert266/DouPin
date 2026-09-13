import PhotosUI
import SwiftData
import SwiftUI

struct ConvertView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// 若从文件夹进入，保存的图纸自动归入该文件夹（T04 文件夹内上传；PRD §5.10）
    var bindFolderId: UUID? = nil

    @State private var pickedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var maxSide = 28
    @State private var colorLimit = 24
    @State private var whiteToEmpty = true
    @State private var autoLevels = true
    @State private var converting = false
    @State private var result: PixelConverter.Result?
    @State private var name = ""
    @State private var savedID: UUID?

    // MARK: - 尺寸分离（PRD §5.4）：图纸行列数 vs 实际拼板 + 偏移
    /// 是否启用「实际拼板」设置（关闭 = 板尺寸同图纸尺寸）
    @State private var useBoard = false
    /// 板宽（列数）
    @State private var boardW = 29
    /// 板高（行数）
    @State private var boardH = 29
    /// 图纸在板上的偏移
    @State private var offsetX = 0
    @State private var offsetY = 0

    /// 默认板尺寸（全局设置）
    @AppStorage("defaultBoardSide") private var defaultBoardSide = 29

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                photoSection
                if image != nil {
                    paramSection
                if let result {
                    previewSection(result)
                    paletteListSection(result)
                    boardSizeCard(result)
                    saveCard(result)
                }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Theme.pageFill)
        .navigationTitle("照片转图纸")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            result = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    image = ui
                    name = name.isEmpty ? "照片图纸 \(Date().formatted(.dateTime.month().day()))" : name
                }
            }
        }
        .alert("已保存", isPresented: Binding(get: { savedID != nil }, set: { if !$0 { savedID = nil } })) {
            Button("好", role: .cancel) { savedID = nil }
        } message: {
            Text("图纸已保存，可在「图纸」标签中查看")
        }
    }

    // MARK: - 选图卡

    private var photoSection: some View {
        VStack(spacing: 12) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("重新选择", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.accent)
                }
            } else {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Theme.mint)
                            BeadDots()
                                .padding(.top, 14).padding(.leading, 16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(height: 110)
                        Text("点击选择照片")
                            .font(.headline)
                        Text("自动匹配 295 色豆号，亮度和色彩智能校正")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 参数卡

    private var paramSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("转换参数", systemImage: "slider.horizontal.3")
                .font(.subheadline.bold())

            // 尺寸滑杆
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("图纸尺寸").font(.subheadline)
                    Spacer()
                    Text("\(maxSide) 格").font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                Slider(value: Binding(
                    get: { Double(maxSide) },
                    set: { maxSide = Int($0) }), in: 16...104, step: 4)
                    .tint(Theme.accent)
            }

            // 色数胶囊
            VStack(alignment: .leading, spacing: 8) {
                Text("颜色数量").font(.subheadline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        colorChip(value: 16, label: "16 色")
                        colorChip(value: 24, label: "24 色")
                        colorChip(value: 32, label: "32 色")
                        colorChip(value: 48, label: "48 色")
                        colorChip(value: 64, label: "64 色")
                        colorChip(value: 0, label: "295 色")
                    }
                }
            }

            Toggle("自动亮度校正", isOn: $autoLevels)
                .font(.subheadline)
            Toggle("白底转空格", isOn: $whiteToEmpty)
                .font(.subheadline)

            // 转换按钮
            Button {
                convert()
            } label: {
                HStack(spacing: 8) {
                    if converting {
                        ProgressView().tint(.white)
                        Text("转换中…")
                    } else {
                        Image(systemName: "wand.and.stars")
                        Text("开始转换")
                    }
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.brand, in: Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
            .disabled(converting)
            .opacity(converting ? 0.6 : 1)
        }
        .cardStyle()
    }

    private func colorChip(value: Int, label: String) -> some View {
        Button {
            colorLimit = value
        } label: {
            Text(label)
                .font(.caption.weight(colorLimit == value ? .semibold : .regular))
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(colorLimit == value
                            ? AnyShapeStyle(Theme.brand)
                            : AnyShapeStyle(Theme.cardFill), in: Capsule())
                .foregroundStyle(colorLimit == value ? .white : Color.primary)
                .overlay(Capsule().stroke(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 预览卡

    private func previewSection(_ result: PixelConverter.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("转换预览", systemImage: "eye")
                .font(.subheadline.bold())
            GridView(cells: result.cells, width: result.width, height: result.height)
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack(spacing: 0) {
                statBlock("\(result.width)×\(result.height)", "图纸尺寸")
                divider
                statBlock("\(beadCounts.count)", "使用颜色")
                divider
                statBlock("\(result.cells.filter { $0 > 0 }.count)", "豆子总数")
            }
        }
        .cardStyle()
    }

    private var divider: some View {
        Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1, height: 28)
    }

    // MARK: - 用色清单（备料单，对标 PIXDOU 出料单）

    private var sortedCounts: [(id: Int, count: Int)] {
        beadCounts.map { (id: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    private func paletteListSection(_ result: PixelConverter.Result) -> some View {
        let items = sortedCounts
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("用色清单", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.bold())
                Spacer()
                Text("共 \(items.count) 色").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(40), id: \.id) { item in
                if let c = BeadPalette.byId[item.id] {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(c.color)
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.25)))
                        Text("Mard \(c.mard)")
                            .font(.subheadline.monospaced().weight(.medium))
                        Spacer()
                        Text("\(item.count) 颗")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if items.count > 40 {
                Text("…等共 \(items.count) 色，保存后可在图纸详情查看完整清单")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .cardStyle()
    }

    private func statBlock(_ value: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.bold().monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 尺寸分离设置卡

    /// 实际拼板设置（可折叠）：板 W×H + 偏移 X/Y（PRD §5.4）。
    ///
    /// 语义（架构师 §A.4.1，**必须遵循**）：
    /// - `width/height` = 图纸行列数（cells 一律为**图纸大小**，不含空白区）；
    /// - `boardWidth/boardHeight + boardOffsetX/Y` = 图纸在实体板上的落位；
    /// - 空白区由"板尺寸 − 图纸尺寸"隐含表达，**不把 cells 扩成板大小**（空区为空格，不点灯、不计豆量）。
    private func boardSizeCard(_ result: PixelConverter.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("设置实际拼板尺寸", isOn: $useBoard)
                .font(.subheadline.weight(.medium))
            if useBoard {
                Stepper(value: $boardW, in: max(result.width, 1)...104) {
                    LabeledContent("板宽", value: "\(boardW) 格")
                }
                .font(.subheadline)
                Stepper(value: $boardH, in: max(result.height, 1)...104) {
                    LabeledContent("板高", value: "\(boardH) 格")
                }
                .font(.subheadline)
                HStack {
                    Button {
                        offsetX = 0; offsetY = 0
                    } label: {
                        Label("左上角", systemImage: "arrow.up.left")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Button {
                        offsetX = max(0, (boardW - result.width) / 2)
                        offsetY = max(0, (boardH - result.height) / 2)
                    } label: {
                        Label("居中", systemImage: "rectangle.center.inset.filled")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Stepper(value: $offsetX, in: 0...max(0, boardW - result.width)) {
                    LabeledContent("水平偏移", value: "\(offsetX) 格")
                }
                .font(.subheadline)
                Stepper(value: $offsetY, in: 0...max(0, boardH - result.height)) {
                    LabeledContent("垂直偏移", value: "\(offsetY) 格")
                }
                .font(.subheadline)
            }
            Text(useBoard
                 ? "图纸 \(result.width)×\(result.height) 落在 \(boardW)×\(boardH) 板上，空白区视为空格（不点灯）。"
                 : "默认板尺寸与图纸一致。小图也可放到大板上指定位置。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    // MARK: - 保存卡

    private func saveCard(_ result: PixelConverter.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("图纸名称", text: $name)
                .font(.subheadline)
                .padding(12)
                .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button {
                save(result)
            } label: {
                Label("保存图纸", systemImage: "square.and.arrow.down.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.violet, in: Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
        }
        .cardStyle()
    }

    // MARK: - 数据

    private var beadCounts: [Int: Int] {
        var d: [Int: Int] = [:]
        for c in result?.cells ?? [] where c > 0 { d[c, default: 0] += 1 }
        return d
    }

    // MARK: - 转换（P1-2 修正）

    /// 转换照片 → 网格。
    ///
    /// P1-2 修正：**不再**在 `Task.detached` 里跨 actor 传 `UIImage`（非 `Sendable`，Swift 6 严格并发下不安全）。
    /// 方案：在主线程（`@MainActor`）上**同步**执行转换。
    /// - 理由：`PixelConverter.convert` 主要开销在对 ≤104×104 的网格做 `gw*gh*295` 次最近色匹配，
    ///   量级约 3×10⁶ 次浮点运算，主线程瞬时完成（通常 <50ms），可接受，无需后台线程。
    /// - 且 `UIImage`/`CGImage` 均在 MainActor 使用，**彻底消除跨 actor 传非 Sendable 类型**。
    private func convert() {
        guard let image else { return }
        converting = true
        var opts = PixelConverter.Options()
        opts.maxSide = maxSide
        opts.colorLimit = colorLimit
        opts.whiteToEmpty = whiteToEmpty
        opts.autoLevels = autoLevels
        // MainActor 同步执行（见方法注释）
        result = PixelConverter.convert(image: image, options: opts)
        // 初始化板尺寸默认值（首次）
        if boardW < max(result?.width ?? 1, 1) { boardW = max(defaultBoardSide, result?.width ?? 1) }
        if boardH < max(result?.height ?? 1, 1) { boardH = max(defaultBoardSide, result?.height ?? 1) }
        converting = false
    }

    // MARK: - 保存（含原图 + 尺寸分离）

    /// 保存图纸：写入 cells + 尺寸分离字段 + **原图**（JPEG 长边 ≤2048、质量 0.8）。
    ///
    /// 原图存 `pattern.sourceImageData`，供「原图对比」模式使用（PRD §5.6）。
    private func save(_ result: PixelConverter.Result) {
        guard result.width > 0, result.height > 0 else { return }
        guard let image else { return }   // 无原图则无法保存
        let p = Pattern(name: name, width: result.width, height: result.height,
                        cells: result.cells, source: "photo")
        // 尺寸分离：仅在启用且板可容纳图纸时写入
        if useBoard {
            p.boardWidth = max(result.width, boardW)
            p.boardHeight = max(result.height, boardH)
            p.boardOffsetX = max(0, min(offsetX, p.boardWidth - result.width))
            p.boardOffsetY = max(0, min(offsetY, p.boardHeight - result.height))
        }
        // 存原图（压缩：长边 ≤2048，质量 0.8）
        p.sourceImageData = compressedJPEG(image)
        // 从文件夹进入时自动归入（T04）
        p.folderId = bindFolderId
        context.insert(p)
        savedID = p.id
    }

    /// 把 UIImage 压缩为 JPEG（长边 ≤2048、质量 0.8）。
    ///
    /// - 说明：原图可能很大，先按长边缩放到 ≤2048 再编码，避免 `sourceImageData` 过大。
    /// - 仅在 MainActor 上处理 `UIImage`（不跨 actor 传递）。
    private func compressedJPEG(_ image: UIImage, maxSide: CGFloat = 2048, quality: CGFloat = 0.8) -> Data? {
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return image.jpegData(compressionQuality: quality) }

        // 无需缩放
        if max(w, h) <= maxSide {
            return image.jpegData(compressionQuality: quality)
        }

        // 等比缩放到长边 = maxSide
        let ratio = maxSide / max(w, h)
        let newSize = CGSize(width: floor(w * ratio), height: floor(h * ratio))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: fmt)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
