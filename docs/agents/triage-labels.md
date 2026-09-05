# Triage Labels

本项目使用五个默认分诊角色。对本地实施任务进行分诊时，将对应字符串写入文件顶部的 `Status:` 行。

| 技能中的角色 | 本地标签 | 含义 |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | 等待维护者评估 |
| `needs-info` | `needs-info` | 等待报告者补充信息 |
| `ready-for-agent` | `ready-for-agent` | 规格充分，可交由 Agent 实施 |
| `ready-for-human` | `ready-for-human` | 需要人工实施 |
| `wontfix` | `wontfix` | 不予处理 |

技能提到某个分诊角色时，使用表中的本地标签。任务领取、完成以及决策任务的状态规则见 [issue-tracker.md](issue-tracker.md)。

以后需要调整词汇时，修改本表的“本地标签”列。
