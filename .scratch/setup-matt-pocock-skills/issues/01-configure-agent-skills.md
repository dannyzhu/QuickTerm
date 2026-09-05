# 配置本地工程技能工作流

Type: task
Status: resolved
Blocked by: none

## Question

如何让当前项目的工程技能使用本地 Markdown 保存决策地图和任务，并明确分诊标签及领域文档读取规则？

## Acceptance criteria

- [x] 根目录入口链接到三份工程技能配置。
- [x] 本地跟踪约定覆盖地图、规格、独立任务、依赖、领取与完成。
- [x] 记录五个默认分诊标签和单一领域上下文布局。
- [x] 验证配置引用、任务格式及文件可被 Git 跟踪。

## Answer

- 使用用户指定的本地 Markdown 跟踪方式，具体规则见 [issue-tracker.md](../../../docs/agents/issue-tracker.md)。
- 新建根目录 [AGENTS.md](../../../AGENTS.md) 作为技能入口；项目原先没有 `AGENTS.md` 或 `CLAUDE.md`。
- 本地已安装 `triage`，采用五个默认分诊标签，见 [triage-labels.md](../../../docs/agents/triage-labels.md)。
- 项目为单个 macOS 应用，采用 single-context 布局；领域文档按需创建，读取规则见 [domain.md](../../../docs/agents/domain.md)。
- 已验证六份 Markdown 的本地链接、默认标签、地图章节、跟踪约定、文件结尾及空白格式，所有文件均可被 Git 跟踪。本次仅修改文档，未运行应用构建和测试。

## Comments

- 2026-09-05：用户指定本地 Markdown；仓库尚无根目录 Agent 指令和技能配置。开始配置。
