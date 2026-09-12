# Triage labels

This project uses the five default triage roles. When triaging a local implementation task, write the matching string on the `Status:` line at the top of the file.

| Role in the skill | Local label | Meaning |
| --- | --- | --- |
| `needs-triage` | `needs-triage` | waiting on a maintainer to assess it |
| `needs-info` | `needs-info` | waiting on the reporter for more information |
| `ready-for-agent` | `ready-for-agent` | specified well enough to hand to an agent |
| `ready-for-human` | `ready-for-human` | needs a human to implement |
| `wontfix` | `wontfix` | not going to be addressed |

Wherever a skill names one of these triage roles, use the local label from the table. Claiming and finishing tasks, and the status rules for decision tickets, are in [issue-tracker.md](issue-tracker.md).

To change the vocabulary later, edit the "Local label" column of this table.
