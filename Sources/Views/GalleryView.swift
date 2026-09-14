import SwiftData
import SwiftUI

// MARK: - 作品集（对标 AI豆仓「作品集」：成品归档 + 作品卡分享）

/// 作品集：展示所有「已完成」图纸（成品照片优先），支持筛选、大图查看与一键生成分享卡。
///
/// - 数据全部来自现有 `Pattern`（`status == .done` + `resultPhoto` + `completedAt`），无新增模型；
/// - 成品照片在作品详情（进度 Tab）上传；无照片时用图纸网格兜底；
/// - 分享卡为竖版 2:3 长图，走系统分享面板（微信 / 小红书 / 存相册）。
///
/// 注意：本视图不自带 `NavigationStack`（由 `PatternsTabView` 的外层栈提供，与 `TemplateGalleryView` 一致）。
@MainActor
struct GalleryView: View {
    @Query(sort: \Pattern.updatedAt, order: .reverse) private var patterns: [Pattern]

    @State private var filter: GalleryFilter = .all
    @State private var detail: Pattern?

    enum GalleryFilter: String, CaseIterable, Identifiable {
        case all = "全部作品"
        case withPhoto = "有成品照"
        case thisMonth = "本月完成"
        var id: String { rawValue }
    }

    // MARK: 数据

    private var doneWorks: [Pattern] {
        patterns
            .filter { $0.status == .done }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    private var works: [Pattern] {
        switch filter {
        case .all: return doneWorks
        case .withPhoto: return doneWorks.filter { $0.resultPhoto != nil }
        case .thisMonth:
            return doneWorks.filter {
                guard let d = $0.completedAt else { return false }
                return Calendar.current.isDate(d, equalTo: Date(), toGranularity: .month)
            }
        }
    }

    private var totalBeads: Int { doneWorks.reduce(0) { $0 + $1.totalBeads } }

    private var monthCount: Int {
        doneWorks.filter {
            guard let d = $0.completedAt else { return false }
            return Calendar.current.isDate(d, equalTo: Date(), toGranularity: .month)
        }.count
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroCard
                filterBar
                if works.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(works) { p in
                            workCard(p)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Theme.pageFill)
        .sheet(item: $detail) { p in
            WorkShowcaseSheet(pattern: p)
        }
    }

    // MARK: 英雄条

    private var heroCard: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.violet)
            BeadDots()
                .padding(.top, 16).padding(.trailing, 18)
            VStack(alignment: .leading, spacing: 12) {
                Label("我的作品集", systemImage: "photo.stack.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white.opacity(0.92))
                HStack(spacing: 0) {
                    heroStat("\(doneWorks.count)", "作品")
                    heroStat("\(totalBeads)", "累计颗数")
                    heroStat("\(monthCount)", "本月完成")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 128)
        .shadow(color: Color(red: 0.62, green: 0.36, blue: 0.92).opacity(0.28), radius: 12, y: 5)
    }

    private func heroStat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 筛选条

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GalleryFilter.allCases) { f in
                    let active = filter == f
                    Button {
                        filter = f
                    } label: {
                        Text(f.rawValue)
                            .font(.caption.weight(active ? .bold : .regular))
                            .padding(.horizontal, 13).padding(.vertical, 7)
                            .background(active ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.cardFill), in: Capsule())
                            .foregroundStyle(active ? .white : Color.primary)
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    // MARK: 作品卡

    private func workCard(_ p: Pattern) -> some View {
        Button {
            detail = p
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    coverImage(p)
                        .frame(height: 148)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    if p.resultPhoto != nil {
                        Text("成品照")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.brand, in: Capsule())
                            .padding(8)
                    }
                }
                Text(p.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(p.width)×\(p.height)")
                    Text("·")
                    Text("\(p.totalBeads) 颗")
                    if let d = p.completedAt {
                        Text("·")
                        Text(d.formatted(.dateTime.month().day()))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func coverImage(_ p: Pattern) -> some View {
        if let data = p.resultPhoto, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
        } else {
            Image(uiImage: p.thumbnailImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(8)
                .background(Theme.pageFill)
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text(doneWorks.isEmpty ? "还没有完成的作品" : "该筛选下没有作品")
                .font(.headline)
            Text(doneWorks.isEmpty
                 ? "拼完一张图纸并打卡完成后，会自动出现在这里；上传成品照片还能生成作品卡分享。"
                 : "换个筛选条件看看。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .cardStyle()
    }
}

// MARK: - 作品展示（大图 + 作品卡分享）

/// 单个作品的大图查看与分享卡导出。
@MainActor
struct WorkShowcaseSheet: View {
    @Bindable var pattern: Pattern
    @Environment(\.dismiss) private var dismiss

    @State private var showPatternGrid = false
    @State private var shareImage: UIImage?
    @State private var showShareSheet = false

    private var photoImage: UIImage? {
        guard let data = pattern.resultPhoto else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    bigPreview
                    infoCard
                    actionCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(Theme.pageFill)
            .navigationTitle(pattern.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let shareImage {
                    SharePreviewSheet(image: shareImage)
                }
            }
        }
    }

    // MARK: 大图

    private var bigPreview: some View {
        VStack(spacing: 10) {
            if let photo = photoImage, !showPatternGrid {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Image(uiImage: pattern.thumbnailImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
                    .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if photoImage != nil {
                Picker("查看", selection: $showPatternGrid) {
                    Text("成品照片").tag(false)
                    Text("图纸").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
        .cardStyle()
    }

    // MARK: 信息

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                infoCell("\(pattern.width)×\(pattern.height)", "图纸尺寸")
                infoCell("\(pattern.totalBeads)", "总颗数")
                infoCell("\(pattern.beadCounts.count)", "用色数")
            }
            if let done = pattern.completedAt {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("完成于 \(done.formatted(.dateTime.year().month().day().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let start = pattern.startedAt, let done = pattern.completedAt {
                let days = max(1, Int(done.timeIntervalSince(start) / 86400) + 1)
                Text("用时约 \(days) 天")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func infoCell(_ value: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 动作

    private var actionCard: some View {
        VStack(spacing: 10) {
            Button {
                generateShareCard()
            } label: {
                Label("生成作品分享卡", systemImage: "square.and.arrow.up.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.brand, in: Capsule())
            }
            .buttonStyle(.plain)
            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)

            Text("竖版长图：成品照（或图纸）+ 尺寸豆量 + 色号用量 Top6，可直接发微信/小红书。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if let shareImage {
                ShareLink(item: Image(uiImage: shareImage),
                          preview: SharePreview("\(pattern.name) · 作品卡", image: Image(uiImage: shareImage))) {
                    Label("分享作品卡", systemImage: "paperplane.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(Theme.accent)
                        .frame(height: 18)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.accent.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    private func generateShareCard() {
        var opts = PatternRenderer.ShareCardOptions()
        opts.title = pattern.name
        var parts: [String] = ["\(pattern.width)×\(pattern.height) 格", "\(pattern.totalBeads) 颗"]
        if let done = pattern.completedAt {
            parts.append(done.formatted(.dateTime.year().month().day()))
        }
        opts.meta = parts.joined(separator: " · ")
        let card = PatternRenderer.shareCard(photo: photoImage,
                                             cells: pattern.cells,
                                             width: pattern.width,
                                             height: pattern.height,
                                             options: opts)
        shareImage = card
        showShareSheet = true
    }
}

// MARK: - 分享卡预览（可长按保存 + 系统分享）

private struct SharePreviewSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    Text("长按图片可存储到相册，或点右上角分享")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview("作品分享卡", image: Image(uiImage: image))) {
                        Label("分享 / 存储", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(height: 22)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Theme.brand, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(Theme.pageFill)
            .navigationTitle("作品分享卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
