import SwiftData
import SwiftUI

// MARK: - 主题（全局视觉语言：糖果渐变 + 豆点装饰 + 圆角卡片）

/// 品牌视觉：粉紫主渐变 + 糖果色功能渐变。
/// 所有渐变均带明确起止点，深浅色模式下文字一律用白色（渐变底色饱和度足够）。
enum Theme {
    /// 品牌主渐变（粉→紫）
    static let brand = LinearGradient(
        colors: [Color(red: 1.00, green: 0.38, blue: 0.55),
                 Color(red: 0.86, green: 0.32, blue: 0.90)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 薄荷青绿（照片转图纸）
    static let mint = LinearGradient(
        colors: [Color(red: 0.05, green: 0.75, blue: 0.65),
                 Color(red: 0.10, green: 0.60, blue: 0.92)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 蜜橙黄（手绘画布）
    static let amber = LinearGradient(
        colors: [Color(red: 1.00, green: 0.62, blue: 0.20),
                 Color(red: 1.00, green: 0.42, blue: 0.38)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 星紫（模板库）
    static let violet = LinearGradient(
        colors: [Color(red: 0.55, green: 0.40, blue: 0.98),
                 Color(red: 0.80, green: 0.36, blue: 0.86)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 天蓝（蓝牙/连接）
    static let sky = LinearGradient(
        colors: [Color(red: 0.20, green: 0.56, blue: 1.00),
                 Color(red: 0.45, green: 0.40, blue: 0.98)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 品牌点缀色（进度条/高亮文字/选中态）
    static let accent = Theme.accent

    /// 卡片底色（深浅色自适应）
    static let cardFill = Color(uiColor: .secondarySystemGroupedBackground)

    /// 页面底色（深浅色自适应的分组背景）
    static let pageFill = Color(uiColor: .systemGroupedBackground)
}

/// 豆子圆点装饰：一排错落的半透明圆点，模拟散落的拼豆。
struct BeadDots: View {
    var color: Color = .white
    var opacity: Double = 0.25

    /// 每行圆点：false 表示空位，制造错落感
    private static let rows: [[Bool]] = [
        [true, false, true, true, false, true, true, false],
        [false, true, true, false, true, false, true, true],
        [true, true, false, true, false, true, false, true]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<Self.rows.count, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(0..<Self.rows[r].count, id: \.self) { c in
                        Circle()
                            .fill(color.opacity(Self.rows[r][c] ? opacity : 0))
                            .frame(width: 7, height: 7)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// 统一卡片外观：圆角 20 + 轻投影
    func cardStyle(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
    }

    /// List 页面底色：隐藏系统分组背景，露出页面底色（配合 cardRow 形成卡片流）
    func themedListPage() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.pageFill)
    }

    /// List 单行卡片化：白圆角卡 + 无分隔线（保留滑动手势/搜索/系统控件）
    func cardRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .listRowBackground(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.cardFill)
                    .padding(.vertical, 5)
            )
            .listRowSeparator(.hidden)
    }

    /// 白字胶囊（放在渐变上）
    func heroCapsule(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.caption2.bold())
            Text(text).font(.caption2.bold())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.white.opacity(0.22), in: Capsule())
    }
}

// MARK: - App 根视图（5 Tab）

struct AppRoot: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        // 5 Tab（PRD §4.1）：首页 / 图纸 / 库存 / 拼豆板 / 我的
        // T04：图纸 Tab 换成 `PatternsTabView`（合并「模板」，含文件夹/标签分段）；
        // T05：「我的」由占位替换为正式 `MoreView`。
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
            PatternsTabView()
                .tabItem { Label("图纸", systemImage: "square.grid.3x3.fill") }
            InventoryView()
                .tabItem { Label("库存", systemImage: "square.stack.3d.up.fill") }
            BoardTabView()
                .tabItem { Label("拼豆板", systemImage: "lightbulb.fill") }
            MoreView()
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
        }
        .tint(Theme.accent)
    }
}

// MARK: - 首页（渐变英雄区 + 入口大卡 + 拼制中横滚 + 统计）

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Pattern.updatedAt, order: .reverse) private var patterns: [Pattern]
    @Query private var stocks: [BeadStock]
    @EnvironmentObject var app: AppState
    @ObservedObject private var board = AppState.shared.board

    var inProgress: [Pattern] { patterns.filter { $0.status == .inProgress } }
    var done: [Pattern] { patterns.filter { $0.status == .done } }

    /// 全部库存数量之和（首页「库存」概览用）
    var totalStockQuantity: Int { stocks.reduce(0) { $0 + $1.quantity } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    headerHero
                    quickStart
                    if !inProgress.isEmpty { inProgressRow }
                    statsCard
                    stockCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(Theme.pageFill)
            .navigationTitle("豆拼")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 纯状态指示（不做跳转：BoardTabView 自带 NavigationStack，
                // 从这里 push 会形成双导航栈，返回手势与标题都会错乱）
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: board.isConnected ? "lightbulb.fill" : "lightbulb")
                        .foregroundStyle(board.isConnected ? .yellow : .secondary)
                }
            }
        }
    }

    // MARK: 英雄区：品牌渐变 + 豆点装饰 + 连接状态

    private var headerHero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.brand)
            BeadDots()
                .padding(.top, 18).padding(.trailing, 20)
            VStack(alignment: .leading, spacing: 10) {
                Text("豆拼 DouPin")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("照片变图纸，图纸点亮拼豆板")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 8) {
                    // 只用 board.isConnected（BoardSession 自己的 @Published，已验证会驱动本视图刷新）；
                    // 不直接读 board.central.linkState —— central 的变化不一定触发 HomeView 重渲染。
                    heroCapsule(board.isConnected ? "拼豆板已连接" : "拼豆板未连接",
                                systemImage: board.isConnected ? "lightbulb.fill" : "lightbulb")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 130)
    }

    // MARK: 快速开始：两大一小渐变入口卡

    private var quickStart: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                entryCard(title: "照片转图纸", subtitle: "一键生成像素图",
                          icon: "photo.on.rectangle.angled", gradient: Theme.mint)
                { ConvertView() }
                entryCard(title: "手绘画布", subtitle: "自由绘制创作",
                          icon: "square.and.pencil", gradient: Theme.amber)
                { EditorView(pattern: nil, initialSize: 29) }
            }
            NavigationLink { TemplateGalleryView() } label: {
                HStack(spacing: 14) {
                    Image(systemName: "gift.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("从模板开始").font(.headline).foregroundStyle(.white)
                        Text("内置图纸模板，直接开拼").font(.caption).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.white.opacity(0.7))
                }
                .padding(16)
                .background(Theme.violet, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func entryCard<Destination: View>(title: String, subtitle: String,
                                              icon: String, gradient: LinearGradient,
                                              @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink { destination() } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: 拼制中：横向滚动卡片

    private var inProgressRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("拼制中", systemImage: "progresscircle")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(inProgress) { p in
                        NavigationLink { WorkDetailView(pattern: p) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(uiImage: p.thumbnailImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 96)
                                    .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(p.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                ProgressView(value: p.progressPercent)
                                    .tint(Theme.accent)
                                Text("\(Int(p.progressPercent * 100))% · \(p.width)×\(p.height)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(width: 150)
                            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: 统计 + 库存

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("统计", systemImage: "chart.bar.fill")
            HStack(spacing: 0) {
                statBlock("\(patterns.count)", "全部图纸")
                statDivider
                statBlock("\(inProgress.count)", "拼制中")
                statDivider
                statBlock("\(done.count)", "已完成")
            }
        }
        .cardStyle()
    }

    private var stockCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("库存", systemImage: "square.stack.3d.up.fill")
            if stocks.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tray").foregroundStyle(.tertiary)
                    Text("还没录入库存，去「库存」Tab 添加")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            } else {
                HStack(spacing: 0) {
                    statBlock("\(stocks.count)", "已录入色号")
                    statDivider
                    statBlock("\(totalStockQuantity)", "总豆量")
                }
                Text("库存充足，图纸详情可查看消耗预估")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.15))
            .frame(width: 1, height: 28)
    }

    private func statBlock(_ value: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.bold())
            .foregroundStyle(.primary)
    }
}

// MARK: - 图纸行（全局复用的紧凑卡片行）

struct PatternRow: View {
    let pattern: Pattern

    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: pattern.thumbnailImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
                .padding(5)
                .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(pattern.name).font(.headline)
                HStack(spacing: 6) {
                    Text("\(pattern.width)×\(pattern.height)")
                    Text(pattern.status.label)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(pattern.status.color.opacity(0.15))
                        .foregroundStyle(pattern.status.color)
                        .clipShape(Capsule())
                    if pattern.status == .inProgress {
                        Text("\(Int(pattern.progressPercent * 100))%")
                            .foregroundStyle(Theme.accent)
                            .bold()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
