import SwiftData
import SwiftUI

// MARK: - 模板库标签页

struct TemplateGalleryView: View {
    var templates: [PatternTemplate] { TemplateLibrary.all }

    var categories: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in templates where !seen.contains(t.category) {
            seen.insert(t.category)
            out.append(t.category)
        }
        return out
    }

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 14)]

    /// 套装名 → SF Symbol 映射（T05）。未知套装回落到通用图标。
    static func setIcon(for category: String) -> String {
        switch category {
        case L10n.s("像素小动物"): return "pawprint.fill"
        case L10n.s("表情包"): return "face.smiling.fill"
        case L10n.s("自然风景"): return "leaf.fill"
        case L10n.s("节日"): return "party.popper.fill"
        case L10n.s("食物甜点"): return "cup.and.saucer.fill"
        case L10n.s("植物花语"): return "camera.macro"
        case L10n.s("太空星球"): return "sparkles"
        case L10n.s("字母数字"): return "textformat"
        case L10n.s("爱心系"): return "heart.fill"
        case L10n.s("日常物件"): return "shippingbox.fill"
        default: return "square.grid.2x2"
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: .sectionHeaders) {
                ForEach(categories, id: \.self) { cat in
                    Section {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(templates.filter { $0.category == cat }) { t in
                                NavigationLink {
                                    TemplatePreviewView(template: t)
                                } label: {
                                    TemplateCard(template: t)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Image(systemName: Self.setIcon(for: cat))
                                .foregroundStyle(Theme.accent)
                            Text(L10n.s(cat)).font(.title3.bold())
                            Text(L10n.p("{0} 个", "\(templates.filter { $0.category == cat }.count)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(L10n.s("模板库"))
    }
}

struct TemplateCard: View {
    let template: PatternTemplate

    var body: some View {
        VStack(spacing: 6) {
            GridView(cells: template.cells, width: template.width, height: template.height)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.25)))
            Text(template.name).font(.footnote.weight(.medium))
            Text(L10n.p("{0}×{1} · {2}颗", "\(template.width)", "\(template.height)", "\(template.cells.filter { $0 > 0 }.count)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 模板预览 + 使用

struct TemplatePreviewView: View {
    @Environment(\.modelContext) private var context
    let template: PatternTemplate

    @State private var created: Pattern?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GridView(cells: template.cells, width: template.width, height: template.height)
                    .frame(maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 12) {
                    stat(L10n.s("尺寸"), "\(template.width)×\(template.height)")
                    stat(L10n.s("颜色"), L10n.p("{0} 种", "\(colorCounts.count)"))
                    stat(L10n.s("豆子"), L10n.p("{0} 颗", "\(template.cells.filter { $0 > 0 }.count)"))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.s("用色清单")).font(.headline)
                    ForEach(Array(colorCounts.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(item.color.color)
                                .frame(width: 26, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.3)))
                            Text("Mard \(item.color.mard)").font(.subheadline.monospaced())
                            Spacer()
                            Text("×\(item.count)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
        }
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                let p = Pattern(name: template.name, width: template.width, height: template.height,
                                cells: template.cells, source: "template")
                context.insert(p)
                created = p
            } label: {
                Label(L10n.s("使用此模板开始拼"), systemImage: "play.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .navigationDestination(item: $created) { p in
            WorkDetailView(pattern: p)
        }
    }

    private var colorCounts: [(color: BeadColor, count: Int)] {
        var dict: [Int: Int] = [:]
        for c in template.cells where c > 0 { dict[c, default: 0] += 1 }
        return dict
            .compactMap { id, n in BeadPalette.byId[id].map { ($0, n) } }
            .sorted { $0.1 > $1.1 }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(white: 0.96), in: RoundedRectangle(cornerRadius: 10))
    }
}


// MARK: - 内置素材库浏览（上千张可直接拼的图纸）

/// 素材库浏览：分类 chips + 搜索 + 网格（缩略图按需解码）
@MainActor
struct LibraryBrowserView: View {
    @Environment(\.modelContext) private var context
    @StateObject private var library = BuiltInPatternLibrary.shared
    @State private var category: String?
    @State private var keyword = ""

    private let columns = [GridItem(.adaptive(minimum: 98), spacing: 10)]

    var body: some View {
        Group {
            if library.loadFailed {
                ContentUnavailableView {
                    Label(L10n.s("素材库暂不可用"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(L10n.s("未找到随包资源，请重新安装最新版本。"))
                }
            } else if !library.isLoaded {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.s("正在载入素材库…")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    categoryBar
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(library.filtered(category: category, keyword: keyword)) { p in
                            NavigationLink {
                                LibraryPreviewView(pattern: p)
                            } label: {
                                LibraryCard(pattern: p)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
                .searchable(text: $keyword, prompt: L10n.s("搜索素材（名称/字母）"))
            }
        }
        .onAppear { library.loadIfNeeded() }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                catChip(nil, L10n.p("全部（{0}）", "\(library.patterns.count)"))
                ForEach(library.categories, id: \.self) { c in
                    catChip(c, c)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func catChip(_ value: String?, _ title: String) -> some View {
        let active = (category ?? "") == (value ?? "")
        return Button {
            category = value
        } label: {
            Text(title)
                .font(.caption.weight(active ? .bold : .regular))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(active ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.cardFill), in: Capsule())
                .foregroundStyle(active ? .white : Color.primary)
                .overlay(Capsule().stroke(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

/// 素材卡片（缩略图懒加载）
struct LibraryCard: View {
    let pattern: LibraryPattern
    @State private var thumb: UIImage?

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let thumb {
                    Image(uiImage: thumb)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(Theme.pageFill)
                        .overlay(ProgressView().scaleEffect(0.6))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2)))

            Text(pattern.displayName)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            Text(L10n.p("{0}×{1} · {2} 色", "\(pattern.w)", "\(pattern.h)", "\(pattern.colors)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .task(id: pattern.id) {
            thumb = BuiltInPatternLibrary.shared.thumbnail(for: pattern)
        }
    }
}

/// 素材详情：高清预览 + 用量 + 一键开始拼
@MainActor
struct LibraryPreviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let pattern: LibraryPattern

    @State private var preview: UIImage?
    @State private var created = false

    private var colorCounts: [(color: BeadColor, count: Int)] {
        var dict: [Int: Int] = [:]
        for c in pattern.decodedCells where c > 0 { dict[c, default: 0] += 1 }
        return dict.compactMap { id, n in BeadPalette.byId[id].map { ($0, n) } }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Group {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                    } else {
                        ProgressView().frame(height: 220)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)

                HStack(spacing: 0) {
                    statCell(L10n.s("尺寸"), "\(pattern.w)×\(pattern.h)")
                    statCell(L10n.s("颜色"), "\(colorCounts.count)")
                    statCell(L10n.s("豆子"), "\(pattern.beads)")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.s("用色清单")).font(.headline)
                    ForEach(Array(colorCounts.prefix(12).enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(item.color.color)
                                .frame(width: 26, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.3)))
                            Text("Mard \(item.color.mard)").font(.subheadline.monospaced())
                            Spacer()
                            Text("×\(item.count)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if colorCounts.count > 12 {
                        Text(L10n.p("…等共 {0} 色，保存后可在图纸详情查看完整清单", "\(colorCounts.count)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
        }
        .background(Theme.pageFill)
        .navigationTitle(pattern.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: pattern.id) {
            preview = BuiltInPatternLibrary.shared.previewImage(for: pattern)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                let p = Pattern(name: pattern.displayName, width: pattern.w, height: pattern.h,
                                cells: pattern.decodedCells, source: "library")
                context.insert(p)
                try? context.save()
                Haptics.success()
                created = true
            } label: {
                Label(created ? L10n.s("已加入我的图纸") : L10n.s("使用此图纸开始拼"),
                      systemImage: created ? "checkmark.circle.fill" : "play.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(created ? .green : Theme.accent)
            .padding(16)
            .background(.bar)
        }
    }

    private func statCell(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
