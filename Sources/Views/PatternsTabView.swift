import SwiftData
import SwiftUI

// MARK: - 图纸 Tab 容器（PRD §4.1：全部 / 文件夹 / 标签 / 模板）

/// 图纸 Tab 容器：顶部分段控件切换「全部 / 文件夹 / 标签 / 模板」。
///
/// 结构说明（避免 NavigationStack 嵌套冲突）：
/// - **外层仅一个 `NavigationStack`**；各分段只提供内容 View，不各自再套 `NavigationStack`。
/// - 「全部」段复用 `PatternListView` 的列表逻辑（此处内联为 `AllPatternsSection`，保持单一导航栈）；
/// - 「文件夹」段用 `FolderListView`；「标签」段用 `TagFilterView`；「模板」段嵌入 `TemplateGalleryView`。
struct PatternsTabView: View {
    @Environment(\.modelContext) private var context

    @State private var segment: PatternsSegment = .all

    enum PatternsSegment: String, CaseIterable, Identifiable {
        case all = "全部"
        case gallery = "作品"
        case folder = "文件夹"
        case tag = "标签"
        case template = "模板"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                segmentBar
                Group {
                    switch segment {
                    case .all:       AllPatternsSection()
                    case .gallery:   GalleryView()
                    case .folder:    FolderListView()
                    case .tag:       TagFilterView()
                    case .template:  TemplateGalleryView()
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BoardConnectCapsule()
                }
                if segment == .all || segment == .folder || segment == .tag {
                    ToolbarItem(placement: .topBarTrailing) { createMenu }
                }
            }
        }
    }

    /// 顶部胶囊分段条（渐变选中态，替代系统菜单样式）
    private var segmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PatternsSegment.allCases) { s in
                    let active = segment == s
                    Button {
                        segment = s
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: segmentIcon(s))
                                .font(.caption2.bold())
                            Text(L10n.s(s.rawValue))
                                .font(.subheadline.weight(active ? .bold : .regular))
                        }
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(active ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.cardFill), in: Capsule())
                        .foregroundStyle(active ? .white : Color.primary)
                        .overlay(Capsule().stroke(Color.secondary.opacity(0.15)))
                        .shadow(color: active ? Theme.accent.opacity(0.25) : .clear, radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.pageFill)
    }

    private func segmentIcon(_ s: PatternsSegment) -> String {
        switch s {
        case .all: return "square.grid.3x3.fill"
        case .gallery: return "photo.stack.fill"
        case .folder: return "folder.fill"
        case .tag: return "tag.fill"
        case .template: return "gift.fill"
        }
    }

    private var navigationTitle: String {
        switch segment {
        case .all: return L10n.s("我的图纸")
        case .gallery: return L10n.s("作品集")
        case .folder: return L10n.s("文件夹")
        case .tag: return L10n.s("标签")
        case .template: return L10n.s("模板库")
        }
    }

    /// 新建菜单（含「从小红书链接导入」）
    private var createMenu: some View {
        Menu {
            NavigationLink {
                ConvertView()
            } label: {
                Label(L10n.s("照片转图纸"), systemImage: "photo.on.rectangle.angled")
            }
            NavigationLink {
                EditorView(pattern: nil, initialSize: 29)
            } label: {
                Label(L10n.s("新建手绘"), systemImage: "square.and.pencil")
            }
            NavigationLink {
                SocialImportView()
            } label: {
                Label(L10n.s("从社交平台导入"), systemImage: "link")
            }
            NavigationLink {
                PatternMergeView()
            } label: {
                Label(L10n.s("合并图纸（多图拼一张）"), systemImage: "square.on.square.dashed")
            }
            Divider()
            Button {
                segment = .template
            } label: {
                Label(L10n.s("从模板开始"), systemImage: "gift")
            }
        } label: {
            Image(systemName: "plus")
        }
    }
}

// MARK: - 「全部」分段内容（复用原 PatternListView 逻辑，但不自带 NavigationStack）

/// 「全部」图纸列表：状态筛选 + 搜索 + 列表 + 删除。
///
/// 说明：原 `PatternListView` 自带 `NavigationStack`；为避免与 `PatternsTabView` 外层导航栈嵌套，
/// 此处内联相同逻辑（仅内容视图）。`PatternListView` 仍保留（供他处复用），不再由本 Tab 直接使用。
struct AllPatternsSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Pattern.updatedAt, order: .reverse) private var patterns: [Pattern]

    @State private var filter: PatternFilter = .all
    @State private var searchText = ""

    private var filtered: [Pattern] {
        patterns.filter { p in
            let okStatus: Bool
            switch filter {
            case .all: okStatus = true
            case .pending: okStatus = p.status == .pending
            case .inProgress: okStatus = p.status == .inProgress
            case .done: okStatus = p.status == .done
            }
            let okText = searchText.isEmpty || p.name.localizedCaseInsensitiveContains(searchText)
            return okStatus && okText
        }
    }

    var body: some View {
        Group {
            if patterns.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
    }

    private var listContent: some View {
        List {
            Section {
                Picker(L10n.s("筛选"), selection: $filter) {
                    ForEach(PatternFilter.allCases) { f in
                        Text(L10n.s(f.rawValue)).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            if filtered.isEmpty {
                Section {
                    Text(L10n.s("没有符合筛选的图纸"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .cardRow()
                }
            } else {
                Section {
                    ForEach(filtered) { p in
                        NavigationLink {
                            WorkDetailView(pattern: p)
                        } label: {
                            PatternRow(pattern: p)
                        }
                        .cardRow()
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .themedListPage()
        .searchable(text: $searchText, prompt: L10n.s("搜索图纸名称"))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.s("还没有图纸"), systemImage: "square.grid.3x3")
        } description: {
            Text(L10n.s("用照片转换、手绘或模板创建第一张图纸"))
        } actions: {
            NavigationLink {
                ConvertView()
            } label: {
                Label(L10n.s("照片转图纸"), systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func delete(at offsets: IndexSet) {
        let list = filtered
        for i in offsets where i >= 0 && i < list.count { context.delete(list[i]) }
    }
}
