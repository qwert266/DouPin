## T05 QA 验证报告

验证者：严过关（QA Engineer） · 方式：静态验证 + 源码级审查 + PowerShell/node 脚本取数（Windows 无 Xcode，无法真编译/跑 XCTest）
取数环境：PowerShell（Bash shim 损坏，全程改用 PowerShell 工具 + 文件回读）

### 验证结果总览
| 项 | 结果 | 证据 |
| --- | --- | --- |
| V1 工程完整性 | PASS | F-unique=34、B-unique=34、SourcesBuildPhase(A…006).files=34、磁盘 Sources/*.swift=34；交叉核对 0 孤儿 |
| V2 5-Tab 结构与可达性 | PASS | AppRoot TabView 恰好 5 项且指向 HomeView/PatternsTabView/InventoryView/BoardTabView/MoreView；MorePlaceholderView 定义0/实例0（仅1处注释）；符号闭环无悬空引用 |
| V3 BLE 修复 | PASS | P0-2/P0-5/P1-3/P1-4/P2 全部落实；waiter 无泄漏、无双重 resume；drain 重入安全 |
| V4 模板库 | PASS | 模板 61、套装 10、行长违规 0、未知字符 0、重名 0；TemplateGalleryView 无自带 NavigationStack |
| V5 全局卫生 | PASS(with P2) | try!=0、fatalError 仅 1 处（App 启动 DB 初始化）；无空文件；遗留 6 个 QA 临时文件（P2） |
| V6 端到端可达性 | PASS | 首页 3 入口 / 图纸 4 分段 / 库存 3 视图 / 作品详情 5 菜单目标全部存在且签名匹配 |

---

### V1 工程完整性（pbxproj 数量守恒）
- `PBXFileReference`（`F\d{23}` 独立定义 key）唯一数 = **34**
- `PBXBuildFile`（`B\d{23}` 独立定义 key）唯一数 = **34**
- `PBXSourcesBuildPhase`（`A00000000000000000000006`）的 `files` 数组元素数 = **34**
- 磁盘 `Sources/**/*.swift` 实际文件数 = **34**
- 三者相等 ✓（注：pbxproj 为 XML-plist 格式，用 `<key>F…</key>` / `<string>B…</string>` 解析，避开了 `fileRef` 引用）
- 交叉核对（脚本）：
  - 每个 `F*` ↔ 每个 `B*` 一一对应（B.fileRef → 存在的 F），**0 个有 F 无 B**
  - 每个 `B*` 均在 SourcesBuildPhase.files 内，**0 个有 B 不在 files**
  - 每个磁盘 `.swift` 均在 pbxproj 有 F 引用（名称集合 Compare-Object 差异为 0），**0 个有文件无 F**
  - 结论：无孤儿。

### V2 5-Tab 结构与可达性
- `AppRoot.swift:11-22`：`TabView` 恰好 **5** 项，顺序 `HomeView / PatternsTabView / InventoryView / BoardTabView / MoreView` ✓
- `MorePlaceholderView`：全项目 `struct MorePlaceholderView` = 0、`MorePlaceholderView(` = 0，仅 `MoreView.swift:6` 一处注释提及 ✓
- 5 个 View 类型均有定义：`MoreView`(MoreView.swift:17)、`InventoryView`(InventoryView.swift:15)、`PatternsTabView`(PatternsTabView.swift:12)、`BoardTabView`(BoardTabView.swift:6)、`HomeView`(AppRoot.swift:27) ✓
- 跨文件符号闭环（脚本：提取全项目 64 个自定义类型定义 vs 147 个被实例化的首字母大写 token）：**未发现引用不存在的自定义 View**。被标记的“未知 token”经人工归类，全部为 SwiftUI/Foundation 标准类型（AppStorage/GridItem/DragGesture/TextField/UIColor/URLSession/UInt8… 等）或注释命中（`O(1)`/`O(n)`、`TODO`），非悬空引用。
  - 显式核对：MoreView → `BoardLogView()`(MoreView.swift:201，定义 BoardTabView.swift:316) ✓；AppRoot → `ConvertView()`(44)/`EditorView(...)`(47)/`TemplateGalleryView()`(50)/`WorkDetailView(...)`(58)/`PatternRow(...)`(59) 均有定义 ✓；WorkDetailView → `StockEstimateView(...)`(76) ✓

### V3 BLE 修复验证

**BLECentral.swift**
- **P0-2** ✓：`private struct NotifyWaiter { let id: UUID; let cont: CheckedContinuation<[UInt8]?, Never> }`（行 50-53）；`nextNotificationWithTimeout` 返回 `[UInt8]?`（163）；用 `firstIndex(where: { $0.id == id })`（171）精确移除后 `resume(returning: nil)`（173）；`deliverNotification` 为 `notifyWaiters.removeFirst().cont.resume(returning: bytes)`（181）。
  - `takeNotification()` = **0**（无）
  - `group.cancelAll()` / `withTaskGroup` = 代码中 **0**（各仅 1 处存在于 P0-2 说明注释 159 行）
- **P1-4** ✓：`? [] : []` 死代码已删（215 行简化为仅取 `ServiceUUIDs`；代码中该模式 0 处，仅 214 行注释说明）
- **P2** ✓：`private static let timeFormatter`（62）静态复用；`log` 用 `Self.timeFormatter`（77）；`private static let boardNameHints`（59）
- **边界审查（drain）** ✓：`drainNotifications()`（192-197）先 `let pending = notifyWaiters` 拷贝 → `notifyWaiters.removeAll()` → 再 `for w in pending { w.cont.resume(returning: nil) }`。拷贝-清空-逐个 resume，重入安全。
- **双重 resume 分析（重点结论）**：**不存在双重 resume 风险**。理由：
  1. 整个 `BLECentral` 为 `@MainActor`，`notifyWaiters` 的所有读写（等待者超时 Task、`deliverNotification`、`drainNotifications`）均在 MainActor 串行执行，临界区内无交错。
  2. `deliverNotification` 先 `removeFirst()` 移出数组再 resume；超时 Task 先 `firstIndex(where:)` 命中才移出并 resume——**等待者一旦被移出数组即不再被 resume**。
  3. 谁先跑谁生效：若超时先跑→该 waiter 移出并 resume(nil)，后续 deliver 取走“另一个”waiter；若 deliver 先跑→该 waiter 被移出，超时 Task 的 `firstIndex` 返回 nil，**跳过 resume**。归功于超时路径“存在性检查”这一不变量。
- **并发重入风险（重点结论）**：**不存在**。`nextNotificationWithTimeout` 内 `if !notifyBuffer.isEmpty { return notifyBuffer.removeFirst() }`（164）到 `await withCheckedContinuation`（166）之间为同步执行；全部 `nonisolated` 回调（203/211/234/243/250/263/273/294）均通过 `Task { @MainActor in … }` 跳回主 actor，无任何绕过 actor 直接触碰 `notifyBuffer`/`notifyWaiters` 的路径。因此两步之间不会被其它 MainActor 任务插入。

**BoardSession.swift**
- **P0-5** ✓：`startStream(crc32: BLEProtocol.crc32c(payload), totalLength: ctn.count)`（69）传的是 **payload 层**校验（非 `crc32c(ctn)`）；含“实机复核点”字样注释（64-68）。与 `BLEProtocol.ctnData` 包头写入的 `crc32c(payload)`（BLEProtocol.swift:168）自洽（方案 A）。
- `syncDisplayState(on:brightnessPercent:)` 新增（116-120），`guard central.linkState == .connected else { return }`——仅连接态下发 `setDisplay`+`setBrightness` ✓
- **逻辑审查**：`sendImage` 分块循环 `_ = await central.nextNotificationWithTimeout(0.3)`（81）超时不中断。结合新 waiter 实现：每轮超时 Task 会按 id 命中并移除自己的 waiter 再 resume(nil)（BLECentral 171-173），故**每轮循环结束不残留 waiter**，即 P0-2 修复的核心收益成立 ✓

**BoardTabView.swift**
- **P1-3** ✓：`onChange(of: central.linkState)` 中握手成功后 `await board.syncDisplayState(on: displayOn, brightnessPercent: brightness)`（44-48）
- Toggle（250-256）与 Slider（234-247）均 `.disabled(central.linkState != .connected)` ✓

### V4 模板库验证（脚本 Templates.swift）
- 模板总数 = **61** ✓
- 套装（category）数 = **10** ✓（像素小动物8 / 表情包6 / 自然风景6 / 节日7 / 食物甜点8 / 植物花语5 / 太空星球5 / 日常物件8 / 字母数字4 / 爱心系4）
- 行长不严格相等的模板数 = **0** ✓
- 非 `.` 字符不在 charMap 键集合内 = **0**（charMap 24 键：W K G L R D P H Y A O S B g l d c b n V v M C m）✓
- 重复模板名 = **0**（去重后 61 = 原始 61）✓
- `TemplateGalleryView.swift`：外层为 `ScrollView`+`LazyVStack`，仅 `.navigationTitle`，**无自带 `NavigationStack`** ✓（嵌入 PatternsTabView 栈）

### V5 全局卫生
- 全 `Sources/` `try!` 出现次数 = **0** ✓（`try?` = 32 处，属正常）
- `fatalError` = **1** 处：`DouPinApp.swift:18`，位于 `DouPinApp.init()` 的 `ModelContainer` 初始化 `catch` 分支——App 启动数据库初始化失败即无法运行，属唯一合理用法 ✓
- `precondition`/`assert`/`assertionFailure` = **0**
- 数据层三文件未在 T05 改动：`Models.swift`/`Models+Extensions.swift`/`Models+Inventory.swift` 的 mtime = **2026-09-13 19:48:20~38**，早于全部 T05 文件（MoreView 20:03、AppRoot 20:04、BLECentral 20:04、BLEProtocol 20:04、BoardSession 20:04、BoardTabView 20:04、TemplateGalleryView 20:06、Templates 20:09）；内容为文件夹/库存/拆板/板尺寸等 T02/T04 功能，无 T05 特征。**判定：T05 未改动数据层** ✓
  - ⚠ 数值偏差备注（见“发现的问题”P2-1）：任务书给出的基线行数（166/136/195）与磁盘实测（206/187/265）不符；因无 .git 无法 diff，仅按 mtime + 内容特征判断为“非 T05 改动”，非代码缺陷。
- 空/近空 `.swift` 文件 = **0**；未使用 import：启发式仅命中 `ColorMerge.swift` 的 `import Foundation`，经人工确认为**误报**（使用 `Set`/`Dictionary` 等，Foundation 属正常）。
- 遗留脚本产物：仓库根存在 6 个 QA 临时文件（见 P2-2）。

### V6 端到端可达性（静态推演）
- 首页「快速开始」3 入口：照片转图纸→`ConvertView`(AppRoot.swift:44)、新建手绘画布→`EditorView(pattern: nil, initialSize: 29)`(47)、从模板开始→`TemplateGalleryView`(50)，均存在；`EditorView.init(pattern:initialSize:)` 签名匹配（EditorView.swift:31）✓
- 图纸 Tab 4 分段（PatternsTabView.swift:28-33）：全部→`AllPatternsSection`(99)、文件夹→`FolderListView`(FolderViews.swift:11)、标签→`TagFilterView`(FolderViews.swift:277)、模板→`TemplateGalleryView`(6)，均存在 ✓
- 库存 Tab：`StockImportView`(StockImportView.swift:9)、`StockQuickAddView`(InventoryView.swift:297)、`StockQuantityEditSheet`(InventoryView.swift:400)，三者在 InventoryView 内以 sheet 展示（88-96）✓
- 作品详情菜单（WorkDetailView.swift）：消耗预估→`StockEstimateView`(76)、拆板→`SplitBoardView`(81)、导出PDF→`exportPDF()`(90，内部 `PDFExporter.exportToTempFile`)、移动到文件夹→`MoveFolderSheet`(147，定义 677)、编辑标签→`TagEditorSheet`(150，定义 737)，目标均存在 ✓
- 依赖方法均存在：`assignFolder`/`addTag`/`removeTag`/`isTile`(Models+Extensions) 、`isLow`/`displayName`/`setQuantity`/`addQuantity`(Models+Inventory)、`XiaohongshuImportView`(FolderViews.swift:383) ✓

---

### 发现的问题
| 级别 | 文件 | 行号 | 现象 | 建议修复 |
| --- | --- | --- | --- | --- |
| P2 | `README.md` | 11 | 写“**15 个**原创像素模板”，实际 Templates.swift 已有 **61** 个（T05 扩充后未同步） | 更新为“61 个原创像素模板”，并同步套装/分类描述 |
| P2 | 仓库根 | — | 遗留 6 个 QA 临时文件：`_check.ps1`、`_check_out.txt`、`_pbxcheck.txt`~`_pbxcheck4.txt`（含中间结果 F=29 等） | 删除；确认未纳入 pbxproj（已确认不在工程目标内，无构建影响） |
| P2（备注/非缺陷） | `Sources/Core/Models.swift`、`Models+Extensions.swift`、`Models+Inventory.swift` | — | 实测行数 206/187/265，与任务书基线 166/136/195 不符 | 不阻塞：mtime 早于全部 T05 文件、内容无 T05 特征，判定为 T04 及更早产物；如任务书基线为准需产品/架构侧澄清 |

无 P0 / P1 级源码缺陷。

### 智能路由判定
- 未发现**源码 Bug**（P0/P1 级）。
- 未发现**测试/验证脚本自身的错误性结论**（个别正则误报——`StockImportView`/`StockQuickAddView` 因尾随闭包、`ColorMerge` import、`O(1)` 注释——均已在分析与报告中纠正，未影响结论）。
- 仅 3 条 P2 级“卫生/文档漂移”项，均为非阻塞性。
- **判定：NoOne**（关键项全部通过；P2 项列为遗留清单，交由主理人决定是否在收尾清理 / 由 Alex 顺手改 README）。

### 结论
**PASS**。T05 关键验收项（工程 34 文件守恒、5-Tab 可达、BLE P0-2/P0-5/P1-3/P1-4/P2 修复与双 resume 安全性、模板 61/10/0/0、卫生 try!=0 与单点 fatalError、端到端可达）全部通过。

遗留问题清单（均 P2，非阻塞）：
1. `README.md:11` 模板数量文案 15→61 未同步。
2. 仓库根 6 个 QA 临时文件待清理。
3. 数据层三文件行数与任务书基线不符（经 mtime/内容判定非 T05 改动，建议澄清基线口径）。

QA_ROUTE: NoOne
