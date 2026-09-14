import SwiftData
import SwiftUI

// MARK: - 「我的」Tab（设置 / 存储清理 / 关于）

/// 「我的」Tab 根视图（T05 替换原 `MorePlaceholderView`）。
///
/// 结构：`NavigationStack` + `List` + `Section`。
/// - 默认板尺寸：`@AppStorage("defaultBoardSide")`，范围 16...64，步进常用值；
/// - 引导偏好：`@AppStorage("guideUseNeighborRows")`（默认 true）、
///   `@AppStorage("guideDefaultBrightness")`（默认 80）；
/// - 存储清理：统计全部 `Pattern.sourceImageData` 占用、清除全部原图、清理临时导出 PDF；
/// - 关于：应用信息 + 蓝牙日志控制台入口（`BoardLogView`，定义于 `BoardTabView.swift`）。
///
/// 注意：本视图自身携带 `NavigationStack`（与其他 Tab 根一致，参照 `InventoryView` / `HomeView`）。
@MainActor
struct MoreView: View {
    @Environment(\.modelContext) private var context
    @Query private var patterns: [Pattern]

    /// 默认板尺寸（边长，格）；与 `AppState.shared.defaultBoardSide` 共用同一 key。
    @AppStorage("defaultBoardSide") private var defaultBoardSide: Int = 29
    /// 引导时是否微亮相邻行
    @AppStorage("guideUseNeighborRows") private var guideUseNeighborRows: Bool = true
    /// 默认亮度百分比
    @AppStorage("guideDefaultBrightness") private var guideDefaultBrightness: Int = 80

    /// 全套可选板尺寸（常用值，覆盖 16...64 范围）
    private static let boardSides: [Int] = [16, 24, 29, 32, 48, 64]

    /// 清除原图二次确认开关
    @State private var showClearImagesConfirm = false
    /// 清理临时文件二次确认开关
    @State private var showClearTempConfirm = false
    /// 操作结果提示
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                brandHero
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                toolSection
                boardSection
                guideSection
                storageSection
                aboutSection
            }
            .themedListPage()
            .navigationTitle("我的")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    BoardConnectCapsule()
                }
            }
            .confirmationDialog("清除全部原图？",
                                isPresented: $showClearImagesConfirm,
                                titleVisibility: .visible) {
                Button("清除全部原图", role: .destructive) { clearAllSourceImages() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("将删除所有图纸保留的原图缓存（\(imageCacheText)）。图纸本身、色号与进度都会保留。此操作不可撤销。")
            }
            .confirmationDialog("清理临时导出文件？",
                                isPresented: $showClearTempConfirm,
                                titleVisibility: .visible) {
                Button("清理", role: .destructive) { clearTemporaryExports() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("将删除应用临时目录下的 PDF 导出文件（不影响已保存到「文件」的副本）。")
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
                    Text("豆绘小栈")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("照片变图纸 · 图纸点亮拼豆板")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    Text("版本 1.2 · 本地优先 · 无账户")
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

    // MARK: - 工具（数据中心 / 合并图纸）

    private var toolSection: some View {
        Section {
            NavigationLink {
                GalleryView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("作品集").font(.headline)
                        Text("成品归档 · 作品分享卡").font(.caption).foregroundStyle(.secondary)
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
                        Text("数据中心").font(.headline)
                        Text("消耗排行 · 补豆清单 · 色系分布").font(.caption).foregroundStyle(.secondary)
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
                        Text("合并图纸").font(.headline)
                        Text("多图拼一张大图").font(.caption).foregroundStyle(.secondary)
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
            Text("工具")
        }
    }

    // MARK: - 默认板尺寸

    private var boardSection: some View {
        Section {
            Picker("默认板尺寸", selection: $defaultBoardSide) {
                ForEach(Self.boardSides, id: \.self) { side in
                    Text("\(side) × \(side) 格").tag(side)
                }
            }
            .cardRow()
            LabeledContent("当前默认尺寸", value: "\(defaultBoardSide) × \(defaultBoardSide) 格")
                .font(.subheadline)
                .cardRow()
        } header: {
            Text("默认板尺寸")
        } footer: {
            Text("新建手绘、拆板与消耗预估会以此尺寸作为初始值。")
        }
    }

    // MARK: - 引导偏好

    private var guideSection: some View {
        Section {
            Toggle("引导时微亮相邻行", isOn: $guideUseNeighborRows)
                .cardRow()
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("默认亮度", value: "\(guideDefaultBrightness)%")
                Slider(value: Binding(
                    get: { Double(guideDefaultBrightness) },
                    set: { guideDefaultBrightness = Int($0.rounded()) }),
                    in: 10...100, step: 5)
                .disabled(!guideUseNeighborRows)
            }
            .cardRow()
        } header: {
            Text("引导偏好")
        } footer: {
            Text("分色/逐行引导会按这里的默认值初始化；发送到拼豆板后仍可实时调整。")
        }
    }

    // MARK: - 存储清理

    private var storageSection: some View {
        Section {
            LabeledContent("原图缓存占用", value: imageCacheText)
                .cardRow()

            Button(role: .destructive) {
                showClearImagesConfirm = true
            } label: {
                Label("清除全部原图", systemImage: "photo.badge.exclamationmark")
            }
            .disabled(imageCacheBytes == 0)
            .cardRow()

            Button(role: .destructive) {
                showClearTempConfirm = true
            } label: {
                Label("清理临时导出文件", systemImage: "trash")
            }
            .cardRow()
        } header: {
            Text("存储清理")
        } footer: {
            Text("「原图缓存」仅指照片转图纸时保留的原图；清除后图纸本身与进度不受影响。")
        }
    }

    /// 全部图纸原图缓存总字节数
    private var imageCacheBytes: Int {
        patterns.reduce(0) { total, p in total + (p.sourceImageData?.count ?? 0) }
    }

    /// 格式化为 KB / MB 的占位文案
    private var imageCacheText: String {
        Self.formatBytes(imageCacheBytes)
    }

    /// 字节数格式化：< 1KB 显示 B，< 1MB 显示 KB，否则显示 MB
    private static func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1.0 { return "\(bytes) B" }
        let mb = kb / 1024.0
        if mb < 1.0 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", mb)
    }

    /// 清除全部图纸的原图缓存（保留图纸本体）
    private func clearAllSourceImages() {
        var removed = 0
        for p in patterns where p.sourceImageData != nil {
            p.sourceImageData = nil
            removed += 1
        }
        try? context.save()
        toast = removed > 0 ? "已清除 \(removed) 张原图缓存" : "没有可清除的原图缓存"
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
        toast = deleted > 0 ? "已清理 \(deleted) 个临时导出文件" : "没有发现临时导出文件"
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent {
                Text("豆绘小栈").font(.headline)
            } label: {
                Label("应用名", systemImage: "app.badge")
            }
            .cardRow()
            LabeledContent("版本", value: "1.0")
                .cardRow()
            Text("本地优先 · 无账户 · 数据只存在你的设备上")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .cardRow()

            NavigationLink {
                BoardLogView()
            } label: {
                Label("蓝牙日志控制台", systemImage: "terminal")
            }
            .cardRow()
        } header: {
            Text("关于")
        }
    }
}
