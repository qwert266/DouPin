import Foundation

/// 智能拼豆板 BLE 线级协议（A950 服务族，逆向自 PIXDOU/iLEDColor 系列固件）
///
/// 帧格式：`[0x54][cmd 1B][length 2B BE][fields…][checksum 2B BE]`
/// - length = length 字段之后的所有字节数（含末尾 checksum）
/// - checksum = 前面所有字节的 u16 累加和（wrap）
///
/// 通道分工（服务 A950）：
/// - A951 write-without-response：指令帧（Connect/TestPass/StartStream/Dimming/DisplayEnable）
/// - A952 write-without-response：数据分块（Continue/EndStream）
/// - A953 notify：板子应答
enum BLEProtocol {
    static let serviceUUID  = CBUUID(string: "0000A950-0000-1000-8000-00805F9B34FB")
    static let cmdUUID      = CBUUID(string: "0000A951-0000-1000-8000-00805F9B34FB")   // A951
    static let dataUUID     = CBUUID(string: "0000A952-0000-1000-8000-00805F9B34FB")   // A952
    static let notifyUUID   = CBUUID(string: "0000A953-0000-1000-8000-00805F9B34FB")   // A953
    /// AE00 厂商元数据服务（显示不需要，扫描识别用）
    static let vendorServiceUUID = CBUUID(string: "0000AE00-0000-1000-8000-00805F9B34FB")

    static let opcode: UInt8 = 0x54

    enum Cmd {
        static let continueStream: UInt8 = 0x00
        static let endStream: UInt8 = 0x01
        static let startStream: UInt8 = 0x06
        static let dimming: UInt8 = 0x09
        static let displayEnable: UInt8 = 0x0A
        static let connect: UInt8 = 0x0D
        static let passwordOps: UInt8 = 0x0E
        static let testPass: UInt8 = 0x0F
    }

    // MARK: - 校验和

    static func checksum16(_ data: [UInt8]) -> UInt16 {
        var s: UInt16 = 0
        for b in data { s = UInt16.addReportingOverflow(s, UInt16(b)).partialValue }
        return s
    }

    // MARK: - 帧构建

    private static func frame(cmd: UInt8, fields: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [opcode, cmd]
        let length = UInt16(fields.count + 2)   // fields + checksum
        out.append(UInt8(length >> 8))
        out.append(UInt8(length & 0xFF))
        out += fields
        let sum = checksum16(out)
        out.append(UInt8(sum >> 8))
        out.append(UInt8(sum & 0xFF))
        return out
    }

    /// A951 握手第一步
    static func connect() -> [UInt8] { frame(cmd: Cmd.connect, fields: [0x00]) }

    /// A951 校验密码（全零 = 未设密码）
    static func testPass(password: [UInt8] = [0,0,0,0,0,0]) -> [UInt8] {
        frame(cmd: Cmd.testPass, fields: password)
    }

    /// A951 亮度。level：0 最亮 ~ 10 最暗
    static func dimming(level: UInt8) -> [UInt8] {
        frame(cmd: Cmd.dimming, fields: [level] + [UInt8](repeating: 0, count: 8))
    }

    /// A951 显示开关
    static func displayEnable(_ on: Bool) -> [UInt8] {
        frame(cmd: Cmd.displayEnable, fields: [on ? 0x01 : 0x00] + [UInt8](repeating: 0, count: 8))
    }

    /// A951 起流：crc32(4B BE) + 0000 + 总长(2B BE) + 000000
    static func startStream(crc32: UInt32, totalLength: Int) -> [UInt8] {
        var f: [UInt8] = []
        f.append(UInt8((crc32 >> 24) & 0xFF))
        f.append(UInt8((crc32 >> 16) & 0xFF))
        f.append(UInt8((crc32 >> 8) & 0xFF))
        f.append(UInt8(crc32 & 0xFF))
        f += [0x00, 0x00]
        f.append(UInt8((totalLength >> 8) & 0xFF))
        f.append(UInt8(totalLength & 0xFF))
        f += [0x00, 0x00, 0x00]
        return frame(cmd: Cmd.startStream, fields: f)
    }

    /// A952 数据分块：seq(4B BE) + chunkLen(2B BE) + chunk
    static func continueChunk(sequence: Int, chunk: ArraySlice<UInt8>) -> [UInt8] {
        var f: [UInt8] = []
        f.append(UInt8((sequence >> 24) & 0xFF))
        f.append(UInt8((sequence >> 16) & 0xFF))
        f.append(UInt8((sequence >> 8) & 0xFF))
        f.append(UInt8(sequence & 0xFF))
        f.append(UInt8((chunk.count >> 8) & 0xFF))
        f.append(UInt8(chunk.count & 0xFF))
        f += chunk
        return frame(cmd: Cmd.continueStream, fields: f)
    }

    /// A952 结束流
    static func endStream() -> [UInt8] { frame(cmd: Cmd.endStream, fields: [0x01]) }

    // MARK: - 应答解析

    struct Notification {
        let cmd: UInt8
        let length: Int
        let body: [UInt8]
        let checksumOK: Bool

        static func parse(_ data: [UInt8]) -> Notification? {
            guard data.count >= 6, data[0] == opcode else { return nil }
            let cmd = data[1]
            let length = Int(data[2]) << 8 | Int(data[3])
            guard data.count == 4 + length else { return nil }
            let body = Array(data[4..<(data.count - 2)])
            let sum = Int(data[data.count - 2]) << 8 | Int(data[data.count - 1])
            return Notification(cmd: cmd, length: length, body: body,
                               checksumOK: sum == Int(checksum16(Array(data[0..<(data.count - 2)]))))
        }
    }

    // MARK: - CRC-32C (Castagnoli)

    private static let crc32cTable: [UInt32] = {
        let poly: UInt32 = 0x82F63B78
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c >> 1) ^ (c & 1 == 1 ? poly : 0)
            }
            table[i] = c
        }
        return table
    }()

    static func crc32c(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in data {
            crc = (crc >> 8) ^ crc32cTable[Int((crc ^ UInt32(b)) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - 图像载荷

    /// 图像元数据：11 × u16 BE。RGB 静态图默认值。
    /// 格式：u1 u2 width height u3 1 1 1 0x32 0x64 u9
    static func imageMetadata(width: Int, height: Int) -> [UInt8] {
        let fields: [UInt16] = [0x0000, 0x0000, UInt16(width), UInt16(height),
                                0x0000, 0x0001, 0x0001, 0x0001, 0x0032, 0x0064, 0x0000]
        var out: [UInt8] = []
        for f in fields {
            out.append(UInt8(f >> 8))
            out.append(UInt8(f & 0xFF))
        }
        return out
    }

    /// CtnData 包装：crc32c(payload)(4B BE) + 0x01 + 0x00×19 + payload
    static func ctnData(payload: [UInt8]) -> [UInt8] {
        let crc = crc32c(payload)
        var out: [UInt8] = [UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF),
                            UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF), 0x01]
        out += [UInt8](repeating: 0, count: 19)
        out += payload
        return out
    }

    /// 将 RGB 像素流封装成完整发送载荷（metadata + pixels）
    static func imagePayload(width: Int, height: Int, rgb: [UInt8]) -> [UInt8] {
        imageMetadata(width: width, height: height) + rgb
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
