# ChipBar 协作约定

- 每次完成用户要求的软件更新，都同步 GitHub 源码和版本记录：维护 CHANGELOG、递增 VERSION，并通过现有 `scripts/release.sh` 流程发布对应的 GitHub Release。
- 发版前完成相关验证；发布后确认工作流成功、安装包已上传，以及 Homebrew Cask 指向新版本。
- 不覆盖已有版本标签或已发布的安装包。验证过程输出放在 `audit-results/`，需要公开留档的证据摘要放在 `validation/`。
- 保持实现简洁，按改动范围完成必要构建、数值抽查与界面检查；没有新问题时不追加重复检查或长时间压力测试。
