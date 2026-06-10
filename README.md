# macOS 按应用流量监控

基于 `nettop` 快照差分，在 VPN/代理模式下精准统计每个应用产生的网络流量。

## 为什么能解决 Shadowrocket 的问题

Shadowrocket 在 macOS 上以 VPN 模式（NEPacketTunnelProvider）运行，流量经过 `utun` 虚拟网卡进入隧道后，内核层面"发起进程"的信息就丢失了——从 Shadowrocket 的视角看，所有流量都像是它自己产生的。Little Snitch 也受此影响，默认过滤了 localhost/隧道流量。

**`nettop` 不同。** 它的数据来自内核网络统计子系统，这个统计在流量进入 `utun` 之前就已经记录了发起连接的进程身份。因此即使 Shadowrocket 是最终出站者，`nettop` 仍能还原出"是 Chrome 在产生流量"。

核心流程图：

```
Chrome → connect()         ← 内核在此记录: Chrome.pid 发起了连接
       → 路由表 → utun    ← 路由到 VPN 隧道
       → Shadowrocket       ← 代理转发，此时看不到原始进程
       → 互联网

nettop 在上层读取，不受下层隧道影响 ✓
```

## 文件结构

```
traffic-monitoring/
├── traffic_collector.py   ← 采集守护进程（需 sudo + 保持运行）
├── traffic_viewer.py      ← 查询 & 报表工具
└── README.md
```

## 快速开始

### 第一步：测试 nettop 是否能正常工作

```bash
# 单次快照测试（需 sudo）
sudo python3 traffic_collector.py --oneshot
```

如果你能看到 Chrome、Edge 等进程及流量数据（即使为 0），说明一切正常。

### 第二步：启动采集器

```bash
# 后台持续采集，每 5 秒一次快照
sudo python3 traffic_collector.py &

# 或者自定义间隔
sudo python3 traffic_collector.py --interval 10 --db ~/traffic.db &
```

数据默认保存在 `~/.traffic_monitor.db`（SQLite）。

### 第三步：查看统计

```bash
# 查看今日汇总
python3 traffic_viewer.py --today

# 查看最近 3 小时
python3 traffic_viewer.py --last 3h

# 只看 Top 5
python3 traffic_viewer.py --top 5 --today

# 过滤特定应用
python3 traffic_viewer.py --process Chrome --today

# 查看 Chrome 的时间线
python3 traffic_viewer.py --timeline "Chrome" --last 1h
```

### 第四步：导出可视化报表

```bash
# 导出为 HTML（包含 Chart.js 柱状图）
python3 traffic_viewer.py --export html --today --output ~/Desktop/traffic.html
```

然后用浏览器打开 HTML 文件即可看到交互式图表。

## 示例输出

```
======================================================================
  今日流量 (2026-06-10)
======================================================================
进程                       下载          上传          合计       占比
----------------------------------------------------------------------
Chrome                   1.2G       300.5M         1.5G      52.3%
Edge                   500.3M        50.1M       550.4M      18.8%
Safari                 200.1M        10.2M       210.3M       7.2%
VS Code                150.0M        80.0M       230.0M       7.8%
WeChat                  80.5M        20.3M       100.8M       3.4%
...                                                              
----------------------------------------------------------------------
总计                                                 2.9G

数据范围: 14h32m, 23 个活跃进程
```

## 技术细节

### 采集原理

```
时间线:  t0        t1        t2        t3
         ↓         ↓         ↓         ↓
快照:   S₀=100M  S₁=150M  S₂=180M  S₃=210M   ← Chrome 累计字节
增量:            Δ₁=50M   Δ₂=30M   Δ₃=30M   ← 写入数据库
```

1. 用 `nettop -l 1 -P -n -J bytes_in,bytes_out` 抓取快照
2. 按进程名聚合（合并同名多 PID，如 Chrome 的多个子进程）
3. 计算相邻快照差值 = 该周期内的流量增量
4. 存入 SQLite，带时间戳

### 进程名规范化

Chrome 和 Edge 在 macOS 上每个 tab/site 会创建独立进程（如 `Google Chrome.1234`, `Google Chrome Helper.5678`），采集器自动将它们聚合到 `Chrome` 下。类似处理也适用于 VS Code 等。

### 处理进程重启

如果 Chrome 在两次快照之间重启，累计计数器会归零。采集器检测到倒退后，会使用当前值作为增量（避免负数）。

### 排除系统噪音

默认跳过 `kernel_task`、`launchd`、`WindowServer` 等永远在运行但不产生实际网络流量的系统进程。

## 开机自启动（可选）

创建 LaunchAgent 让采集器开机自启：

```bash
# 创建 plist
cat > ~/Library/LaunchAgents/com.traffic.collector.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.traffic.collector</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/sudo</string>
        <string>/usr/bin/python3</string>
        <string>/Volumes/dev/web/mo2g/traffic-monitoring/traffic_collector.py</string>
        <string>--interval</string>
        <string>10</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/traffic_collector.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/traffic_collector.err</string>
</dict>
</plist>
EOF

# 加载
launchctl load ~/Library/LaunchAgents/com.traffic.collector.plist
```

**注意**：如果使用 LaunchAgent，需要在 `/etc/sudoers` 中配置 `nopasswd`，否则 sudo 会卡住。更推荐的方式是用 cron 或手动运行：

```bash
# crontab（每10分钟检查一次，确保一直在跑）
*/10 * * * * pgrep -f traffic_collector.py || sudo python3 /path/to/traffic_collector.py --interval 10 &
```

## 局限性与注意事项

| 局限 | 说明 | 影响 |
|------|------|------|
| nettop 粒度 | 5 秒间隔内的小流量请求可能被合并 | 轻微——总体统计准确 |
| UDP 流量 | nettop 默认只看 TCP，UDP 需 `-m udp` | QUIC/HTTP3 流量可能遗漏 |
| 短连接 | 两次快照之间建立又断开的连接不可见 | 对总量影响小 |
| 快照时差 | 快照时刻的瞬间偏差 | 可忽略——统计级别 |
| 需 sudo | nettop 需要 root 权限 | 安全性考量 |

## 扩展方向

- 增加 UDP 支持：在 `take_snapshot()` 中添加 `-m udp` 的第二次采集
- 实时 Web 仪表板：用 Flask + WebSocket 推送实时数据
- 告警：某个应用超出预设流量阈值时通知
- 与 Shadowrocket 统计关联：对比两套数据验证一致性
