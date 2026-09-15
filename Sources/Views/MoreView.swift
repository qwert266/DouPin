import SwiftData
import SwiftUI

// MARK: - 「我的」Tab（品牌卡 / 工具 / 关于）
//
// 说明：默认板尺寸、引导偏好、默认亮度、主题/语言/触觉、存储清理等偏好项
// 已统一迁至「设置」页（`SettingsView`）；本页只保留入口与关于信息，避免两处重复配置。

@MainActor
struct MoreView: View {
    @Environment(\.modelContext) private var context
    @Query private var patterns: [Pattern]

    @State private var toast: String?

    var body: some View {
        NavigationStack {
            List {
                brandHero
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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

    // MARK: - 工具

    private var toolSection: some View {
        Section {
            NavigationLink {
                SettingsView()
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.s("设置")).font(.headline)
                        Text(L10n.s("板规格 · 色板档位 · 语言 · 更新")).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Theme.sky, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .cardRow()

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

            LabeledContent(L10n.k("版本"), value: "1.2")
                .cardRow()

            LabeledContent(L10n.k("构建"), value: UpdateChecker.localCommit)
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

            Link(destination: UpdateChecker.repoURL) {
                Label(L10n.s("项目仓库"), systemImage: "link")
            }
            .cardRow()
        } header: {
            Text(L10n.s("关于"))
        }
    }
}
