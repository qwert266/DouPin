import SwiftData
import SwiftUI

// MARK: - 拼豆板标签页（连接 / 控制 / 调试）

struct BoardTabView: View {
    var body: some View {
        NavigationStack {
            BoardPanel()
                .navigationTitle("拼豆板")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct BoardPanel: View {
    @ObservedObject var board = AppState.shared.board
    @ObservedObject private var central = AppState.shared.board.central
    @Query(sort: \Pattern.updatedAt, order: .reverse) private var patterns: [Pattern]

    @State private var brightness = 80
    @State private var displayOn = true
    @State private var showPatternPicker = false
    @State private var sendTarget: Pattern?
    @State private var infoMessage: String?
    @State private var didHandshake = false
    @State private var brightnessTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                connectionHero
                if deviceCardVisible { deviceListCard }
                if central.linkState == .connected {
                    controlCard
                    sendCard
                }
                debugCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Theme.pageFill)
        .onChange(of: central.linkState) { _, state in
            if state == .connected {
                didHandshake = false
                Task {
                    do {
                        try await board.handshake()
                        didHandshake = true
                        // P1-3：握手成功后把当前 UI 状态（显示开关 + 亮度）同步到实物，
                        // 避免本地状态与灯板不一致。
                        await board.syncDisplayState(on: displayOn, brightnessPercent: brightness)
                    } catch {
                        infoMessage = error.localizedDescription
                    }
                }
            } else {
                didHandshake = false
            }
        }
        .onChange(of: sendTarget) { _, p in
            if let p { send(pattern: p) }
        }
        .sheet(isPresented: $showPatternPicker) {
            NavigationStack {
                List(patterns) { p in
                    Button {
                        showPatternPicker = false
                        sendTarget = p
                    } label: {
                        PatternRow(pattern: p)
                    }
                    .tint(.primary)
                }
                .navigationTitle("选择要发送的图纸")
                .navigationBarTitleDisplayMode(.inline)
                .overlay {
                    if patterns.isEmpty {
                        ContentUnavailableView("暂无图纸", systemImage: "square.grid.3x3")
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .alert("拼豆板", isPresented: Binding(get: { infoMessage != nil },
                                         set: { if !$0 { infoMessage = nil } })) {
            Button("好", role: .cancel) { infoMessage = nil }
        } message: {
            Text(infoMessage ?? "")
        }
        .onAppear {
            displayOn = true
        }
    }

    // MARK: - 连接英雄卡

    private var connectionHero: some View {
        VStack(spacing: 16) {
            // 状态大圆灯
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 84, height: 84)
                Circle()
                    .fill(
                        LinearGradient(colors: [statusColor.opacity(0.85), statusColor],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 62, height: 62)
                Image(systemName: statusIcon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 4) {
                Text(statusText).font(.title3.bold())
                if central.linkState == .connected {
                    Text(didHandshake ? "已握手，可发图与控制" : "已连接，正在握手…")
                        .font(.caption)
                        .foregroundStyle(didHandshake ? .green : .secondary)
                } else if central.linkState == .connecting {
                    // P0-D：必须用 pendingConnectName 而非 connectedName。
                    // `connectedName` 只在真正连上后才赋值，连接期间它仍是空串，
                    // 旧写法会渲染成「正在连接 …」，用户看不出到底在连哪台。
                    Text("正在连接 \(central.pendingConnectName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if central.linkState == .idle {
                    Text("给拼豆板通电，点下方按钮开始连接")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 主操作按钮
            switch central.linkState {
            case .idle, .poweredOff:
                primaryButton(title: "扫描附近设备", icon: "dot.radiowaves.left.and.right",
                              gradient: central.linkState == .poweredOff ? nil : Theme.sky)
                {
                    central.startScan()
                }
                .disabled(central.linkState == .poweredOff)

            case .scanning:
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("正在搜索…")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        central.stopScan()
                    } label: {
                        Text("停止")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                }
                .padding(.leading, 18).padding(.trailing, 10)
                .frame(height: 50)
                .frame(maxWidth: .infinity)
                .background(Theme.sky, in: Capsule())
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)

            case .connecting:
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("连接中…")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .frame(height: 50)
                .frame(maxWidth: .infinity)
                .background(Theme.sky.opacity(0.75), in: Capsule())

            case .connected:
                Button {
                    central.disconnect()
                } label: {
                    Label("断开连接", systemImage: "minus.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(height: 22)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.red.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle(padding: 20)
    }

    /// 全宽渐变主按钮
    private func primaryButton(title: String, icon: String, gradient: LinearGradient?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(gradient.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Color.secondary.opacity(0.4)), in: Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: gradient != nil ? .black.opacity(0.10) : .clear, radius: 10, y: 4)
    }

    // MARK: - 设备列表卡（含过滤提示 / 调试退路开关）

    private var deviceListCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 扫描中空列表提示：绝不能一片空白 —— 必须告诉用户「扫到了多少台、都被过滤了」，
            // 否则无从判断是板子没通电、还是被过滤误杀、还是 App 坏了。
            if central.boards.isEmpty && central.linkState == .scanning && !central.showAllDevices {
                // 去重后再展示与计数：附近常有多台同名设备（如多个「LED-01」），
                // 直接拿数组 count 会虚高，且列表里出现重复名字会让用户以为 App 有 bug。
                // 用 seen 集合保序去重（纯 Swift，不引 Foundation 桥接）。
                var seen = Set<String>()
                let filtered = central.filteredOutSummary.filter { seen.insert($0).inserted }
                if !filtered.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("已过滤 \(filtered.count) 台无关设备", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.subheadline.weight(.medium))
                        Text(filtered.prefix(6).joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        if filtered.count > 6 {
                            Text("…等共 \(filtered.count) 台")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text("如果其中有你的拼豆板，请打开下面的「显示全部蓝牙设备」开关。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在搜索拼豆板，请确保已通电…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
            }

            // 扫描结果设备行
            if !central.boards.isEmpty && central.linkState != .connected {
                ForEach(sortedBoards) { b in
                    Button {
                        central.connect(b)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lightbulb.max.fill")
                                .font(.title3)
                                .foregroundStyle(b.looksLikeBoard
                                                 ? AnyShapeStyle(Theme.brand)
                                                 : AnyShapeStyle(Color.secondary))
                                .frame(width: 40, height: 40)
                                .background((b.looksLikeBoard ? Color.pink : Color.secondary).opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(b.summary).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    if b.looksLikeBoard {
                                        Text("疑似拼豆板")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 7).padding(.vertical, 2)
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
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(b.rssi) dBm")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(10)
                        .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            // 调试退路开关：默认只显示 PIXDOU 类拼豆板；一旦用户的板子因固件改名/不带名字
            // 被过滤误杀，这里是他唯一的自救入口。必须走 setShowAllDevices(_:)：
            // 该方法在切换时会清空列表并重扫，否则用户切了开关却看不到任何变化，会以为开关坏了。
            if central.linkState == .scanning || central.linkState == .idle {
                Toggle(isOn: Binding(
                    get: { central.showAllDevices },
                    set: { central.setShowAllDevices($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示全部蓝牙设备").font(.subheadline)
                        Text("调试用。找不到你的板子时可打开，查看是否被名称过滤挡掉了。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 页脚说明
            if central.linkState != .connected {
                Text(footerHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .cardStyle()
    }

    private var deviceCardVisible: Bool {
        central.linkState == .scanning || central.linkState == .idle
    }

    private var footerHint: String {
        if central.linkState == .scanning {
            return central.showAllDevices
                ? "正在搜索附近的全部 BLE 设备（过滤已关闭）。请确保拼豆板已通电，优先选择标有「疑似拼豆板」的。"
                : "为屏蔽无关设备，当前仅显示名称以 PIXDOU / iLEDColor / Wofan 开头、或广播 A950/AE00 服务的设备。"
        }
        return "仅显示 PIXDOU / iLEDColor / Wofan 前缀或带 A950/AE00 蓝牙服务的智能拼豆板。板子没出现时可打开上方开关查看全部设备。"
    }

    private var sortedBoards: [DiscoveredBoard] {
        central.boards.sorted { a, b in
            if a.looksLikeBoard != b.looksLikeBoard { return a.looksLikeBoard }
            return a.rssi > b.rssi
        }
    }

    private var statusIcon: String {
        switch central.linkState {
        case .poweredOff: return "exclamationmark.triangle.fill"
        case .connected: return "checkmark.circle.fill"
        case .scanning, .connecting: return "dot.radiowaves.left.and.right"
        case .idle: return "lightbulb"
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

    // MARK: - 灯板控制卡

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("灯板控制", systemImage: "slider.horizontal.3")
                .font(.subheadline.bold())

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("亮度").font(.subheadline)
                    Spacer()
                    Text("\(brightness)%")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                Slider(value: Binding(
                    get: { Double(brightness) },
                    set: { newValue in
                        brightness = Int(newValue)
                    }), in: 10...100, step: 5)
                    .tint(Theme.accent)
                    .onChange(of: brightness) { _, pct in
                        brightnessTask?.cancel()
                        brightnessTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)   // 防抖，避免拖动时刷指令
                            guard !Task.isCancelled else { return }
                            await board.setBrightness(level: board.level(forBrightnessPercent: pct))
                        }
                    }
                    .disabled(central.linkState != .connected)
            }

            Toggle("点亮灯板", isOn: Binding(
                get: { displayOn },
                set: { on in
                    displayOn = on
                    Task { await board.setDisplay(on) }
                }))
                .font(.subheadline)
                .disabled(central.linkState != .connected)
        }
        .cardStyle()
    }

    // MARK: - 发送图纸卡

    private var sendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("发送图纸", systemImage: "square.and.arrow.up.on.square")
                .font(.subheadline.bold())

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
                    showPatternPicker = true
                } label: {
                    Label("发送图纸到拼豆板", systemImage: "paperplane.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(height: 22)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Theme.brand, in: Capsule())
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                .disabled(!didHandshake)
                .opacity(didHandshake ? 1 : 0.45)

                Text("发送完整预览图；已拼的格子会以暗色显示（需要在作品详情里打卡进度）。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .cardStyle()
    }

    // MARK: - 调试卡

    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                BoardLogView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.gray.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("蓝牙控制台").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Text(central.logLines.last.map { String($0.suffix(48)) } ?? "暂无日志")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .cardStyle(padding: 12)
    }

    private func send(pattern: Pattern) {
        Task {
            do {
                if !didHandshake { try await board.handshake(); didHandshake = true }
                let rgb = BoardImageBuilder.fullImage(width: pattern.width, height: pattern.height,
                                                      cells: pattern.cells, placed: pattern.placed)
                try await board.sendImage(width: pattern.width, height: pattern.height, rgb: rgb)
                infoMessage = "「\(pattern.name)」已发送到拼豆板"
            } catch {
                infoMessage = "发送失败：\(error.localizedDescription)"
            }
            sendTarget = nil
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
