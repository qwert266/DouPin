import Foundation

/// 构建信息（由 CI 覆盖生成）。
///
/// 仓库里的这份是**占位值**；GitHub Actions 在构建前会用当前提交重写本文件，
/// 因此「设置 → 检测更新」能拿到真实构建号与仓库最新提交做对比。
/// 本地 Xcode 构建保持占位值即可。
enum BuildInfo {
    /// 提交短 SHA（CI 注入；本地为 "dev"）
    static let commit = "dev"
    /// 构建时间（ISO8601，UTC；本地为空）
    static let builtAt = ""
}
