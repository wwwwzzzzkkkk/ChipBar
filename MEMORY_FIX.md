# ChipBar 内存增长修复

日期：2026-10-13，Asia/Singapore。基线：Git 标签 `v1.0.4`。

## 现场与结论边界

用户提供的 Mac mini 取样报告：ChipBar 1.0.4，macOS 27.0.1（26A434），PID 60682，physical footprint 3.4G；启动于 10 月 10 日 04:51，取样于 10 月 13 日 15:57，约运行 83 小时。用户说明面板长期打开。

本机验证环境：Apple M1 Pro、macOS 27.2（26B5086k）。以下加速测试使用 M1 Pro JSON 夹具，未调用硬件传感器。线程取样不能给出 Mac mini 的堆对象归属，因此不能把现场 3.4G 全部归给某一组件，也没有完成 Mac mini 修复版的两天实机长测。

## 已复现的读取线程问题

两条长期 Dispatch 工作项循环调用 Foundation 读取数据，stdout 还使用 JSONSerialization。原版没有在循环内部释放 autorelease 临时对象，工作项直到采样停止才结束。错误诊断限长 4 KB、行缓冲限长 1 MB、历史限长 600 点，都不能约束这些对象。

同一真实 StreamClient、20,000 个样本、每样本约 1 ms 间隔，保持读取线程存活后测量：

| 测试 | 修复前 footprint | 修复后 footprint |
| --- | ---: | ---: |
| 正常 JSON，20,000 个样本 | 409.4 MiB | 2.8 MiB |
| 每样本再写 4 KB stderr，3,000 个样本 | 109.4 MiB | 2.5 MiB |

`leaks --autoreleasePools --groupByType` 进一步确认 stderr 对照测试中，旧版 autorelease pools 持有约 106.1M 数据，修复后约 15K。两条后台线程上 JSON 和读取对象的保留有直接证据。

修复：stdout 每块、JSON 每行、EOF 尾行以及 stderr 每块分别使用 autoreleasepool。保持原有错误报告、解析规则与子进程退出处理。

原始证据：`validation/2026-10-13/stream-baseline.json`、`stream-fixed.json`、`stream-baseline-stderr.json`、`stream-fixed-stderr.json` 和对应的 `.autorelease-summary.txt` 摘要。

## 趋势区域的独立增长

使用已经修复的 StreamClient、同一个 Monitor 和玻璃面板，以 20 ms 间隔输入样本。历史达到 600 点后持续更新，面板先打开 120 秒、关闭 30 秒，再打开 30 秒。

| 趋势绘制 | 15 秒 footprint | 115 秒 footprint | 180 秒 footprint |
| --- | ---: | ---: | ---: |
| 原 Swift Charts 趋势区域 | 77.5 MiB | 410.5 MiB | 522.2 MiB |
| 新 SwiftUI 路径绘图 | 29.1 MiB | 29.7 MiB | 30.1 MiB |

原趋势关闭阶段约保持在 420–430 MiB，重开后恢复增长。只从临时测试源码移除趋势区域的对照测试，历史、其他指标与玻璃仍保留，60 秒测试 footprint 保持约 25–26 MiB。

这将第二条增长路径隔离到原趋势区域。尚未定位 Swift Charts 内部的具体对象或系统框架缺陷，不声称已证明其内部某个缓存泄漏。新绘图从当前有界历史创建折线路径，保留功率刻度、三处时间标签、均值、缺失值及睡眠/重启间隙断线，增加孤立采样点显示和可访问性摘要。

关闭面板时将仪表盘从 NSHostingView 中移除，设置与历史保存在各自的状态对象内。重新打开使用同一个面板和材质视图，不重复创建窗口。

原始证据：`validation/2026-10-13/ui-soak-fixed.json`（读取已修复、趋势未替换）、`ui-soak-no-chart.json`、`ui-soak-path.json`。脚本通过命令行参数域设置临时夹具路径和间隔，不改变已保存偏好。

另以初始 600 点、之后每秒一个样本核对原趋势（读取仍使用修复版）：5 秒约 41.9 MiB、75 秒约 51.3 MiB；关闭后降到约 45.1 MiB，重开后 120 秒约 52.7 MiB，见 `ui-soak-chart-1hz.json`。正常速度也观察到增长，但这两分钟不足以区分初始化缓存和无限增长；不能将高频测试的斜率直接外推到 Mac mini 上两秒采样的增长速度。

## 检查和交付

- 8 项 Swift 解析测试、7 项子进程故障测试和 9 项版本/打包测试通过。
- Release arm64 构建、应用签名、ZIP 完整性和解压副本签名检查通过。
- 实际菜单栏文字、原生玻璃/旧系统磨砂、明暗模式、设置展开、关闭、重开、Esc 和外部点击关闭由菜单 QA 检查。
- 加速面板测试持续检查历史不超过 600 点，以及隐藏时仪表盘不在视图树中。
- 最终旧系统材质/缺失数据测试 60 秒通过，footprint 约 27.8–30.4 MiB；最终窗口截图确认折线在缺失数据处断开、时间标签完整、功率刻度与网格对齐，见 `validation/2026-10-13/ui-soak-gaps.json` 及其 `.window.png`。

## 菜单栏展开/收起动画

同日继续更新：点击一次展开、再次点击收起。使用 AppKit NSAnimationContext 和窗口自身的透明度，在现有窗口上执行约 0.16 秒淡入、0.12 秒淡出，缓入缓出。开启系统“减少动态效果”时立即切换。

以用户请求的目标状态决定切换，独立于淡出期间仍可见的窗口；动画回调携带代次，避免旧收起回调隐藏已经重新展开的面板。点击状态栏时的失焦处理不会抢先收起再被按钮重新打开。收起动画结束后才移除仪表盘，设置与历史继续保留。

原生玻璃和旧系统磨砂的菜单 QA 检查实际按钮动作、淡入/淡出中间透明度、收起中途重新展开、十次快速反向切换、设置状态保留、Esc、外部点击和即时关闭路径。结果见 `validation/2026-10-13/animation-native-final/transitions.json`、`animation-legacy-final/transitions.json`。系统“减少动态效果”开关未被修改；即时关闭路径由测试直接执行。

动画版本的 30 秒加速内存检查仍保持约 29 MiB，历史最多 600 点，关闭后仪表盘移除，见 `validation/2026-10-13/animation-memory.json`。

## 发布交付

本次修复与菜单栏动画归入 1.0.5，发行包见 [GitHub v1.0.5](https://github.com/wwwwzzzzkkkk/ChipBar/releases/tag/v1.0.5)。此前基于 1.0.4 的本地 memory-fix 测试包仅用于前期验证，正式更新应使用带新版本号的发行包。本次发布不会自动替换 Mac mini 上正在运行的旧应用。

在 Mac mini 上验证时，先保留必要的旧版内存现场记录，再退出旧版，将旧应用移到备份位置，解压并启动修复包。既有 macmon 与偏好设置仍可使用；退出会清空内存中的旧趋势。保持原先采样间隔和面板长期打开条件，观察至少 24–48 小时的 footprint；短时加速稳定不能代替实机长测。
