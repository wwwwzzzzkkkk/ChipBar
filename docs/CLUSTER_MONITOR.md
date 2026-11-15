# ChipBar Cluster Monitor v3.6.2

ChipBar 3.6 introduces **opt-in, read-only LAN monitoring**. It does **not**
start, stop, cancel, schedule, execute, or otherwise control simulations.
Users and external tools such as GPT/Codex retain full control of computations.

## 配对两台 Mac（无需复制密钥）

1. 在两台 Mac 上安装同一版 ChipBar，并打开菜单栏里的 **计算集群** 页面。
2. 搜索启动后，在「附近设备」中选择另一台 Mac，点击 **配对**。
3. 两边屏幕显示六位数字。确认两组数字**完全相同**后，
   分别点击 **数字一致，确认配对**。
4. ChipBar 会记住授权设备，并自动开启只读监控。之后只需运行
   ChipBar，无需再次复制密钥或重复配对。

每台 Mac 只在配对前传输设备名称和 X25519 公钥；监控数据
直到双方都在本机确认了同一个六位配对码、保存对方公钥后才交换。
32 字节会话密钥通过 X25519 + HKDF 分别生成，不经明文网络发送；
每帧监控数据继续使用 AES-256-GCM 加密及认证。
私钥、已信任的公钥存在各自 macOS 钥匙串中。不要在不可信设备或
无法核对配对数字的情况下确认配对。

可随时通过「共享」开关暂停本机共享；只读监控不包含任何
远程 Shell、任务调度或仿真启动/停止功能。

## 雷雳桥接连接检查

单独插上雷雳线不保证已建立可发现的 IP 网络。
在**两台** Mac 的「系统设置 → 网络」确认 **Thunderbolt Bridge**
已存在且处于已连接状态，TCP/IP 有可用地址；没有该服务就先新增。
此外，在「系统设置 → 隐私与安全性 → 本地网络」允许 ChipBar，
并在两台 Mac 的集群页保持搜索状态。
ChipBar 通过 Bonjour 搜索本地网络，可经可达的雷雳桥接或 Wi-Fi
进行通信；目前不会将任意检测到的雷雳设备误认为计算节点。
若打开了网络隔离、防火墙阻断或 MacBook 睡眠，设备可能不可达。

## v3.6.2 多来源日志监测和并行仿真分组

**最佳监测方式**：由用户或 GPT/Codex 在启动 OpenFAST 时将其原本就会
打印的 SttsTime 状态信息保存为日志，ChipBar 只负责读取该日志。
OpenFAST 的 Time / Timestep: X of Y seconds 消息是真实的仿真时间，
即使结果格式是二进制 .outb，也不需要为了监测而改成文字 .out。

示例：外部脚本（不是 ChipBar）启动时，可使用以下命令保留标准输出：

    set -o pipefail
    openfast case.fst 2>&1 | tee case.log

日志文件名 case.log 与 case.fst 对应。ChipBar 会自动检查关联进程的
stdout/stderr 已重定向文件路径，以及 case.log、case.stdout.log、
case.run.log、case.openfast.log、case.out.log。其它文件名如果不是
直接重定向的 stdout/stderr、也不是上述同名日志，可由 GPT/Codex
使用旧版 cluster-status.json 明确上报进度。

**检测优先级：** 外部状态 JSON（由 GPT/Codex 管理）→ 运行中的
OpenFAST 终端状态日志 → 同一运行生成的新鲜文本 .out → 进度未知。
仅扫描正在运行的进程；每份文件只读取尾部 16 KiB，且要求文件
修改时间不早于进程启动时间。日志报告的总仿真时长还需与
当前 .fst 的 TMax 基本一致。没有保存终端输出时，ChipBar 无法
事后读取已丢失的 stdout，亦不会强行抓取其它进程的输出或
替用户重启仿真。OpenFAST SttsTime 若关闭、太稀疏或流式输出未
及时写入日志，进度可能暂时未知或滞后。

**并行任务 UI：** 每个 Mac 节点最多显示 12 项当前 OpenFAST 进程；
同一节点有多个任务时默认折叠，仅展示「并行仿真 · N 项」。
全部任务均有有效进度时，汇总显示「平均 X%」和进度条（只是各
任务百分比的算术平均，不能解释为总计算量完成率）；否则显示
「有进度的任务数/总任务数」，不虚构平均值。点击可展开并逐项显示
LOG 或 OUT 来源、模拟时间、运行状态和预测剩余时间。
点击折叠不发送任何仿真控制命令，也不影响监控采样。

## v3.6.1 自动识别 OpenFAST 仿真进度

ChipBar **不会**启动、结束、暂停、取消或调度仿真。OpenFAST 仍由用户、
GPT/Codex 或用户自己的脚本管理。只有当「计算集群」面板打开或共享
已启用时，ChipBar 才在本地约每 9 秒低优先级读取现有进程和必要文件，
不另外启动 Shell、lsof 或其他任务执行进程。

对本机可读取的**正在运行的 OpenFAST 可执行进程**，只读采集：

- 通过进程参数确定 .fst 文件；相对路径使用该进程的真实工作目录，
  不使用 ChipBar 自身目录猜测。
- 从 .fst 的 TMax 字段读取总模拟时长。
- 仅从该次运行中近期写入的同名 .out **文本结果**读取最后完整数据行
  的 Time (s)，计算 progress = Time / TMax。
- 显示进度百分比、模拟时长/总模拟时长、进程实际运行时长，且在
  进度足够大时提供**近似**的墙上时钟剩余时间，不能保证准时完成。
- 对同一用户的多个 OpenFAST 进程最多显示 8 项；在当前集群设备间
  通过原有已授权 AES-GCM 遥测展示，不暴露绝对仿真文件路径。

**重要局限：** 默认只写入二进制 .outb 的 OpenFAST 情形，运行中通常
无法从输出文件可靠计算进度。必要时可由 GPT 的独立仿真脚本写出
cluster-status.json，或在未来仿真中启用 OutFileFmt=1/3 的文本输出
（修改仿真输入由用户/GPT 负责，ChipBar 永不修改）。
如果进程参数、文件权限、TMax 或新鲜的 .out 读数不可用，
ChipBar 只显示「进度未知」，绝不按 CPU 使用率、输出文件大小
或旧运行的 .out 猜测进度。只有外部状态文件时，
继续显示该文件中的真实状态。

### 与外部 GPT/Codex 状态文件的优先级

如果外部 cluster-status.json 提供了任务，ChipBar **优先采用该文件**；
否则回退到自动发现的 OpenFAST 进程。外部脚本可以提供更可靠的
运行状态和进度，包括只输出 .outb 的任务。

## External simulation state (optional)

ChipBar reads, but never writes, the following file on each Mac:

`~/Library/Application Support/ChipBar/cluster-status.json`

An external orchestration script can publish a single **small** JSON object,
preferably by writing a temporary file and atomically renaming it:

```json
{
  "tasks": [
    {"id": "case-001", "title": "OpenFAST case 001",
     "state": "running", "progress": 0.42},
    {"id": "case-002", "title": "OpenFAST case 002",
     "state": "running", "progress": null}
  ]
}
```

- `progress` is a fraction in **0...1**, not an estimated CPU percentage.
- If external progress is unavailable, omit the field or set it to `null`;
  ChipBar displays **进度未知**.
- Maximum file size is 64 KiB and up to 12 task entries are displayed.
- As of v3.6, ChipBar does **not** infer simulation progress from process
  names, CPU load, logs or guessed output file sizes. External tools own the
  lifecycle and validity of this file.
- A stale external file is not automatically interpreted as proof that a
  simulation is still running. External scripts should remove or update their
  own task entries when tasks end; do not rely on the file as an authoritative
  process inventory.

## Limitations of the first version

- ChipBar itself must remain running on both Macs. A separate login-item
  LaunchAgent is **not** included in this release.
- Pairing requires both users to visually compare and confirm a six-digit
  X25519 short authentication string. No monitoring values are sent before
  mutual approval. Bonjour still exposes service availability and the hello
  includes a device name and public key. No certificate-backed node identity
  or centralized PKI is implemented.
- Use trusted local networks only. This is not a public-internet service.
- The first version sends small snapshots every three seconds, only to
  separately trusted nodes. It does not
  transfer files, expose logs, or offer GPU cluster scheduling.
- LAN availability is subject to Bonjour routing, local-network permissions,
  macOS sleep, firewall and network isolation. CI compilation cannot prove
  cross-device connectivity without testing two physical Macs.
- None of the existing macmon hardware samplers, power accounting, or
  WidgetKit kinds were changed.
