import SwiftUI

/// 只读网格渲染（预览/转换结果用）
struct GridView: View {
    let cells: [Int]
    let width: Int
    let height: Int
    var showGuides = true

    var body: some View {
        Canvas { ctx, size in
            let side = min(size.width / CGFloat(width), size.height / CGFloat(height))
            let ox = (size.width - side * CGFloat(width)) / 2
            let oy = (size.height - side * CGFloat(height)) / 2

            for y in 0..<height {
                for x in 0..<width {
                    let v = cells[y * width + x]
                    let color: Color = v > 0 ? (BeadPalette.byId[v]?.color ?? .clear)
                                            : Color(white: 0.97)
                    let rect = CGRect(x: ox + CGFloat(x) * side, y: oy + CGFloat(y) * side,
                                      width: side + 0.5, height: side + 0.5)
                    ctx.fill(Path(rect), with: .color(color))
                }
            }

            if showGuides && side > 4 {
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
        .background(Color(white: 0.94))
        .aspectRatio(CGFloat(width) / CGFloat(height), contentMode: .fit)
    }
}

// MARK: - 编辑器模型

enum EditorTool: String, CaseIterable {
    case brush = "paintbrush.pointed.fill"
    case eraser = "eraser.fill"
    case eyedropper = "eyedropper"
    case bucket = "paintbucket.fill"

    var label: String {
        switch self {
        case .brush: return "画笔"
        case .eraser: return "橡皮"
        case .eyedropper: return "吸管"
        case .bucket: return "填充"
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    @Published var cells: [Int]
    @Published var width: Int
    @Published var height: Int
    @Published var tool: EditorTool = .brush
    @Published var selectedColorId: Int = 199
    @Published var showGuides = true
    @Published var highlightColorId: Int? = nil
    @Published var mirror = false
    @Published var paintMode = true
    @Published var canUndo = false

    private var undoStack: [[Int]] = []
    private let maxUndo = 40

    init(width: Int, height: Int, cells: [Int]? = nil) {
        self.width = width
        self.height = height
        self.cells = cells ?? [Int](repeating: 0, count: width * height)
    }

    init(pattern: Pattern) {
        self.width = pattern.width
        self.height = pattern.height
        self.cells = pattern.cells
    }

    func pushUndo() {
        undoStack.append(cells)
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        canUndo = !undoStack.isEmpty
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        cells = last
        canUndo = !undoStack.isEmpty
    }

    /// 命中检测：点 → 格子
    func cellIndex(at point: CGPoint, in size: CGSize) -> Int? {
        let side = min(size.width / CGFloat(width), size.height / CGFloat(height))
        let ox = (size.width - side * CGFloat(width)) / 2
        let oy = (size.height - side * CGFloat(height)) / 2
        let gx = Int((point.x - ox) / side)
        let gy = Int((point.y - oy) / side)
        guard gx >= 0, gx < width, gy >= 0, gy < height else { return nil }
        return gy * width + gx
    }

    func apply(tool: EditorTool, at index: Int) {
        switch tool {
        case .brush:
            setCell(index, colorId: selectedColorId)
            if mirror { setCell(mirrorIndex(index), colorId: selectedColorId) }
        case .eraser:
            setCell(index, colorId: 0)
            if mirror { setCell(mirrorIndex(index), colorId: 0) }
        case .eyedropper:
            if cells[index] > 0 { selectedColorId = cells[index] }
        case .bucket:
            bucketFill(at: index)
        }
    }

    private func mirrorIndex(_ i: Int) -> Int {
        let y = i / width
        let x = i % width
        return y * width + (width - 1 - x)
    }

    private func setCell(_ i: Int, colorId: Int) {
        guard i >= 0, i < cells.count, cells[i] != colorId else { return }
        cells[i] = colorId
    }

    private func bucketFill(at index: Int) {
        let target = cells[index]
        guard target != selectedColorId else { return }
        var queue = [index]
        var visited = Set<Int>([index])
        while let i = queue.popLast() {
            setCell(i, colorId: selectedColorId)
            let x = i % width, y = i / width
            let neighbors = [(x-1, y), (x+1, y), (x, y-1), (x, y+1)]
            for (nx, ny) in neighbors {
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let j = ny * width + nx
                if !visited.contains(j), cells[j] == target {
                    visited.insert(j)
                    queue.append(j)
                }
            }
        }
    }
}
