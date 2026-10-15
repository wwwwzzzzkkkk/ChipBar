# 外接 NVMe SSD 温度验证（2026-10-16）

此功能通过 PR 交付，VERSION 为 1.2.0 候选；未创建发布标签、GitHub Release 或更新 Homebrew Cask。

## 已完成

- Swift Testing：29 项通过（原有 13 项 + 新增 16 项），覆盖真实脱敏 ZHITAI JSON、综合温度与稀疏传感器、异常数值、SMART 退出位、外接物理整盘筛选、模拟断连 / 重插编号变化、权限拒绝、有界输出、超时、取消、暂停 / 恢复、过期数据、自选程序禁止 sudo，以及取消后旧结果不能写回。
- 现有版本管理测试：9 项通过。
- arm64 release 可执行程序编译通过，应用版本为 1.2.0。Documents 中的 File Provider 在本次构建输出重新附加 Finder 元数据，导致构建脚本最后对工作副本的严格签名检查报错；现有打包脚本剔除这些元数据后，ZIP 解压副本的严格签名、ZIP 完整性及版本检查全部通过。没有修改现有打包流程。
- 现有 macmon 子进程故障集成检查：7 项通过。
- 实盘诊断：本机 Apple M5 Pro，macOS 27.0，smartctl 7.5，外接 `ZHITAI TiPlus7100s 2TB`，固件 ZTA25002。diskutil 将当前连接识别为外接 Physical / WholeDisk / PCI-Express；`-d auto` 在普通用户权限下读取成功。观测综合温度 46–47°C，两独立传感器会随采样变化，SMART PASSED。未公开磁盘序列号。
- 原生深色面板与浅色设置截图人工检查：型号、综合温度、两个传感器、健康状态和更新时间显示完整；设置说明换行完整。
- 实际菜单栏 QA：文字包含 `W · SSD 47°C`，状态项宽约 141.5 pt。面板正常开关、外部关闭后卸载；默认内容高度约 805 pt；展开设置的实际内容高度约 1326 pt，在本机 1080 pt 屏幕上限制到 1036 pt 并滚动。保留原有 Liquid Glass 面板。

原始日志、PNG 与布局 / 过渡报告保存在本地忽略目录 `audit-results/`，不上传桌面截图及进程排行。可复现命令：

```sh
python3 -m unittest discover -s Tests/ReleaseTests -v
./scripts/test.sh
./scripts/build.sh
python3 scripts/integration.py
python3 scripts/version.py package
dist/ChipBar.app/Contents/MacOS/ChipBar --diagnose-ssd
dist/ChipBar.app/Contents/MacOS/ChipBar --snapshot "$PWD/audit-results/ssd-dark.png" --ssd
dist/ChipBar.app/Contents/MacOS/ChipBar --snapshot "$PWD/audit-results/ssd-light.png" --ssd --settings --light
dist/ChipBar.app/Contents/MacOS/ChipBar --menu-qa "$PWD/audit-results/ssd-menu-qa" --ssd
```

`--ssd` 只在原有 snapshot / menu QA 模式中通过隔离的临时偏好启用 SSD，不改用户保存的 SSD 设置；正常启动仍按用户设置运行。

## 验证边界

未物理拔出在用磁盘、未令整机实际睡眠、未修改 sudoers、未对真实 sudo 拒绝 / 授权状态进行系统配置测试。断连、编号变化、权限拒绝及异步取消由测试夹具覆盖。睡眠 / 唤醒接入 NSWorkspace 通知，未做整机睡眠实测。UGREEN 40Gbps 盒体品牌来自用户说明，本机未独立确认盒体型号。其他 USB 桥接型号、混合桥接多盘、Intel Mac 与较旧 macOS 未做硬件验证。不推断温度传感器位置，不承诺所有硬盘盒均支持 SMART 透传。
