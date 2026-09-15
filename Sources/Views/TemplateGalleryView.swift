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
