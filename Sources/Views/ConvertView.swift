import PhotosUI
import SwiftData
import SwiftUI

struct ConvertView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    enum Field { case width, height }
    @FocusState private var focusedField: Field?

    @State private var pickedItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var gridWidth = 22
    @State private var gridHeight = 22
    @State private var colorLimit = 24
    @State private var whiteToEmpty = true
    @State private var converting = false
    @State private var result: PixelConverter.Result?
    @State private var name = ""
    @State private var savedID: UUID?
    @State private var isSendingToBoard = false
    @State private var boardSendMessage: String?

    var body: some View {
        Form {
            Section("选择照片") {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label(image == nil ? "从相册选择" : "重新选择", systemImage: "photo.on.rectangle.angled")
                }
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            if image != nil {
                Section("转换参数") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("宽")
                            TextField("8 - 104", value: $gridWidth, format: .number)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .width)
                                .multilineTextAlignment(.trailing)
                            Text("格")
                        }
                        HStack {
                            Text("高")
                            TextField("8 - 104", value: $gridHeight, format: .number)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .height)
                                .multilineTextAlignment(.trailing)
                            Text("格")
                        }
                        Text("图纸像素宽高，范围 8 - 104 格")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Picker("总色数", selection: $colorLimit) {
                        Text("295 色").tag(0)
                        Text("291 色").tag(291)
                        Text("221 色").tag(221)
                        Text("144 色").tag(144)
                        Text("96 色").tag(96)
                        Text("48 色").tag(48)
                        Text("24 色").tag(24)
                        Text("16 色").tag(16)
                    }
                    Toggle("白底转空格", isOn: $whiteToEmpty)
                        .help("适合 logo、线稿等白底图")
                    Button {
                        convert()
                    } label: {
                        if converting {
                            HStack { ProgressView().controlSize(.small); Text("转换中…") }
                        } else {
                            Label("开始转换", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(converting)
                }

                if let result {
                    Section("预览") {
                        GridView(cells: result.cells, width: result.width, height: result.height)
                            .frame(maxHeight: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        LabeledContent("图纸尺寸", value: "\(result.width) × \(result.height)")
                        LabeledContent("使用颜色", value: "\(beadCounts.count) 种")
                        LabeledContent("豆子总数", value: "\(result.cells.filter { $0 > 0 }.count) 颗")
                    }

                    Section("发送到拼豆板") {
                        Button {
                            sendToBoard()
                        } label: {
                            if isSendingToBoard {
                                HStack { ProgressView().controlSize(.small); Text("发送中…") }
                            } else {
                                Label("发送到拼豆板", systemImage: "paperplane.fill")
                            }
                        }
                        .disabled(isSendingToBoard || !AppState.shared.board.isConnected)
                        if !AppState.shared.board.isConnected {
                            Text("未连接拼豆板，请先到「拼豆板」页连接")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("保存") {
                        TextField("图纸名称", text: $name)
                        Button {
                            save()
                        } label: {
                            Label("保存图纸", systemImage: "square.and.arrow.down")
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
        .navigationTitle("照片转图纸")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            result = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    image = ui
                    name = name.isEmpty ? "照片图纸 \(Date().formatted(.dateTime.month().day()))" : name
                }
            }
        }
        .alert("已保存", isPresented: Binding(get: { savedID != nil }, set: { if !$0 { savedID = nil } })) {
            Button("好", role: .cancel) { savedID = nil }
        } message: {
            Text("图纸已保存，可在「图纸」标签中查看")
        }
        .alert("发送到拼豆板", isPresented: Binding(get: { boardSendMessage != nil },
                                                 set: { if !$0 { boardSendMessage = nil } })) {
            Button("好", role: .cancel) { boardSendMessage = nil }
        } message: {
            Text(boardSendMessage ?? "")
        }
    }

    private var beadCounts: [Int: Int] {
        var d: [Int: Int] = [:]
        for c in result?.cells ?? [] where c > 0 { d[c, default: 0] += 1 }
        return d
    }

    private func convert() {
        guard let image else { return }
        converting = true
        var opts = PixelConverter.Options()
        opts.gridWidth = max(8, min(104, gridWidth))
        opts.gridHeight = max(8, min(104, gridHeight))
        opts.colorLimit = colorLimit
        opts.whiteToEmpty = whiteToEmpty
        let img = image
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                PixelConverter.convert(image: img, options: opts)
            }.value
            await MainActor.run {
                result = r
                converting = false
            }
        }
    }

    private func save() {
        guard let result, result.width > 0 else { return }
        let p = Pattern(name: name, width: result.width, height: result.height,
                        cells: result.cells, source: "photo")
        context.insert(p)
        savedID = p.id
    }

    private func sendToBoard() {
        guard let result, result.width > 0 else { return }
        let board = AppState.shared.board
        guard board.isConnected else {
            boardSendMessage = "未连接拼豆板，请先到「拼豆板」页连接"
            return
        }
        isSendingToBoard = true
        Task {
            defer { isSendingToBoard = false }
            do {
                try await board.handshake()
                let rgb = BoardImageBuilder.fullImage(width: result.width, height: result.height,
                                                      cells: result.cells, placed: nil)
                try await board.sendImage(width: result.width, height: result.height, rgb: rgb)
                boardSendMessage = "图纸已发送到拼豆板"
            } catch {
                boardSendMessage = "发送失败：\(error.localizedDescription)"
            }
        }
    }
}
