# 外接 NVMe SSD 温度

在“设置”开启“读取外接 NVMe SSD 温度”。默认关闭，因此未开启时不运行磁盘查询或 smartctl。面板默认显示温度、可用空间和实际读取 / 写入速度，点击“详情 / 收起”展开或隐藏传感器、健康信息及卷空间；约 0.2 秒动画同步内容高度、箭头和窗口尺寸，尊重“减少动态效果”。可另外开启“菜单栏附加 SSD 综合温度”，例如 `2.3 W · SSD 44°C`。多盘显示所有有效综合温度的最高值，面板列出每块盘的型号、磁盘编号、综合温度、传感器编号、SMART 状态和更新时间。只有传感器温度而没有综合温度时，菜单栏显示 `SSD —`，不会用某个传感器冒充综合温度。

## 安装与首次读取

```sh
brew install smartmontools
# 列出外接物理磁盘，编号可能在重插后改变
/usr/sbin/diskutil list external physical
# 将 disk4 换成当前编号；与 ChipBar 使用完全相同的只读参数
/opt/homebrew/bin/smartctl -j -i -H -A -d auto /dev/disk4
```

自动查找 Apple Silicon 和 Intel Homebrew 的 bin / sbin 路径；也可选择可信的 smartctl 可执行文件。缺失程序、无权限、不支持 SMART、无 NVMe 温度和读取超时均有提示。仅接收 smartctl JSON，不解析本地化终端表格。smartmontools 是可选依赖，不自动安装，也不影响 macmon 功率监控。

## ZHITAI TiPlus7100s 2TB + UGREEN 40Gbps

优先使用“自动识别”。40Gbps 硬盘盒可能以 PCIe / 原生 NVMe 呈现，不应仅凭品牌或带宽强制指定 USB 桥接协议。本机 2026-10-16 实测该 SSD 被 macOS 识别为外接 `PCI-Express`，smartctl 7.5 的 `-d auto` 成功返回型号、综合温度和两个传感器，且不需要 sudo。硬盘盒的品牌和型号来自用户提供的描述，本机查询未独立确认盒体型号。

USB 回退模式或其他桥接芯片可能需要在设置中选择 `sntasmedia`、`sntjmicron` 或 `sntrealtek`。应使用已确认在同一连接方式下可工作的类型；不自动轮流尝试协议。该设置应用到所有外接盘，混合桥接类型优先保留自动识别。硬盘盒不透传 SMART 时，软件无法补出温度。

JSON 的 `nvme_smart_health_information_log.temperature`（其次 `temperature.current`）是综合温度；`temperature_sensors` 是独立测温点，保留空缺位置及编号。这些字段已经是摄氏度，不再做 Kelvin 转换。不能仅凭编号认定主控 / 闪存位置。`percentage_used` 是设备估算寿命消耗，可能超过 100%，不会转换为未经证实的剩余寿命。

## 可用空间与实时读写速度

空间通过系统卷容量接口读取，显示“可用 / 总容量”，使用十进制单位；它是当前用户可用的文件系统空间，并非 SSD 物理空闲块或 SMART 寿命百分比。APFS 每个卷单独列出并注明共享空间，不把共享同一容器的卷容量相加；多卷时摘要提示展开详情，不伪造整盘剩余容量。未挂载、锁定或不可读时显示不可用。跨多个物理盘的卷不归到单块盘。

速率从当前外接整盘对应的 IOBlockStorageDriver 累计字节计数计算，按实际采样间隔换算为 MB/s（1 MB = 1,000,000 字节）。读取与写入分开显示；首个样本建立基线，不伪装为零。无 I/O 时有效零值显示 0.0；计数器缺失、归零、磁盘替换或采样间隔过长重新建立基线。它是整盘实际 I/O，不是 40Gbps 接口标称速度，也不是某次复制任务的文件进度；缓存命中的读操作不一定产生物理盘 I/O。

面板可见时每 2 秒查询原生计数器，容量缓存 30 秒；关闭面板停止，重新打开重建基线。暂停、睡眠、关闭功能及断连时不继续显示旧速率。普通用户即可使用，不需要 smartctl 或 sudo；未安装 smartctl 时仍发现外接物理盘并展示空间及速度，温度单独提示不可用。磁盘空间只在本机显示，随应用打包的 PrivacyInfo.xcprivacy 声明显示空间信息的用途。

原生接口依据：[IOKit 驱动统计](https://developer.apple.com/documentation/iokit/kioblockstoragedriverstatisticskey)、[可用卷容量](https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacitykey)。

## 读取权限

先尝试普通读取。本机实盘无需管理员权限，不要仅因此前命令使用了 sudo 就开启授权模式。

只有普通读取明确报权限不足、且用户已配置固定命令授权时，才开启“使用已配置的非交互 sudo”。ChipBar 调用 `/usr/bin/sudo -n -- <smartctl> -j -i -H -A -d <类型> /dev/diskN`。`-n` 禁止等待密码；普通终端中运行一次 `sudo smartctl` 不保证菜单栏应用获得权限。授权不存在或过期会显示失败，30 秒后再试，不保存密码、不自动修改 sudoers、不安装常驻管理员服务。

需要长期授权时，可由管理员使用 `sudo visudo -f /etc/sudoers.d/chipbar-smartctl` 为**实际用户名、标准 smartctl 路径、当前磁盘编号及设备类型**添加精确命令，例如：

```sudoers
# 将 YOUR_SHORT_USERNAME、路径、disk4 和 auto 换成实际值；不要保留占位符。
YOUR_SHORT_USERNAME ALL=(root) NOPASSWD: /opt/homebrew/bin/smartctl -j -i -H -A -d auto /dev/disk4
```

只允许该完整只读命令，不使用 `ALL` 命令授权或参数通配符。管理员需确认 smartctl 及其真实目标、父目录由可信账户维护，无法被不受信任的账户替换。配置语法可用 `sudo visudo -cf /etc/sudoers.d/chipbar-smartctl` 验证。以普通用户检查：

```sh
/usr/bin/sudo -n -- /opt/homebrew/bin/smartctl -j -i -H -A -d auto /dev/disk4
```

重插后磁盘编号可能改变，精确授权需对应调整；移除授权时用 visudo 删除这条规则。自选可执行文件始终以普通用户运行，应用禁用其 sudo 选项。无需授权的系统请保持此选项关闭。

## 生命周期与资源限制

- 每轮重新枚举外接物理整盘，排除内置盘、分区和虚拟卷；最多处理 8 块盘，逐盘确认外接 / 物理 / 整盘属性后再读取。硬盘编号不会被保存为设备身份，重插后重新发现。
- 每个程序运行最长约 5 秒，stdout 上限 1 MB，错误诊断上限 4 KB。读取和等待在后台，输出通过非阻塞管道读取；同时只运行一轮。每轮完成后等待 30 秒，失败也按该间隔重试。多盘或超时时实际刷新周期会更长。
- 不保存温度历史，面板关闭仍读取，以支持菜单栏。暂停、睡眠、关闭功能及退出时取消读取并清空温度；唤醒后重新发现。设置变更等待旧轮次退出后再启动。
- 挂载 / 卸载通知触发重新发现并清空旧数据。没有通知的物理断连在下轮发现；不代表即时硬件事件检测。单盘失败立即在该轮结果中替换旧读数；超过 90 秒的读数由每 5 秒检查移除。菜单栏和面板也检查时间有效性，不继续将过期温度显示为实时读数。
- SMART 退出码按位解释：读取 / 参数错误不保留旧数据；健康警告位不会丢弃有效温度。部分命令失败但仍有有效 NVMe 温度时显示温度，同时提示部分读取失败；健康未知不会显示 PASSED。

## 验证

```sh
./scripts/test.sh
./scripts/build.sh
# 一轮真实只读探测；不修改偏好设置，不使用 sudo
dist/ChipBar.app/Contents/MacOS/ChipBar --diagnose-ssd
# 选择可信的自定义程序或已确认的类型
dist/ChipBar.app/Contents/MacOS/ChipBar --diagnose-ssd --smartctl /path/to/smartctl --ssd-type auto
```

测试覆盖真实脱敏 TiPlus7100s JSON、传感器空缺 / 非法值、健康警告、权限失败、外接物理盘筛选、断连 / 编号变化、过期判断、命令超时 / 取消 / 输出限制。实机验证范围见 [验证记录](../validation/2026-10-16/README.md)。

接口依据：[smartctl 手册及退出状态位](https://github.com/smartmontools/smartmontools/blob/main/src/smartctl.8.in)、[NVMe JSON 字段与摄氏温度输出](https://github.com/smartmontools/smartmontools/blob/main/src/nvmeprint.cpp)。核对日期：2026-10-16。
