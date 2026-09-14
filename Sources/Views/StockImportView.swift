import SwiftData
import SwiftUI

/// 批量导入 Sheet（PRD §5.1）
///
/// 流程：粘贴多行文本 → 实时解析预览（成功 ✓ / 失败高亮标红 + 行号）
///      → 冲突处理（累加 / 覆盖 / 跳过，全局分段控件）→ 确认导入 → 结果统计。
@MainActor
struct StockImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BeadStock.colorId) private var stocks: [BeadStock]

    /// 导入完成回调（用于外层 toast）
    var onFinished: (String) -> Void = { _ in }

    /// 目标豆仓（"" = 默认仓）；查重与写入均限定在该仓内
    var binName: String = ""

    /// 冲突处理策略
    enum ConflictPolicy: String, CaseIterable {
        case add = "累加"
        case overwrite = "覆盖"
        case skip = "跳过"
    }

    @State private var text = ""
    @State private var policy: ConflictPolicy = .add
    /// 导入结果统计
    @State private var resultSummary: ImportSummary?

    /// 导入结果统计
    struct ImportSummary {
        let inserted: Int
        let updated: Int
        let skipped: Int
        let failed: Int
    }

    /// 实时解析结果
    private var parseResult: StockTextParser.ParseResult {
        StockTextParser.parse(text)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("粘贴文本") {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .font(.body.monospaced())
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("每行：色号 数量\n例如：\nA1 500\nA2,300\nH7\t120")
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button {
                        if let clip = UIPasteboard.general.string { text = clip }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                }

                conflictSection

                previewSection

                Section {
                    LabeledContent("归入豆仓", value: BeadBinCatalog.displayName(binName))
                        .font(.subheadline)
                } footer: {
                    Text("查重与写入都在该豆仓内进行；同色号在其他仓的记录不受影响。")
                }

                if let summary = resultSummary {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("导入完成", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("新增 \(summary.inserted) 条 · 更新 \(summary.updated) 条 · 跳过 \(summary.skipped) 条 · 失败 \(summary.failed) 行")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("批量导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确认导入") { performImport() }
                        .disabled(parseResult.ok.isEmpty)
                }
            }
        }
    }

    // MARK: - 冲突处理

    private var conflictSection: some View {
        Section {
            Picker("冲突时", selection: $policy) {
                ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("冲突处理")
        } footer: {
            Text("当导入的色号已有库存时：累加 = 原数量 + 导入数量；覆盖 = 直接改为导入数量；跳过 = 保留原库存。")
        }
    }

    // MARK: - 预览

    private var previewSection: some View {
        Section {
            let result = parseResult
            if result.ok.isEmpty && result.failed.isEmpty {
                Text("粘贴文本后将在此处显示解析预览")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // 成功项
                ForEach(result.ok) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(BeadPalette.byId[item.colorId]?.color ?? .clear)
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.gray.opacity(0.3)))
                        Text(item.mard).font(.subheadline.monospaced().weight(.medium))
                        Spacer()
                        Text("→ \(item.quantity)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if existing(item.colorId) != nil {
                            Text("已存在")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }
                // 失败行（高亮标红 + 行号）
                ForEach(result.failed) { f in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("第 \(f.line) 行：\(f.text)")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.red)
                            Text(f.reason)
                                .font(.caption2)
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.red.opacity(0.08))
                }
            }
        } header: {
            HStack {
                Text("解析预览")
                Spacer()
                let r = parseResult
                if !r.ok.isEmpty || !r.failed.isEmpty {
                    Text("成功 \(r.okCount) · 失败 \(r.failedCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 查表

    private func existing(_ colorId: Int) -> BeadStock? {
        stocks.first { $0.colorId == colorId && $0.binName == binName }
    }

    // MARK: - 导入

    /// 批量 upsert：按 colorId 在当前仓内查改 / 插入
    private func performImport() {
        let result = parseResult
        var inserted = 0
        var updated = 0
        var skipped = 0

        // 同一色号在文本中多次出现时，按顺序合并到同一条目（限定当前仓）
        var index: [Int: BeadStock] = [:]
        for s in stocks where s.colorId > 0 && s.binName == binName { index[s.colorId] = s }

        for item in result.ok {
            if let stock = index[item.colorId] {
                switch policy {
                case .add:
                    stock.addQuantity(item.quantity)
                    updated += 1
                case .overwrite:
                    stock.setQuantity(item.quantity)
                    updated += 1
                case .skip:
                    skipped += 1
                }
            } else {
                let newStock = BeadStock(colorId: item.colorId, quantity: item.quantity, binName: binName)
                context.insert(newStock)
                index[item.colorId] = newStock
                inserted += 1
            }
        }

        try? context.save()

        let summary = ImportSummary(inserted: inserted,
                                    updated: updated,
                                    skipped: skipped,
                                    failed: result.failedCount)
        resultSummary = summary
        onFinished("导入完成：新增 \(inserted) / 更新 \(updated) / 跳过 \(skipped) / 失败 \(result.failedCount)")
    }
}
