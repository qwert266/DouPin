import SwiftData
import SwiftUI

// MARK: - 拼豆板标签页（连接 / 控制 / 调试）

struct BoardTabView: View {
    var body: some View {
        NavigationStack {
            BoardPanel()
                .navigationTitle("拼豆板")
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
        Form {
            connectionSection

            if central.linkState == .connected {
                controlSection
                sendSection
            }

            debugSection
        }
        .onChange(of: central.linkState) { _, state in
            if state == .connected {
                didHandshake = false
                Task {
                    do {
                        try await board.handshake()
                        didHandshake = true
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

    // MARK: - 连接区

    private var connectionSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText).font(.headline)
                    if central.linkState == .connected {
                        Text(didHandshake ? "已握手，可发图与控制" : "已连接，正在握手…")
                            .font(.caption)
                            .foregroundStyle(didHandshake ? .green : .secondary)
                    }
                }
                Spacer()
            }

            switch central.linkState {
            case .idle, .poweredOff:
                Button {
                    central.startScan()
                } label: {
                    Label("扫描附近设备", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(central.linkState == .poweredOff)

            case .scanning:
                HStack {
                    Button {
                        central.stopScan()
                    } label: {
                        Label("停止扫描", systemImage: "stop.circle")
                    }
                    ProgressView()
                }

            case .connecting:
                HStack {
                    ProgressView()
                    Text("正在连接 \(central.connectedName)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            case .connected:
                Button(role: .destructive) {
                    central.disconnect()
                } label: {
                    Label("断开连接", systemImage: "minus.circle")
                }
            }

            if !central.boards.isEmpty && central.linkState != .connected {
                ForEach(sortedBoards) { b in
                    Button {
                        central.connect(b)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(b.summary).font(.body.weight(.medium))
                                    if b.looksLikeBoard {
                                        Text("疑似拼豆板")
                                            .font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.pink.opacity(0.15))
                                            .foregroundStyle(.pink)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(b.name.isEmpty ? b.id.uuidString : b.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(b.rssi) dBm").font(.caption.monospaced())
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
        } header: {
            Text(central.linkState == .connected ? "已连接" : "连接拼豆板")
        } footer: {
            if central.linkState != .connected && central.boards.isEmpty && central.linkState == .scanning {
                Text("正在搜索附近的 BLE 设备，请确保拼豆板已通电。普通设备也会列出，优先选择标有「疑似拼豆板」的。")
            } else if central.linkState == .idle {
                Text("支持 Wofan / PIXDOU 类智能拼豆板（A950 蓝牙服务）。")
            }
        }
    }

    private var sortedBoards: [DiscoveredBoard] {
        central.boards.sorted { a, b in
            if a.looksLikeBoard != b.looksLikeBoard { return a.looksLikeBoard }
            return a.rssi > b.rssi
        }
    }

    private var statusIcon: String {
        switch central.linkState {
        case .poweredOff: return "exclamationmark.triangle"
        case .connected: return "checkmark.circle.fill"
        case .scanning, .connecting: return "dot.radiowaves.left.and.right"
        case .idle: return "lightbulb"
        }
    }

    private var statusColor: Color {
        switch central.linkState {
        case .poweredOff: return .red
        case .connected: return .green
        case .scanning, .connecting: return .blue
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

    // MARK: - 灯板控制

    private var controlSection: some View {
        Section("灯板控制") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("亮度", value: "\(brightness)%")
                Slider(value: Binding(
                    get: { Double(brightness) },
                    set: { newValue in
                        brightness = Int(newValue)
                    }), in: 10...100, step: 5)
                    .onChange(of: brightness) { _, pct in
                        brightnessTask?.cancel()
                        brightnessTask = Task {
                            try? await Task.sleep(nanoseconds: 250_000_000)   // 防抖，避免拖动时刷指令
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
        }
    }

    // MARK: - 发送图纸

    private var sendSection: some View {
        Section("发送图纸") {
            if board.isSending {
                VStack(alignment: .leading, spacing: 6) {
                    Text("正在发送… \(Int(board.sendProgress * 100))%")
                        .font(.subheadline)
                    ProgressView(value: board.sendProgress)
                }
            } else {
                Button {
                    showPatternPicker = true
                } label: {
                    Label("发送图纸到拼豆板", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(!didHandshake)
            }
        } footer: {
            Text("发送完整预览图；已拼的格子会以暗色显示（需要在作品详情里打卡进度）。")
        }
    }

    // MARK: - 调试

    private var debugSection: some View {
        Section("调试") {
            NavigationLink {
                BoardLogView()
            } label: {
                Label("蓝牙日志控制台", systemImage: "terminal")
            }
            LabeledContent("最近日志", value: central.logLines.last?.suffix(60) ?? "暂无")
                .font(.caption.monospaced())
                .lineLimit(1)
        }
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
