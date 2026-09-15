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
            if local == "dev" || local == L10n.s("未知") {
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
