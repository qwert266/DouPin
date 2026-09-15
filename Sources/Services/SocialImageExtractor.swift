import Foundation

// MARK: - 多社交平台图片导入

/// 多平台分享链接提取：抖音 / 小红书为主，其它平台走通用兜底。
///
/// **合规声明（与 `XiaohongshuExtractor` 一致，务必遵守）**：
/// - 仅读取**公开分享页**上的图片资源，供本地个人像素化参考；
/// - **不伪造登录态**（普通浏览器 UA，不带 Cookie / Token）；
/// - **不绕过风控**（不逆向私有接口、不模拟登录、不注入 cookie）；
/// - 不上传、不分享、不缓存 HTML（仅内存解析）；
/// - 界面明示「仅供个人自用参考，请尊重原作者版权」。
///
/// **流水线**：
/// ```
/// L1 平台识别：按域名判断抖音 / 小红书 / 其它，并取出首个链接
/// L2 展开短链抓最终页：跟随 302，普通 UA，8 秒超时（http 自动升 https，避免 ATS 例外）
/// L3 按平台抠图：抖音 = douyinpic 图床 + url_list 数组；小红书 = 复用既有三级抠图；其它 = og:image 兜底
/// ```
/// 任何一步失败都不抛异常，返回结构化 `Result`，UI 据此提示或引导改用「从相册选择图片」。
enum SocialImageExtractor {

    // MARK: - 平台

    enum Platform: String, CaseIterable {
        case douyin
        case xiaohongshu
        case kuaishou
        case weibo
        case generic

        /// 界面展示名（保持品牌原名，不翻译）
        var displayName: String {
            switch self {
            case .douyin: return L10n.s("抖音")
            case .xiaohongshu: return L10n.s("小红书")
            case .kuaishou: return L10n.s("快手")
            case .weibo: return L10n.s("微博")
            case .generic: return L10n.s("网页")
            }
        }

        /// 是否有专用解析（否则走通用 og:image 兜底）
        var hasDedicatedParser: Bool {
            switch self {
            case .douyin, .xiaohongshu: return true
            default: return false
            }
        }
    }

    /// 支持的平台清单（用于界面提示文案）
    static let supportedPlatformsText = "抖音 / 小红书 / 快手 / 微博"

    // MARK: - 结果

    struct Result {
        /// 提取到的候选图片 URL（按出现顺序去重）
        var imageURLs: [URL]
        /// 作品标题（若能解析到）
        var title: String?
        /// 识别到的平台
        var platform: Platform
        /// 错误信息（成功为 nil）
        var error: String?
        /// 失败时是否应引导改用「从相册选择图片」
        var suggestAlbum: Bool

        var hasImages: Bool { !imageURLs.isEmpty && error == nil }

        /// 失败且建议走相册兜底（UI 据此显示「改用从相册选择图片」入口）
        var shouldFallbackToAlbum: Bool { !hasImages && suggestAlbum }

        static func success(_ urls: [URL], title: String?, platform: Platform) -> Result {
            Result(imageURLs: urls, title: title, platform: platform, error: nil, suggestAlbum: false)
        }

        static func failure(_ error: String, platform: Platform, suggestAlbum: Bool) -> Result {
            Result(imageURLs: [], title: nil, platform: platform, error: error, suggestAlbum: suggestAlbum)
        }
    }

    // MARK: - 常量

    static let timeoutSeconds: TimeInterval = 8

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 平台域名指纹（小写包含匹配）
    private static let platformHosts: [(Platform, [String])] = [
        (.douyin, ["douyin.com", "iesdouyin.com", "douyin"]),
        (.xiaohongshu, ["xiaohongshu.com", "xhslink.com", "xhscdn.com"]),
        (.kuaishou, ["kuaishou.com", "gifshow.com", "chenzhongtech.com"]),
        (.weibo, ["weibo.com", "weibo.cn"]),
    ]

    // MARK: - 正则

    private static let urlRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "https?://[^\\s\"'<>）》】]+", options: [.caseInsensitive])

    /// 抖音图床：`https://p3-sign.douyinpic.com/tos-cn-i-xxx/xxx~tplv-...`
    private static let douyinImageRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "https://p\\d+[a-z-]*\\.douyinpic\\.com/[^\"'\\\\\\s<>]+", options: [.caseInsensitive])

    /// 抖音图文：`"url_list":["https://...","https://..."]`（取整个数组再二次抠 URL）
    private static let urlListRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\"(?:url_list|urlList|download_url_list)\"\\s*:\\s*\\[([^\\]]*)\\]", options: [.caseInsensitive])

    /// og:image（两种属性顺序）
    private static let ogImageRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<meta[^>]*property=[\"']og:image[\"'][^>]*content=[\"']([^\"']+)[\"']", options: [.caseInsensitive])
    private static let ogImageReversedRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<meta[^>]*content=[\"']([^\"']+)[\"'][^>]*property=[\"']og:image[\"']", options: [.caseInsensitive])

    /// 通用图片 CDN（其它平台兜底：只认明显的图片扩展名或常见图床目录）
    private static let genericImageRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "https://[^\"'\\\\\\s<>]+?\\.(?:jpg|jpeg|png|webp)(?:\\?[^\"'\\\\\\s<>]*)?", options: [.caseInsensitive])

    private static let titleRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "<title[^>]*>([^<]+)</title>", options: [.caseInsensitive])

    // MARK: - 主入口

    /// 从任意分享文本提取候选图片 URL。
    ///
    /// - Parameter input: 用户粘贴的分享文案 / 短链 / 长链
    static func extract(from input: String) async -> Result {
        // ---- L1：取链接 + 识别平台 ----
        guard let rawLink = firstLink(in: input) else {
            return .failure(L10n.s("未识别到链接，请重新复制分享文案后再试。"), platform: .generic, suggestAlbum: false)
        }
        guard let startURL = normalizeToHTTPS(rawLink) else {
            return .failure(L10n.s("链接格式无法解析，请重新复制分享链接。"), platform: .generic, suggestAlbum: false)
        }
        let platform = detectPlatform(in: startURL.absoluteString)
        let resolvedPlatform = platform == .generic ? detectPlatform(in: input) : platform

        // 小红书：复用既有三级流水线（已验证）
        if resolvedPlatform == .xiaohongshu {
            let legacy = await XiaohongshuExtractor.extract(from: input)
            if legacy.hasImages {
                return .success(legacy.imageURLs, title: legacy.noteTitle, platform: .xiaohongshu)
            }
            return .failure(legacy.error ?? L10n.s("未能从分享页解析到图片。可改用「从相册选择图片」。"),
                            platform: .xiaohongshu,
                            suggestAlbum: legacy.suggestAlbum)
        }

        // ---- L2：抓最终页 ----
        guard let (finalURL, html) = await fetchHTMLFollowingRedirects(from: startURL) else {
            return .failure(L10n.s("抓取失败（可能网络超时或分享页受限）。可改用「从相册选择图片」。"),
                            platform: resolvedPlatform, suggestAlbum: true)
        }
        // 若短链最终落到小红书，转交专用解析
        let finalPlatform = resolvedPlatform == .generic ? detectPlatform(in: finalURL.absoluteString) : resolvedPlatform

        // ---- L3：按平台抠图 ----
        var urls: [URL] = []
        switch finalPlatform {
        case .douyin:
            urls = douyinImageURLs(fromHTML: html, baseURL: finalURL)
        default:
            urls = genericImageURLs(fromHTML: html, baseURL: finalURL)
        }

        guard !urls.isEmpty else {
            return .failure(L10n.s("未能从分享页解析到图片。可改用「从相册选择图片」。"),
                            platform: finalPlatform, suggestAlbum: true)
        }
        return .success(urls, title: extractTitle(fromHTML: html), platform: finalPlatform)
    }

    /// 下载图片数据（失败返回 nil，不抛异常）
    static func downloadImage(_ url: URL) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
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

    // MARK: - 平台识别

    /// 按域名识别平台（大小写不敏感；无法识别返回 `.generic`）
    static func detectPlatform(in text: String) -> Platform {
        let lower = text.lowercased()
        for (platform, hosts) in platformHosts {
            if hosts.contains(where: { lower.contains($0) }) {
                return platform
            }
        }
        return .generic
    }

    // MARK: - L1 工具

    /// 取首个 http(s) 链接（去除尾部中文标点）
    static func firstLink(in text: String) -> String? {
        guard !text.isEmpty, let regex = urlRegex else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 1 else { return nil }
        var link = ns.substring(with: match.range(at: 0))
        while let last = link.last, ".,;:!?，。；：！？、".contains(last) {
            link.removeLast()
        }
        return link.isEmpty ? nil : link
    }

    /// http → https（避免为 ATS 加例外）
    static func normalizeToHTTPS(_ link: String) -> URL? {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http://") {
            s = "https://" + s.dropFirst("http://".count)
        } else if !s.hasPrefix("https://") {
            s = "https://" + s
        }
        return URL(string: s)
    }

    // MARK: - L2 工具

    private static func fetchHTMLFollowingRedirects(from start: URL) async -> (URL, String)? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds * 2
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
        ]
        let session = URLSession(configuration: config)
        do {
            let (data, response) = try await session.data(from: start)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .init(rawValue: 0x80000632))   // GB18030 兜底
            guard let html, !html.isEmpty else { return nil }
            return (http.url ?? start, html)
        } catch {
            return nil
        }
    }

    // MARK: - L3 抠图

    /// 抖音：图床直链 + `url_list` 数组 + og:image 兜底
    static func douyinImageURLs(fromHTML html: String, baseURL: URL) -> [URL] {
        var raw: [String] = []
        raw.append(contentsOf: captures(douyinImageRegex, in: html, group: 0))
        // url_list 数组里再抠一遍（数组元素形如 "https://p3-sign.douyinpic.com/..."）
        for arrayText in captures(urlListRegex, in: html, group: 1) {
            raw.append(contentsOf: captures(douyinImageRegex, in: arrayText, group: 0))
            raw.append(contentsOf: captures(genericImageRegex, in: arrayText, group: 0))
        }
        raw.append(contentsOf: captures(ogImageRegex, in: html, group: 1))
        raw.append(contentsOf: captures(ogImageReversedRegex, in: html, group: 1))
        return normalizeAndFilter(raw, baseURL: baseURL)
    }

    /// 通用兜底：og:image → 图片扩展名直链
    static func genericImageURLs(fromHTML html: String, baseURL: URL) -> [URL] {
        var raw: [String] = []
        raw.append(contentsOf: captures(ogImageRegex, in: html, group: 1))
        raw.append(contentsOf: captures(ogImageReversedRegex, in: html, group: 1))
        raw.append(contentsOf: captures(genericImageRegex, in: html, group: 0))
        return normalizeAndFilter(raw, baseURL: baseURL)
    }

    static func extractTitle(fromHTML html: String) -> String? {
        guard let regex = titleRegex else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        let title = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // MARK: - 私有工具

    private static func captures(_ regex: NSRegularExpression?, in text: String, group: Int) -> [String] {
        guard let regex else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var out: [String] = []
        for m in matches {
            guard m.numberOfRanges > group else { continue }
            let r = m.range(at: group)
            guard r.location != NSNotFound, r.length > 0 else { continue }
            out.append(ns.substring(with: r))
        }
        return out
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\/", with: "/")
         .replacingOccurrences(of: "\\u002F", with: "/")
         .replacingOccurrences(of: "\\u002f", with: "/")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveURL(_ s: String, baseURL: URL) -> URL? {
        guard !s.isEmpty else { return nil }
        if let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }
        return URL(string: s, relativeTo: baseURL)?.absoluteURL
    }

    /// 转义还原 → 转 URL → 去重 → 过滤掉头像/图标/占位等明显非作品图
    private static func normalizeAndFilter(_ raw: [String], baseURL: URL) -> [URL] {
        // 非作品图的路径特征（抖音/小红书都会把头像、图标放在这些目录里）
        let blocked = ["avatar", "aweme-avatar", "/icon", "favicon", "logo", "sprite", "placeholder", "loading"]
        var seen = Set<String>()
        var out: [URL] = []
        for item in raw {
            let cleaned = unescape(item)
            guard let url = resolveURL(cleaned, baseURL: baseURL) else { continue }
            let lower = url.absoluteString.lowercased()
            if blocked.contains(where: { lower.contains($0) }) { continue }
            // 排除极小尺寸参数（如 ?x-oss-process=...resize,w_40）
            if lower.contains("w_40") || lower.contains("w_50") || lower.contains("w_60") { continue }
            guard !seen.contains(lower) else { continue }
            seen.insert(lower)
            out.append(url)
        }
        return out
    }
}
