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
        Form {
            Section("选择照片") {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label(image == nil ? "从相册选择" : "重新选择", systemImage: "photo.on.rectangle.angled")
                }
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            if image != nil {
                Section("转换参数") {
                    VStack(alignment: .leading) {
                        LabeledContent("尺寸（最大边格数）", value: "\(maxSide) 格")
                        Slider(value: Binding(
                            get: { Double(maxSide) },
                            set: { maxSide = Int($0) }), in: 16...104, step: 4)
                    }
                    Picker("颜色数量", selection: $colorLimit) {
                        Text("全部（295 色）").tag(0)
                        Text("≤ 64 色").tag(64)
                        Text("≤ 48 色").tag(48)
                        Text("≤ 32 色").tag(32)
                        Text("≤ 24 色").tag(24)
                        Text("≤ 16 色").tag(16)
                    }
                    Toggle("白底转空格", isOn: $whiteToEmpty)
                        .help("适合 logo、线稿等白底图")
                    Button {
                        convert()
                    } label: {
                        if converting {
                            HStack { ProgressView().controlSize(.small); Text("转换中…") }
                        } else {
                            Label("开始转换", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(converting)
                }

                if let result {
                    Section("预览") {
                        GridView(cells: result.cells, width: result.width, height: result.height)
                            .frame(maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        LabeledContent("图纸尺寸", value: "\(result.width) × \(result.height)")
                        LabeledContent("使用颜色", value: "\(beadCounts.count) 种")
                        LabeledContent("豆子总数", value: "\(result.cells.filter { $0 > 0 }.count) 颗")
                    }

                    boardSizeSection(result)
                    saveSection(result)
                }
            }
        }
        .navigationTitle("照片转图纸")
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

    // MARK: - 尺寸分离设置区

    /// 实际拼板设置（可折叠）：板 W×H + 偏移 X/Y（PRD §5.4）。
    ///
    /// 语义（架构师 §A.4.1，**必须遵循**）：
    /// - `width/height` = 图纸行列数（cells 一律为**图纸大小**，不含空白区）；
    /// - `boardWidth/boardHeight + boardOffsetX/Y` = 图纸在实体板上的落位；
    /// - 空白区由"板尺寸 − 图纸尺寸"隐含表达，**不把 cells 扩成板大小**（空区为空格，不点灯、不计豆量）。
    private func boardSizeSection(_ result: PixelConverter.Result) -> some View {
        Section {
            Toggle("设置实际拼板尺寸", isOn: $useBoard)
            if useBoard {
                Stepper(value: $boardW, in: max(result.width, 1)...104) {
                    LabeledContent("板宽", value: "\(boardW) 格")
                }
                Stepper(value: $boardH, in: max(result.height, 1)...104) {
                    LabeledContent("板高", value: "\(boardH) 格")
                }
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
                Stepper(value: $offsetY, in: 0...max(0, boardH - result.height)) {
                    LabeledContent("垂直偏移", value: "\(offsetY) 格")
                }
            }
        } header: {
            Text("实际拼板（可选）")
        } footer: {
            Text(useBoard
                 ? "图纸 \(result.width)×\(result.height) 落在 \(boardW)×\(boardH) 板上，空白区视为空格（不点灯）。"
                 : "默认板尺寸与图纸一致。小图也可放到大板上指定位置。")
        }
    }

    private func saveSection(_ result: PixelConverter.Result) -> some View {
        Section("保存") {
            TextField("图纸名称", text: $name)
            Button {
                save(result)
            } label: {
                Label("保存图纸", systemImage: "square.and.arrow.down")
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
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
