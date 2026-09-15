import SwiftUI

/// 可复用「多指缩放网格」与「原图对比容器」。
///
/// 依据 PRD §5.6（原图对比）与 §5.7（多指缩放 + 框选）：
/// - `ZoomableGrid`：包住只读网格，支持 `MagnifyGesture`（iOS 17 可用）缩放 + `DragGesture` 平移，
///   放大上限按网格尺寸计算，保证最大可达"单格可见"；双击复位。
/// - `CompareGridView`：左右分屏，左原图、右像素网格，**缩放/平移联动**（共享同一 `scale`/`offset`）。
///
/// 并发约定：全部 `View` 默认 `@MainActor`；不跨 actor 传 `UIImage`。
///
/// 状态归属说明：
/// `ZoomableGrid` 的 `scale`/`offset` 由**外部**通过 `@Binding` 提供。
/// 独立使用时，调用方用 `@State` 自管理；左右联动时，`CompareGridView` 把同一份
/// `@State` 同时绑定给左右两个子网格，实现天然联动。

// MARK: - 缩放网格

/// 多指缩放 + 平移的网格容器。
///
/// - 接收 `cells/width/height` 值类型，便于在编辑页、预览页、对比页复用。
/// - 缩放范围：`1.0 ... maxScale`，其中 `maxScale = max(1, cellVisibleSize / 基础单格边长)`，
///   默认 `cellVisibleSize = 40pt`，保证放大到单格约 40pt 可见。
struct ZoomableGrid: View {
    /// 网格数据（行优先，0 = 空格）
    let cells: [Int]
    /// 网格宽（列数）
    let width: Int
    /// 网格高（行数）
    let height: Int
    /// 是否显示每 10 格辅助线（默认 true）
    var showGuides: Bool = true
    /// 高亮色号（非空时其余色号弱化显示）
    var highlightColorId: Int? = nil
    /// 单格可见时的目标像素边长（用于推导最大缩放，默认 40pt）
    var cellVisibleSize: CGFloat = 40
    /// 是否允许手势缩放/平移（默认 true）
    var gestureEnabled: Bool = true
    /// 变换变化回调（可选，用于外部联动）
    var onTransform: ((_ scale: CGFloat, _ offset: CGSize) -> Void)? = nil

    // 由调用方托管的共享状态
    @Binding var scale: CGFloat
    @Binding var offset: CGSize

    // 手势过程中的基准值
    @State private var baseScale: CGFloat = 1
    @State private var baseOffset: CGSize = .zero

    /// 主构造：外部传入共享 `scale`/`offset`（左右联动核心）。
    init(cells: [Int],
         width: Int,
         height: Int,
         showGuides: Bool = true,
         highlightColorId: Int? = nil,
         cellVisibleSize: CGFloat = 40,
         gestureEnabled: Bool = true,
         scale: Binding<CGFloat>,
         offset: Binding<CGSize>,
         onTransform: ((CGFloat, CGSize) -> Void)? = nil) {
        self.cells = cells
        self.width = width
        self.height = height
        self.showGuides = showGuides
        self.highlightColorId = highlightColorId
        self.cellVisibleSize = cellVisibleSize
        self.gestureEnabled = gestureEnabled
        self._scale = scale
        self._offset = offset
        self.onTransform = onTransform
    }

    var body: some View {
        GeometryReader { geo in
            let baseSide = baseCellSide(in: geo.size)
            let maxScale = maxScaleValue(baseSide: baseSide)

            Canvas { ctx, size in
                drawGrid(ctx: &ctx, size: size, baseSide: baseSide,
                         scale: scale, offset: offset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(gestureEnabled
                     ? magnifyGesture(maxScale: maxScale).simultaneously(with: dragGesture())
                     : nil)
            .onTapGesture(count: 2) { reset() }
            .clipped()
        }
        .background(Color(white: 0.94))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 手势

    /// 缩放手势（iOS 17 `MagnifyGesture`，非旧的 `MagnificationGesture`）
    private func magnifyGesture(maxScale: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let target = baseScale * value.magnification
                scale = min(max(1.0, target), maxScale)
            }
            .onEnded { _ in
                baseScale = scale
                onTransform?(scale, offset)
            }
    }

    /// 平移手势
    private func dragGesture() -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in
                baseOffset = offset
                onTransform?(scale, offset)
            }
    }

    /// 复位缩放/平移（双击或按钮触发）
    func reset() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            offset = .zero
        }
        baseScale = 1
        baseOffset = .zero
        onTransform?(1, .zero)
    }

    // MARK: - 几何计算

    /// 基础单格边长（未缩放时，铺满容器）
    private func baseCellSide(in size: CGSize) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        return min(size.width / CGFloat(width), size.height / CGFloat(height))
    }

    /// 最大缩放：使单格达到 `cellVisibleSize` 像素（至少 1）
    private func maxScaleValue(baseSide: CGFloat) -> CGFloat {
        guard baseSide > 0 else { return 1 }
        return max(1, cellVisibleSize / baseSide)
    }

    // MARK: - 绘制

    private func drawGrid(ctx: inout GraphicsContext,
                          size: CGSize,
                          baseSide: CGFloat,
                          scale: CGFloat,
                          offset: CGSize) {
        guard width > 0, height > 0, cells.count == width * height else { return }
        let side = baseSide * scale
        let gridW = side * CGFloat(width)
        let gridH = side * CGFloat(height)
        let ox = (size.width - gridW) / 2 + offset.width
        let oy = (size.height - gridH) / 2 + offset.height

        for y in 0..<height {
            for x in 0..<width {
                let v = cells[y * width + x]
                var color: Color = v > 0 ? (BeadPalette.byId[v]?.color ?? .clear)
                                         : Color(white: 0.97)
                if let hi = highlightColorId, v != hi {
                    color = v > 0 ? color.opacity(0.22) : color.opacity(0.55)
                }
                let rect = CGRect(x: ox + CGFloat(x) * side,
                                  y: oy + CGFloat(y) * side,
                                  width: side + 0.5, height: side + 0.5)
                ctx.fill(Path(rect), with: .color(color))
            }
        }

        if showGuides && side > 4 {
            var grid = Path()
            for gx in stride(from: 10, to: width, by: 10) {
                let x = ox + CGFloat(gx) * side
                grid.move(to: CGPoint(x: x, y: oy))
                grid.addLine(to: CGPoint(x: x, y: oy + gridH))
            }
            for gy in stride(from: 10, to: height, by: 10) {
                let y = oy + CGFloat(gy) * side
                grid.move(to: CGPoint(x: ox, y: y))
                grid.addLine(to: CGPoint(x: ox + gridW, y: y))
            }
            ctx.stroke(grid, with: .color(.gray.opacity(0.5)), lineWidth: 1)
        }
    }
}

// MARK: - 原图对比容器（左右分屏 + 缩放联动）

/// 原图对比容器：左原图、右像素网格，缩放/平移联动。
///
/// 依据 PRD §5.6：仅对「照片转图纸」来源（`pattern.sourceImageData != nil`）可用；
/// 叠加半透明模式（P1 增强）把右侧网格半透明叠在左侧原图之上。
struct CompareGridView: View {
    /// 像素网格数据
    let cells: [Int]
    /// 网格宽
    let width: Int
    /// 网格高
    let height: Int
    /// 原图数据（JPEG）；为 nil 时显示无原图提示
    let sourceImageData: Data?

    // 共享缩放状态（左右联动核心）
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    // 叠加半透明模式（P1）
    @State private var overlayMode = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle(isOn: $overlayMode) {
                    Label(L10n.s("叠加半透明"), systemImage: "square.on.square.dashed")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                Spacer()
                Button {
                    scale = 1
                    offset = .zero
                } label: {
                    Label(L10n.s("复位"), systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)

            if overlayMode {
                overlayView
            } else {
                splitView
            }
        }
    }

    // MARK: - 左右分屏

    private var splitView: some View {
        HStack(spacing: 6) {
            // 左：原图（读取同一份 scale/offset → 联动）
            ZStack {
                Color(white: 0.95)
                if let data = sourceImageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                } else {
                    noSourcePlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) { tag(L10n.s("原图")) }

            // 右：像素网格（同一份 scale/offset → 联动）
            ZStack {
                if sourceImageData == nil {
                    noSourcePlaceholder
                } else {
                    ZoomableGrid(cells: cells, width: width, height: height,
                                 showGuides: true,
                                 scale: $scale, offset: $offset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { tag(L10n.s("像素图")) }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - 叠加模式

    private var overlayView: some View {
        ZStack {
            Color(white: 0.95)
            if let data = sourceImageData, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .opacity(0.55)
            }
            ZoomableGrid(cells: cells, width: width, height: height,
                         showGuides: true,
                         scale: $scale, offset: $offset)
                .opacity(0.65)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topLeading) { tag(L10n.s("叠加对比")) }
    }

    // MARK: - 小组件

    private var noSourcePlaceholder: some View {
        ContentUnavailableView {
            Label(L10n.s("该图纸无原图"), systemImage: "photo.badge.exclamationmark")
        } description: {
            Text(L10n.s("仅「照片转图纸」来源的图纸支持原图对比。"))
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .padding(6)
    }
}
