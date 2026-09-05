import SwiftData
import SwiftUI

@main
struct DouPinApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Pattern.self)
        } catch {
            fatalError("无法初始化数据库：\(error)")
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
}
