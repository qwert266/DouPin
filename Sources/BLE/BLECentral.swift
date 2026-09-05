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
        case poweredOff, unauthorized, unsupported, idle, scanning, connecting, connected
    }

    @Published var linkState: LinkState = .idle
    @Published var boards: [DiscoveredBoard] = []
    @Published var connectedName: String = ""
    @Published var logLines: [String] = []

    var onNotify: (([UInt8]) -> Void)?
    var onDisconnect: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    // A950 协议特征（首选）
    private var a951: CBCharacteristic?
    private var a952: CBCharacteristic?
    private var a953: CBCharacteristic?
    // AE00 协议特征（部分板型仅有此服务，同协议跑不同 UUID）
    private var ae01: CBCharacteristic?
    private var ae02: CBCharacteristic?
    /// 实际生效的通道（解析后）
    private var cmdChar: CBCharacteristic?
    private var dataChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    /// 是否已经完成通道选择（防止特征乱序到达时重复触发）
    private var channelsResolved = false

    private var centralReady = false
    private var pendingConnectID: UUID?
    /// 扫描发现的原始外设对象（LightBlue/官方 App 同款做法：用发现时的对象直连）
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    /// 蓝牙就绪后自动补扫（用户在权限弹窗关闭前点了扫描时用）
    private var wantsScanWhenReady = false
    /// 扫描无结果提示任务
    private var scanHintTask: Task<Void, Never>?

    // ---- 通知等待队列（支持超时等待） ----
    private var notifyBuffer: [[UInt8]] = []
    private var notifyWaiters: [CheckedContinuation<[UInt8], Never>] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - 日志

    private func log(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
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
            wantsScanWhenReady = true
            log("蓝牙未就绪（状态 \(central.state.rawValue)），就绪后将自动开始扫描")
            return
        }
        scanHintTask?.cancel()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        linkState = .scanning
        log("开始扫描 BLE 设备…")
        // 15 秒无结果给出排查提示
        scanHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.linkState == .scanning && self.boards.isEmpty {
                self.log("15 秒未发现任何设备。请检查：① 拼豆板已通电 ② 没有被其他手机 App 连着 ③ iPhone 蓝牙已开")
            }
        }
    }

    func stopScan() {
        scanHintTask?.cancel()
        central.stopScan()
        if linkState == .scanning { linkState = .idle }
        log("停止扫描")
    }

    // MARK: - 连接

    /// 连接超时任务
    private var connectTimeoutTask: Task<Void, Never>?
    /// 发起连接中的外设（超时时用于取消挂起的连接请求）
    private var connectingPeripheral: CBPeripheral?
    /// 本轮连接的自动重试次数（超时后只静默重试一次）
    private var connectRetryCount = 0

    func connect(_ board: DiscoveredBoard) {
        // 优先用扫描时发现的原始对象直连；取不到再走系统缓存
        let p = discoveredPeripherals[board.id]
            ?? central.retrievePeripherals(withIdentifiers: [board.id]).first
        guard let p else {
            log("找不到设备 \(board.name)，请重新扫描后再连接")
            return
        }
        // 发起连接前先停扫描，避免扫描占着天线影响建链
        if central.isScanning { central.stopScan() }
        pendingConnectID = board.id
        connectingPeripheral = p
        linkState = .connecting
        central.connect(p, options: nil)
        log("连接中：\(board.name.isEmpty ? board.id.uuidString : board.name)")
        // 15 秒连不上自动放弃（板子被其他手机/App 占用时会一直挂起）
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.linkState == .connecting else { return }
            // 真正取消挂起的连接请求（否则请求会一直留在系统里）
            if let p = self.connectingPeripheral { self.central.cancelPeripheralConnection(p) }
            self.connectingPeripheral = nil
            guard self.linkState == .connecting else { return }
            // 静默自动重试一次（iOS 首次建链偶尔会挂起）
            if self.connectRetryCount < 1, let id = self.pendingConnectID,
               let again = self.boards.first(where: { $0.id == id }) {
                self.connectRetryCount += 1
                self.log("连接超时，自动重试…（若仍失败：请杀掉手机上 PIXDOU 官方 App，或把板子断电重启）")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, self.linkState != .connected else { return }
                if let p = self.connectingPeripheral { self.central.cancelPeripheralConnection(p) }
                self.connect(again)
            } else {
                self.linkState = .idle
                self.connectRetryCount = 0
                self.log("连接超时。请依次尝试：① 杀掉 iPhone 上 PIXDOU 官方 App（它后台连着板子会导致永远连不上）② 板子断电重启 ③ 回来重新扫描连接")
            }
        }
    }

    func disconnect() {
        connectTimeoutTask?.cancel()
        connectRetryCount = 0
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        if let p = connectingPeripheral {
            central.cancelPeripheralConnection(p)
            connectingPeripheral = nil
        }
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

    /// 等待下一条板子通知；超时返回 nil
    func nextNotificationWithTimeout(_ timeout: TimeInterval) async -> [UInt8]? {
        await withTaskGroup(of: [UInt8]?.self) { group in
            group.addTask { await self.takeNotification() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func takeNotification() async -> [UInt8] {
        await withCheckedContinuation { (cont: CheckedContinuation<[UInt8], Never>) in
            if !notifyBuffer.isEmpty {
                cont.resume(returning: notifyBuffer.removeFirst())
            } else {
                notifyWaiters.append(cont)
            }
        }
    }

    private func deliverNotification(_ bytes: [UInt8]) {
        if !notifyWaiters.isEmpty {
            notifyWaiters.removeFirst().resume(returning: bytes)
        } else {
            notifyBuffer.append(bytes)
            if notifyBuffer.count > 64 { notifyBuffer.removeFirst(notifyBuffer.count - 64) }
        }
    }

    func drainNotifications() { notifyBuffer.removeAll() }

    /// 待完成特征发现的服务数（用于判断 A951/A952/A953 是否永远凑不齐）
    private var pendingCharDiscovery = 0
}

// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate

extension BLECentral: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            centralReady = central.state == .poweredOn
            switch central.state {
            case .poweredOn:
                if linkState == .poweredOff || linkState == .unauthorized || linkState == .unsupported {
                    linkState = .idle
                }
            case .poweredOff: linkState = .poweredOff
            case .unauthorized: linkState = .unauthorized
            case .unsupported: linkState = .unsupported
            default: break
            }
            let desc: String
            switch central.state {
            case .poweredOn: desc = "开启"
            case .unauthorized: desc = "未授权（App 蓝牙权限被拒绝，请到 设置→隐私与安全性→蓝牙 里允许「豆拼」）"
            case .unsupported: desc = "设备不支持 BLE"
            case .poweredOff: desc = "关闭"
            case .resetting: desc = "重置中"
            case .unknown: desc = "未知"
            @unknown default: desc = "其他"
            }
            log("蓝牙状态：\(desc)")
            if central.state == .poweredOn && wantsScanWhenReady {
                wantsScanWhenReady = false
                startScan()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "")
        // 只显示 PIXDOU 开头的拼豆板，其余设备一律屏蔽
        guard name.lowercased().hasPrefix("pixdou") else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let board = DiscoveredBoard(id: peripheral.identifier, name: name, rssi: RSSI.intValue,
                                    services: services, manufacturerData: mfr,
                                    looksLikeBoard: true)
        Task { @MainActor in
            discoveredPeripherals[peripheral.identifier] = peripheral
            if let i = boards.firstIndex(where: { $0.id == board.id }) {
                boards[i] = board
            } else {
                boards.append(board)
                log("发现拼豆板：\(name) \(RSSI.intValue)dBm")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectTimeoutTask?.cancel()
            connectRetryCount = 0
            connectingPeripheral = nil
            self.peripheral = peripheral
            peripheral.delegate = self
            log("已连接 \(peripheral.name ?? peripheral.identifier.uuidString)，发现服务…")
            // 不过滤，发现全部服务（避免服务表与预期不符时静默失败）
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectTimeoutTask?.cancel()
            connectRetryCount = 0
            connectingPeripheral = nil
            linkState = .idle
            log("连接失败：\(error?.localizedDescription ?? "未知错误")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectTimeoutTask?.cancel()
            connectRetryCount = 0
            connectingPeripheral = nil
            let wasConnected = self.peripheral?.identifier == peripheral.identifier
            cmdChar = nil; dataChar = nil; notifyChar = nil
            a951 = nil; a952 = nil; a953 = nil
            ae01 = nil; ae02 = nil
            channelsResolved = false
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
            let list = peripheral.services ?? []
            if list.isEmpty {
                log("连接成功但服务表为空（板子固件不兼容或已休眠），请断电重启板子后重试")
                central.cancelPeripheralConnection(peripheral)
                linkState = .idle
                return
            }
            channelsResolved = false
            a951 = nil; a952 = nil; a953 = nil
            ae01 = nil; ae02 = nil
            cmdChar = nil; dataChar = nil; notifyChar = nil
            pendingCharDiscovery = list.count
            for svc in list {
                log("服务：\(svc.uuid)")
                peripheral.discoverCharacteristics(nil, for: svc)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                pendingCharDiscovery = max(0, pendingCharDiscovery - 1)
                log("发现特征失败：\(error.localizedDescription)")
                checkCharDiscoveryDone()
                return
            }
            for c in service.characteristics ?? [] {
                log("  特征：\(c.uuid)  props=\(c.properties)")
                if c.uuid == BLEProtocol.cmdUUID { a951 = c }
                if c.uuid == BLEProtocol.dataUUID { a952 = c }
                if c.uuid == BLEProtocol.notifyUUID { a953 = c }
                if c.uuid == BLEProtocol.vendorWriteUUID { ae01 = c }
                if c.uuid == BLEProtocol.vendorNotifyUUID { ae02 = c }
            }
            // A950 三特征齐全 → 立即就绪（快速路径）
            if let n = a953 {
                peripheral.setNotifyValue(true, for: n)
            }
            if a951 != nil && a952 != nil && a953 != nil {
                resolveChannels(cmd: a951!, data: a952!, notify: a953!, mode: "A950")
            }
            pendingCharDiscovery = max(0, pendingCharDiscovery - 1)
            checkCharDiscoveryDone()
        }
    }

    private func resolveChannels(cmd: CBCharacteristic, data: CBCharacteristic,
                                notify: CBCharacteristic, mode: String) {
        guard !channelsResolved else { return }
        channelsResolved = true
        cmdChar = cmd
        dataChar = data
        notifyChar = notify
        // AE02 也开通知（官方 App 两路都开，无害）
        if let v = ae02, v != notify {
            peripheral?.setNotifyValue(true, for: v)
        }
        linkState = .connected
        connectedName = peripheral?.name ?? peripheral?.identifier.uuidString ?? ""
        log("拼豆板就绪（\(mode) 协议），最大单包写入 \(maxWriteLength) 字节")
        drainNotifications()
    }

    /// 全部特征发现完毕后：A950 不齐则回退 AE00 双特征；再不行才报错
    private func checkCharDiscoveryDone() {
        guard pendingCharDiscovery == 0, linkState == .connecting, !channelsResolved else { return }
        if let w = ae01, let n = ae02 {
            // AE00 模式：AE01 同时承担指令与数据写入
            peripheral?.setNotifyValue(true, for: n)
            resolveChannels(cmd: w, data: w, notify: n, mode: "AE00")
            return
        }
        let missing = [(a951 == nil, "A951"), (a952 == nil, "A952"), (a953 == nil, "A953"),
                       (ae01 == nil, "AE01"), (ae02 == nil, "AE02")].filter(\.0).map(\.1)
        log("板子不支持已知协议（缺少 \(missing.joined(separator: " "))特征）。请把上方服务/特征日志截图反馈")
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        linkState = .idle
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
