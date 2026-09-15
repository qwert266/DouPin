import SwiftData
import SwiftUI

@main
struct DouPinApp: App {
    let container: ModelContainer

    init() {
        do {
            // 功能融合 T01：Schema 扩容，纳入新增实体 PatternFolder / BeadStock。
            // 现有 Pattern 仅加字段、不加关系，全部新字段带默认值 → SwiftData 自动轻量迁移，无需 MigrationPlan。
            container = try ModelContainer(
                for: Pattern.self,
                PatternFolder.self,
                BeadStock.self
            )
        } catch {
            fatalError(L10n.p("无法初始化数据库：{0}", "\(error)"))
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environmentObject(AppState.shared)
        }
        .modelContainer(container)
    }
}

/// 全局共享状态
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    let board = BoardSession()

    /// 默认板尺寸（边长，格）；29 = 常见标准板。用于拆板/尺寸分离的默认值。
    @AppStorage("defaultBoardSide")
    var defaultBoardSide: Int = 29
}
