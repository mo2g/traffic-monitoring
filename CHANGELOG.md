# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/);
this project uses [Semantic Versioning](https://semver.org/).

## [0.6.0] — 2026-09-07

### Added

- **中英双语界面**。跟随系统语言，也可在「设置 › 通用 › 界面语言」里指定，
  切换后立即生效（App 层用 `.id(language)` 强制重建视图树）。
  共 132 条字符串，两种语言键集完全对齐。

  三个实测坑，都写进了代码注释：
  - SwiftPM 可执行目标的资源会被打进独立的
    `TrafficMonitor_TrafficMonitor.bundle`，而 SwiftUI 的
    `Text(LocalizedStringKey)` 默认查 `Bundle.main` —— 在这里永远查不到。
    因此走自建的 `L()` 查表。
  - 资源必须用 `.copy` 而非 `.process` 声明：`.process` 会把 `zh-Hans.lproj`
    **小写**成 `zh-hans.lproj`，之后 `Bundle.preferredLocalizations` 再也匹配不上，
    永远回落英文。
  - 语言匹配也自己做，不依赖 `preferredLocalizations`。
- `make-app.sh` 把本地化资源包复制进 `Contents/Resources/` 并声明
  `CFBundleLocalizations`。
  资源包**不能**放 `Contents/MacOS/` —— codesign 会把它当作未签名的嵌套代码，
  导致整个 .app 签名失败（`code object is not signed at all / In subcomponent: …`）。
  这个错误此前被脚本里的 `2>/dev/null` 吞掉，签名失败时只表现为静默退出；
  该重定向已移除。
- README 补上英文界面截图。

### Changed

- **菜单栏速率改为上行在上、下行在下**，与箭头方向直觉一致。
- 日志改为英文输出（诊断信息惯例），界面文案全部走本地化。
- `TimeRange` 与 `ChartStyle` 的 `rawValue` 改为语言无关的 ASCII 标识
  （`today`/`week`/`month`、`line`/`area`/`bar`），避免持久化内容依赖界面语言。
- `GroupRow` 新增 `isOthers` 字段。此前靠 `name == "其他"` 判断兜底分组，
  本地化之后这种比较必然失效。

### Tests

129 个（+11）。新增的字符串表校验会卡住三类问题：两种语言键集不一致、
占位符数量不匹配、源码里 `L("…")` 用到了表中不存在的键。
这三条都用注入缺陷的方式验证过确实会失败。

## [0.5.1] — 2026-09-07

### Fixed

- **打包成 .app 后界面无响应**：`MenuBarExtra(isInserted:)` 每次场景更新都会把
  当前值回写进绑定，而 `@Observable` 的合成 setter 即使值没变也调用
  `withMutation`，于是 `App.body` 求值 → 回写 → 失效 → 再求值形成死循环。
  打包后每轮还多一次 `SMAppService` 的阻塞 XPC（`SettingsView` 的 `@State`
  初值表达式），主线程被彻底打满。修复后主线程 452/457 个采样空转。
- **面积图与折线对不上**：`AreaMark` 默认按分组**堆叠**而 `LineMark` 不堆叠，
  红色面积顶边远高于红色线。改用 `stacking: .unstacked`。
- **图表样式用中文显示名做持久化值**：`"detail.style" = "面积"` 直接写进
  UserDefaults，既让存储依赖界面语言，初始选中项也对不上。
  `rawValue` 改为稳定的 `line` / `area` / `bar`，展示文案走独立的 `label`。
- **默认窗口宽度放不下六列**，「合计」列被挤出可视区并出现横向滚动条。

### Added

- README 补上主窗口与时间线截图。

## [0.5.0] — 2026-09-07

补齐此前列在 Roadmap 里的功能，并接上自动发布。

### Added

- **菜单栏模式**：常驻显示上下行速率，点开是一个面板（总速率、最活跃的 6 个
  进程、启停采集、打开主窗口、退出）。设置里可关，默认开启。
  标签宽度必须恒定 —— 每秒刷新一次，宽度一变 NSStatusItem 就要在布局过程中
  重新测量，既让菜单栏抖动也会触发 AppKit 布局递归警告。
- **「今日 / 本周 / 本月」真正生效**：改用日历边界（今天零点、本周一、本月一号）
  而非「往前推 N 秒」，切换时重查数据库并替换管线里的历史部分。
- **「排除进程」输入框接线**：按进程名或本地化显示名精确匹配，改设置立即生效，
  已累计的数据一并清出。
- **开机自启动**（`SMAppService`）：不可用时（裸二进制运行）禁用开关并说明原因；
  被系统设置阻止时给出直达「登录项」的链接。
- **行内速率趋势图**，默认关闭。用 `Canvas` 手绘而非 Swift Charts。
- **自动发布**：推送 `v*` tag 触发 GitHub Actions 构建 `.dmg` 并发布到 Releases，
  发布说明取自 CHANGELOG 对应小节，附 SHA-256 校验和。
  发布前校验 tag 与 `Constants.appVersion` 一致。

### Fixed

- `.searchable(placement: .toolbar)` 触发的 AppKit 布局递归警告。用 lldb 断在
  `_NSDetectedLayoutRecursion` 定位到 `NSSearchToolbarItemView.updateConstraints`
  内部又去调 `layoutSubtreeIfNeeded`，改为在工具栏里自己拼 TextField。

### Performance

窗口在后台、45 秒采样：

| 配置 | CPU |
|---|---|
| 基线 | 1.0% |
| 开启菜单栏（默认） | 1.3–1.4% |
| 再开启行内趋势图 | 1.6% |

菜单栏开启时 UI 可见性闸门必须一直放行，否则主窗口被遮挡后数字会冻住 ——
这就是它带来 0.3 个百分点的原因。

## [0.4.0] — 2026-09-07

体验向的一轮迭代：图表、图标、分发格式。

### Added

- **真实应用图标**：表格与详情窗显示进程自身的图标，与活动监视器一致。
  身份解析时只记录路径（`String`，可跨 actor 传递），`NSImage` 由主线程侧的
  `ProcessIconCache` 按需加载并缓存 —— AppKit 图像不是 `Sendable`，不该穿过 actor 边界。
  实测未带来可测量的 CPU 开销（稳态仍为 1.3–1.4%）。
- **图表样式切换**：平滑曲线 / 面积 / 柱状，选择与时间跨度都持久化。
- **`Scripts/make-dmg.sh`**：产出标准「拖进 Applications」样式的压缩磁盘映像（约 2.2 MB）。
- **应用图标**：`Scripts/make-icon.swift` 用 CoreGraphics 生成完整尺寸集并打成
  `Resources/AppIcon.icns`，`make-app.sh` 会写进 bundle 并设置 `CFBundleIconFile`。
- **搜索框**：按进程名过滤（此前 `searchText` 被声明却从未接线）。
- **行右键菜单**：查看时间线、复制名称 / Bundle ID、在访达中显示。
- CI 增加 `.dmg` 打包与产物上传。

### Changed

- **时间线图表用 Swift Charts 重写**。旧实现是约 200 行手绘 `Path` + 手算坐标 +
  手摆刻度标签，只能画直线折线，坐标轴、hover 命中、深色模式配色都得自己维护。
  现在有原生坐标轴、平滑插值（`catmullRom`）和选取覆盖层，样式切换只是换 Mark 类型。
- **图表纵轴改画速率而非字节**，这样切换时间跨度（桶大小随之改变）时纵轴含义保持一致。
- **时间桶随跨度自适应**（1 分钟 → 1 小时），7 天视图不再挤上千个点。
- **单击行不再弹出模态详情窗**，改为双击打开（`contextMenu` 的 `primaryAction`）。
  此前想排序或选行都会被详情窗打断。

### Fixed

- **采集间隔与落库间隔现在会持久化**。此前只存在内存里，改完重启就回默认值。
- 图表数据点此前用 `UUID()` 作 id，每次刷新都是全新身份，导致 Chart 把整幅图当作
  新数据重画并重跑动画；改为「时间 + 方向」的稳定 id。
- 详情窗的 5 秒刷新从 `Timer` 改为可取消的 `Task`，关窗即停。

## [0.3.0] — 2026-09-07

CPU 从 6.3% 降到 1.4%，并把仓库整理成可公开发布的形态。
测量方法与全部数字见 [docs/performance.md](docs/performance.md)。

### Performance

- **采集层零桥接**：counts 回调改用 `CFDictionaryGetValue` + 静态 CFString 键直读
  4 个字段，取代 `dict as? [String: Any]` 对 47 键字典的整体桥接。
  340 条连接一帧从 4.4–10 ms 降到 0.25–0.58 ms（17–20×）。
  切换前用 823 条真实记录逐字段比对两条路径，零差异。
- **身份解析缓存化**：`ProcessIdentifier.displayName` 从每次读取都同步 XPC 查
  LaunchServices 的 computed property，改为解析时算好的存储属性；
  新增 `ProcessIdentityResolver` 按 `(pid, execName)` 缓存，热路径零 XPC。
- **计算移出主线程**：新增 `TrafficPipeline` actor 承载全部逐帧计算。
  `ingest()` 返回可选快照 —— 不到刷新节拍或窗口被遮挡时返回 nil，主线程整帧不被唤醒。
- **UI 改为差分更新**：`ObservableObject` → `@Observable`（属性级依赖追踪）；
  视图按数据依赖拆分；表格行从 `NSObject` 子类换成 `Equatable` 值类型 `ProcessRow`，
  使 SwiftUI `Table` 能做行级差分。这一项贡献了最大收益。
- **落库分桶**：内存内按 60 秒桶聚合后再写库，单条多值 `INSERT` 分块提交。
  同等负载下日写入行数从约 173 万降到约 5.8 万（30×）。

### Fixed

- 同一个 `AsyncStream` 被迭代两次（`AsyncStream` 只支持单次迭代，属未定义行为）。
- `AsyncStream` 使用默认 unbounded 缓冲，消费端慢于生产端时会无限堆积；改为
  `.bufferingNewest(1)`。
- `stop()` 的异步 reset 可能在 `start()` 的 `initialize` 之后才执行，导致
  「改设置 → 重启采集」时抹掉历史累计。
- `NStatManagerCreate` 收到的是 `Unmanaged.passUnretained(queue)`，存在悬垂风险。
- `ProcessHelper.pidCache` 是跨并发域访问的无隔离 `static var`（数据竞争）。
- 详情窗多余的 1 秒 `Timer.publish` 强制重绘。
- 启动时 AppKit 打印
  `Application performed a reentrant operation in its NSTableView delegate`：
  侧栏 `List` 的 `Section` 落到 NSOutlineView，`expandItem:` 时行高缓存自我重入。
  改用扁平 `List` 后清零，原生侧栏样式不受影响。

### Added

- `Scripts/make-app.sh`：组装带 `Info.plist` 的 `TrafficMonitor.app` 并 ad-hoc 签名。
  **此前只产出裸二进制，`Bundle.main.bundleIdentifier` 为 nil，告警通知被自身的
  guard 静默跳过 —— 也就是说告警功能在打包前是失效的。**
- 数据库保留期清理（启动时执行）。
- GitHub Actions CI：`macos-14` 上编译、测试、打包 `.app`。
- 中英双语 README、`docs/architecture.md`、`docs/performance.md`。
- MIT LICENSE。

### Changed

- 包布局拍平到仓库根，采用 SwiftPM 的单目标扁平布局（源码直接位于 `Sources/`、
  测试直接位于 `Tests/`），与 `swift package init --type executable` 生成的形态一致，
  `Package.swift` 无需任何自定义 `path:`。
- 测试从单个 862 行文件拆成 7 个按关注点组织的文件；`NStatFrameReducer` /
  `DeltaCalculator` / `ProcessAggregator` 的测试重写为 `SourceLedger` 与
  `TrafficPipeline` 测试。共 89 个测试。
- 版本号与 Bundle ID 统一到 `Constants.swift` 作为唯一真源，`make-app.sh`
  与设置窗「关于」页都从这里读取。
- 补上 `.gitignore`（此前为空，`.build/` 仅靠本地 `.git/info/exclude` 屏蔽，
  该文件不会随仓库分发）；`.claude/settings.local.json` 取消跟踪。

### Removed

- `TrafficStore`、`ProcessAggregator`、`DeltaCalculator`、`ProcessRecord` —— 职责并入
  `SourceLedger` 与 `TrafficPipeline`。按连接相减后，`knownPIDs`、首见 PID 上限钳制
  等启发式全部不再需要。
- `TrafficMonitor/archive/`（7 个不参与编译的废弃视图）、空的 `Resources/` 目录、
  已完成使命的 `MVP_PLAN.md` 与 `REFACTOR_PLAN.md`。

## [0.2.0]

- 采集后端从 `nettop` 子进程切换到 `NetworkStatistics.framework` 直接调用，
  去掉 fork/exec 与输出解析，**不再需要 sudo**。

## [0.1.0]

- 首个可用版本：`nettop` 快照差分、SQLite 持久化、SwiftUI 界面、分组与告警。
