import Foundation

enum BoardError: LocalizedError {
    case notConnected
    case handshakeFailed(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "板子未连接"
        case .handshakeFailed(let s): return "握手失败：\(s)"
        case .sendFailed(let s): return "发送失败：\(s)"
        }
    }
}

/// 拼豆板高层会话：握手、发图、亮度、显示开关、引导图构建
@MainActor
final class BoardSession: ObservableObject {
    @Published var isSending = false
    @Published var sendProgress: Double = 0
    @Published var lastError: String?

    let central = BLECentral()

    /// 分块大小：A952 分块帧开销 12 字节（4 头 + 4 seq + 2 len + 2 校验）
    private var chunkSize: Int { max(8, min(492, central.maxWriteLength - 12)) }

    var isConnected: Bool { central.linkState == .connected }

    // MARK: - 握手

    /// Connect + TestPass（全零密码）。板子应答 TestPass 后即具备发图能力。
    func handshake() async throws {
        guard central.linkState == .connected else { throw BoardError.notConnected }
        await central.writeCmd(BLEProtocol.connect())
        guard let ack = await central.nextNotificationWithTimeout(2.0) else {
            throw BoardError.handshakeFailed("Connect 无应答")
        }
        await central.writeCmd(BLEProtocol.testPass())
        guard let passAck = await central.nextNotificationWithTimeout(2.0) else {
            throw BoardError.handshakeFailed("TestPass 无应答")
        }
        // PassCheck 字节：0x02 = 密码错误；其他（0x00/0x01/0x03）视为通过
        if passAck.count >= 3 && passAck[passAck.count - 3] == 0x02 {
            throw BoardError.handshakeFailed("板子设置了密码，请先用官方 app 清除密码")
        }
    }

    // MARK: - 发图

    /// 发送 RGB 图（row-major，宽×高×3 字节）
    func sendImage(width: Int, height: Int, rgb: [UInt8]) async throws {
        guard central.linkState == .connected else { throw BoardError.notConnected }
        guard rgb.count == width * height * 3 else { throw BoardError.sendFailed("像素数据长度不符") }

        isSending = true
        sendProgress = 0
        defer { isSending = false }

        let payload = BLEProtocol.imagePayload(width: width, height: height, rgb: rgb)
        let ctn = BLEProtocol.ctnData(payload: payload)

        let start = BLEProtocol.startStream(crc32: BLEProtocol.crc32c(ctn), totalLength: ctn.count)
        await central.writeCmd(start)
        _ = await central.nextNotificationWithTimeout(1.0)   // StartStream 应答

        let size = chunkSize
        let total = (ctn.count + size - 1) / size
        var seq = 0
        var offset = 0
        while offset < ctn.count {
            let end = min(offset + size, ctn.count)
            let frame = BLEProtocol.continueChunk(sequence: seq, chunk: ctn[offset..<end])
            await central.writeData(frame)
            _ = await central.nextNotificationWithTimeout(0.3)   // 分块应答，超时不中断
            offset = end
            seq += 1
            sendProgress = Double(seq) / Double(total)
        }

        await central.writeData(BLEProtocol.endStream())
        _ = await central.nextNotificationWithTimeout(1.0)
        sendProgress = 1
    }

    // MARK: - 控制

    /// 亮度 0（最亮）~ 10（最暗）
    func setBrightness(level: Int) async {
        guard central.linkState == .connected else { return }
        await central.writeCmd(BLEProtocol.dimming(level: UInt8(max(0, min(10, level)))))
        _ = await central.nextNotificationWithTimeout(0.5)
    }

    func setDisplay(_ on: Bool) async {
        guard central.linkState == .connected else { return }
        await central.writeCmd(BLEProtocol.displayEnable(on))
        _ = await central.nextNotificationWithTimeout(0.5)
    }

    /// 亮度百分比对协议等级的换算：UI 百分比 100% = 等级 0
    func level(forBrightnessPercent pct: Int) -> Int {
        10 - Int(round(Double(max(0, min(100, pct))) / 10.0))
    }
}

/// 图纸 → 板子 RGB 图像的构建器（引导模式的核心）
enum BoardImageBuilder {

    /// 完整预览图
    static func fullImage(width: Int, height: Int, cells: [Int], placed: [Bool]?) -> [UInt8] {
        rgbFrom(width: width, height: height) { idx in
            guard let c = validColor(cells[idx]) else { return (0, 0, 0) }
            if let placed, placed[idx] { return dimmed(c, factor: 0.35) }
            return colorRGB(c)
        }
    }

    /// 分色引导：仅点亮指定色号（已拼的灭掉，未拼的亮）
    static func colorGuide(width: Int, height: Int, cells: [Int], colorId: Int, placed: [Bool]?) -> [UInt8] {
        rgbFrom(width: width, height: height) { idx in
            guard let c = validColor(cells[idx]), c.id == colorId else { return (0, 0, 0) }
            if let placed, placed[idx] { return (0, 0, 0) }
            return colorRGB(c)
        }
    }

    /// 行定位：仅当前行亮（配合分色可先过滤色再过滤行）
    static func rowGuide(width: Int, height: Int, cells: [Int], row: Int,
                         colorId: Int?, placed: [Bool]?) -> [UInt8] {
        rgbFrom(width: width, height: height) { idx in
            let y = idx / width
            let matchColor = colorId == nil || cells[idx] == colorId
            guard y == row, let c = validColor(cells[idx]), matchColor else { return (0, 0, 0) }
            if let placed, placed[idx] { return (0, 0, 0) }
            return colorRGB(c)
        }
    }

    /// 当前行的邻域模式：当前行全亮 + 相邻行微亮（更容易对位）
    static func rowGuideWithNeighbors(width: Int, height: Int, cells: [Int], row: Int,
                                       colorId: Int?, placed: [Bool]?) -> [UInt8] {
        rgbFrom(width: width, height: height) { idx in
            let y = idx / width
            let matchColor = colorId == nil || cells[idx] == colorId
            guard let c = validColor(cells[idx]), matchColor else { return (0, 0, 0) }
            if let placed, placed[idx] { return (0, 0, 0) }
            if y == row { return colorRGB(c) }
            if abs(y - row) == 1 { return dimmed(c, factor: 0.25) }
            return (0, 0, 0)
        }
    }

    // MARK: - 工具

    private static func rgbFrom(width: Int, height: Int, _ cellColor: (Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var rgb = [UInt8]()
        rgb.reserveCapacity(width * height * 3)
        for i in 0..<(width * height) {
            let (r, g, b) = cellColor(i)
            rgb.append(r); rgb.append(g); rgb.append(b)
        }
        return rgb
    }

    /// cells 存官方 colorId（1...295），0 = 空格
    private static func validColor(_ v: Int) -> BeadColor? {
        BeadPalette.byId[v]
    }

    private static func colorRGB(_ c: BeadColor) -> (UInt8, UInt8, UInt8) {
        (c.r, c.g, c.b)
    }

    private static func dimmed(_ c: BeadColor, factor: Double) -> (UInt8, UInt8, UInt8) {
        (UInt8(Double(c.r) * factor), UInt8(Double(c.g) * factor), UInt8(Double(c.b) * factor))
    }
}
