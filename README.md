# 豆拼 DouPin — 智能拼豆 iOS App

面向 Wofan / PIXDOU 类智能拼豆灯板的 iOS 原生应用（SwiftUI + SwiftData，iOS 17+，无会员系统）。

## 功能总览

| 模块 | 说明 |
| --- | --- |
| 照片转图纸 | 相册选图 → 像素化 → 匹配 Mard 通用色号（295 色），可限色（64/48/32/24/16）、白底转空格、豆量统计 |
| 手绘编辑器 | 画笔 / 橡皮 / 吸管 / 油漆桶，左右镜像、10 格辅助线、色号高亮、40 步撤销，底栏常备 48 色常用色 + 全色板搜索 |
| 模板库 | 15 个原创像素模板（经典 / 表情 / 动物 / 食物 / 自然 / 配饰 / 符号 / 节日），预览用色清单，一键开始拼 |
| 图纸库 | 全部图纸管理：搜索、状态筛选（待拼 / 拼制中 / 已完成）、删除、进度百分比 |
| 作品详情 | 图纸查看 + 编辑 + 导出图片（网格 / 色号标注 / 图例）+ 复制豆子清单 |
| 色号统计 | 作品详情「统计」页：全色号用量表（含可可/漫漫/盼盼/米小窝对照色号）、占比、结合豆仓的缺货状态，一键复制豆子清单 / 补货清单 |
| 完整进度打卡 | ① 逐行打卡（拼完一行点一下，可撤销）② 逐格打卡（点格子标记已拼）③ 分色打卡（整色一次标记）④ 成品照片存档；进度持久化，断点续拼 |
| 智能拼豆板（BLE） | 扫描 / 连接 Wofan 拼豆板（A950 首选，AE00 自动回退，双协议），自动握手；发完整预览图（已拼格暗显）；**行引导**：点亮当前行 + 相邻行微亮，可按颜色过滤；**逐色引导**（PIXDOU 同款）：滑条逐色前进，板子只亮当前色未拼的格子，「本色拼完 → 下一色」自动打卡并前进 |
| 豆仓库存 | 独立标签页：手动入库（295 色可搜索）、按图纸入库（补足到需求量）、按图纸扣减（拼完出库）、生成补货清单（缺多少列多少，可复制发店家）、单色数量精确调整 |
| 灯板控制 | 亮度 10–100%（防抖下发）、显示开 / 关 |
| 调试控制台 | BLE 日志（服务 / 特征 / 应答帧全记录）+ 十六进制手动发指令（A951 / A952） |

## 目录结构

```
DouPin/
├── README.md
├── .gitignore
├── .github/workflows/build-ios.yml   # GitHub Actions 云构建（Windows 用户走这条路）
├── DouPin.xcodeproj/                 # 完整 Xcode 工程（Mac 上直接打开）
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/DouPin.xcscheme
└── Sources/
    ├── App/       # 入口、AppState（全局共享 BoardSession）、TabView、首页
    ├── Core/      # Pattern 模型、295 色板、像素转换、图纸渲染、模板库
    ├── BLE/       # A950 协议帧、CoreBluetooth、拼豆板会话（握手/发图/行引导）
    └── Views/     # 转换、编辑器、图纸库、模板库、拼豆板、作品详情
```

## 构建路径 A：有 Mac

双击 `DouPin.xcodeproj` 打开 → 选自己的 Team（Signing & Capabilities）→ 真机 Cmd+R 运行。工程已含全部配置（含蓝牙权限），无需任何手动步骤。

## 构建路径 B：纯 Windows（GitHub 云构建 + Sideloadly 安装）

Windows 无法本地编译 iOS 应用（苹果限制），但可以用 GitHub 免费的云端 Mac 服务器编译，再用 Sideloadly 签名装进 iPhone，全程不需要 Mac。

### 第 1 步：推送到 GitHub

1. 注册 / 登录 GitHub（github.com，免费）
2. 新建仓库（New repository），名字如 `DouPin`
   - **Public**（公开）：macOS 云构建时长**免费不限量**（推荐，代码本身无敏感内容）
   - Private（私有）：免费账号每月约 2000 分钟（macOS 按 10 倍计），约合 20 次构建，也够用
3. 把整个 `DouPin` 文件夹推上去（用 GitHub Desktop 拖入即可，或命令行 git push）

推送完成后 GitHub 会自动跑 Actions 云构建（`.github/workflows/build-ios.yml`）：在云端 Mac 上编译并打出**未签名 IPA**。

### 第 2 步：下载 IPA

仓库页面 → Actions 标签 → 点最新一次运行 → 页面底部 Artifacts 下载 `DouPin-unsigned-ipa`（解压得到 `DouPin-unsigned.ipa`）。

### 第 3 步：Sideloadly 签名安装到 iPhone

1. 电脑安装 **Sideloadly**（sideloadly.io，免费）
2. 安装 **iTunes**：必须从苹果官网下载 Windows 版（apple.com/itunes），**不能**用微软商店版（缺驱动）
3. iPhone 用数据线连电脑，手机上点「信任」
4. 打开 Sideloadly：拖入 `DouPin-unsigned.ipa` → 填你的 Apple ID 和密码
   - 开了两步验证的话，去 appleid.apple.com → 登录与安全 → App 专用密码，生成一个专用密码填进去
5. 点 Start，等它签名安装完成
6. iPhone 上：设置 → 通用 → VPN与设备管理 → 点你的 Apple ID → **信任**
7. 如果桌面上 App 打不开提示需开发者模式：设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启

### 免费账号的限制（必读）

| 项目 | 免费 Apple ID | 付费开发者账号（¥688/年） |
| --- | --- | --- |
| App 有效期 | **7 天**，到期后连电脑重新点一次 Start 续期 | 1 年 |
| 同时安装 App 数 | 最多 3 个 | 不限 |
| 试用建议 | 先用免费账号验证蓝牙能不能连上板子 | 长期用再买 |

日常使用提示：图纸和进度都存在手机里，重新签名安装**不会**丢数据；只有 7 天内必须连一次电脑续期这一点比较麻烦。

## BLE 协议速查（逆向自 PIXDOU / iLEDColor，JieLi 方案）

- 服务 `0xA950`：
  - `A951` 写指令（write-without-response）
  - `A952` 写数据分块（write-without-response）
  - `A953` 通知（板子应答）
- 帧格式：`[0x54][cmd 1B][length 2B BE][fields…][checksum 2B BE]`
  - `length` = fields + checksum 的字节数
  - `checksum` = 前面所有字节的 u16 累加和（大端）
- 指令：`0x0D Connect`、`0x0F TestPass`（全零 = 无密码）、`0x06 StartStream`（含 CtnData 的 CRC32C 与总长）、`0x00 Continue`（A952 分块，seq + len + data）、`0x01 EndStream`、`0x09 Dimming`（0 最亮 ~ 10 最暗）、`0x0A DisplayEnable`
- 图像载荷 = 11×u16 元数据 + RGB 像素（行优先），再包 CtnData（CRC32C + 0x01 + 19 个 0x00 + payload），按 MTU 分块发送
- 发图步骤：Connect → TestPass → StartStream（等应答）→ N×Continue → EndStream
- 分块大小自动按 `maximumWriteValueLength` 适配（≤492 字节/块），每包间隔 10ms

## 调试控制台使用

「拼豆板」标签 → 底部「调试」区 → 「蓝牙日志控制台」：

- 上半部分是实时日志：蓝牙状态、扫描到的设备、服务/特征发现、每条应答帧（`← 通知 cmd=0x0d …`）
- 下半部分可手动粘贴十六进制指令发送。常用（已含校验，直接粘贴）：
  - 握手 Connect：`54 0d 00 03 00 00 64`
  - 校验密码 TestPass：`54 0f 00 08 00 00 00 00 00 00 00 6b`
  - 亮度 5 级：`54 09 00 0b 05 00 00 00 00 00 00 00 00 00 6d`
  - 开屏：`54 0a 00 0b 01 00 00 00 00 00 00 00 00 00 70`

排查建议：连接后如果一直「正在握手」，先看日志里 Connect 是否有应答；没有应答说明设备不是 A950 系（先用官方 app 确认板子型号）。

## 修改代码后重新构建

改了 Swift 代码 → git push → Actions 自动重新构建 → 下载新 IPA → Sideloadly 重新装一次即可。

## 已知限制

- 协议为逆向所得，非官方文档；不同批次固件可能有差异（日志控制台就是为此准备）。
- 板子若设置了连接密码，本 app 暂不支持改密 / 解密，需要先用官方 app 清除密码。
- GIF 动图发送（协议支持）未做 UI，后续可加。
- 模拟器和 Mac 无法测试蓝牙，BLE 相关功能必须真机。
