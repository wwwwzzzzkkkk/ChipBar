# 2026-10-13 验证快照

这些文件保留本次内存修复和菜单栏动画的本地验证结果，条件和结论边界见 [MEMORY_FIX.md](../../MEMORY_FIX.md)。后续验证输出写入 `audit-results/`，保留此日期的快照。

- JSON 记录是原始测试结果的副本；`manifest.json` 记录其 SHA-256。
- autorelease 摘要保留原始报告第 1–32 行，包含 footprint 与池内存统计；完整报告仍在本地 `audit-results/`，原文件 SHA-256 保留在 manifest 中。
- `ui-soak-fixed.json` 是读取线程已修复、原趋势尚未替换的对照；`ui-soak-path.json` 是新绘图结果。
- GUI 测试使用夹具或本机真实采样，不代表 Mac mini 24–48 小时实机长测。
