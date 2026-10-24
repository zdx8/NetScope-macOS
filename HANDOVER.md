# NetScope 交接文档

> 版本 1.0.0（build 261025.xxxx）· 2026-10-25 · 本机实测，非交付时回溯文档

---

## 1. 一句话结论

一个 macOS 菜单栏常驻的应用级网络流量监控小工具，**可交付、当前已在本机运行**。
面向「想知道刚才到底是谁在偷偷跑流量」的个人使用场景：点开面板 3 秒内能看出是哪个应用在下载/上传。

不发 Release、不做官网、不对外分发（原因见第 6 节：临时签名 + 依赖 `nettop` 私有输出格式）。

## 2. 交付物与位置

| 交付物 | 路径 | 版本 | 校验 |
|---|---|---|---|
| 应用包 | `dist/NetScope.app` | 1.1.2 | SHA-256（可执行文件）`b71f340ee6c8cfe39f0c66837e54bb8287448cee8dc97fd96cc22b0e22b545c1` |
| 源码 | `/Users/zyg/WorkBuddy/Software Development/NetScope` | 本地 git 未初始化 | — |
| 界面快照 | `docs/panel.png`、`docs/panel-history.png`、`docs/panel-settings.png` | — | 748×845 / 748×754 / 748×1020（真实 popover 截图） |

- 可执行文件 1,034,016 字节（1.01 MB）；`.app` 整包 3.1 MB。体积增长来自 libsqlite3 与 UserNotifications 的链接。
- **未对外发布**：没有 GitHub Release、没有 Pages、没有远程仓库。
- 临时签名（`codesign --sign -`），仅本机可双击运行。

## 3. 怎么跑起来

实测环境：**macOS 27.2 (26B118) / Xcode 27.1 (27A9275) / Swift 6.4 / arm64**

```bash
cd "/Users/zyg/WorkBuddy/Software Development/NetScope"

# 一条命令：编译 → 图标 → 组装 .app → 签名 → 启动
bash Scripts/build_app.sh

# 只要产物不启动
bash Scripts/build_app.sh --no-open
```

耗时实测：**首次构建 23.68 秒**（含 SwiftPM 全量编译），**增量构建 6–7 秒**。
产物落在 `dist/NetScope.app`，双击即可运行；`open dist/NetScope.app` 等价。

前置条件：
- 需要 `/usr/bin/nettop`（macOS 自带，无需安装任何东西）。
- **不需要 root**：实测普通用户即可读到全系统各进程的累计字节数（能看到 `mDNSResponder`、
  `networksession` 等系统守护进程的计数）。
- 不需要辅助功能权限、屏幕录制权限、完全磁盘访问权限。

## 4. 架构与关键设计

```
NetScopeMain (@main)
└── AppDelegate
    ├── StatusItemController        菜单栏项 + NSPopover + 右键菜单 + 信号处理
    │   ├── MonitorEngine (@MainActor, ObservableObject)
    │   │   ├── TrafficChannel(.external)   应用归属通道
    │   │   │   ├── NettopPTY               pty + posix_spawn，读 nettop CSV
    │   │   │   └── TrafficAggregator       累计值 → 速率差分
    │   │   ├── TrafficChannel(.physical)   总量通道（只算 en*）
    │   │   ├── TunnelDetector              识别活动 utun / VPN 客户端
    │   │   └── ProcessDirectory            pid → 名称/图标/聚合键
    │   └── PanelView               SwiftUI 面板
    │       ├── Sparkline           Canvas 双线曲线
    │       └── AppRowView          单行：图标 / 名称 / 双速率 / 占比条
    └── OrphanReaper                启动时清理遗留 nettop
```

数据流：`nettop stdout(pty) × 2 → 按行切分 → 按表头分批 → 差分得速率 → 按 app bundle 聚合 → 主线程刷新 UI`

### 决策 1：用 pty 驱动 nettop，而不是反复 fork

- **为什么**：`nettop -L N` 的采样窗口固定 30 秒（实测 `-L 1 -s 1` 与 `-L 3 -s 1` 都是 30.0 秒），
  没法用它做秒级采样；`-L 0` 接管道时 stdout 全缓冲（4 KB），实测延迟数秒且进程被杀会丢数据。
- **代价**：要自己 `openpty` + `posix_spawn` + 管理 fd 生命周期，比管道多约 80 行；
  并且 **nettop 在 pty 下会忽略 SIGTERM**（见决策 3）。
- **什么条件下推翻**：直接用 `NetworkStatistics` 私有框架（nettop 的底层），能省掉子进程与 pty，
  但需要 dlsym 私有符号，跨系统版本风险更高。当前选择更稳。

### 决策 2：聚合键统一取「最外层 .app 路径」

- **为什么**：初版让 `NSWorkspace.runningApplications` 用 `bundleIdentifier`、
  让 `proc_pidpath` 用可执行路径，结果同一个 FlClash 被拆成两行（实测）。
  统一到「可执行文件 → 向上第一个最外层 .app」后，Chrome 的多个 Helper 也能自动并进一条。
- **代价**：`/usr/libexec/*` 这类系统守护进程找不到 .app，只能用进程名 + 齿轮图标；
  同一 Xcode 内部的构建子进程会被算进 Xcode 名下（对本用途可以接受）。
- **什么条件下推翻**：需要区分「应用本体」与「其 XPC 服务」时，改用 `NSRunningApplication.bundleIdentifier`
  加一层父子映射表。

### 决策 3：退出时 SIGTERM 之后必须补 SIGKILL

- **为什么**：实测 nettop 在 pty 下**不响应 SIGTERM**（同一命令接管道时正常退出），
  `kill(2)` 却返回 0。只发 SIGTERM 会让 nettop 被 launchd 收养后在后台长期每秒采样。
- **代价**：退出路径多了 80 ms 等待。
- **什么条件下推翻**：如果将来发现 nettop 在 pty 下能响应 TERM（系统版本行为变化），可以省掉这一刀。

### 决策 4：速率历史 60 个点，且按 pid 真实时间差摊平

- **为什么**：nettop 只列出「当前持有 socket」的进程，一个进程可能这秒有连接、下秒没有。
  一消失就丢基准会让它再次出现时被当成新进程、速率归零，那段字节凭空消失。
  改为保留 30 秒基准，并用该 pid 的真实时间差（而非全局采样间隔）算速率。
- **代价**：进程重新出现的那一次采样，瞬时速率会略偏高（流量被摊到 1 秒里）。
- **什么条件下推翻**：需要严格瞬时速率时，改用 nettop 的 `-d`（delta 模式）直接取增量。

### 决策 5：双通道采样——列表看全接口，总量只认物理网卡

- **为什么**：nettop 按 socket 所在接口归因。`-t external` 把 utun / bridge / vmnet 全算进来，
  同一份数据在虚拟接口和物理接口各出现一次。实测一次采样里 `-t external` 合计 **23,575 B**，
  `-t wifi -t wired` 只有 **10,758 B**，差的 12,817 B 全部来自虚拟接口（limactl 6478、
  tailscale 6078、syspolicyd 4417）。虚拟机（Lima / Docker）的 bridge / vmnet 同理，
  所以这个改动不只修 VPN。
- **做法**：两条通道各司其职——`.external` 出应用列表（覆盖所有应用，含走隧道的那部分），
  `.physical` 出总量（网卡真实跑过的字节）。
- **为什么不剔除 VPN 客户端**：它在物理链路上的流量是真实发生的字节，删掉就是漏统计；
  而且用户明确要求能看到 VPN 类应用自身的流量。代价是「客户端的密文」与「隧道内应用的明文」
  互为副本，各应用之和会大于总量——用行内盾牌标记 + 悬停说明来交代，而不是把行藏起来。
- **代价**：多一个 nettop 子进程（实测 CPU 0.16%→0.27%，内存 41.3→43.4 MB）。
- **什么条件下推翻**：能拿到「进程 → 接口」的归属映射（直接调 NetworkStatistics 私有框架读
  NStatSource）时，可以精确到每条连接，进而给每个应用标注「这份流量走隧道还是物理链路」。

### 决策 6：隧道判据用「utun 上有 IPv4」

- **为什么**：只需要知道「当前有没有 TUN 型 VPN」，用来决定标题上是否打 VPN 标记、
  以及解释列表之和为什么可能大于总量；不需要知道是哪个进程建的隧道。
- **判据**：`utun*` 上分配了 IPv4 地址。macOS 会给每个 utun 都发 `fe80::` 链路本地地址
  （utun0–4 这类系统内部接口就是这样），用 IPv4 能干净地区分——实测本机 utun5
  （Tailscale，100.68.175.24）与 utun6（FlClash，198.18.0.0）有 IPv4，utun0–4 没有。
- **代价**：只跑 IPv6 的隧道识别不到，此时不显示 VPN 标记（总量依然准确）。
- **什么条件下推翻**：需要按隧道做分流统计时，必须拿到接口与进程的映射。

### 决策 7：历史用 SQLite + 30 秒落盘节流

- **为什么用 SQLite**：系统自带 `libsqlite3`（实测 3.54.0），零第三方依赖；按天聚合的查询
  （今日合计、7 天序列、Top N）用 SQL 一句话，JSON/plist 要全量读写。
- **为什么节流 30 秒**：采样每秒一次，逐秒 UPSERT 会把磁盘写入放大 30 倍，而这份数据的粒度
  只是「天」。代价是崩溃最多丢 30 秒，可接受。
- **为什么口径用 external**：历史里的「Top 应用」要与实时面板看到的一致。代价同列表——
  走 TUN 时 VPN 客户端与隧道内应用会各记一份。
- **什么条件下推翻**：需要秒级回溯（比如画某天的流量曲线）时，得改成按分钟分桶，写入频率也要提高。

### 决策 8：告警必须连坐三次才发

- **为什么**：瞬时速率极易冲高（下载刚开始那一秒就会飙到峰值），单次超阈值就推送会把功能
  变成噪音，用户第一件事就是关掉它。
- **规则**：连续 3 次采样都超阈值 + 同应用 10 分钟冷却 + 掉出阈值立即清零计数。
- **代价**：真正持续的大流量会晚 2 秒提醒。
- **什么条件下推翻**：用户明确希望「一开始下载就提醒」时，把 `minConsecutive` 调到 1。

## 5. 已完成 / 未完成 / 已知问题

**已完成**
- 秒级采样、按应用聚合、总速率与本次累计
- 60 秒双线曲线、Top N 列表（含「其他 N 个进程」聚合行）、占比条
- **菜单栏双行数值**：网络图标 + 上行/下行两行实时速率（template image，自适应深浅色）；趋势图为右键可选形态
- **历史持久化**：SQLite 按天聚合，今日/近 7 天合计、7 天柱状图、今日 Top 应用
- **流量告警**：连续 3 次超阈值才通知，同应用 10 分钟冷却
- **总量口径**：双通道采样——列表用全接口（覆盖走隧道的应用），总量只取物理网卡；VPN 应用照常显示并带盾牌标注
- **列表口径开关**：可切成「只统计物理链路」，此时各应用之和与总量一致
- 右键菜单（暂停 / 显示速率 / 退出）、面板内设置（间隔 / 条数 / 口径 / 告警 / 开机启动）
- 故障自愈：看门狗按通道独立重启，连续失败 5 次转错误态；物理通道失效时自动退化为全接口合计
- 退出清理（SIGTERM 信号拦截 + SIGKILL 兜底）、启动时清理孤儿、单实例保护
- 104 项断言的纯逻辑自检（含 SQLite 读写、告警时序、趋势图光栅化、双通道并行采样）、无界面 `--headless`、离屏面板渲染

**未完成**
- 没有历史持久化：关掉应用后「本次累计」归零，看不到过去几天谁用得最多
- 没有按连接/域名下钻，只有进程维度
- 没有告警（某应用超过阈值时提醒）
- VPN 标记靠客户端名称匹配，无法精确到「哪个进程用了哪个接口」；漏识别只是少了盾牌标注，不影响总量

**已知问题（三档）**

| 严重度 | 问题 | 说明 |
|---|---|---|
| 影响体验 | 列表之和会大于总量 | 走 TUN 型 VPN 时，VPN 客户端显示的是物理链路上的加密字节，与隧道内应用的明文互为副本。**总量本身准确**（取自物理网卡），但不能把各行相加。行内盾牌标记 + 悬停说明提示这一点 |
| 边缘 | 只跑 IPv6 的隧道识别不到 | 隧道判据是 utun 上有 IPv4；此时只是不显示 VPN 标记，总量依然准确 |
| 边缘 | 改采样间隔仍有 250 ms 的空白 | 重建 nettop 必然丢一小段；期间曲线会出现一个缺口，属预期 |
| 边缘 | 面板打开时状态项有系统高亮底 | 这是 NSPopover 锚定绘制的高亮层：`button.highlight(false)`、`isBordered = false`、多次延迟清除**都无效**（实测被系统重绘覆盖）。彻底去掉要换成自绘 NSPanel，代价是材质、圆角、点外部关闭全部自己实现。当前选择保留 |
| 影响体验 | 开机自动启动在项目目录下会失败 | `SMAppService.mainApp.register()` 要求 app 位于可注册位置；注册失败会静默回滚开关，需拖进「应用程序」再用 |
| 影响体验 | 列表只显示有流量的应用 | 0 B/s 的进程被过滤（实测 32 个进程里 16 个是 0），想看完整进程表需要别的手段 |
| 边缘 | 偶发首次打开面板为空 | 冷启动第 1 个样本只是基线，速率全为 0 会被过滤掉；1 秒后自动恢复 |
| 边缘 | 系统守护进程显示齿轮图标 | `/usr/libexec/*` 没有 app bundle，无法取真实图标 |
| 边缘 | 只统计 TCP/UDP | ICMP、部分 RAW socket 不计入，与「活动监视器」的数字不完全一致 |

## 6. 外部依赖与凭据

- **第三方库：无**。只用系统框架：AppKit / SwiftUI / ServiceManagement / Combine /
  UserNotifications / Darwin(libproc) / **libsqlite3**（系统自带，实测 3.54.0，链接参数 `-lsqlite3`）。
- **外部进程**：`/usr/bin/nettop`（macOS 自带，Apple 未公开其 CSV 输出格式，属事实标准）。
- **凭据：不适用**。本应用不联网、不需要任何账号或密钥。
- 许可：本项目仅本机自用，未选择开源许可；若将来开源需先确认 `nettop` 输出格式的稳定性声明。

## 7. 数据与配置在哪

- 偏好：`~/Library/Preferences/com.zdx8.netscope.plist`
  键：`showRateInMenuBar`、`showMenuBarSparkline`、`sampleInterval`(1–5)、`maxVisibleRows`(3–15)、
  `physicalOnlyList`、`alertsEnabled`、`alertThresholdMBps`、`launchAtLogin`。
- **历史数据库**：`~/Library/Application Support/NetScope/traffic.db`（含 `-wal` / `-shm`）。
  单表 `daily_app_traffic(day, app_key, app_name, bytes_in, bytes_out, updated_at)`，
  主键 `(day, app_key)`，保留 120 天。
- 重置偏好（保留历史）：

  ```bash
  defaults delete com.zdx8.netscope
  pkill -x NetScope && open dist/NetScope.app
  ```

- 清空历史（**先退出应用**，否则 WAL 会把它写回去）：

  ```bash
  pkill -x NetScope
  rm -rf ~/Library/Application\ Support/NetScope
  ```

- 查库确认：

  ```bash
  sqlite3 ~/Library/Application\ Support/NetScope/traffic.db \
    "SELECT day, app_name, bytes_in, bytes_out FROM daily_app_traffic ORDER BY bytes_in DESC LIMIT 5;"
  ```

- 运行期除此之外不写任何文件（只有 `--render-panel` 才写你指定的 png）。

## 8. 维护手册

| 现象 | 排查步骤 | 日志位置 |
|---|---|---|
| 菜单栏看不到图标 | 菜单栏项太多会被系统挤出屏幕：先退出几个占位应用；再确认进程在跑 `pgrep -x NetScope` | 无 |
| 面板一直「正在采集…」 | `pgrep -f 'nettop -P -x'` 看子进程在不在；不在说明 spawn 失败，重启应用 | 无 |
| 面板显示「无法读取网络计数」 | 连续 5 次采样失败后的状态；点面板里的「重试」 | 无 |
| 流量数字全为 0 | 确认不是被暂停（标题右侧会写"已暂停"）；确认有真实外网流量（loopback 被排除） | 无 |
| 退出后 nettop 仍在跑 | 说明是被 SIGKILL 杀的（无法清理）。重启一次应用即可自动清扫 | 无 |
| 数字比实际偏大 | 大概率在走 VPN，见第 5 节 | 无 |

诊断用（沙箱里 `top`/`ps` 不可用时）：

```bash
swiftc -O -o /tmp/cpumeter Scripts/cpumeter.swift
/tmp/cpumeter $(pgrep -x NetScope) 10     # 输出 CPU% 与物理内存
```

## 9. 复现与验证清单

每条都给预期输出，照此可确认「在我手里是好的」。

```bash
cd "/Users/zyg/WorkBuddy/Software Development/NetScope"

# 1) 逻辑自检：104 项断言全过
bash Scripts/selfcheck/run.sh
# 预期末行：全部通过：104 项断言
# 其中包含隧道/客户端识别的合成数据用例（不依赖真实隧道是否有流量）

# 2) 真实二进制采样：退出码 0，且样本数 >= 3、进程数 > 0
BIN=dist/NetScope.app/Contents/MacOS/NetScope
"$BIN" --headless | tail -8
# 预期含：样本数 : 8 / 进程数 : 20~45 / 隧道状态 / 总量口径 : 物理网卡 / 结果 : 通过
# 开着 TUN 型 VPN 时，列表里能看到 VPN 客户端本身（它不再被剔除）

# 3) 前提校验：物理接口必须是全接口的子集
bash Scripts/traffic-probe.sh 8
# 预期末行：✓ 物理接口是全接口的子集
# 「虚拟接口部分」为 0 表示当前没有隧道/虚拟机流量，属于正常；> 0 就是被物理口径排除掉的那部分

# 3) 面板离屏渲染（浅色+深色两张，验证布局在极端数据下不塌）
"$BIN" --headless --demo --render-panel /tmp/check.png
# 预期：生成 /tmp/check-light.png（696×1024）与 /tmp/check-dark.png

# 4) 启动 + 菜单栏项存在
open dist/NetScope.app && sleep 4
pgrep -x NetScope                 # 预期一个 pid
pgrep -f 'nettop -P -x'           # 预期一个 pid（子进程）

# 5) 历史持久化：跑完 headless 后库里有数据
sqlite3 ~/Library/Application\ Support/NetScope/traffic.db \
  "SELECT count(*), sum(bytes_in+bytes_out) FROM daily_app_traffic;"
# 预期：行数 >= 1，字节数 > 0

# 6) 资源占用（10 秒平均）
swiftc -O -o /tmp/cpumeter Scripts/cpumeter.swift
/tmp/cpumeter $(pgrep -x NetScope) 10
# 实测：CPU 0.06% / 内存 34.8 MB；nettop 子进程 CPU 0.10% / 6.5 MB

# 7) 优雅退出不残留子进程
kill -TERM $(pgrep -x NetScope); sleep 2
pgrep -f 'nettop -P -x'           # 预期无输出

# 8) 孤儿清理（模拟异常退出）
open dist/NetScope.app; sleep 4
kill -9 $(pgrep -x NetScope); sleep 1.5
pgrep -f 'nettop -P -x'           # 预期仍有 1 个（孤儿）
open dist/NetScope.app; sleep 4
pgrep -f 'nettop -P -x'           # 预期只剩 1 个（旧孤儿已被清理）

# 9) 与网卡实际字节交叉校验（量级应一致，允许 20% 差异）
netstat -ib -I en0 | awk 'NR==2{print $7}'   # 读两次，与面板"本次累计"对比
```

## 10. 下一步建议

1. **历史持久化（优先级最高）**：按天把每个应用的累计写入 SQLite，面板加「今日/本周」切换。
   动 `MonitorEngine` + 新增 `HistoryStore`。这是把它从「看当下」变成「看趋势」的关键一步。
2. **VPN 流量去重**：识别 `utun*` 接口并排除物理接口上的重复计数。动 `NettopPTY` 的 `-t` 参数
   与 `TrafficAggregator` 的接口维度。
3. **菜单栏迷你趋势图**：用 `NSStatusItem` 的 `button.image` 动态画 20×18 的迷你曲线，
   比纯数字更直观。动 `StatusItemController.updateMenuBarTitle`。
4. **按域名下钻**：`nettop` 不加 `-P` 时能拿到每条连接，配合反查可做「哪个域名在吃流量」。
   数据量会大一个量级，需要节流。
5. **告警**：某应用连续 N 秒超过阈值时发通知（`UNUserNotificationCenter`）。

## 11. 变更历史

| 日期 | 版本 | 改了什么 |
|---|---|---|
| 2026-10-25 | 1.0.0 | 首版。确认 pty 方案可行，完成采样/差分/聚合/界面/打包全链路；59 项自检通过 |
| 2026-10-25 | 1.0.0+ | 修两处实测缺陷：FlClash 因聚合键来源不一致被拆成两行；nettop 在 pty 下忽略 SIGTERM 导致退出后残留子进程（补 SIGKILL 兜底 + 启动清理孤儿） |
| 2026-10-25 | 1.0.1 | 双通道采样：`.external` 出应用列表、`.physical` 出总量，修掉 VPN / 虚拟接口（Lima、Docker）导致的重复计数；隧道判据为 utun 上有 IPv4 |
| 2026-10-25 | 1.0.2 | 按用户要求调整口径：**总量仍取物理网卡，但不再剔除 VPN 类应用**——它们在物理链路上的字节是真实流量，照常显示并加盾牌标注。移除「已排除加密开销」提示，自检 86 → 78 项 |
| 2026-10-25 | 1.1.2 | 菜单栏默认形态改为**网络图标 + 双行数值**（上行在上、下行在下），趋势图降为右键可选。整块画成一张 template image：菜单栏按钮默认单行排版，塞两行文本会被压扁；文字区固定最小宽度 27pt，避免速率跳变时右侧图标左右抖动。移除 `showRateInMenuBar` 设置项 |
| 2026-10-25 | 1.1.1 | **修闪退**：点「刷新间隔」时在 segmented picker 的 action 里同步重启两条 nettop 通道（各 kill + usleep 80ms），主线程被卡在控件的事件帧里；改为延迟 250ms 再重启，并把重启挪出 UI 事件窗口。同时修掉「改间隔后 nettop 仍用旧 `-s`」的真 bug（`restart()` 没把新间隔传下去）。新增未捕获异常日志 `~/Library/Logs/NetScope-crash.log` |
| 2026-10-25 | 1.1.0 | 四项功能：**历史持久化**（SQLite 按天聚合，30 秒落盘节流，今日/7 天/Top 应用视图）、**菜单栏趋势图**（40 点下行曲线，template image）、**流量告警**（连续 3 次超阈值 + 10 分钟冷却）、**列表口径开关**（只统计物理链路）。自检 78 → 104 项 |
