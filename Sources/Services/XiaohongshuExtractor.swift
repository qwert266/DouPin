import Foundation

/// 小红书链接提取：从分享文案/短链/长链中尽力提取笔记图片 URL（架构师 §A.5.4）。
///
/// **合规声明（务必遵守）**：
/// - 仅抓取**公开分享页**上的图片资源，用于**本地个人像素化**参考；
/// - **不伪造登录态**（使用普通浏览器 UA，不带任何 Cookie/Token）；
/// - **不绕过风控**（不逆向私有接口、不注入 cookie、不模拟登录）；
/// - **不上传、不分享、不缓存 HTML**（仅内存解析，用完即弃）；
/// - 界面需明示"仅供个人自用参考，请尊重原作者版权"。
///
/// **三级流水线 + 降级策略**（失败绝不阻塞主流程）：
/// ```
/// L1 文本清洗：正则从任意文本取第一个 http(s) 链接
/// L2 短链展开 + 抓页面：URLSession 跟随 302/301 → GET HTML（普通 UA）→ 正则抠图
///      ① og:image meta  ② JSON urlDefault/originImageUrl  ③ 兜底 sns-img
/// L3 用户确认 & 保存：返回候选图片 URL 列表（可能多图），由 UI 让用户选
/// ```
///
/// **降级策略**：
/// | 触发 | 降级 |
/// |---|---|
/// | L1 无链接 | 返回 error，UI 提示重新复制 |
/// | L2 失败（超时/403/无图） | 返回 error，UI 引导改用「从相册选择图片」 |
/// | 下载失败 | 提示网络问题，保留链接可重试 |
/// | 多图 | 返回列表让用户选，不自动猜 |
///
/// 工程约定：
/// - 网络调用为**可选功能**，超时 **8 秒**；失败不影响任何主流程。
/// - 短链优先在代码内把 `http://` 升级为 `https://`（避免改 Info.plist 的 ATS 例外）。
/// - **不抛异常**，统一返回结构化 `ExtractResult`。
enum XiaohongshuExtractor {

    // MARK: - 结果类型

    /// 提取结果（结构化，不抛异常）
    struct ExtractResult {
        /// 提取到的候选图片 URL（可能多图，按出现顺序去重）
        var imageURLs: [URL]
        /// 笔记标题（若能解析到）
        var noteTitle: String?
        /// 错误信息（成功时为 `nil`）
        var error: String?
        /// 失败时是否应引导用户改用「从相册选择图片」
        var suggestAlbum: Bool

        /// 是否成功提取到图片
        var hasImages: Bool { !imageURLs.isEmpty && error == nil }

        /// 失败且建议走相册兜底
        var shouldFallbackToAlbum: Bool { !hasImages && suggestAlbum }

        /// 成功结果
        static func success(_ urls: [URL], title: String?) -> ExtractResult {
            ExtractResult(imageURLs: urls, noteTitle: title, error: nil, suggestAlbum: false)
        }

        /// 失败结果
        /// - Parameters:
        ///   - error: 错误描述
        ///   - suggestAlbum: 是否引导用户改用「从相册选择图片」
        static func failure(_ error: String, suggestAlbum: Bool) -> ExtractResult {
            ExtractResult(imageURLs: [], noteTitle: nil, error: error, suggestAlbum: suggestAlbum)
        }
    }

    // MARK: - 常量

    /// 网络超时（秒）—— 架构师要求 8 秒
    static let timeoutSeconds: TimeInterval = 8

    /// 普通浏览器 UA（**不伪造登录态**，仅用于正常抓取公开分享页）
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 短链域名（xhslink.com）
    private static let shortLinkHosts: Set<String> = ["xhslink.com", "www.xhslink.com"]

    /// 图片 CDN 域名前缀（兜底匹配用）
    private static let imageCdnPattern = "https://sns-img[^\"'\\s\\\\<>]+"

    // MARK: - 正则（懒加载，编译失败回退 nil）

    /// 通用 URL 提取：`https?://[^\s"'<>]+`
    private static let urlRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "https?://[^\\s\"'<>）》】]+",
        options: [.caseInsensitive])

    /// og:image meta（两种属性顺序都兼容）
    private static let ogImageRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<meta[^>]*property=[\"']og:image[\"'][^>]*content=[\"']([^\"']+)[\"']",
        options: [.caseInsensitive])

    private static let ogImageReversedRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<meta[^>]*content=[\"']([^\"']+)[\"'][^>]*property=[\"']og:image[\"']",
        options: [.caseInsensitive])

    /// JSON 内图片字段：`"urlDefault":"..."` / `"originImageUrl":"..."`（含转义斜杠兼容）
    private static let jsonImageRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\"(?:urlDefault|originImageUrl|urlPre|masterUrl)\"\\s*:\\s*\"([^\"]+)\"",
        options: [.caseInsensitive])

    /// 兜底 CDN 图片：`https://sns-img...`
    private static let cdnImageRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: imageCdnPattern,
        options: [.caseInsensitive])

    /// 笔记标题：`<title>...</title>`
    private static let titleRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<title[^>]*>([^<]+)</title>",
        options: [.caseInsensitive])

    // MARK: - 主入口（async）

    /// 从任意文本提取小红书图片 URL（三级流水线）。
    ///
    /// **绝不抛异常**；任何失败都返回带 `error` 的结构化结果。
    ///
    /// - Parameter input: 用户粘贴的文本（分享文案 / 短链 / 长链均可）
    /// - Returns: `ExtractResult`（含候选图片 URL / 标题 / 错误 / 相册降级建议）
    static func extract(from input: String) async -> ExtractResult {
        // ---------- Level 1：文本清洗 ----------
        guard let rawLink = firstLink(in: input) else {
            return .failure("未识别到链接，请重新复制小红书分享文案后再试。", suggestAlbum: false)
        }
        // 优先升级 http → https（避免改 ATS 配置；架构师 §A.5.4 工程约定）
        guard let startURL = normalizeToHTTPS(rawLink) else {
            return .failure("链接格式无法解析，请重新复制分享链接。", suggestAlbum: false)
        }

        // ---------- Level 2：跟随跳转抓最终页 ----------
        guard let (finalURL, html) = await fetchHTMLFollowingRedirects(from: startURL) else {
            // 超时 / 403 / 网络失败 → 降级到相册
            return .failure("抓取失败（可能网络超时或分享页受限）。可改用「从相册选择图片」。",
                            suggestAlbum: true)
        }
        // 记录最终页 URL（供"下载失败保留链接可重试"提示用；此处不回传，仅用于日志语义）

        // 从 HTML 抠图（按优先级）
        let urls = extractImageURLs(fromHTML: html, baseURL: finalURL)
        guard !urls.isEmpty else {
            // 抓到页面但无图 → 降级到相册
            return .failure("未能从分享页解析到图片。可改用「从相册选择图片」。",
                            suggestAlbum: true)
        }

        let title = extractNoteTitle(fromHTML: html)
        return .success(urls, title: title)
    }

    /// 下载图片数据（供 L3 用户确认后使用；失败返回 `nil`，不抛异常）。
    ///
    /// - Parameter url: 图片 URL
    /// - Returns: 图片二进制数据；失败返回 `nil`（UI 提示网络问题，保留链接可重试）
    static func downloadImage(_ url: URL) async -> Data? {
        let config = URLSessionConfiguration.ephemeral   // 不持久化 cookie / 缓存
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds * 2
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        let session = URLSession(configuration: config)
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Level 1 实现

    /// 从任意文本中取第一个 http(s) 链接。
    ///
    /// - Parameter text: 用户输入文本
    /// - Returns: 首个链接字符串（去除尾部常见中文标点）；无则 `nil`
    static func firstLink(in text: String) -> String? {
        guard !text.isEmpty, let regex = urlRegex else { return nil }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 1 else { return nil }
        var link = ns.substring(with: match.range(at: 0))
        // 去除尾部可能误捕获的标点（正则已排除大部分，此处再兜底）
        while let last = link.last, ".,;:!?，。；：！？、".contains(last) {
            link.removeLast()
        }
        return link.isEmpty ? nil : link
    }

    /// 把 `http://` 升级为 `https://`（仅升级协议，避免改 ATS）。
    ///
    /// - Parameter link: 原始链接
    /// - Returns: 升级后的 URL；无法解析返回 `nil`
    static func normalizeToHTTPS(_ link: String) -> URL? {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http://") {
            s = "https://" + s.dropFirst("http://".count)
        } else if !s.hasPrefix("https://") {
            // 无协议前缀：补 https
            s = "https://" + s
        }
        return URL(string: s)
    }

    // MARK: - Level 2 实现

    /// 跟随 301/302 抓取最终 HTML（超时 8 秒，普通 UA，不持久化 cookie）。
    ///
    /// - Parameter start: 起始 URL（短链或长链）
    /// - Returns: `(最终 URL, HTML 字符串)`；任一步失败返回 `nil`
    private static func fetchHTMLFollowingRedirects(from start: URL) async -> (URL, String)? {
        let config = URLSessionConfiguration.ephemeral   // 不持久化 cookie / 缓存
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds * 2
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml"
        ]
        let session = URLSession(configuration: config)
        do {
            // URLSession 默认跟随重定向，返回最终 URL 与响应体
            let (data, response) = try await session.data(from: start)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            // 尝试 UTF-8；失败回退 GBK（部分页面）
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .init(rawValue: 0x80000632)) // GB18030 兜底
            guard let html, !html.isEmpty else { return nil }
            // response.url 为最终 URL（跟随重定向后）
            let finalURL = http.url ?? start
            return (finalURL, html)
        } catch {
            return nil
        }
    }

    /// 从 HTML 中按优先级抠出候选图片 URL（去重、保持出现顺序）。
    ///
    /// 优先级（架构师 §A.5.4）：
    /// ① `og:image` meta；② JSON 的 `urlDefault`/`originImageUrl`；③ 兜底 `https://sns-img...`
    ///
    /// - Parameters:
    ///   - html: 页面 HTML
    ///   - baseURL: 最终页 URL（用于相对路径补全）
    /// - Returns: 候选图片 URL 列表（去重）
    static func extractImageURLs(fromHTML html: String, baseURL: URL) -> [URL] {
        var collected: [String] = []

        // ① og:image（两种属性顺序）
        collected.append(contentsOf: captures(ogImageRegex, in: html, group: 1))
        collected.append(contentsOf: captures(ogImageReversedRegex, in: html, group: 1))

        // ② JSON 内的图片字段
        collected.append(contentsOf: captures(jsonImageRegex, in: html, group: 1))

        // ③ 兜底 CDN
        collected.append(contentsOf: captures(cdnImageRegex, in: html, group: 0))

        // 转义还原 + 转 URL + 去重 + 过滤（只保留 http/https）
        var seen = Set<String>()
        var result: [URL] = []
        for raw in collected {
            let unescaped = unescapeJSONString(raw)
            guard let url = resolveURL(unescaped, baseURL: baseURL) else { continue }
            let key = url.absoluteString
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(url)
        }
        return result
    }

    /// 提取笔记标题（`<title>`）。
    ///
    /// - Parameter html: 页面 HTML
    /// - Returns: 标题（去除首尾空白）；无则 `nil`
    static func extractNoteTitle(fromHTML html: String) -> String? {
        guard let regex = titleRegex else { return nil }
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges >= 2 else { return nil }
        let title = ns.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // MARK: - Level 3 说明
    //
    // L3（用户确认 & 保存）由 UI 层实现：
    // - `XiaohongshuImportView`（见 Sources/Views/FolderViews.swift）展示候选图片，
    //   用户选定后调用 `downloadImage(_:)` 下载 → 走 PixelConverter → PatternFactory 建图纸。
    // - 多图时不自动猜，始终让用户选。
    // - 下载失败提示网络问题并保留链接可重试。

    // MARK: - 私有工具

    /// 用正则提取所有匹配指定分组的子串。
    private static func captures(_ regex: NSRegularExpression?, in text: String, group: Int) -> [String] {
        guard let regex else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, options: [], range: range)
        var out: [String] = []
        for m in matches {
            guard m.numberOfRanges > group else { continue }
            let r = m.range(at: group)
            guard r.location != NSNotFound, r.length > 0 else { continue }
            out.append(ns.substring(with: r))
        }
        return out
    }

    /// 还原 JSON 字符串中的转义（`\/` → `/`，`\u002F` → `/` 等）。
    private static func unescapeJSONString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\/", with: "/")
         .replacingOccurrences(of: "\\u002F", with: "/")
         .replacingOccurrences(of: "\\u002f", with: "/")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把字符串解析为 URL（支持相对路径按 baseURL 补全）。
    private static func resolveURL(_ s: String, baseURL: URL) -> URL? {
        guard !s.isEmpty else { return nil }
        // 已是绝对 URL
        if let url = URL(string: s), url.scheme != nil {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return url
        }
        // 相对路径：基于最终页 URL 补全
        return URL(string: s, relativeTo: baseURL)?.absoluteURL
    }
}
