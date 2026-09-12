# Issue tracker: local Markdown

This project's decision maps, specs and tasks live in local Markdown under `.scratch/` in the repo — that is the source of truth. When an engineering skill says "publish to the issue tracker", it means write a local file.

## Conventions

- One directory per effort: `.scratch/<effort>/`, the directory name in kebab-case.
- Decision map: `.scratch/<effort>/map.md`.
- Spec: `.scratch/<effort>/spec.md`, created once something needs a spec.
- Implementation tasks: `.scratch/<effort>/issues/<NN>-<slug>.md`, numbered consecutively from `01`, one file per task.
- An implementation task carries its triage role on a `Status:` line at the top of the file; the values are in [triage-labels.md](triage-labels.md). Use `claimed` once it is picked up, `resolved` once it is done.
- Comments and conversation history are appended at the end of the task file, under `## Comments`.
- These files are the persistent project record and can be committed to Git.

## When a skill says "publish to the issue tracker"

Create the file inside `.scratch/<effort>/`, following the file types above, and create the directory if it isn't there. Reuse an existing effort directory, leave what is already in it alone, and give a new task the next number nobody has taken.

## When a skill says "fetch the relevant ticket"

Read the task path the user pointed at. If all you were given is a number, look inside the current effort's `issues/` directory; if several efforts share that number and the context can't settle which one it is, ask the user to name the effort.

## Wayfinding operations

- **Map**: `.scratch/<effort>/map.md`, with the sections `Destination`, `Notes`, `Decisions so far`, `Not yet specified` and `Out of scope`. The map is an index; the detail behind a decision stays in the ticket.
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, named after its title, with the open question recorded under `## Question`. `Type:` at the top is `research`, `prototype`, `grilling` or `task`; `Status:` starts at `open`, becomes `claimed` when picked up and `resolved` when answered.
- **Blocking**: `Blocked by: NN, NN` at the top, referring to tickets in the same effort; write `Blocked by: none` when there are none. Work may start only once every dependency is `resolved`; a dependency that is missing counts as unresolved.
- **Frontier**: scan the current effort's `issues/`, keep the ones with `Status: open` whose dependencies are all resolved, and take the first by number.
- **Claim**: set `Status:` to `claimed` and save it before you start work.
- **Resolve**: record the answer, or what was done, under the ticket's `## Answer`, set `Status:` to `resolved`, then append one line to the map's `Decisions so far` — a link to the ticket title plus a summary of the conclusion.
- **Triage**: the five triage roles apply to implementation tasks; decision tickets use the `open` / `claimed` / `resolved` lifecycle above.

The record of the current configuration effort is in [Setting up QuickTerm's engineering skills](../../.scratch/setup-matt-pocock-skills/map.md).
