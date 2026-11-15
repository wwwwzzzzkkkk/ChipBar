# ChipBar WidgetKit · v3.4 交付与验收

本次只更新小组件、Codable 共享模型、快照适配层、URL Scheme 与打包配置；不更改 macmon/SMC/CPU/磁盘采样器的采样机制。

## 文件清单

- Sources/ChipBarCore/ChipBarSnapshot.swift：Codable、App Group 读写、预览示例
- Sources/ChipBarWidgets/GlassWidgetViews.swift：RingView、SparklineView、CoreBarsView、UsageBar、PillView、IconChip 与三尺寸布局
- Sources/ChipBarWidgets/GlassWidgetIntents.swift：macOS 14+ AppIntent 储存卷选择
- Sources/ChipBarWidgets/ChipBarWidgets.swift：新 kind、TimelineProvider、placeholder、旧 11 kind、四个 #Preview
- Sources/ChipBarWidgets/Localizable.xcstrings：简体中文、英文
- Sources/ChipBar/WidgetTelemetryBridge.swift：把已有采样的快照映射为共享模型、限频刷新新 kind
- Sources/ChipBar/MenuController.swift 与 Sources/ChipBar/App.swift：打开主面板、功率侧栏、磁盘详情
- WidgetExtension/ChipBarWidgets.xcodeproj/project.pbxproj：把三个小组件源码、共享模型和 Catalog 编译进扩展
- scripts/build.sh：主 App URL Scheme、可选的真实 Team/App Group 签名
- WidgetExtension/ChipBarWidgets.entitlements 和 Assets/ChipBarHost.entitlements：手动签名模板
- Tests/ChipBarCoreTests/ChipBarSnapshotTests.swift 与 Tests/ReleaseTests/test_version.py：单元和发布回归

## Xcode 手动配置

1. 使用 Xcode 26 打开 WidgetExtension/ChipBarWidgets.xcodeproj，Deployment Target 维持 macOS 13。确保 Sources 包括 Widget 与 Snapshot 共享文件，Resources 包含 Localizable.xcstrings。
2. 主程序当前由 SwiftPM 构建后封装为 .app，并非现有 WidgetExtension Xcode 工程中的第二个 target。若转为 Xcode 统一维护，需要添加 macOS App Target 和 Embed App Extensions，保持 Bundle ID local.chipbar.monitor 与 local.chipbar.monitor.widgets。
3. 开发者签名时须在主 App 与 Widget Extension 的 Signing & Capabilities 中添加相同 App Groups：group.local.chipbar.shared。将两个 .entitlements 模板分别用于对应 target。需要相同 Apple Developer Team、有效的配置与权限。
4. 正式开源发布仍为 ad-hoc 签名。没有开发者签名时不能宣称 App Group 已启用，也不要把受保护 entitlement 塞进 ad-hoc 包。代码会检测 entitlement，回退到旧版扩展容器路径，不影响已有组件。
5. 若已有真实 Team 签名证书，可设置 CHIPBAR_CODESIGN_IDENTITY 与 CHIPBAR_APP_GROUP_ID=group.local.chipbar.shared 后运行 scripts/build.sh。
6. 主程序 Info.plist 的 CFBundleURLSchemes 必须包含 chipbar（构建脚本已添加）。菜单栏 AppDelegate 使用 kAEGetURL 处理 chipbar://main、chipbar://disk/<编码后的卷名>、chipbar://power。
7. 储存卷 AppIntentConfiguration 需要 macOS 14+。macOS 13 使用新 kind 的 StaticConfiguration，默认显示两个卷。

## 新旧 kind

新的：ChipBar.Overview（小/中/大）、ChipBar.Storage（小型，可编辑储存卷）。
旧的 11 种必须继续注册：local.chipbar.telemetry.overview、powerTrend、cpu、gpu、memory、cpuCores、fan、ane、storage、powerSupply、applications（后缀；前缀均为 local.chipbar.telemetry.）。

## 设计及数据更新边界

新小组件仅读取 ChipBarSnapshot JSON，不执行硬件采样、不使用动画或 TimelineView。真实文件不存在时所有数字为破折号；预览固定示例仅在 #Preview 中使用。超过 180 秒透明度下降并提示数据已过期；系统可延迟时间线切换。
新两个 kind 的 reloadTimelines(ofKind:) 请求间隔至少 120 秒；实际桌面更新由 macOS WidgetKit 预算决定。通过有 Team 权限的 App Group 共享文件，ad-hoc 时使用旧版扩展容器回退。
系统容器背景由 containerBackground(for: .widget) 管理；清透及着色模式保持文字标签，不能仅靠颜色区分 CPU/GPU/内存。

## 验收清单

- [ ] 主 App 和真正的 WidgetKit .appex 构建、签名与 Bundle ID 验证通过
- [ ] Overview 三种尺寸与 Storage 小尺寸 #Preview 正常，参考数据完整
- [ ] 缺失 JSON 时数字全部为 —，不会展示预览样本
- [ ] 快照 181 秒时显示“数据已过期”并整体降低透明度
- [ ] macOS 13、14、26 的深浅色、清透/着色下文字和关键线条均可读
- [ ] 15 核柱状图、圆环、曲线、容量条不重叠，不超出 158×158、338×158、338×354 参考边界
- [ ] AppIntent 选择单卷后可放大显示该卷；macOS 13 回退静态两卷
- [ ] 原 11 个 widget kind 与旧桌面组件全部继续存在
- [ ] app 关闭后不启用任何 widget 侧采样进程，WidgetKit 自动显示过期
- [ ] chipbar://main / chipbar://disk/卷名 / chipbar://power 能打开相应页面
- [ ] pluginkit 可以发现扩展，chronod 不出现 WidgetKit 描述加载 Code 4099
