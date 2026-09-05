# Issue tracker: Local Markdown

本项目的决策地图、规格和任务以本地 Markdown 为准，保存在仓库的 `.scratch/` 下。工程技能中的“发布到任务跟踪器”表示写入本地文件。

## Conventions

- 每个事项使用独立目录：`.scratch/<effort>/`，目录名使用 kebab-case。
- 决策地图：`.scratch/<effort>/map.md`。
- 规格：`.scratch/<effort>/spec.md`，需要形成规格时创建。
- 实施任务：`.scratch/<effort>/issues/<NN>-<slug>.md`，从 `01` 连续编号，每个任务一个文件。
- 实施任务在文件顶部使用 `Status:` 行保存分诊角色，取值见 [triage-labels.md](triage-labels.md)；领取后使用 `claimed`，完成后使用 `resolved`。
- 评论和对话历史追加到任务文件末尾的 `## Comments` 下。
- 这些文件作为持久项目记录，可纳入 Git 版本管理。

## When a skill says "publish to the issue tracker"

按上述文件类型在 `.scratch/<effort>/` 内创建文件，必要时创建目录。复用已有事项目录，保留已有内容，新任务使用尚未占用的下一个编号。

## When a skill says "fetch the relevant ticket"

读取用户引用的任务路径。若只提供编号，在当前事项的 `issues/` 目录内查找；多个事项存在相同编号且上下文无法确定时，请用户指定事项。

## Wayfinding operations

- **Map**：`.scratch/<effort>/map.md`，包含 `Destination`、`Notes`、`Decisions so far`、`Not yet specified`、`Out of scope` 各节。地图作为索引，决策细节保存在任务中。
- **Child ticket**：`.scratch/<effort>/issues/NN-<slug>.md`，以标题命名，并在 `## Question` 下记录待解决的问题。顶部 `Type:` 为 `research`、`prototype`、`grilling` 或 `task`；`Status:` 初始为 `open`，领取后为 `claimed`，解决后为 `resolved`。
- **Blocking**：顶部使用 `Blocked by: NN, NN`，引用同一事项内的任务；无依赖时写 `Blocked by: none`。所有依赖均为 `resolved` 才可开始；缺失的依赖视为未解决。
- **Frontier**：扫描当前事项的 `issues/`，筛选 `Status: open` 且所有依赖已解决的任务，按编号选择第一个。
- **Claim**：开始工作前将 `Status:` 改为 `claimed` 并保存。
- **Resolve**：在任务的 `## Answer` 下记录答案或完成结果，将 `Status:` 改为 `resolved`，然后在地图的 `Decisions so far` 追加一行“任务标题链接 + 结论摘要”。
- **Triage**：五个分诊角色用于实施任务的分诊；决策任务使用上述 `open` / `claimed` / `resolved` 生命周期。

当前配置事项的记录见 [配置 QuickTerm 的工程技能](../../.scratch/setup-matt-pocock-skills/map.md)。
