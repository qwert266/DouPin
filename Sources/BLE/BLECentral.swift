import CoreBluetooth
import Foundation

/// 扫描到的 BLE 设备
///
/// P0-A 修复：直接持有 `CBPeripheral` 引用（`peripheral` 字段）。
/// 旧实现只存 `identifier`，连接时用 `retrievePeripherals(withIdentifiers:)` 反查。
/// 该 API 对「本次扫描刚发现、系统尚未缓存」的设备可能返回空数组，而旧实现在返回空时
/// **直接 return**，此时 `linkState` 已被置为 `.connecting` 且再无任何回调复位 ——
/// 这就是用户看到的「连接中…一直转圈、连不上」的直接死状态（P0-D）。
struct DiscoveredBoard: Identifiable, Equatable {
    let id: UUID                  // peripheral.identifier
    let name: String
    let rssi: Int
    let services: [CBUUID]
    let manufacturerData: Data?
    /// 是否疑似智能拼豆板（A950/AE00 服务、JLAISDK 标记，或命中宽松名称关键字）
    let looksLikeBoard: Bool
    /// 是否命中 PIXDOU 等名称前缀白名单（用户明确要求只显示这类设备）
    let matchesNameFilter: Bool
    /// 外围设备引用，连接时直接使用，绕开 retrievePeripherals 的不确定性。
    ///
    /// 用强引用而非 `unowned(unsafe)`：后者在对象释放后再访问是**未定义行为**，
    /// 而 `boards` 每次 `startScan()` 都会 `removeAll()`，SwiftUI 列表若在旧的
    /// 渲染帧里再读一次残留元素，就是一次悬垂指针访问。强引用彻底消除该风险：
    /// - 无循环引用：`CBPeripheral` 不反向持有这个值类型
    /// - 无泄漏：`boards.removeAll()` 后这些 peripheral 立即失去唯一强引用而被释放
    let peripheral: CBPeripheral

    static func == (l: DiscoveredBoard, r: DiscoveredBoard) -> Bool { l.id == r.id }

    var summary: String {
        if looksLikeBoard { return L10n.s("拼豆板") }
        if name.isEmpty { return L10n.s("未知设备") }
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
    /// 手选目标设备的展示名（用于 `.connecting` 期间 UI 文案，不依赖 peripheral.name）
    @Published var pendingConnectName: String = ""
    /// 调试开关：为 true 时不做名称/服务过滤，列出附近全部 BLE 设备。
    ///
    /// 存在的意义：过滤是「按名字」的，一旦用户板子固件不带 PIXDOU 前缀，
    /// 严格过滤会让他彻底看不到自己的板子、无路可走。这个开关是唯一的退路。
    /// App 重启后自动复位为 false，避免用户忘记关掉后又被杂设备列表淹没。
    @Published var showAllDevices = false

    // ---- 自动连接（点「连接」直接连 PIXDOU 板子，不弹设备列表） ----

    /// 是否处于「自动搜索并连接」流程中（UI 显示「搜索中…」）
    @Published var autoConnecting = false
    /// 自动连接失败原因（超时未找到候选设备时写入，UI 据此提示并回退手动选择）
    @Published var autoConnectFailure: String?

    /// 自动连接看门狗任务
    private var autoConnectTask: Task<Void, Never>?

    var onNotify: (([UInt8]) -> Void)?
    var onDisconnect: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var dataChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var centralReady = false

    // ---- 诊断状态（供日志解释「为什么卡住/为什么没列出」） ----

    /// 本次扫描以来「扫描到但被名称过滤掉」的设备名（最多留 40 条），
    /// 用于在列表为空时告诉用户到底扫到了什么，而不是一片空白。
    private var filteredOutNames: [String] = []
    /// 已尝试连接的设备 id，用于「重连」前先 cancel 掉旧连接，避免 connect 被静默忽略
    private var attemptedConnectID: UUID?
    /// 连接超时看门狗
    private var connectTimeoutTask: Task<Void, Never>?
    /// 特征发现超时任务（didConnect 后启动）
    private var charDiscoveryTask: Task<Void, Never>?

    /// 连接超时（秒）。超时后强制回到 `.idle` 并写日志 —— 绝不允许卡在 `.connecting`。
    private static let connectTimeout: TimeInterval = 15
    /// 特征发现超时（秒）。`discoverServices(nil)` 后逐服务发现特征，
    /// 5s 内 A951/A952 仍未凑齐即带诊断失败，避免用户等满 15s 全局看门狗。
    private static let charDiscoveryTimeout: TimeInterval = 5

    // ---- 通知等待队列（支持超时等待） ----

    /// 单个等待者：带 id 便于超时后精确移除，彻底消除僵尸 waiter。
    private struct NotifyWaiter {
        let id: UUID
        let cont: CheckedContinuation<[UInt8]?, Never>
    }

    private var notifyBuffer: [[UInt8]] = []
    private var notifyWaiters: [NotifyWaiter] = []

    /// 板卡名称关键字（命中视为疑似拼豆板，**仅用于排序/打标签，不用于过滤**）。
    ///
    /// 保留原有的宽松关键字集合：`led` / `pd` 这类短词用来「不误杀」，
    /// 但也正因为太宽松，不能拿来当过滤条件，否则邻居的 LED 灯带、PD 充电器都会被留下。
    private nonisolated static let boardNameHints = ["pixdou", "iledcolor", "wofan", "led", "pd"]

    /// 严格的名称前缀白名单（大小写不敏感）——用户明确要求「只显示 PIXDOU 开头的」。
    ///
    /// ⚠️ 待真机复核：`iLEDColor` / `Wofan` 是「同协议不同品牌」的合理推断
    /// （BoardTabView footer 原有文案即写明兼容 Wofan；`iLEDColor` 来自协议逆向注释），
    /// 若真机板子名字是别的写法，请在「调试 → 显示全部设备」里读出真实名字后补进本数组。
    private nonisolated static let strictNamePrefixes = ["PIXDOU", "iLEDColor", "iLED", "Wofan"]

    /// 名称是否命中严格前缀白名单
    nonisolated static func matchesNameAllowlist(_ name: String) -> Bool {
        let upper = name.uppercased()
        return strictNamePrefixes.contains { upper.hasPrefix($0.uppercased()) }
    }

    /// 把特征属性打印为原始位值。
    ///
    /// 这里刻意不做「可读名」翻译：`CBCharacteristicProperties` 是 OptionSet，
    /// 用 `.contains(_:)` 判断位时要走 CoreBluetooth 提供的专用重载，自己写位与容易出错，
    /// 一旦翻译错了会把排查引向歧途。原始位值配合 CoreBluetooth 头文件对照即可，不作假信息。
    nonisolated static func describe(_ props: CBCharacteristicProperties) -> String {
        "0x\(String(props.rawValue, radix: 16))"
    }

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
        filteredOutNames.removeAll()
        guard centralReady else {
            log("蓝牙未就绪（状态 \(central.state.rawValue)），稍后自动重试")
            return
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        linkState = .scanning
        log("开始扫描 BLE 设备…（过滤：\(showAllDevices ? "已关闭，显示全部设备" : "仅显示 " + Self.strictNamePrefixes.joined(separator: "/") + " 前缀，或有 A950/AE00 服务的板子")）")
    }

    func stopScan() {
        central.stopScan()
        if linkState == .scanning { linkState = .idle }
        log("停止扫描")
    }

    /// 切换「显示全部设备」调试开关。切换后清空当前列表并重扫，
    /// 否则用户切了开关却看不到任何变化，会以为开关坏了。
    func setShowAllDevices(_ on: Bool) {
        guard showAllDevices != on else { return }
        showAllDevices = on
        log(on ? "已开启「显示全部设备」（调试用，不过滤）" : "已关闭「显示全部设备」，恢复为仅显示拼豆板")
        if linkState == .scanning || linkState == .idle {
            startScan()
        }
    }

    /// 名称是否命中自动连接优先目标（PIXDOU / iLEDColor / Wofan 前缀，大小写不敏感）
    nonisolated static func isAutoConnectTarget(_ name: String) -> Bool {
        matchesNameAllowlist(name)
    }

    /// 自动连接：已连接直接返回；否则开始扫描，**发现候选板子立即连**（用户无需在列表里挑）。
    ///
    /// 候选判定（严格）：名称命中 PIXDOU/iLEDColor/Wofan 前缀，或广播 A950/AE00 服务，
    /// 或厂商标记 JLAISDK —— 不采用 `looksLikeBoard` 里的宽松 `led`/`pd` 关键字，
    /// 避免点一下就把邻居的 LED 灯带连上。
    ///
    /// - Parameter timeout: 超时秒数（默认 8s）；超时未找到候选则停扫、置 `autoConnectFailure`。
    func autoConnect(timeout: TimeInterval = 8) {
        guard linkState != .connected, linkState != .connecting else { return }
        autoConnectFailure = nil
        autoConnecting = true
        startScan()
        log("自动连接：搜索 \(Self.strictNamePrefixes.joined(separator: "/")) 拼豆板…（\(Int(timeout))s 超时）")

        autoConnectTask?.cancel()
        autoConnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.autoConnecting else { return }
            self.autoConnecting = false
            if self.linkState == .scanning { self.stopScan() }
            self.autoConnectFailure = L10n.s("没找到 PIXDOU 拼豆板。请确认板子已通电、蓝牙已开启，或手动选择设备。")
            self.log("自动连接超时：未发现候选设备，已回退到手动选择")
        }
    }

    /// 取消自动连接流程（用户手动选设备 / 断开 / 关闭面板时调用）
    func cancelAutoConnect() {
        autoConnectTask?.cancel()
        autoConnectTask = nil
        autoConnecting = false
    }

    /// 被名称过滤掉的设备（供 UI 在列表为空时给出解释文案）
    var filteredOutSummary: [String] { filteredOutNames }

    // MARK: - 连接

    /// 连接目标设备。
    ///
    /// P0-A/P0-D 修复要点：
    /// 1. 直接用 `board.peripheral` 建立连接，**不再走 `retrievePeripherals(withIdentifiers:)`**。
    ///    旧实现在 retrieve 返回空时**直接 return**，`linkState` 已经/即将停在 `.connecting` 永不复位，
    ///    这是「一直转圈、连不上」的直接死状态。
    /// 2. 连接前先停扫描（iOS 上扫描中连接会显著变慢甚至失败）。
    /// 3. 置 `.connecting` 后启动 15s 看门狗，超时强制回 `.idle` 并写日志，保证状态机永不死锁。
    /// 4. 重连同一台设备时先 `cancelPeripheralConnection`，否则重复 connect 可能被静默忽略
    ///    （表现为「点了没反应」）。
    func connect(_ board: DiscoveredBoard) {
        connectTimeoutTask?.cancel()
        // 手动选择设备时结束自动连接流程（若仍在等待超时）
        autoConnectTask?.cancel()
        autoConnectTask = nil
        autoConnecting = false
        autoConnectFailure = nil

        // 若正连着别的设备，先断开，避免两路连接互相干扰
        if let current = peripheral, current.identifier != board.id {
            log("先断开当前设备 \(current.name ?? current.identifier.uuidString)")
            central.cancelPeripheralConnection(current)
        }

        if linkState == .scanning {
            central.stopScan()
            log("连接前停止扫描")
        }

        let p = board.peripheral
        p.delegate = self

        // 同一台设备的重复连接请求：先 cancel 再 connect，避免被系统忽略
        if attemptedConnectID == board.id, peripheral?.identifier == board.id {
            log("复用上一次的连接尝试，先取消后重连")
            central.cancelPeripheralConnection(p)
        }
        attemptedConnectID = board.id

        pendingConnectName = board.name.isEmpty ? board.id.uuidString : board.name
        linkState = .connecting
        central.connect(p, options: nil)
        log("连接中：\(pendingConnectName)（id=\(board.id.uuidString)，RSSI=\(board.rssi)）")

        // 看门狗：15s 内未进入 .connected 就强制收尾，绝不允许停在 .connecting
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.linkState == .connecting else { return }
            self.log("⚠️ 连接超时（\(Int(Self.connectTimeout))s 未完成）。已强制复位。请确认：板子通电并在近处、未被官方 App 占用、蓝牙已开启。")
            self.abortConnection(p, reason: L10n.s("连接超时"))
        }
    }

    /// 统一的连接中止路径：取消连接、复位状态机、清空特征缓存。
    ///
    /// 所有失败分支（超时 / 服务缺失 / 特征缺失）都走这里，
    /// 保证「任何一步失败都回 `.idle`」，不再有死状态。
    private func abortConnection(_ p: CBPeripheral?, reason: String) {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        charDiscoveryTask?.cancel()
        charDiscoveryTask = nil
        if let p { central.cancelPeripheralConnection(p) }
        cmdChar = nil; dataChar = nil; notifyChar = nil
        peripheral = nil
        pendingConnectName = ""
        linkState = .idle
        connectedName = ""
        log("连接已中止：\(reason)")
    }

    func disconnect() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        charDiscoveryTask?.cancel()
        charDiscoveryTask = nil
        // 断开后清掉自动连接的残留状态，下次点「连接」重新自动搜索
        cancelAutoConnect()
        autoConnectFailure = nil
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
        // 用 if-let 绑定取代 `mfr!` 强制解包：mfr 是可选值，`&&` 短路虽能保证此处非 nil，
        // 但强制解包在真机异常路径（广播数据被截断等）下一旦失守就是直接崩溃，得不偿失。
        let jlaisdk: Bool
        if let mfr, mfr.count >= 7 {
            jlaisdk = String(data: mfr.suffix(7), encoding: .ascii) == "JLAISDK"
        } else {
            jlaisdk = false
        }
        let lower = name.lowercased()
        // P2：关键字数组提为静态量（Self.boardNameHints），避免每次扫描重复构造。
        let nameHit = Self.boardNameHints.contains { lower.contains($0) }
        // 用户明确要求：只显示 PIXDOU 开头的设备（大小写不敏感）
        let nameAllowed = Self.matchesNameAllowlist(name)

        let board = DiscoveredBoard(id: peripheral.identifier, name: name, rssi: RSSI.intValue,
                                    services: services, manufacturerData: mfr,
                                    looksLikeBoard: hasBoardService || jlaisdk || (nameHit && !name.isEmpty),
                                    matchesNameFilter: nameAllowed,
                                    peripheral: peripheral)
        Task { @MainActor in
            // ---- 过滤：【名称白名单】或【服务指纹】二者命中其一即保留 ----
            //
            // 服务指纹（A950/AE00）是与名字无关的最可靠判据：即使板子固件改了名、
            // 或广播里压根不带名字，只要广播了私有服务就不会被误杀。
            // JLAISDK 厂商标记同理是板子强指纹（来自旧版 looksLikeBoard 判定），
            // 名字不白名单、广播也不带 A950/AE00 的 JLAISDK 板子不能被误杀。
            // 名称白名单则覆盖「广播没带服务 UUID、但名字是 PIXDOU-xxxx」的情形。
            let shouldShow = showAllDevices || board.matchesNameFilter || hasBoardService || jlaisdk
            if shouldShow {
                if let i = boards.firstIndex(where: { $0.id == board.id }) {
                    boards[i] = board
                } else {
                    boards.append(board)
                    // 新增设备时留一条可追溯的日志，真机排查全靠它
                    log("发现设备：\(name.isEmpty ? "<无名>" : name) RSSI=\(RSSI.intValue)\(board.matchesNameFilter ? " [名称命中]" : "")\(hasBoardService ? " [服务命中]" : "")")
                }

                // ---- 自动连接：命中候选板子立即连，用户无需在列表里挑 ----
                // 判定刻意严格（名称白名单 / A950 服务 / JLAISDK 厂商指纹），
                // 不用 looksLikeBoard 里的宽松 led/pd 关键字，免得点一下连到邻居的灯带。
                if autoConnecting, linkState == .scanning,
                   (Self.isAutoConnectTarget(name) || hasBoardService || jlaisdk) {
                    log("自动连接：命中 \(name.isEmpty ? "<无名>" : name)，开始连接…")
                    autoConnecting = false
                    autoConnectTask?.cancel()
                    autoConnectTask = nil
                    connect(board)
                }
            } else {
                // 被过滤掉的设备名留档，供 UI 在列表为空时给出「其实扫到了 N 台，都被过滤了」
                // 的解释文案 —— 否则用户面对的是一片空白，无从判断哪里出了问题。
                // 去重：附近常有多台同名设备（如多个「LED-01」），不去重会让「已过滤 N 台」虚高。
                let display = name.isEmpty ? L10n.p("<无名 {0}>", "\(peripheral.identifier.uuidString.prefix(8))") : name
                if filteredOutNames.count < 40, !filteredOutNames.contains(display) {
                    filteredOutNames.append(display)
                }
                // 已被过滤的设备若之前误入了列表（例如开关切换前的残留），同步剔除
                if let i = boards.firstIndex(where: { $0.id == board.id }) {
                    boards.remove(at: i)
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.peripheral = peripheral
            peripheral.delegate = self
            log("已连接 \(peripheral.name ?? peripheral.identifier.uuidString)，发现服务…")
            // P0-B 修复：必须传 nil 发现【全部】服务。
            //
            // 旧实现只发现 [A950, AE00]。若真板子的 A951/A952/A953 挂在别的服务下
            // （部分固件用 A900，或厂商私有的 FFF0/FFE0），三个特征永远凑不齐，
            // `linkState` 就永远停在 .connecting —— UI 表现为「一直转圈、连不上」。
            // 下面 didDiscoverCharacteristicsFor 里的匹配本来就是按特征 UUID 全局匹配的，
            // 只要服务被发现就能命中，因此放开发现范围即可根治。
            peripheral.discoverServices(nil)

            // 特征发现超时（5s）：替代旧的「遍历 services 检查 characteristics 是否都非 nil」判定。
            // 旧判定依赖「每个服务都会回调一次 didDiscoverCharacteristicsFor」的假设，
            // 无特征服务可能被系统静默跳过（characteristics 停留在 nil），在多服务真机上不可靠；
            // 且旧判定只在特征回调里执行，失败场景要等满 15s 全局看门狗。
            // 现改为独立计时：两必需特征到齐会提前取消本任务，否则 5s 到点带完整诊断失败。
            charDiscoveryTask?.cancel()
            charDiscoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.charDiscoveryTimeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard self.linkState == .connecting else { return }
                guard self.peripheral?.identifier == peripheral.identifier else { return }
                guard self.cmdChar == nil || self.dataChar == nil else { return }
                var missing: [String] = []
                if self.cmdChar == nil { missing.append(L10n.s("A951(指令)")) }
                if self.dataChar == nil { missing.append(L10n.s("A952(数据)")) }
                if self.notifyChar == nil { missing.append(L10n.s("A953(通知，可选)")) }
                let found = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
                    .map { $0.uuid.uuidString }
                self.abortConnection(peripheral, reason: L10n.p("{0}s 内未发现必需特征（缺 {1}）。已发现的特征：[{2}]。这可能不是拼豆板，或固件使用了不同的特征 UUID", "\(Int(Self.charDiscoveryTimeout))", "\(missing.joined(separator: "、"))", "\(found.isEmpty ? "无" : found.joined(separator: ", "))"))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            // P0-D：走统一收尾路径，保证超时看门狗被取消、特征缓存被清空
            abortConnection(peripheral, reason: L10n.p("系统连接失败：{0}", "\(error?.localizedDescription ?? "未知错误")"))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            // P0-D：旧实现只在 `self.peripheral` 与新断开的 peripheral 相同时才复位 linkState。
            // 但重连场景下 `self.peripheral` 可能已被新连接覆盖（或已在 abortConnection 里置 nil），
            // 导致一次真实的断开被忽略、状态机卡死在 .connecting。改为：只要断开的不是当前
            // 在用的设备（或当前本就处于 .connecting/.connected），就一律复位。
            let isCurrent = self.peripheral?.identifier == peripheral.identifier
            let wasUnsettled = (linkState == .connecting || linkState == .connected)
            guard isCurrent || wasUnsettled else { return }

            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            cmdChar = nil; dataChar = nil; notifyChar = nil
            if isCurrent { self.peripheral = nil }
            pendingConnectName = ""
            linkState = .idle
            connectedName = ""
            log("已断开\(error.map { "（\($0.localizedDescription)）" } ?? "")")
            onDisconnect?()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            // 只处理当前目标设备的回调，避免上一次连接的迟到回调污染新连接的状态
            guard self.peripheral?.identifier == peripheral.identifier else { return }

            if let error {
                // P0-D：发现服务失败也必须收尾，不能停在 .connecting
                abortConnection(peripheral, reason: L10n.p("发现服务失败：{0}", "\(error.localizedDescription)"))
                return
            }
            let svcList = peripheral.services ?? []
            guard !svcList.isEmpty else {
                abortConnection(peripheral, reason: L10n.s("该设备没有暴露任何 GATT 服务（可能不是拼豆板，或已被官方 App 占用）"))
                return
            }
            // 服务全貌是排查「特征找不到」的第一手证据，必须完整打印
            log("发现 \(svcList.count) 个服务：\(svcList.map { $0.uuid.uuidString }.joined(separator: ", "))")
            for svc in svcList {
                peripheral.discoverCharacteristics(nil, for: svc)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            // 只处理当前目标设备
            guard self.peripheral?.identifier == peripheral.identifier else { return }
            // 已经就绪后不再重复判定（多个服务会各触发一次本回调）
            guard linkState != .connected else { return }

            if let error {
                log("发现特征失败（服务 \(service.uuid.uuidString)）：\(error.localizedDescription)")
                return
            }
            for c in service.characteristics ?? [] {
                log("  特征：\(c.uuid)  props=\(Self.describe(c.properties))  服务=\(service.uuid.uuidString)")
                if c.uuid == BLEProtocol.cmdUUID { cmdChar = c }
                if c.uuid == BLEProtocol.dataUUID { dataChar = c }
                if c.uuid == BLEProtocol.notifyUUID {
                    notifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                }
            }

            // ---- P0-C：就绪判定改为「两必需 + 一可选」 ----
            //
            // A951(cmd) 与 A952(data) 缺一不可：没有它们无法下发任何指令或数据。
            // A953(notify) 视为【可选】—— 部分固件是纯单向写、不提供通知通道。
            // 旧实现要求三者齐全才置 .connected，只要缺 A953 就永远卡在 .connecting，
            // 且没有任何日志说明缺了什么，用户只能看到无限转圈。
            guard cmdChar != nil, dataChar != nil else {
                // 还不能判定失败：其他服务的特征回调可能尚未到达，
                // 交给 didConnect 启动的 5s 特征发现超时兜底（超时会带「缺哪个/已发现什么」诊断复位）。
                return
            }

            charDiscoveryTask?.cancel()
            charDiscoveryTask = nil
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            linkState = .connected
            connectedName = peripheral.name ?? peripheral.identifier.uuidString
            if notifyChar != nil {
                log("拼豆板就绪（A951+A952+A953 齐全），最大单包写入 \(maxWriteLength) 字节")
            } else {
                // ⚠️ 待真机复核：缺 A953 时板子能否正常应答 Connect/TestPass 尚未验证。
                // 这里选择「仍然置为已连接」，让用户至少可以尝试发图（纯写路径），
                // 而不是像旧版一样彻底卡死。若真机确认握手必然失败，应改为在此直接报错。
                log("⚠️ 拼豆板就绪，但未发现 A953 通知特征：本设备可能不支持应答回传，握手/发图可能超时")
            }
            drainNotifications()
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
