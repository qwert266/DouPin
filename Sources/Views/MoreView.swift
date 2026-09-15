import SwiftData
import SwiftUI

// MARK: - 「我的」Tab（设置中心：规格 / 颜色 / 连接 / 外观 / 更新 / 存储 + 工具 + 关于）
//
// 说明：原「设置」二级页已整体并入本页——板规格、色板档位等常用项直接可见，不再多跳一层。
// `SettingsView.swift` 仅保留 AppLanguage / L10n / PaletteAccess / UpdateChecker 等全局类型。

@MainActor
struct MoreView: View {
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
        NavigationStack {
            List {
                brandHero
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                boardSection
                colorSection
                connectionSection
                appearanceSection
                updateSection
                storageSection
                toolSection
                aboutSection
            }
            .themedListPage()
            .navigationTitle(L10n.t("我的", "Me"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BoardConnectCapsule()
                }
            }
            .confirmationDialog(L10n.s("清除全部原图？"),
                                isPresented: $showClearImagesConfirm,
                                titleVisibility: .visible) {
                Button(L10n.s("清除全部原图"), role: .destructive) { clearAllSourceImages() }
                Button(L10n.s("取消"), role: .cancel) { }
            } message: {
                Text(L10n.p("将删除所有图纸保留的原图缓存（{0}）。图纸本身、色号与进度都会保留。此操作不可撤销。",
                            Self.formatBytes(imageCacheBytes)))
            }
            .confirmationDialog(L10n.s("清理临时导出文件？"),
                                isPresented: $showClearTempConfirm,
                                titleVisibility: .visible) {
                Button(L10n.s("清理"), role: .destructive) { clearTemporaryExports() }
                Button(L10n.s("取消"), role: .cancel) { }
            } message: {
                Text(L10n.s("将删除应用临时目录下的 PDF 导出文件（不影响已保存到「文件」的副本）。"))
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
    }

    // MARK: - 品牌英雄卡

    private var brandHero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.brand)
            BeadDots()
                .padding(.top, 14).padding(.trailing, 16)
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.22))
                        .frame(width: 50, height: 50)
                    Image(systemName: "lightbulb.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.s("豆绘小栈"))
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(L10n.s("照片变图纸 · 图纸点亮拼豆板"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(L10n.s("版本 1.2 · 本地优先 · 无账户"))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }
            .padding(16)
        }
        .frame(height: 92)
        .shadow(color: Theme.accent.opacity(0.22), radius: 10, y: 4)
    }

    // MARK: - 拼豆板规格

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
                    LabeledContent(L10n.k(L10n.s("边长")), value: L10n.p("{0} 格", "\(defaultBoardSide)"))
                }
            }

            LabeledContent(L10n.k(L10n.s("当前默认板")),
                           value: L10n.p("{0} × {1} 格", "\(defaultBoardSide)", "\(defaultBoardSide)"))
        } header: {
            Text(L10n.s("拼豆板规格"))
        } footer: {
            Text(L10n.s("52 钉 ≈ 14cm、78 钉 ≈ 21cm、104 钉 ≈ 28cm。新建手绘、拆板与尺寸分离以此作为默认板尺寸；灯板发图尺寸始终按图纸本身。"))
        }
    }

    private func boardOption(_ preset: BoardPreset) -> some View {
        Text(preset.side == nil ? L10n.s(preset.title) : "\(preset.title)（\(preset.detail)）")
            .tag(preset.rawValue)
    }

    // MARK: - 颜色规格（色板档位）

    private var colorSection: some View {
        Section {
            Picker(L10n.s("色板档位"), selection: $paletteTier) {
                ForEach(PaletteTier.allCases) { tier in
                    Text(L10n.s(tier.title)).tag(tier.rawValue)
                }
            }

            LabeledContent(L10n.k(L10n.s("可用于匹配")), value: L10n.p("{0} 种颜色", "\(availableColorCount)"))
        } header: {
            Text(L10n.s("颜色规格"))
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

    // MARK: - 连接与灯板

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

    // MARK: - 外观与反馈

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
            Text(L10n.s("界面文案已全量支持中英文；切换后立即生效。"))
        }
    }

    // MARK: - 更新

    private var updateSection: some View {
        Section {
            LabeledContent(L10n.k(L10n.s("当前版本")), value: versionText)
            LabeledContent(L10n.k(L10n.s("构建")), value: UpdateChecker.localCommit)
            if !UpdateChecker.localBuiltAt.isEmpty {
                LabeledContent(L10n.k(L10n.s("构建时间")), value: Self.formatBuiltAt(UpdateChecker.localBuiltAt))
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2"
    }

    private var updateMessage: (text: String, icon: String, color: Color)? {
        switch updater.state {
        case .idle:
            return nil
        case .checking:
            return (L10n.s("正在检查…"), "clock", .secondary)
        case .upToDate(let sha):
            return (L10n.p("已是最新版本（{0}）", sha), "checkmark.seal.fill", .green)
        case .available(let sha):
            return (L10n.p("发现新版本（远端 {0}）——点上方仓库链接下载最新 IPA", sha), "arrow.down.circle.fill", .orange)
        case .unknownLocal(let sha):
            return (L10n.p("远端最新提交 {0}（本包未注入构建号，无法精确对比）", sha), "info.circle.fill", .secondary)
        case .failed(let reason):
            return (L10n.p("检查失败：{0}", reason), "exclamationmark.triangle.fill", .orange)
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section {
            LabeledContent(L10n.k(L10n.s("原图缓存占用")), value: Self.formatBytes(imageCacheBytes))
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

    private func clearTemporaryExports() {
        let manager = FileManager.default
        let dir = manager.temporaryDirectory
        var deleted = 0
        let contents = (try? manager.contentsOfDirectory(at: dir,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
        for url in contents where url.pathExtension.lowercased() == "pdf" {
            if (try? manager.removeItem(at: url)) != nil { deleted += 1 }
        }
        toast = deleted > 0 ? L10n.p("已清理 {0} 个临时导出文件", "\(deleted)") : L10n.s("没有发现临时导出文件")
    }

    // MARK: - 工具

    private var toolSection: some View {
        Section {
            NavigationLink {
                GalleryView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.s("作品集")).font(.headline)
                        Text(L10n.s("成品归档 · 作品分享卡")).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "photo.stack.fill")
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Theme.violet, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .cardRow()

            NavigationLink {
                StatsView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.s("数据中心")).font(.headline)
                        Text(L10n.s("消耗排行 · 补豆清单 · 色系分布")).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "chart.pie.fill")
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .cardRow()

            NavigationLink {
                PatternMergeView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.s("合并图纸")).font(.headline)
                        Text(L10n.s("多图拼一张大图")).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "square.on.square.dashed")
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Theme.amber, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .cardRow()
        } header: {
            Text(L10n.s("工具"))
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text(L10n.s("豆绘小栈")).font(.headline)
            } label: {
                Label(L10n.s("应用名"), systemImage: "app.badge")
            }
            .cardRow()

            LabeledContent(L10n.k(L10n.s("版本")), value: "1.2")
                .cardRow()

            Text(L10n.s("本地优先 · 无账户 · 数据只存在你的设备上"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .cardRow()

            NavigationLink {
                BoardLogView()
            } label: {
                Label(L10n.s("蓝牙日志控制台"), systemImage: "terminal")
            }
            .cardRow()
        } header: {
            Text(L10n.s("关于"))
        }
    }

    // MARK: - 工具方法

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
