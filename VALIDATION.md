# 本次验证记录

## 2026-10-14 点击事件收敛

1.0.7 继续修复录屏反馈的间歇性无法收起，改为原生鼠标按下事件负责本次切换，失焦关闭可被按钮事件取消。验证边界与结果见 [MENU_CLICK_FOLLOWUP.md](MENU_CLICK_FOLLOWUP.md)。

## 2026-10-13 菜单栏真实点击修复

1.0.6 修复再次点击图标无法收起。使用 WindowServer 鼠标事件复现 1.0.5 的失败，并核对修复后的实际窗口状态；过程和证据见 [MENU_CLICK_FIX.md](MENU_CLICK_FIX.md)。

## 2026-10-13 内存修复验证

读取线程的对照测试、完整趋势区域隔离、正常速度核对及修复范围见 [MEMORY_FIX.md](MEMORY_FIX.md)。修复与菜单栏动画归入 1.0.5；Mac mini 尚未完成修复版 24–48 小时验证。

## 2026-10-08 首次验证

日期：2026-10-08（Asia/Singapore）。

环境：Apple M1 Pro，MacBookPro18,3，arm64，macOS 27.2（26B5086k），Swift 6.4 Command Line Tools，macmon 0.9.0。

- Release 构建成功，生成原生 arm64 `.app`，使用本地 ad-hoc 签名。
- 发布 ZIP 解压到本机临时目录后，`codesign --verify --strict` 通过；ZIP 完整性检查通过。Documents 的 File Provider 会给原地 `.app` 重新附加 Finder 元数据，因此签名验证以干净的发布 ZIP 解压副本为准。安装脚本复制时排除扩展元数据。
- 8 项 Swift Testing 单元测试通过：真实 M1 Pro 输出、缺失指标、完整求和条件、非法数值 / 布尔值、合法零功率、非法 JSON / schema、逐字节 UTF-8 与多行分片、缓冲上限。
- 7 项进程故障测试通过：分片 JSON、硬件不支持的错误输出 / 非零退出、非法 JSON、只有 CPU 字段的部分 schema、找不到程序、拒绝 SIGTERM 的子进程清理、无输出时的诊断超时。
- `--diagnose` 连续读取四个真实样本，芯片名称、CPU / GPU / 合计功率与 CPU 温度正常。
- 原生 SwiftUI 深色界面、浅色设置展开界面使用真实采样渲染并目视检查，见 `preview.png` 与 `preview-settings.png`。图表、单位、字段与设置控件显示正常。预览图只有短时间采样，并非十分钟历史。
- 菜单栏应用通过 Launch Services 启动并持续运行，观察到单个 `macmon pipe --interval 2000 --soc-info` 子进程。
- 一次菜单栏收起时的进程快照约为应用 0.6% CPU / 41 MB 常驻内存，macmon 0.1% CPU / 10 MB。这是本机短时观察，不是跨机型性能基准。
- 构建、安装与测试脚本的 shell 语法检查通过。应用安装脚本未自动执行；目前运行的是项目 `dist` 中的应用。

未验证：Mac mini M5 Pro 实机传感器、macOS 13–26 实机运行、真实系统睡眠 / 唤醒、长时间稳定性、Developer ID 签名或公证。界面截图验证不等同于逐项人工点击测试。新芯片的支持以该机器 macmon 的实际输出和错误为准，尤其不能由零值推断传感器支持。
