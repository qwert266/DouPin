import SwiftData
import SwiftUI

// MARK: - 图纸库标签页

enum PatternFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case pending = "待拼"
    case inProgress = "拼制中"
    case done = "已完成"
    var id: String { rawValue }
}

struct PatternListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Pattern.updatedAt, order: .reverse) private var patterns: [Pattern]
    @State private var filter: PatternFilter = .all
    @State private var searchText = ""

    var filtered: [Pattern] {
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
        NavigationStack {
            Group {
                if patterns.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .navigationTitle("我的图纸")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink {
                            ConvertView()
                        } label: {
                            Label("照片转图纸", systemImage: "photo.on.rectangle.angled")
                        }
                        NavigationLink {
                            EditorView(pattern: nil, initialSize: 29)
                        } label: {
                            Label("新建手绘", systemImage: "square.and.pencil")
                        }
                        NavigationLink {
                            TemplateGalleryView()
                        } label: {
                            Label("从模板开始", systemImage: "gift")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private var listContent: some View {
        List {
            Section {
                Picker("筛选", selection: $filter) {
                    ForEach(PatternFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            if filtered.isEmpty {
                Section {
                    Text("没有符合筛选的图纸")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                Section {
                    ForEach(filtered) { p in
                        NavigationLink {
                            WorkDetailView(pattern: p)
                        } label: {
                            PatternRow(pattern: p)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .searchable(text: $searchText, prompt: "搜索图纸名称")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有图纸", systemImage: "square.grid.3x3")
        } description: {
            Text("用照片转换、手绘或模板创建第一张图纸")
        } actions: {
            NavigationLink {
                ConvertView()
            } label: {
                Label("照片转图纸", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { context.delete(filtered[i]) }
    }
}
