import CoreBluetooth
import Foundation

/// 扫描到的 BLE 设备
struct DiscoveredBoard: Identifiable, Equatable {
    let id: UUID                  // peripheral.identifier
    let name: String
    let rssi: Int
    let services: [CBUUID]
    let manufacturerData: Data?
    /// 是否疑似智能拼豆板（A950/AE00 服务或 JLAISDK 标记）
    let looksLikeBoard: Bool

    static func == (l: DiscoveredBoard, r: DiscoveredBoard) -> Bool { l.id == r.id }

    var summary: String {
        if looksLikeBoard { return "拼豆板" }
        if name.isEmpty { return "未知设备" }
        return name
    }
}

/// CoreBluetooth 外围设备管理：扫描、连接、特征读写
@MainActor
final class BLECentral: NSObject, ObservableObject {
    enum LinkState: Equatable {
        case poweredOff, idle, scanning, connecting, connected
    }

    @Published var linkState: LinkState = .idle
    @Published var boards: [DiscoveredBoard] = []
    @Published var connectedName: String = ""
    @Published var logLines: [String] = []

    var onNotify: (([UInt8]) -> Void)?
    var onDisconnect: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var dataChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var centralReady = false
    private var pendingConnectID: UUID?

    // ---- 通知等待队列（支持超时等待） ----

    /// 单个等待者：带 id 便于超时后精确移除，彻底消除僵尸 waiter。
    private struct NotifyWaiter {
        let id: UUID
        let cont: CheckedContinuation<[UInt8]?, Never>
    }

    private var notifyBuffer: [[UInt8]] = []
    private var notifyWaiters: [NotifyWaiter] = []

    /// 板卡名称关键字（命中视为疑似拼豆板）；提为静态量，避免每次扫描重复构造数组。
    private nonisolated static let boardNameHints = ["pixdou", "iledcolor", "wofan", "led", "pd"]

    /// 日志时间戳格式化器（静态复用，避免每次 log 都新建 formatter）。
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - 日志

    private func log(_ s: String) {
        let t = Self.timeFormatter.string(from: Date())
        logLines.append("\(t)  \(s)")
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        #if DEBUG
        print("[BLE] \(s)")
        #endif
    }

    // MARK: - 扫描

    func startScan() {
        boards.removeAll()
        guard centralReady else {
            log("蓝牙未就绪（状态 \(central.state.rawValue)），稍后自动重试")
            return
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        linkState = .scanning
        log("开始扫描 BLE 设备…")
    }

    func stopScan() {
        central.stopScan()
        if linkState == .scanning { linkState = .idle }
        log("停止扫描")
    }

    // MARK: - 连接

    func connect(_ board: DiscoveredBoard) {
        guard let p = central.retrievePeripherals(withIdentifiers: [board.id]).first else {
            log("找不到设备 \(board.name)")
            return
        }
        pendingConnectID = board.id
        linkState = .connecting
        central.connect(p, options: nil)
        log("连接中：\(board.name.isEmpty ? board.id.uuidString : board.name)")
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // MARK: - 写入

    /// 写指令帧到 A951
    func writeCmd(_ bytes: [UInt8]) async {
        guard let p = peripheral, let c = cmdChar else { return }
        let payload = Data(bytes)
        p.writeValue(payload, for: c, type: .withoutResponse)
        try? await Task.sleep(nanoseconds: 10_000_000)   // 10ms 间隔，对齐参考实现
    }

    /// 写数据分块到 A952
    func writeData(_ bytes: [UInt8]) async {
        guard let p = peripheral, let c = dataChar else { return }
        let payload = Data(bytes)
        p.writeValue(payload, for: c, type: .withoutResponse)
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    /// 单次写入（无等待）
    func writeRaw(_ bytes: [UInt8], to char: CBCharacteristic?) {
        guard let p = peripheral, let c = char else { return }
        p.writeValue(Data(bytes), for: c, type: .withoutResponse)
    }

    var cmdCharacteristic: CBCharacteristic? { cmdChar }
    var dataCharacteristic: CBCharacteristic? { dataChar }
    var notifyCharacteristic: CBCharacteristic? { notifyChar }
    var currentPeripheral: CBPeripheral? { peripheral }

    /// 无响应写入的单包上限（A952 分块尺寸用）
    var maxWriteLength: Int {
        peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 182
    }

    // MARK: - 通知

    /// 等待下一条板子通知；超时返回 nil。
    ///
    /// P0-2 重写：旧实现用 `withTaskGroup` + `cancelAll()`，但 `withCheckedContinuation`
    /// 不响应取消 → 每次超时都会泄漏一个 waiter，连续发图后应答错位。
    /// 现改为「带 id 的 waiter + 独立超时任务」：超时任务通过 id 精确定位并从数组中移除，
    /// 再 resume(nil)，保证 waiter 生命周期闭合、绝不泄漏。
    func nextNotificationWithTimeout(_ timeout: TimeInterval) async -> [UInt8]? {
        if !notifyBuffer.isEmpty { return notifyBuffer.removeFirst() }
        let id = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
            notifyWaiters.append(NotifyWaiter(id: id, cont: cont))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                if let i = self.notifyWaiters.firstIndex(where: { $0.id == id }) {
                    let w = self.notifyWaiters.remove(at: i)
                    w.cont.resume(returning: nil)
                }
            }
        }
    }

    private func deliverNotification(_ bytes: [UInt8]) {
        if !notifyWaiters.isEmpty {
            notifyWaiters.removeFirst().cont.resume(returning: bytes)
        } else {
            notifyBuffer.append(bytes)
            if notifyBuffer.count > 64 { notifyBuffer.removeFirst(notifyBuffer.count - 64) }
        }
    }

    /// 清空缓冲 + 释放所有排队 waiter（连接重试/重新握手时调用）。
    ///
    /// 先把 waiter 数组整体搬出并清空，再逐个 resume(nil)，避免 resume 过程中回调
    /// 又写入 `notifyWaiters` 引发重入。
    func drainNotifications() {
        notifyBuffer.removeAll()
        let pending = notifyWaiters
        notifyWaiters.removeAll()
        for w in pending { w.cont.resume(returning: nil) }
    }
}

// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate

extension BLECentral: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            centralReady = central.state == .poweredOn
            if central.state == .poweredOff { linkState = .poweredOff }
            log("蓝牙状态：\(central.state == .poweredOn ? "开启" : "不可用(\(central.state.rawValue))")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "")
        // P1-4：原三元 `? [] : []` 恒为空数组，属死代码，直接简化为仅取 ServiceUUIDs。
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let hasBoardService = services.contains(BLEProtocol.serviceUUID) || services.contains(BLEProtocol.vendorServiceUUID)
        let jlaisdk = mfr != nil && mfr!.count >= 7 && String(data: mfr!.suffix(7), encoding: .ascii) == "JLAISDK"
        let lower = name.lowercased()
        // P2：关键字数组提为静态量（Self.boardNameHints），避免每次扫描重复构造。
        let nameHit = Self.boardNameHints.contains { lower.contains($0) }
        let board = DiscoveredBoard(id: peripheral.identifier, name: name, rssi: RSSI.intValue,
                                    services: services, manufacturerData: mfr,
                                    looksLikeBoard: hasBoardService || jlaisdk || (nameHit && !name.isEmpty))
        Task { @MainActor in
            if let i = boards.firstIndex(where: { $0.id == board.id }) {
                boards[i] = board
            } else {
                boards.append(board)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.peripheral = peripheral
            peripheral.delegate = self
            log("已连接 \(peripheral.name ?? peripheral.identifier.uuidString)，发现服务…")
            peripheral.discoverServices([BLEProtocol.serviceUUID, BLEProtocol.vendorServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            linkState = .idle
            log("连接失败：\(error?.localizedDescription ?? "未知错误")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let wasConnected = self.peripheral?.identifier == peripheral.identifier
            cmdChar = nil; dataChar = nil; notifyChar = nil
            if wasConnected {
                linkState = .idle
                connectedName = ""
                log("已断开\(error != nil ? "（\(error!.localizedDescription)）" : "")")
                onDisconnect?()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error { log("发现服务失败：\(error.localizedDescription)"); return }
            for svc in peripheral.services ?? [] {
                log("服务：\(svc.uuid)")
                peripheral.discoverCharacteristics(nil, for: svc)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error { log("发现特征失败：\(error.localizedDescription)"); return }
            for c in service.characteristics ?? [] {
                log("  特征：\(c.uuid)  props=\(c.properties)")
                if c.uuid == BLEProtocol.cmdUUID { cmdChar = c }
                if c.uuid == BLEProtocol.dataUUID { dataChar = c }
                if c.uuid == BLEProtocol.notifyUUID {
                    notifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            if cmdChar != nil && dataChar != nil && notifyChar != nil {
                linkState = .connected
                connectedName = peripheral.name ?? peripheral.identifier.uuidString
                log("拼豆板就绪（A950 特征齐全），最大单包写入 \(maxWriteLength) 字节")
                drainNotifications()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        Task { @MainActor in
            if let n = BLEProtocol.Notification.parse(bytes) {
                log(String(format: "← 通知 cmd=0x%02X %@", n.cmd, bytes.hexString))
            } else {
                log("← 原始 \(bytes.hexString)")
            }
            deliverNotification(bytes)
            onNotify?(bytes)
        }
    }
}
