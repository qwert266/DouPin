import PhotosUI
import SwiftData
import SwiftUI

// MARK: - 文件夹列表（一级，无多级嵌套；PRD §5.10）

/// 一级文件夹列表：显示文件夹 + 图纸数量；支持新建/重命名/删除；
/// 支持文件夹内直接「+」导入图纸（自动归入当前文件夹，解决竞品痛点）。
///
/// 删除语义（架构师 §B.8 约定）：**不级联删图纸**，手动把该文件夹下图纸的 `folderId` 置 `nil`。
struct FolderListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PatternFolder.sortOrder) private var folders: [PatternFolder]
    @Query private var patterns: [Pattern]

    @State private var showCreate = false
    @State private var newName = ""
    @State private var renameTarget: PatternFolder?
    @State private var renameText = ""
    @State private var deleteTarget: PatternFolder?

    var body: some View {
        Group {
            if folders.isEmpty {
                emptyState
            } else {
                folderList
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newName = ""
                    showCreate = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
            }
        }
        .alert(L10n.s("新建文件夹"), isPresented: $showCreate) {
            TextField(L10n.s("文件夹名称"), text: $newName)
            Button(L10n.s("创建")) { createFolder() }
            Button(L10n.s("取消"), role: .cancel) { newName = "" }
        }
        .alert(L10n.s("重命名文件夹"), isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField(L10n.s("文件夹名称"), text: $renameText)
            Button(L10n.s("确定")) {
                let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { renameTarget?.rename(to: t) }
                renameTarget = nil
            }
            Button(L10n.s("取消"), role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(L10n.s("删除文件夹？"),
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button(L10n.s("删除"), role: .destructive) {
                if let f = deleteTarget { deleteFolder(f) }
                deleteTarget = nil
            }
            Button(L10n.s("取消"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(L10n.s("文件夹内的图纸不会被删除，将被移出到「全部」。"))
        }
    }

    // MARK: - 视图

    private var folderList: some View {
        List {
            Section {
                ForEach(folders) { folder in
                    NavigationLink {
                        FolderDetailView(folder: folder)
                    } label: {
                        FolderRow(folder: folder, count: count(in: folder))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTarget = folder
                        } label: {
                            Label(L10n.s("删除"), systemImage: "trash")
                        }
                        Button {
                            renameText = folder.name
                            renameTarget = folder
                        } label: {
                            Label(L10n.s("重命名"), systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .cardRow()
                }
            } footer: {
                Text(L10n.s("长按拖动排序为 P2（暂未实现，见 TODO）。"))
            }
        }
        .themedListPage()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.s("还没有文件夹"), systemImage: "folder")
        } description: {
            Text(L10n.s("用文件夹给图纸归档，找图更快"))
        } actions: {
            Button {
                newName = ""
                showCreate = true
            } label: {
                Label(L10n.s("新建文件夹"), systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 逻辑

    private func count(in folder: PatternFolder) -> Int {
        patterns.filter { $0.folderId == folder.id }.count
    }

    private func createFolder() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let next = (folders.map(\.sortOrder).max() ?? -1) + 1
        context.insert(PatternFolder(name: name, sortOrder: next))
        newName = ""
    }

    /// 删除文件夹：**不级联删图纸**，手动把其下图纸 `folderId` 置 nil。
    private func deleteFolder(_ folder: PatternFolder) {
        let id = folder.id
        // 收集副本后统一处理（避免在 ForEach 内 delete）
        let affected = patterns.filter { $0.folderId == id }
        for p in affected {
            p.folderId = nil
            p.touch()
        }
        context.delete(folder)
        try? context.save()
    }

    // TODO(P2): 文件夹长按拖动排序（`sortOrder` 已就位，PRD §5.10 P2，本任务暂不实现）。
}

// MARK: - 文件夹行

/// 文件夹列表行：名称 + 图纸数量
struct FolderRow: View {
    let folder: PatternFolder
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.pink)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.headline)
                Text(L10n.p("{0} 张图纸", "\(count)")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - 文件夹详情（文件夹内图纸列表 + 文件夹内上传）

/// 文件夹内图纸列表：复用 `PatternRow`；带「+」导入入口（照片转图纸 / 导入后自动归入当前文件夹）。
struct FolderDetailView: View {
    @Environment(\.modelContext) private var context
    @Query private var patterns: [Pattern]

    let folder: PatternFolder

    @State private var importing = false
    @State private var importItem: PhotosPickerItem?

    /// 文件夹内图纸（按更新时间倒序）
    private var items: [Pattern] {
        patterns.filter { $0.folderId == folder.id }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.s("文件夹是空的"), systemImage: "folder")
                } description: {
                    Text(L10n.p("点右上角「+」导入图纸，将自动归入「{0}」", "\(folder.name)"))
                } actions: {
                    PhotosPicker(selection: $importItem, matching: .images) {
                        Label(L10n.s("从相册导入"), systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        ForEach(items) { p in
                            NavigationLink {
                                WorkDetailView(pattern: p)
                            } label: {
                                PatternRow(pattern: p)
                            }
                            .cardRow()
                        }
                        .onDelete(perform: remove)
                    } footer: {
                        Text(L10n.p("共 {0} 张图纸", "\(items.count)"))
                    }
                }
                .themedListPage()
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        ConvertView(bindFolderId: folder.id)
                    } label: {
                        Label(L10n.s("照片转图纸"), systemImage: "photo.on.rectangle.angled")
                    }
                    NavigationLink {
                        EditorView(pattern: nil, initialSize: 29)
                    } label: {
                        Label(L10n.s("新建手绘（导入后手动归入）"), systemImage: "square.and.pencil")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onChange(of: importItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    // 走与 ConvertView 相同的下游（简单像素化），自动归入本文件夹
                    var opts = PixelConverter.Options()
                    opts.maxSide = 29
                    opts.colorLimit = 24
                    let res = PixelConverter.convert(image: ui, options: opts)
                    if !res.cells.isEmpty {
                        let p = Pattern(name: L10n.p("{0} 图纸 {1}", "\(folder.name)", "\(Date().formatted(.dateTime.month().day()))"),
                                        width: res.width, height: res.height,
                                        cells: res.cells, source: "photo")
                        p.folderId = folder.id
                        p.sourceImageData = ui.jpegData(compressionQuality: 0.8)
                        context.insert(p)
                    }
                }
                importItem = nil
            }
        }
    }

    /// 从文件夹移除图纸（仅解除归属，不删图纸）
    private func remove(at offsets: IndexSet) {
        let list = items
        for i in offsets where i >= 0 && i < list.count {
            list[i].folderId = nil
            list[i].touch()
        }
        try? context.save()
    }
}

// MARK: - 标签筛选（P1，PRD §5.10）

/// 标签云 + 按标签筛选：所有标签由 `@Query` 的 patterns 聚合 `tags` 字段。
struct TagFilterView: View {
    @Query(sort: \Pattern.updatedAt, order: .reverse) private var patterns: [Pattern]

    @State private var selectedTag: String?

    /// 全部标签（去重，按出现次数降序）
    private var allTags: [(tag: String, count: Int)] {
        var dict: [String: Int] = [:]
        for p in patterns {
            for t in p.tags where !t.isEmpty { dict[t, default: 0] += 1 }
        }
        return dict.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// 当前筛选结果
    private var filtered: [Pattern] {
        guard let selectedTag else { return [] }
        return patterns.filter { $0.tags.contains(selectedTag) }
    }

    var body: some View {
        Group {
            if allTags.isEmpty {
                ContentUnavailableView {
                    Label(L10n.s("还没有标签"), systemImage: "tag")
                } description: {
                    Text(L10n.s("在图纸详情里「编辑标签」，即可按标签归档"))
                }
            } else {
                List {
                    Section(L10n.k("全部标签")) {
                        TagCloud(tags: allTags, selected: $selectedTag)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                            .cardRow()
                    }

                    if let tag = selectedTag {
                        Section {
                            if filtered.isEmpty {
                                Text(L10n.p("没有含「{0}」的图纸", "\(tag)"))
                                    .foregroundStyle(.secondary)
                                    .cardRow()
                            } else {
                                ForEach(filtered) { p in
                                    NavigationLink {
                                        WorkDetailView(pattern: p)
                                    } label: {
                                        PatternRow(pattern: p)
                                    }
                                    .cardRow()
                                }
                            }
                        } header: {
                            HStack {
                                Text(L10n.p("标签「{0}」", "\(tag)"))
                                Spacer()
                                Button(L10n.s("清除")) { selectedTag = nil }
                                    .font(.caption)
                            }
                        }
                    }
                }
                .themedListPage()
            }
        }
    }
}

/// 标签云（可换行的标签按钮）
struct TagCloud: View {
    let tags: [(tag: String, count: Int)]
    @Binding var selected: String?

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.tag) { item in
                Button {
                    selected = (selected == item.tag) ? nil : item.tag
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill").font(.caption2)
                        Text(item.tag).font(.subheadline)
                        Text("\(item.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selected == item.tag
                                ? AnyShapeStyle(Theme.brand)
                                : AnyShapeStyle(Theme.cardFill), in: Capsule())
                    .foregroundStyle(selected == item.tag ? .white : Color.primary)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 小红书链接导入（L3：用户确认 & 保存；架构师 §A.5.4）

/// 小红书链接导入：粘贴分享文案 → 三级流水线提取图片 → 用户选图 → 下载 → 像素化 → 建图纸。
///
/// **降级策略（必须）**：
/// - L1 无链接：提示重新复制；
/// - L2 失败（超时/403/无图）：引导改用「从相册选择图片」（`ConvertView` 路径）；
/// - 下载失败：提示网络问题，保留链接可重试；
/// - 多图：让用户选，不自动猜。
///
/// **合规**：仅抓取公开分享页图片、不伪造登录态、不上传不分享、不缓存 HTML；界面明示仅供个人自用。
struct XiaohongshuImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// 若从文件夹进入，导入的图纸自动归入该文件夹
    var bindFolderId: UUID? = nil

    @State private var input = ""
    @State private var extracting = false
    @State private var result: XiaohongshuExtractor.ExtractResult?
    @State private var selectedImageURL: URL?
    @State private var downloadedData: Data?
    @State private var downloading = false
    @State private var previewImage: UIImage?
    @State private var maxSide = 29
    @State private var colorLimit = 24
    @State private var patternName = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $input)
                    .frame(minHeight: 90)
                Button {
                    Task { await runExtract() }
                } label: {
                    if extracting {
                        HStack { ProgressView().controlSize(.small); Text(L10n.s("解析中…")) }
                    } else {
                        Label(L10n.s("解析链接"), systemImage: "sparkle.magnifyingglass")
                    }
                }
                .disabled(extracting || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(L10n.s("粘贴小红书分享链接 / 文案"))
            } footer: {
                Text(L10n.s("打开小红书笔记 →「分享」→「复制链接」，粘贴到这里即可。\\n仅抓取公开分享页图片，供个人自用参考，请尊重原作者版权。"))
            }

            if let result {
                if let err = result.error {
                    failureSection(result: result, error: err)
                }
                if !result.imageURLs.isEmpty {
                    imageListSection(urls: result.imageURLs, title: result.noteTitle)
                }
            }

            if let previewImage {
                Section(L10n.k("预览（像素化后）")) {
                    Image(uiImage: previewImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    TextField(L10n.s("图纸名称"), text: $patternName)
                    LabeledContent(L10n.k("尺寸（最大边格数）"), value: L10n.p("{0} 格", "\(maxSide)"))
                    Slider(value: Binding(get: { Double(maxSide) }, set: { maxSide = Int($0);
                            regeneratePreview() }), in: 16...64, step: 4)
                    Picker(L10n.s("颜色数量"), selection: Binding(get: { colorLimit }, set: {
                        colorLimit = $0; regeneratePreview() })) {
                        Text(L10n.s("全部（295 色）")).tag(0)
                        Text(L10n.s("≤ 48 色")).tag(48)
                        Text(L10n.s("≤ 24 色")).tag(24)
                        Text(L10n.s("≤ 16 色")).tag(16)
                    }
                }
                Section {
                    Button {
                        savePattern()
                    } label: {
                        Label(L10n.s("保存为图纸"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(patternName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle(L10n.s("从小红书链接导入"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 子视图

    private func failureSection(result: XiaohongshuExtractor.ExtractResult, error: String) -> some View {
        Section {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            if result.shouldFallbackToAlbum {
                NavigationLink {
                    ConvertView(bindFolderId: bindFolderId)
                } label: {
                    Label(L10n.s("改用「从相册选择图片」"), systemImage: "photo.on.rectangle.angled")
                }
                Text(L10n.s("提示：在 App 中把感兴趣的内容截图或保存图片，再走相册导入即可。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.s("未成功提取"))
        }
    }

    private func imageListSection(urls: [URL], title: String?) -> some View {
        Section {
            if let title {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(L10n.p("共 {0} 张候选图片，请选择一张：", "\(urls.count)"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                Button {
                    Task { await choose(url) }
                } label: {
                    HStack {
                        Image(systemName: selectedImageURL == url
                              ? "checkmark.circle.fill" : "photo")
                            .foregroundStyle(selectedImageURL == url ? .pink : .secondary)
                        Text(url.lastPathComponent.isEmpty ? url.absoluteString : url.lastPathComponent)
                            .font(.footnote)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
                .disabled(downloading)
            }
            if downloading {
                HStack { ProgressView().controlSize(.small); Text(L10n.s("下载中…")) }
            }
        } header: {
            Text(L10n.s("选择图片"))
        }
    }

    // MARK: - 动作

    private func runExtract() async {
        extracting = true
        result = nil
        selectedImageURL = nil
        downloadedData = nil
        previewImage = nil
        let r = await XiaohongshuExtractor.extract(from: input)
        result = r
        extracting = false
    }

    /// 用户选定某张图 → 下载（失败保留链接可重试）
    private func choose(_ url: URL) async {
        downloading = true
        selectedImageURL = url
        let data = await XiaohongshuExtractor.downloadImage(url)
        downloading = false
        guard let data, let ui = UIImage(data: data) else {
            // 下载失败：提示网络问题，保留链接可重试（result 不重置）
            result?.error = L10n.s("图片下载失败，请检查网络后重试（可直接再次点击该图片）。")
            result?.suggestAlbum = true
            return
        }
        downloadedData = data
        if patternName.isEmpty {
            patternName = result?.noteTitle ?? L10n.p("小红书图纸 {0}", "\(Date().formatted(.dateTime.month().day()))")
        }
        regeneratePreview(image: ui)
    }

    private func regeneratePreview(image: UIImage? = nil) {
        let ui: UIImage?
        if let image { ui = image }
        else if let data = downloadedData { ui = UIImage(data: data) }
        else { ui = nil }
        guard let ui else { return }
        var opts = PixelConverter.Options()
        opts.maxSide = maxSide
        opts.colorLimit = colorLimit
        let res = PixelConverter.convert(image: ui, options: opts)
        if !res.cells.isEmpty {
            previewImage = PatternRenderer.renderThumb(cells: res.cells, width: res.width,
                                                       height: res.height, size: 320)
        }
    }

    private func savePattern() {
        guard let data = downloadedData, let ui = UIImage(data: data) else { return }
        var opts = PixelConverter.Options()
        opts.maxSide = maxSide
        opts.colorLimit = colorLimit
        let res = PixelConverter.convert(image: ui, options: opts)
        guard !res.cells.isEmpty else { return }
        let p = Pattern(name: patternName, width: res.width, height: res.height,
                        cells: res.cells, source: "xhs")
        p.folderId = bindFolderId
        p.sourceImageData = ui.jpegData(compressionQuality: 0.8)
        context.insert(p)
        dismiss()
    }
}
