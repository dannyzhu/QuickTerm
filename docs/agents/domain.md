# Domain Docs

## Before exploring, read these

- 阅读仓库根目录的 `CONTEXT.md`。
- 阅读 `docs/adr/` 中与当前工作相关的架构决策记录。
- 若以后出现根目录 `CONTEXT-MAP.md`，先读取地图，再读取其中与当前主题相关的上下文及其 ADR。

文件不存在时直接继续。由 `domain-modeling` 在术语或决策实际确定后按需创建领域文档。

## File structure

本项目采用 **single-context** 布局：

```text
/
├── CONTEXT.md
├── docs/adr/
│   └── NNNN-<decision>.md
└── Sources/
```

以上是按需创建的路径约定。`vendor/ghostty/` 是第三方依赖，不因此拆分项目领域上下文。

## Use the glossary's vocabulary

在任务标题、重构提案、假设和测试名称中引用领域概念时，使用 `CONTEXT.md` 定义的术语。缺少所需概念时，先核对项目现有用词；确有缺口则记录供 `domain-modeling` 处理。

## Flag ADR conflicts

建议与现有 ADR 冲突时，明确指出该 ADR，并解释重新讨论的理由。
