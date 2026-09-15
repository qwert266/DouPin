import SwiftData
import SwiftUI

// MARK: - 语言与极简本地化

/// 界面语言（system = 跟随系统）
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case zh = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L10n.s("跟随系统")
        case .zh: return L10n.s("简体中文")
        case .en: return "English"
        }
    }
}

/// 极简本地化工具：`L10n.t("设置", "Settings")`。
///
/// 说明：当前仅覆盖核心界面（Tab 标题、设置页、首页主文案），其余文案仍为中文，
/// 后续版本逐步补齐；不引入 `.strings` 资源以规避手写 pbxproj 的 variant group 风险。
enum L10n {
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "system") ?? .system
    }

    static func t(_ zh: String, _ en: String) -> String {
        switch current {
        case .zh: return zh
        case .en: return en
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
            return preferred.hasPrefix("zh") ? zh : en
        }
    }
}

// MARK: - 色板访问控制（档位 → 允许的色号）

/// 依据「设置 → 色板档位」计算允许参与匹配/选色的色号。
/// - 返回 `nil` 表示不限制（全色板）
@MainActor
enum PaletteAccess {

    /// - Parameters:
    ///   - tierRaw: `@AppStorage("paletteTier")` 原始值（PaletteTier.rawValue）
    ///   - stocks: 库存（`stockOnly` 档位用）
    static func allowedIds(tierRaw: Int, stocks: [BeadStock]) -> [Int]? {
        guard let tier = PaletteTier(rawValue: tierRaw) else { return nil }
        if tier == .stockOnly {
            let ids = Set(stocks.filter { $0.quantity > 0 && $0.colorId > 0 }.map(\.colorId))
            return ids.isEmpty ? nil : ids.sorted()
        }
        return tier.colorIds
    }

    /// 当前档位可用的颜色数（用于设置页摘要文案）
    static func count(tierRaw: Int, stocks: [BeadStock]) -> Int {
        allowedIds(tierRaw: tierRaw, stocks: stocks)?.count ?? BeadPalette.all.count
    }
}

// MARK: - 检测更新（GitHub 仓库最新提交对比）

/// 检查 GitHub 仓库最新提交与当前构建的差异。
///
/// 构建号来源：GitHub Actions 构建时通过 `INFOPLIST_KEY_DouPinCommit=<短 SHA>` 注入，
/// App 内读 `Bundle.main` 的 `DouPinCommit`；本地/旧包缺失时显示「未知」。
@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)      // 最新短 SHA
        case available(String)     // 远端短 SHA（与本地不同）
        case unknownLocal(String)  // 本地包未注入构建号（旧包），仅报告远端
        case failed(String)
    }

    @Published var state: State = .idle

    /// 当前构建号（短 SHA）；CI 注入，本地/旧包为 "dev"
    static var localCommit: String {
        BuildInfo.commit.isEmpty ? L10n.s("未知") : BuildInfo.commit
    }

    /// 构建时间（CI 注入的 ISO8601 UTC 串；本地为空）
    static var localBuiltAt: String {
        BuildInfo.builtAt
    }

    static let repoURL = URL(string: "https://github.com/qwert266/DouPin")!

    func check() async {
        state = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/qwert266/DouPin/commits?per_page=1")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = arr.first,
                  let sha = first["sha"] as? String else {
                state = .failed(L10n.s("返回数据无法解析"))
                return
            }
            let remote = String(sha.prefix(7))
            let local = Self.localCommit
            if local == "dev" || local == "未知" {
                state = .unknownLocal(remote)
            } else if local.caseInsensitiveCompare(remote) == .orderedSame {
                state = .upToDate(remote)
            } else {
                state = .available(remote)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

// MARK: - 设置页

/// 设置：拼豆板规格、色板档位、连接偏好、外观与反馈、更新、存储。
@MainActor
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var patterns: [Pattern]
    @Query private var stocks: [BeadStock]

    // 拼豆板
    @AppStorage("defaultBoardSide") private var defaultBoardSide = 29
    @AppStorage("boardPreset") private var boardPreset = ""

    // 颜色
    @AppStorage("paletteTier") private var paletteTier = PaletteTier.full.rawValue

    // 连接
    @AppStorage("autoConnectBLE") private var autoConnectBLE = true
    @AppStorage("guideDefaultBrightness") private var guideDefaultBrightness = 80
    @AppStorage("guideUseNeighborRows") private var guideUseNeighborRows = true

    // 外观与反馈
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("appLanguage") private var appLanguage = AppLanguage.system.rawValue
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    @StateObject private var updater = UpdateChecker()
    @State private var showClearImagesConfirm = false
    @State private var showClearTempConfirm = false
    @State private var toast: String?

    var body: some View {
        List {
            boardSection
            colorSection
            connectionSection
            appearanceSection
            updateSection
            storageSection
        }
        .themedListPage()
        .navigationTitle(L10n.t("设置", "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(L10n.s("清除全部原图？"),
                            isPresented: $showClearImagesConfirm,
                            titleVisibility: .visible) {
            Button(L10n.s("清除全部原图"), role: .destructive) { clearAllSourceImages() }
            Button(L10n.s("取消"), role: .cancel) { }
        } message: {
            Text(L10n.p("将删除所有图纸保留的原图缓存（{0}）。图纸本身、色号与进度都会保留。此操作不可撤销。", "\(Self.formatBytes(imageCacheBytes))"))
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        self.toast = nil
                    }
            }
        }
    }

    // MARK: 拼豆板规格

    private var boardSection: some View {
        Section {
            Picker(L10n.s("板规格"), selection: $boardPreset) {
                boardOption(BoardPreset.pd25)
                boardOption(BoardPreset.pd52)
                boardOption(BoardPreset.pd78)
                boardOption(BoardPreset.pd104)
                boardOption(BoardPreset.custom)
            }
            .onChange(of: boardPreset) { _, newValue in
                if let preset = BoardPreset(rawValue: newValue), let side = preset.side {
                    defaultBoardSide = side
                }
            }

            if BoardPreset(rawValue: boardPreset)?.side == nil {
                Stepper(value: $defaultBoardSide, in: 16...104, step: 1) {
                    LabeledContent(L10n.k("边长"), value: L10n.p("{0} 格", "\(defaultBoardSide)"))
                }
            }

            LabeledContent(L10n.k("当前默认板"), value: L10n.p("{0} × {1} 格", "\(defaultBoardSide)", "\(defaultBoardSide)"))
        } header: {
            Text(L10n.s("拼豆板规格"))
        } footer: {
            Text(L10n.s("52 钉 ≈ 14cm、78 钉 ≈ 21cm、104 钉 ≈ 28cm。新建手绘、拆板与尺寸分离以此作为默认板尺寸；灯板发图尺寸始终按图纸本身。"))
        }
    }

    private func boardOption(_ preset: BoardPreset) -> some View {
        Text(preset.side == nil ? preset.title : "\(preset.title)（\(preset.detail)）")
            .tag(preset.rawValue)
    }

    // MARK: 色板档位

    private var colorSection: some View {
        Section {
            Picker(L10n.s("色板档位"), selection: $paletteTier) {
                ForEach(PaletteTier.allCases) { tier in
                    Text(L10n.s(tier.title)).tag(tier.rawValue)
                }
            }

            LabeledContent(L10n.k("可用于匹配"), value: L10n.p("{0} 种颜色", "\(availableColorCount)"))
        } header: {
            Text(L10n.s("颜色"))
        } footer: {
            Text(paletteTierNote)
        }
    }

    private var paletteTierNote: String {
        if paletteTier == PaletteTier.stockOnly.rawValue {
            return L10n.s("仅使用库存中数量大于 0 的色号——转图与选色只会用到你手上有的颜色，避免配不到色。")
        }
        return L10n.s("档位按 Mard 色号顺序取前 N 色，与出厂套装一致；若与你的实物色卡不符，请选「仅我的库存色」，或在库存页录入你实际拥有的色号。")
    }

    private var availableColorCount: Int {
        PaletteAccess.count(tierRaw: paletteTier, stocks: stocks)
    }

    // MARK: 连接偏好

    private var connectionSection: some View {
        Section {
            Toggle(L10n.s("自动连接拼豆板"), isOn: $autoConnectBLE)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.s("默认亮度")).font(.subheadline)
                    Spacer()
                    Text("\(guideDefaultBrightness)%")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                Slider(value: Binding(get: { Double(guideDefaultBrightness) },
                                      set: { guideDefaultBrightness = Int($0.rounded()) }),
                       in: 10...100, step: 5)
                    .tint(Theme.accent)
            }

            Toggle(L10n.s("引导时微亮相邻行"), isOn: $guideUseNeighborRows)
        } header: {
            Text(L10n.s("连接与灯板"))
        } footer: {
            Text(L10n.s("开启自动连接后，点任意页面右上角的「连接」会直接搜索并连上 PIXDOU 板子；关闭后改为弹出面板手动选择。亮度与相邻行微亮用于行/分色引导。"))
        }
    }

    // MARK: 外观与反馈

    private var appearanceSection: some View {
        Section {
            Picker(L10n.s("主题"), selection: $appTheme) {
                Text(L10n.s("跟随系统")).tag("system")
                Text(L10n.s("浅色")).tag("light")
                Text(L10n.s("深色")).tag("dark")
            }
            Picker(L10n.s("语言"), selection: $appLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.title).tag(lang.rawValue)
                }
            }
            Toggle(L10n.s("触觉反馈"), isOn: $hapticsEnabled)
        } header: {
            Text(L10n.s("外观与反馈"))
        } footer: {
            Text(L10n.s("英文界面正在逐步补齐（当前覆盖标签栏、设置页与首页主文案）。"))
        }
    }

    // MARK: 更新

    private var updateSection: some View {
        Section {
            LabeledContent(L10n.k("当前版本"), value: versionText)
            LabeledContent(L10n.k("构建"), value: UpdateChecker.localCommit)
            if !UpdateChecker.localBuiltAt.isEmpty {
                LabeledContent(L10n.k("构建时间"), value: Self.formatBuiltAt(UpdateChecker.localBuiltAt))
            }

            Button {
                Task { await updater.check() }
            } label: {
                HStack {
                    Label(L10n.s("检测更新"), systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if updater.state == .checking { ProgressView() }
                }
            }
            .disabled(updater.state == .checking)

            if let message = updateMessage {
                Label(message.text, systemImage: message.icon)
                    .font(.caption)
                    .foregroundStyle(message.color)
            }

            Link(destination: UpdateChecker.repoURL) {
                Label(L10n.s("打开项目仓库（下载最新 IPA）"), systemImage: "link")
            }
        } header: {
            Text(L10n.s("更新"))
        } footer: {
            Text(L10n.s("构建号来自云端构建注入的提交短 SHA；与仓库最新提交一致即为最新版。"))
        }
    }

    private var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2"
        return v
    }

    private var updateMessage: (text: String, icon: String, color: Color)? {
        switch updater.state {
        case .idle:
            return nil
        case .checking:
            return (L10n.s("正在检查…"), "clock", .secondary)
        case .upToDate(let sha):
            return (L10n.p("已是最新版本（{0}）", "\(sha)"), "checkmark.seal.fill", .green)
        case .available(let sha):
            return (L10n.p("发现新版本（远端 {0}）——点上方仓库链接下载最新 IPA", "\(sha)"), "arrow.down.circle.fill", .orange)
        case .unknownLocal(let sha):
            return (L10n.p("远端最新提交 {0}（本包未注入构建号，无法精确对比）", "\(sha)"), "info.circle.fill", .secondary)
        case .failed(let reason):
            return (L10n.p("检查失败：{0}", "\(reason)"), "exclamationmark.triangle.fill", .orange)
        }
    }

    // MARK: 存储

    private var storageSection: some View {
        Section {
            LabeledContent(L10n.k("原图缓存占用"), value: Self.formatBytes(imageCacheBytes))
            Button(role: .destructive) {
                showClearImagesConfirm = true
            } label: {
                Label(L10n.s("清除全部原图"), systemImage: "photo.badge.exclamationmark")
            }
            .disabled(imageCacheBytes == 0)

            Button(role: .destructive) {
                showClearTempConfirm = true
            } label: {
                Label(L10n.s("清理临时导出文件"), systemImage: "trash")
            }
        } header: {
            Text(L10n.s("存储"))
        } footer: {
            Text(L10n.s("「原图缓存」仅指照片转图纸时保留的原图；清除后图纸本身与进度不受影响。临时导出文件指应用临时目录下的 PDF 导出件。"))
        }
        .confirmationDialog(L10n.s("清理临时导出文件？"),
                            isPresented: $showClearTempConfirm,
                            titleVisibility: .visible) {
            Button(L10n.s("清理"), role: .destructive) { clearTemporaryExports() }
            Button(L10n.s("取消"), role: .cancel) { }
        } message: {
            Text(L10n.s("将删除应用临时目录下的 PDF 导出文件（不影响已保存到「文件」的副本）。"))
        }
    }

    /// 清理临时目录下的 PDF 导出文件
    private func clearTemporaryExports() {
        let dir = FileManager.default.temporaryDirectory
        let manager = FileManager.default
        var deleted = 0
        let contents = (try? manager.contentsOfDirectory(at: dir,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
        for url in contents where url.pathExtension.lowercased() == "pdf" {
            if (try? manager.removeItem(at: url)) != nil { deleted += 1 }
        }
        toast = deleted > 0 ? L10n.p("已清理 {0} 个临时导出文件", "\(deleted)") : L10n.s("没有发现临时导出文件")
    }

    private var imageCacheBytes: Int {
        patterns.reduce(0) { $0 + ($1.sourceImageData?.count ?? 0) }
    }

    private func clearAllSourceImages() {
        var removed = 0
        for p in patterns where p.sourceImageData != nil {
            p.sourceImageData = nil
            removed += 1
        }
        try? context.save()
        toast = removed > 0 ? L10n.p("已清除 {0} 张原图缓存", "\(removed)") : L10n.s("没有可清除的原图缓存")
    }

    /// ISO8601(UTC) → 本地「yyyy-MM-dd HH:mm」
    private static func formatBuiltAt(_ iso: String) -> String {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "yyyy-MM-dd HH:mm"
        return out.string(from: date)
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1.0 { return "\(bytes) B" }
        let mb = kb / 1024.0
        if mb < 1.0 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", mb)
    }
}
