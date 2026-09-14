import SwiftData
import SwiftUI

// MARK: - 拼豆板相关视图（连接面板 / 连接胶囊 / 日志控制台）

// 注：原「拼豆板」标签页（BoardPanel）已移除——连接交给全局连接胶囊，
// 发图/分色引导在作品详情，灯板日志在「我的 → 蓝牙日志控制台」。

// MARK: - 用色明细行（分色引导 / 快速发送共用）

/// 图纸用色行：色号 + 总颗数 + 未拼颗数
struct BeadUsageRow: Identifiable {
    let id: Int          // colorId
    let color: BeadColor
    let total: Int
    let remaining: Int
}

extension Pattern {
    /// 用色明细（按未拼颗数降序）
    var usageRows: [BeadUsageRow] {
        var total: [Int: Int] = [:]
        var done: [Int: Int] = [:]
        for (i, c) in cells.enumerated() where c > 0 {
            total[c, default: 0] += 1
            if i < placed.count && placed[i] { done[c, default: 0] += 1 }
        }
        return total.compactMap { id, n -> BeadUsageRow? in
            guard let color = BeadPalette.byId[id] else { return nil }
            return BeadUsageRow(id: id, color: color, total: n, remaining: n - (done[id] ?? 0))
        }
        .sorted { $0.remaining > $1.remaining }
    }
}

// MARK: - 快速发送图纸（转图完成后 / 作品详情入口；支持完整预览与分色点亮）

/// 自包含的发送面板：预览 + 连接状态 + 模式（完整/分色）+ 发送进度。
/// 连接复用全局 `BoardSession`（任意页面右上角连接胶囊连上后这里直接可用）。
struct BoardSendSheet: View {
    let pattern: Pattern
    @ObservedObject private var board = AppState.shared.board
    @ObservedObject private var central = AppState.shared.board.central
    @Environment(\.dismiss) private var dismiss

    @State private var mode: SendMode = .full
    @State private var guideColorId: Int?
    @State private var busy = false
    @State private var infoMessage: String?

    enum SendMode: String, CaseIterable, Identifiable {
        case full = "完整预览"
        case color = "分色点亮"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    previewCard
                    connectionCard
                    modeCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(Theme.pageFill)
            .navigationTitle("开始拼豆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("拼豆板", isPresented: Binding(get: { infoMessage != nil },
                                             set: { if !$0 { infoMessage = nil } })) {
                Button("好", role: .cancel) { infoMessage = nil }
            } message: {
                Text(infoMessage ?? "")
            }
            .onAppear {
                if guideColorId == nil { guideColorId = pattern.usageRows.first?.color.id }
            }
        }
    }

    // MARK: 预览

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(pattern.name).font(.headline)
                Spacer()
                Text("\(pattern.width)×\(pattern.height) · \(pattern.totalBeads) 颗")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GridView(cells: pattern.cells, width: pattern.width, height: pattern.height, showGuides: false)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .cardStyle()
    }

    // MARK: 连接状态

    @ViewBuilder
    private var connectionCard: some View {
        if central.linkState == .connected {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("已连接 \(central.connectedName)")
                    .font(.subheadline)
                Spacer()
                Text(didHandshakeReady ? "可发送" : "准备握手…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .cardStyle(padding: 12)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "lightbulb")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.amber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("拼豆板未连接").font(.subheadline.weight(.medium))
                    Text("点右上角「连接」按钮连上拼豆板后，这里就能发送")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .cardStyle(padding: 12)
        }
    }

    /// 会话是否可用（连接 + 首次发送前自动握手，无需手工状态）
    private var didHandshakeReady: Bool { central.linkState == .connected }

    // MARK: 模式 + 发送

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("发送模式", selection: $mode) {
                ForEach(SendMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            if mode == .color {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选一种颜色，灯板只亮这种颜色的位置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pattern.usageRows) { row in
                                colorChip(row)
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                    }
                }
            }

            if board.isSending {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在发送… \(Int(board.sendProgress * 100))%")
                        .font(.subheadline)
                        .monospacedDigit()
                    ProgressView(value: board.sendProgress)
                        .tint(Theme.brand)
                }
            } else {
                Button {
                    sendCurrent()
                } label: {
                    Label(mode == .full ? "发送完整图，开始拼豆" : "点亮该色，开始拼豆",
                          systemImage: "paperplane.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(height: 22)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(canSend ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.secondary.opacity(0.35)),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .shadow(color: canSend ? .black.opacity(0.10) : .clear, radius: 10, y: 4)
                .disabled(!canSend)

                if mode == .color {
                    Button {
                        finishColorAndAdvance()
                    } label: {
                        Label("此色拼完 → 下一色", systemImage: "checkmark.circle.badge.arrow.forward")
                            .font(.subheadline.bold())
                            .foregroundStyle(Theme.accent)
                            .frame(height: 18)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.accent.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }

                Text(mode == .full
                     ? "完整预览：已拼的格子以暗色显示。"
                     : "分色点亮：只亮选中色号；「此色拼完」会自动打卡整色并点亮下一色。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .cardStyle()
    }

    private var canSend: Bool {
        central.linkState == .connected && !busy && (mode == .full || guideColorId != nil)
    }

    private func colorChip(_ row: BeadUsageRow) -> some View {
        let active = guideColorId == row.color.id
        return Button {
            guideColorId = row.color.id
        } label: {
            HStack(spacing: 6) {
                BeadDot(color: row.color, size: 20)
                Text(row.color.mard)
                    .font(.caption.monospaced().weight(.semibold))
                Text("剩\(row.remaining)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(active ? AnyShapeStyle(Theme.brand.opacity(0.14)) : AnyShapeStyle(Theme.cardFill), in: Capsule())
            .overlay(Capsule().stroke(active ? Theme.accent : Color.secondary.opacity(0.15), lineWidth: active ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: 动作

    private func sendCurrent() {
        Task {
            busy = true
            defer { busy = false }
            let rgb: [UInt8]
            switch mode {
            case .full:
                rgb = BoardImageBuilder.fullImage(width: pattern.width, height: pattern.height,
                                                  cells: pattern.cells, placed: pattern.placed)
            case .color:
                guard let cid = guideColorId else { return }
                rgb = BoardImageBuilder.colorGuide(width: pattern.width, height: pattern.height,
                                                   cells: pattern.cells, colorId: cid, placed: pattern.placed)
            }
            do {
                try await board.sendImage(width: pattern.width, height: pattern.height, rgb: rgb)
                Haptics.success()
            } catch {
                infoMessage = "发送失败：\(error.localizedDescription)"
            }
        }
    }

    /// 整色打卡并点亮下一色（未拼颗数最多的优先）
    private func finishColorAndAdvance() {
        guard let cid = guideColorId else { return }
        pattern.placeColor(colorId: cid)
        if let next = pattern.usageRows.first(where: { $0.remaining > 0 && $0.color.id != cid }) {
            guideColorId = next.color.id
        }
        sendCurrent()
    }
}

// MARK: - 连接面板（任意页面可用的「一键连接」Sheet）

/// 自包含连接面板：扫描 / 停止 / 设备列表 / 连接 / 断开 + 连上后的亮度与点亮控制。
///
/// 与全局连接胶囊共用同一个 `BoardSession`（`AppState.shared.board`），
/// 因此在图纸详情右上角一键连上后，全 App 的连接状态与灯板控制都同步。
struct BoardConnectSheet: View {
    @ObservedObject private var board = AppState.shared.board
    @ObservedObject private var central = AppState.shared.board.central
    @Environment(\.dismiss) private var dismiss

    @State private var didHandshake = false
    @State private var brightness = 80
    @State private var displayOn = true
    @State private var infoMessage: String?
    @State private var brightnessTask: Task<Void, Never>?

    private var sortedBoards: [DiscoveredBoard] {
        central.boards.sorted { a, b in
            if a.looksLikeBoard != b.looksLikeBoard { return a.looksLikeBoard }
            return a.rssi > b.rssi
        }
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if central.linkState != .connected { deviceSection }
                if central.linkState == .connected { controlSection }
            }
            .themedListPage()
            .navigationTitle("连接拼豆板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: central.linkState) { _, state in
                guard state == .connected else {
                    didHandshake = false
                    return
                }
                Task {
                    didHandshake = false
                    do {
                        try await board.handshake()
                        didHandshake = true
                        await board.syncDisplayState(on: displayOn, brightnessPercent: brightness)
                    } catch {
                        infoMessage = error.localizedDescription
                    }
                }
            }
            .onAppear {
                if central.linkState == .connected { didHandshake = true }
            }
            .alert("拼豆板", isPresented: Binding(get: { infoMessage != nil },
                                             set: { if !$0 { infoMessage = nil } })) {
                Button("好", role: .cancel) { infoMessage = nil }
            } message: {
                Text(infoMessage ?? "")
            }
        }
    }

    // MARK: 状态 + 主操作

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText).font(.subheadline.weight(.medium))
                    Text(statusHint).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }

            switch central.linkState {
            case .idle, .poweredOff, .scanning:
                // 自动连接主按钮（对标 PIXDOU：点一下就连上，不用在列表里挑）
                Button {
                    if central.autoConnecting {
                        central.cancelAutoConnect()
                    } else {
                        central.autoConnect()
                    }
                } label: {
                    Label(central.autoConnecting ? "正在搜索 PIXDOU…（点此取消）" : "自动连接拼豆板",
                          systemImage: "bolt.horizontal.circle.fill")
                }
                .disabled(central.linkState == .poweredOff)

                if let failure = central.autoConnectFailure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case .connecting:
                HStack {
                    ProgressView()
                    Text("连接中 \(central.pendingConnectName)…").font(.subheadline)
                }
            case .connected:
                Button(role: .destructive) {
                    central.disconnect()
                } label: {
                    Label("断开连接", systemImage: "minus.circle.fill")
                }
            }
        } header: {
            Text("状态")
        } footer: {
            if central.linkState != .connected {
                Text("点「自动连接拼豆板」会自动搜索并连接名字带 PIXDOU 的板子（也兼容 iLEDColor / Wofan）；没连上时可在下方列表手动选择。")
            }
        }
    }

    private var statusColor: Color {
        switch central.linkState {
        case .poweredOff: return .red
        case .connected: return .green
        case .scanning, .connecting: return Color(red: 0.20, green: 0.56, blue: 1.00)
        case .idle: return .gray
        }
    }

    private var statusText: String {
        switch central.linkState {
        case .poweredOff: return "蓝牙未开启"
        case .idle: return "未连接"
        case .scanning: return "扫描中…"
        case .connecting: return "连接中…"
        case .connected: return central.connectedName
        }
    }

    private var statusHint: String {
        switch central.linkState {
        case .connected:
            return didHandshake ? "已握手，可以发图和点亮引导" : "已连接，正在握手…"
        case .scanning:
            return "请确保拼豆板已通电"
        case .idle:
            return "点下方按钮搜索附近的拼豆板"
        case .connecting:
            return "首次连接需要几秒"
        case .poweredOff:
            return "请在系统设置中打开蓝牙"
        }
    }

    // MARK: 设备列表

    private var deviceSection: some View {
        Section {
            if sortedBoards.isEmpty {
                if central.linkState == .scanning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在搜索拼豆板…").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text("还没有扫描结果")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(sortedBoards) { b in
                    Button {
                        central.connect(b)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lightbulb.max.fill")
                                .foregroundStyle(b.looksLikeBoard ? AnyShapeStyle(Theme.brand)
                                                                  : AnyShapeStyle(Color.secondary))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(b.summary).font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if b.looksLikeBoard {
                                        Text("疑似拼豆板")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Theme.brand, in: Capsule())
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(b.name.isEmpty ? b.id.uuidString : b.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(b.rssi) dBm")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Toggle(isOn: Binding(
                get: { central.showAllDevices },
                set: { central.setShowAllDevices($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("显示全部蓝牙设备").font(.subheadline)
                    Text("找不到板子时打开，查看是否被名称过滤挡掉")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(central.linkState == .connecting || central.linkState == .connected)
        } header: {
            Text("附近设备")
        } footer: {
            Text("默认只显示 PIXDOU / iLEDColor / Wofan 前缀或带 A950 服务的设备。")
        }
    }

    // MARK: 连上后的快捷控制

    private var controlSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("亮度").font(.subheadline)
                    Spacer()
                    Text("\(brightness)%")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                Slider(value: Binding(get: { Double(brightness) },
                                      set: { brightness = Int($0) }),
                       in: 10...100, step: 5)
                    .tint(Theme.accent)
                    .onChange(of: brightness) { _, pct in
                        brightnessTask?.cancel()
                        brightnessTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            guard !Task.isCancelled else { return }
                            await board.setBrightness(level: board.level(forBrightnessPercent: pct))
                        }
                    }
            }

            Toggle("点亮灯板", isOn: Binding(
                get: { displayOn },
                set: { on in
                    displayOn = on
                    Task { await board.setDisplay(on) }
                }))
                .font(.subheadline)
        } header: {
            Text("快捷控制")
        } footer: {
            Text("连上后可直接回到图纸页点「开始拼豆」发送完整图或分色点亮。")
        }
    }
}

// MARK: - 全局连接胶囊（每个 Tab 导航栏右上角复用）

/// 「连接拼豆板」胶囊按钮（各 Tab 导航栏统一放置）。
///
/// 交互（对标 PIXDOU「点一下就连上」）：
/// - **未连接**：点一下**直接自动搜索并连接** PIXDOU 板子（不弹设备列表）；
///   搜索中显示「搜索中…」转圈，再点一次可取消；自动连接失败时自动弹出连接面板兜底。
/// - **已连接**：点一下打开连接面板（状态 / 亮度 / 点亮 / 断开）。
///
/// 内部直接观察全局 `BoardSession` 与 `BLECentral`，状态变化自动刷新。
struct BoardConnectCapsule: View {
    @ObservedObject private var board = AppState.shared.board
    @ObservedObject private var central = AppState.shared.board.central
    /// 「设置 → 自动连接拼豆板」；关闭后点击胶囊直接进入手动选择面板
    @AppStorage("autoConnectBLE") private var autoConnectBLE = true
    @State private var showSheet = false

    private var label: String {
        if board.isConnected { return "已连接" }
        if central.autoConnecting { return "搜索中" }
        return "连接"
    }

    var body: some View {
        Button {
            if board.isConnected {
                showSheet = true
            } else if central.autoConnecting {
                central.cancelAutoConnect()
            } else if autoConnectBLE {
                central.autoConnect()
            } else {
                showSheet = true   // 关闭自动连接 → 手动选择面板
            }
        } label: {
            HStack(spacing: 4) {
                if central.autoConnecting {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 10, height: 10)
                        .tint(.white)
                } else {
                    Image(systemName: board.isConnected ? "checkmark.circle.fill" : "link")
                        .font(.caption2.bold())
                }
                Text(label)
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(board.isConnected
                        ? AnyShapeStyle(Color.green.opacity(0.16))
                        : AnyShapeStyle(Theme.sky), in: Capsule())
            .foregroundStyle(board.isConnected ? Color.green : Color.white)
        }
        .buttonStyle(.plain)
        // 自动连接失败 → 自动弹出面板，让用户手动选或重试
        .onChange(of: central.autoConnectFailure) { _, failure in
            if failure != nil { showSheet = true }
        }
        .sheet(isPresented: $showSheet) {
            BoardConnectSheet()
        }
    }
}

// MARK: - BLE 日志控制台 + 手动指令

struct BoardLogView: View {
    @ObservedObject private var central = AppState.shared.board.central

    @State private var hexInput = ""
    @State private var hexError: String?
    @State private var charChoice = 0   // 0 = A951 指令, 1 = A952 数据

    var body: some View {
        List {
            Section {
                TextEditor(text: $hexInput)
                    .font(.body.monospaced())
                    .frame(minHeight: 60)
                    .overlay(alignment: .topLeading) {
                        if hexInput.isEmpty {
                            Text("十六进制帧，如 54 0d 00 02 00 57")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
                Picker("写入特征", selection: $charChoice) {
                    Text("A951 指令").tag(0)
                    Text("A952 数据").tag(1)
                }
                .pickerStyle(.segmented)
                Button {
                    sendHex()
                } label: {
                    Label("发送", systemImage: "paperplane.fill")
                }
                .disabled(hexInput.trimmingCharacters(in: .whitespaces).isEmpty)
                if let hexError {
                    Text(hexError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("手动发送指令")
            } footer: {
                Text("常用指令（含校验，可直接粘贴）：握手 Connect = 54 0d 00 03 00 00 64；校验密码 TestPass = 54 0f 00 08 00 00 00 00 00 00 00 6b；亮度 5 级 = 54 09 00 0b 05 00 00 00 00 00 00 00 00 00 6d；开屏 = 54 0a 00 0b 01 00 00 00 00 00 00 00 00 00 70。用于协议排查。")
            }

            Section {
                ForEach(Array(central.logLines.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                HStack {
                    Text("日志（最新在前）")
                    Spacer()
                    Button("清空") { central.logLines.removeAll() }
                        .font(.caption)
                }
            }
        }
        .navigationTitle("蓝牙控制台")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendHex() {
        let cleaned = hexInput
            .replacingOccurrences(of: "0x", with: " ")
            .filter { $0.isHexDigit || $0 == " " }
            .split(separator: " ")
            .compactMap { UInt8($0, radix: 16) }
        guard !cleaned.isEmpty else {
            hexError = "无法解析十六进制字节"
            return
        }
        hexError = nil
        Task {
            if charChoice == 0 {
                await central.writeCmd(cleaned)
            } else {
                await central.writeData(cleaned)
            }
        }
    }
}
