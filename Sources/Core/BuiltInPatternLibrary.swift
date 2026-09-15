import SwiftUI

// MARK: - 内置图纸素材库
//
// 资源随包分发（bundle 内 `PatternLibrary/`，由 pbxproj folder reference 原样复制）：
//   catalog.json    全部图纸元数据 + RLE 网格
//   thumb/*.png     列表缩略图（256px，滚动流畅）
//   preview/*.png   高清预览（2048px 拼豆质感，详情页用）
//
// 图纸为 CMYK→Mard 真实色号构成，可直接"使用此图纸开始拼"。
// 加载策略：进页面时后台解析 catalog（1~2MB JSON），缩略图按需从 bundle 同步解码 + NSCache 缓存。

/// RLE 网格编码（`"120x0,5x12,..."` = 120 个空格 + 5 个 12 号色）
enum RLE {
    static func decode(_ s: String, expected: Int) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(expected)
        for part in s.split(separator: ",") {
            let bits = part.split(separator: "x")
            guard bits.count == 2, let n = Int(bits[0]), let v = Int(bits[1]), n > 0 else { continue }
            out.append(contentsOf: repeatElement(v, count: n))
        }
        if out.count < expected {
            out.append(contentsOf: repeatElement(0, count: expected - out.count))
        } else if out.count > expected {
            out.removeSubrange(expected...)
        }
        return out
    }
}

/// 素材库中的一张图纸
struct LibraryPattern: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let nameEn: String
    let category: String
    let categoryEn: String
    let w: Int
    let h: Int
    /// RLE 编码的网格
    let cells: String
    let colors: Int
    let beads: Int
    let preview: String
    let thumb: String

    var displayName: String { L10n.resolved == .en ? nameEn : name }
    var displayCategory: String { L10n.resolved == .en ? categoryEn : category }

    /// RLE → 网格数组（按需解码；调用方一般只在详情/导入时用）
    var decodedCells: [Int] { RLE.decode(cells, expected: w * h) }
}

/// 素材库（单例，进程内共享一次解析结果）
@MainActor
final class BuiltInPatternLibrary: ObservableObject {
    static let shared = BuiltInPatternLibrary()

    @Published private(set) var patterns: [LibraryPattern] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var loadFailed = false

    private let thumbCache = NSCache<NSString, UIImage>()

    private init() {
        thumbCache.countLimit = 400
    }

    /// 分类列表（按图纸数量降序）
    var categories: [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for p in patterns {
            let key = p.displayCategory
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        return order.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
    }

    /// 首次进入时后台解析（避免 1~2MB JSON 阻塞主线程）
    func loadIfNeeded() {
        guard !isLoaded, !loadFailed, !isLoading else { return }
        isLoading = true
        guard let url = Self.catalogURL else {
            loadFailed = true
            isLoading = false
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: url)
                let catalog = try JSONDecoder().decode(Catalog.self, from: data)
                await MainActor.run {
                    self.patterns = catalog.patterns
                    self.isLoaded = true
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.loadFailed = true
                    self.isLoading = false
                }
            }
        }
    }

    private var isLoading = false

    /// 缩略图（bundle 内同步解码，单张 1~3ms；NSCache 避免重复解码）
    func thumbnail(for p: LibraryPattern) -> UIImage? {
        let key = p.thumb as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let dir = Self.dirURL,
              let img = UIImage(contentsOfFile: dir.appendingPathComponent("thumb/\(p.thumb)").path) else {
            return nil
        }
        thumbCache.setObject(img, forKey: key)
        return img
    }

    /// 高清预览（2048px，仅详情页调用一次）
    func previewImage(for p: LibraryPattern) -> UIImage? {
        guard let dir = Self.dirURL else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent("preview/\(p.preview)").path)
    }

    /// 按分类 + 关键词过滤
    func filtered(category: String?, keyword: String) -> [LibraryPattern] {
        var list = patterns
        if let category, !category.isEmpty {
            list = list.filter { $0.displayCategory == category }
        }
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        if !kw.isEmpty {
            list = list.filter {
                $0.displayName.localizedCaseInsensitiveContains(kw) || $0.name.contains(kw)
            }
        }
        return list
    }

    // MARK: - 资源定位

    private struct Catalog: Decodable {
        let version: Int
        let patterns: [LibraryPattern]
    }

    /// folder reference 原样复制到 bundle 根目录
    private static var dirURL: URL? {
        Bundle.main.url(forResource: "PatternLibrary", withExtension: nil)
    }

    private static var catalogURL: URL? {
        dirURL?.appendingPathComponent("catalog.json")
    }
}
