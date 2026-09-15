import Foundation

/// 库存批量导入文本解析器（无状态 Service）
///
/// 依据 PRD §5.1 与架构师 §A.5.3 / §B.8：
/// - 输入：用户粘贴的多行文本；
/// - 输出：**结构化结果**（成功项 + 失败行），**不抛异常**。
///
/// 单行格式（宽松解析，分隔符支持空格 / 逗号 / 制表符）：
/// ```
/// A1 500
/// A1,500
/// A1	500
/// ```
/// 色号为 Mard 编号（形如 `A1` / `H7` / `GB1` / `Z8`），需能反查到 `BeadPalette` 中的
/// `BeadColor.mard`（大小写不敏感）；数量为非负整数（负数钳制为 0）。
enum StockTextParser {

    // MARK: - 结果类型

    /// 解析成功项
    struct ParsedItem: Identifiable, Hashable {
        /// 唯一标识（供 SwiftUI 列表使用）
        let id = UUID()
        /// 官方色号（1…295）
        let colorId: Int
        /// 展示用 Mard 色号（如 "A1"）
        let mard: String
        /// 解析出的数量（≥ 0）
        let quantity: Int
    }

    /// 解析失败项
    struct FailedLine: Identifiable, Hashable {
        /// 唯一标识（供 SwiftUI 列表使用）
        let id = UUID()
        /// 原始行号（从 1 开始，方便用户定位）
        let line: Int
        /// 该行原始文本（去除首尾空白后）
        let text: String
        /// 失败原因（中文，直接展示给用户）
        let reason: String
    }

    /// 解析总结果
    struct ParseResult {
        /// 成功解析的条目（保持原文顺序）
        let ok: [ParsedItem]
        /// 失败的行（保持原文顺序）
        let failed: [FailedLine]

        /// 空结果
        static let empty = ParseResult(ok: [], failed: [])

        /// 是否全部成功（无失败行）
        var isAllOK: Bool { failed.isEmpty }

        /// 成功条数
        var okCount: Int { ok.count }

        /// 失败行数
        var failedCount: Int { failed.count }
    }

    // MARK: - Mard → colorId 反查表（静态缓存）

    /// Mard 色号（大写）→ 官方色号 的查表
    ///
    /// 说明：`BeadColor.mard` 在同一色板中唯一，故可直接以大写 Mard 作 key。
    private static let mardToId: [String: Int] = {
        var map: [String: Int] = [:]
        for c in BeadPalette.all where map[c.mard.uppercased()] == nil {
            map[c.mard.uppercased()] = c.id
        }
        return map
    }()

    // MARK: - 对外接口

    /// 解析多行文本
    /// - Parameter text: 用户粘贴的原始文本（可含空行 / 多余空白）
    /// - Returns: 结构化解析结果（成功项 + 失败行），**不抛异常**
    static func parse(_ text: String) -> ParseResult {
        var ok: [ParsedItem] = []
        var failed: [FailedLine] = []

        let rawLines = text.components(separatedBy: .newlines)
        for (idx, raw) in rawLines.enumerated() {
            let lineNo = idx + 1
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 跳过完全空行（不计入失败）
            if trimmed.isEmpty { continue }

            if let item = parseLine(trimmed) {
                ok.append(item)
            } else {
                failed.append(FailedLine(line: lineNo, text: trimmed, reason: reason(for: trimmed)))
            }
        }
        return ParseResult(ok: ok, failed: failed)
    }

    /// 把 Mard 色号反查为官方色号 `colorId`
    /// - Parameter mard: Mard 编号（大小写不敏感，忽略首尾空白）
    /// - Returns: 命中的 `colorId`；未命中返回 nil
    static func colorId(forMard mard: String) -> Int? {
        let key = mard.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return nil }
        return mardToId[key]
    }

    // MARK: - 行解析

    /// 解析单行（已去除首尾空白、非空）
    /// - Parameter line: 单行文本
    /// - Returns: 解析成功返回 `ParsedItem`，否则 nil
    private static func parseLine(_ line: String) -> ParsedItem? {
        let tokens = splitTokens(line)
        // 至少需要「色号 + 数量」两个 token
        guard tokens.count >= 2 else { return nil }

        let mard = tokens[0]
        let qtyText = tokens[1]

        guard let cid = colorId(forMard: mard) else { return nil }
        guard let qty = Int(qtyText) else { return nil }

        return ParsedItem(colorId: cid, mard: mard.uppercased(), quantity: max(0, qty))
    }

    /// 按空格 / 逗号 / 制表符拆分，并丢弃空 token
    /// - Parameter line: 单行文本
    /// - Returns: 拆分后的 token 数组
    private static func splitTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in line {
            if ch == " " || ch == "," || ch == "\t" || ch == "，" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// 生成失败原因（中文）
    /// - Parameter line: 单行文本
    /// - Returns: 面向用户的失败原因
    private static func reason(for line: String) -> String {
        let tokens = splitTokens(line)
        if tokens.count < 2 {
            return L10n.s("无法识别：需要「色号 数量」两个字段")
        }
        if colorId(forMard: tokens[0]) == nil {
            return L10n.p("无法识别：色号「{0}」不在 295 色板中", "\(tokens[0])")
        }
        if Int(tokens[1]) == nil {
            return L10n.p("无法识别：数量「{0}」不是整数", "\(tokens[1])")
        }
        return L10n.s("无法识别")
    }
}
