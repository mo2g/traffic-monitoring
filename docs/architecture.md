# 架构 / Architecture

> 中文为准，英文摘要见文末。

## 数据流

```
┌─────────────────────────────────────────────────────────────────┐
│ NetworkStatistics.framework（内核 NStat 子系统，私有 API）        │
│   nettop / 活动监视器 用的是同一个后端                            │
└───────────────────────────┬─────────────────────────────────────┘
                            │ QueryAllSourcesUpdate，每 interval 秒（默认 2s）
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ NStatCollector          串行 DispatchQueue（.utility），非主线程  │
│  · counts 回调：CFDictionaryGetValue 直读 4 个字段（零桥接）      │
│  · SourceLedger：每条连接累计值就地相减 → 按 PID 聚合成增量       │
└───────────────────────────┬─────────────────────────────────────┘
                            │ AsyncStream<TrafficFrame>
                            │ .bufferingNewest(1) —— 消费端慢时丢旧帧而非堆积
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ CollectorService        @MainActor，只持有状态，不做逐帧计算      │
│  · detached 消费任务，把帧喂给管线                                │
│  · 监听窗口遮挡 / 应用隐藏，切换 UI 可见性                        │
└───────────────────────────┬─────────────────────────────────────┘
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ TrafficPipeline         actor，全部计算在这里                     │
│  ├ ProcessIdentityResolver  pid+execName → 标识（永久缓存）       │
│  ├ stats[processKey]        累计流量 + 瞬时速率                   │
│  ├ buckets[60s][key]        待落库的时间桶                        │
│  ├ 告警判定                 阈值 + 60s 节流                       │
│  └ 节流 + 可见性闸门 → DashboardSnapshot?                        │
└──────────┬──────────────────────────────────┬───────────────────┘
           │ 每 ≥1s 且窗口可见时才产出          │ 每 saveInterval（15s）
           ▼                                  ▼
┌────────────────────────┐        ┌───────────────────────────────┐
│ DashboardViewModel     │        │ DataStore   actor / GRDB      │
│ @Observable @MainActor │        │ SQLite WAL，多值 INSERT 分块   │
└──────────┬─────────────┘        └───────────────────────────────┘
           ▼ 属性级依赖追踪
┌─────────────────────────────────────────────────────────────────┐
│ SwiftUI  SummaryRow / ProcessTableView / GroupTableView …        │
└─────────────────────────────────────────────────────────────────┘
```

## 目录

| 路径 | 职责 |
|---|---|
| `Sources/App/` | 应用入口，注入环境对象 |
| `Sources/Core/Collector/` | `NStatCollector`（内核接口）、`SourceLedger`（纯函数差值）、`CollectorService`（生命周期） |
| `Sources/Core/` | `TrafficPipeline`（管线 actor）、`DataStore`（持久化）、`AlertStore` / `GroupStore`（偏好） |
| `Sources/Models/` | 值类型：`PIDDelta`、`TrafficFrame`、`ProcessIdentifier`、`ProcessRow`、`DashboardSnapshot`、`TrafficEvent` … |
| `Sources/Utilities/` | `Constants`（配置真源）、`ProcessIdentityResolver`、`ProcessIconCache`、`ByteFormatter`、`LogStore` |
| `Sources/ViewModels/` | `DashboardViewModel` |
| `Sources/Views/` | SwiftUI 视图，按窗口分子目录 |

## 关键设计决策

### 1. 为什么用 NetworkStatistics 私有框架，而不是 `nettop` 子进程

早期版本每个采样周期 `fork/exec` 一次 `nettop -l 1`。单次 fork/exec 约 5ms，加上 nettop 自己的内核查询 150–300ms，1s 间隔下 CPU 约 20%。

`NStatManagerCreate` + `QueryAllSourcesUpdate` 直接接同一个内核后端，无子进程、无解析、**无需 root**。代价是依赖私有 API（见 [限制](#限制)）。

### 2. 为什么按「连接」而不是按「进程」做差值

`SourceLedger` 保存的是每条 NStat source（一条 TCP/UDP 连接）的累计值，相减后才按 PID 汇总。

连接的累计值从建立时开始单调递增，关闭即被内核移除，因此：

- 不存在计数器回退 → 不需要 `knownPIDs`、上限钳制之类的启发式
- PID 复用、进程退出被连接生命周期自然覆盖
- 中途新建的连接，其累计值恰好就是这段间隔内的真实流量，可直接计入

首帧是例外：此时每条连接的累计值是它自建立以来的总量，不代表这一秒的流量。所以首帧标记 `isBaseline`，只用于建立基线和登记活跃进程，不计入统计。

### 3. 为什么不用 `dict as? [String: Any]`

counts 回调给的 CFDictionary 有 **47 个键**（rtt、拥塞窗口、收发缓冲区、地址……），我们只要 4 个。整体桥接要把 47 个 CFString 逐个转成 Swift String、数值全部装箱。

实测 340 条连接一帧：桥接 4.4–10ms，`CFDictionaryGetValue` 直读 0.25–0.58ms，**17–20 倍**差距。进程名对同一条连接恒定，只在该 PID 首次出现时桥接一次。

### 4. 为什么管线是 actor 且不在 MainActor 上

身份解析要调 `NSRunningApplication`（LaunchServices 同步 XPC，实测 0.24ms/次）。放在 `@MainActor` 上等于让主线程做 XPC 阻塞。

现在 `ingest()` 返回 `DashboardSnapshot?`：不到刷新节拍、或窗口被完全遮挡时返回 nil，**主线程整帧不被唤醒**。

### 5. 为什么用 `@Observable` 而不是 `ObservableObject`

`ObservableObject` 的 `objectWillChange` 是**对象级**通知：一个内部计数器自增，就会让所有观察它的视图重新求值 —— 在 `NavigationSplitView` 里表现为整棵 AppKit 视图树重新布局（30+ 层 `-[NSView _layoutSubtreeWithOldSize:]` 递归、约束求解、文本测量）。

`@Observable`（Observation 框架，macOS 14+）按**属性**追踪依赖。速率每秒变化只让 3 张汇总卡片失效，表格行变化只让表格失效。这一项贡献了性能重构中最大的一块收益，详见 [performance.md](performance.md)。

配套要求：表格行必须是 `Equatable` 值类型（`ProcessRow`），SwiftUI `Table` 才能做行级差分。旧实现用 `NSObject` 子类且无 `Equatable`，每次刷新都是 NSTableView 全量 reload。

### 6. 为什么落库要先分桶

旧实现每进程每 tick 写一行：40 个活跃进程 @2s = 20 行/秒 ≈ **173 万行/天**。

现在先在内存里按 60 秒时间桶聚合，一个桶一个进程只写一行 → 同样负载下约 5.8 万行/天，**降低 30 倍**（比值就是 `storageBucketSeconds / interval`）。写入用单条多值 `INSERT ... VALUES (?,…),(?,…)` 分块提交。

### 7. 图标为什么只在管线里存路径

`NSImage` 不是 `Sendable`，不能跟着 `ProcessIdentifier` 穿过 actor 边界。
所以身份解析时只记录一个 `String` 路径（`.app` 包优先，否则可执行文件本身），
真正的图像由主线程侧的 `ProcessIconCache` 按需加载。

缓存对**未命中也记录**：否则每次重绘都会对同一个失败路径重试一遍 LaunchServices 查询。
历史行只有 `bundleId` 没有路径，缓存会退回 `urlForApplication(withBundleIdentifier:)`，
同样每个标识最多一次。

### 8. 侧栏为什么是扁平 `List` 而不是带 `Section`

macOS 上带 `Section` 的 `List` 由 NSOutlineView 承载，构建时要 `expandItem:` 展开 section，而 AppKit 在这条路径上会自我重入：

```
expandItem: → NSTableRowData.endUpdates → _keepTopRowStableAtLeastOnce
  → rowAtPoint: → _cacheRowSpansInRange:                 ← 第一次进入
    → _adjustRowSpansStartingAtRow: → _updateTableViewSize
      → _minimumFrameSize → _totalHeightOfTableView
        → _cacheRowSpansInRange:                         ← 重入
```

每次启动都会打印 `Application performed a reentrant operation in its NSTableView delegate`，且 AppKit 声明将来会升级成 assert。扁平 `List` 走 NSTableView，没有 `expandItem:` 这一步，警告消失且完整保留原生侧栏材质。

## 并发模型

| 执行域 | 承载内容 |
|---|---|
| `com.trafficmonitor.nstat`（串行队列） | NStat 回调、`SourceLedger`、帧组装 |
| `TrafficPipeline`（actor） | 身份解析、聚合、累计、分桶、告警、快照生成 |
| `DataStore`（actor） | 所有 SQLite 读写 |
| `@MainActor` | `CollectorService` 状态、`DashboardViewModel`、全部 SwiftUI |

跨域只通过值类型传递（`TrafficFrame`、`DashboardSnapshot`），没有共享可变状态。

## 限制

| 限制 | 说明 |
|---|---|
| 依赖私有 API | `NetworkStatistics.framework` 未公开，**无法上架 App Store**，且 macOS 大版本升级可能改变符号或行为 |
| loopback 自连双记 | 进程通过 127.0.0.1 连自己时是同一 PID 的两条连接，内核分别记收和发。实测传输 10 MiB → rx=10 MiB 且 tx=10 MiB，"下载+上传"合计是实际载荷的 2 倍。真实外网流量不受影响 |
| 采样间隔内的短连接 | 两次采样之间建立又关闭的连接，其流量会在关闭时随 source 移除而丢失 |
| 统计窗口固定 24 小时 | 侧栏的「今日/本周/本月」目前只改标签，历史查询窗口硬编码为最近 24 小时 |

---

## English summary

`NStatCollector` polls the kernel Network Statistics subsystem (the same backend
`nettop` and Activity Monitor use) on a serial dispatch queue, reading only four
fields per connection through `CFDictionaryGetValue` — bridging the full 47-key
`CFDictionary` cost 17–20× more. `SourceLedger` turns per-connection cumulative
counters into per-PID deltas; because a connection's counter is monotonic and the
kernel removes it on close, no counter-rollback heuristics are needed.

Frames flow through an `AsyncStream` (`.bufferingNewest(1)`) into `TrafficPipeline`,
an actor that does *all* the work off the main thread: identity resolution
(cached, so LaunchServices XPC happens once per process lifetime), aggregation by
bundle identifier, 60-second bucketing for persistence, alert evaluation, and
snapshot generation. `ingest()` returns an optional snapshot — `nil` when the
refresh interval hasn't elapsed or the window is occluded — so the main thread is
never woken for a frame it cannot use.

The UI uses `@Observable` (property-level dependency tracking) rather than
`ObservableObject` (object-level invalidation), and `Equatable` value-type rows so
SwiftUI `Table` can diff individual rows. See [performance.md](performance.md) for
the measurements behind these choices.
