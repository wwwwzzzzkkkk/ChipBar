# 迁移后的维护范围

- 当前应用源码和发布流程位于 `https://github.com/wwwwzzzzkkkk/macmon` 的 `chipbar` 分支、`apps/ChipBar/` 目录；后续应用开发到该仓库进行。
- 此旧仓库保留历史源码和 Releases，仅维护迁移说明与 Homebrew 兼容入口。不要从旧仓库发布新的应用版本。
- `scripts/sync_cask.py` 从新仓库稳定 Release 及根目录 Cask 核对版本与校验值，更新本仓库的 `Casks/chipbar.rb`。

下面是迁移前约定，供历史参考。

# ChipBar 协作约定

- 每次完成用户要求的软件更新，都同步 GitHub 源码和版本记录：维护 CHANGELOG、递增 VERSION，并通过现有 `scripts/release.sh` 流程发布对应的 GitHub Release。
- 发版前完成相关验证；发布后确认工作流成功、安装包已上传，以及 Homebrew Cask 指向新版本。
- 不覆盖已有版本标签或已发布的安装包。验证过程输出放在 `audit-results/`，需要公开留档的证据摘要放在 `validation/`。
- 保持实现简洁，按改动范围完成必要构建、数值抽查与界面检查；没有新问题时不追加重复检查或长时间压力测试。
