# TrafficMonitor macOS App — MVP 开发计划

> 状态：✅ P0+P1 全部完成，编译通过，可运行  
> 目标：一款 macOS 标准窗口应用，按进程/应用统计网络流量使用情况，弥补 Shadowrocket 等 VPN 代理无法区分应用流量的痛点。

---

## 一、产品定义

### 1.1 用户问题

macOS 上使用 Shadowrocket/Surge 等 VPN 模式代理时，所有流量经过 `utun` 虚拟网卡后"发起进程"身份丢失——代理工具只能看到自己在产生流量，无法知道到底是 Chrome、Edge、VS Code 还是 WeChat 消耗的。Little Snitch 同样受此限制。

### 1.2 解决方案

利用内核网络统计子系统在流量进入 VPN 隧道**之前**就已记录的进程身份信息，通过 `nettop` 采集，构建一款桌面窗口应用。

### 1.3 一句话定位

**"Mac 上的流量仪表盘——打开即看哪个应用吃了多少流量，实时统计、历史回看，代理模式下也能精准区分。"**

---

## 二、MVP 范围 — 完成度

### 2.1 P0 — 100% ✅

| 编号 | 功能 | 状态 | 实现 |
|------|------|------|------|
| F1 | 实时按进程流量采集 | ✅ | `RootCollector` + `CollectorService`，5s 间隔，首次弹窗后静默 |
| F2 | 主窗口仪表盘 | ✅ | NavigationSplitView：侧栏时间范围 + 概要卡片 + 进程表格(5列) |
| F3 | 采集状态指示 | ✅ | 工具栏状态胶囊 + 启停按钮 + 快照计数 |
| F4 | 本地数据持久化 | ✅ | GRDB + SQLite(WAL) + 复合索引 + 查询/时间线/删除 API |
| F5 | 基础设置 | ✅ | 采集间隔(自动重启) + DB大小 + 自动清理(天数/开关/按钮) + 排除进程 + 关于 |

### 2.2 P1 — 100% ✅

| 编号 | 功能 | 状态 | 实现 |
|------|------|------|------|
| F6 | 今日/本周/本月汇总 | ✅ | 侧栏切换时间范围，联动 SQL 查询 |
| F7 | 单进程详情 | ✅ | 点击表格行弹出 DetailWindow：时间选择器 + 柱状图 + 汇总卡片 |
| F8 | 历史记录导出 | ✅ | 工具栏导出按钮 → 系统原生 `fileExporter` → CSV |

### 2.3 P2+ — 0%（以后再做）

| 功能 | 优先级 |
|------|--------|
| 进程分组/标签 | 低 |
| 流量告警 | 低 |
| 白名单模式 | 低 |
| 与 Shadowrocket/Surge 数据关联 | 低 |
| UDP/QUIC 支持 | 低 |
| iCloud 同步 | 低 |

---

## 三、技术架构

### 3.1 实际架构图（与实现一致）

```
┌──────────────────────────────────────────────────────────────────┐
│                      TrafficMonitor.app                          │
│  ┌──────────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   MainWindow     │  │ DetailWindow │  │ SettingsView │       │
│  │  (SwiftUI)       │  │ (SwiftUI)    │  │ (SwiftUI)    │       │
│  │  · 进程表格+占比  │  │ · 柱状图      │  │ · 采集/数据   │       │
│  │  · 速率概要      │  │ · 时间选择器  │  │ · 关于页     │       │
│  └────────┬─────────┘  └──────┬───────┘  └──────┬───────┘       │
│           └─────────┬─────────┴──────────┬───────┘               │
│          ┌──────────▼──────┐    ┌────────▼────────┐              │
│          │ DashboardVM     │    │   DataStore     │              │
│          │ (1s 定时刷新)   │    │   (GRDB Actor)  │              │
│          └──────────┬──────┘    └────────┬────────┘              │
│                     └──────────┬────────┘                        │
│                     ┌──────────▼──────────┐                      │
│                     │  CollectorService   │                      │
│                     │  · Timer 5s 循环    │                      │
│                     │  · touch trigger    │                      │
│                     │  · 读取 output 文件 │                      │
│                     └──────────┬──────────┘                      │
│                                │                                 │
│         /tmp/tm_nettop_trigger    /tmp/tm_nettop_output           │
│                    │                         ▲                   │
│         ┌──────────▼─────────┐               │                   │
│         │  collector.sh      │               │                   │
│         │  (root 常驻)       ├───────────────┘                   │
│         │  AppleScript 直接  │                                   │
│         │  启动，绕过 sudo   │                                   │
│         └────────────────────┘                                   │
│                                                                  │
│         ┌────────▼────────┐                                      │
│         │     SQLite      │                                      │
│         │  (GRDB.swift)   │                                      │
│         └─────────────────┘                                      │
└──────────────────────────────────────────────────────────────────┘
```

### 3.2 技术选型

| 层 | 选择 | 理由 |
|----|------|------|
| 语言 | Swift 5.10 | macOS 原生 |
| UI 框架 | SwiftUI (NavigationSplitView) | macOS 14+ 标准布局 |
| 数据采集 | **nettop**（libproc 不可用——XNU 源码确认） | 唯一能获取进程级网络累计字节的方式 |
| 提权方式 | **AppleScript 弹窗 + 纯文件 IPC** | 首次弹窗 → AppleScript 直接 `nohup collector.sh &` 以 root 启动（绕开 sudo，避免 Touch ID 二次认证） |
| 子进程 IPC | **文件触发**（touch trigger → 子进程检测 → 写入 output） | 比管道简单可靠，无需管理 stdin/stdout 生命周期 |
| 数据库 | GRDB.swift v6.29.3 | 类型安全、async/await |
| 图表 | 手绘柱状图（GeometryReader） | 零依赖，避免 Swift Charts 导入问题 |
| 最低系统 | macOS 14.0 | SwiftUI 现代 API |
| 包管理 | SPM | 官方工具 |

### 3.3 采集与提权设计（最终实现）

```
首次启动:
  ┌─────────────────────────────────────┐
  │  系统密码弹窗（仅一次！）            │
  │  "TrafficMonitor 想要进行更改"       │
  └─────────────────────────────────────┘
          │ 用户输入密码
          ▼
  NSAppleScript:
    do shell script "nohup collector.sh &" with administrator privileges
    → collector.sh 以 root 启动，循环检测 trigger 文件
          │
          ▼
  ┌────── root 子进程（常驻）───────────┐
  │  while true:                      │
  │    if /tmp/tm_nettop_trigger:     │
  │      rm trigger                   │
  │      nettop → /tmp/tm_nettop_output│
  │      echo "---SNAPSHOT_END---"    │
  │    sleep 0.5                      │
  └────────────────────────────────────┘
          ▲                    │
    touch trigger      read output (mtime 检测)
          │                    ▼
  ┌────── 主进程 ──────────────────────┐
  │  Timer 每 5s:                     │
  │    1. 记下 output 当前 mtime      │
  │    2. touch trigger               │
  │    3. 轮询 output mtime 变化(10s) │
  │    4. 读取 → 解析 → 差值 → 存储   │
  └───────────────────────────────────┘
          │
          │ 应用退出 → pkill collector.sh
          ▼
  root 权限随之消失 ✓
```

**关键设计决策**：不使用 `sudo /bin/sh collector.sh`，而是 AppleScript 直接以 root 启动 `collector.sh`。这绕过了 sudo 机制，彻底消除了"密码后还弹 Touch ID"的双重认证问题。

### 3.4 数据模型

```sql
CREATE TABLE trafficEvent (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp   REAL NOT NULL,       -- Unix 时间戳
    interval    REAL NOT NULL,       -- 采集间隔（秒）
    processKey  TEXT NOT NULL,       -- 聚合键（bundleId 或 execName）
    bundleId    TEXT,                -- Bundle ID（可能为空）
    displayName TEXT NOT NULL,       -- 显示名
    bytesIn     INTEGER NOT NULL,    -- 增量接收字节
    bytesOut    INTEGER NOT NULL     -- 增量发送字节
);

CREATE INDEX idx_traffic_ts_process ON trafficEvent(timestamp, processKey);
```

---

## 四、开发阶段 — 全部完成 ✅

| Phase | 内容 | 状态 | 产出 |
|-------|------|------|------|
| 0 | 脚手架 + 采集引擎 | ✅ | collector.sh, RootCollector, NettopParser, DeltaCalculator, ProcessAggregator |
| 1 | 数据持久化 + 采集服务 | ✅ | DataStore(GRDB), CollectorService(状态机), 9项XCTest |
| 2 | 主窗口仪表盘 | ✅ | MainWindowView, DashboardViewModel, SummaryCard, ProcessRow |
| 3 | 详情 + 历史 | ✅ | DetailWindow(柱状图+时间选择器+汇总), CSV导出 |
| 4 | 设置 + 打磨 | ✅ | SettingsView(间隔/DB/清理/关于), 导出按钮 |

### 实际文件清单（29 文件，~2,200 行 Swift）

```
TrafficMonitor/
├── Package.swift                    # SPM + GRDB v6.29.3
├── build_and_test.sh                # 编译 + XCTest 运行
├── Sources/
│   ├── App/TrafficMonitorApp.swift  # @main 入口（挂载 CollectorService + DashboardVM）
│   ├── Core/
│   │   ├── Collector/
│   │   │   ├── collector.sh         # root 子进程（trigger 驱动，AppleScript 直接启动）
│   │   │   ├── RootCollector.swift  # 授权 + 文件 IPC（touch trigger / 轮询 output）
│   │   │   ├── NettopParser.swift   # nettop 文本解析（正则+单位转换+PID聚合）
│   │   │   ├── CollectorService.swift # 采集状态机（idle→authorizing→running→stopped→error）
│   │   │   └── DeltaCalculator.swift # 快照差值（进程重启检测+异常值上限）
│   │   ├── ProcessAggregator.swift  # Bundle ID 优先聚合
│   │   └── DataStore.swift          # GRDB 封装（建表/写入/查询/时间线/删除/大小）
│   ├── Models/
│   │   ├── TrafficEvent.swift       # DB 模型（GRDB TableRecord 适配）
│   │   ├── ProcessSnapshot.swift    # 内存快照（ProcessRecord + 聚合记录）
│   │   └── ProcessIdentifier.swift  # 聚合键（bundleId + execName）
│   ├── Utilities/
│   │   ├── ByteFormatter.swift      # 字节格式化 + 速率格式化
│   │   ├── Constants.swift          # 全局常量（路径/超时/排除列表 + nettop 自动检测）
│   │   └── ProcessHelper.swift      # NSRunningApplication + libproc 工具
│   ├── ViewModels/
│   │   ├── DashboardViewModel.swift # 1s 刷新（Timer→NotificationCenter 解耦）
│   │   └── (DetailViewModel 内嵌在 DetailWindow.swift)
│   └── Views/
│       ├── MainWindow/
│       │   ├── MainWindowView.swift # 主窗口（侧栏+概要+表格+工具栏+CSV导出）
│       │   ├── SidebarView.swift    # 侧栏（占位——功能已移入 MainWindowView）
│       │   └── DashboardView.swift  # 仪表盘（占位——功能已移入 MainWindowView）
│       ├── Detail/
│       │   ├── DetailWindow.swift   # 详情窗口（柱状图+时间选择器+汇总卡片）
│       │   └── TrafficChart.swift   # 图表（占位——实现在 DetailWindow）
│       ├── History/HistoryView.swift # 历史（占位——汇总已集成到主窗口）
│       ├── Settings/SettingsView.swift # 设置页（TabView：采集+数据+关于）
│       └── Components/
│           ├── ProcessRow.swift     # 进程行（备用组件）
│           ├── TrafficBadge.swift   # 速率标签（备用组件）
│           ├── SummaryCard.swift    # 概要卡片组件
│           └── StatusIndicator.swift # 状态指示器（备用组件）
└── Tests/CoreTests.swift            # 9 项 XCTest（NettopParser 6 + DeltaCalculator 3）
```

---

## 五、已确认的设计决策

### Q1：采集方式

**结论**：nettop 子进程（libproc 不可用——XNU 源码确认 `sockbuf_info.sbi_cc` 仅为当前 buffer 占用，非累计值）

### Q2：提权操作

**结论**：AppleScript 弹窗 + 文件触发 IPC。首次弹窗后 AppleScript 直接以 root 启动 `collector.sh`，完全绕过 sudo，消除 Touch ID 二次认证。子进程通过检测 `/tmp/tm_nettop_trigger` 文件执行采集，结果写入 `/tmp/tm_nettop_output`。应用退出时 `pkill` 子进程回收权限。

### Q3：进程聚合策略

Bundle ID 优先（NSRunningApplication），fallback 进程名。

### Q4：菜单栏显示

不提供菜单栏常驻，标准窗口应用。

### Q5：数据库保留策略

手动调整，默认关闭自动清理。

---

## 六、风险和缓解

| 风险 | 状态 | 缓解 |
|------|------|------|
| ~~libproc 拿不到网络字节数~~ | ✅ 已解决 | 转为 nettop 方案 |
| ~~双重认证（密码后 Touch ID）~~ | ✅ 已修复 | AppleScript 直接启动，绕开 sudo |
| ~~DataStore 重复初始化~~ | ✅ 已修复 | `isSetup` 守卫 |
| ~~stop/restart 僵尸进程~~ | ✅ 已修复 | `stop()` await shutdown 完成后再设状态 |
| 子进程崩溃导致采集中断 | 低 | mtime 超时检测 → 自动标记 error → 用户手动重启 |
| AppleScript 弹窗被用户取消 | 中 | `authorizeAndStart()` 返回 false → UI 提示 |
| nettop 输出格式变化 | 低 | 正则解析 + 单元测试 |
| 文件 IPC 竞争 | 低 | mtime 精确检测 + 轮询等待 + 10s 超时保护 |

---

## 七、依赖

| 库 | 版本 | 用途 |
|----|------|------|
| GRDB.swift | 6.29.3 | SQLite ORM |
| (无其他第三方库) | — | 其余全部系统框架：SwiftUI, AppKit, Foundation, Combine, Security, UniformTypeIdentifiers |

---

## 八、已知限制

1. **编译环境**：开发在 Linux 沙盒，无法自动编译 macOS 代码；每次修改后需用户手动 `bash build_and_test.sh` 验证
2. **unused 文件**：`SidebarView.swift`、`DashboardView.swift`、`TrafficChart.swift`、`HistoryView.swift`、`ProcessRow.swift`、`TrafficBadge.swift`、`StatusIndicator.swift` 为早期阶段的占位组件，功能已集成到 `MainWindowView` 和 `DetailWindow` 中，可安全删除
3. **UDP/QUIC 流量**：nettop 默认只统计 TCP，HTTP3(QUIC) 暂不采集

---

> **变更记录**：
> - 2026-06-10：初始版本，提交 Review
> - 2026-06-10：根据 Review 反馈更新——采集双后端、弹窗提权、Bundle ID 聚合、取消菜单栏、数据保留手动控制
> - 2026-06-10：预研完成——libproc 不可用，nettop 为主采集方案
> - 2026-06-10：授权方案确认——方案 B 持久 root 子进程
> - 2026-06-10：P0+P1 全部完成——架构调整为文件触发 IPC（绕过 sudo 消除 Touch ID 二次认证），9 项测试通过，可编译运行
